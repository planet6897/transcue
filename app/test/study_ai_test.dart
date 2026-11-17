import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:transcue/src/translate/translator.dart';

void main() {
  test('읽는 법: 조각을 이어 붙이면 원래 줄이어야 받는다', () {
    final out = furiganaOf(
      {
        'items': [
          {
            'id': 0,
            'segments': [
              {'text': '日本', 'reading': 'にほん'},
              {'text': 'へ', 'reading': ''},
              {'text': '行', 'reading': 'い'},
              {'text': 'きたい。', 'reading': ''},
            ],
          },
          {
            // 글자를 빠뜨린 응답은 버린다
            'id': 1,
            'segments': [
              {'text': '東京', 'reading': 'とうきょう'},
            ],
          },
        ],
      },
      {0: '日本へ行きたい。', 1: '東京です'},
    );
    expect(out.keys, [0]);
    expect(rubySegments(out[0]!), [
      ('日本', 'にほん'),
      ('へ', ''),
      ('行', 'い'),
      ('きたい。', ''),
    ]);
  });

  test('읽기가 없는 줄은 표시 형식에서도 그대로', () {
    expect(rubyMarkup([('ありがとう', '')]), 'ありがとう');
    expect(rubySegments('ありがとう'), [('ありがとう', '')]);
  });

  test('읽는 법은 시간을 바꿔도 남는다', () {
    const c = BilingualCue(
      start: Duration(seconds: 1),
      end: Duration(seconds: 2),
      original: '日本',
    );
    final r = c.withRuby(rubyMarkup([('日本', 'にほん')]));
    final moved = r.withTimes(Duration.zero, const Duration(seconds: 1));
    expect(moved.ruby, r.ruby);
    expect(BilingualCue.fromJson(moved.toJson()).ruby, r.ruby);
  });

  test('문장 해설 응답 해석', () {
    final e = explanationOf({
      'points': [
        {'phrase': 'fall apart', 'note': '무너지다, 끝장나다'},
      ],
      'nuance': '담담하게 말하지만 아쉬움이 묻어난다.',
    });
    expect(e.points.single.phrase, 'fall apart');
    expect(e.asText, 'fall apart: 무너지다, 끝장나다\n담담하게 말하지만 아쉬움이 묻어난다.');
  });
}
