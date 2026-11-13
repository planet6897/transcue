import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
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

  group('TrackpadSteps (트랙패드 두 손가락 밀기)', () {
    test('40픽셀마다 한 칸, 남은 거리는 다음 이동에 더한다', () {
      final t = TrackpadSteps();
      // 위로 (dy −) 조금씩
      expect(t.add(-15), 0);
      expect(t.add(-15), 0);
      expect(t.add(-15), 1); // 45
      expect(t.add(-35), 1); // 5 + 35 = 40
      expect(t.add(-130), 3); // 130 → 3칸, 10 남음
      // 방향을 바꾸면 남은 것부터 빠진다
      expect(t.add(30), 0); // 10 − 30 = −20
      expect(t.add(25), -1); // −45
    });

    test('새로 밀기 시작하면 남은 거리를 버린다', () {
      final t = TrackpadSteps()..add(-39);
      t.reset();
      expect(t.add(-5), 0);
    });
  });

  testWidgets('트랙패드 팬 이벤트가 Listener에 온다 (손가락을 위로 밀면 dy −)', (tester) async {
    final dys = <double>[];
    await tester.pumpWidget(
      Listener(
        behavior: HitTestBehavior.opaque,
        onPointerPanZoomUpdate: (e) => dys.add(e.panDelta.dy),
        child: const SizedBox.expand(),
      ),
    );
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(
      pointer.panZoomStart(const Offset(400, 300)),
    );
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(const Offset(400, 300), pan: const Offset(0, -20)),
    );
    await tester.sendEventToBinding(
      pointer.panZoomUpdate(const Offset(400, 300), pan: const Offset(0, -50)),
    );
    await tester.sendEventToBinding(pointer.panZoomEnd());
    expect(dys, [-20, -30]);
    final t = TrackpadSteps();
    expect(dys.map(t.add).fold(0, (a, b) => a + b), 1);
  });
}
