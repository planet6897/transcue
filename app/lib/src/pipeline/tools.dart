import 'dart:io';

class ToolNotFound implements Exception {
  const ToolNotFound(this.name, this.install);
  final String name;
  final String install;
  @override
  String toString() => '$name을(를) 찾을 수 없습니다. 설치: $install';
}

final _cache = <String, String>{};

/// ffmpeg·whisper·yt-dlp 같은 외부 프로그램을 쓸 수 있는 환경인지 (데스크톱).
/// 모바일(Android)에서는 재생·인터넷 자막·번역만 되고, 음성 인식·싱크·음성 대조는 건너뛴다.
/// TODO(M6): whisper.cpp를 앱에 내장해 모바일에서도 음성 인식
final bool hasDesktopTools =
    Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// 외부 실행 파일(ffmpeg, ffprobe, whisper-cli, yt-dlp)을 찾는다.
/// macOS GUI 앱은 셸 PATH를 물려받지 않으므로 Homebrew 경로를 먼저 본다.
///
/// TODO(M5): 배포판에서는 앱에 번들하거나 앱 지원 폴더에 내려받은 것을 쓴다.
Future<String> findTool(String name, {required String install}) async {
  final cached = _cache[name];
  if (cached != null) return cached;
  final exe = Platform.isWindows ? '$name.exe' : name;
  for (final dir in ['/opt/homebrew/bin', '/usr/local/bin']) {
    final p = '$dir/$exe';
    if (await File(p).exists()) return _cache[name] = p;
  }
  try {
    final r = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
    if (r.exitCode == 0) {
      final p = (r.stdout as String).split(RegExp(r'\r?\n')).first.trim();
      if (p.isNotEmpty) return _cache[name] = p;
    }
  } on ProcessException {
    // 무시
  }
  throw ToolNotFound(name, install);
}

Future<String> ffmpeg() =>
    findTool('ffmpeg', install: 'brew install ffmpeg / winget install ffmpeg');
Future<String> ffprobe() =>
    findTool('ffprobe', install: 'brew install ffmpeg / winget install ffmpeg');
Future<String> whisperCli() =>
    findTool('whisper-cli', install: 'brew install whisper-cpp');
