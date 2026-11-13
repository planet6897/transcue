import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/source/innertube.dart';
import 'package:transcue/src/source/ted_catalog.dart';

Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/innertube/$name.json').readAsStringSync())
        as Map<String, dynamic>;

void main() {
  final now = DateTime.utc(2026, 11, 13, 12);

  group('실제 응답 (2026-11, 줄인 것)', () {
    test('채널 최신 영상: 제목·길이·조회수·올린 날, 다음 페이지 토큰', () {
      final p = parseBrowse(fixture('videos'), now);
      expect(p.entries.length, 4);
      final first = p.entries.first;
      expect(first['id'], 'f5RqYHd2cBQ');
      expect(
        first['title'],
        'How Would You Design Your Dream City? | James Rojas | TED',
      );
      expect(first['duration'], 8 * 60 + 35);
      expect(first['view_count'], 29000);
      expect(
        first['timestamp'],
        now.subtract(const Duration(hours: 13)).millisecondsSinceEpoch ~/ 1000,
      );
      // 댓글 패널 등 다른 곳의 토큰이 아니라 목록 끝의 토큰
      expect(
        p.continuation,
        startsWith('4qmFsgLdCBIYVUNBdVVVblQ2b0RlS3dFNnYxTkdReHVn'),
      );
      // 목록이 쓰는 모양 그대로 TedVideo가 된다
      final v = TedVideo.fromEntry(first)!;
      expect(v.speaker, 'James Rojas');
    });

    test('채널 재생목록 탭 → 분류', () {
      final p = parseBrowse(fixture('playlists'), now);
      expect(p.entries.first, {
        'id': 'PLe3qqz7JaEDM',
        'title': 'Best TED Talks on psychology',
      });
      expect(
        TedFeed.playlistFromEntry(p.entries.first)?.title,
        'Best TED Talks on psychology',
      );
      expect(p.continuation, isNotNull);
    });

    test('재생목록 안 영상', () {
      final p = parseBrowse(fixture('playlist'), now);
      expect(p.entries, isNotEmpty);
      expect(p.entries.first['id'], '3Ae4qCvQIcM');
      expect(p.entries.first['title'], contains('Depression'));
      expect(p.entries.first['duration'], isA<int>());
    });

    test('채널 안 검색 (예전 형식 videoRenderer)', () {
      final p = parseBrowse(fixture('search'), now);
      final first = p.entries.first;
      expect(first['id'], '8KkKuTCFvzI');
      expect(first['duration'], 12 * 60 + 47);
      expect(first['view_count'], 30553705);
      expect(
        first['timestamp'],
        now.subtract(const Duration(days: 3650)).millisecondsSinceEpoch ~/ 1000,
      );
      expect(p.continuation, isNotNull);
    });
  });

  test('표시 문자열 읽기', () {
    expect(parseClock('8:35'), 515);
    expect(parseClock('1:02:03'), 3723);
    expect(parseClock('LIVE'), isNull);
    expect(parseViewCount('29K views'), 29000);
    expect(parseViewCount('1.2M views'), 1200000);
    expect(parseViewCount('30,553,705 views'), 30553705);
    expect(parseViewCount('1 view'), 1);
    expect(parseViewCount('No views'), 0);
    expect(parseViewCount('13 hours ago'), isNull);
    expect(
      parseAgo('Streamed 2 years ago', now),
      DateTime.utc(2024, 11, 13, 12),
    );
    expect(parseAgo('3 weeks ago', now), DateTime.utc(2026, 10, 23, 12));
    expect(parseAgo('29K views', now), isNull);
  });

  test('목록 주소 → 요청', () async {
    Future<String> id(String h) async => 'UC-$h';
    expect(await browseRequestFor('https://www.youtube.com/@TED/videos', id), {
      'browseId': 'UC-TED',
      'params': 'EgZ2aWRlb3PyBgQKAjoA',
    });
    expect(
      await browseRequestFor('https://www.youtube.com/@TEDEd/playlists', id),
      {'browseId': 'UC-TEDEd', 'params': 'EglwbGF5bGlzdHPyBgQKAkIA'},
    );
    expect(await browseRequestFor(TedFeed.search('public speaking').url, id), {
      'browseId': 'UC-TED',
      'params': 'EgZzZWFyY2jyBgQKAloA',
      'query': 'public speaking',
    });
    expect(
      await browseRequestFor(
        'https://www.youtube.com/playlist?list=PLe3qqz7JaEDM',
        id,
      ),
      {'browseId': 'VLPLe3qqz7JaEDM'},
    );
    expect(await browseRequestFor('https://example.com/x', id), isNull);
  });

  test('InnertubeBrowser: 다음 페이지를 이어 받아 yt-dlp처럼 범위를 돌려준다', () async {
    final requests = <Map<String, dynamic>>[];
    // 한 번에 3개씩, 토큰 p1 → p2 → 끝
    Map<String, dynamic> page(List<int> ids, String? next) => {
      'items': [
        for (final i in ids)
          {
            'lockupViewModel': {
              'contentId': 'vid$i'.padRight(11, '_'),
              'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
              'metadata': {
                'lockupMetadataViewModel': {
                  'title': {'content': 'Talk $i'},
                },
              },
            },
          },
        if (next != null)
          {
            'continuationItemRenderer': {
              'continuationEndpoint': {
                'continuationCommand': {'token': next},
              },
            },
          },
      ],
    };
    final b = InnertubeBrowser(
      channelId: (h) async => 'UC1',
      now: () => now,
      post: (body) async {
        requests.add(body);
        return switch (body['continuation']) {
          null => page([0, 1, 2], 'p1'),
          'p1' => page([2, 3, 4, 5], 'p2'), // 2는 겹침
          _ => page([6], null),
        };
      },
    );
    const url = 'https://www.youtube.com/@TED/videos';
    List<String> titles(Map<String, dynamic> r) => [
      for (final e in r['entries'] as List) (e as Map)['title'] as String,
    ];
    expect(titles(await b.listPlaylist(url, start: 1, end: 2)), [
      'Talk 0',
      'Talk 1',
    ]);
    expect(requests.length, 1);
    expect(titles(await b.listPlaylist(url, start: 3, end: 5)), [
      'Talk 2',
      'Talk 3',
      'Talk 4',
    ]);
    expect(titles(await b.listPlaylist(url, start: 6, end: 30)), [
      'Talk 5',
      'Talk 6',
    ]);
    expect(requests.map((r) => r['continuation']), [null, 'p1', 'p2']);
    // 처음부터 다시 받으면(새로 고침) 새로 요청한다
    await b.listPlaylist(url, start: 1, end: 3);
    expect(requests.length, 4);
  });
}
