import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/ted_browser.dart';
import 'package:transcue/src/source/ted_catalog.dart';
import 'package:transcue/src/source/yt_dlp.dart';

/// yt-dlp 대신 주소별로 정해진 항목을 돌려준다
class _FakeYtDlp extends YtDlp {
  _FakeYtDlp(this.entries);
  final Map<String, List<Map<String, dynamic>>> entries;

  @override
  Future<Map<String, dynamic>> listPlaylist(
    String url, {
    required int start,
    required int end,
  }) async {
    final all = entries[url] ?? const [];
    return {
      'entries': all.sublist(
        (start - 1).clamp(0, all.length),
        end.clamp(0, all.length),
      ),
    };
  }
}

Map<String, dynamic> _video(
  String id,
  String title, {
  int duration = 600,
  int views = 12345,
}) => {
  'id': id.padRight(11, '_'),
  'title': title,
  'duration': duration,
  'view_count': views,
};

/// 실제 파일·가짜 yt-dlp 응답(진짜 비동기)이 끝나 [finder]가 나타날 때까지 기다린다
Future<void> settle(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('ted_ui_'));
  tearDown(() async {
    // 다음 페이지를 받은 뒤 캐시 저장이 진행 중이면 Windows에서 지우지 못한다.
    // 위젯 테스트 안에서는 시간이 가짜로 흘러 기다려도 소용없으므로 그냥 둔다 (OS 임시 폴더).
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // 무시
    }
  });

  TedCatalog catalog() => TedCatalog(
    _FakeYtDlp({
      '$tedChannelUrl/videos': [
        // 조회수는 뒤로 갈수록 많고, 4분짜리 짧은 강연은 33번째·38번째에만 있다
        for (var i = 0; i < 40; i++)
          _video(
            'new$i',
            'Latest talk $i | Speaker $i | TED',
            views: 1000 + i,
            duration: i == 33 || i == 38 ? 240 : 600,
          ),
      ],
      '$tedChannelUrl/playlists': [
        for (var i = 0; i < 60; i++)
          {'id': 'PL$i', 'title': i == 0 ? 'Psychology' : 'Category $i'},
      ],
      'https://www.youtube.com/playlist?list=PL0': [
        _video('psy1', 'Why Depression Isn’t What We Think | Lisa M | TED'),
      ],
      TedFeed.search('happiness').url: [
        _video('hap1', 'The happy secret to better work | Shawn Achor'),
      ],
    }),
    File('${dir.path}/ted.json'),
  );

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cat = catalog();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showDialog<String>(
                context: context,
                builder: (_) => TedBrowserDialog(catalog: cat),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await settle(tester, find.text('Psychology'));
    await settle(tester, find.text('Latest talk 0'));
  }

  for (final size in [const Size(800, 500), const Size(1600, 900)]) {
    testWidgets('창 ${size.width}x${size.height}에 맞고 넘치지 않는다', (tester) async {
      await open(tester, size);
      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(find.byType(Dialog));
      expect(dialog.right, lessThanOrEqualTo(size.width));
      expect(dialog.bottom, lessThanOrEqualTo(size.height));
      expect(find.text('Latest talk 0'), findsOneWidget);
      // 분류 목록은 첫 항목부터 보인다
      expect(find.text('Psychology'), findsOneWidget);
    });
  }

  testWidgets('분류를 고르면 그 재생목록, 검색하면 검색 결과를 보여 준다', (tester) async {
    await open(tester, const Size(1280, 800));
    await tester.tap(find.text('Psychology'));
    await settle(tester, find.text('Why Depression Isn’t What We Think'));
    expect(find.text('Why Depression Isn’t What We Think'), findsOneWidget);
    expect(find.text('Latest talk 0'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'happiness');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await settle(tester, find.text('The happy secret to better work'));
    expect(find.text('The happy secret to better work'), findsOneWidget);
    // 검색어가 왼쪽 목록에 남아 다시 고를 수 있다
    expect(find.text('“happiness” 검색 결과'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('정렬을 고르면 순서가 바뀌고, 길이로 거르면 다음 페이지까지 찾아 온다', (tester) async {
    await open(tester, const Size(1280, 800));
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('Latest talk 0'), lessThan(y('Latest talk 1')));

    await tester.tap(find.text('기본 순서'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('조회수 높은 순').last);
    await tester.pumpAndSettle();
    // 첫 페이지(0~29) 중 조회수가 가장 많은 29번이 맨 위
    expect(y('Latest talk 29'), lessThan(y('Latest talk 28')));
    expect(find.text('불러온 30개 중'), findsOneWidget);

    await tester.tap(find.text('모든 길이'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('5분 이하').last);
    await tester.pump();
    // 첫 페이지에는 5분 이하가 없어 다음 페이지(30~39)를 알아서 받는다
    await settle(tester, find.text('Latest talk 38'));
    expect(find.text('Latest talk 33'), findsOneWidget);
    expect(find.text('Latest talk 0'), findsNothing);
    expect(y('Latest talk 38'), lessThan(y('Latest talk 33')));
    expect(find.text('불러온 40개 중 2개'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
