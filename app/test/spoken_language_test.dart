import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/subtitle_job.dart';
import 'package:transcue/src/pipeline/whisper.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

void main() {
  group('mergeSpokenLang', () {
    test('처음 감지한 언어를 쓴다', () {
      expect(mergeSpokenLang(null, 'zh'), 'zh');
    });

    test('같은 언어가 이어지면 그대로다', () {
      expect(mergeSpokenLang('ja', 'ja'), 'ja');
    });

    test('언어가 바뀌면 혼합으로 본다', () {
      expect(mergeSpokenLang('zh', 'ja'), 'auto');
      expect(mergeSpokenLang('auto', 'ja'), 'auto');
    });
  });

  group('parseDetectedLanguage', () {
    test('언어와 확신도를 읽는다', () {
      final r = parseDetectedLanguage(
        'whisper_full_with_state: auto-detected language: ja (p = 0.867253)',
      );
      expect(r?.$1, 'ja');
      expect(r?.$2, closeTo(0.867, 0.001));
    });

    test('다른 로그는 무시한다', () {
      expect(parseDetectedLanguage('progress = 10%'), isNull);
    });
  });

  group('shouldRetryLanguage', () {
    test('확신이 낮고 직전 언어와 다르면 다시 인식한다', () {
      expect(shouldRetryLanguage('ko', 0.70, 'ja'), isTrue);
    });

    test('확신이 높으면 언어가 바뀐 것으로 본다', () {
      expect(shouldRetryLanguage('ja', 0.87, 'zh'), isFalse);
    });

    test('직전 언어와 같거나 직전 언어가 없으면 그대로 쓴다', () {
      expect(shouldRetryLanguage('ja', 0.49, 'ja'), isFalse);
      expect(shouldRetryLanguage('ko', 0.40, null), isFalse);
    });
  });

  group('isMostlyKorean', () {
    test('한국어 문장', () {
      expect(isMostlyKorean('안녕하세요, 반갑습니다.'), isTrue);
      expect(isMostlyKorean('OK 알겠습니다'), isTrue);
    });

    test('다른 언어 문장', () {
      expect(isMostlyKorean('今日はいい天気ですね'), isFalse);
      expect(isMostlyKorean('你好,很高兴见到你'), isFalse);
      expect(isMostlyKorean('Hello there'), isFalse);
    });

    test('글자가 없으면 아니다', () {
      expect(isMostlyKorean('...!?'), isFalse);
      expect(isMostlyKorean(''), isFalse);
    });
  });
}
