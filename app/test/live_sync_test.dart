import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/subsync.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

BilingualCue cue(int startMs, int endMs) => BilingualCue(
  start: Duration(milliseconds: startMs),
  end: Duration(milliseconds: endMs),
  original: 'line $startMs',
);

void main() {
  // 불규칙한 간격의 말소리 (규칙적이면 다른 위치에서도 잘 맞아 버린다)
  const speech = <(int, int)>[
    (1000, 3000),
    (4200, 7000),
    (9500, 11000),
    (12500, 16000),
    (19000, 20500),
    (22000, 26000),
  ];
  List<BilingualCue> shifted(int ms) => [
    for (final (a, b) in speech) cue(a + ms, b + ms),
  ];

  test('자막이 늦으면 앞당기는 값을 잰다', () {
    final o = estimateLocalOffset(shifted(2000), speech)!;
    expect((o.inMilliseconds + 2000).abs(), lessThan(150));
  });

  test('자막이 빠르면 늦추는 값을 잰다', () {
    final o = estimateLocalOffset(shifted(-1500), speech)!;
    expect((o.inMilliseconds - 1500).abs(), lessThan(150));
  });

  test('이미 맞으면 보정하지 않는다', () {
    expect(estimateLocalOffset(shifted(0), speech), isNull);
  });

  test('자막이 3줄 미만이면 판단하지 않는다', () {
    expect(estimateLocalOffset(shifted(2000).take(2).toList(), speech), isNull);
  });

  test('말소리가 없으면 판단하지 않는다', () {
    expect(estimateLocalOffset(shifted(2000), const []), isNull);
  });

  group('LiveSyncTracker', () {
    const a = Duration(milliseconds: -2000);
    const near = Duration(milliseconds: -1800);
    const far = Duration(milliseconds: 1000);

    test('두 번 연속 비슷해야 적용한다', () {
      final t = LiveSyncTracker();
      expect(t.add(a), isNull);
      expect(t.add(near), near);
    });

    test('값이 튀면 적용하지 않고 새로 센다', () {
      final t = LiveSyncTracker();
      expect(t.add(a), isNull);
      expect(t.add(far), isNull);
      expect(t.add(far), far);
    });

    test('중간에 판단 불가가 끼면 처음부터 센다', () {
      final t = LiveSyncTracker();
      expect(t.add(a), isNull);
      expect(t.add(null), isNull);
      expect(t.add(a), isNull);
    });

    test('적용 뒤와 reset 뒤에는 다시 두 번 필요하다', () {
      final t = LiveSyncTracker();
      t.add(a);
      expect(t.add(a), a);
      expect(t.add(a), isNull);
      t.reset();
      expect(t.add(a), isNull);
    });
  });

  group('shiftCuesFrom', () {
    test('기준 시각 이후의 자막만 옮기고 번역을 유지한다', () {
      final cues = [cue(1000, 2000), cue(5000, 6000).withTranslation('번역')];
      final out = shiftCuesFrom(
        cues,
        const Duration(seconds: 3),
        const Duration(seconds: 1),
      );
      expect(out[0].start, const Duration(seconds: 1));
      expect(out[1].start, const Duration(seconds: 6));
      expect(out[1].translation, '번역');
    });

    test('앞당겨서 순서가 바뀌면 시간순으로 다시 정렬한다', () {
      final out = shiftCuesFrom(
        [cue(4000, 5000), cue(5000, 6000)],
        const Duration(milliseconds: 4500),
        const Duration(seconds: -2),
      );
      expect(out.map((c) => c.start.inSeconds).toList(), [3, 4]);
    });
  });
}
