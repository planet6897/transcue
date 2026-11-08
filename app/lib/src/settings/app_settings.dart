import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 번역에 쓸 Claude 모델. 비용은 96분 에피소드(자막 약 1,500줄) 기준 대략치.
enum ClaudeModel {
  haiku('claude-haiku-5-5', 'Claude Haiku 5.5', '가장 저렴 · 1편 약 \$0.05'),
  sonnet('claude-sonnet-5-5', 'Claude Sonnet 5.5', '균형 · 1편 약 \$0.5~0.8'),
  opus('claude-opus-5-5', 'Claude Opus 5.5', '최고 품질 · 1편 약 \$1~2');

  const ClaudeModel(this.id, this.label, this.costHint);
  final String id;
  final String label;
  final String costHint;
}

/// 로컬 음성 인식(whisper.cpp) 모델.
enum WhisperModel {
  turbo(
    'ggml-large-v3-turbo-q5_0.bin',
    'large-v3-turbo (정확 · 574MB)',
    574041195,
  ),
  small('ggml-small-q5_1.bin', 'small (빠름 · 190MB)', 190085487);

  const WhisperModel(this.file, this.label, this.bytes);
  final String file;
  final String label;
  final int bytes;

  String get url =>
      'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$file';
}

/// 앱 설정. 앱 지원 폴더의 settings.json에 저장한다.
///
/// TODO(M3): API 키는 OS 키체인(macOS Keychain / Windows Credential Manager)으로 이동.
/// 지금은 소유자만 읽을 수 있는 파일(600)에 저장한다.
class AppSettings {
  AppSettings({
    this.claudeApiKey = '',
    this.claudeModel = ClaudeModel.opus,
    this.whisperModel = WhisperModel.turbo,
  });

  String claudeApiKey;
  ClaudeModel claudeModel;
  WhisperModel whisperModel;

  bool get hasClaudeKey => claudeApiKey.trim().isNotEmpty;

  static Future<Directory> supportDir() async {
    final d = await getApplicationSupportDirectory();
    await d.create(recursive: true);
    return d;
  }

  static Future<File> _file() async =>
      File('${(await supportDir()).path}/settings.json');

  static Future<AppSettings> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return AppSettings();
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return AppSettings(
        claudeApiKey: j['claudeApiKey'] as String? ?? '',
        claudeModel: ClaudeModel.values.firstWhere(
          (m) => m.name == j['claudeModel'],
          orElse: () => ClaudeModel.opus,
        ),
        whisperModel: WhisperModel.values.firstWhere(
          (m) => m.name == j['whisperModel'],
          orElse: () => WhisperModel.turbo,
        ),
      );
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save() async {
    final f = await _file();
    await f.writeAsString(
      jsonEncode({
        'claudeApiKey': claudeApiKey.trim(),
        'claudeModel': claudeModel.name,
        'whisperModel': whisperModel.name,
      }),
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', f.path]);
    }
  }
}
