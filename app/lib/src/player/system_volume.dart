import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'volume_gesture.dart' show wheelStep, volumeKeyStep;

/// 휠·키·음량 버튼으로 시스템 음량(과 화면 밝기)을 바꾸는 플랫폼인지.
/// 앱 음량이 시스템 음량과 따로 관리되면 앱에서 줄인 소리를 시스템 음량을 올려도
/// 되돌릴 수 없었다 (Windows 실측) → 앱 음량은 100으로 두고 시스템 음량만 쓴다.
/// Linux는 장치마다 방식이 달라 앱 음량을 그대로 쓴다.
bool get usesSystemVolume =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isAndroid);

/// Windows 시스템 음량 (기본 출력 장치, 0~1). 바꾼 값은 [level]로도 알린다.
class SystemVolume {
  SystemVolume._();
  static final instance = SystemVolume._();

  static const _ch = MethodChannel('transcue/volume');

  /// 마지막으로 읽거나 바꾼 값 (음소거면 표시용으로 따로 [muted])
  final level = ValueNotifier<double>(1);
  final muted = ValueNotifier<bool>(false);

  double? _target;
  DateTime _changedAt = DateTime(0);
  Future<void> _queue = Future.value();

  Future<double> refresh() async {
    try {
      final v = await _ch.invokeMethod<double>('get');
      final m = await _ch.invokeMethod<bool>('getMute');
      if (v != null) level.value = v;
      if (m != null) muted.value = m;
    } on PlatformException catch (e) {
      debugPrint('[volume] $e');
    } on MissingPluginException catch (e) {
      debugPrint('[volume] $e');
    }
    return level.value;
  }

  /// 음량을 [deltaPercent](예: +5)만큼 바꾸고 새 값(0~1)을 돌려준다.
  /// 연달아 오면 차례로 처리하고, 직전 목표값에서 이어 간다.
  Future<double> change(double deltaPercent) {
    final done = Completer<double>();
    _queue = _queue.then((_) async {
      final now = DateTime.now();
      final recent = now.difference(_changedAt).inMilliseconds < 500;
      final base = recent && _target != null ? _target! : await refresh();
      final want = ((base * 100 + deltaPercent) / 100).clamp(0.0, 1.0);
      _target = want;
      _changedAt = now;
      try {
        final got = await _ch.invokeMethod<double>('set', want) ?? want;
        level.value = got;
        if (got > 0) muted.value = false;
      } on PlatformException catch (e) {
        debugPrint('[volume] $e');
      }
      done.complete(want);
    });
    return done.future;
  }

  Future<void> toggleMute() async {
    try {
      final now = !(await _ch.invokeMethod<bool>('getMute') ?? false);
      await _ch.invokeMethod<bool>('setMute', now);
      muted.value = now;
    } on PlatformException catch (e) {
      debugPrint('[volume] $e');
    }
  }
}

/// 아래 조작부의 음량 버튼 (시스템 음량). 누르면 음소거, 위에서 휠을 굴리면 음량.
/// 키보드 음량 키 등으로 밖에서 바꾼 값도 1초마다 다시 읽어 보여 준다.
class SystemVolumeButton extends StatefulWidget {
  const SystemVolumeButton({super.key});

  @override
  State<SystemVolumeButton> createState() => _SystemVolumeButtonState();
}

class _SystemVolumeButtonState extends State<SystemVolumeButton> {
  final _vol = SystemVolume.instance;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_vol.refresh());
    _poll = Timer.periodic(
      const Duration(seconds: 1),
      (_) => unawaited(_vol.refresh()),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerSignal: (e) {
        if (e is! PointerScrollEvent) return;
        final step = wheelStep(e.scrollDelta);
        if (step == 0) return;
        GestureBinding.instance.pointerSignalResolver.register(
          e,
          (_) => unawaited(_vol.change(step * volumeKeyStep)),
        );
      },
      child: ListenableBuilder(
        listenable: Listenable.merge([_vol.level, _vol.muted]),
        builder: (context, _) {
          final v = _vol.level.value;
          final mute = _vol.muted.value || v == 0;
          final pct = (v * 100).round();
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: mute ? '음소거 해제' : '음소거 (Windows 음량 $pct)',
                color: Colors.white,
                icon: Icon(
                  mute
                      ? Icons.volume_off
                      : v < 0.5
                      ? Icons.volume_down
                      : Icons.volume_up,
                ),
                onPressed: () => unawaited(_vol.toggleMute()),
              ),
              SizedBox(
                width: 28,
                child: Text(
                  mute ? '' : '$pct',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Windows 화면 밝기 (앱 창이 있는 모니터, 0~1). 외부 모니터는 DDC/CI,
/// 노트북 내장 화면은 WMI로 바꾼다. 모니터가 지원하지 않으면 [change]가 null을
/// 돌려주고, 그때는 앱이 영상 위를 어둡게 덮는 방식으로 대신한다.
class SystemBrightness {
  SystemBrightness._();
  static final instance = SystemBrightness._();

  static const _ch = MethodChannel('transcue/brightness');

  /// 이 모니터가 밝기 조절을 지원하지 않음 (한 번 실패하면 다시 묻지 않는다)
  bool unsupported = false;

  double? _target;
  bool _sending = false;
  DateTime _changedAt = DateTime(0);
  Future<void> _queue = Future.value();

  /// 이만큼 조작이 없으면 다음에는 모니터 값을 다시 읽는다 (모니터 버튼·Windows 설정으로
  /// 바꿨을 수 있다). 조작하는 동안에는 읽지 않는다: 보낸 값이 아직 반영되기 전의
  /// 옛 값이 읽혀 표시가 0 → 50처럼 튀었다 (실측).
  static const _rereadAfter = Duration(seconds: 3);

  /// 밝기를 [delta](0~1 단위)만큼 바꾼 값. 지원하지 않으면 null.
  /// 휠 칸들은 차례로 처리하고, 모니터 명령은 느려서 마지막 값만 보낸다.
  Future<double?> change(double delta) {
    final done = Completer<double?>();
    _queue = _queue.then((_) async {
      done.complete(await _changeOnce(delta));
    });
    return done.future;
  }

  Future<double?> _changeOnce(double delta) async {
    if (unsupported) return null;
    final now = DateTime.now();
    var base = now.difference(_changedAt) < _rereadAfter || _sending
        ? _target
        : null;
    if (base == null) {
      try {
        base = await _ch.invokeMethod<double>('get');
      } on PlatformException {
        base = null;
      } on MissingPluginException {
        base = null;
      }
      if (base == null) {
        unsupported = true;
        return null;
      }
      debugPrint('[brightness] read ${(base * 100).round()}');
    }
    final want = (base + delta).clamp(0.0, 1.0);
    _target = want;
    _changedAt = now;
    unawaited(_flush());
    return want;
  }

  Future<void> _flush() async {
    if (_sending) return;
    _sending = true;
    try {
      double? sent;
      while (_target != null && _target != sent) {
        sent = _target;
        final got = await _ch.invokeMethod<double>('set', sent);
        debugPrint(
          '[brightness] set ${(sent! * 100).round()} → '
          '${got == null ? '?' : (got * 100).round()}',
        );
      }
    } on PlatformException catch (e) {
      debugPrint('[brightness] $e');
    } finally {
      _sending = false;
    }
  }
}
