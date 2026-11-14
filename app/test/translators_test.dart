import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/settings/app_settings.dart';
import 'package:transcue/src/translate/claude_translator.dart';
import 'package:transcue/src/translate/gemini_translator.dart';
import 'package:transcue/src/translate/openai_translator.dart';
import 'package:transcue/src/translate/translators.dart';

const _batch = TranslationBatch(
  sourceLang: 'en',
  context: [('Hello.', '안녕.'), ('Wait', null)],
  items: {7: 'Who are you?', 8: "I'm KITT."},
);

const _answer =
    '{"translations":[{"id":7,"text":" 누구세요? "},{"id":8,"text":"나는 키트야."}]}';

void main() {
  group('OpenAiTranslator', () {
    final t = OpenAiTranslator(apiKey: 'k', model: OpenAiModel.sol);

    test('request body', () {
      final b = t.buildBody(_batch);
      expect(b['model'], 'gpt-6.1-sol');
      expect(b['store'], false);
      expect((b['reasoning'] as Map)['effort'], 'low');
      final format = (b['text'] as Map)['format'] as Map;
      expect(format['type'], 'json_schema');
      expect(format['strict'], true);
      expect(format['name'], isNotEmpty);
      expect((format['schema'] as Map)['required'], ['translations']);
      final input = (b['input'] as List).cast<Map>();
      expect(input.first['role'], 'system');
      final content = input.last['content'] as String;
      expect(content, contains('"id":7'));
      expect(content, contains('"korean":"안녕."'));
      expect(content, isNot(contains('"korean":null')));
      expect(t.headers['authorization'], 'Bearer k');
      expect(t.endpoint.toString(), 'https://api.openai.com/v1/responses');
    });

    test('vocab request uses the vocab schema', () {
      final b = t.buildVocabBody(
        const VocabBatch(sourceLang: 'en', items: {0: 'He was abducted.'}),
        VocabLevel.intermediate,
      );
      final format = (b['text'] as Map)['format'] as Map;
      expect((format['schema'] as Map)['required'], ['items']);
    });

    test('parse response (reasoning item ignored)', () {
      final out = t.outputJson({
        'status': 'completed',
        'output': [
          {'type': 'reasoning', 'summary': []},
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'annotations': [], 'text': _answer},
            ],
          },
        ],
      });
      expect(translationsOf(out), {7: '누구세요?', 8: '나는 키트야.'});
    });

    test('refusal is not retried', () {
      expect(
        () => t.outputJson({
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'refusal', 'refusal': 'no'},
              ],
            },
          ],
        }),
        throwsA(
          isA<TranslateException>().having(
            (e) => e.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
    });

    test('cut off before any text', () {
      expect(
        () => t.outputJson({
          'status': 'incomplete',
          'incomplete_details': {'reason': 'max_output_tokens'},
          'output': [],
        }),
        throwsA(
          isA<TranslateException>().having(
            (e) => e.message,
            'message',
            contains('max_output_tokens'),
          ),
        ),
      );
    });

    test('broken JSON is retried', () {
      expect(
        () => t.outputJson({
          'status': 'completed',
          'output': [
            {
              'type': 'message',
              'content': [
                {'type': 'output_text', 'text': '{"translations":['},
              ],
            },
          ],
        }),
        throwsA(
          isA<TranslateException>().having(
            (e) => e.retryable,
            'retryable',
            isTrue,
          ),
        ),
      );
    });
  });

  group('GeminiTranslator', () {
    final t = GeminiTranslator(apiKey: 'k', model: GeminiModel.hydrogen);

    test('request body', () {
      final b = t.buildBody(_batch);
      expect(b['model'], 'gemini-4-hydrogen');
      expect(b['store'], false);
      expect(b['system_instruction'], contains('Korean'));
      expect((b['generation_config'] as Map)['thinking_level'], 'low');
      final format = b['response_format'] as Map;
      expect(format['type'], 'text');
      expect(format['mime_type'], 'application/json');
      expect((format['schema'] as Map)['required'], ['translations']);
      final input = b['input'] as String;
      expect(input, contains('"id":7'));
      expect(input, contains('"korean":"안녕."'));
      expect(t.headers['x-goog-api-key'], 'k');
      expect(
        t.endpoint.toString(),
        'https://generativelanguage.googleapis.com/v1beta/interactions',
      );
    });

    test('parse response (other steps ignored)', () {
      final out = t.outputJson({
        'status': 'completed',
        'steps': [
          {'type': 'thought', 'summary': []},
          {
            'type': 'model_output',
            'content': [
              {'type': 'text', 'text': _answer},
            ],
          },
        ],
      });
      expect(translationsOf(out), {7: '누구세요?', 8: '나는 키트야.'});
    });

    test('cut off', () {
      expect(
        () => t.outputJson({'status': 'incomplete', 'steps': []}),
        throwsA(isA<TranslateException>()),
      );
    });

    test('failed is retried with the server message', () {
      expect(
        () => t.outputJson({
          'status': 'failed',
          'errors': [
            {'code': 'internal', 'message': 'boom'},
          ],
        }),
        throwsA(
          isA<TranslateException>()
              .having((e) => e.retryable, 'retryable', isTrue)
              .having((e) => e.message, 'message', contains('boom')),
        ),
      );
    });

    test('no text (blocked) is not retried', () {
      expect(
        () => t.outputJson({'status': 'completed', 'steps': []}),
        throwsA(
          isA<TranslateException>().having(
            (e) => e.retryable,
            'retryable',
            isFalse,
          ),
        ),
      );
    });
  });

  group('HTTP errors', () {
    final t = GeminiTranslator(apiKey: 'k', model: GeminiModel.hydrogen);

    test('names the provider and reads the server message', () {
      final e = t.httpError(400, '{"error":{"message":"API key not valid"}}');
      expect(e.message, 'Gemini API 오류 400: API key not valid');
      expect(e.retryable, isFalse);
    });

    test('429 and 5xx are retried, 401 is not', () {
      expect(t.httpError(429, 'slow down').retryable, isTrue);
      expect(t.httpError(503, '').retryable, isTrue);
      expect(t.httpError(401, '').retryable, isFalse);
      expect(t.httpError(401, '').message, contains('Gemini API 키'));
    });
  });

  group('provider choice', () {
    test('default is Claude, as before', () {
      final s = AppSettings(claudeApiKey: 'c');
      expect(s.provider, TranslateProvider.claude);
      expect(s.hasTranslateKey, isTrue);
      expect(createTranslator(s), isA<ClaudeTranslator>());
    });

    test('key and model follow the chosen provider', () {
      final s = AppSettings(
        claudeApiKey: 'c',
        provider: TranslateProvider.openai,
        openaiModel: OpenAiModel.luna,
      );
      // Claude 키만 있고 OpenAI 키는 없다
      expect(s.hasTranslateKey, isFalse);
      s.openaiApiKey = ' o ';
      expect(s.hasTranslateKey, isTrue);
      expect(s.translateModelLabel, 'GPT-6 Luna');
      final t = createTranslator(s) as OpenAiTranslator;
      expect(t.apiKey, 'o');
      expect(t.model, OpenAiModel.luna);

      s
        ..provider = TranslateProvider.gemini
        ..geminiApiKey = 'g';
      expect(s.translateModelLabel, 'Gemini 4 Hydrogen');
      expect(createTranslator(s), isA<GeminiTranslator>());
    });
  });
}
