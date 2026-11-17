import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/study/transcript_panel.dart';
import 'package:transcue/src/study/wordbook.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:transcue/src/subtitle/dual_subtitle_overlay.dart';

List<BilingualCue> _cues(int n) => [
  for (var i = 0; i < n; i++)
    BilingualCue(
      start: Duration(seconds: i * 3),
      end: Duration(seconds: i * 3 + 2),
      original: 'line $i',
    ),
];

void main() {
  testWidgets('자막 목록: 다시 쓰는 줄이 있어도 바뀐 번역·끼워 넣은 줄은 보인다', (t) async {
    await t.binding.setSurfaceSize(const Size(1200, 2000));
    final view = DualSubtitleState()..cues = _cues(5);
    final pos = StreamController<Duration>.broadcast();
    addTearDown(pos.close);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranscriptPanel(
            view: view,
            book: Wordbook(
              Future.value(
                File('${Directory.systemTemp.path}/wb_rebuild.json'),
              ),
            ),
            position: pos.stream,
            currentPosition: () => Duration.zero,
            onSeek: (_) {},
            sentenceSaved: (_) => false,
            onToggleSentence: (_) {},
            onToggleWord: (_, _) {},
            onExplain: (_) {},
            onClose: () {},
          ),
        ),
      ),
    );
    expect(find.text('line 3'), findsOneWidget);

    // 번역이 한 줄에만 붙는다
    final c = [...view.cues];
    c[3] = c[3].withTranslation('번역 3');
    view.cues = c;
    await t.pump();
    expect(find.text('번역 3'), findsOneWidget);
    expect(find.text('line 0'), findsOneWidget);

    // 음성 인식이 중간에 줄을 끼워 넣는다
    view.cues = [
      ...c.take(2),
      const BilingualCue(
        start: Duration(milliseconds: 4500),
        end: Duration(milliseconds: 5500),
        original: 'inserted',
      ),
      ...c.skip(2),
    ];
    await t.pump();
    expect(find.text('inserted'), findsOneWidget);
    expect(find.text('번역 3'), findsOneWidget);
    expect(find.textContaining('6문장'), findsOneWidget);
  });

  testWidgets('화면 자막: 위치가 같은 줄 안에서 움직이면 다시 그리지 않고, 줄·번역이 바뀌면 보인다', (t) async {
    final view = DualSubtitleState()..cues = _cues(3);
    final pos = StreamController<Duration>.broadcast();
    addTearDown(pos.close);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LiveDualSubtitle(
            position: pos.stream,
            currentPosition: () => const Duration(milliseconds: 500),
            view: view,
          ),
        ),
      ),
    );
    expect(find.text('line 0'), findsOneWidget);
    final before = t.widget<DualSubtitleOverlay>(
      find.byType(DualSubtitleOverlay),
    );

    pos.add(const Duration(milliseconds: 900));
    await t.pump();
    await t.pump(); // 스트림 이벤트는 다음 프레임에 반영
    // 같은 줄: 위젯을 새로 만들지 않았다
    expect(
      identical(
        t.widget<DualSubtitleOverlay>(find.byType(DualSubtitleOverlay)),
        before,
      ),
      isTrue,
    );

    pos.add(const Duration(milliseconds: 3500));
    await t.pump();
    await t.pump();
    expect(find.text('line 1'), findsOneWidget);

    // 지금 줄에 번역이 붙으면 위치가 그대로여도 보인다
    final c = [...view.cues];
    c[1] = c[1].withTranslation('번역 1');
    view.cues = c;
    await t.pump();
    expect(find.text('번역 1'), findsOneWidget);

    // 줄이 끝난 사이에는 아무것도 보이지 않는다
    pos.add(const Duration(milliseconds: 5500));
    await t.pump();
    await t.pump();
    expect(find.text('line 1'), findsNothing);
  });
}
