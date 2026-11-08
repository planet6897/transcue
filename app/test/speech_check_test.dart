import 'package:transcue/src/pipeline/speech_check.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:flutter_test/flutter_test.dart';

BilingualCue cue(int s, String o, {String? t}) => BilingualCue(
  start: Duration(seconds: s),
  end: Duration(seconds: s + 2),
  original: o,
  translation: t,
);

void main() {
  test('단어 정규화: 대소문자·문장부호·아포스트로피', () {
    expect(speechWords("I don't KNOW, Michael!"), [
      'i',
      'dont',
      'know',
      'michael',
    ]);
  });

  final cues = [
    cue(100, "Michael, we've got a problem."),
    cue(103, 'The car is missing from the garage.'),
    cue(600, 'Completely different scene far away.'),
  ];

  test('같은 대사면 높은 일치율', () {
    final r = compareWithCues(
      speechWords("Michael we've got a problem the car is missing"),
      cues,
      const Duration(seconds: 100),
      const Duration(seconds: 130),
    );
    expect(r.pairs, 8);
    expect(r.matched, 8);
  });

  test('자막 시간이 2분 넘게 틀어져 있어도 찾음 (싱크 전)', () {
    final r = compareWithCues(
      speechWords('the car is missing from the garage'),
      cues,
      const Duration(seconds: 230),
      const Duration(seconds: 260),
    );
    expect(r.matched, r.pairs);
  });

  test('다른 대사면 낮은 일치율', () {
    final r = compareWithCues(
      speechWords('where is the secret base of the organization tonight'),
      cues,
      const Duration(seconds: 100),
      const Duration(seconds: 130),
    );
    expect(r.matched / r.pairs, lessThan(SpeechCheck.threshold));
  });

  test('멀리 떨어진 자막은 비교에서 제외', () {
    final r = compareWithCues(
      speechWords('completely different scene far away'),
      cues,
      const Duration(seconds: 100),
      const Duration(seconds: 130),
    );
    expect(r.matched, 0);
  });

  test('판단 기준 (실측 91% / 9%)', () {
    const good = SpeechCheck(matched: 133, pairs: 146, samples: 2);
    const bad = SpeechCheck(matched: 11, pairs: 122, samples: 2);
    const quiet = SpeechCheck(matched: 1, pairs: 10, samples: 1);
    expect(good.matches, isTrue);
    expect(bad.matches, isFalse);
    expect(quiet.conclusive, isFalse);
    expect(quiet.matches, isTrue, reason: '말소리가 적으면 판단하지 않고 믿는다');
    expect(good.describe(), '음성 대조 91% 일치');
  });

  test('한국어 자막 채움 비율', () {
    expect(koreanCoverage([cue(0, 'a', t: '가'), cue(5, 'b')]), 0.5);
    expect(koreanCoverage(const []), 0);
  });

  test('결과가 뚜렷하면 일찍 끝냄 (태블릿 시간 절약)', () {
    expect(isDecided(10, 20), isFalse, reason: '단어 쌍이 너무 적음');
    expect(isDecided(40, 45), isTrue, reason: '89% — 분명히 맞음');
    expect(isDecided(3, 40), isTrue, reason: '8% — 분명히 다름');
    expect(isDecided(18, 40), isFalse, reason: '45% — 애매하면 더 들어 봄');
    expect(isDecided(30, 60), isTrue, reason: '충분히 들었음');
  });
}
