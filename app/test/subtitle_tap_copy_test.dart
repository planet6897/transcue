import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:transcue/src/subtitle/dual_subtitle_overlay.dart';

void main() {
  const cue = BilingualCue(
    start: Duration(seconds: 1),
    end: Duration(seconds: 3),
    original: 'Hello.',
    translation: '안녕.',
  );

  test('화면에 보이는 줄만 복사한다', () {
    final view = DualSubtitleState();
    expect(view.copyText(cue), 'Hello.\n안녕.');
    view.showTranslation = false;
    expect(view.copyText(cue), 'Hello.');
    view
      ..showTranslation = true
      ..showOriginal = false;
    expect(view.copyText(cue), '안녕.');
  });

  test('번역이 없으면 원문만 복사한다', () {
    const noKo = BilingualCue(
      start: Duration.zero,
      end: Duration(seconds: 1),
      original: 'Who?',
    );
    expect(DualSubtitleState().copyText(noKo), 'Who?');
  });

  Widget host(Widget overlay, VoidCallback behind) => MaterialApp(
    home: Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: behind,
          ),
        ),
        overlay,
      ],
    ),
  );

  testWidgets('자막을 누르면 해당 줄을 넘기고 아래로 전달하지 않는다', (t) async {
    BilingualCue? tapped;
    var behind = 0;
    await t.pumpWidget(
      host(
        DualSubtitleOverlay(cue: cue, onTapCue: (c) => tapped = c),
        () => behind++,
      ),
    );
    await t.tap(find.text('안녕.'));
    expect(tapped, same(cue));
    expect(behind, 0);
  });

  testWidgets('자막 밖을 누르면 아래 조작부로 전달한다', (t) async {
    BilingualCue? tapped;
    var behind = 0;
    await t.pumpWidget(
      host(
        DualSubtitleOverlay(cue: cue, onTapCue: (c) => tapped = c),
        () => behind++,
      ),
    );
    await t.tapAt(const Offset(100, 100));
    expect(tapped, isNull);
    expect(behind, 1);
  });
}
