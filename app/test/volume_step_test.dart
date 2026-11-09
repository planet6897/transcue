import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/volume_gesture.dart';

void main() {
  group('steppedVolume', () {
    test('한 번에 정해진 만큼 바뀐다', () {
      expect(steppedVolume(50, volumeKeyStep), 55);
      expect(steppedVolume(50, -volumeKeyStep), 45);
    });

    test('0~100을 벗어나지 않는다', () {
      expect(steppedVolume(98, volumeKeyStep), 100);
      expect(steppedVolume(100, volumeKeyStep), 100);
      expect(steppedVolume(2, -volumeKeyStep), 0);
      expect(steppedVolume(0, -volumeKeyStep), 0);
    });
  });
}
