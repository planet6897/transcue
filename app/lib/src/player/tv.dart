import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('transcue/device');

/// TV(리모컨으로만 조작하는 기기)인지. Android TV·Google TV면 true.
/// 개발용: DUALCUE_TV=1 이면 데스크톱에서도 TV처럼 동작한다.
Future<bool> detectTv() async => tvDevice = await _detectTv();

/// [detectTv]가 알아낸 값. 재생 화면 밖(대화상자의 [TvTextField] 등)에서 본다.
bool tvDevice = false;

Future<bool> _detectTv() async {
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

/// TV 리모컨으로 지나갈 수 있는 입력란.
///
/// 입력란은 포커스를 받으면 바로 화면 키보드가 뜨고, 방향키를 커서 이동에 써서
/// 리모컨으로는 다음 항목으로 넘어갈 수 없다. 그래서 TV에서는 두 단계로 나눈다.
///
/// - 방향키로 왔을 때는 테두리만 표시하고 지나갈 수 있다 (키보드가 뜨지 않는다)
/// - 가운데(선택)·Enter를 누르면 입력을 시작한다 (키보드가 뜬다)
/// - 입력 중 ↑/↓, 또는 글 맨 앞에서 ←·맨 뒤에서 →를 누르면 입력을 끝내고 그쪽으로 옮긴다
///
/// TV가 아니면 [builder]가 만든 입력란을 그대로 쓴다. [builder]는 받은 포커스 노드를
/// 입력란에 넘겨야 한다.
class TvTextField extends StatefulWidget {
  const TvTextField({
    super.key,
    required this.controller,
    required this.builder,
  });

  final TextEditingController controller;
  final Widget Function(FocusNode focusNode) builder;

  @override
  State<TvTextField> createState() => _TvTextFieldState();
}

class _TvTextFieldState extends State<TvTextField> {
  final _outer = FocusNode(debugLabel: 'TvTextField');
  final _field = FocusNode(debugLabel: 'TvTextField input');
  var _editing = false;

  @override
  void initState() {
    super.initState();
    _outer.addListener(() => setState(() {}));
    _field.addListener(() {
      // 검색 실행 등으로 입력란이 포커스를 놓으면 지나가는 상태로 돌아온다
      if (_editing && !_field.hasFocus) _stop();
    });
  }

  @override
  void dispose() {
    _outer.dispose();
    _field.dispose();
    super.dispose();
  }

  void _stop() {
    if (!mounted) return;
    setState(() => _editing = false);
    _outer.requestFocus();
  }

  static bool _isSelect(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter;

  KeyEventResult _onOuterKey(FocusNode _, KeyEvent e) {
    if (_editing || e is! KeyDownEvent || !_isSelect(e.logicalKey)) {
      return KeyEventResult.ignored;
    }
    setState(() => _editing = true);
    // 입력란이 포커스를 받을 수 있게 된 다음(다음 프레임)에 넘긴다
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing) _field.requestFocus();
    });
    return KeyEventResult.handled;
  }

  KeyEventResult _onFieldKey(FocusNode _, KeyEvent e) {
    if (!_editing || e is KeyUpEvent) return KeyEventResult.ignored;
    final sel = widget.controller.selection;
    final at = sel.isValid && sel.isCollapsed ? sel.baseOffset : null;
    final k = e.logicalKey;
    final dir = k == LogicalKeyboardKey.arrowUp
        ? TraversalDirection.up
        : k == LogicalKeyboardKey.arrowDown
        ? TraversalDirection.down
        : k == LogicalKeyboardKey.arrowLeft && (at == 0 || !sel.isValid)
        ? TraversalDirection.left
        : k == LogicalKeyboardKey.arrowRight &&
              (at == widget.controller.text.length || !sel.isValid)
        ? TraversalDirection.right
        : null;
    if (dir == null) return KeyEventResult.ignored;
    _stop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _outer.focusInDirection(dir);
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (!tvDevice) return widget.builder(_field);
    return Focus(
      focusNode: _outer,
      onKeyEvent: _onOuterKey,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _outer.hasPrimaryFocus
              ? Border.all(color: TvMenu.focusColor, width: 3)
              : null,
          borderRadius: BorderRadius.circular(4),
        ),
        child: ExcludeFocus(
          excluding: !_editing,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onFieldKey,
            child: widget.builder(_field),
          ),
        ),
      ),
    );
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
