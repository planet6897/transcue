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

/// 학습 단어 수준: 이 수준에서 모를 만한 단어를 고른다
enum VocabLevel {
  beginner('초급', 'A2', 'knows only basic everyday words'),
  intermediate(
    '중급',
    'B1',
    'handles everyday conversation, misses less common words and idioms',
  ),
  advanced(
    '고급',
    'B2',
    'understands most speech, wants rarer words, idioms and slang',
  );

  const VocabLevel(this.label, this.cefr, this.description);
  final String label;
  final String cefr;
  final String description;
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

  /// 기본값은 재생을 앞서갈 수 있는 small.
  /// 실측: i7-1255U에서 small은 재생 속도의 3배, turbo는 0.8배로 재생을 따라가지 못한다.
  static const defaultModel = small;
}

/// 영어 음성에 쓸 인식 엔진
enum EnglishStt {
  whisper('whisper (위에서 고른 모델)'),
  parakeet('Parakeet (영어에 빠르고 정확 · 처음 한 번 670MB)');

  const EnglishStt(this.label);
  final String label;
}

/// NVIDIA Parakeet TDT 0.6B v3 (whisper.cpp의 parakeet-cli로 실행)
class ParakeetModel {
  static const file = 'ggml-parakeet-tdt-0.6b-v3-q8_0.bin';
  static const url =
      'https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/$file';
}

/// 앱 설정. 앱 지원 폴더의 settings.json에 저장한다.
///
/// TODO(M3): API 키는 OS 키체인(macOS Keychain / Windows Credential Manager)으로 이동.
/// 지금은 소유자만 읽을 수 있는 파일(600)에 저장한다.
class AppSettings {
  AppSettings({
    this.claudeApiKey = '',
    this.claudeModel = ClaudeModel.opus,
    WhisperModel? whisperModel,
    this.englishStt = EnglishStt.whisper,
    this.osApiKey = '',
    this.osUsername = '',
    this.osPassword = '',
    this.showVocab = false,
    this.vocabLevel = VocabLevel.intermediate,
    this.autoPlayNext = true,
    this.repeatVideo = false,
  }) : whisperModel = whisperModel ?? WhisperModel.defaultModel;

  /// 반복 재생: 영상이 끝나면 처음부터 다시 (연속 재생보다 우선)
  bool repeatVideo;

  /// 연속 재생: 영상이 끝나면 같은 폴더의 다음 영상을 연다
  bool autoPlayNext;

  /// 학습 단어 표시 (켜져 있을 때만 단어를 만든다 — Claude 비용)
  bool showVocab;
  VocabLevel vocabLevel;

  String claudeApiKey;
  ClaudeModel claudeModel;
  WhisperModel whisperModel;

  /// 영어 음성은 Parakeet으로 인식할지 (다른 언어는 항상 whisper)
  EnglishStt englishStt;

  /// OpenSubtitles.com (인터넷 자막 검색). 아이디/비밀번호는 선택.
  String osApiKey;
  String osUsername;
  String osPassword;

  bool get hasOpenSubtitles => osApiKey.trim().isNotEmpty;

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
          orElse: () => WhisperModel.defaultModel,
        ),
        englishStt: EnglishStt.values.firstWhere(
          (m) => m.name == j['englishStt'],
          orElse: () => EnglishStt.whisper,
        ),
        osApiKey: j['osApiKey'] as String? ?? '',
        osUsername: j['osUsername'] as String? ?? '',
        osPassword: j['osPassword'] as String? ?? '',
        showVocab: j['showVocab'] == true,
        vocabLevel: VocabLevel.values.firstWhere(
          (m) => m.name == j['vocabLevel'],
          orElse: () => VocabLevel.intermediate,
        ),
        autoPlayNext: j['autoPlayNext'] != false,
        repeatVideo: j['repeatVideo'] == true,
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
        'englishStt': englishStt.name,
        'osApiKey': osApiKey.trim(),
        'osUsername': osUsername.trim(),
        'osPassword': osPassword,
        'showVocab': showVocab,
        'vocabLevel': vocabLevel.name,
        'autoPlayNext': autoPlayNext,
        'repeatVideo': repeatVideo,
      }),
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', f.path]);
    }
  }
}
