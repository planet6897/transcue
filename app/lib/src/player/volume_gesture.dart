import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 키 한 번에 바뀌는 음량 (0~100)
const volumeKeyStep = 5.0;

/// [current]에서 [delta]만큼 바꾼 음량. 0~100을 벗어나지 않는다.
double steppedVolume(double current, double delta) =>
    (current + delta).clamp(0.0, 100.0);

/// 화면을 위/아래로 밀어 조절 (터치 기기): 오른쪽 절반은 소리, 왼쪽 절반은 밝기.
/// 소리는 기기 미디어 음량 (볼륨 버튼과 같은 값), 밝기는 이 앱 화면만 바꾸고
/// 재생 화면을 나가면 기기 설정 밝기로 돌아간다.
/// 탭·두 번 탭·가로 밀기는 아래 조작부로 그대로 간다.
class VolumeDragLayer extends StatefulWidget {
  const VolumeDragLayer({super.key});

  @override
  State<VolumeDragLayer> createState() => _VolumeDragLayerState();
}

class _VolumeDragLayerState extends State<VolumeDragLayer> {
  static const _volumeCh = MethodChannel('transcue/volume');
  static const _brightnessCh = MethodChannel('transcue/brightness');

  MethodChannel _ch = _volumeCh; // 지금 밀고 있는 쪽
  bool _brightness = false;
  bool _brightnessChanged = false;
  double? _value; // 표시 중일 때만 값이 있다
  double _target = 0;
  Timer? _hide;
  bool _sending = false;

  Future<void> _start(DragStartDetails d, double width) async {
    _hide?.cancel();
    final brightness = d.localPosition.dx < width / 2;
    final ch = brightness ? _brightnessCh : _volumeCh;
    _value = null; // 값을 읽는 동안 들어온 이동은 무시
    final v = await ch.invokeMethod<double>('get') ?? 0.5;
    if (!mounted) return;
    setState(() {
      _ch = ch;
      _brightness = brightness;
      _value = _target = v;
    });
  }

  void _update(DragUpdateDetails d, double height) {
    if (_value == null) return;
    // 화면 높이의 70%를 밀면 0 → 최대
    _target = (_target - d.delta.dy / (height * 0.7)).clamp(0.0, 1.0);
    setState(() => _value = _target);
    if (_brightness) _brightnessChanged = true;
    _send();
  }

  /// 기기 음량은 단계(0~15 등)라서 너무 자주 보내지 않는다
  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    try {
      await _ch.invokeMethod<double>('set', _target);
    } finally {
      _sending = false;
    }
  }

  void _end(DragEndDetails _) {
    if (_value == null) return;
    unawaited(_ch.invokeMethod<double>('set', _target));
    _hide = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _value = null);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    if (_brightnessChanged) unawaited(_brightnessCh.invokeMethod('reset'));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: (d) => _start(d, box.maxWidth),
        onVerticalDragUpdate: (d) => _update(d, box.maxHeight),
        onVerticalDragEnd: _end,
        child: SizedBox.expand(
          child: _value == null
              ? null
              : Center(
                  child: VolumeIndicator(
                    value: _value!,
                    brightness: _brightness,
                  ),
                ),
        ),
      ),
    );
  }
}

/// 음량·밝기를 바꿀 때 화면 가운데에 잠깐 보여 주는 표시
class VolumeIndicator extends StatelessWidget {
  const VolumeIndicator({
    super.key,
    required this.value,
    this.brightness = false,
  });

  /// 0.0~1.0
  final double value;

  /// true면 밝기 표시
  final bool brightness;

  @override
  Widget build(BuildContext context) {
    final icon = brightness
        ? (value < 0.5 ? Icons.brightness_low : Icons.brightness_high)
        : value == 0
        ? Icons.volume_off
        : value < 0.5
        ? Icons.volume_down
        : Icons.volume_up;
    return IgnorePointer(
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 6,
                  color: const Color(0xFF80DEEA),
                  backgroundColor: Colors.white24,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 36,
              child: Text(
                '${(value * 100).round()}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
