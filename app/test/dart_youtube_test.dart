import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/source/dart_youtube.dart';
import 'package:transcue/src/source/yt_dlp.dart';
import 'package:transcue/src/subtitle/webvtt.dart';

void main() {
  test('자막 XML(srv1) → WebVTT: 두 번 감싼 엔티티도 푼다', () {
    // 실제 응답 앞부분 (TED f5RqYHd2cBQ, 영어)
    const xml =
        '<?xml version="1.0" encoding="utf-8" ?><transcript>'
        '<text start="3.504" dur="3.75">Today we&amp;#39;re going to learn about</text>'
        '<text start="7.254" dur="2.1">cities &amp;amp; &lt;b&gt;people&lt;/b&gt;</text>'
        '<text start="9.5" dur="1">   </text>'
        '<text start="3700.25">last line</text>'
        '</transcript>';
    final vtt = transcriptToVtt(xml);
    expect(vtt, startsWith('WEBVTT'));
    final cues = parseWebVtt(vtt);
    expect(cues.map((c) => c.original).toList(), [
      "Today we're going to learn about",
      'cities & people',
      'last line',
    ]);
    expect(cues.first.start, const Duration(milliseconds: 3504));
    expect(cues.first.end, const Duration(milliseconds: 7254));
    // dur가 없으면 2초
    expect(cues.last.start, const Duration(milliseconds: 3700250));
    expect(cues.last.end, const Duration(milliseconds: 3702250));
  });

  group('자막 고르기', () {
    CaptionTrack t(String lang, {bool auto = false}) =>
        CaptionTrack(lang: lang, url: 'u-$lang-$auto', auto: auto);

    test('사람이 단 영어 + 사람이 단 한국어', () {
      final (o, k, lang) = pickCaptions([
        t('ar'),
        t('en'),
        t('ko'),
        t('en', auto: true),
      ]);
      expect(o?.url, 'u-en-false');
      expect(k?.url, 'u-ko-false');
      expect(lang, 'en');
    });

    test('사람이 단 자막이 없으면 자동 자막(음성 언어), 한국어는 없음', () {
      final (o, k, lang) = pickCaptions([t('en', auto: true)]);
      expect(o?.auto, isTrue);
      expect(k, isNull);
      expect(lang, 'en');
    });

    test('영상이 한국어면 한국어 자막을 따로 받지 않는다', () {
      final (o, k, lang) = pickCaptions([t('ko'), t('ko', auto: true)]);
      expect(o?.lang, 'ko');
      expect(k, isNull);
      expect(lang, 'ko');
    });

    test('자막이 전혀 없으면 둘 다 없음 (음성 인식으로)', () {
      expect(pickCaptions(const []), (null, null, null));
    });
  });
}
