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

  group('정렬', () {
    TedVideo t(String id, {int? views, int? day}) => TedVideo(
      id: id.padRight(11, '_'),
      title: id,
      views: views,
      uploaded: day == null ? null : DateTime.utc(2026, 1, day),
    );
    final list = [
      t('a', views: 10, day: 5),
      t('b', views: 300, day: 1),
      t('c', day: 20), // 조회수 없음
      t('d', views: 300, day: 9), // b와 조회수 같음
      t('e', views: 50), // 날짜 없음
    ];

    test('기본 순서는 받은 순서 그대로', () {
      expect(ids(sortVideos(list, TedSort.original)), [
        'a',
        'b',
        'c',
        'd',
        'e',
      ]);
    });
    test('조회수 높은 순: 같으면 원래 순서, 없으면 뒤로', () {
      expect(ids(sortVideos(list, TedSort.views)), ['b', 'd', 'e', 'a', 'c']);
    });
    test('최근 올라온 순: 날짜 없으면 뒤로', () {
      expect(ids(sortVideos(list, TedSort.recent)), ['c', 'd', 'a', 'b', 'e']);
    });
  });

  group('재생 시간', () {
    TedVideo len(String id, int? min) => TedVideo(
      id: id.padRight(11, '_'),
      title: id,
      duration: min == null ? null : Duration(minutes: min),
    );
    final list = [
      len('a', 12),
      len('b', 3),
      len('c', null),
      len('d', 5),
      len('e', 20),
    ];

    test('짧은 순 / 긴 순 (길이 모르면 뒤로)', () {
      expect(ids(sortVideos(list, TedSort.shortest)), [
        'b',
        'd',
        'a',
        'e',
        'c',
      ]);
      expect(ids(sortVideos(list, TedSort.longest)), ['e', 'a', 'd', 'b', 'c']);
    });
    test('길이 필터: 경계 5분·15분은 짧은 쪽, 길이 모르면 모든 길이에서만', () {
      List<String> f(TedLength l) => ids(list.where(l.accepts).toList());
      expect(f(TedLength.any), ['a', 'b', 'c', 'd', 'e']);
      expect(f(TedLength.short), ['b', 'd']);
      expect(f(TedLength.medium), ['a']);
      expect(f(TedLength.long), ['e']);
      expect(TedLength.medium.accepts(len('x', 15)), isTrue);
      expect(TedLength.long.accepts(len('x', 15)), isFalse);
    });
  });

  test('formatAgo', () {
    final now = DateTime.utc(2026, 11, 13, 12);
    expect(formatAgo(DateTime.utc(2026, 11, 13), now), '오늘');
    expect(formatAgo(DateTime.utc(2026, 11, 12), now), '어제');
    expect(formatAgo(DateTime.utc(2026, 11, 9), now), '4일 전');
    expect(formatAgo(DateTime.utc(2026, 10, 23), now), '3주 전');
    expect(formatAgo(DateTime.utc(2026, 5, 1), now), '6개월 전');
    expect(formatAgo(DateTime.utc(2016, 11, 13), now), '10년 전');
  });

  test('올린 날: yt-dlp timestamp(어림값)를 읽고 캐시에 남긴다', () {
    final x = TedVideo.fromEntry({
      'id': 'f5RqYHd2cBQ',
      'title': 'How Would You Design Your Dream City? | James Rojas | TED',
      'timestamp': 1794499200,
    })!;
    expect(x.uploaded, DateTime.utc(2026, 11, 12, 16)); // 한국 시간 11-13 0시
    expect(TedVideo.fromJson(x.toJson())!.uploaded, x.uploaded);
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

  group('채널', () {
    VideoChannel ch(String id) => VideoChannel.byId(id);

    test('5개 채널, 주소', () {
      expect(VideoChannel.all.map((c) => c.name), [
        'TED',
        'TED-Ed',
        'TEDx Talks',
        'BBC Learning English',
        'VOA Learning English',
      ]);
      expect(
        TedFeed.latestOf(ch('bbc-le')).url,
        'https://www.youtube.com/@bbclearningenglish/videos',
      );
      expect(
        TedFeed.search('grammar', channel: ch('voa-le')).url,
        'https://www.youtube.com/@VOALearningEnglish/search?query=grammar',
      );
      expect(TedFeed.latest, TedFeed.latestOf(VideoChannel.ted));
      expect(VideoChannel.byId('없는 채널'), VideoChannel.ted);
    });

    test('같은 검색어라도 채널이 다르면 다른 목록', () {
      expect(
        TedFeed.search('ai') == TedFeed.search('ai', channel: ch('tedx')),
        isFalse,
      );
    });

    test('채널마다 제목 형식 (실제 제목)', () {
      expect(
        splitTitle(
          'Can you solve the Billy Bonka riddle? - Edwin F. Meyer',
          TitleStyle.dash,
        ),
        ('Can you solve the Billy Bonka riddle?', 'Edwin F. Meyer'),
      );
      // 강연자 없는 TED-Ed 제목은 그대로
      expect(
        splitTitle(
          'How to effectively use visuals in your presentation',
          TitleStyle.dash,
        ),
        ('How to effectively use visuals in your presentation', null),
      );
      // " - " 뒤가 이름이 아니면 떼지 않는다
      expect(splitDashTitle('Grammar - what is the present perfect?'), (
        'Grammar - what is the present perfect?',
        null,
      ));
      expect(
        splitTitle(
          "Why moms shouldn't have to do it all | Onnie Michalsky | TEDxBillings",
          TitleStyle.ted,
        ),
        ("Why moms shouldn't have to do it all", 'Onnie Michalsky'),
      );
      expect(
        splitTitle('Everyday Grammar Video: Ramen | Part 2', TitleStyle.plain),
        ('Everyday Grammar Video: Ramen | Part 2', null),
      );
    });

    test('채널별 캐시, TED는 예전 캐시 그대로, 마지막 채널 기억', () async {
      final dir = await Directory.systemTemp.createTemp('ted_ch_');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/ted.json');
      // 채널을 나누기 전에 저장된 TED 캐시
      await file.writeAsString(
        '{"videos":[{"id":"81iS7JsTGmk","title":"Old TED"}]}',
      );
      final cat = TedCatalog(YtDlp(executable: 'unused'), file);
      expect((await cat.cached()).single.title, 'Old TED');
      expect(await cat.cached(ch('bbc-le')), isEmpty);
      expect(await cat.lastChannel(), VideoChannel.ted);

      await cat.save([v('bbc')], ch('bbc-le'));
      await cat.saveLastChannel(ch('bbc-le'));
      expect(ids(await cat.cached(ch('bbc-le'))), ['bbc']);
      expect((await cat.cached()).single.title, 'Old TED');
      expect(await cat.lastChannel(), ch('bbc-le'));
    });

    test('채널 영상은 그 채널 형식으로 강연자를 뗀다', () async {
      final tedEd = ch('ted-ed');
      final yt = _FakeYtDlp({
        TedFeed.latestOf(tedEd).url: [
          {
            'id': 'abcdefghijk',
            'title': 'Why is pepper such a popular spice? - Carolyn Beans',
          },
        ],
      });
      final cat = TedCatalog(yt, File('unused.json'));
      final p = await cat.fetch(TedFeed.latestOf(tedEd));
      expect(p.videos.single.title, 'Why is pepper such a popular spice?');
      expect(p.videos.single.speaker, 'Carolyn Beans');
    });
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
