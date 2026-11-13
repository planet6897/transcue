import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/volume_gesture.dart';

void main() {
  test('기기 음량은 휠 한 칸에 한 단계(1/15), 밝기는 5%', () {
    expect(
      deviceWheelTarget(7 / 15, 1, brightness: false),
      closeTo(8 / 15, 1e-9),
    );
    expect(deviceWheelTarget(0.5, -1, brightness: true), closeTo(0.45, 1e-9));
    expect(deviceWheelTarget(1, 1, brightness: false), 1);
    expect(deviceWheelTarget(0.02, -1, brightness: true), 0);
  });

  testWidgets('마우스 휠: 오른쪽은 기기 음량, 왼쪽은 밝기 (차례로 처리)', (tester) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // 기기 음량은 15단계로 맞춰지고, 밝기는 그대로 저장된다
    var volume = 7 / 15;
    var brightness = 0.5;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(const MethodChannel('transcue/volume'), (
      c,
    ) async {
      if (c.method == 'set') {
        volume = ((c.arguments as double) * 15).round() / 15;
      }
      calls.add('volume.${c.method}');
      return volume;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('transcue/brightness'),
      (c) async {
        if (c.method == 'set') brightness = c.arguments as double;
        calls.add('brightness.${c.method}');
        return c.method == 'get' ? brightness : null;
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('transcue/volume'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('transcue/brightness'),
        null,
      );
    });

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: VolumeDragLayer())),
    );
    final size = tester.getSize(find.byType(VolumeDragLayer));

    Future<void> wheel(double x, double dy) async {
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: Offset(x, size.height / 2),
          scrollDelta: Offset(0, dy),
        ),
      );
      await tester.pump();
    }

    // 오른쪽에서 위로 세 칸 (빠르게 연달아)
    await wheel(size.width * 0.8, -100);
    await wheel(size.width * 0.8, -100);
    await wheel(size.width * 0.8, -100);
    await tester.pumpAndSettle();
    expect(volume, closeTo(10 / 15, 1e-9));
    expect(find.text('67'), findsOneWidget); // 10/15

    // 왼쪽에서 아래로 두 칸
    await wheel(size.width * 0.2, 100);
    await wheel(size.width * 0.2, 100);
    await tester.pumpAndSettle();
    expect(brightness, closeTo(0.4, 1e-9));
    expect(find.byIcon(Icons.brightness_low), findsOneWidget);

    // 표시가 떠 있는 동안 같은 쪽은 기기 값을 다시 읽지 않고 이어서 바꾼다
    expect(calls.where((c) => c == 'volume.get').length, 1);
    expect(calls.where((c) => c == 'volume.set').length, 3);
    expect(calls.where((c) => c == 'brightness.get').length, 1);

    // 표시는 잠시 뒤 사라진다
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(VolumeIndicator), findsNothing);
  });
}
