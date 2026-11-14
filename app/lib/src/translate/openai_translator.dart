import 'dart:convert';

import '../settings/app_settings.dart';
import 'translator.dart';

/// OpenAI Responses API (REST)
class OpenAiTranslator extends LlmTranslator {
  OpenAiTranslator({required this.apiKey, required this.model});

  final String apiKey;
  final OpenAiModel model;

  @override
  String get providerName => 'OpenAI';

  @override
  final Uri endpoint = Uri.parse('https://api.openai.com/v1/responses');

  @override
  Map<String, String> get headers => {
    'content-type': 'application/json',
    'authorization': 'Bearer $apiKey',
  };

  @override
  Map<String, Object?> envelope(
    String system,
    Map<String, Object?> schema,
    Object payload,
  ) => {
    'model': model.id,
    'input': [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': jsonEncode(payload)},
    ],
    'text': {
      'format': {
        'type': 'json_schema',
        'name': 'subtitles',
        'schema': schema,
        'strict': true,
      },
    },
    // 자막 번역은 단순 작업이라 낮은 effort로 비용/지연을 줄인다
    // ('none'/'minimal'은 모델에 따라 400 오류라 모든 모델이 받는 'low')
    'reasoning': {'effort': 'low'},
    // 이어지는 대화가 아니므로 서버에 남기지 않는다
    'store': false,
  };

  @override
  Map<String, dynamic> outputJson(Map<String, dynamic> response) =>
      jsonOf(response);

  /// 응답에서 모델이 만든 JSON을 꺼낸다 (테스트용으로 분리)
  static Map<String, dynamic> jsonOf(Map<String, dynamic> j) {
    final parts = [
      for (final item in (j['output'] as List? ?? []).cast<Map>())
        if (item['type'] == 'message')
          ...(item['content'] as List? ?? []).cast<Map>(),
    ];
    if (parts.any((p) => p['type'] == 'refusal')) {
      throw const TranslateException('OpenAI가 이 구간의 번역을 거절했습니다');
    }
    if (j['status'] == 'incomplete') {
      final reason = (j['incomplete_details'] as Map?)?['reason'];
      throw TranslateException('응답이 잘렸습니다 ($reason)');
    }
    if (j['status'] == 'failed') {
      final msg = (j['error'] as Map?)?['message'];
      throw TranslateException('OpenAI 응답 실패: $msg', retryable: true);
    }
    return decodeModelJson(
      parts
          .where((p) => p['type'] == 'output_text')
          .map((p) => p['text'] as String)
          .join(),
    );
  }
}
