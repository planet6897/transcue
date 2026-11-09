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

  testWidgets('복사 표시는 잠깐 켜졌다가 저절로 꺼진다', (t) async {
    final view = DualSubtitleState();
    view.flashCopied();
    expect(view.copied, isTrue);
    await t.pump(const Duration(milliseconds: 1000));
    expect(view.copied, isTrue);
    await t.pump(const Duration(milliseconds: 300));
    expect(view.copied, isFalse);
  });

  testWidgets('복사 표시가 켜지면 보이고 꺼지면 투명해진다', (t) async {
    double opacity() => t
        .widget<AnimatedOpacity>(
          find.ancestor(
            of: find.text('✓ 복사됨'),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;
    Widget build(bool on) => MaterialApp(
      home: DualSubtitleOverlay(cue: cue, copied: on),
    );
    await t.pumpWidget(build(false));
    expect(opacity(), 0);
    await t.pumpWidget(build(true));
    expect(opacity(), 1);
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
