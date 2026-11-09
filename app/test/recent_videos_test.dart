import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/recent_videos.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('transcue_recent');
    file = File('${dir.path}/recent.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<List<String>> sources(RecentVideos r) async =>
      (await r.list()).map((v) => v.source).toList();

  test('가장 최근에 연 영상이 맨 앞이고 새로 열어도 유지된다', () async {
    final r = RecentVideos(file);
    await r.add('a', 'A');
    await r.add('b', 'B');
    expect(await sources(r), ['b', 'a']);
    expect(await sources(RecentVideos(file)), ['b', 'a']);
  });

  test('다시 열면 중복 없이 맨 앞으로 옮긴다', () async {
    final r = RecentVideos(file);
    await r.add('a', 'A');
    await r.add('b', 'B');
    await r.add('a', 'A');
    expect(await sources(r), ['a', 'b']);
  });

  test('개수 제한을 넘으면 오래된 것부터 지운다', () async {
    final r = RecentVideos(file);
    for (var i = 0; i <= RecentVideos.maxEntries; i++) {
      await r.add('v$i', 'V');
    }
    final all = await sources(r);
    expect(all.length, RecentVideos.maxEntries);
    expect(all.contains('v0'), isFalse);
  });

  test('지운 항목은 저장 후에도 없다', () async {
    final r = RecentVideos(file);
    await r.add('a', 'A');
    await r.add('b', 'B');
    await r.remove('a');
    expect(await sources(RecentVideos(file)), ['b']);
  });

  test('손상된 파일은 빈 목록으로 시작한다', () async {
    await file.writeAsString('{broken');
    expect(await sources(RecentVideos(file)), isEmpty);
  });

  test('이어 볼 위치와 재생 횟수를 한 줄로 만든다', () {
    const v = RecentVideo(source: 'a', title: 'A');
    expect(
      const RecentRow(
        video: v,
        resumeAt: Duration(minutes: 12, seconds: 5),
        playCount: 3,
      ).detail,
      '12:05부터 이어 보기 · 재생 3회',
    );
    expect(const RecentRow(video: v).detail, '');
    expect(const RecentRow(video: v, available: false).detail, '파일을 찾을 수 없음');
  });

  group('대화상자', () {
    const a = RecentVideo(source: '/a.mkv', title: 'Movie A');
    const b = RecentVideo(source: '/b.mkv', title: 'Movie B');

    Future<Future<String?> Function()> open(
      WidgetTester t,
      List<RecentRow> rows,
      ValueChanged<String> onRemove,
    ) async {
      String? picked;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await showDialog<String>(
                  context: context,
                  builder: (_) =>
                      RecentVideosDialog(rows: rows, onRemove: onRemove),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      return () async => picked;
    }

    testWidgets('영상을 누르면 그 영상을 돌려준다', (t) async {
      final result = await open(t, const [RecentRow(video: a)], (_) {});
      await t.pump();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Movie A'));
      await t.pumpAndSettle();
      expect(await result(), '/a.mkv');
    });

    testWidgets('지우기를 누르면 목록에서 사라지고 대화상자는 유지된다', (t) async {
      final removed = <String>[];
      await open(t, const [
        RecentRow(video: a),
        RecentRow(video: b),
      ], removed.add);
      await t.pump();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.byIcon(Icons.close).first);
      await t.pumpAndSettle();
      expect(removed, ['/a.mkv']);
      expect(find.text('Movie A'), findsNothing);
      expect(find.text('Movie B'), findsOneWidget);
    });

    testWidgets('파일이 없으면 눌러도 열지 않는다', (t) async {
      final result = await open(t, const [
        RecentRow(video: a, available: false),
      ], (_) {});
      await t.pump();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Movie A'));
      await t.pumpAndSettle();
      expect(await result(), isNull);
      expect(find.text('최근 재생목록'), findsOneWidget);
    });

    testWidgets('목록이 비어 있으면 안내를 보여 준다', (t) async {
      await open(t, const [], (_) {});
      await t.pump();
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('아직 재생한 영상이 없습니다'), findsOneWidget);
    });
  });
}
