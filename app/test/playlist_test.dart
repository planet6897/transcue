import 'dart:io';

import 'package:transcue/src/player/playlist.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('자연 정렬: E2 < E10', () {
    final l = ['Show S01E10.mkv', 'Show S01E2.mkv', 'Show S01E01.mkv']
      ..sort(naturalCompare);
    expect(l, ['Show S01E01.mkv', 'Show S01E2.mkv', 'Show S01E10.mkv']);
  });

  test('동영상만, 숨김 파일 제외', () {
    final names = ['a.srt', '._b.mkv', 'b.mkv', 'c.MP4', 'cover.jpg'];
    expect(neighborName(names, 'b.mkv', 1), 'c.MP4');
    expect(neighborName(names, 'b.mkv', -1), isNull);
    expect(neighborName(names, 'c.MP4', 1), isNull);
  });

  group('neighborVideo (실제 폴더)', () {
    late Directory root;
    String p(String rel) => '${root.path}/$rel';
    setUp(() {
      root = Directory.systemTemp.createTempSync('dualcue_pl');
      for (final f in [
        'Season 1/S01E01.mkv',
        'Season 1/S01E02.mkv',
        'Season 1/S01E02.srt',
        'Season 2/S02E01.mkv',
        'Season 2/S02E02.mkv',
        'Season 10/S10E01.mkv',
      ]) {
        File(p(f)).createSync(recursive: true);
      }
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('같은 폴더 다음/이전', () {
      expect(neighborVideo(p('Season 1/S01E01.mkv')), p('Season 1/S01E02.mkv'));
      expect(
        neighborVideo(p('Season 1/S01E02.mkv'), delta: -1),
        p('Season 1/S01E01.mkv'),
      );
    });

    test('폴더 끝이면 다음 시즌 첫 화 / 이전 시즌 마지막 화', () {
      expect(neighborVideo(p('Season 1/S01E02.mkv')), p('Season 2/S02E01.mkv'));
      expect(
        neighborVideo(p('Season 2/S02E01.mkv'), delta: -1),
        p('Season 1/S01E02.mkv'),
      );
      expect(
        neighborVideo(p('Season 2/S02E02.mkv')),
        p('Season 10/S10E01.mkv'),
      );
    });

    test('마지막이면 null', () {
      expect(neighborVideo(p('Season 10/S10E01.mkv')), isNull);
    });
  });
}
