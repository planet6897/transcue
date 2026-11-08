import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cues = [
    BilingualCue(
      start: Duration(seconds: 1),
      end: Duration(seconds: 3),
      original: 'a',
    ),
    BilingualCue(
      start: Duration(seconds: 3),
      end: Duration(seconds: 6),
      original: 'b',
    ),
    BilingualCue(
      start: Duration(seconds: 8),
      end: Duration(seconds: 9),
      original: 'c',
    ),
  ];

  test('cueAt finds the active cue', () {
    expect(cueAt(cues, const Duration(milliseconds: 500)), isNull);
    expect(cueAt(cues, const Duration(seconds: 1))?.original, 'a');
    expect(cueAt(cues, const Duration(seconds: 3))?.original, 'b');
    expect(cueAt(cues, const Duration(seconds: 7)), isNull);
    expect(cueAt(cues, const Duration(milliseconds: 8500))?.original, 'c');
    expect(cueAt(cues, const Duration(seconds: 9)), isNull);
  });

  test('cueAt with linger: +1s, but stops at the next cue', () {
    const linger = Duration(seconds: 1);
    Duration ms(int v) => Duration(milliseconds: v);
    // a: 1~3s, b: 3~6s (바로 이어짐), c: 8~9s (2초 간격)
    expect(cueAt(cues, ms(2999), linger: linger)?.original, 'a');
    expect(
      cueAt(cues, ms(3000), linger: linger)?.original,
      'b',
    ); // 다음 자막이 시작하면 교체
    expect(cueAt(cues, ms(6500), linger: linger)?.original, 'b'); // 끝난 뒤 1초 더
    expect(cueAt(cues, ms(6999), linger: linger)?.original, 'b');
    expect(cueAt(cues, ms(7000), linger: linger), isNull);
    expect(
      cueAt(cues, ms(9900), linger: linger)?.original,
      'c',
    ); // 마지막 자막도 1초 더
    expect(cueAt(cues, ms(10000), linger: linger), isNull);
    expect(cueAt(cues, ms(500), linger: linger), isNull);
  });

  test('cueAt with linger: gap shorter than 1s ends at next start', () {
    const close = [
      BilingualCue(
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        original: 'x',
      ),
      BilingualCue(
        start: Duration(milliseconds: 2400),
        end: Duration(seconds: 4),
        original: 'y',
      ),
    ];
    const linger = Duration(seconds: 1);
    expect(
      cueAt(
        close,
        const Duration(milliseconds: 2300),
        linger: linger,
      )?.original,
      'x',
    );
    expect(
      cueAt(
        close,
        const Duration(milliseconds: 2400),
        linger: linger,
      )?.original,
      'y',
    );
  });
}
