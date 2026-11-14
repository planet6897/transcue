import '../settings/app_settings.dart';
import 'claude_translator.dart';
import 'gemini_translator.dart';
import 'openai_translator.dart';

export 'translator.dart';

/// 설정에서 고른 공급자의 번역기
Translator createTranslator(AppSettings s) => switch (s.provider) {
  TranslateProvider.claude => ClaudeTranslator(
    apiKey: s.claudeApiKey.trim(),
    model: s.claudeModel,
  ),
  TranslateProvider.openai => OpenAiTranslator(
    apiKey: s.openaiApiKey.trim(),
    model: s.openaiModel,
  ),
  TranslateProvider.gemini => GeminiTranslator(
    apiKey: s.geminiApiKey.trim(),
    model: s.geminiModel,
  ),
};
