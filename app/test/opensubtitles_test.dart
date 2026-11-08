import 'dart:io';

import 'package:dualcue/src/online/opensubtitles.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseReleaseName', () {
    test('TV episode with title after code', () {
      final r = parseReleaseName(
        '/x/Knight Rider (1982)/Season 1/Knight Rider S01E01-E02 Knight of the Phoenix.mkv',
      );
      expect(r.title, 'Knight Rider');
      expect((r.season, r.episode), (1, 1));
      expect(r.isEpisode, isTrue);
    });
    test('dotted scene release', () {
      final r = parseReleaseName(
        'Breaking.Bad.S05E14.Ozymandias.1080p.WEB-DL.mkv',
      );
      expect(r.title, 'Breaking Bad');
      expect((r.season, r.episode), (5, 14));
    });
    test('movie with year', () {
      final r = parseReleaseName('The.Matrix.1999.1080p.BluRay.x264.mkv');
      expect(r.title, 'The Matrix');
      expect(r.year, 1999);
      expect(r.isEpisode, isFalse);
    });
    test('movie with year in parentheses', () {
      final r = parseReleaseName('Blade Runner (1982).mp4');
      expect(r.title, 'Blade Runner');
      expect(r.year, 1982);
    });
    test('plain name', () {
      expect(parseReleaseName('home_video.mov').title, 'home video');
    });
  });

  test('osLang', () {
    expect(osLang('eng'), 'en');
    expect(osLang(null), 'en');
    expect(osLang('jpn'), 'ja');
    expect(osLang('kor'), 'ko');
    expect(osLang('chi'), 'zh-cn');
  });

  group('search results', () {
    Map<String, Object?> sub(
      int id,
      String lang, {
      bool hash = false,
      int dl = 0,
      bool ai = false,
      int files = 1,
    }) => {
      'attributes': {
        'language': lang,
        'moviehash_match': hash,
        'download_count': dl,
        'ai_translated': ai,
        'machine_translated': false,
        'release': 'r$id',
        'files': [
          for (var i = 0; i < files; i++) {'file_id': id * 10 + i},
        ],
      },
    };

    test('parse + pick best: hash > human > downloads', () {
      final hits = SubtitleHit.fromSearchJson({
        'data': [
          sub(1, 'en', dl: 9000),
          sub(2, 'en', hash: true, dl: 10),
          sub(3, 'ko', dl: 500, ai: true),
          sub(4, 'ko', dl: 100),
          sub(5, 'en', hash: true, dl: 99, files: 2), // CD1/CD2 → 제외
        ],
      });
      expect(hits.length, 4);
      expect(pickBest(hits, 'en')?.fileId, 20);
      expect(pickBest(hits, 'ko')?.fileId, 40);
      expect(pickBest(hits, 'ja'), isNull);
    });
  });

  test('openSubtitlesHash matches reference implementation', () async {
    final dir = await Directory.systemTemp.createTemp('oshash');
    try {
      // 결정적인 바이트로 200KB 파일 생성 (아래 기대값은 Python 참조 구현으로 계산)
      final f = File('${dir.path}/a.bin');
      await f.writeAsBytes([
        for (var i = 0; i < 200000; i++) (i * 31 + 7) & 0xff,
      ]);
      expect(await openSubtitlesHash(f), _expected200k);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  group('matchesRelease (이름 검색 결과 검증)', () {
    SubtitleHit hit({
      String title = '',
      String parent = '',
      int? season,
      int? episode,
      bool hash = false,
    }) => SubtitleHit(
      fileId: 1,
      language: 'en',
      hashMatch: hash,
      downloads: 0,
      machine: false,
      release: '',
      title: title,
      parentTitle: parent,
      season: season,
      episode: episode,
    );

    test('real case: different show with overlapping words is rejected', () {
      final name = parseReleaseName(
        '/x/2 Broke Girls (2011)/Featurettes/Season 1/2 Girls Going 4 Broke.mkv',
      );
      expect(
        matchesRelease(hit(title: 'Chief Daddy 2: Going for Broke'), name),
        isFalse,
      );
    });
    test('same show, right episode', () {
      final name = parseReleaseName(
        'Knight Rider S01E01-E02 Knight of the Phoenix.mkv',
      );
      expect(
        matchesRelease(
          hit(
            title: 'Knight of the Phoenix',
            parent: 'Knight Rider',
            season: 1,
            episode: 1,
          ),
          name,
        ),
        isTrue,
      );
    });
    test('same show, wrong episode is rejected', () {
      final name = parseReleaseName('Knight Rider S01E01.mkv');
      expect(
        matchesRelease(
          hit(parent: 'Knight Rider', season: 1, episode: 5),
          name,
        ),
        isFalse,
      );
    });
    test('hash match is always trusted', () {
      final name = parseReleaseName('totally_random_name.mkv');
      expect(
        matchesRelease(hit(title: 'Something Else', hash: true), name),
        isTrue,
      );
    });
    test('movie title', () {
      final name = parseReleaseName('The.Matrix.1999.1080p.mkv');
      expect(matchesRelease(hit(title: 'The Matrix'), name), isTrue);
      expect(matchesRelease(hit(title: 'The Matrix Reloaded'), name), isFalse);
    });
    test('pickBest skips non-matching titles', () {
      final name = parseReleaseName('2 Girls Going 4 Broke.mkv');
      expect(
        pickBest(
          [hit(title: 'Chief Daddy 2: Going for Broke')],
          'en',
          name: name,
        ),
        isNull,
      );
    });
  });
}

const _expected200k = '5f9fe02060a3cd40';
