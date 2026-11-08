import 'dart:convert';

import 'package:transcue/src/settings/app_settings.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';
import 'package:transcue/src/subtitle/dual_subtitle_overlay.dart';
import 'package:transcue/src/translate/claude_translator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('highlightSegments', () {
    test('case-insensitive, multi-word, keeps the rest', () {
      expect(
        highlightSegments('They ABDUCTED him and picked it up.', [
          'abducted',
          'picked it up',
        ]),
        [
          ('They ', false),
          ('ABDUCTED', true),
          (' him and ', false),
          ('picked it up', true),
          ('.', false),
        ],
      );
    });
    test('whole words only', () {
      expect(highlightSegments('Start the art.', ['art']), [
        ('Start the ', false),
        ('art', true),
        ('.', false),
      ]);
    });
    test('no targets / not found', () {
      expect(highlightSegments('Hello.', []), [('Hello.', false)]);
      expect(highlightSegments('Hello.', ['bye']), [('Hello.', false)]);
    });
  });

  group('vocab response', () {
    Map<String, dynamic> resp(Object items) => {
      'stop_reason': 'end_turn',
      'content': [
        {'type': 'thinking', 'thinking': ''},
        {
          'type': 'text',
          'text': jsonEncode({'items': items}),
        },
      ],
    };

    test('keeps words found in the line, max 2, drops hallucinated ones', () {
      final out = ClaudeTranslator.parseVocabResponse(
        resp([
          {
            'id': 0,
            'words': [
              {
                'text': 'abducted',
                'lemma': 'abduct',
                'pos': '동',
                'meaning': '납치하다',
              },
              {
                'text': 'ransom',
                'lemma': 'ransom',
                'pos': '명',
                'meaning': '몸값',
              }, // 줄에 없음
              {
                'text': 'Wilton',
                'lemma': 'Wilton',
                'pos': '명',
                'meaning': '이름',
              },
              {
                'text': 'reckless',
                'lemma': 'reckless',
                'pos': '형',
                'meaning': '무모한',
              },
            ],
          },
          {'id': 1, 'words': []},
        ]),
        {0: 'Wilton was abducted by a reckless gang.', 1: 'Hello.'},
      );
      expect(out[0]!.map((w) => w.lemma), ['abduct', 'Wilton']);
      expect(out[1], isEmpty);
    });

    test('request carries the learner level', () {
      final t = ClaudeTranslator(apiKey: 'k', model: ClaudeModel.haiku);
      final b = t.buildVocabBody(
        const VocabBatch(sourceLang: 'en', items: {0: 'Hi.'}),
        VocabLevel.advanced,
      );
      expect(b['model'], 'claude-haiku-5-5');
      expect(b['system'] as String, contains('B2'));
      expect(
        ((b['output_config'] as Map)['format'] as Map)['type'],
        'json_schema',
      );
    });
  });

  test('cue json keeps words; null vs empty distinguished', () {
    const w = VocabItem(
      text: 'abducted',
      lemma: 'abduct',
      pos: '동',
      meaning: '납치하다',
    );
    const c = BilingualCue(
      start: Duration(seconds: 1),
      end: Duration(seconds: 2),
      original: 'He was abducted.',
      translation: '그는 납치됐다.',
      words: [w],
    );
    final back = BilingualCue.fromJson(
      jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>,
    );
    expect(back.words, [w]);
    expect(back.withTranslation('x').words, [w]); // 번역이 바뀌어도 단어 유지
    expect(
      BilingualCue.fromJson(
        jsonDecode(jsonEncode(c.withWords(const []).toJson()))
            as Map<String, dynamic>,
      ).words,
      isEmpty,
    );
    expect(
      BilingualCue.fromJson(
        jsonDecode(jsonEncode(c.withWords(null).toJson()))
            as Map<String, dynamic>,
      ).words,
      isNull,
    );
  });

  testWidgets('vocab panel shows only when enabled', (t) async {
    const cue = BilingualCue(
      start: Duration.zero,
      end: Duration(seconds: 2),
      original: 'He was abducted.',
      words: [
        VocabItem(text: 'abducted', lemma: 'abduct', pos: '동', meaning: '납치하다'),
      ],
    );
    Future<void> show(bool on) => t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DualSubtitleOverlay(cue: cue, showVocab: on),
        ),
      ),
    );
    await show(false);
    expect(find.textContaining('납치하다', findRichText: true), findsNothing);
    await show(true);
    expect(find.textContaining('납치하다', findRichText: true), findsOneWidget);
    expect(find.textContaining('abduct', findRichText: true), findsWidgets);
  });
}
