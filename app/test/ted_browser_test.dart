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

Map<String, dynamic> _video(String id, String title) => {
  'id': id.padRight(11, '_'),
  'title': title,
  'duration': 600,
  'view_count': 12345,
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
    // 캐시 저장이 끝나기 전에 지우면 Windows에서 실패한다
    for (var i = 0; ; i++) {
      try {
        return await dir.delete(recursive: true);
      } on FileSystemException {
        if (i > 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  TedCatalog catalog() => TedCatalog(
    _FakeYtDlp({
      '$tedChannelUrl/videos': [
        for (var i = 0; i < 40; i++)
          _video('new$i', 'Latest talk $i | Speaker $i | TED'),
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
}
