import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/subtitle_job.dart';

void main() {
  const sec = Duration(seconds: 1);

  test('보통 재생·일시정지·2배속은 이동이 아니다', () {
    expect(isSeek(sec, sec), isFalse);
    expect(isSeek(Duration.zero, sec), isFalse);
    expect(isSeek(sec * 2, sec), isFalse);
  });

  test('seek bar로 앞뒤로 옮기면 이동이다', () {
    expect(isSeek(const Duration(minutes: 5), sec), isTrue);
    expect(isSeek(const Duration(seconds: -30), sec), isTrue);
  });
}
