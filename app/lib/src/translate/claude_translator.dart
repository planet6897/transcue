import 'dart:convert';
import 'dart:io';

import '../settings/app_settings.dart';

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

/// 공급자 공통 인터페이스 (OpenAI/Gemini는 M3에서 추가)
abstract interface class Translator {
  Future<Map<int, String>> translate(TranslationBatch batch);
}

const _system = '''
You translate video subtitles into natural, spoken Korean for Korean learners of the source language.
Rules:
- Translate each item independently: exactly one Korean line per input id, never merge or split items.
- Keep the meaning of the speaker's words; use natural conversational Korean that matches the tone (casual vs. polite) and stays consistent with the context.
- Keep proper nouns consistent with the context. Keep sound tags like [Music] or (laughs) as short Korean tags, e.g. [음악], (웃음).
- Output only the JSON object defined by the schema.''';

const _schema = {
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

/// Claude Messages API (REST — Dart용 공식 SDK가 없어 직접 호출)
class ClaudeTranslator implements Translator {
  ClaudeTranslator({required this.apiKey, required this.model});

  final String apiKey;
  final ClaudeModel model;

  static final _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  /// 요청 본문 (테스트용으로 분리)
  Map<String, Object?> buildBody(TranslationBatch b) {
    final payload = {
      'source_language': b.sourceLang,
      'target_language': 'ko',
      'context': [
        for (final (o, t) in b.context) {'original': o, 'korean': ?t},
      ],
      'items': [
        for (final e in b.items.entries) {'id': e.key, 'text': e.value},
      ],
    };
    return {
      'model': model.id,
      'max_tokens': 16000,
      'system': _system,
      'messages': [
        {'role': 'user', 'content': jsonEncode(payload)},
      ],
      'output_config': {
        // 자막 번역은 단순 작업이라 낮은 effort로 비용/지연을 줄인다
        'effort': 'low',
        'format': {'type': 'json_schema', 'schema': _schema},
      },
      // 안전 분류기 거절 시 서버가 다른 모델로 재시도 (Opus/Sonnet만 지원)
      if (model != ClaudeModel.haiku) 'fallbacks': 'default',
    };
  }

  Map<String, String> get headers => {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2026-10-21',
    if (model != ClaudeModel.haiku)
      'anthropic-beta': 'server-side-fallback-2026-07-01',
  };

  /// 응답 해석 (테스트용으로 분리)
  static Map<int, String> parseResponse(Map<String, dynamic> j) {
    final stop = j['stop_reason'];
    if (stop == 'refusal') {
      throw const TranslateException('Claude가 이 구간의 번역을 거절했습니다');
    }
    if (stop == 'max_tokens') {
      throw const TranslateException('응답이 잘렸습니다 (max_tokens)');
    }
    final text = (j['content'] as List? ?? [])
        .cast<Map>()
        .where((c) => c['type'] == 'text')
        .map((c) => c['text'] as String)
        .join();
    final Map<String, dynamic> out;
    try {
      out = jsonDecode(text) as Map<String, dynamic>;
    } on FormatException {
      throw const TranslateException('번역 응답 형식 오류', retryable: true);
    }
    return {
      for (final t in (out['translations'] as List).cast<Map>())
        (t['id'] as num).toInt(): (t['text'] as String).trim(),
    };
  }

  @override
  Future<Map<int, String>> translate(TranslationBatch batch) async {
    final body = jsonEncode(buildBody(batch));
    for (var attempt = 0; ; attempt++) {
      try {
        return await _post(body);
      } on TranslateException catch (e) {
        if (!e.retryable || attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      } on IOException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 << attempt));
      }
    }
  }

  Future<Map<int, String>> _post(String body) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.postUrl(_endpoint);
      headers.forEach(req.headers.set);
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(minutes: 5));
      final text = await res.transform(utf8.decoder).join();
      final code = res.statusCode;
      if (code == 200) {
        return parseResponse(jsonDecode(text) as Map<String, dynamic>);
      }
      String msg = text;
      try {
        msg = (jsonDecode(text) as Map)['error']['message'] as String;
      } catch (_) {}
      if (code == 401) {
        throw const TranslateException('Claude API 키가 올바르지 않습니다 (설정 확인)');
      }
      if (code == 402 || code == 403) {
        throw TranslateException('Claude API 사용 불가 ($code): $msg');
      }
      // 429 요청 제한, 5xx/529 서버 과부하 → 재시도
      final retry = code == 429 || code >= 500;
      throw TranslateException('Claude API 오류 $code: $msg', retryable: retry);
    } finally {
      client.close();
    }
  }
}
