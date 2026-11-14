import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('transcue/device');

/// TV(리모컨으로만 조작하는 기기)인지. Android TV·Google TV면 true.
/// 개발용: DUALCUE_TV=1 이면 데스크톱에서도 TV처럼 동작한다.
Future<bool> detectTv() async {
  if (kDebugMode && Platform.environment['DUALCUE_TV'] == '1') return true;
  if (!Platform.isAndroid) return false;
  try {
    return await _channel.invokeMethod<bool>('isTv') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// TV 리모컨으로 쓰는 메뉴 줄.
///
/// - ←/→: 버튼 사이 이동, 가운데(선택)·Enter: 누르기
/// - ↑/↓: 메뉴 밖으로 빠져나가지 않게 막는다 (보이지 않는 조작부로 포커스가 가지 않게)
/// - Esc: [onBack] (메뉴 닫기). 리모컨 뒤로 버튼은 여기서 잡지 않는다: 키 다운만 처리되고
///   키 업이 Android로 넘어가 앱이 닫힌다(실측). 화면 쪽 PopScope가 메뉴를 닫는다.
///
/// 화면 전체에 걸린 단축키(←/→ 문장 이동, Enter 재생 등)보다 먼저 처리되도록
/// 메뉴 바로 위에 단축키를 둔다. 포커스된 버튼은 굵은 테두리로 크게 보여 준다.
class TvMenu extends StatelessWidget {
  const TvMenu({super.key, required this.onBack, required this.child});

  final VoidCallback onBack;
  final Widget child;

  /// 포커스된 버튼 표시 색
  static const focusColor = Color(0xFF80DEEA);

  @override
  Widget build(BuildContext context) {
    // Theme이 아니라 IconButtonTheme으로 감싼다: 앱바가 메뉴 위에 자기 IconButtonTheme을
    // 끼워 넣어서, 버튼은 그쪽을 먼저 찾고 Theme의 iconButtonTheme은 무시한다 (TV 실측)
    final base = IconButtonTheme.of(context).style ?? const ButtonStyle();
    return IconButtonTheme(
      data: IconButtonThemeData(
        style: base.copyWith(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused)
                ? focusColor.withValues(alpha: 0.28)
                : base.backgroundColor?.resolve(s),
          ),
          side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused)
                ? const BorderSide(color: focusColor, width: 3)
                : base.side?.resolve(s),
          ),
        ),
      ),
      child: FocusTraversalGroup(
        child: Shortcuts(
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.arrowLeft):
                DirectionalFocusIntent(TraversalDirection.left),
            SingleActivator(LogicalKeyboardKey.arrowRight):
                DirectionalFocusIntent(TraversalDirection.right),
            SingleActivator(LogicalKeyboardKey.arrowUp):
                DoNothingAndStopPropagationIntent(),
            SingleActivator(LogicalKeyboardKey.arrowDown):
                DoNothingAndStopPropagationIntent(),
            SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
          },
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  onBack();
                  return null;
                },
              ),
            },
            child: child,
          ),
        ),
      ),
    );
  }
}
