import 'dart:convert';

import '../settings/app_settings.dart';
import 'translator.dart';

/// Google Gemini Interactions API (REST)
class GeminiTranslator extends LlmTranslator {
  GeminiTranslator({required this.apiKey, required this.model});

  final String apiKey;
  final GeminiModel model;

  @override
  String get providerName => 'Gemini';

  @override
  final Uri endpoint = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/interactions',
  );

  @override
  Map<String, String> get headers => {
    'content-type': 'application/json',
    'x-goog-api-key': apiKey,
    'api-revision': '2026-05-20',
  };

  @override
  Map<String, Object?> envelope(
    String system,
    Map<String, Object?> schema,
    Object payload,
  ) => {
    'model': model.id,
    'system_instruction': system,
    'input': jsonEncode(payload),
    'response_format': {
      'type': 'text',
      'mime_type': 'application/json',
      'schema': schema,
    },
    // 자막 번역은 단순 작업이라 생각을 적게 해 비용/지연을 줄인다
    'generation_config': {'thinking_level': 'low'},
    // 이어지는 대화가 아니므로 서버에 남기지 않는다
    'store': false,
  };

  @override
  Map<String, dynamic> outputJson(Map<String, dynamic> response) =>
      jsonOf(response);

  /// 응답에서 모델이 만든 JSON을 꺼낸다 (테스트용으로 분리)
  static Map<String, dynamic> jsonOf(Map<String, dynamic> j) {
    final status = j['status'];
    if (status == 'incomplete' || status == 'requires_continuation') {
      throw const TranslateException('응답이 잘렸습니다 (출력 한도)');
    }
    final text = [
      for (final step in (j['steps'] as List? ?? []).cast<Map>())
        if (step['type'] == 'model_output')
          for (final c in (step['content'] as List? ?? []).cast<Map>())
            if (c['type'] == 'text') c['text'] as String,
    ].join();
    if (status == 'failed' || status == 'cancelled') {
      final errors = (j['errors'] as List? ?? []).cast<Map>();
      final msg = errors.isEmpty ? status : errors.first['message'];
      throw TranslateException('Gemini 응답 실패: $msg', retryable: true);
    }
    if (text.isEmpty) {
      // 안전 필터에 걸리면 글 없이 끝난다
      throw const TranslateException('Gemini가 이 구간의 번역을 돌려주지 않았습니다');
    }
    return decodeModelJson(text);
  }
}
