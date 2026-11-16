import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../pipeline/tools.dart';
import 'youtube_backend.dart';
import 'youtube_url.dart';

/// yt-dlp가 알려준 자막 트랙 하나.
class CaptionTrack {
  const CaptionTrack({
    required this.lang,
    required this.url,
    required this.auto,
  });

  final String lang;
  final String url;

  /// YouTube 자동 생성(또는 자동 번역) 자막 여부
  final bool auto;
}

/// 재생에 필요한 YouTube 스트림 정보.
class YoutubeMedia {
  const YoutubeMedia({
    required this.id,
    required this.title,
    required this.videoUrl,
    this.audioUrl,
    this.httpHeaders = const {},
    this.language,
    this.original,
    this.korean,
    this.duration,
    this.captionTracks = const [],
  });

  /// 받을 수 있는 자막 트랙 (사람이 만든 자막과 음성 받아쓰기 자동 자막. 자동 번역은 뺀다).
  /// 음성 언어를 몰라 [original]을 못 고른 영상에서, 음성 인식으로 언어를 알아낸 뒤 고른다.
  final List<CaptionTrack> captionTracks;

  /// 영상 길이 (yt-dlp `duration`)
  final Duration? duration;

  final String id;
  final String title;
  final String videoUrl;

  /// 영상/음성이 분리된 고화질 포맷일 때의 음성 스트림
  final String? audioUrl;
  final Map<String, String> httpHeaders;

  /// 영상의 원어 (yt-dlp `language`)
  final String? language;

  /// 원어 자막 (수동 자막 우선, 없으면 자동 생성)
  final CaptionTrack? original;

  /// 한국어 자막 (수동 자막 우선, 없으면 YouTube 자동 번역)
  final CaptionTrack? korean;

  /// `yt-dlp -J` 출력(JSON)에서 재생 정보를 고른다.
  factory YoutubeMedia.fromInfoJson(
    Map<String, dynamic> info, {
    int maxHeight = 1080,
  }) {
    var formats = (info['formats'] as List? ?? [])
        .cast<Map<String, dynamic>>()
        .where(
          (f) =>
              f['url'] is String &&
              // DASH 조각(mhtml 썸네일 등) 제외
              const {
                'https',
                'http',
                'm3u8_native',
                'm3u8',
              }.contains(f['protocol']),
        )
        .toList();

    bool hasV(Map f) => (f['vcodec'] ?? 'none') != 'none';
    bool hasA(Map f) => (f['acodec'] ?? 'none') != 'none';
    // 자동 더빙 등 소리 트랙이 여러 개면 원본 음성만 남긴다 (자막 원어와 같은 언어).
    // yt-dlp는 원본 트랙의 format_note에 'original'을 붙이고 language_preference를 가장 높게 준다.
    final audioFormats = formats.where(hasA).toList();
    bool isOriginal(Map f) =>
        '${f['format_note']}'.toLowerCase().contains('original');
    num langPref(Map f) => (f['language_preference'] as num?) ?? 0;
    final bestPref = audioFormats
        .map(langPref)
        .fold<num?>(null, (a, b) => a == null || b > a ? b : a);
    final keepAudio = audioFormats.any(isOriginal)
        ? isOriginal
        : (Map f) => langPref(f) == bestPref;
    formats = [
      for (final f in formats)
        if (!hasA(f) || keepAudio(f)) f,
    ];
    String? audioLanguage = [
      for (final f in formats)
        if (hasA(f) && f['language'] is String) f['language'] as String,
    ].firstOrNull;
    num h(Map f) => (f['height'] as num?) ?? 0;
    num br(Map f) => (f['tbr'] as num?) ?? (f['abr'] as num?) ?? 0;
    int byQuality(Map a, Map b) {
      final c = h(a).compareTo(h(b));
      return c != 0 ? c : br(a).compareTo(br(b));
    }

    final videoOnly =
        formats.where((f) => hasV(f) && !hasA(f) && h(f) <= maxHeight).toList()
          ..sort(byQuality);
    final audioOnly = formats.where((f) => hasA(f) && !hasV(f)).toList()
      ..sort(byQuality);
    final muxed =
        formats.where((f) => hasV(f) && hasA(f) && h(f) <= maxHeight).toList()
          ..sort(byQuality);

    // HLS(m3u8) 스트림을 우선한다. 직접(https) 스트림 URL은 yt-dlp 외의 플레이어에
    // 403을 돌려주고, 마스터 재생목록은 mpv가 모든 화질을 한꺼번에 열다 멈춘다 (2026-11 실측).
    // → HLS 영상 1개 + HLS 음성 1개 (각각 1초 안에 열림)
    bool isHls(Map f) => '${f['protocol']}'.startsWith('m3u8');
    final hlsVideo =
        formats.where((f) => isHls(f) && hasV(f) && h(f) <= maxHeight).toList()
          ..sort((a, b) {
            final c = h(a).compareTo(h(b));
            if (c != 0) return c;
            // 같은 화질이면 H.264(avc1) 우선 — 하드웨어 디코딩
            final av = '${a['vcodec']}'.startsWith('avc1') ? 1 : 0;
            final bv = '${b['vcodec']}'.startsWith('avc1') ? 1 : 0;
            return av.compareTo(bv);
          });
    final hlsAudio = formats.where((f) => isHls(f) && !hasV(f)).toList();
    final hlsAudioBest =
        hlsAudio
            .where((f) => '${f['format_note']}'.contains('high'))
            .firstOrNull ??
        hlsAudio.lastOrNull;

    Map<String, dynamic>? video, audio;
    if (hlsVideo.isNotEmpty && hlsAudioBest != null) {
      video = hlsVideo.last;
      audio = hlsAudioBest;
    } else if (videoOnly.isNotEmpty &&
        audioOnly.isNotEmpty &&
        (muxed.isEmpty || h(videoOnly.last) > h(muxed.last))) {
      video = videoOnly.last;
      audio = audioOnly.last;
    } else if (muxed.isNotEmpty) {
      video = muxed.last;
    } else if (info['url'] is String) {
      video = info;
    } else {
      throw const FormatException('재생 가능한 포맷이 없습니다');
    }

    final manual = _tracks(info['subtitles'], auto: false);
    final auto = _tracks(info['automatic_captions'], auto: true);
    // 실제 음성 언어: 자동 자막의 '<lang>-orig'(음성을 받아 적은 것) → 원본 소리 트랙의 언어
    // → 영상 정보의 언어(올린 사람이 적은 값이라 틀릴 수 있다)
    // 자동 더빙 영상은 더빙 소리마다 '<lang>-orig'가 있어(실사례: 21개, 알파벳순 첫 번째가 ar)
    // 하나일 때만 믿고, 여럿이면 원본 소리 트랙 → 영상 정보의 언어 순으로 고른다
    final origLangs = [
      for (final k in auto.keys)
        if (k.endsWith('-orig')) k.substring(0, k.length - '-orig'.length),
    ];
    audioLanguage = audioLanguage?.split('-').first;
    final infoLanguage = (info['language'] as String?)?.split('-').first;
    final language = origLangs.length == 1
        ? origLangs.single
        : audioLanguage ??
              infoLanguage ??
              (origLangs.isEmpty ? null : origLangs.first);

    CaptionTrack? pick(Map<String, CaptionTrack> m, bool Function(String) ok) {
      for (final e in m.entries) {
        if (ok(e.key)) return e.value;
      }
      return null;
    }

    bool isLang(String key, String lang) =>
        key == lang || key.startsWith('$lang-');
    // 음성 언어를 모르면 원어 자막 없음 → 음성 인식으로 만든다 (다른 언어 자막을 원어로 쓰지 않는다)
    // 자동 자막의 '<lang>-orig'는 원본 음성 인식 결과 (자동 번역이 아님)
    final original = language == null
        ? null
        : pick(manual, (k) => isLang(k, language)) ??
              auto['$language-orig'] ??
              auto[language];
    final korean = language == null || language == 'ko'
        ? null
        : pick(manual, (k) => isLang(k, 'ko')) ?? auto['ko'];

    final headers = <String, String>{
      for (final e in ((video['http_headers'] as Map?) ?? {}).entries)
        '${e.key}': '${e.value}',
    };

    return YoutubeMedia(
      id: info['id'] as String? ?? '',
      title: info['title'] as String? ?? '',
      videoUrl: video['url'] as String,
      audioUrl: audio?['url'] as String?,
      httpHeaders: headers,
      language: language,
      original: original,
      korean: korean,
      duration: info['duration'] is num
          ? Duration(milliseconds: ((info['duration'] as num) * 1000).round())
          : null,
      captionTracks: [
        ...manual.values,
        for (final e in auto.entries)
          if (e.key.endsWith('-orig')) e.value,
      ],
    );
  }

  static Map<String, CaptionTrack> _tracks(Object? raw, {required bool auto}) {
    final out = <String, CaptionTrack>{};
    if (raw is! Map) return out;
    for (final e in raw.entries) {
      final lang = '${e.key}';
      if (lang == 'live_chat') continue;
      final vtt = (e.value as List? ?? [])
          .cast<Map>()
          .where((t) => t['ext'] == 'vtt' && t['url'] is String)
          .firstOrNull;
      if (vtt != null) {
        out[lang] = CaptionTrack(
          lang: lang,
          url: vtt['url'] as String,
          auto: auto,
        );
      }
    }
    return out;
  }
}

/// 음성 언어 [lang]의 원어 자막: 사람이 만든 자막 → 음성 받아쓰기 자동 자막(`<lang>-orig` 또는 [lang])
CaptionTrack? captionForLanguage(List<CaptionTrack> tracks, String lang) {
  bool isLang(String code) => code == lang || code.startsWith('$lang-');
  return tracks.where((t) => !t.auto && isLang(t.lang)).firstOrNull ??
      tracks.where((t) => t.auto && isLang(t.lang)).firstOrNull;
}

/// 제목 글자로 짐작한 영상 언어. 짐작이 어려우면 null.
/// (음성 언어를 YouTube가 알려 주지 않을 때 자막을 바로 보여 주려는 용도. 음성 인식으로 다시 확인한다)
String? guessLanguageFromTitle(String title) {
  int count(RegExp r) => r.allMatches(title).length;
  final hangul = count(RegExp(r'[가-힣]'));
  final kana = count(RegExp(r'[぀-ヿ]'));
  final han = count(RegExp(r'[一-鿿]'));
  final cyrillic = count(RegExp(r'[Ѐ-ӿ]'));
  final latin = count(RegExp(r'[A-Za-z]'));
  if (hangul > 0 && hangul >= kana) return 'ko';
  if (kana > 0) return 'ja';
  if (han > 0) return 'zh';
  if (cyrillic > latin) return 'ru';
  if (latin == 0) return null;
  // 라틴 글자는 언어가 여럿이라 흔한 영어 낱말이 있을 때만 영어로 본다
  const english = {
    'the',
    'a',
    'an',
    'of',
    'to',
    'and',
    'is',
    'are',
    'in',
    'on',
    'for',
    'with',
    'how',
    'why',
    'what',
    'when',
    'who',
    'you',
    'your',
    'can',
    'do',
    'does',
    'this',
    'that',
    'it',
    'my',
    'we',
    'i',
    'be',
    'from',
    'about',
  };
  final words = title.toLowerCase().split(RegExp(r"[^a-z']+"));
  return words.any(english.contains) ? 'en' : null;
}

class YtDlpException implements Exception {
  const YtDlpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// yt-dlp 실행기. 데스크톱 전용 (모바일은 M6에서 별도 방안).
///
/// 배포판(M5)에서는 앱 지원 폴더에 yt-dlp 단독 실행 파일을 내려받아 쓰고
/// `-U`로 자동 업데이트한다. 개발 중에는 설치된 yt-dlp를 찾는다.
class YtDlp implements YoutubeBackend {
  YtDlp({this.executable});

  /// 명시 경로. null이면 [locate]로 찾는다.
  final String? executable;

  Future<String?> locate() async => executable ?? await locateTool('yt-dlp');

  Future<String> _exe() async {
    final exe = await locate();
    if (exe == null) {
      throw const YtDlpException(
        'yt-dlp를 찾을 수 없습니다.\n'
        'macOS: brew install yt-dlp\nWindows: winget install yt-dlp\n'
        'Linux: scripts/setup-linux.sh',
      );
    }
    return exe;
  }

  Future<String> _run(List<String> args) async {
    final r = await Process.run(await _exe(), [
      '--no-playlist',
      '--no-warnings',
      '--no-cache-dir',
      ...args,
    ], stdoutEncoding: lenientUtf8);
    if (r.exitCode != 0) {
      throw YtDlpException('yt-dlp 실패: ${(r.stderr as String).trim()}');
    }
    return r.stdout as String;
  }

  @override
  Future<YoutubeMedia> resolve(String url) async {
    final out = await _run(['-J', url]);
    final m = YoutubeMedia.fromInfoJson(
      jsonDecode(out) as Map<String, dynamic>,
    );
    debugPrint(
      '[captions] ${m.id} tracks=${[for (final t in m.captionTracks) '${t.lang}${t.auto ? '(auto)' : ''}']} '
      '→ original=${m.original?.lang} korean=${m.korean?.lang} language=${m.language}',
    );
    return m;
  }

  /// 채널·재생목록의 영상 목록(`--flat-playlist`). [start]부터 [end]까지 (1부터, 끝 포함).
  /// 영상마다 페이지를 열지 않아 30개에 몇 초면 된다.
  /// 업로드 날짜는 목록의 "3주 전" 같은 표시로 어림한 값(`timestamp`, 하루 단위)이다.
  @override
  Future<Map<String, dynamic>> listPlaylist(
    String url, {
    required int start,
    required int end,
  }) async {
    final out = await _run([
      '--flat-playlist',
      '--extractor-args',
      'youtubetab:approximate_date',
      '-J',
      '--playlist-start',
      '$start',
      '--playlist-end',
      '$end',
      url,
    ]);
    return jsonDecode(out) as Map<String, dynamic>;
  }

  /// 자막을 VTT 텍스트로 받는다.
  ///
  /// 자막 URL을 직접 받지 않는 이유: YouTube 자동 번역 자막 등 일부 트랙은
  /// VTT가 아니라 HLS 재생목록(m3u8)으로 내려온다. yt-dlp가 이를 처리해 준다.
  ///
  /// YouTube는 자막 요청이 몰리면 429를 돌려주므로 몇 초 쉬고 재시도한다.
  @override
  Future<String> fetchCaption(
    YoutubeMedia media,
    CaptionTrack track, {
    int retries = 2,
    Duration backoff = const Duration(seconds: 4),
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await _fetchCaptionOnce(media, track);
      } on YtDlpException catch (e) {
        if (attempt >= retries || !e.message.contains('429')) rethrow;
        await Future<void>.delayed(backoff * (attempt + 1));
      }
    }
  }

  Future<String> _fetchCaptionOnce(
    YoutubeMedia media,
    CaptionTrack track,
  ) async {
    final dir = await Directory.systemTemp.createTemp('transcue_sub_');
    try {
      await _run([
        '--skip-download',
        track.auto ? '--write-auto-subs' : '--write-subs',
        '--sub-langs',
        track.lang,
        '--sub-format',
        'vtt',
        '-o',
        '${dir.path}${Platform.pathSeparator}sub',
        youtubeWatchUrl(media.id),
      ]);
      final file = await dir
          .list()
          .where((e) => e is File && e.path.endsWith('.vtt'))
          .cast<File?>()
          .firstWhere((_) => true, orElse: () => null);
      if (file == null) {
        throw YtDlpException('자막(${track.lang})을 받지 못했습니다');
      }
      return await file.readAsString();
    } finally {
      await deleteTempDir(dir);
    }
  }
}
