import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:transcue/src/subtitle/webvtt.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('일반 WebVTT', () {
    const vtt = '''WEBVTT
Kind: captions
Language: en

NOTE 주석

1
00:00:01.000 --> 00:00:03.500 align:start position:0%
Hello <b>there</b> &amp; welcome.

01:02.250 --> 01:04.000
How are you?
Fine.
''';
    final cues = parseWebVtt(vtt);
    expect(cues.length, 2);
    expect(cues[0].start, const Duration(seconds: 1));
    expect(cues[0].end, const Duration(milliseconds: 3500));
    expect(cues[0].original, 'Hello there & welcome.');
    expect(cues[1].start, const Duration(milliseconds: 62250));
    expect(cues[1].original, 'How are you?\nFine.');
  });

  test('YouTube 자동 자막 롤링 중복 제거', () {
    // 실제 YouTube 파일처럼 공백 한 칸짜리 줄(⎵)을 포함한다.
    final vtt =
        '''WEBVTT
Kind: captions
Language: en

00:00:00.160 --> 00:00:02.390 align:start position:0%
⎵
so<00:00:00.480><c> today</c><00:00:00.800><c> we're</c>

00:00:02.390 --> 00:00:02.400 align:start position:0%
so today we're
⎵

00:00:02.400 --> 00:00:04.950 align:start position:0%
so today we're
going<00:00:02.800><c> to</c><00:00:03.000><c> learn</c>

00:00:04.950 --> 00:00:04.960 align:start position:0%
going to learn
⎵

00:00:04.960 --> 00:00:07.000 align:start position:0%
going to learn
something<00:00:05.500><c> new</c>
'''
            .replaceAll('⎵', ' ');
    final texts = parseWebVtt(vtt).map((c) => c.original).toList();
    expect(texts, ["so today we're", 'going to learn', 'something new']);
  });

  test('번역 병합: 중간 시점 기준', () {
    const orig = [
      BilingualCue(
        start: Duration(seconds: 0),
        end: Duration(seconds: 2),
        original: 'Hi.',
      ),
      BilingualCue(
        start: Duration(seconds: 2),
        end: Duration(seconds: 5),
        original: 'Nice to meet you.',
      ),
      BilingualCue(
        start: Duration(seconds: 5),
        end: Duration(seconds: 6),
        original: 'Bye.',
      ),
    ];
    const ko = [
      BilingualCue(
        start: Duration(milliseconds: 100),
        end: Duration(milliseconds: 1900),
        original: '안녕.',
      ),
      BilingualCue(
        start: Duration(milliseconds: 1500),
        end: Duration(milliseconds: 3500),
        original: '만나서',
      ),
      BilingualCue(
        start: Duration(milliseconds: 3500),
        end: Duration(milliseconds: 4800),
        original: '반가워.',
      ),
    ];
    final merged = mergeTranslation(orig, ko);
    expect(merged.map((c) => c.translation).toList(), [
      '안녕.',
      '만나서 반가워.',
      null,
    ]);
  });
}
