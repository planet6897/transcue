import 'dart:async';
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

/// 문장 해설 요청: 해설할 문장과 앞뒤 문맥
class ExplainRequest {
  const ExplainRequest({
    required this.sourceLang,
    required this.sentence,
    this.translation,
    this.before = const [],
    this.after = const [],
  });
  final String sourceLang;
  final String sentence;
  final String? translation;
  final List<String> before;
  final List<String> after;
}

/// 문장 해설: 짚어 볼 표현들과 문장 전체의 뉘앙스
class Explanation {
  const Explanation({required this.points, required this.nuance});
  final List<({String phrase, String note})> points;
  final String nuance;

  /// 단어장에 함께 저장할 글
  String get asText => [
    for (final p in points) '${p.phrase}: ${p.note}',
    if (nuance.isNotEmpty) nuance,
  ].join('\n');
}

/// 공급자 공통 인터페이스 (Claude / OpenAI / Gemini)
abstract interface class Translator {
  /// 문장 하나를 학습자에게 풀어 설명한다
  Future<Explanation> explain(ExplainRequest req, VocabLevel level);

  /// 일본어 줄마다 한자에 읽는 법을 단다 (줄 id → [rubyMarkup] 형식)
  Future<Map<int, String>> furigana(Map<int, String> lines);

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

String explainSystem(VocabLevel level) =>
    '''
You are a friendly tutor explaining one line of a video's subtitles to a Korean learner of the source language.
The learner's level is ${level.cefr} (${level.description}).
Rules:
- Write every explanation in Korean, short and concrete.
- "points": 1 to 4 items. Each "phrase" is copied exactly from the line (a word, expression, grammar pattern or idiom worth knowing);
  "note" explains its meaning, the grammar or usage, and why it is used here, in 1-2 sentences.
  Prefer what this learner would find hard; skip trivial words.
- "nuance": 1-2 sentences on the tone, feeling or implied meaning of the whole line in this context (casual/polite, sarcasm, emotion).
- The surrounding lines are context only; explain only the target line.
- Output only the JSON object defined by the schema.''';

const explainSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'points': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'phrase': {'type': 'string'},
          'note': {'type': 'string'},
        },
        'required': ['phrase', 'note'],
        'additionalProperties': false,
      },
    },
    'nuance': {'type': 'string'},
  },
  'required': ['points', 'nuance'],
  'additionalProperties': false,
};

Explanation explanationOf(Map<String, dynamic> out) => Explanation(
  points: [
    for (final p in (out['points'] as List).cast<Map>())
      (phrase: '${p['phrase']}'.trim(), note: '${p['note']}'.trim()),
  ],
  nuance: '${out['nuance'] ?? ''}'.trim(),
);

const furiganaSystem = '''
You add furigana (hiragana readings) to Japanese subtitle lines.
For each line, return "segments" that, concatenated, reproduce the line EXACTLY (same characters, same order, nothing added or removed).
Split the line so that every run of kanji (with its okurigana left outside) is its own segment with "reading" in hiragana,
read as it is pronounced in this context. All other text (kana, punctuation, latin, numbers) goes in segments with an empty "reading".
Return every input id. Output only the JSON object defined by the schema.''';

const furiganaSchema = <String, Object?>{
  'type': 'object',
  'properties': {
    'items': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer'},
          'segments': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'},
                'reading': {'type': 'string'},
              },
              'required': ['text', 'reading'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['id', 'segments'],
        'additionalProperties': false,
      },
    },
  },
  'required': ['items'],
  'additionalProperties': false,
};

/// 읽는 법 결과 JSON → 줄 id별 [rubyMarkup]. 이어 붙인 글이 원래 줄과 다르면 버린다.
Map<int, String> furiganaOf(Map<String, dynamic> out, Map<int, String> lines) {
  final result = <int, String>{};
  for (final it in (out['items'] as List).cast<Map>()) {
    final id = (it['id'] as num).toInt();
    final line = lines[id];
    if (line == null) continue;
    final segs = [
      for (final s in (it['segments'] as List).cast<Map>())
        ('${s['text']}', '${s['reading']}'.trim()),
    ];
    if (segs.map((s) => s.$1).join() != line) continue;
    result[id] = rubyMarkup(segs);
  }
  return result;
}

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

  /// 문장 해설 요청 본문 (테스트용으로 분리)
  Map<String, Object?> buildExplainBody(ExplainRequest r, VocabLevel level) =>
      envelope(explainSystem(level), explainSchema, {
        'source_language': r.sourceLang,
        'before': r.before,
        'line': r.sentence,
        'korean_translation': ?r.translation,
        'after': r.after,
      });

  @override
  Future<Explanation> explain(ExplainRequest req, VocabLevel level) => _request(
    jsonEncode(buildExplainBody(req, level)),
    (j) => explanationOf(outputJson(j)),
  );

  @override
  Future<Map<int, String>> furigana(Map<int, String> lines) => _request(
    jsonEncode(
      envelope(furiganaSystem, furiganaSchema, {
        'items': [
          for (final e in lines.entries) {'id': e.key, 'text': e.value},
        ],
      }),
    ),
    (j) => furiganaOf(outputJson(j), lines),
  );

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
      } on IOException catch (e) {
        // 연결 오류도 여러 번 실패하면 안내할 수 있는 오류로 바꾼다
        // (그냥 던지면 번역 루프가 안내 없이 멈췄다)
        if (attempt >= 4) {
          throw TranslateException('$providerName 연결 실패: $e');
        }
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  }

  /// 응답을 기다리는 최대 시간. 넘으면 끊고 다시 요청한다.
  /// (실측: API 응답이 오지 않은 채 연결만 남아 번역이 몇 분씩 멈췄다)
  static const responseTimeout = Duration(seconds: 90);

  Future<Map<String, dynamic>> _post(String body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    var force = false;
    try {
      final req = await client.postUrl(endpoint);
      headers.forEach(req.headers.set);
      req.add(utf8.encode(body));
      final res = await req.close().timeout(responseTimeout);
      final text = await res
          .transform(utf8.decoder)
          .join()
          .timeout(responseTimeout);
      final code = res.statusCode;
      if (code == 200) return jsonDecode(text) as Map<String, dynamic>;
      throw httpError(code, text);
    } on TimeoutException {
      force = true; // 기다리던 연결을 끊는다
      throw TranslateException('$providerName 응답 지연', retryable: true);
    } finally {
      client.close(force: force);
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
