import 'dart:convert';
import 'dart:io';

import '../settings/app_settings.dart';
import '../subtitle/bilingual_cue.dart';

class TranslateException implements Exception {
  const TranslateException(this.message, {this.retryable = false});
  final String message;
  final bool retryable;
  @override
  String toString() => message;
}

/// 번역 요청 한 묶음. id는 자막 목록에서의 위치.
class TranslationBatch {
  const TranslationBatch({
    required this.sourceLang,
    required this.context,
    required this.items,
  });

  final String sourceLang;

  /// 직전 자막(원문, 번역) — 문맥·용어 일관성용, 번역하지 않음
  final List<(String, String?)> context;
  final Map<int, String> items;
}

/// 학습 단어 추출 요청 한 묶음. id는 묶음 안 순번.
class VocabBatch {
  const VocabBatch({required this.sourceLang, required this.items});
  final String sourceLang;
  final Map<int, String> items;
}

/// 공급자 공통 인터페이스 (Claude / OpenAI / Gemini)
abstract interface class Translator {
  Future<Map<int, String>> translate(TranslationBatch batch);

  /// 학습 단어 추출 (줄 id → 단어 0~2개)
  Future<Map<int, List<VocabItem>>> extractVocab(
    VocabBatch batch,
    VocabLevel level,
  );
}

const translateSystem = '''
You translate video subtitles into natural, spoken Korean for Korean learners of the source language.
Rules:
- Translate each item independently: exactly one Korean line per input id, never merge or split items.
- Keep the meaning of the speaker's words; use natural conversational Korean that matches the tone (casual vs. polite) and stays consistent with the context.
- Keep proper nouns consistent with the context. Keep sound tags like [Music] or (laughs) as short Korean tags, e.g. [음악], (웃음).
- Output only the JSON object defined by the schema.''';

const translateSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'translations': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'text': {'type': 'string'},
        },
        'required': ['id', 'text'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['translations'],
  'additionalProperties': false,
};

String vocabSystem(VocabLevel level) =>
    '''
You help a Korean learner study the source language while watching a video.
The learner's level is ${level.cefr} (${level.description}).
For each subtitle line, pick 0 to 2 words or short expressions (phrasal verbs, idioms, collocations)
that this learner is likely not to know and that are worth learning.
Rules:
- Skip words the learner surely knows at this level, names of people/places, and sound tags.
- "text": copy the word or expression exactly as it appears in the line (same spelling and case), so it can be highlighted.
- "lemma": dictionary form (e.g. "abducted" → "abduct", "picked it up" → "pick up").
- "pos": Korean part-of-speech abbreviation: 명, 동, 형, 부, 전, 접, 구(phrase/idiom).
- "meaning": a short Korean meaning that fits THIS line's context, at most 12 characters.
- Return every input id, with an empty "words" list when nothing is worth learning.
- Output only the JSON object defined by the schema.''';

const vocabSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'items': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'words': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
                'lemma': {'type': 'string'},
                'pos': {'type': 'string'},
                'meaning': {'type': 'string'},
              },
              'required': ['text', 'lemma', 'pos', 'meaning'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['id', 'words'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['items'],
  'additionalProperties': false,
};

/// 모델이 돌려준 JSON 글자를 읽는다. 깨진 JSON은 다시 요청하면 되는 오류로 본다.
Map<String, dynamic> decodeModelJson(String text) {
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } on FormatException {
    throw const TranslateException('응답 형식 오류', retryable: true);
  } on TypeError {
    throw const TranslateException('응답 형식 오류', retryable: true);
  }
}

/// 번역 결과 JSON → 줄 id별 한국어
Map<int, String> translationsOf(Map<String, dynamic> out) => {
  for (final t in (out['translations'] as List).cast<Map>())
    (t['id'] as num).toInt(): (t['text'] as String).trim(),
};

/// 학습 단어 결과 JSON → 줄 id별 단어. 자막에 실제로 없는 표현은 버린다 (강조 표시 불가).
Map<int, List<VocabItem>> vocabOf(
  Map<String, dynamic> out,
  Map<int, String> lines,
) {
  final result = <int, List<VocabItem>>{};
  for (final it in (out['items'] as List).cast<Map>()) {
    final id = (it['id'] as num).toInt();
    final line = (lines[id] ?? '').toLowerCase();
    result[id] = [
      for (final w in (it['words'] as List).cast<Map>())
        if ('${w['text']}'.trim().isNotEmpty &&
            line.contains('${w['text']}'.trim().toLowerCase()))
          VocabItem(
            text: '${w['text']}'.trim(),
            lemma: '${w['lemma']}'.trim(),
            pos: '${w['pos']}'.trim(),
            meaning: '${w['meaning']}'.trim(),
          ),
    ].take(2).toList();
  }
  return result;
}

/// REST로 부르는 LLM 번역기의 공통 부분: 요청 내용, 재시도, 오류 안내.
/// 공급자마다 다른 것(주소·헤더·요청 틀·응답에서 JSON 꺼내기)만 하위 클래스가 정한다.
abstract class LlmTranslator implements Translator {
  /// 오류 안내에 쓰는 공급자 이름 (예: 'Claude')
  String get providerName;

  Uri get endpoint;

  Map<String, String> get headers;

  /// 시스템 지시문·출력 스키마·입력을 공급자의 요청 형식으로 감싼다
  Map<String, Object?> envelope(
    String system,
    Map<String, Object?> schema,
    Object payload,
  );

  /// 응답에서 모델이 만든 JSON을 꺼낸다. 거절·잘림은 [TranslateException].
  Map<String, dynamic> outputJson(Map<String, dynamic> response);

  /// 번역 요청 본문 (테스트용으로 분리)
  Map<String, Object?> buildBody(TranslationBatch b) =>
      envelope(translateSystem, translateSchema, {
        'source_language': b.sourceLang,
        'target_language': 'ko',
        'context': [
          for (final (o, t) in b.context) {'original': o, 'korean': ?t},
        ],
        'items': [
          for (final e in b.items.entries) {'id': e.key, 'text': e.value},
        ],
      });

  /// 학습 단어 요청 본문 (테스트용으로 분리)
  Map<String, Object?> buildVocabBody(VocabBatch b, VocabLevel level) =>
      envelope(vocabSystem(level), vocabSchema, {
        'source_language': b.sourceLang,
        'items': [
          for (final e in b.items.entries) {'id': e.key, 'text': e.value},
        ],
      });

  @override
  Future<Map<int, String>> translate(TranslationBatch batch) => _request(
    jsonEncode(buildBody(batch)),
    (j) => translationsOf(outputJson(j)),
  );

  @override
  Future<Map<int, List<VocabItem>>> extractVocab(
    VocabBatch batch,
    VocabLevel level,
  ) => _request(
    jsonEncode(buildVocabBody(batch, level)),
    (j) => vocabOf(outputJson(j), batch.items),
  );

  Future<T> _request<T>(
    String body,
    T Function(Map<String, dynamic>) parse,
  ) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return parse(await _post(body));
      } on TranslateException catch (e) {
        if (!e.retryable || attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      } on IOException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  }

  Future<Map<String, dynamic>> _post(String body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.postUrl(endpoint);
      headers.forEach(req.headers.set);
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(minutes: 5));
      final text = await res.transform(utf8.decoder).join();
      final code = res.statusCode;
      if (code == 200) return jsonDecode(text) as Map<String, dynamic>;
      throw httpError(code, text);
    } finally {
      client.close();
    }
  }

  /// HTTP 오류 → 사용자에게 보일 안내 (테스트용으로 분리)
  TranslateException httpError(int code, String body) {
    var msg = body;
    try {
      msg = (jsonDecode(body) as Map)['error']['message'] as String;
    } catch (_) {}
    if (code == 401) {
      return TranslateException('$providerName API 키가 올바르지 않습니다 (설정 확인)');
    }
    if (code == 402 || code == 403) {
      return TranslateException('$providerName API 사용 불가 ($code): $msg');
    }
    // 429 요청 제한, 5xx/529 서버 과부하 → 재시도
    final retry = code == 429 || code >= 500;
    return TranslateException(
      '$providerName API 오류 $code: $msg',
      retryable: retry,
    );
  }
}
