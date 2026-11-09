import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/play_counts.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('transcue_counts');
    file = File('${dir.path}/play_counts.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('영상별로 횟수를 세고 새로 열어도 유지한다', () async {
    final c = PlayCounts(file);
    expect(await c.get('file:a'), 0);
    expect(await c.increment('file:a'), 1);
    expect(await c.increment('file:a'), 2);
    expect(await c.increment('file:b'), 1);
    final again = PlayCounts(file);
    expect(await again.get('file:a'), 2);
    expect(await again.get('file:b'), 1);
  });

  test('리셋은 해당 영상만 0으로 되돌리고 저장한다', () async {
    final c = PlayCounts(file);
    await c.increment('file:a');
    await c.increment('file:b');
    await c.reset('file:a');
    final again = PlayCounts(file);
    expect(await again.get('file:a'), 0);
    expect(await again.get('file:b'), 1);
  });

  test('손상된 파일은 0회로 시작한다', () async {
    await file.writeAsString('{broken');
    expect(await PlayCounts(file).get('file:a'), 0);
  });

  Widget host(ValueNotifier<({bool repeat, int count})> info, VoidCallback f) =>
      MaterialApp(
        home: Stack(
          children: [PlayCountBadge(info: info, onReset: f)],
        ),
      );

  testWidgets('반복이 꺼져 있고 0회면 숨기고, 값이 바뀌면 바로 표시한다', (t) async {
    final info = ValueNotifier((repeat: false, count: 0));
    await t.pumpWidget(host(info, () {}));
    expect(find.textContaining('재생'), findsNothing);

    info.value = (repeat: true, count: 0);
    await t.pump();
    expect(find.text('재생 0회'), findsOneWidget);

    info.value = (repeat: true, count: 3);
    await t.pump();
    expect(find.text('재생 3회'), findsOneWidget);
  });

  testWidgets('리셋 버튼을 누르면 콜백을 부른다', (t) async {
    var resets = 0;
    final info = ValueNotifier((repeat: false, count: 2));
    await t.pumpWidget(host(info, () => resets++));
    await t.tap(find.byIcon(Icons.restart_alt));
    expect(resets, 1);
  });
}
