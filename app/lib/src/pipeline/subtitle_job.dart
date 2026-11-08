import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../online/opensubtitles.dart';
import '../settings/app_settings.dart';
import '../source/yt_dlp.dart';
import '../subtitle/bilingual_cue.dart';
import '../subtitle/webvtt.dart';
import '../translate/claude_translator.dart';
import 'media_tools.dart';
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

/// 영상 하나의 이중 자막을 만드는 작업.
///
/// 순서: 캐시 → (내장 자막 | YouTube 자막) → 없으면 음성 추출 + whisper STT
///       → 한국어가 없는 줄은 Claude 번역. STT/번역 결과는 생기는 대로 [cues]에 반영.
class SubtitleJob extends ChangeNotifier {
  SubtitleJob({required this.source, required this.settings});

  final JobSource source;
  final AppSettings settings;

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
  int _translatedUpTo = 0; // 이 위치 이전은 번역 시도 완료

  /// 캐시 형식/품질이 바뀌면 올린다. v2: whisper -mc 0 적용
  static const _cacheVersion = 2;
  static const _batchSize = 30;
  static const _contextSize = 5;

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

  Future<void> _saveCache() async {
    if (!_sttDone) return; // 인식이 끝난 결과만 저장
    final f = await _cacheFile();
    await f.writeAsString(
      jsonEncode({
        'v': _cacheVersion,
        'lang': sourceLang,
        'from': originalFrom,
        'osTried': _osTried,
        'cues': [for (final c in cues) c.toJson()],
      }),
    );
  }

  Future<bool> _loadCache() async {
    final f = await _cacheFile();
    if (!await f.exists()) return false;
    try {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (j['v'] != _cacheVersion) return false; // 이전 버전 결과는 다시 만든다
      sourceLang = j['lang'] as String?;
      originalFrom = '${j['from'] ?? '저장된 자막'}';
      _osTried = j['osTried'] == true;
      _fromCache = true;
      _setCues([
        for (final c in (j['cues'] as List).cast<Map<String, dynamic>>())
          BilingualCue.fromJson(c),
      ]);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- 실행 ----

  Future<void> run() async {
    try {
      _set(JobStage.preparing, '자막 준비 중…');
      if (await _loadCache()) {
        _sttDone = true;
        // 저장된 결과가 음성 인식이면 인터넷 자막을 먼저 찾아본다 (있으면 우선 사용)
        if (_shouldTryOnlineOverCache) await _tryOnlineOverCache();
      } else if (!await _loadExistingSubtitles()) {
        await _speechToText();
        // 인터넷에서 한국어 자막만 찾은 경우: 음성 인식 결과에 시간 기준으로 붙인다
        final ko = _onlineKorean;
        if (ko != null) _setCues(mergeTranslation(cues, ko));
      }
      _sttDone = true;
      await _saveCache();
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
    final t = cues.where((c) => c.translation != null).length;
    final trans = sourceLang == 'ko'
        ? ''
        : t == n
        ? ' · 번역 완료'
        : ' · 번역 $t/$n';
    return '자막 $n줄 ($originalFrom${_fromCache ? ' · 저장됨' : ''})$trans';
  }

  /// 내장 자막 또는 YouTube 자막. 찾으면 true.
  Future<bool> _loadExistingSubtitles() async {
    switch (source) {
      case LocalFileSource(:final path):
        final info = await probe(path);
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

  Future<void> _tryOnlineOverCache() async {
    final path = (source as LocalFileSource).path;
    final stt = cues;
    if (await _loadOnlineSubtitles(path, await probe(path))) {
      _fromCache = false; // 인터넷 자막으로 교체됨
    } else if (_onlineKorean case final ko?) {
      // 한국어 자막만 있으면 저장된 음성 인식 원문에 붙인다
      _setCues(mergeTranslation(stt, ko));
    }
  }

  /// 인터넷에서 찾은 한국어 자막 (원어 자막은 못 찾았을 때 STT 결과에 병합)
  List<BilingualCue>? _onlineKorean;

  /// OpenSubtitles에서 원어/한국어 자막을 찾는다. 원어를 찾으면 true.
  /// 실패해도 예외를 내지 않고 음성 인식으로 넘어간다.
  Future<bool> _loadOnlineSubtitles(String path, MediaInfo info) async {
    if (!settings.hasOpenSubtitles) return false;
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
      final origHit = pickBest(hits, lang);
      final koHit = lang == 'ko' ? null : pickBest(hits, 'ko');
      debugPrint(
        'OpenSubtitles ${name.title} S${name.season}E${name.episode} '
        'hash=$hash hits=${hits.length} orig=${origHit?.release} ko=${koHit?.release}',
      );

      List<BilingualCue>? koCues;
      if (koHit != null) {
        _set(JobStage.preparing, '한국어 자막 내려받는 중 (OpenSubtitles)…');
        koCues = parseWebVtt(await os.download(koHit.fileId));
      }
      if (origHit == null) {
        _onlineKorean = koCues;
        return false;
      }
      _set(JobStage.preparing, '자막 내려받는 중 (OpenSubtitles)…');
      var c = parseWebVtt(await os.download(origHit.fileId));
      if (c.isEmpty) return false;
      if (koCues != null) c = mergeTranslation(c, koCues);
      sourceLang = lang.split('-').first;
      originalFrom = origHit.hashMatch
          ? 'OpenSubtitles · 파일 일치'
          : 'OpenSubtitles · 이름 검색 (싱크 확인 필요)';
      _setCues(c);
      return true;
    } on Exception catch (e) {
      debugPrint('OpenSubtitles failed: $e');
      notice = '인터넷 자막을 가져오지 못했습니다 ($e)';
      if (!_disposed) notifyListeners();
      return false;
    }
  }

  Future<void> _speechToText() async {
    final model = await ensureWhisperModel(
      settings.whisperModel,
      onProgress: (p) => _set(
        JobStage.downloadingModel,
        '음성 인식 모델 내려받는 중 (처음 한 번) ${(p * 100).toStringAsFixed(0)}%',
        p,
      ),
    );
    final vad = await ensureVadModel();

    final tmp = await Directory.systemTemp.createTemp('dualcue_');
    try {
      final wav = '${tmp.path}/audio.wav';
      final (input, headers, duration) = switch (source) {
        LocalFileSource(:final path) => (
          path,
          const <String, String>{},
          (await probe(path)).duration,
        ),
        YoutubeSource(:final media) => (
          media.audioUrl ?? media.videoUrl,
          media.httpHeaders,
          null,
        ),
      };
      _set(JobStage.extractingAudio, '음성 추출 중…', duration == null ? null : 0);
      await extractAudio(
        input,
        wav,
        httpHeaders: headers,
        duration: duration,
        onProgress: (p) => _set(
          JobStage.extractingAudio,
          '음성 추출 중 ${(p * 100).toStringAsFixed(0)}%',
          p,
        ),
      );

      originalFrom = fromStt;
      _set(JobStage.transcribing, '음성 인식 중…', 0);
      final found = <BilingualCue>[];
      await for (final ev in transcribe(
        wavPath: wav,
        model: model,
        vadModel: vad,
      )) {
        switch (ev) {
          case SttCue(:final cue):
            found.add(cue);
            _setCues(List.unmodifiable(found));
            _kickTranslation();
          case SttProgress(:final fraction):
            _set(
              JobStage.transcribing,
              '음성 인식 중 ${(fraction * 100).toStringAsFixed(0)}% · ${found.length}줄',
              fraction,
            );
          case SttLanguage(:final code):
            sourceLang = code;
        }
      }
    } finally {
      await tmp.delete(recursive: true);
    }
  }

  // ---- 번역 ----

  Future<void>? _loop;

  bool get _needsTranslation =>
      sourceLang != 'ko' && cues.any((c) => c.translation == null);

  /// 번역 루프가 없으면 시작한다. 인식 중에는 묶음이 찰 때마다 불린다.
  void _kickTranslation() {
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
    _translatedUpTo = 0; // 앞에서 누락된 줄도 다시 시도
    notice = null;
    while (!_disposed) {
      _kickTranslation();
      final l = _loop;
      if (l == null) break;
      await l;
      if (notice != null) break;
      final left = cues.skip(_translatedUpTo).any((c) => c.translation == null);
      if (!left) break;
    }
    if (!_disposed && stage != JobStage.failed && _sttDone) {
      _set(JobStage.done, _summary());
    }
  }

  Future<void> _translateLoop() async {
    final tr = ClaudeTranslator(
      apiKey: settings.claudeApiKey,
      model: settings.claudeModel,
    );
    try {
      while (!_disposed) {
        final pending = <int>[
          for (var i = _translatedUpTo; i < cues.length; i++)
            if (cues[i].translation == null) i,
        ];
        // 인식 중에는 마지막 줄이 아직 이어질 수 있어 빼고, 묶음이 찰 때까지 기다린다
        final ready = _sttDone ? pending.length : pending.length - 1;
        if (ready <= 0 || (!_sttDone && ready < _batchSize)) return;

        final ids = pending.take(_batchSize).toList();
        final first = ids.first;
        final batch = TranslationBatch(
          sourceLang: sourceLang ?? 'auto',
          context: [
            for (var i = (first - _contextSize).clamp(0, first); i < first; i++)
              (cues[i].original, cues[i].translation),
          ],
          items: {for (final i in ids) i: cues[i].original},
        );
        if (_sttDone) {
          final done = cues.where((c) => c.translation != null).length;
          _set(
            JobStage.translating,
            '번역 중 $done/${cues.length} · ${settings.claudeModel.label}',
            done / cues.length,
          );
        }
        final out = await tr.translate(batch);
        final next = [...cues];
        for (final i in ids) {
          final t = out[i];
          if (t != null && t.isNotEmpty) next[i] = next[i].withTranslation(t);
        }
        _translatedUpTo = ids.last + 1; // 누락된 줄은 다음 translateRemaining 때 재시도
        _setCues(next);
        await _saveCache();
      }
    } on TranslateException catch (e) {
      notice = '번역 중단: $e';
      if (!_disposed) notifyListeners();
    }
  }
}
