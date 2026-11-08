import 'dart:convert';
import 'dart:io';

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
  });

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
    final formats = (info['formats'] as List? ?? [])
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

    Map<String, dynamic>? video, audio;
    if (videoOnly.isNotEmpty &&
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

    final language = info['language'] as String?;
    final manual = _tracks(info['subtitles'], auto: false);
    final auto = _tracks(info['automatic_captions'], auto: true);

    CaptionTrack? pick(Map<String, CaptionTrack> m, bool Function(String) ok) {
      for (final e in m.entries) {
        if (ok(e.key)) return e.value;
      }
      return null;
    }

    bool isLang(String key, String lang) =>
        key == lang || key.startsWith('$lang-');
    final orig = language ?? 'en';
    // 자동 자막의 '<lang>-orig'는 원본 음성 인식 결과 (자동 번역이 아님)
    final original =
        pick(manual, (k) => isLang(k, orig)) ??
        auto['$orig-orig'] ??
        auto[orig] ??
        (language == null && manual.isNotEmpty ? manual.values.first : null);
    final korean = orig == 'ko'
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
class YtDlp {
  YtDlp({this.executable});

  /// 명시 경로. null이면 [locate]로 찾는다.
  final String? executable;

  static const _candidates = [
    '/opt/homebrew/bin/yt-dlp', // macOS GUI 앱은 셸 PATH를 물려받지 않는다
    '/usr/local/bin/yt-dlp',
  ];

  Future<String?> locate() async {
    if (executable != null) return executable;
    for (final p in _candidates) {
      if (await File(p).exists()) return p;
    }
    try {
      final r = await Process.run(Platform.isWindows ? 'where' : 'which', [
        'yt-dlp',
      ]);
      if (r.exitCode == 0) {
        return (r.stdout as String).split(RegExp(r'\r?\n')).first.trim();
      }
    } on ProcessException {
      // 무시
    }
    return null;
  }

  Future<YoutubeMedia> resolve(String url) async {
    final exe = await locate();
    if (exe == null) {
      throw const YtDlpException(
        'yt-dlp를 찾을 수 없습니다.\n'
        'macOS: brew install yt-dlp\nWindows: winget install yt-dlp',
      );
    }
    final r = await Process.run(exe, [
      '-J',
      '--no-playlist',
      '--no-warnings',
      '--no-cache-dir',
      url,
    ], stdoutEncoding: utf8);
    if (r.exitCode != 0) {
      throw YtDlpException('yt-dlp 실패: ${(r.stderr as String).trim()}');
    }
    return YoutubeMedia.fromInfoJson(
      jsonDecode(r.stdout as String) as Map<String, dynamic>,
    );
  }
}

/// 자막 파일(VTT) 텍스트를 내려받는다.
Future<String> fetchText(String url) async {
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    }
    return await res.transform(utf8.decoder).join();
  } finally {
    client.close();
  }
}
