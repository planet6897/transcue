import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

Duration s(double v) => Duration(milliseconds: (v * 1000).round());

BilingualCue cue(double a, double b) =>
    BilingualCue(start: s(a), end: s(b), original: '$a');

void main() {
  final cues = [cue(10, 13), cue(20, 24), cue(30, 33), cue(40, 44)];

  test('다음 문장은 시작 0.5초 앞으로 간다', () {
    expect(sentenceSeekTarget(cues, s(12), 1), s(19.5));
  });

  test('문장으로 옮겨 온 직후 다시 누르면 그다음 문장으로 간다', () {
    expect(sentenceSeekTarget(cues, s(19.5), 1), s(29.5));
  });

  test('뒤로 가면 문장 중간이어도 바로 앞 문장의 처음으로 간다', () {
    expect(sentenceSeekTarget(cues, s(42), -1), s(29.5));
    expect(sentenceSeekTarget(cues, s(32), -1), s(19.5));
    expect(sentenceSeekTarget(cues, s(30.5), -1), s(19.5));
  });

  test('연달아 뒤로 가면 한 문장씩 간다', () {
    final first = sentenceSeekTarget(cues, s(43), -1)!;
    expect(first, s(29.5));
    final second = sentenceSeekTarget(cues, first, -1)!;
    expect(second, s(19.5));
    expect(sentenceSeekTarget(cues, second, -1), s(9.5));
  });

  test('첫 문장에서 뒤로 가면 첫 문장에 머문다', () {
    expect(sentenceSeekTarget(cues, s(12), -1), s(9.5));
    expect(sentenceSeekTarget(cues, s(9.5), -1), s(9.5));
  });

  test('갈 문장이 없으면 null', () {
    expect(sentenceSeekTarget(cues, s(41), 1), isNull);
    expect(sentenceSeekTarget(cues, s(1), -1), isNull);
    expect(sentenceSeekTarget(const [], s(1), 1), isNull);
  });

  test('문장이 0.5초 안쪽에서 시작하면 0초 앞으로 가지 않는다', () {
    expect(sentenceSeekTarget([cue(0.2, 2)], Duration.zero, -1), Duration.zero);
  });

  test('첫 문장 전에서 다음으로 가면 첫 문장으로 간다', () {
    expect(sentenceSeekTarget(cues, s(1), 1), s(9.5));
  });
}
