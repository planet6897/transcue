import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/parakeet.dart';

void main() {
  test('실제 parakeet-cli 출력을 문장 단위 자막으로 나눈다', () {
    final lines = File('test/fixtures/parakeet_tokens.txt').readAsLinesSync();
    final cues = parseParakeetTokens(lines);
    expect(cues.map((c) => c.original).toList(), [
      'Hello there.',
      'My name is Michael Knight.',
      'I need your help tonight.',
      'Because the car is parked outside the old warehouse.',
      'We have 20 minutes before they compete.',
      'Are you ready?',
      "Let's go.",
    ]);
    expect(cues.first.start, Duration.zero);
    expect(cues[1].start, const Duration(milliseconds: 1440));
    for (var i = 0; i + 1 < cues.length; i++) {
      expect(cues[i].end <= cues[i + 1].start, isTrue);
      expect(cues[i].end > cues[i].start, isTrue);
    }
  });

  test('Android(JNI)가 돌려주는 토큰 줄도 같은 방식으로 문장이 된다', () {
    // whisper_jni.cpp nativeParakeet 출력 형식 (CLI에서 id·frame 등을 뺀 것)
    final lines = [
      '[0] t0=0 t1=8 word_start=true "▁Hello"',
      '[1] t0=8 t1=12 word_start=false "▁there"',
      '[2] t0=12 t1=14 word_start=false "."',
      '[0] t0=150 t1=160 word_start=true "▁Say"',
      '[1] t0=160 t1=170 word_start=false "▁"hi""',
      '[2] t0=170 t1=172 word_start=false "."',
      '',
    ];
    final cues = parseParakeetTokens(lines);
    expect(cues.map((c) => c.original), ['Hello there.', 'Say "hi".']);
    expect(cues[1].start, const Duration(milliseconds: 1500));
  });

  test('음성 파일을 못 읽으면 exit 0이어도 실패로 본다', () {
    // 실제 parakeet-cli 출력 (exit code 0)
    expect(
      parakeetFailed([
        'read_audio_data: trying to decode with miniaudio',
        'read_audio_data: failed to read audio data',
        "error: failed to read audio file 'C:\\no\\such.wav'",
      ]),
      isTrue,
    );
  });

  test('정상 출력은 실패가 아니다', () {
    final lines = File('test/fixtures/parakeet_tokens.txt').readAsLinesSync();
    expect(parakeetFailed(lines), isFalse);
    expect(parakeetFailed(const []), isFalse);
  });

  test('쉼표 없이 긴 말은 10초를 넘기 전에 나눈다', () {
    final lines = [
      for (var i = 0; i < 40; i++)
        '  [$i] id= 1 frame= 0 dur_idx= 4 dur_val= 4 p=1 plog=-1 '
            't0= ${i * 40} t1= ${i * 40 + 30} word_start=true "▁word"',
    ];
    final cues = parseParakeetTokens(lines);
    expect(cues.length, greaterThan(1));
    for (final c in cues) {
      expect(c.end - c.start, lessThan(const Duration(seconds: 11)));
    }
  });
}
