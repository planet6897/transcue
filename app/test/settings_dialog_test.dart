import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/settings/app_settings.dart';
import 'package:transcue/src/settings/settings_dialog.dart';

void main() {
  Future<void> open(WidgetTester tester, AppSettings s) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        // 테스트 글꼴은 글자 폭이 넓어 긴 항목이 넘친다. 실제 글꼴 폭에 가깝게 줄인다.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(0.5)),
          child: child!,
        ),
        home: Scaffold(body: SettingsDialog(settings: s)),
      ),
    );
  }

  Future<void> pick(WidgetTester tester, String from, String to) async {
    await tester.tap(find.text(from));
    await tester.pumpAndSettle();
    await tester.tap(find.text(to).last);
    await tester.pumpAndSettle();
  }

  testWidgets('공급자를 바꾸면 그 공급자의 키·모델을 따로 저장한다', (tester) async {
    final s = AppSettings(claudeApiKey: 'claude-key');
    await open(tester, s);
    expect(find.text('Claude API 키'), findsOneWidget);
    expect(find.textContaining('Claude Opus'), findsOneWidget);

    await pick(tester, 'Claude', 'OpenAI');
    expect(find.text('OpenAI API 키'), findsOneWidget);
    expect(find.textContaining('GPT-6.1 Sol'), findsOneWidget);
    expect(find.textContaining('Claude Opus'), findsNothing);
    // Claude 키가 OpenAI 입력란에 보이면 안 된다
    expect(find.text('claude-key'), findsNothing);

    await tester.enterText(find.byType(TextField).first, ' openai-key ');
    await tester.tap(find.textContaining('GPT-6.1 Sol'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('GPT-6 Luna').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));

    expect(s.provider, TranslateProvider.openai);
    expect(s.openaiApiKey, 'openai-key');
    expect(s.openaiModel, OpenAiModel.luna);
    // 다른 공급자의 키·모델은 그대로
    expect(s.claudeApiKey, 'claude-key');
    expect(s.claudeModel, ClaudeModel.opus);
    expect(s.hasTranslateKey, isTrue);
  });

  testWidgets('Gemini로 바꿨다 돌아와도 넣어 둔 키가 남아 있다', (tester) async {
    final s = AppSettings(claudeApiKey: 'claude-key');
    await open(tester, s);
    await pick(tester, 'Claude', 'Gemini');
    expect(find.text('Gemini API 키'), findsOneWidget);
    expect(find.textContaining('Gemini 4 Hydrogen'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'gemini-key');
    await pick(tester, 'Gemini', 'Claude');
    await tester.tap(find.text('저장'));

    expect(s.provider, TranslateProvider.claude);
    expect(s.geminiApiKey, 'gemini-key');
    expect(s.claudeApiKey, 'claude-key');
  });
}
