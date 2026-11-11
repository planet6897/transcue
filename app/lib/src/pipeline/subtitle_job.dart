import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../online/opensubtitles.dart';
import '../player/resume.dart' show formatPosition;
import '../settings/app_settings.dart';
import '../source/yt_dlp.dart';
import '../subtitle/bilingual_cue.dart';
import '../subtitle/webvtt.dart';
import '../translate/claude_translator.dart';
import 'media_tools.dart';
import 'speech_check.dart';
import 'stt_engine.dart';
import 'subsync.dart';
import 'tools.dart';
import 'whisper.dart';

/// 자막을 어디서 가져올지
sealed class JobSource {
  const JobSource();
}

class LocalFileSource extends JobSource {
  const LocalFileSource(this.path);
  final String path;
}

class YoutubeSource extends JobSource {
  const YoutubeSource(this.media, this.ytDlp);
  final YoutubeMedia media;
  final YtDlp ytDlp;
}

enum JobStage {
  idle,
  preparing,
  downloadingModel,
  extractingAudio,
  transcribing,
  translating,
  done,
  failed,
}

/// 저장된 결과를 어떻게 다시 만들지
enum JobRefresh {
  /// 저장된 결과를 그대로 사용
  none,

  /// 저장된 결과를 무시하고 내장·인터넷·YouTube 자막부터 다시 찾는다
  fetch,

  /// 저장된 결과와 기존 자막을 무시하고 음성 인식으로 만든다
  speech,
}

/// 영상 하나의 이중 자막을 만드는 작업.
///
/// 순서: 캐시 → (내장 자막 | YouTube 자막) → 없으면 음성 추출 + whisper STT
///       → 한국어가 없는 줄은 Claude 번역. STT/번역 결과는 생기는 대로 [cues]에 반영.
/// 구간마다 감지한 언어를 합친다. 영상 안에서 언어가 바뀌면 'auto'가 된다.
String mergeSpokenLang(String? current, String detected) =>
    current == null || current == detected ? detected : 'auto';

class SubtitleJob extends ChangeNotifier {
  SubtitleJob({
    required this.source,
    required this.settings,
    this.refresh = JobRefresh.none,
    Duration Function()? playhead,
    Duration Function()? mediaDuration,
  }) : playhead = playhead ?? (() => Duration.zero),
       mediaDuration = mediaDuration ?? (() => Duration.zero);

  /// 저장된 결과는 새 결과가 저장될 때 덮어쓰므로, 다시 만들다 실패해도 남는다.
  final JobRefresh refresh;

  /// 플레이어가 알려 준 영상 길이 (ffprobe가 없는 모바일용)
  final Duration Function() mediaDuration;

  /// 영상 정보. 모바일은 ffprobe가 없어 플레이어의 길이만 쓴다 (내장 자막 없음).
  Future<MediaInfo> _probe(String path) async {
    if (hasDesktopTools) return probe(path);
    var d = mediaDuration();
    for (var i = 0; i < 100 && d <= Duration.zero; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      d = mediaDuration();
    }
    return MediaInfo(duration: d, subtitles: const []);
  }

  final JobSource source;
  final AppSettings settings;

  /// 현재 재생 위치. 음성 인식/번역을 이 위치부터 먼저 한다.
  final Duration Function() playhead;

  List<BilingualCue> cues = const [];
  JobStage stage = JobStage.idle;
  double? progress;
  String status = '';
  String? sourceLang;

  /// 원문 소스 설명 (예: "내장 자막", "음성 인식")
  String originalFrom = '';
  static const fromStt = '음성 인식';

  bool _fromCache = false;

  /// 이 영상에 대해 OpenSubtitles 검색을 이미 했는지 (다운로드 한도 절약)
  bool _osTried = false;

  /// 사용자에게 알릴 오류/안내 (번역 실패 등). 원문 자막은 계속 사용 가능.
  String? notice;

  bool _disposed = false;
  bool _sttDone = false;

  /// 음성 인식이 끝난 구간 (ms). 부분 결과 저장/이어하기, 번역 가능 여부 판단에 쓴다.
  final List<(int, int)> _covered = [];

  /// 저장된 결과가 끝까지 완료된 것인지 (음성 인식 도중 저장된 부분 결과면 false)
  bool _complete = true;

  /// 캐시 형식/품질이 바뀌면 올린다. v2: whisper -mc 0 적용
  static const _cacheVersion = 2;
  static const _batchSize = 30;

  /// 재생 위치 근처는 작은 묶음으로 빨리 번역한다
  static const _nearBatchSize = 15;
  static const _contextSize = 5;

  /// 음성 인식 조각 길이: 처음(또는 이동 직후)은 짧게 해서 자막이 빨리 나오게
  static const _firstChunkMs = 20000;
  static const _chunkMs = 30000;

  /// 조각 끝에서 문장이 잘리지 않도록 더 읽는 시간
  static const _tailMs = 4000;

  // ---- 진행 상태 ----

  void _set(JobStage s, String msg, [double? p]) {
    if (_disposed) return;
    stage = s;
    status = msg;
    progress = p;
    notifyListeners();
  }

  void _setCues(List<BilingualCue> c) {
    if (_disposed) return;
    cues = c;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ---- 캐시 ----

  Future<File> _cacheFile() async {
    final key = switch (source) {
      LocalFileSource(:final path) => () {
        final st = File(path).statSync();
        return '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
      }(),
      YoutubeSource(:final media) => 'yt:${media.id}',
    };
    final dir = Directory('${(await AppSettings.supportDir()).path}/cache');
    await dir.create(recursive: true);
    return File('${dir.path}/${sha1.convert(utf8.encode(key))}.json');
  }

  /// 개발용 스위치 (실기기 검증 시 저장 결과·API 비용에 영향 없게)
  static bool _dbg(String k) => kDebugMode && Platform.environment[k] == '1';

  Future<void> _saveCache() async {
    if (_dbg('DUALCUE_NO_CACHE')) return;
    // 중단된 작업은 저장하지 않는다. 일부만 인식한 결과가 완료로 기록되거나,
    // 다시 만들기를 시작한 새 작업의 결과를 덮어쓰게 된다.
    if (_disposed) return;
    if (cues.isEmpty && _covered.isEmpty) return;
    final f = await _cacheFile();
    await f.writeAsString(
      jsonEncode({
        'v': _cacheVersion,
        'lang': sourceLang,
        'from': originalFrom,
        'osTried': _osTried,
        'sync': ?syncInfo,
        'release': ?_release,
        'speech': ?speechMatch,
        // 음성 인식 중간 저장: 다시 열면 남은 구간만 이어서 인식
        'complete': _sttDone || originalFrom != fromStt,
        if (originalFrom == fromStt)
          'covered': [
            for (final (a, b) in _covered) [a, b],
          ],
        'cues': [for (final c in cues) c.toJson()],
      }),
    );
  }

  /// 저장된 결과를 읽는다. 버린 경우 읽다 만 값(싱크 정보 등)이 남지 않게 되돌린다.
  /// (실사례: 잘못된 자막의 '싱크 +114.6초'가 음성 인식 자막에 표시됨)
  Future<bool> _loadCache() async {
    if (await _readCache()) return true;
    sourceLang = null;
    originalFrom = '';
    _osTried = false;
    syncInfo = null;
    _release = null;
    speechMatch = null;
    _complete = true;
    _covered.clear();
    _fromCache = false;
    return false;
  }

  /// 예전에 저장된 깨진 번역은 지워서 다시 번역하게 한다
  static BilingualCue _repairSaved(BilingualCue c) {
    final t = c.translation;
    return t != null && isBrokenKorean(t) ? c.withTranslation(null) : c;
  }

  Future<bool> _readCache() async {
    if (_dbg('DUALCUE_NO_CACHE')) return false;
    final f = await _cacheFile();
    if (!await f.exists()) return false;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['v'] != _cacheVersion) return false; // 이전 버전 결과는 다시 만든다
      sourceLang = j['lang'] as String?;
      originalFrom = '${j['from'] ?? '저장된 자막'}';
      _osTried = j['osTried'] == true;
      syncInfo = j['sync'] as String?;
      _release = j['release'] as String?;
      speechMatch = (j['speech'] as num?)?.toDouble();
      // 이름 검색으로 받은 예전 결과는 연도 검사 전이라 다시 확인한다
      if (originalFrom == _fromNameSearch && _release == null) {
        debugPrint(
          'cache rejected: name-search subtitles saved before year check',
        );
        return false;
      }
      // 음성 인식 자막을 실시간 보정이 잘못 옮겨 저장한 결과: 원래 시간을 되살릴 수 없어 다시 만든다
      if (originalFrom == fromStt && (syncInfo?.startsWith('실시간') ?? false)) {
        debugPrint(
          'cache rejected: speech-recognized subtitles shifted by live sync',
        );
        return false;
      }
      _complete = j['complete'] != false;
      final saved = [
        for (final c in (j['cues'] as List).cast<Map<String, dynamic>>())
          _repairSaved(BilingualCue.fromJson(c)),
      ];
      if (source case LocalFileSource(:final path) when _complete) {
        // 예전에 잘못 받은 인터넷 자막 등: 영상 길이와 안 맞으면 버리고 다시 만든다
        if (!fitsDuration(saved, (await _probe(path)).duration)) {
          debugPrint('cache rejected: subtitles do not fit the video length');
          return false;
        }
      }
      for (final c in (j['covered'] as List? ?? []).cast<List>()) {
        _addCovered((c[0] as num).toInt(), (c[1] as num).toInt());
      }
      _fromCache = true;
      _setCues(saved);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- 실행 ----

  Future<void> run() async {
    try {
      _set(JobStage.preparing, '자막 준비 중…');
      final cached = refresh == JobRefresh.none && await _loadCache();
      // 직접 음성 인식을 고른 결과가 다음에 열 때 인터넷 자막으로 바뀌지 않게 한다
      if (refresh == JobRefresh.speech) _osTried = true;
      var have = cached && _complete;
      // 저장된 결과가 음성 인식이면 인터넷 자막을 먼저 찾아본다 (있으면 우선 사용)
      if (cached && _shouldTryOnlineOverCache && await _tryOnlineOverCache()) {
        have = true;
      }
      if (!cached &&
          refresh != JobRefresh.speech &&
          await _loadExistingSubtitles()) {
        have = true;
      }
      // 받아 온 자막이 실제 음성과 같은 내용인지 확인 (번역 비용을 쓰기 전에)
      if (have && _needsSpeechCheck && !await _checkSpeech()) have = false;
      if (!have) {
        // 처음부터, 또는 중간 저장된 음성 인식을 이어서
        await _speechToText();
        // 인터넷에서 한국어 자막만 찾은 경우: 음성 인식 결과에 시간 기준으로 붙인다
        final ko = _onlineKorean;
        if (ko != null) {
          _setCues(mergeTranslation(cues, ko));
        }
      }
      _sttDone = true;
      await _saveCache();
      if (_needsSync) {
        // 한국어 자막을 다시 붙여야 하면 번역 전에, 아니면 번역과 동시에 싱크를 맞춘다
        if (_onlineKorean != null) {
          await _autoSync();
          _checkKoreanTiming();
        } else {
          unawaited(_wholeFileSync = _autoSync());
        }
      }
      unawaited(_liveSyncLoop());
      await translateRemaining();
      if (stage != JobStage.failed) {
        _set(JobStage.done, _summary());
      }
    } catch (e, st) {
      debugPrint('SubtitleJob failed: $e\n$st');
      _set(JobStage.failed, '자막 생성 실패: $e');
    }
  }

  String _summary() {
    final n = cues.length;
    final t = _translatedCount;
    final trans = sourceLang == 'ko'
        ? ''
        : t == n
        ? ' · 번역 완료'
        : ' · 번역 $t/$n';
    final sync = syncInfo == null ? '' : ' · $syncInfo';
    final speech = speechMatch == null
        ? ''
        : speechMatch! < 0
        ? ' · 음성 대조 불가'
        : ' · 음성 대조 ${(speechMatch! * 100).round()}% 일치';
    final w = settings.showVocab && sourceLang != 'ko'
        ? ' · 단어 ${cues.where((c) => c.words != null).length}/$n'
        : '';
    return '자막 $n줄 ($originalFrom${_fromCache ? ' · 저장됨' : ''})$trans$w$sync$speech';
  }

  /// 내장 자막 또는 YouTube 자막. 찾으면 true.
  Future<bool> _loadExistingSubtitles() async {
    switch (source) {
      case LocalFileSource(:final path):
        final info = await _probe(path);
        final orig = info.originalTrack;
        if (orig != null) {
          var c = await extractEmbeddedSubtitle(path, orig);
          if (c.isNotEmpty) {
            final ko = info.koreanTrack;
            if (ko != null) {
              c = mergeTranslation(c, await extractEmbeddedSubtitle(path, ko));
            }
            sourceLang = orig.language;
            originalFrom = '내장 자막';
            _setCues(c);
            return true;
          }
        }
        return _loadOnlineSubtitles(path, info);

      case YoutubeSource(:final media, :final ytDlp):
        final orig = media.original;
        if (orig == null) return false;
        var c = parseWebVtt(await ytDlp.fetchCaption(media, orig));
        if (c.isEmpty) return false;
        sourceLang = media.language ?? orig.lang.split('-').first;
        originalFrom = orig.auto ? 'YouTube 자동 자막' : 'YouTube 자막';
        _setCues(c);
        final ko = media.korean;
        // YouTube 자동 번역은 429가 잦아 실패해도 Claude 번역으로 넘어간다
        if (ko != null) {
          try {
            c = mergeTranslation(
              c,
              parseWebVtt(await ytDlp.fetchCaption(media, ko)),
            );
            _setCues(c);
          } on YtDlpException catch (e) {
            debugPrint('YouTube Korean captions failed: $e');
          }
        }
        return true;
    }
  }

  bool get _shouldTryOnlineOverCache =>
      source is LocalFileSource &&
      settings.hasOpenSubtitles &&
      !_osTried &&
      originalFrom == fromStt;

  /// 인터넷 원어 자막으로 교체했으면 true
  Future<bool> _tryOnlineOverCache() async {
    final path = (source as LocalFileSource).path;
    final stt = cues;
    if (await _loadOnlineSubtitles(path, await _probe(path))) {
      _fromCache = false; // 인터넷 자막으로 교체됨
      _covered.clear();
      return true;
    }
    if (_onlineKorean case final ko?) {
      // 한국어 자막만 있으면 저장된 음성 인식 원문에 붙인다
      _setCues(mergeTranslation(stt, ko));
    }
    return false;
  }

  /// 인터넷에서 찾은 한국어 자막 (원본 시간 그대로, 싱크 보정 전)
  List<BilingualCue>? _onlineKorean;

  /// 원어 자막을 인터넷에서 가져왔는지
  bool _onlineOriginal = false;

  // ---- 음성 대조 ----

  /// 자막과 실제 음성의 일치율 (0~1). -1 = 말소리가 적어 판단 못 함, null = 안 함
  double? speechMatch;

  bool get _needsSpeechCheck =>
      source is LocalFileSource &&
      originalFrom != fromStt &&
      speechMatch == null &&
      cues.isNotEmpty &&
      !_dbg('DUALCUE_NO_VERIFY');

  /// 저장된/내장 자막 확인. 안 맞으면 자막을 버리고 음성 인식으로 넘어간다.
  Future<bool> _checkSpeech() async {
    if (await _speechMatches(cues)) {
      await _saveCache();
      return true;
    }
    _onlineOriginal = false;
    _onlineKorean = null;
    _fromCache = false;
    _complete = false;
    _covered.clear();
    _release = null;
    syncInfo = null;
    _setCues(const []);
    return false;
  }

  /// [c]가 실제 음성과 같은 내용이면 true (판단 못 하거나 확인이 실패해도 true).
  /// 안 맞으면 [notice]를 남긴다.
  Future<bool> _speechMatches(List<BilingualCue> c, {String? lang}) async {
    if (_dbg('DUALCUE_NO_VERIFY') || !canTranscribe) return true;
    final path = (source as LocalFileSource).path;
    // 확인하는 동안에도 자막(원문)은 바로 보여 준다. 번역은 확인이 끝난 뒤에.
    final before = cues;
    _setCues(c);
    try {
      _set(JobStage.preparing, '자막이 음성과 맞는지 확인 중…');
      final model = await ensureWhisperModel(
        settings.whisperModel,
        onProgress: (p) => _set(
          JobStage.downloadingModel,
          '음성 인식 모델 내려받는 중 (처음 한 번) ${(p * 100).toStringAsFixed(0)}%',
          p,
        ),
      );
      final r = await checkAgainstSpeech(
        input: path,
        cues: c,
        duration: (await _probe(path)).duration,
        model: model,
        vadModel: await ensureVadModel(),
        language: lang ?? sourceLang ?? 'auto',
        onSample: (n) =>
            _set(JobStage.preparing, '자막이 음성과 맞는지 확인 중 ($n번째 구간)…'),
      );
      debugPrint(
        'speech check: ${r.describe()} (${r.matched}/${r.pairs}, ${r.samples}구간)',
      );
      if (r.matches) {
        speechMatch = r.conclusive ? r.ratio : -1;
        return true;
      }
      // 다른 작품/에피소드 자막
      notice =
          '받은 자막이 음성과 맞지 않아(${(r.ratio * 100).round()}% 일치) '
          '음성 인식 자막을 사용합니다';
      _setCues(before); // 보여 주던 받은 자막을 거둔다
      return false;
    } on Exception catch (e) {
      debugPrint('speech check failed: $e');
      return true; // 확인 실패는 자막을 그대로 쓴다
    }
  }

  /// 인터넷 한국어 자막이 원문 줄과 시간이 맞는지.
  /// 절반 넘게 비어 있으면 다른 편집본 자막이라 버리고 Claude 번역을 쓴다.
  void _checkKoreanTiming() {
    // 음성 인식 원문은 줄을 다르게 나눠서 비교 기준이 못 된다
    if (_onlineKorean == null || !_onlineOriginal || cues.isEmpty) return;
    final r = koreanCoverage(cues);
    debugPrint('korean timing: ${(r * 100).round()}% of lines covered');
    if (r >= 0.5) return;
    notice = '인터넷 한국어 자막이 음성과 맞지 않아(${(r * 100).round()}%) Claude로 번역합니다';
    _onlineKorean = null;
    _setCues([for (final c in cues) c.withTranslation(null)]);
    unawaited(_saveCache());
  }

  static const _fromNameSearch = 'OpenSubtitles · 이름 검색';

  /// 받은 인터넷 자막의 릴리스 이름 (저장 결과 검증용)
  String? _release;

  // ---- 싱크 ----

  /// 사용자가 [ ] 키로 옮긴 누적 시간
  Duration manualOffset = Duration.zero;

  bool get _needsSync =>
      source is LocalFileSource && (_onlineOriginal || _onlineKorean != null);

  /// 인터넷 자막의 시간을 음성 구간에 맞춘다. 실패해도 자막은 그대로 쓴다.
  Future<void> _autoSync() async {
    if (!hasDesktopTools) return; // ffmpeg 없음 (모바일)
    final path = (source as LocalFileSource).path;
    final tmp = await Directory.systemTemp.createTemp('transcue_sync_');
    try {
      if (stage != JobStage.translating) {
        _set(JobStage.preparing, '자막 싱크 확인 중 (음성 구간 분석)…');
      }
      final wav = '${tmp.path}/audio.wav';
      await extractAudio(path, wav);
      final speech = await detectSpeech(wav, await ensureVadModel());
      final notes = <String>[];

      // 원어 자막: 현재 목록에 바로 적용 (번역은 줄 순서로 붙어 있어 그대로 유지)
      if (_onlineOriginal) {
        final r = findBestSync(cues, speech);
        debugPrint(
          'sync original: ${r.describe()} score ${r.baseScore} → ${r.score} / ${r.total}',
        );
        if (r.improves) {
          _setCues(applySync(cues, r));
          notes.add('원문 ${r.describe()}');
        }
      }
      // 한국어 자막: 따로 맞춘 뒤 원문에 다시 붙인다 (다른 릴리스용일 수 있음)
      final ko = _onlineKorean;
      if (ko != null) {
        final r = findBestSync(ko, speech);
        debugPrint(
          'sync korean: ${r.describe()} score ${r.baseScore} → ${r.score} / ${r.total}',
        );
        if (r.improves) {
          final fixed = applySync(ko, r);
          final cleared = [for (final c in cues) c.withTranslation(null)];
          _setCues(mergeTranslation(cleared, fixed));
          notes.add('한국어 ${r.describe()}');
        }
      }
      syncInfo = notes.isEmpty ? '싱크 정상' : '싱크 자동 보정: ${notes.join(', ')}';
      await _saveCache();
      if (stage == JobStage.done || stage == JobStage.preparing) {
        _set(JobStage.done, _summary());
      } else if (!_disposed) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('auto sync failed: $e');
      syncInfo = '싱크 자동 보정 실패';
    } finally {
      await deleteTempDir(tmp);
    }
  }

  String? syncInfo;

  /// 수동 싱크 조정 ([ / ] 키). 저장된 결과에도 반영.
  Future<void> nudge(Duration d) async {
    if (cues.isEmpty) return;
    manualOffset += d;
    _setCues(shiftCues(cues, d));
    await _saveCache();
  }

  // ---- 실시간 싱크 ----

  static const _liveInterval = Duration(seconds: 10);

  /// 한 번에 비교하는 길이. 40초는 대사가 빽빽한 시트콤에서 측정이 들쭉날쭉해
  /// (+3초 밀린 2 Broke Girls: +3.5, -3.7, -7.5초…) 두 번 연속 일치가 거의 안 나왔다.
  /// 90초면 24번 중 22번이 +2.3~3.7초, 싱크가 맞는 영상에서는 12번 모두 판단 보류.
  static const _liveWindow = Duration(seconds: 90);

  /// 영상 전체 싱크 작업. 끝나기 전에 옮기면 두 보정이 겹친다.
  Future<void>? _wholeFileSync;

  /// 판본이 다른 자막은 광고 구간 등에서 어긋나는 양이 구간마다 달라
  /// 영상 전체에 한 번 적용하는 [_autoSync]만으로는 맞출 수 없다.
  /// 음성 인식 자막은 같은 소리에서 시간을 얻었으므로 맞출 필요가 없다. 게다가
  /// whisper 자막은 문장 사이 빈 시간까지 이어 붙여 길어서, 비교하면 거의 매번
  /// 몇 초 밀린 것처럼 잘못 잰다 (2 Broke Girls 10분: −7.8초가 두 번 연속 → 잘못 적용).
  bool get _canLiveSync =>
      canDetectSpeech &&
      source is LocalFileSource &&
      originalFrom != fromStt &&
      cues.isNotEmpty;

  /// 재생 중 앞으로 나올 구간의 음성과 자막을 계속 비교해 어긋나면 그 지점부터 옮긴다.
  Future<void> _liveSyncLoop() async {
    await _wholeFileSync;
    if (_disposed || !_canLiveSync) return;
    final path = (source as LocalFileSource).path;
    final tmp = await Directory.systemTemp.createTemp('transcue_live_');
    try {
      final vad = await ensureVadModel();
      final tracker = LiveSyncTracker();
      var last = playhead() - _liveInterval; // 첫 측정은 기다리지 않는다
      for (var first = true; !_disposed; first = false) {
        if (!first) await Future<void>.delayed(_liveInterval);
        if (_disposed) break;
        final now = playhead();
        final moved = now - last;
        last = now;
        // 앞뒤로 건너뛰었으면 다른 구간이므로 이전 측정값을 버린다
        if (moved.isNegative || moved > _liveInterval * 2) tracker.reset();
        if (moved < const Duration(seconds: 5)) continue; // 일시정지
        // 사용자가 직접 맞춘 뒤에는 건드리지 않는다
        if (manualOffset != Duration.zero) continue;
        final end = now + _liveWindow;
        final near = [
          for (final c in cues)
            if (c.start >= now && c.start < end) c,
        ];
        try {
          final speech = await speechInRange(
            input: path,
            start: now,
            length: _liveWindow,
            vadModel: vad,
            tmp: tmp,
          );
          final measured = estimateLocalOffset(shiftCues(near, -now), speech);
          debugPrint('[live-sync] at ${now.inSeconds}s measured $measured');
          final offset = tracker.add(measured);
          if (offset == null || _disposed) continue;
          _setCues(shiftCuesFrom(cues, now, offset));
          final s = offset.inMilliseconds / 1000;
          syncInfo = '실시간 보정 ${s >= 0 ? '+' : ''}${s.toStringAsFixed(1)}초';
          debugPrint('[live-sync] applied $offset from ${now.inSeconds}s');
          await _saveCache();
          if (stage == JobStage.done) _set(JobStage.done, _summary());
        } on Exception catch (e) {
          debugPrint('live sync check failed: $e');
        }
      }
    } on Exception catch (e) {
      debugPrint('live sync stopped: $e');
    } finally {
      await deleteTempDir(tmp);
    }
  }

  /// OpenSubtitles에서 원어/한국어 자막을 찾는다. 원어를 찾으면 true.
  /// 실패해도 예외를 내지 않고 음성 인식으로 넘어간다.
  Future<bool> _loadOnlineSubtitles(String path, MediaInfo info) async {
    if (!settings.hasOpenSubtitles || _dbg('DUALCUE_NO_ONLINE')) return false;
    _set(JobStage.preparing, '인터넷 자막 검색 중 (OpenSubtitles)…');
    final lang = osLang(info.audioLanguage);
    try {
      final os = OpenSubtitlesClient(
        apiKey: settings.osApiKey,
        username: settings.osUsername,
        password: settings.osPassword,
      );
      final name = parseReleaseName(path);
      String? hash;
      try {
        hash = await openSubtitlesHash(File(path));
      } catch (_) {}
      final hits = await os.search(
        hash: hash,
        name: name,
        languages: lang == 'ko' ? 'ko' : '$lang,ko',
      );
      _osTried = true; // 검색이 성공했을 때만 기록 (키 오류면 다음에 다시 시도)
      final origHit = pickBest(hits, lang, name: name);
      final koHit = lang == 'ko' ? null : pickBest(hits, 'ko', name: name);
      debugPrint(
        'OpenSubtitles ${name.title} S${name.season}E${name.episode} '
        'hash=$hash hits=${hits.length} orig=${origHit?.release} ko=${koHit?.release}',
      );

      List<BilingualCue>? koCues;
      if (koHit != null) {
        _set(JobStage.preparing, '한국어 자막 내려받는 중 (OpenSubtitles)…');
        koCues = parseWebVtt(await os.download(koHit.fileId));
        if (!fitsDuration(koCues, info.duration)) {
          debugPrint(
            'OpenSubtitles korean rejected: length does not fit the video',
          );
          koCues = null;
        }
        // 옛 인코딩(CP949) 자막은 글자가 깨지므로 쓰지 않고 AI 번역에 맡긴다
        if (koCues != null &&
            koCues.where((c) => isBrokenKorean(c.original)).length >
                koCues.length * 0.1) {
          debugPrint('OpenSubtitles korean rejected: broken encoding');
          koCues = null;
        }
      }
      if (origHit == null) {
        _onlineKorean = koCues;
        return false;
      }
      _set(JobStage.preparing, '자막 내려받는 중 (OpenSubtitles)…');
      var c = parseWebVtt(await os.download(origHit.fileId));
      if (c.isEmpty) return false;
      if (!fitsDuration(c, info.duration)) {
        // 다른 작품/편집본 자막: 싱크로 맞출 수 없으니 음성 인식을 쓴다
        notice = '인터넷 자막이 영상 길이와 맞지 않아 음성 인식을 사용합니다';
        _onlineKorean = koCues;
        if (!_disposed) notifyListeners();
        return false;
      }
      // 실제 음성과 같은 내용인지
      if (!await _speechMatches(c, lang: lang.split('-').first)) {
        _onlineKorean = null; // 같은 검색에서 나온 한국어 자막도 믿을 수 없다
        return false;
      }
      _onlineOriginal = true;
      _onlineKorean = koCues;
      if (koCues != null) {
        c = mergeTranslation(c, koCues);
      }
      sourceLang = lang.split('-').first;
      _release = origHit.release;
      originalFrom = origHit.hashMatch
          ? 'OpenSubtitles · 파일 일치'
          : _fromNameSearch;
      _setCues(c);
      return true;
    } on Exception catch (e) {
      debugPrint('OpenSubtitles failed: $e');
      notice = '인터넷 자막을 가져오지 못했습니다 ($e)';
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  // ---- 음성 인식 (재생 위치부터 조각 단위) ----

  void _addCovered(int a, int b) {
    if (b <= a) return;
    _covered
      ..add((a, b))
      ..sort((x, y) => x.$1.compareTo(y.$1));
    final merged = <(int, int)>[];
    for (final c in _covered) {
      if (merged.isNotEmpty && c.$1 <= merged.last.$2 + 50) {
        final l = merged.removeLast();
        merged.add((l.$1, c.$2 > l.$2 ? c.$2 : l.$2));
      } else {
        merged.add(c);
      }
    }
    _covered
      ..clear()
      ..addAll(merged);
  }

  bool _inCovered(int ms) => _covered.any((c) => ms >= c.$1 && ms < c.$2);

  int get _coveredMs => _covered.fold(0, (a, c) => a + c.$2 - c.$1);

  /// [from] 이후 처음으로 인식이 안 된 위치. 끝까지 다 됐으면 null.
  int? _firstGap(int from, int total) {
    var t = from;
    for (final (a, b) in _covered) {
      if (b <= t) continue;
      if (a > t) break;
      t = b;
    }
    return t < total - 500 ? t : null;
  }

  int _nextCoveredStart(int after, int total) {
    var n = total;
    for (final (a, _) in _covered) {
      if (a > after && a < n) n = a;
    }
    return n;
  }

  /// 재생 위치에 맞춰 큐를 시간순으로 끼워 넣는다
  void _insertCue(BilingualCue c) {
    var lo = 0, hi = cues.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cues[mid].start <= c.start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _setCues([...cues.take(lo), c, ...cues.skip(lo)]);
  }

  /// 지금 인식 중인 구간과 경과 시간 (whisper는 진행률을 드물게만 알려 준다)
  String? _activeChunk;
  final _chunkWatch = Stopwatch();

  String _sttStatus(double fraction) {
    final t = _translatedCount;
    final active = _activeChunk;
    final chunk = active == null
        ? ''
        : ' · $active 인식 중 ${_chunkWatch.elapsed.inSeconds}초';
    final trans = settings.hasClaudeKey && sourceLang != 'ko'
        ? ' · 번역 $t줄'
        : '';
    return '음성 인식 ${(fraction * 100).toStringAsFixed(0)}% · ${cues.length}줄$trans$chunk';
  }

  /// 음성 인식이 마지막으로 믿은 언어
  String? _spokenLang;

  Future<void> _speechToText() async {
    if (!canTranscribe) {
      originalFrom = '자막 없음';
      notice = '이 기기에서는 아직 음성 인식을 지원하지 않습니다 (인터넷 자막만 사용)';
      return;
    }
    final model = await ensureWhisperModel(
      settings.whisperModel,
      onProgress: (p) => _set(
        JobStage.downloadingModel,
        '음성 인식 모델 내려받는 중 (처음 한 번) ${(p * 100).toStringAsFixed(0)}%',
        p,
      ),
    );
    final vad = await ensureVadModel();

    final (input, headers, duration) = switch (source) {
      LocalFileSource(:final path) => (
        path,
        const <String, String>{},
        (await _probe(path)).duration,
      ),
      YoutubeSource(:final media) => (
        media.audioUrl ?? media.videoUrl,
        media.httpHeaders,
        media.duration,
      ),
    };
    // 길이를 모르면 넉넉히 잡고, 소리가 더 없으면 끝낸다
    final total = duration != null && duration > Duration.zero
        ? duration.inMilliseconds
        : const Duration(hours: 6).inMilliseconds;

    originalFrom = fromStt;
    final tmp = await Directory.systemTemp.createTemp('transcue_');
    try {
      int? lastEnd;
      _set(
        JobStage.transcribing,
        _sttStatus(_coveredMs / total),
        _coveredMs / total,
      );
      while (!_disposed) {
        // 재생 위치(2초 앞)부터 비어 있는 곳 → 없으면 처음부터 비어 있는 곳
        final ph = (playhead().inMilliseconds - 2000).clamp(0, total);
        final start = _firstGap(ph, total) ?? _firstGap(0, total);
        if (start == null) break;
        final jumped = lastEnd == null || (start - lastEnd).abs() > 1000;
        final stop = _nextCoveredStart(start, total);
        final hardEnd = [
          start + (jumped ? _firstChunkMs : _chunkMs),
          stop,
          total,
        ].reduce((a, b) => a < b ? a : b);
        final readEnd = hardEnd >= stop
            ? hardEnd
            : (hardEnd + _tailMs).clamp(0, total);

        debugPrint(
          '[stt] chunk ${start ~/ 1000}s → ${hardEnd ~/ 1000}s '
          '(playhead ${playhead().inSeconds}s)',
        );
        var lastCueEnd = hardEnd;
        var ended = false;
        _activeChunk =
            '${formatPosition(Duration(milliseconds: start))}'
            '~${formatPosition(Duration(milliseconds: hardEnd))}';
        _chunkWatch
          ..reset()
          ..start();
        final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          _set(
            JobStage.transcribing,
            _sttStatus(progress ?? _coveredMs / total),
            progress,
          );
        });
        try {
          await for (final ev in transcribeRange(
            input: input,
            httpHeaders: headers,
            start: Duration(milliseconds: start),
            length: Duration(milliseconds: readEnd - start),
            model: model,
            vadModel: vad,
            // 영상 안에서 언어가 바뀔 수 있으므로 구간마다 새로 감지한다
            language: 'auto',
            fallbackLanguage: _spokenLang,
            tmp: tmp,
          )) {
            switch (ev) {
              case SttEnd():
                ended = true;
              case SttCue(:final cue):
                final c = shiftCues([cue], Duration(milliseconds: start)).first;
                final s = c.start.inMilliseconds;
                // 다음 조각에 속하는 줄, 이미 인식한 구간의 줄은 버린다
                if (s >= hardEnd || _inCovered(s)) continue;
                final e = c.end.inMilliseconds;
                if (e > lastCueEnd) lastCueEnd = e > readEnd ? readEnd : e;
                _insertCue(c);
                _kickTranslation(); // 구간이 끝나길 기다리지 않고 바로 번역
              case SttProgress(:final fraction):
                final p = (_coveredMs + fraction * (hardEnd - start)) / total;
                _set(JobStage.transcribing, _sttStatus(p), p);
              case SttLanguage(:final code):
                debugPrint('[stt] language $code');
                _spokenLang = code;
                sourceLang = mergeSpokenLang(sourceLang, code);
            }
          }
        } finally {
          ticker.cancel();
          _activeChunk = null;
        }
        if (ended) {
          // 소리가 끝남. 재생 위치부터 시작했다면 앞부분이 남아 있으므로 계속한다
          _addCovered(start, total);
          continue;
        }
        // 마지막 문장이 조각 끝을 넘었으면 그 문장 끝까지를 인식된 구간으로
        _addCovered(start, lastCueEnd);
        lastEnd = lastCueEnd;
        final p = _coveredMs / total;
        _set(JobStage.transcribing, _sttStatus(p), p);
        await _saveCache(); // 중간 저장
        _kickTranslation(); // 이 조각을 바로 번역 (다음 조각 인식과 동시에)
      }
    } finally {
      await deleteTempDir(tmp);
    }
  }

  // ---- 번역 (재생 위치 근처부터, 음성 인식과 동시에) ----

  Future<void>? _loop;

  /// 이번 실행에서 번역을 시도한 줄 (누락돼도 무한 반복하지 않도록)
  final _attempted = <String>{};

  String _key(BilingualCue c) => '${c.start.inMilliseconds}|${c.original}';

  /// 번역이 필요한 줄: 번역이 없거나 사용자가 다시 번역을 요청한 줄
  bool _wantsTranslation(BilingualCue c) =>
      !isMostlyKorean(c.original) &&
      (c.translation == null || (c.provisional && settings.hasClaudeKey));

  int get _translatedCount =>
      cues.where((c) => c.translation != null && !_wantsTranslation(c)).length;

  List<BilingualCue> _pendingByPriority() {
    final ph = playhead().inMilliseconds - 5000;
    final p = [
      for (final c in cues)
        if (_wantsTranslation(c) && !_attempted.contains(_key(c))) c,
    ];
    return [
      ...p.where((c) => c.end.inMilliseconds >= ph),
      ...p.where((c) => c.end.inMilliseconds < ph),
    ];
  }

  bool get _needsTranslation =>
      sourceLang != 'ko' && _pendingByPriority().isNotEmpty;

  /// 번역 루프가 없으면 시작한다. 음성 인식 조각이 끝날 때마다 불린다.
  void _kickTranslation() {
    kickVocab(); // 학습 단어도 같은 시점에 (켜져 있을 때만)
    if (_dbg('DUALCUE_NO_TRANSLATE')) return;
    if (_loop != null || !_needsTranslation) return;
    if (!settings.hasClaudeKey) {
      notice = '설정(⚙)에서 Claude API 키를 등록하면 한국어 번역이 표시됩니다';
      if (!_disposed) notifyListeners();
      return;
    }
    _loop = _translateLoop().whenComplete(() => _loop = null);
  }

  /// 한국어가 없는 줄을 모두 번역할 때까지 기다린다.
  /// 설정에서 API 키를 넣은 뒤 다시 불러도 된다.
  Future<void> translateRemaining() async {
    _attempted.clear(); // 앞에서 누락된 줄도 다시 시도
    notice = null;
    while (!_disposed) {
      _kickTranslation();
      final l = _loop;
      if (l == null) break;
      await l;
      if (notice != null) break;
      if (_pendingByPriority().isEmpty) break;
    }
    if (!_disposed && stage != JobStage.failed && _sttDone) {
      _set(JobStage.done, _summary());
    }
  }

  /// 번역만 다시 할 수 있는 상태인지. 작업 중에는 자막이 계속 바뀌므로 끝난 뒤에만.
  bool get canRetranslate =>
      stage == JobStage.done &&
      sourceLang != 'ko' &&
      cues.isNotEmpty &&
      settings.hasClaudeKey;

  /// 원문은 그대로 두고 AI로 다시 번역한다. 새 번역이 온 줄부터 바뀐다.
  Future<void> retranslate() async {
    if (!canRetranslate) return;
    _fromCache = false;
    _setCues([
      for (final c in cues)
        c.translation == null
            ? c
            : c.withTranslation(c.translation, provisional: true),
    ]);
    await translateRemaining();
  }

  Future<void> _translateLoop() async {
    final tr = ClaudeTranslator(
      apiKey: settings.claudeApiKey,
      model: settings.claudeModel,
    );
    try {
      while (!_disposed) {
        final pending = _pendingByPriority();
        if (pending.isEmpty) return;
        final near = (pending.first.start - playhead()).inSeconds.abs() < 30;
        final batch = pending.take(near ? _nearBatchSize : _batchSize).toList();

        final firstIdx = cues.indexWhere((c) => identical(c, batch.first));
        final req = TranslationBatch(
          sourceLang: sourceLang ?? 'auto',
          context: [
            for (
              var i = (firstIdx - _contextSize).clamp(0, firstIdx);
              i < firstIdx;
              i++
            )
              (cues[i].original, cues[i].translation),
          ],
          items: {for (var i = 0; i < batch.length; i++) i: batch[i].original},
        );
        if (_sttDone) {
          final done = _translatedCount;
          _set(
            JobStage.translating,
            '번역 중 $done/${cues.length} · ${settings.claudeModel.label}',
            done / cues.length,
          );
        }
        final out = await tr.translate(req);
        // 기다리는 동안 음성 인식이 줄을 끼워 넣었을 수 있어 위치가 아니라 내용으로 찾는다
        final byKey = <String, String>{
          for (var i = 0; i < batch.length; i++)
            if ((out[i] ?? '').isNotEmpty) _key(batch[i]): out[i]!,
        };
        _attempted.addAll(
          batch.map(_key),
        ); // 누락된 줄은 다음 translateRemaining 때 재시도
        _setCues([
          for (final c in cues)
            if (byKey[_key(c)] case final t?) c.withTranslation(t) else c,
        ]);
        if (stage == JobStage.transcribing) {
          // 인식 중이면 상태 줄의 "번역 N줄"만 갱신
          _set(JobStage.transcribing, _sttStatus(progress ?? 0), progress);
        }
        await _saveCache();
      }
    } on TranslateException catch (e) {
      notice = '번역 중단: $e';
      if (!_disposed) notifyListeners();
    }
  }

  // ---- 학습 단어 (켜져 있을 때만, 재생 위치 근처부터) ----

  Future<void>? _vocabLoop;
  final _vocabAttempted = <String>{};

  List<BilingualCue> _vocabPending() {
    final ph = playhead().inMilliseconds - 5000;
    final p = [
      for (final c in cues)
        if (c.words == null && !_vocabAttempted.contains(_key(c))) c,
    ];
    return [
      ...p.where((c) => c.end.inMilliseconds >= ph),
      ...p.where((c) => c.end.inMilliseconds < ph),
    ];
  }

  /// 학습 단어 만들기를 시작한다 (설정에서 켰을 때도 호출).
  void kickVocab() {
    if (!settings.showVocab || sourceLang == 'ko') return;
    if (_dbg('DUALCUE_NO_TRANSLATE')) return;
    if (_vocabLoop != null || _vocabPending().isEmpty) return;
    if (!settings.hasClaudeKey) {
      notice = '설정(⚙)에서 Claude API 키를 등록하면 학습 단어가 표시됩니다';
      if (!_disposed) notifyListeners();
      return;
    }
    _vocabLoop = _vocabRun().whenComplete(() {
      _vocabLoop = null;
      if (!_disposed && stage == JobStage.done) _set(JobStage.done, _summary());
    });
  }

  Future<void> _vocabRun() async {
    final tr = ClaudeTranslator(
      apiKey: settings.claudeApiKey,
      model: settings.claudeModel,
    );
    try {
      while (!_disposed && settings.showVocab) {
        final pending = _vocabPending();
        if (pending.isEmpty) return;
        final near = (pending.first.start - playhead()).inSeconds.abs() < 30;
        final batch = pending.take(near ? _nearBatchSize : _batchSize).toList();
        final out = await tr.extractVocab(
          VocabBatch(
            sourceLang: sourceLang ?? 'auto',
            items: {
              for (var i = 0; i < batch.length; i++) i: batch[i].original,
            },
          ),
          settings.vocabLevel,
        );
        final byKey = <String, List<VocabItem>>{
          for (var i = 0; i < batch.length; i++)
            if (out[i] != null) _key(batch[i]): out[i]!,
        };
        _vocabAttempted.addAll(batch.map(_key));
        _setCues([
          for (final c in cues)
            if (byKey[_key(c)] case final w?) c.withWords(w) else c,
        ]);
        await _saveCache();
      }
    } on TranslateException catch (e) {
      notice = '학습 단어 생성 중단: $e';
      if (!_disposed) notifyListeners();
    }
  }

  /// 학습 수준을 바꾸면 지금 영상의 단어를 새로 만든다
  void resetVocab() {
    _vocabAttempted.clear();
    _setCues([for (final c in cues) c.words == null ? c : c.withWords(null)]);
    kickVocab();
  }
}
