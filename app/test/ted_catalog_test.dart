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
    test('예전 형식 "제목 | 강연자" (실제 검색 결과)', () {
      expect(splitTedTitle('The happy secret to better work | Shawn Achor'), (
        'The happy secret to better work',
        'Shawn Achor',
      ));
    });
    test('형식이 다르면 그대로', () {
      expect(splitTedTitle('The TED Interview'), ('The TED Interview', null));
      expect(splitTedTitle('A | '), ('A |', null));
    });
  });

  group('TedFeed', () {
    test('주소', () {
      expect(TedFeed.latest.url, 'https://www.youtube.com/@TED/videos');
      expect(
        const TedFeed.playlist('PLe3qqz7JaEDM', 'Psychology').url,
        'https://www.youtube.com/playlist?list=PLe3qqz7JaEDM',
      );
      expect(
        TedFeed.search(' public speaking ').url,
        'https://www.youtube.com/@TED/search?query=public+speaking',
      );
    });
    test('같은 분류·검색어면 같다 (선택 표시·상태 보관용)', () {
      expect(TedFeed.search('ai'), TedFeed.search(' ai '));
      expect(
        const TedFeed.playlist('PL1', 'a'),
        const TedFeed.playlist('PL1', 'b'),
      );
      expect(
        TedFeed.search('PL1') == const TedFeed.playlist('PL1', 'x'),
        isFalse,
      );
    });
    test('채널 재생목록 항목 (실제 yt-dlp 출력 형태)', () {
      final f = TedFeed.playlistFromEntry({
        'title': 'Best TED Talks on psychology',
        'id': 'PLe3qqz7JaEDM',
        '_type': 'url',
        'url': 'https://www.youtube.com/playlist?list=PLe3qqz7JaEDM',
      })!;
      expect(f.kind, TedFeedKind.playlist);
      expect(f.title, 'Best TED Talks on psychology');
      expect(
        TedFeed.playlistFromEntry({'id': '81iS7JsTGmk', 'title': 'x'}),
        isNull,
      );
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

  test('분류·검색 페이지를 받고, 분류 목록은 캐시에 남는다', () async {
    final dir = await Directory.systemTemp.createTemp('ted_test_');
    addTearDown(() => dir.delete(recursive: true));
    final yt = _FakeYtDlp({
      'https://www.youtube.com/@TED/playlists': [
        {'id': 'PLaaa', 'title': 'Psychology'},
        {'id': 'PLbbb', 'title': 'AI'},
        {'id': 'PLaaa', 'title': 'Psychology'}, // 중복
        {'id': 'UCchannel', 'title': 'not a playlist'},
      ],
      'https://www.youtube.com/playlist?list=PLbbb': [
        for (var i = 0; i < 45; i++) _video(i),
      ],
    });
    final cat = TedCatalog(yt, File('${dir.path}/ted.json'));
    // 최신 영상 저장과 분류 저장이 동시에 일어나도 둘 다 남아야 한다
    final saving = cat.save([v('a')]);
    final pls = await cat.fetchPlaylists();
    await saving;
    expect(pls.map((p) => p.title), ['Psychology', 'AI']);
    expect((await cat.cachedPlaylists()).map((p) => p.key), ['PLaaa', 'PLbbb']);
    expect(ids(await cat.cached()), ['a']);

    const feed = TedFeed.playlist('PLbbb', 'AI');
    final p1 = await cat.fetch(feed);
    final p2 = await cat.fetch(feed, offset: p1.received);
    expect(p1.videos.length, 30);
    expect(p1.isLast, isFalse);
    expect(p2.videos.length, 15);
    expect(p2.isLast, isTrue);
    expect(p2.videos.first.title, 'Talk 30');
    expect(p2.videos.first.speaker, 'Speaker 30');
    expect(yt.calls.last, 'https://www.youtube.com/playlist?list=PLbbb 31-60');
  });

  test('검색 결과에 재생목록이 섞여 영상이 30개보다 적어도 마지막 페이지가 아니다', () async {
    final url = TedFeed.search('happiness').url;
    final yt = _FakeYtDlp({
      url: [
        for (var i = 0; i < 60; i++)
          i % 7 == 0 ? {'id': 'PLx$i', 'title': 'playlist'} : _video(i),
      ],
    });
    final cat = TedCatalog(yt, File('unused.json'));
    final p1 = await cat.fetch(TedFeed.search('happiness'));
    expect(p1.videos.length, lessThan(30));
    expect(p1.received, 30);
    expect(p1.isLast, isFalse);
    final p2 = await cat.fetch(
      TedFeed.search('happiness'),
      offset: p1.received,
    );
    expect(yt.calls.last, endsWith(' 31-60'));
    expect(p2.videos.first.title, 'Talk 30'); // 31번째 항목 (i=30)
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

/// yt-dlp 대신 정해진 항목을 돌려주고, 받은 요청을 기록한다
class _FakeYtDlp extends YtDlp {
  _FakeYtDlp(this.entries);
  final Map<String, List<Map<String, dynamic>>> entries;
  final calls = <String>[];

  @override
  Future<Map<String, dynamic>> listPlaylist(
    String url, {
    required int start,
    required int end,
  }) async {
    calls.add('$url $start-$end');
    final all = entries[url] ?? const [];
    return {
      'entries': all.sublist(
        (start - 1).clamp(0, all.length),
        end.clamp(0, all.length),
      ),
    };
  }
}

Map<String, dynamic> _video(int i) => {
  'id': 'vid${i.toString().padLeft(8, '0')}',
  'title': 'Talk $i | Speaker $i | TED',
  'duration': 600,
};
