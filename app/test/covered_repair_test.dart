import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/subtitle_job.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

BilingualCue cue(int s, int e) => BilingualCue(
  start: Duration(seconds: s),
  end: Duration(seconds: e),
  original: '$s',
);

void main() {
  const max = 180000; // 3분
  const total = 5000000; // 약 83분

  test('잘못 저장된 "끝까지 인식됨"에서 자막 없는 뒤쪽을 뺀다 (태블릿 실사례)', () {
    // 0~60초만 실제로 인식했는데 26초부터 영상 끝까지 인식된 것으로 저장됨
    final cues = [cue(1, 5), cue(10, 20), cue(30, 58)];
    expect(trimEmptyCovered([(0, total)], cues, max), [(0, 58000)]);
  });

  test('자막 사이 긴 빈 곳만 빼고 나머지는 남긴다', () {
    final cues = [cue(0, 10), cue(1000, 1010)];
    expect(trimEmptyCovered([(0, 1020000)], cues, max), [
      (0, 10000),
      (1000000, 1020000),
    ]);
  });

  test('짧은 빈 곳(조용한 장면)은 그대로 둔다', () {
    final cues = [cue(0, 10), cue(100, 110)];
    expect(trimEmptyCovered([(0, 120000)], cues, max), [(0, 120000)]);
  });

  test('자막이 하나도 없는 긴 구간은 통째로 뺀다', () {
    expect(trimEmptyCovered([(0, 600000)], const [], max), isEmpty);
  });
}
