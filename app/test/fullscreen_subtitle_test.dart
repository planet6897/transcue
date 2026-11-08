import 'dart:async';

import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:transcue/src/subtitle/dual_subtitle_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 전체 화면은 새 화면(route)으로 뜬다. 그 화면에서도 자막이 갱신되는지 확인.
void main() {
  testWidgets('subtitles update inside a separately pushed route', (t) async {
    final pos = StreamController<Duration>.broadcast();
    var now = Duration.zero;
    final view = DualSubtitleState();
    Widget overlay() => LiveDualSubtitle(
      position: pos.stream,
      currentPosition: () => now,
      view: view,
    );

    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(body: overlay()),
                  ),
                ),
                child: const Text('fullscreen'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('fullscreen'));
    await t.pumpAndSettle();

    // 자막이 나중에 도착 (음성 인식 결과)
    view.cues = const [
      BilingualCue(
        start: Duration(seconds: 1),
        end: Duration(seconds: 3),
        original: 'Hello, Michael.',
      ),
      BilingualCue(
        start: Duration(seconds: 3),
        end: Duration(seconds: 5),
        original: 'Who are you?',
      ),
    ];
    now = const Duration(seconds: 2);
    pos.add(now);
    await t.pump();
    expect(find.text('Hello, Michael.'), findsOneWidget);

    // 재생 위치가 바뀌면 다음 줄
    pos.add(const Duration(seconds: 4));
    await t.pump();
    await t.pump(); // 스트림 이벤트는 다음 프레임에 반영
    expect(find.text('Who are you?'), findsOneWidget);

    // 번역이 채워지면 바로 반영
    view.cues = [
      for (final c in view.cues) c.withTranslation('번역: ${c.original}'),
    ];
    await t.pump();
    expect(find.text('번역: Who are you?'), findsOneWidget);

    // 번역 숨기기
    view.showTranslation = false;
    await t.pump();
    expect(find.text('번역: Who are you?'), findsNothing);
    await pos.close();
  });
}
