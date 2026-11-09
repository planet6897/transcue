import 'dart:convert';
import 'dart:io';

import '../pipeline/tools.dart';
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
  });

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
      duration: info['duration'] is num
          ? Duration(milliseconds: ((info['duration'] as num) * 1000).round())
          : null,
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

  Future<String?> locate() async => executable ?? await locateTool('yt-dlp');

  Future<String> _exe() async {
    final exe = await locate();
    if (exe == null) {
      throw const YtDlpException(
        'yt-dlp를 찾을 수 없습니다.\n'
        'macOS: brew install yt-dlp\nWindows: winget install yt-dlp',
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

  Future<YoutubeMedia> resolve(String url) async {
    final out = await _run(['-J', url]);
    return YoutubeMedia.fromInfoJson(jsonDecode(out) as Map<String, dynamic>);
  }

  /// 자막을 VTT 텍스트로 받는다.
  ///
  /// 자막 URL을 직접 받지 않는 이유: YouTube 자동 번역 자막 등 일부 트랙은
  /// VTT가 아니라 HLS 재생목록(m3u8)으로 내려온다. yt-dlp가 이를 처리해 준다.
  ///
  /// YouTube는 자막 요청이 몰리면 429를 돌려주므로 몇 초 쉬고 재시도한다.
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
