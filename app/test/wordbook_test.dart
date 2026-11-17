import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/study/wordbook.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

const _cue = BilingualCue(
  start: Duration(seconds: 12),
  end: Duration(seconds: 15),
  original: 'He was abducted, "allegedly".',
  translation: '그는 납치됐다, "주장에 따르면".',
);

const _word = VocabItem(
  text: 'abducted',
  lemma: 'abduct',
  pos: '동',
  meaning: '납치하다',
);

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('wordbook'));
  tearDown(() => dir.deleteSync(recursive: true));

  Wordbook book() => Wordbook(Future.value(File('${dir.path}/wb.json')));

  test('넣었다 빼기, 파일에 남는다', () async {
    final b = book();
    final w = StudyItem.ofWord(_word, _cue, source: '/v.mp4', title: 'v');
    final s = StudyItem.ofSentence(_cue, source: '/v.mp4', title: 'v');
    expect(await b.toggle(w), isTrue);
    expect(await b.toggle(s), isTrue);
    expect(b.hasWord('Abduct'), isTrue);
    expect(b.hasSentence('/v.mp4', _cue.start), isTrue);

    final again = book();
    await again.load();
    expect(again.items.map((e) => e.key), [s.key, w.key]); // 최근 것이 앞
    expect(again.items.last.meaning, '납치하다');

    expect(await again.toggle(w), isFalse);
    expect(again.hasWord('abduct'), isFalse);
    expect(again.items, hasLength(1));
  });

  test('같은 단어는 다른 영상에서 모아도 하나', () async {
    final b = book();
    await b.toggle(StudyItem.ofWord(_word, _cue, source: '/a', title: 'a'));
    final added = await b.toggle(
      StudyItem.ofWord(_word, _cue, source: '/b', title: 'b'),
    );
    expect(added, isFalse); // 이미 있어서 뺀다
    expect(b.items, isEmpty);
  });

  test('CSV: 머리줄, 쉼표·따옴표 감싸기', () {
    final csv = wordbookCsv([
      StudyItem.ofWord(_word, _cue, source: '/v.mp4', title: 'My, video'),
    ]);
    final lines = csv.split('\r\n');
    expect(lines[0], '﻿단어,품사,뜻,문장,번역,영상,시간');
    expect(
      lines[1],
      'abduct,동,납치하다,"He was abducted, ""allegedly"".",'
      '"그는 납치됐다, ""주장에 따르면"".","My, video",00:12',
    );
  });

  test('지금 문장 번호', () {
    final cues = [
      const BilingualCue(
        start: Duration(seconds: 1),
        end: Duration(seconds: 2),
        original: 'a',
      ),
      const BilingualCue(
        start: Duration(seconds: 5),
        end: Duration(seconds: 6),
        original: 'b',
      ),
    ];
    expect(lastCueIndexBefore(cues, Duration.zero), -1);
    expect(lastCueIndexBefore(cues, const Duration(seconds: 3)), 0);
    expect(lastCueIndexBefore(cues, const Duration(seconds: 5)), 1);
  });
}
