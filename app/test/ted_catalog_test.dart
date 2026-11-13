import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/source/ted_catalog.dart';
import 'package:transcue/src/source/yt_dlp.dart';

TedVideo v(String id) => TedVideo(id: id.padRight(11, '_'), title: id);

List<String> ids(List<TedVideo> l) => [
  for (final x in l) x.id.replaceAll('_', ''),
];

void main() {
  group('splitTedTitle', () {
    test('제목 | 강연자 | TED', () {
      expect(
        splitTedTitle(
          'How Would You Design Your Dream City? | James Rojas | TED',
        ),
        ('How Would You Design Your Dream City?', 'James Rojas'),
      );
    });
    test('제목에 | 가 있어도 끝의 강연자·TED만 뗀다', () {
      expect(splitTedTitle('A | B | Speaker | TED'), ('A | B', 'Speaker'));
    });
    test('TED 계열 꼬리 (TEDx, TED Countdown)', () {
      expect(splitTedTitle('Idea | Kim | TEDxSeoul'), ('Idea', 'Kim'));
      expect(splitTedTitle('Climate | TED Countdown'), ('Climate', null));
    });
    test('형식이 다르면 그대로', () {
      expect(splitTedTitle('The TED Interview'), ('The TED Interview', null));
      expect(splitTedTitle('A | B'), ('A | B', null));
    });
  });

  test('flat-playlist 항목을 읽는다 (실제 yt-dlp 출력 형태)', () {
    final x = TedVideo.fromEntry({
      'title': 'How Sharing Books Makes You Less Lonely | Rebecca Toh | TED',
      'duration': 606,
      'view_count': 100000,
      'id': '81iS7JsTGmk',
      '_type': 'url',
      'url': 'https://www.youtube.com/watch?v=81iS7JsTGmk',
    })!;
    expect(x.title, 'How Sharing Books Makes You Less Lonely');
    expect(x.speaker, 'Rebecca Toh');
    expect(x.duration, const Duration(seconds: 606));
    expect(x.views, 100000);
    expect(x.thumbnailUrl, 'https://i.ytimg.com/vi/81iS7JsTGmk/mqdefault.jpg');
    // 재생목록·채널 같은 다른 항목은 건너뛴다
    expect(
      TedVideo.fromEntry({'id': 'UCAuUUnT6oDeKwE6v1NGQxug', 'title': 'x'}),
      isNull,
    );
    expect(TedVideo.fromEntry({'id': '81iS7JsTGmk'}), isNull);
  });

  group('mergeLatest', () {
    test('새 영상을 앞에, 이전 목록을 겹치지 않게 뒤에', () {
      expect(
        ids(mergeLatest([v('n'), v('a'), v('b')], [v('a'), v('b'), v('c')])),
        ['n', 'a', 'b', 'c'],
      );
    });
    test('겹치는 영상이 없으면(오래된 캐시) 이전 목록을 버린다', () {
      expect(ids(mergeLatest([v('x'), v('y')], [v('a'), v('b')])), ['x', 'y']);
    });
    test('새로 받은 게 비면 이전 목록 그대로', () {
      expect(ids(mergeLatest([], [v('a')])), ['a']);
    });
  });

  test('appendNew는 겹치지 않아도 다음 페이지를 붙인다', () {
    expect(ids(appendNew([v('a'), v('b')], [v('b'), v('c')])), ['a', 'b', 'c']);
    expect(ids(appendNew([v('a')], [v('c')])), ['a', 'c']);
  });

  test('formatViews', () {
    expect(formatViews(950), '950');
    expect(formatViews(1200), '1.2천');
    expect(formatViews(34000), '3.4만');
    expect(formatViews(100000), '10만');
    expect(formatViews(1234567), '123만');
    expect(formatViews(250000000), '2.5억');
  });

  test('캐시 저장·불러오기, 깨진 캐시는 빈 목록', () async {
    final dir = await Directory.systemTemp.createTemp('ted_test_');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/ted.json');
    final cat = TedCatalog(YtDlp(executable: 'unused'), file);
    expect(await cat.cached(), isEmpty);
    await cat.save([
      const TedVideo(
        id: '81iS7JsTGmk',
        title: 'T',
        speaker: 'S',
        duration: Duration(seconds: 60),
        views: 5,
      ),
      v('b'),
    ]);
    final back = await cat.cached();
    expect(back.length, 2);
    expect(back.first.speaker, 'S');
    expect(back.first.duration, const Duration(seconds: 60));
    expect(back.first.views, 5);
    await file.writeAsString('{broken');
    expect(await cat.cached(), isEmpty);
  });
}
