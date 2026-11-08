import 'package:dualcue/src/source/youtube_url.dart';
import 'package:dualcue/src/source/yt_dlp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseYoutubeId', () {
    const id = 'dQw4w9WgXcQ';
    for (final url in [
      id,
      'https://www.youtube.com/watch?v=$id',
      'https://youtube.com/watch?v=$id&t=42s&list=PL123',
      'youtube.com/watch?v=$id',
      'https://m.youtube.com/watch?v=$id',
      'https://music.youtube.com/watch?v=$id',
      'https://youtu.be/$id?si=abc',
      'https://www.youtube.com/shorts/$id',
      'https://www.youtube.com/embed/$id',
      'https://www.youtube.com/live/$id',
      'https://www.youtube-nocookie.com/embed/$id',
    ]) {
      test(url, () => expect(parseYoutubeId(url), id));
    }
    for (final bad in [
      '',
      'https://vimeo.com/12345678901',
      'https://www.youtube.com/watch?v=short',
      'https://www.youtube.com/@channel',
      'https://notyoutube.com/watch?v=$id',
    ]) {
      test('rejects "$bad"', () => expect(parseYoutubeId(bad), isNull));
    }
  });

  group('YoutubeMedia.fromInfoJson', () {
    Map<String, dynamic> fmt(
      String id, {
      int? h,
      String v = 'none',
      String a = 'none',
      num tbr = 100,
      String protocol = 'https',
    }) => {
      'format_id': id,
      'url': 'https://cdn/$id',
      'protocol': protocol,
      'height': h,
      'vcodec': v,
      'acodec': a,
      'tbr': tbr,
      'http_headers': {'User-Agent': 'UA'},
    };

    List<Map<String, String>> subs(String lang) => [
      {'ext': 'json3', 'url': 'https://subs/$lang.json3'},
      {'ext': 'vtt', 'url': 'https://subs/$lang.vtt'},
    ];

    final info = <String, dynamic>{
      'id': 'abc',
      'title': 'Sample',
      'language': 'en',
      'formats': [
        fmt('sb0', protocol: 'mhtml', h: 90, v: 'images'),
        fmt('18', h: 360, v: 'avc1', a: 'mp4a'),
        fmt('140', a: 'mp4a', tbr: 129),
        fmt('251', a: 'opus', tbr: 140),
        fmt('137', h: 1080, v: 'avc1', tbr: 4000),
        fmt('271', h: 1440, v: 'vp9', tbr: 9000),
        fmt('248', h: 1080, v: 'vp9', tbr: 2500),
      ],
      'subtitles': {'live_chat': subs('live_chat')},
      'automatic_captions': {
        'en-orig': subs('en-orig'),
        'en': subs('en'),
        'ko': subs('ko'),
        'ja': subs('ja'),
      },
    };

    test('고화질 영상 + 별도 음성 선택, 1080p 제한', () {
      final m = YoutubeMedia.fromInfoJson(info);
      expect(m.videoUrl, 'https://cdn/137');
      expect(m.audioUrl, 'https://cdn/251');
      expect(m.httpHeaders, {'User-Agent': 'UA'});
      expect(m.title, 'Sample');
    });

    test('자동 자막: 원어는 -orig, 한국어는 자동 번역', () {
      final m = YoutubeMedia.fromInfoJson(info);
      expect(m.original?.url, 'https://subs/en-orig.vtt');
      expect(m.original?.auto, isTrue);
      expect(m.korean?.url, 'https://subs/ko.vtt');
    });

    test('수동 자막이 있으면 우선', () {
      final m = YoutubeMedia.fromInfoJson({
        ...info,
        'subtitles': {'en-US': subs('en-US'), 'ko': subs('ko-manual')},
      });
      expect(m.original?.url, 'https://subs/en-US.vtt');
      expect(m.original?.auto, isFalse);
      expect(m.korean?.url, 'https://subs/ko-manual.vtt');
      expect(m.korean?.auto, isFalse);
    });

    test('HLS 영상 + HLS 음성 우선 (H.264, high 음성)', () {
      final m = YoutubeMedia.fromInfoJson({
        ...info,
        'formats': [
          ...(info['formats'] as List),
          fmt('609', h: 720, v: 'vp09', protocol: 'm3u8_native'),
          fmt('232', h: 720, v: 'avc1', protocol: 'm3u8_native'),
          fmt('231', h: 480, v: 'avc1', protocol: 'm3u8_native'),
          {
            ...fmt('233', protocol: 'm3u8_native'),
            'acodec': null,
            'format_note': 'Default, low',
          },
          {
            ...fmt('234', protocol: 'm3u8_native'),
            'acodec': null,
            'format_note': 'Default, high',
          },
        ],
      });
      expect(m.videoUrl, 'https://cdn/232');
      expect(m.audioUrl, 'https://cdn/234');
    });

    test('분리 포맷이 없으면 영상+음성 통합 포맷', () {
      final m = YoutubeMedia.fromInfoJson({
        ...info,
        'formats': [fmt('18', h: 360, v: 'avc1', a: 'mp4a')],
      });
      expect(m.videoUrl, 'https://cdn/18');
      expect(m.audioUrl, isNull);
    });

    test('한국어 영상이면 번역 트랙 없음', () {
      final m = YoutubeMedia.fromInfoJson({
        ...info,
        'language': 'ko',
        'automatic_captions': {'ko-orig': subs('ko-orig'), 'en': subs('en')},
      });
      expect(m.original?.url, 'https://subs/ko-orig.vtt');
      expect(m.korean, isNull);
    });

    test('재생 가능한 포맷이 없으면 예외', () {
      expect(
        () => YoutubeMedia.fromInfoJson({'id': 'x', 'formats': []}),
        throwsFormatException,
      );
    });
  });
}
