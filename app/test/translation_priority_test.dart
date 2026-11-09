import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

void main() {
  BilingualCue cue(int a, int b, String o) => BilingualCue(
    start: Duration(seconds: a),
    end: Duration(seconds: b),
    original: o,
  );

  group('isBrokenKorean', () {
    test('CP949를 라틴 문자로 읽은 줄은 깨진 것으로 본다', () {
      final broken = latin1.decode([
        0xBE,
        0xC8,
        0xB3,
        0xE7,
        0xC7,
        0xCF,
        0xBC,
        0xBC,
      ]);
      expect(isBrokenKorean(broken), isTrue);
    });

    test('대체 문자만 있는 줄도 깨진 것으로 본다', () {
      expect(isBrokenKorean('��'), isTrue);
    });

    test('정상 한국어와 영어 줄은 깨지지 않았다', () {
      expect(isBrokenKorean('안녕하세요'), isFalse);
      expect(isBrokenKorean('카페 Café'), isFalse);
      expect(isBrokenKorean('FBI'), isFalse);
      expect(isBrokenKorean('♪ ♪'), isFalse);
    });
  });

  group('임시 번역', () {
    final temp = cue(1, 3, 'Hello').withTranslation('안녕', provisional: true);

    test('AI 번역을 넣으면 임시 표시가 사라진다', () {
      final ai = temp.withTranslation('안녕하세요');
      expect(ai.translation, '안녕하세요');
      expect(ai.provisional, isFalse);
    });

    test('시간 보정과 학습 단어 변경에도 임시 표시가 유지된다', () {
      expect(temp.withTimes(Duration.zero, temp.end).provisional, isTrue);
      expect(temp.withWords(const []).provisional, isTrue);
    });

    test('저장 후 다시 읽어도 임시 표시가 유지된다', () {
      final j = jsonDecode(jsonEncode(temp.toJson())) as Map<String, dynamic>;
      expect(BilingualCue.fromJson(j).provisional, isTrue);
    });

    test('일반 번역은 저장 형식이 그대로다', () {
      final plain = cue(1, 3, 'Hi').withTranslation('안녕');
      expect(plain.toJson().containsKey('p'), isFalse);
      expect(BilingualCue.fromJson(plain.toJson()).provisional, isFalse);
    });
  });
}
