import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../online/opensubtitles.dart';
import '../player/resume.dart' show formatPosition;
import '../player/tv.dart' show tvDevice;
import '../settings/app_settings.dart';
import '../source/youtube_backend.dart';
import '../source/yt_dlp.dart';
import '../subtitle/bilingual_cue.dart';
import '../subtitle/webvtt.dart';
import '../translate/translators.dart';
import 'audio_download.dart';
import 'media_tools.dart';
import 'speech_check.dart';
import 'stt_engine.dart';
import 'subsync.dart';
import 'text_sync.dart';
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

  /// 데스크톱 yt-dlp 또는 Android 순수 Dart
  final YoutubeBackend ytDlp;
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
/// 저장된 자막·번역 (영상마다 파일 하나)
Future<Directory> subtitleCacheDir() async =>
    Directory('${(await AppSettings.supportDir()).path}/cache');

/// 저장된 자막 개수와 크기(바이트)
Future<({int files, int bytes})> subtitleCacheSize() async {
  final dir = await subtitleCacheDir();
  if (!await dir.exists()) return (files: 0, bytes: 0);
  var files = 0, bytes = 0;
  await for (final e in dir.list()) {
    if (e is File && e.path.endsWith('.json')) {
      files++;
      bytes += await e.length();
    }
  }
  return (files: files, bytes: bytes);
}

/// 저장된 자막·번역을 모두 지운다. 지운 개수.
Future<int> clearSubtitleCache() async {
  final dir = await subtitleCacheDir();
  if (!await dir.exists()) return 0;
  var n = 0;
  await for (final e in dir.list()) {
    if (e is File && e.path.endsWith('.json')) {
      try {
        await e.delete();
        n++;
      } on FileSystemException {
        // 쓰는 중인 파일 등은 건너뛴다
      }
    }
  }
  return n;
}

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
///       → 한국어가 없는 줄은 AI 번역. STT/번역 결과는 생기는 대로 [cues]에 반영.
/// 구간마다 감지한 언어를 합친다. 영상 안에서 언어가 바뀌면 'auto'가 된다.
String mergeSpokenLang(String? current, String detected) =>
    current == null || current == detected ? detected : 'auto';

/// 재생 위치가 [moved]만큼 바뀌는 동안 [elapsed]가 흘렀을 때, 사용자가 위치를 옮긴 것인지.
/// 보통 재생(빠르게 재생 포함)·일시정지는 3초 넘게 차이 나지 않는다.
bool isSeek(Duration moved, Duration elapsed) =>
    (moved - elapsed).abs() > const Duration(seconds: 3);

/// 인식된 구간 [covered]에서 자막([cues])이 한 줄도 없이 [maxEmptyMs]보다 길게 이어지는 곳을
/// 뺀다 (그곳은 다시 인식한다). 앞뒤 자막이 있는 곳까지는 남긴다.
List<(int, int)> trimEmptyCovered(
  List<(int, int)> covered,
  List<BilingualCue> cues,
  int maxEmptyMs,
) {
  final sorted = [...cues]..sort((x, y) => x.start.compareTo(y.start));
  final out = <(int, int)>[];
  for (final (a, b) in covered) {
    var segStart = a, pos = a;
    for (final c in sorted) {
      final s = c.start.inMilliseconds, e = c.end.inMilliseconds;
      if (e <= a) continue;
      if (s >= b) break;
      if (s - pos > maxEmptyMs) {
        if (pos > segStart) out.add((segStart, pos));
        segStart = s;
      }
      if (e > pos) pos = e > b ? b : e;
    }
    if (b - pos > maxEmptyMs) {
      if (pos > segStart) out.add((segStart, pos));
    } else {
      out.add((segStart, b));
    }
  }
  return out;
}

/// 시작할 때 싱크를 재는 방법: 한 번에 받아 적는 길이, 근거가 모자랄 때 다음 구간으로
/// 옮겨 다시 재는 횟수, Android에서 쓸 스레드 수(null = 빠른 코어 전부).
///
/// Android는 받아 적기가 느려(태블릿: 30초에 30~60초) 짧게 한 번만 잰다. 30초면 근거가
/// 40~80개쯤 나와 판정(최소 12개)에는 충분하다. TV는 CPU가 약해 재생이 끊기지 않게
/// 스레드를 2개만 쓴다 (Chromecast는 코어 4개가 모두 같은 속도라 기본값이 4개 전부).
({Duration window, int tries, int? threads}) startSyncPlan({
  required bool android,
  required bool tv,
}) => android
    ? (window: const Duration(seconds: 30), tries: 1, threads: tv ? 2 : null)
    : (window: const Duration(seconds: 60), tries: 3, threads: null);

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
  /// (20초는 인식이 끝날 때까지 자막 없이 영상이 한참 지나간다)
  static const _firstChunkMs = 10000;
  static const _chunkMs = 30000;

  /// 조각 끝에서 문장이 잘리지 않도록 더 읽는 시간
  static const _tailMs = 4000;

  /// Android에서 재생 위치보다 이만큼 넘게 앞은 미리 인식하지 않는다
  static const _androidAheadMs = 3 * 60 * 1000;

  /// 이보다 짧은 미인식 틈은 인식하지 않고 채운다 (1초 미만 소리는 '영상 끝'으로 읽힌다)
  static const _minGapMs = 2000;

  /// 소리가 없다고 나온 조각이 영상 끝에서 이만큼 안이면 영상 끝으로 본다
  static const _endSlackMs = 5000;

  /// 저장된 인식 구간 중 자막이 한 줄도 없이 이만큼 넘게 이어지는 곳은 다시 인식한다
  /// (예전 버전이 짧은 조각을 '영상 끝'으로 잘못 보고 끝까지 인식된 것으로 저장한 것을 고친다)
  static const _emptyCoveredMs = 3 * 60 * 1000;

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
    _seekWatch?.cancel();
    super.dispose();
  }

  // ---- 재생 위치 이동 감지 ----

  Timer? _seekWatch;

  /// 음성 인식 중인 조각이 이동에 반응하도록 등록하는 콜백
  void Function(Duration)? _onSeek;

  /// 사용자가 재생 위치를 옮기면 그 위치부터 인식·번역하도록 알린다
  void _watchSeek() {
    var last = playhead();
    final wall = Stopwatch()..start();
    _seekWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_disposed) return;
      final ph = playhead();
      final seeked = isSeek(ph - last, wall.elapsed);
      last = ph;
      wall.reset();
      if (!seeked) return;
      debugPrint('[seek] playhead moved to ${ph.inSeconds}s');
      _onSeek?.call(ph);
      // 번역이 이미 돌고 있을 때만 (받은 자막을 음성과 대조하는 중에는 번역하지 않는다)
      if (_loop != null) _kickTranslation();
    });
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
    final dir = await subtitleCacheDir();
    await dir.create(recursive: true);
    return File('${dir.path}/${sha1.convert(utf8.encode(key))}.json');
  }

  /// 개발용 스위치 (실기기 검증 시 저장 결과·API 비용에 영향 없게)
  static bool _dbg(String k) => kDebugMode && Platform.environment[k] == '1';

  /// 진행 중인 저장. 번역·학습 단어·읽는 법·음성 인식이 따로 저장을 부르므로,
  /// 쓰는 중에 또 부르면 같은 파일에 동시에 쓰지 않고 끝난 뒤 한 번 더 쓴다.
  Future<void>? _saving;
  bool _saveAgain = false;

  Future<void> _saveCache() {
    if (_saving != null) {
      _saveAgain = true;
      return _saving!;
    }
    return _saving = () async {
      try {
        do {
          _saveAgain = false;
          await _writeCache();
        } while (_saveAgain);
      } finally {
        _saving = null;
      }
    }();
  }

  Future<void> _writeCache() async {
    if (_dbg('DUALCUE_NO_CACHE')) return;
    // 중단된 작업은 저장하지 않는다. 일부만 인식한 결과가 완료로 기록되거나,
    // 다시 만들기를 시작한 새 작업의 결과를 덮어쓰게 된다.
    if (_disposed) return;
    if (cues.isEmpty && _covered.isEmpty) return;
    final f = await _cacheFile();
    // 임시 파일에 다 쓴 뒤 바꿔 넣는다 (쓰는 도중 앱이 꺼져도 저장본이 깨지지 않게)
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({
        'v': _cacheVersion,
        'lang': sourceLang,
        'from': originalFrom,
        'koFrom': ?koreanFrom,
        'aiLines': _aiLines,
        'osTried': _osTried,
        'sync': ?syncInfo,
        'release': ?_release,
        'speech': ?speechMatch,
        // 음성 인식 중간 저장: 다시 열면 남은 구간만 이어서 인식
        'complete': _sttDone || originalFrom != fromStt,
        'spoken': ?_spokenLang,
        'guess': ?_titleGuess,
        if (originalFrom == fromStt)
          'covered': [
            for (final (a, b) in _covered) [a, b],
          ],
        'cues': [for (final c in cues) c.toJson()],
      }),
      flush: true,
    );
    await tmp.rename(f.path);
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
      koreanFrom = j['koFrom'] as String?;
      _aiLines = (j['aiLines'] as num?)?.toInt() ?? 0;
      debugPrint('[cache] saved from=$originalFrom lang=$sourceLang');
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
      // 예전에 음성과 다른 언어의 YouTube 자막(사람이 단 첫 자막 등)을 원어로 저장한 결과:
      // 지금 알아낸 음성 언어와 다르거나 음성 언어를 모르면 버리고 다시 받거나 음성 인식으로 만든다
      // (음성 언어를 YouTube가 알려 주지 않아 음성 인식으로 알아내 고른 자막은 그 언어로 확인)
      final spokenSaved = j['spoken'] as String? ?? j['guess'] as String?;
      _titleGuess = j['spoken'] == null ? j['guess'] as String? : null;
      _spokenLang ??= j['spoken'] as String?;
      if (source case YoutubeSource(:final media)
          when originalFrom.startsWith('YouTube') &&
              (media.language ?? spokenSaved) != sourceLang) {
        debugPrint(
          'cache rejected: YouTube captions in $sourceLang, speech is ${media.language}',
        );
        return false;
      }
      _complete = j['complete'] != false;
      final saved = [
        for (final c in (j['cues'] as List).cast<Map<String, dynamic>>())
          _repairSaved(BilingualCue.fromJson(c)),
      ];
      // 예전에 저장한 음성 인식 자막도 말이 끝나면 닫히게
      if (originalFrom == fromStt) {
        for (var i = 0; i < saved.length; i++) {
          saved[i] = trimLingeringEnd(saved[i]);
        }
      }
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
      // 자막 없이 길게 '인식됨'으로 저장된 곳은 다시 인식한다
      if (originalFrom == fromStt && _covered.isNotEmpty) {
        final trimmed = trimEmptyCovered(_covered, saved, _emptyCoveredMs);
        if (!listEquals(trimmed, _covered)) {
          debugPrint('[cache] re-recognize empty ranges: $_covered → $trimmed');
          _covered
            ..clear()
            ..addAll(trimmed);
          _complete = false;
        }
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
    _watchSeek();
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
      // 저장된 음성 인식 결과라도 그 언어의 YouTube 자막이 있으면 그것을 쓴다
      if (cached &&
          originalFrom == fromStt &&
          refresh != JobRefresh.speech &&
          await _switchToYoutubeCaptions(sourceLang)) {
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
      // YouTube 자막은 번역과 동시에 음성과 대조해 밀린 만큼 옮긴다
      if (_needsStartSync) unawaited(_startSync());
      await translateRemaining();
      if (stage != JobStage.failed) {
        _set(JobStage.done, _summary());
      }
    } catch (e, st) {
      debugPrint('SubtitleJob failed: $e\n$st');
      _set(JobStage.failed, '자막 생성 실패: $e');
    }
  }

  /// 원문 자막의 출처 (음성 인식이면 어떤 엔진인지)
  String get originalLabel => originalFrom == fromStt
      ? settings.englishStt == EnglishStt.parakeet && sourceLang == 'en'
            ? '음성 인식 (Parakeet)'
            : '음성 인식 (whisper)'
      : originalFrom;

  /// 번역의 출처: 한국어 자막 + AI로 번역한 줄
  String get translationLabel {
    final ai = settings.provider.label;
    return switch ((koreanFrom, _aiLines)) {
      (null, _) => ai,
      (final k?, 0) => k,
      (final k?, final n) => '$k + $ai $n줄',
    };
  }

  String _summary() {
    final n = cues.length;
    final t = _translatedCount;
    final trans = sourceLang == 'ko'
        ? ''
        : t == 0
        ? ''
        : ' · 번역 $translationLabel${t == n ? '' : ' ($t/$n)'}';
    final sync = syncInfo == null ? '' : ' · $syncInfo';
    final speech = speechMatch == null
        ? ''
        : speechMatch! < 0
        ? ' · 음성 대조 불가'
        : ' · 음성 대조 ${(speechMatch! * 100).round()}% 일치';
    final w = settings.showVocab && sourceLang != 'ko'
        ? ' · 단어 ${cues.where((c) => c.words != null).length}/$n'
        : '';
    return '자막 $n줄 · 원문 $originalLabel${_fromCache ? ' (저장됨)' : ''}$trans$w$sync$speech';
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
              koreanFrom = '내장 한국어 자막';
            }
            sourceLang = orig.language;
            originalFrom = '내장 자막';
            _setCues(c);
            return true;
          }
        }
        final found = await _loadOnlineSubtitles(path, info);
        // 원어 자막은 없고 내장 한국어 자막만 있으면 음성 인식 원문에 붙인다 (AI 번역 대신)
        final embeddedKo = info.koreanTrack;
        if (!found &&
            _onlineKorean == null &&
            embeddedKo != null &&
            osLang(info.audioLanguage) != 'ko') {
          final k = await extractEmbeddedSubtitle(path, embeddedKo);
          if (k.isNotEmpty) {
            debugPrint('[captions] embedded Korean only: ${k.length} lines');
            _onlineKorean = k;
            koreanFrom = '내장 한국어 자막';
            _koreanTimed = true; // 같은 파일에 든 자막이라 시간이 맞는다
          }
        }
        return found;

      case YoutubeSource(:final media, :final ytDlp):
        final orig = media.original;
        if (orig == null) {
          // 음성 언어를 모르면 제목 글자로 짐작해 그 언어 자막을 바로 보여 주고,
          // 시작 싱크에서 음성 인식으로 언어를 확인한다 (음성 인식 모델을 받는 동안 자막이 없지 않게)
          if (await _showGuessedCaptions(media, ytDlp)) return true;
          // 원어 자막은 없어도 한국어 자막이 있으면 음성 인식 원문에 붙인다
          final ko = media.korean;
          if (ko != null) unawaited(_fetchKoreanForStt(media, ytDlp, ko));
          return false;
        }
        var c = parseWebVtt(await ytDlp.fetchCaption(media, orig));
        if (c.isEmpty) return false;
        sourceLang = media.language ?? orig.lang.split('-').first;
        originalFrom = orig.auto ? 'YouTube 자동 자막' : 'YouTube 자막';
        _setCues(c);
        final ko = media.korean;
        // 한국어 자막은 뒤에서 받는다. 받는 동안 원문을 먼저 보여 주고 AI 번역도 시작한다.
        // (yt-dlp는 한 번에 5~10초, 429면 다시 시도까지 30초 넘게 걸려 그동안 번역이 멈춰 있었다)
        // 받으면 그 번역으로 바꾸고, 그 뒤로는 AI 번역이 필요 없다.
        if (ko != null) unawaited(_fetchYoutubeKorean(media, ytDlp, ko));
        return true;
    }
  }

  bool _koreanForSttTried = false;

  /// 제목으로 짐작한 언어의 자막을 보여 주는 중 (음성으로 아직 확인 안 함)
  String? _titleGuess;

  Future<bool> _showGuessedCaptions(
    YoutubeMedia media,
    YoutubeBackend ytDlp,
  ) async {
    final guess = guessLanguageFromTitle(media.title);
    if (guess == null) return false;
    final track = captionForLanguage(media.captionTracks, guess);
    if (track == null) return false;
    try {
      final c = parseWebVtt(await ytDlp.fetchCaption(media, track));
      if (c.isEmpty || _disposed) return false;
      debugPrint(
        '[captions] title guess $guess → YouTube ${track.lang} (${c.length} lines)',
      );
      _titleGuess = guess;
      sourceLang = guess;
      originalFrom = track.auto ? 'YouTube 자동 자막' : 'YouTube 자막';
      _setCues(c);
      final ko =
          media.korean ??
          captionForLanguage(
            media.captionTracks.where((t) => !t.auto).toList(),
            'ko',
          );
      if (guess != 'ko' && ko != null) {
        unawaited(_fetchYoutubeKorean(media, ytDlp, ko));
      }
      return true;
    } on Exception catch (e) {
      debugPrint('[captions] title guess $guess failed: $e');
      return false;
    }
  }

  /// 시작 싱크에서 알아낸 음성 언어로 제목 짐작을 확인한다
  Future<void> _confirmTitleGuess(String spoken) async {
    final guess = _titleGuess;
    if (guess == null) return;
    _titleGuess = null;
    final lang = spoken.split('-').first;
    _spokenLang = lang;
    if (lang == guess) {
      debugPrint('[captions] title guess $guess confirmed by speech');
      await _saveCache();
      return;
    }
    // 짐작이 틀렸다: 음성 언어의 자막으로 바꾸고, 없으면 음성 인식을 권한다
    debugPrint('[captions] title guess $guess wrong: speech is $lang');
    _onlineKorean = null;
    koreanFrom = null;
    if (await _switchToYoutubeCaptions(lang)) return;
    notice = '자막 언어가 음성과 다릅니다. 🎤 자막 자동 생성으로 음성 인식 자막을 만드세요';
    if (!_disposed) notifyListeners();
  }

  /// 음성 언어의 자막은 없지만 사람이 만든 한국어 자막이 있으면 음성 인식 원문에 붙인다
  void _koreanForSttOnce(String? lang) {
    if (_koreanForSttTried || lang == null || _onlineKorean != null) return;
    if (source case YoutubeSource(
      :final media,
      :final ytDlp,
    ) when media.original == null && media.korean == null) {
      if (lang.split('-').first == 'ko') return;
      _koreanForSttTried = true;
      final ko = captionForLanguage(
        media.captionTracks.where((t) => !t.auto).toList(),
        'ko',
      );
      if (ko != null) unawaited(_fetchKoreanForStt(media, ytDlp, ko));
    }
  }

  /// 한 번만 시도한다 (받기에 실패하면 음성 인식을 계속한다)
  bool _captionSwitchTried = false;

  /// 원어 자막을 못 고른 YouTube 영상에서 음성 언어 [lang]의 자막 트랙
  CaptionTrack? _youtubeCaptionFor(String? lang) {
    if (_captionSwitchTried || lang == null) return null;
    if (source case YoutubeSource(:final media) when media.original == null) {
      return captionForLanguage(media.captionTracks, lang.split('-').first);
    }
    return null;
  }

  /// YouTube에 음성 언어의 자막이 있으면 음성 인식 대신 그것을 보여 준다. 바꿨으면 true.
  /// (음성 언어를 몰라 원어 자막을 못 고른 영상: 자막이 여러 언어로 있는 TED 등)
  Future<bool> _switchToYoutubeCaptions(String? lang) async {
    final track = _youtubeCaptionFor(lang);
    if (track == null) {
      _koreanForSttOnce(lang);
      return false;
    }
    _captionSwitchTried = true;
    final (media, ytDlp) = switch (source) {
      YoutubeSource(:final media, :final ytDlp) => (media, ytDlp),
      _ => throw StateError('not youtube'),
    };
    try {
      final c = parseWebVtt(await ytDlp.fetchCaption(media, track));
      if (c.isEmpty || _disposed) return false;
      debugPrint(
        '[captions] spoken $lang → YouTube ${track.lang} (${c.length} lines)',
      );
      sourceLang = lang!.split('-').first;
      originalFrom = track.auto ? 'YouTube 자동 자막' : 'YouTube 자막';
      _fromCache = false;
      _covered.clear();
      // 음성 인식에 붙이려고 받아 둔 한국어 자막이 있으면 그대로 쓰고, 없으면 받는다
      final known = _onlineKorean;
      _setCues(known == null ? c : mergeTranslation(c, known));
      final ko =
          media.korean ??
          captionForLanguage(
            media.captionTracks.where((t) => !t.auto).toList(),
            'ko',
          );
      if (known == null && sourceLang != 'ko' && ko != null) {
        unawaited(_fetchYoutubeKorean(media, ytDlp, ko));
      }
      await _saveCache();
      return true;
    } on Exception catch (e) {
      debugPrint('[captions] YouTube ${track.lang} failed: $e');
      return false;
    }
  }

  static String _youtubeKoreanLabel(CaptionTrack ko) =>
      ko.auto ? 'YouTube 자동 번역' : 'YouTube 한국어 자막';

  /// 한국어 자막의 출처 (예: 'YouTube 한국어 자막'). 없으면 null (AI 번역만).
  String? koreanFrom;

  /// AI로 번역한 줄 수
  int _aiLines = 0;

  /// 받는 중인 한국어 자막 수 (받는 동안은 'API 키를 넣으라'는 안내를 미룬다)
  int _koreanPending = 0;

  /// [_onlineKorean]의 시간이 이 영상과 맞는지 (내장·YouTube 한국어 자막).
  /// 인터넷(OpenSubtitles) 한국어 자막은 다른 판본일 수 있어 음성 인식이 끝난 뒤 싱크를 맞추고 붙인다.
  bool _koreanTimed = false;

  /// 원어 자막 없이 음성 인식할 YouTube 영상의 한국어 자막을 받아 둔다.
  /// 이미 인식된 줄에는 바로 붙이고, 앞으로 인식되는 줄에는 [_insertCue]가 붙인다.
  Future<void> _fetchKoreanForStt(
    YoutubeMedia media,
    YoutubeBackend ytDlp,
    CaptionTrack ko,
  ) async {
    _koreanPending++;
    try {
      final k = parseWebVtt(await ytDlp.fetchCaption(media, ko));
      if (_disposed || k.isEmpty || originalFrom != fromStt) return;
      debugPrint('[captions] Korean for speech recognition: ${k.length} lines');
      _onlineKorean = k;
      _koreanTimed = true;
      koreanFrom = _youtubeKoreanLabel(ko);
      _setCues(mergeTranslation(cues, k));
      await _saveCache();
    } on Exception catch (e) {
      debugPrint('YouTube Korean captions failed: $e');
    } finally {
      // 다 받았거나 실패했으면 남은 줄의 번역(또는 API 키 안내)을 이어서 한다
      _koreanPending--;
      if (!_disposed) _kickTranslation();
    }
  }

  Future<void> _fetchYoutubeKorean(
    YoutubeMedia media,
    YoutubeBackend ytDlp,
    CaptionTrack ko,
  ) async {
    final watch = Stopwatch()..start();
    _koreanPending++;
    try {
      final k = parseWebVtt(await ytDlp.fetchCaption(media, ko));
      if (_disposed || k.isEmpty) return;
      debugPrint(
        '[captions] Korean ${k.length} lines in ${watch.elapsedMilliseconds}ms',
      );
      koreanFrom = _youtubeKoreanLabel(ko);
      _setCues(mergeTranslation(cues, k));
      await _saveCache();
    } on Exception catch (e) {
      // YouTube 자동 번역은 429가 잦다. 실패하면 AI 번역을 그대로 쓴다
      debugPrint(
        'YouTube Korean captions failed (${watch.elapsedMilliseconds}ms): $e',
      );
    } finally {
      // 다 받았거나 실패했으면 남은 줄의 번역(또는 API 키 안내)을 이어서 한다
      _koreanPending--;
      if (!_disposed) _kickTranslation();
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
    koreanFrom = null;
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
  /// 절반 넘게 비어 있으면 다른 편집본 자막이라 버리고 AI 번역을 쓴다.
  void _checkKoreanTiming() {
    // 음성 인식 원문은 줄을 다르게 나눠서 비교 기준이 못 된다
    if (_onlineKorean == null || !_onlineOriginal || cues.isEmpty) return;
    final r = koreanCoverage(cues);
    debugPrint('korean timing: ${(r * 100).round()}% of lines covered');
    if (r >= 0.5) return;
    notice =
        '인터넷 한국어 자막이 음성과 맞지 않아(${(r * 100).round()}%) ${settings.provider.label}로 번역합니다';
    _onlineKorean = null;
    koreanFrom = null;
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

  // ---- 시작할 때 싱크 (YouTube 자막) ----

  static const _syncUnknown = '싱크 확인 불가';

  /// YouTube에 올라온 자막은 영상과 다른 판본 기준일 수 있다
  /// (실사례: TED 강연 자막이 인트로 없는 판본 기준이라 처음부터 끝까지 18.6초 빠름).
  /// 음성 인식 자막은 같은 소리에서 시간을 얻었으므로 확인하지 않는다.
  ///
  /// 로컬 파일: 내장 자막은 다른 판본 기준일 수 있고, 인터넷 자막의 전체 싱크([_autoSync])는
  /// ffmpeg가 있는 데스크톱에서만 되므로 그 밖의 경우 이 방법으로 맞춘다.
  bool get _needsStartSync =>
      switch (source) {
        YoutubeSource() => true,
        LocalFileSource() => !_needsSync || !hasDesktopTools,
      } &&
      canTranscribe &&
      originalFrom != fromStt &&
      syncInfo == null &&
      cues.isNotEmpty &&
      !_dbg('DUALCUE_NO_VERIFY');

  /// 재생 위치부터 1분(Android 30초)을 받아 적어 자막과 같은 말이 나오는 시각을 비교하고,
  /// 자막 전체가 밀려 있으면 그만큼 옮긴다. 실패해도 자막은 그대로 쓴다.
  Future<void> _startSync() async {
    final plan = startSyncPlan(android: Platform.isAndroid, tv: tvDevice);
    // Android는 싱크 확인만 하려고 큰 모델을 받지 않는다. 받아 둔 뒤에 열 때 확인한다
    final model = Platform.isAndroid
        ? await whisperModelIfPresent(settings.whisperModel)
        : await ensureWhisperModel(settings.whisperModel);
    if (model == null) {
      debugPrint('[start-sync] skipped: speech model not downloaded');
      return;
    }
    final tmp = await Directory.systemTemp.createTemp('transcue_start_');
    try {
      final vad = await ensureVadModel();
      final (input, headers, total) = switch (source) {
        YoutubeSource(:final media) => (
          media.audioUrl ?? media.videoUrl,
          media.httpHeaders,
          media.duration,
        ),
        LocalFileSource(:final path) => (
          path,
          const <String, String>{},
          (await _probe(path)).duration,
        ),
      };
      TextOffset? found;
      String? detected;
      var from = playhead();
      for (var i = 0; i < plan.tries && found == null; i++) {
        if (_disposed) return;
        if (total != null && total > Duration.zero && from >= total) break;
        final spoken = <BilingualCue>[];
        await for (final ev in transcribeRange(
          input: input,
          httpHeaders: headers,
          start: from,
          length: plan.window,
          model: model,
          vadModel: vad,
          // 제목으로 짐작한 언어면 음성 언어를 확인하려고 자동 감지
          language: _titleGuess != null ? 'auto' : sourceLang ?? 'auto',
          tmp: tmp,
          threads: plan.threads,
        )) {
          if (ev is SttCue) spoken.add(ev.cue);
          if (ev is SttLanguage) detected ??= ev.code;
        }
        if (detected != null && _titleGuess != null) {
          final guess = _titleGuess;
          await _confirmTitleGuess(detected);
          // 짐작이 틀려 자막이 바뀌었으면 이 측정은 의미가 없다
          if (detected.split('-').first != guess) return;
        }
        found = estimateTextOffset(shiftCues(spoken, from), cues);
        debugPrint(
          '[start-sync] at ${from.inSeconds}s: '
          '${found == null ? 'undecided' : '${found.describe()} (${found.matches})'}',
        );
        from += plan.window;
      }
      // 재는 동안 사용자가 직접 맞췄으면 건드리지 않는다
      if (_disposed || manualOffset != Duration.zero) return;
      if (found == null) {
        syncInfo = _syncUnknown;
      } else if (found.significant) {
        _setCues(shiftCues(cues, found.offset));
        syncInfo = '싱크 자동 보정 ${found.describe()}';
      } else {
        syncInfo = '싱크 정상';
      }
      await _saveCache();
      if (stage == JobStage.done) {
        _set(JobStage.done, _summary());
      } else if (!_disposed) {
        notifyListeners();
      }
    } catch (e) {
      debugPrint('start sync failed: $e'); // 다음에 열 때 다시 확인한다
    } finally {
      await deleteTempDir(tmp);
    }
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
        if (koCues != null) koreanFrom = 'OpenSubtitles 한국어 자막';
        return false;
      }
      _set(JobStage.preparing, '자막 내려받는 중 (OpenSubtitles)…');
      var c = parseWebVtt(await os.download(origHit.fileId));
      if (c.isEmpty) return false;
      if (!fitsDuration(c, info.duration)) {
        // 다른 작품/편집본 자막: 싱크로 맞출 수 없으니 음성 인식을 쓴다
        notice = '인터넷 자막이 영상 길이와 맞지 않아 음성 인식을 사용합니다';
        _onlineKorean = koCues;
        if (koCues != null) koreanFrom = 'OpenSubtitles 한국어 자막';
        if (!_disposed) notifyListeners();
        return false;
      }
      // 실제 음성과 같은 내용인지
      if (!await _speechMatches(c, lang: lang.split('-').first)) {
        _onlineKorean = null;
        koreanFrom = null; // 같은 검색에서 나온 한국어 자막도 믿을 수 없다
        return false;
      }
      _onlineOriginal = true;
      _onlineKorean = koCues;
      if (koCues != null) koreanFrom = 'OpenSubtitles 한국어 자막';
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

  /// 재생 위치 [ph]에서 인식을 시작할 곳: 말 첫머리가 잘리지 않게 조금 앞
  static int _sttFrom(Duration ph, int total) =>
      (ph.inMilliseconds - 1500).clamp(0, total);

  int _nextCoveredStart(int after, int total) {
    var n = total;
    for (final (a, _) in _covered) {
      if (a > after && a < n) n = a;
    }
    return n;
  }

  /// 재생 위치에 맞춰 큐를 시간순으로 끼워 넣는다
  void _insertCue(BilingualCue cue) {
    // 시간이 맞는 한국어 자막이 있으면 인식되는 줄마다 바로 붙인다 (AI 번역을 기다리지 않게)
    final ko = _onlineKorean;
    final c = ko != null && _koreanTimed && cue.translation == null
        ? mergeTranslation([cue], ko).first
        : cue;
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

  /// 인식이 느린 기기에서 재생 위치보다 얼마나 앞에서 인식을 시작할지
  /// (조각 하나에 걸린 시간. 재생 위치에서 시작하면 끝날 때 그 구간은 이미 지나가 있다)
  int _leadMs = 0;
  Duration get _lead => Duration(milliseconds: _leadMs);

  // ---- Parakeet (영어) ----

  /// whisper로 언어를 다시 확인하기 전까지 Parakeet으로 인식할 조각 수
  static const _parakeetRecheck = 5;

  File? _parakeetModel;
  bool _parakeetStarted = false;
  double? _parakeetDownload;

  /// parakeet-cli와 모델을 준비한다. 받는 동안에는 whisper로 계속 인식한다.
  void _prepareParakeet() {
    if (_parakeetStarted) return;
    _parakeetStarted = true;
    () async {
      try {
        // 데스크톱은 parakeet-cli가 있어야 한다 (Android는 앱에 함께 빌드되어 있다)
        if (hasDesktopTools) await parakeetCli(); // 없으면 예외
        final f = await ensureModelFile(
          ParakeetModel.file,
          ParakeetModel.url,
          onProgress: (p) => _parakeetDownload = p,
        );
        _parakeetDownload = null;
        _parakeetModel = f;
        debugPrint('[stt] parakeet ready: ${f.path}');
      } on Exception catch (e) {
        _parakeetDownload = null;
        debugPrint('parakeet unavailable: $e');
        notice = 'Parakeet을 쓸 수 없어 whisper로 인식합니다 ($e)';
        if (!_disposed) notifyListeners();
      }
    }();
  }

  String _sttStatus(double fraction) {
    final t = _translatedCount;
    final active = _activeChunk;
    final chunk = active == null
        ? ''
        : ' · $active 인식 중 ${_chunkWatch.elapsed.inSeconds}초';
    final trans = settings.hasTranslateKey && sourceLang != 'ko'
        ? ' · 번역 $t줄 ($translationLabel)'
        : '';
    final dl = _parakeetDownload;
    final parakeet = dl == null
        ? ''
        : ' · Parakeet 모델 받는 중 ${(dl * 100).toStringAsFixed(0)}%';
    return '음성 인식 ${(fraction * 100).toStringAsFixed(0)}% · ${cues.length}줄$trans$chunk$parakeet';
  }

  /// 음성 인식이 마지막으로 믿은 언어
  String? _spokenLang;

  Future<void> _speechToText() async {
    if (!canTranscribe) {
      originalFrom = '자막 없음';
      notice = '이 기기에서는 음성 인식을 지원하지 않습니다 (인터넷 자막만 사용)';
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
    // 영어로 확인된 구간은 Parakeet으로 (모델은 처음 필요할 때 뒤에서 받는다)
    final wantParakeet =
        settings.englishStt == EnglishStt.parakeet && canUseParakeet;
    var parakeetRuns = 0;

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
    // Android: YouTube 소리를 미리 받아 두고, 다 받으면 파일에서 읽는다
    // (주소에서 바로 읽으면 구간마다 받는 데 10~30초가 걸린다)
    String? localAudio;
    if (Platform.isAndroid && source is YoutubeSource) {
      unawaited(() async {
        try {
          final f = await downloadInRanges(
            input,
            headers,
            File('${tmp.path}/audio'),
            // 다른 영상으로 넘어가면 그만 받는다
            cancelled: () => _disposed,
          );
          if (!_disposed) localAudio = f.path;
        } on Exception catch (e) {
          debugPrint('[audio] download failed: $e');
        }
      }());
    }
    try {
      int? lastEnd;
      _set(
        JobStage.transcribing,
        _sttStatus(_coveredMs / total),
        _coveredMs / total,
      );
      while (!_disposed) {
        // 음성 인식으로 언어를 알았고 그 언어의 YouTube 자막이 있으면 그것으로 바꾸고 끝낸다
        if (refresh != JobRefresh.speech &&
            await _switchToYoutubeCaptions(_spokenLang)) {
          return;
        }
        // 재생 위치(2초 앞)부터 비어 있는 곳 → 없으면 처음부터 비어 있는 곳
        // 인식이 느린 기기는 조각 하나에 걸리는 시간만큼 앞에서 시작한다
        final start =
            _firstGap(_sttFrom(playhead() + _lead, total), total) ??
            _firstGap(0, total);
        if (start == null) break;
        // Android: 재생 위치에서 먼 곳(3분 넘게 앞이거나 지나간 곳)은 미리 인식하지 않고 쉰다.
        // 인식이 빠른 코어를 모두 쓰는 동안 영상 디코딩이 밀려 소리와 입 모양이 어긋났다
        // (갤럭시 탭 S9, 로컬 파일을 재생 위치보다 10분 넘게 앞까지 쉬지 않고 인식).
        // 재생 위치를 옮기면 다음 확인(2초 뒤)에 그곳부터 인식한다.
        if (Platform.isAndroid) {
          final ph = playhead().inMilliseconds;
          if (start > ph + _leadMs + _androidAheadMs || start < ph - 2000) {
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
        }
        // 앞에서 시작할 때는 짧은 조각이 도움이 안 된다 (받기·인식에 길이와 상관없이 드는 시간이 크다)
        final jumped =
            _leadMs == 0 && (lastEnd == null || (start - lastEnd).abs() > 1000);
        final stop = _nextCoveredStart(start, total);
        // 인식된 구간 사이의 아주 짧은 틈(2초 미만)은 인식하지 않고 채운다.
        // 1초도 안 되는 소리는 '소리 없음(영상 끝)'으로 돌아와, 그 뒤 전체가 인식된 것으로
        // 잘못 표시되었다 (태블릿: 26초→26초 조각 뒤로 영상 끝까지 자막이 생기지 않음)
        if (stop < total && stop - start < _minGapMs) {
          _addCovered(start, stop);
          lastEnd = null;
          continue;
        }
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
        // 중단될 때 인식이 끝난 곳 (whisper는 앞에서부터 차례로 내보낸다)
        var doneUntil = start;
        if (wantParakeet && _spokenLang == 'en') _prepareParakeet();
        final parakeet = _parakeetModel;
        // 영상 안에서 언어가 바뀔 수 있어 몇 조각마다 whisper로 언어를 다시 확인한다
        final useParakeet =
            parakeet != null &&
            _spokenLang == 'en' &&
            parakeetRuns < _parakeetRecheck;
        parakeetRuns = useParakeet ? parakeetRuns + 1 : 0;
        _activeChunk =
            '${formatPosition(Duration(milliseconds: start))}'
            '~${formatPosition(Duration(milliseconds: hardEnd))}'
            '${useParakeet ? ' (Parakeet)' : ''}';
        _chunkWatch
          ..reset()
          ..start();
        final finished = Completer<void>();
        final aborted = Completer<void>();
        final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
          _set(
            JobStage.transcribing,
            _sttStatus(progress ?? _coveredMs / total),
            progress,
          );
        });
        // 재생 위치를 옮겨서 이 조각이 지금 보는 곳과 상관없어졌으면 그만둔다
        _onSeek = (ph) {
          if (aborted.isCompleted || finished.isCompleted) return;
          final target = _firstGap(_sttFrom(ph + _lead, total), total);
          if (target != null && (target < start || target >= hardEnd)) {
            debugPrint(
              '[stt] seek to ${ph.inSeconds}s: abort chunk ${start ~/ 1000}s',
            );
            aborted.complete();
            // whisper 조각만 멈출 수 있다 (Parakeet은 끝까지 돈다)
            if (!useParakeet) unawaited(cancelTranscribe());
          }
        };
        final sub =
            transcribeRange(
              input: localAudio ?? input,
              httpHeaders: headers,
              start: Duration(milliseconds: start),
              length: Duration(milliseconds: readEnd - start),
              model: model,
              vadModel: vad,
              // 영상 안에서 언어가 바뀔 수 있으므로 구간마다 새로 감지한다
              language: 'auto',
              fallbackLanguage: _spokenLang,
              tmp: tmp,
              parakeetModel: useParakeet ? parakeet : null,
            ).listen(
              (ev) {
                switch (ev) {
                  case SttEnd():
                    ended = true;
                  case SttCue(:final cue):
                    final c = shiftCues([
                      cue,
                    ], Duration(milliseconds: start)).first;
                    final s = c.start.inMilliseconds;
                    // 다음 조각에 속하는 줄, 이미 인식한 구간의 줄은 버린다
                    if (s >= hardEnd || _inCovered(s)) return;
                    final e = c.end.inMilliseconds;
                    if (e > lastCueEnd) lastCueEnd = e > readEnd ? readEnd : e;
                    if (e > doneUntil) doneUntil = e > hardEnd ? hardEnd : e;
                    // 말이 끝났는데 자막이 오래 남지 않게 (인식 구간은 원래 끝으로 센다)
                    _insertCue(trimLingeringEnd(c));
                    _kickTranslation(); // 구간이 끝나길 기다리지 않고 바로 번역
                  case SttProgress(:final fraction):
                    final p =
                        (_coveredMs + fraction * (hardEnd - start)) / total;
                    _set(JobStage.transcribing, _sttStatus(p), p);
                  case SttLanguage(:final code):
                    debugPrint('[stt] language $code');
                    _spokenLang = code;
                    sourceLang = mergeSpokenLang(sourceLang, code);
                    // 이 언어의 YouTube 자막이 있으면 이 조각을 기다리지 않고 바로 바꾼다
                    if (refresh != JobRefresh.speech &&
                        _youtubeCaptionFor(code) != null &&
                        !aborted.isCompleted) {
                      aborted.complete();
                    }
                }
              },
              onError: (Object e, StackTrace st) {
                if (!finished.isCompleted) finished.completeError(e, st);
              },
              onDone: () {
                if (!finished.isCompleted) finished.complete();
              },
              cancelOnError: true,
            );
        try {
          await Future.any([finished.future, aborted.future]);
        } on Exception catch (e) {
          if (!useParakeet) rethrow;
          // Parakeet이 실패하면 작업 전체를 멈추지 않고 이 조각부터 whisper로 다시 인식한다
          // (Parakeet은 끝난 뒤 한꺼번에 내보내므로 이 조각에서 들어온 줄이 없다)
          debugPrint('[stt] parakeet failed, fallback to whisper: $e');
          _parakeetModel = null;
          notice = 'Parakeet 인식에 실패해 whisper로 인식합니다';
          if (!_disposed) notifyListeners();
          lastEnd = null;
          continue;
        } finally {
          ticker.cancel();
          _onSeek = null;
          _activeChunk = null;
          if (!finished.isCompleted) await sub.cancel();
        }
        if (!finished.isCompleted) {
          // 옮긴 위치부터 다시. 받은 줄까지는 인식된 것으로 남긴다.
          _addCovered(start, doneUntil);
          lastEnd = null;
          await _saveCache();
          continue;
        }
        // Android에서 3초 넘게 걸리면 다음 조각을 그만큼(+여유 2초) 앞에서 시작한다.
        // Android는 조각이 끝나야 줄을 한꺼번에 내보내므로 재생 위치에서 시작하면 늦는다.
        // 데스크톱(whisper-cli)은 인식하는 대로 줄을 내보내므로 재생 위치부터 인식해야
        // 영상 초반 자막이 빠지지 않는다 (앞에서 시작하면 첫 조각 뒤 11~27초가 비었다).
        final took = _chunkWatch.elapsedMilliseconds;
        _leadMs = Platform.isAndroid && took > 3000
            ? (took + 2000).clamp(0, 90000)
            : 0;
        if (ended) {
          // 소리가 없음. 영상 끝 근처(또는 길이를 모름)일 때만 끝까지 인식된 것으로 본다.
          // 중간이면 이 조각만 채운다 (소리가 짧게 읽혔을 뿐 뒤에는 아직 말이 있다)
          final atEnd =
              duration == null ||
              duration <= Duration.zero ||
              readEnd >= total - _endSlackMs;
          _addCovered(start, atEnd ? total : readEnd);
          // 재생 위치부터 시작했다면 앞부분이 남아 있으므로 계속한다
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
      (c.translation == null || (c.provisional && settings.hasTranslateKey));

  int get _translatedCount =>
      cues.where((c) => c.translation != null && !_wantsTranslation(c)).length;

  /// 번역 요청을 보내 놓고 응답을 기다리는 줄 (두 번역 루프가 같은 줄을 보내지 않게)
  final _inFlight = <String>{};

  /// 재생 위치 근처로 보는 범위: 지난 5초 ~ 앞으로 1분
  static const _nearBeforeMs = 5000;
  static const _nearAheadMs = 60000;

  List<BilingualCue> _pendingByPriority({bool nearOnly = false}) {
    final now = playhead().inMilliseconds;
    final ph = now - _nearBeforeMs;
    final p = [
      for (final c in cues)
        if (_wantsTranslation(c) &&
            !_attempted.contains(_key(c)) &&
            !_inFlight.contains(_key(c)))
          c,
    ];
    final ahead = p.where((c) => c.end.inMilliseconds >= ph);
    if (nearOnly) {
      return [
        for (final c in ahead)
          if (c.start.inMilliseconds < now + _nearAheadMs) c,
      ];
    }
    return [...ahead, ...p.where((c) => c.end.inMilliseconds < ph)];
  }

  bool get _needsTranslation =>
      sourceLang != 'ko' && _pendingByPriority().isNotEmpty;

  /// 재생 위치 근처만 번역하는 두 번째 루프. 재생 위치를 옮겼을 때 다른 곳을
  /// 번역하던 요청(최대 30줄)의 응답을 기다리지 않고 지금 보는 곳을 바로 번역한다.
  Future<void>? _nearLoop;

  /// 번역 루프가 없으면 시작한다. 음성 인식 줄이 생기거나 재생 위치를 옮길 때 불린다.
  void _kickTranslation() {
    kickVocab(); // 학습 단어도 같은 시점에 (켜져 있을 때만)
    kickRuby(); // 일본어 읽는 법도
    if (_dbg('DUALCUE_NO_TRANSLATE')) return;
    if (!_needsTranslation) {
      // 한국어 자막으로 모두 채워졌으면 API 키 안내는 필요 없다
      if (notice?.contains('API 키를 등록') ?? false) {
        notice = null;
        if (!_disposed) notifyListeners();
      }
      return;
    }
    if (!settings.hasTranslateKey) {
      // 한국어 자막을 받는 중이면 그것으로 채워질 수 있으니 기다린다 (받으면 다시 불린다)
      if (_koreanPending > 0) return;
      final left = _pendingByPriority().length;
      notice = koreanFrom == null
          ? '설정(⚙)에서 ${settings.provider.label} API 키를 등록하면 한국어 번역이 표시됩니다'
          : '$koreanFrom에 없는 $left줄은 설정(⚙)에서 ${settings.provider.label} API 키를 등록하면 번역됩니다';
      if (!_disposed) notifyListeners();
      return;
    }
    if (_loop == null) {
      _loop = _translateLoop().whenComplete(() => _loop = null);
    } else if (_nearLoop == null &&
        _pendingByPriority(nearOnly: true).isNotEmpty) {
      _nearLoop = _translateLoop(
        nearOnly: true,
      ).whenComplete(() => _nearLoop = null);
    }
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
      await Future.wait([l, ?_nearLoop]);
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
      settings.hasTranslateKey;

  /// 원문은 그대로 두고 AI로 다시 번역한다. 새 번역이 온 줄부터 바뀐다.
  Future<void> retranslate() async {
    if (!canRetranslate) return;
    _fromCache = false;
    koreanFrom = null; // 한국어 자막 대신 AI 번역으로 모두 바꾼다
    _aiLines = 0;
    _setCues([
      for (final c in cues)
        c.translation == null
            ? c
            : c.withTranslation(c.translation, provisional: true),
    ]);
    await translateRemaining();
  }

  Future<void> _translateLoop({bool nearOnly = false}) async {
    final tr = createTranslator(settings);
    try {
      while (!_disposed) {
        final pending = _pendingByPriority(nearOnly: nearOnly);
        if (pending.isEmpty) return;
        final near = (pending.first.start - playhead()).inSeconds.abs() < 30;
        final batch = pending.take(near ? _nearBatchSize : _batchSize).toList();
        final keys = batch.map(_key).toList();
        _inFlight.addAll(keys);

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
            '번역 중 $done/${cues.length} · ${settings.translateModelLabel}',
            done / cues.length,
          );
        }
        final Map<int, String> out;
        try {
          out = await tr.translate(req);
        } finally {
          _inFlight.removeAll(keys);
        }
        // 기다리는 동안 음성 인식이 줄을 끼워 넣었을 수 있어 위치가 아니라 내용으로 찾는다
        final byKey = <String, String>{
          for (var i = 0; i < batch.length; i++)
            if ((out[i] ?? '').isNotEmpty) _key(batch[i]): out[i]!,
        };
        _aiLines += byKey.length;
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
    } catch (e) {
      // 어떤 오류든 알린다 (안내 없이 멈추면 번역이 왜 안 되는지 알 수 없다)
      debugPrint('[translate] stopped: $e');
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
    if (!settings.hasTranslateKey) {
      notice = '설정(⚙)에서 ${settings.provider.label} API 키를 등록하면 학습 단어가 표시됩니다';
      if (!_disposed) notifyListeners();
      return;
    }
    _vocabLoop = _vocabRun().whenComplete(() {
      _vocabLoop = null;
      if (!_disposed && stage == JobStage.done) _set(JobStage.done, _summary());
    });
  }

  Future<void> _vocabRun() async {
    final tr = createTranslator(settings);
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
    } catch (e) {
      // 어떤 오류든 알린다 (안내 없이 멈추면 번역이 왜 안 되는지 알 수 없다)
      debugPrint('[translate] stopped: $e');
      notice = '학습 단어 생성 중단: $e';
      if (!_disposed) notifyListeners();
    }
  }

  // ---- 일본어 읽는 법 (켜져 있을 때만, 재생 위치 근처부터) ----

  Future<void>? _rubyLoop;
  final _rubyAttempted = <String>{};
  static final _kanji = RegExp(r'[㐀-䶿一-鿿々〆ヶ]');

  List<BilingualCue> _rubyPending() {
    final ph = playhead().inMilliseconds - 5000;
    final p = [
      for (final c in cues)
        if (c.ruby == null &&
            _kanji.hasMatch(c.original) &&
            !_rubyAttempted.contains(_key(c)))
          c,
    ];
    return [
      ...p.where((c) => c.end.inMilliseconds >= ph),
      ...p.where((c) => c.end.inMilliseconds < ph),
    ];
  }

  /// 읽는 법 만들기를 시작한다 (설정에서 켰을 때도 호출). 일본어 자막에만.
  void kickRuby() {
    if (!settings.showRuby || sourceLang != 'ja') return;
    if (_dbg('DUALCUE_NO_TRANSLATE')) return;
    if (_rubyLoop != null || _rubyPending().isEmpty) return;
    if (!settings.hasTranslateKey) {
      notice = '설정(⚙)에서 ${settings.provider.label} API 키를 등록하면 읽는 법이 표시됩니다';
      if (!_disposed) notifyListeners();
      return;
    }
    _rubyLoop = _rubyRun().whenComplete(() => _rubyLoop = null);
  }

  Future<void> _rubyRun() async {
    final tr = createTranslator(settings);
    try {
      while (!_disposed && settings.showRuby) {
        final pending = _rubyPending();
        if (pending.isEmpty) return;
        final near = (pending.first.start - playhead()).inSeconds.abs() < 30;
        final batch = pending.take(near ? _nearBatchSize : _batchSize).toList();
        final out = await tr.furigana({
          for (var i = 0; i < batch.length; i++) i: batch[i].original,
        });
        final byKey = <String, String>{
          for (var i = 0; i < batch.length; i++)
            if (out[i] != null) _key(batch[i]): out[i]!,
        };
        _rubyAttempted.addAll(batch.map(_key));
        _setCues([
          for (final c in cues)
            if (byKey[_key(c)] case final r?) c.withRuby(r) else c,
        ]);
        await _saveCache();
      }
    } catch (e) {
      // 어떤 오류든 알린다 (안내 없이 멈추면 번역이 왜 안 되는지 알 수 없다)
      debugPrint('[translate] stopped: $e');
      notice = '읽는 법 생성 중단: $e';
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
