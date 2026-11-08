import 'dart:math';

import 'package:dualcue/src/pipeline/subsync.dart';
import 'package:dualcue/src/subtitle/bilingual_cue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseVadSegments (centiseconds → ms)', () {
    const out = '''
Detected 2 speech segments:
Speech segment 0: start = 67.00, end = 105.00
Speech segment 1: start = 15495.00, end = 15571.50
''';
    expect(parseVadSegments(out), [(670, 1050), (154950, 155715)]);
  });

  // 불규칙한 길이의 말소리 구간 200개 (10분) + 같은 위치의 자막
  final rnd = Random(7);
  final speech = <(int, int)>[];
  var t = 2000;
  for (var i = 0; i < 200; i++) {
    final len = 600 + rnd.nextInt(2400);
    speech.add((t, t + len));
    t += len + 300 + rnd.nextInt(3000);
  }
  final cues = [
    for (final (s, e) in speech)
      BilingualCue(
        start: Duration(milliseconds: s),
        end: Duration(milliseconds: e),
        original: '$s',
        translation: 'ko$s',
      ),
  ];

  test('already in sync → no change', () {
    final r = findBestSync(cues, speech);
    expect(r.isIdentity, isTrue);
    expect(r.improves, isFalse);
  });

  test('recovers offset', () {
    final late = shiftCues(cues, const Duration(milliseconds: 4300));
    final r = findBestSync(late, speech);
    expect(r.scale, 1.0);
    expect((r.offset.inMilliseconds + 4300).abs(), lessThanOrEqualTo(20));
    expect(r.improves, isTrue);
    final fixed = applySync(late, r);
    expect(fixed.first.translation, 'ko${speech.first.$1}'); // 번역 유지
  });

  test('recovers framerate mismatch', () {
    final wrong = shiftCues(
      cues,
      const Duration(milliseconds: -800),
      scale: 25 / 23.976,
    );
    final r = findBestSync(wrong, speech);
    expect(r.scale, closeTo(23.976 / 25, 1e-9));
    final fixed = applySync(wrong, r);
    final err = (fixed.last.start - cues.last.start).inMilliseconds.abs();
    expect(err, lessThan(50));
  });

  test('shiftCues never goes negative', () {
    final s = shiftCues(cues.take(1).toList(), const Duration(hours: -1));
    expect(s.first.start, Duration.zero);
  });

  test('fitsDuration: real case 105-min subtitles on a 14-min video', () {
    BilingualCue at(int min) => BilingualCue(
      start: Duration(minutes: min),
      end: Duration(minutes: min, seconds: 2),
      original: 'x',
    );
    const video14 = Duration(minutes: 14, seconds: 7);
    expect(fitsDuration([at(1), at(105)], video14), isFalse);
    expect(fitsDuration([at(1), at(13)], video14), isTrue);
    expect(fitsDuration([at(1), at(30)], const Duration(minutes: 96)), isFalse);
    expect(fitsDuration([at(1), at(94)], const Duration(minutes: 96)), isTrue);
    expect(fitsDuration(const [], video14), isTrue);
  });
}
