import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/tv.dart';

void main() {
  testWidgets('TV 리모컨: ←/→로 버튼 이동, 가운데로 누르기, ↑/↓는 밖으로 안 새고, Esc는 닫기', (
    tester,
  ) async {
    final pressed = <String>[];
    var backs = 0;
    var outsideKeys = 0;
    final first = FocusNode();
    addTearDown(first.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CallbackShortcuts(
            // 화면 전체 단축키 (실제 앱: ←/→ 문장 이동, ↑/↓ 메뉴 열기, 가운데 재생)
            bindings: {
              for (final k in [
                LogicalKeyboardKey.arrowLeft,
                LogicalKeyboardKey.arrowRight,
                LogicalKeyboardKey.arrowUp,
                LogicalKeyboardKey.arrowDown,
                LogicalKeyboardKey.select,
              ])
                SingleActivator(k): () => outsideKeys++,
            },
            child: Column(
              children: [
                TvMenu(
                  onBack: () => backs++,
                  child: Row(
                    children: [
                      for (final name in ['a', 'b', 'c'])
                        IconButton(
                          focusNode: name == 'a' ? first : null,
                          tooltip: name,
                          icon: const Icon(Icons.circle),
                          onPressed: () => pressed.add(name),
                        ),
                    ],
                  ),
                ),
                // 메뉴 아래의 다른 버튼 (↓로 여기에 가면 안 된다)
                TextButton(onPressed: () {}, child: const Text('below')),
              ],
            ),
          ),
        ),
      ),
    );
    first.requestFocus();
    await tester.pump();

    Future<void> key(LogicalKeyboardKey k) async {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }

    expect(first.hasFocus, isTrue);
    await key(LogicalKeyboardKey.arrowRight);
    await key(LogicalKeyboardKey.select);
    expect(pressed, ['b']);
    await key(LogicalKeyboardKey.arrowRight);
    await key(LogicalKeyboardKey.enter);
    expect(pressed, ['b', 'c']);
    await key(LogicalKeyboardKey.arrowLeft);
    await key(LogicalKeyboardKey.arrowLeft);
    expect(first.hasFocus, isTrue);

    // ↑/↓: 메뉴에 머물고, 화면 전체 단축키로도 가지 않는다
    await key(LogicalKeyboardKey.arrowDown);
    await key(LogicalKeyboardKey.arrowUp);
    expect(first.hasFocus, isTrue);
    expect(outsideKeys, 0);

    // 닫기: DismissIntent(직접 호출)와 Esc 키. 리모컨 뒤로는 화면의 PopScope가 처리한다
    Actions.invoke(first.context!, const DismissIntent());
    await key(LogicalKeyboardKey.escape);
    expect(backs, 2);
  });

  testWidgets('앱바 안에서도 포커스된 버튼에 청록색 테두리를 그린다 (앱바의 버튼 스타일보다 우선)', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              TvMenu(
                onBack: () {},
                child: IconButton(
                  focusNode: node,
                  icon: const Icon(Icons.subtitles),
                  onPressed: () {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    BorderSide side() {
      final m = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(IconButton),
              matching: find.byType(Material),
            )
            .first,
      );
      return (m.shape as OutlinedBorder?)?.side ?? BorderSide.none;
    }

    expect(side().width, lessThan(3));
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(side().color, TvMenu.focusColor);
    expect(side().width, 3);
  });
}
