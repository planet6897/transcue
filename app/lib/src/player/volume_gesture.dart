import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 화면을 위로 밀면 소리 크게, 아래로 밀면 작게 (터치 기기).
/// 기기 미디어 음량을 바꾼다 (볼륨 버튼과 같은 값). 탭·두 번 탭·가로 밀기는 아래 조작부로 그대로 간다.
class VolumeDragLayer extends StatefulWidget {
  const VolumeDragLayer({super.key});

  @override
  State<VolumeDragLayer> createState() => _VolumeDragLayerState();
}

class _VolumeDragLayerState extends State<VolumeDragLayer> {
  static const _ch = MethodChannel('transcue/volume');

  double? _volume; // 표시 중일 때만 값이 있다
  double _target = 0;
  Timer? _hide;
  bool _sending = false;

  Future<void> _start(DragStartDetails _) async {
    _hide?.cancel();
    final v = await _ch.invokeMethod<double>('get') ?? 0.5;
    setState(() => _volume = _target = v);
  }

  void _update(DragUpdateDetails d, double height) {
    if (_volume == null) return;
    // 화면 높이의 70%를 밀면 0 → 최대
    _target = (_target - d.delta.dy / (height * 0.7)).clamp(0.0, 1.0);
    setState(() => _volume = _target);
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
    unawaited(_ch.invokeMethod<double>('set', _target));
    _hide = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _volume = null);
    });
  }

  @override
  void dispose() {
    _hide?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onVerticalDragStart: _start,
        onVerticalDragUpdate: (d) => _update(d, box.maxHeight),
        onVerticalDragEnd: _end,
        child: SizedBox.expand(
          child: _volume == null
              ? null
              : Center(child: _VolumeIndicator(value: _volume!)),
        ),
      ),
    );
  }
}

class _VolumeIndicator extends StatelessWidget {
  const _VolumeIndicator({required this.value});
  final double value;

  @override
  Widget build(BuildContext context) {
    final icon = value == 0
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
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
