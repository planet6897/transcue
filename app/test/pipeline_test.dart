import 'package:dualcue/src/pipeline/media_tools.dart';
import 'package:dualcue/src/pipeline/whisper.dart';
import 'package:dualcue/src/settings/app_settings.dart';
import 'package:dualcue/src/translate/claude_translator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseWhisperLine', () {
    test('segment', () {
      final c = parseWhisperLine(
        '[00:01:02.250 --> 00:01:04.000]   Michael, you must listen.',
      )!;
      expect(
        c.start,
        const Duration(minutes: 1, seconds: 2, milliseconds: 250),
      );
      expect(c.end, const Duration(minutes: 1, seconds: 4));
      expect(c.original, 'Michael, you must listen.');
    });
    test('non-segment lines', () {
      expect(parseWhisperLine('whisper_init_from_file: loading model'), isNull);
      expect(parseWhisperLine('[00:00:00.000 --> 00:00:01.000]   '), isNull);
    });
  });

  group('MediaInfo.fromProbeJson', () {
    test('text subtitles only, English preferred, Korean detected', () {
      final info = MediaInfo.fromProbeJson({
        'format': {'duration': '5765.439000'},
        'streams': [
          {'codec_type': 'video', 'codec_name': 'h264'},
          {'codec_type': 'audio', 'codec_name': 'aac'},
          {
            'codec_type': 'subtitle',
            'codec_name': 'hdmv_pgs_subtitle',
            'tags': {'language': 'eng'},
          },
          {
            'codec_type': 'subtitle',
            'codec_name': 'subrip',
            'tags': {'language': 'spa'},
          },
          {
            'codec_type': 'subtitle',
            'codec_name': 'ass',
            'tags': {'language': 'eng'},
          },
          {
            'codec_type': 'subtitle',
            'codec_name': 'subrip',
            'tags': {'language': 'kor'},
          },
        ],
      });
      expect(info.duration, const Duration(milliseconds: 5765439));
      expect(info.subtitles.map((s) => s.index), [1, 2, 3]); // PGS(0) 제외
      expect(info.originalTrack?.index, 2);
      expect(info.koreanTrack?.index, 3);
    });
    test('no subtitles', () {
      final info = MediaInfo.fromProbeJson({
        'format': {'duration': '10'},
        'streams': [
          {'codec_type': 'audio', 'codec_name': 'aac'},
        ],
      });
      expect(info.originalTrack, isNull);
    });
  });

  group('ClaudeTranslator', () {
    const batch = TranslationBatch(
      sourceLang: 'en',
      context: [('Hello.', '안녕.'), ('Wait', null)],
      items: {7: 'Who are you?', 8: "I'm KITT."},
    );

    test('request body', () {
      final t = ClaudeTranslator(apiKey: 'k', model: ClaudeModel.opus);
      final b = t.buildBody(batch);
      expect(b['model'], 'claude-opus-5-5');
      expect(b['fallbacks'], 'default');
      expect(t.headers['anthropic-version'], '2026-10-21');
      expect(t.headers['anthropic-beta'], 'server-side-fallback-2026-07-01');
      final oc = b['output_config'] as Map;
      expect(oc['effort'], 'low');
      expect((oc['format'] as Map)['type'], 'json_schema');
      final content =
          ((b['messages'] as List).single as Map)['content'] as String;
      expect(content, contains('"id":7'));
      expect(content, contains('"korean":"안녕."'));
      expect(content, isNot(contains('"korean":null')));
    });

    test('haiku has no fallbacks', () {
      final t = ClaudeTranslator(apiKey: 'k', model: ClaudeModel.haiku);
      expect(t.buildBody(batch).containsKey('fallbacks'), isFalse);
      expect(t.headers.containsKey('anthropic-beta'), isFalse);
    });

    test('parse response (thinking block ignored)', () {
      final out = ClaudeTranslator.parseResponse({
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'thinking', 'thinking': ''},
          {
            'type': 'text',
            'text':
                '{"translations":[{"id":7,"text":" 누구세요? "},{"id":8,"text":"나는 키트야."}]}',
          },
        ],
      });
      expect(out, {7: '누구세요?', 8: '나는 키트야.'});
    });

    test('refusal', () {
      expect(
        () => ClaudeTranslator.parseResponse({
          'stop_reason': 'refusal',
          'content': [],
        }),
        throwsA(isA<TranslateException>()),
      );
    });
  });
}
