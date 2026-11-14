import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/tv.dart';

void main() {
  tearDown(() => tvDevice = false);

  Future<(FocusNode, FocusNode, TextEditingController)> pump(
    WidgetTester tester,
  ) async {
    final above = FocusNode();
    final below = FocusNode();
    final text = TextEditingController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: above,
                onPressed: () {},
                child: const Text('위'),
              ),
              TvTextField(
                controller: text,
                builder: (focus) =>
                    TextField(focusNode: focus, controller: text),
              ),
              TextButton(
                focusNode: below,
                onPressed: () {},
                child: const Text('아래'),
              ),
            ],
          ),
        ),
      ),
    );
    above.requestFocus();
    await tester.pump();
    return (above, below, text);
  }

  testWidgets('TV: 방향키로 입력란을 지나가고 키보드는 뜨지 않는다', (tester) async {
    tvDevice = true;
    final (above, below, _) = await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(above.hasFocus, isFalse);
    expect(below.hasFocus, isFalse);
    expect(tester.testTextInput.isVisible, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(below.hasPrimaryFocus, isTrue);
  });

  testWidgets('TV: 선택을 누르면 입력하고, 방향키로 입력을 끝내고 옮긴다', (tester) async {
    tvDevice = true;
    final (above, below, text) = await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    tester.testTextInput.enterText('ab');
    await tester.pump();
    expect(text.text, 'ab');

    // 글 가운데에서는 ←가 커서를 옮긴다 (입력란을 떠나지 않는다)
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(above.hasFocus || below.hasFocus, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump();
    expect(below.hasPrimaryFocus, isTrue);
    expect(text.text, 'ab');
  });

  testWidgets('TV가 아니면 입력란 그대로', (tester) async {
    final (_, _, text) = await pump(tester);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    tester.testTextInput.enterText('x');
    expect(text.text, 'x');
  });
}
