import 'package:dualcue/src/subtitle/bilingual_cue.dart';
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
}
