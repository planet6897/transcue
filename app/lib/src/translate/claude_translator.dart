import 'dart:convert';

import '../settings/app_settings.dart';
import '../subtitle/bilingual_cue.dart';
import 'translator.dart';

export 'translator.dart';

/// Claude Messages API (REST — Dart용 공식 SDK가 없어 직접 호출)
class ClaudeTranslator extends LlmTranslator {
  ClaudeTranslator({required this.apiKey, required this.model});

  final String apiKey;
  final ClaudeModel model;

  @override
  String get providerName => 'Claude';

  @override
  final Uri endpoint = Uri.parse('https://api.anthropic.com/v1/messages');

  @override
  Map<String, Object?> envelope(
    String system,
    Map<String, Object?> schema,
    Object payload,
  ) => {
    'model': model.id,
    'max_tokens': 16000,
    'system': system,
    'messages': [
      {'role': 'user', 'content': jsonEncode(payload)},
    ],
    'output_config': {
      // 자막 번역은 단순 작업이라 낮은 effort로 비용/지연을 줄인다
      'effort': 'low',
      'format': {'type': 'json_schema', 'schema': schema},
    },
    // 안전 분류기 거절 시 서버가 다른 모델로 재시도 (Opus/Sonnet만 지원)
    if (model != ClaudeModel.haiku) 'fallbacks': 'default',
  };

  @override
  Map<String, String> get headers => {
    'content-type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': '2026-10-21',
    if (model != ClaudeModel.haiku)
      'anthropic-beta': 'server-side-fallback-2026-07-01',
  };

  /// 응답 해석 (테스트용으로 분리)
  static Map<int, String> parseResponse(Map<String, dynamic> j) =>
      translationsOf(_jsonOf(j));

  /// 학습 단어 응답 해석. 자막에 실제로 없는 표현은 버린다 (강조 표시 불가).
  static Map<int, List<VocabItem>> parseVocabResponse(
    Map<String, dynamic> j,
    Map<int, String> lines,
  ) => vocabOf(_jsonOf(j), lines);

  @override
  Map<String, dynamic> outputJson(Map<String, dynamic> response) =>
      _jsonOf(response);

  static Map<String, dynamic> _jsonOf(Map<String, dynamic> j) {
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
    return decodeModelJson(text);
  }
}
