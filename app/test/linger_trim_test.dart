import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

BilingualCue cue(int startMs, int endMs, String text) => BilingualCue(
  start: Duration(milliseconds: startMs),
  end: Duration(milliseconds: endMs),
  original: text,
  translation: '번역',
);

void main() {
  test('짧은 일본어 문장이 다음 문장까지 늘어진 끝을 줄인다', () {
    // 5글자(구두점 제외) → 말 0.8초 → 1.4배 + 0.8초 = 1.92초
    final c = trimLingeringEnd(cue(10000, 18000, 'そうですね。'));
    expect(c.end, const Duration(milliseconds: 11920));
    expect(c.translation, '번역');
  });

  test('말하는 시간에 맞는 끝은 그대로 둔다', () {
    final c = cue(0, 2500, 'I think we should go home now.');
    expect(trimLingeringEnd(c).end, c.end);
  });

  test('아주 짧은 말도 최소 1.5초는 보여 준다', () {
    expect(
      trimLingeringEnd(cue(0, 6000, 'Oh.')).end,
      const Duration(milliseconds: 1500),
    );
  });
}
