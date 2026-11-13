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

  group('steppedBrightness (데스크톱 휠)', () {
    test('한 칸에 5%씩', () {
      expect(steppedBrightness(1, -brightnessStep), closeTo(0.95, 1e-9));
      expect(steppedBrightness(0.5, brightnessStep), closeTo(0.55, 1e-9));
    });

    test('원래 밝기보다 밝아지지 않고, 완전히 까맣게 되지도 않는다', () {
      expect(steppedBrightness(1, brightnessStep), 1);
      expect(steppedBrightness(0.12, -brightnessStep), minScreenBrightness);
      expect(steppedBrightness(minScreenBrightness, -1), minScreenBrightness);
    });
  });

  test('wheelStep: 위로 굴리면 올리고 아래로 굴리면 내린다', () {
    expect(wheelStep(const Offset(0, -100)), 1);
    expect(wheelStep(const Offset(0, 53.3)), -1);
    // 가로 스크롤만 있으면 무시
    expect(wheelStep(const Offset(40, 0)), 0);
  });
}
