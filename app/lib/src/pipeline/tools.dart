import 'dart:convert';
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

/// 외부 프로그램 출력용 UTF-8. whisper가 글자 중간에서 끊은 토큰이나 시스템 코드페이지(CP949)
/// 메시지가 섞여도 예외 없이 읽는다.
const lenientUtf8 = Utf8Codec(allowMalformed: true);

const whisperInstallHint =
    'brew install whisper-cpp / Windows: scripts\\setup-windows.ps1';

/// Windows에서 PATH 외에 찾아볼 폴더.
/// 앱을 띄운 뒤(또는 탐색기를 다시 시작하기 전에) 설치하면 PATH가 갱신되지 않으므로 직접 본다.
List<String> windowsToolDirs(Map<String, String> env) {
  final local = env['LOCALAPPDATA'];
  final profile = env['USERPROFILE'];
  final programFiles = env['ProgramFiles'];
  final programData = env['ProgramData'];
  return [
    if (local != null) ...[
      '$local\\Programs\\whisper.cpp', // scripts/setup-windows.ps1
      '$local\\Microsoft\\WinGet\\Links',
    ],
    if (programFiles != null) '$programFiles\\WinGet\\Links',
    if (profile != null) '$profile\\scoop\\shims',
    if (programData != null) '$programData\\chocolatey\\bin',
  ];
}

/// `where` 출력에서 실행할 파일을 고른다. Process.start는 셸 없이 실행하므로
/// .cmd/.bat 대신 .exe만 쓸 수 있다.
String? pickWindowsExecutable(String whereOutput) {
  for (final line in whereOutput.split(RegExp(r'\r?\n'))) {
    final p = line.trim();
    if (p.toLowerCase().endsWith('.exe')) return p;
  }
  return null;
}

/// 외부 실행 파일(ffmpeg, ffprobe, whisper-cli, yt-dlp)을 찾는다. 없으면 null.
/// macOS GUI 앱은 셸 PATH를 물려받지 않으므로 Homebrew 경로를 먼저 본다.
///
/// TODO(M5): 배포판에서는 앱에 번들하거나 앱 지원 폴더에 내려받은 것을 쓴다.
Future<String?> locateTool(String name) async {
  final cached = _cache[name];
  if (cached != null) return cached;
  final candidates = Platform.isWindows
      ? [
          for (final dir in windowsToolDirs(Platform.environment))
            '$dir\\$name.exe',
        ]
      : ['/opt/homebrew/bin/$name', '/usr/local/bin/$name'];
  for (final p in candidates) {
    if (await File(p).exists()) return _cache[name] = p;
  }
  try {
    final r = await Process.run(Platform.isWindows ? 'where' : 'which', [name]);
    if (r.exitCode == 0) {
      final out = r.stdout as String;
      final p = Platform.isWindows
          ? pickWindowsExecutable(out)
          : out.split('\n').first.trim();
      if (p != null && p.isNotEmpty) return _cache[name] = p;
    }
  } on ProcessException {
    // 무시
  }
  return null;
}

Future<String> findTool(String name, {required String install}) async {
  final p = await locateTool(name);
  if (p == null) throw ToolNotFound(name, install);
  return p;
}

/// 임시 폴더를 지운다. Windows에서는 백신·검색 인덱서가 파일을 잠시 잡고 있어 실패할 수 있는데,
/// 뒷정리 실패로 작업 결과까지 잃으면 안 되므로 몇 번 재시도한 뒤 포기한다.
Future<void> deleteTempDir(Directory dir) async {
  for (var attempt = 1; ; attempt++) {
    try {
      await dir.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt >= 5) return;
      await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
    }
  }
}

Future<String> ffmpeg() =>
    findTool('ffmpeg', install: 'brew install ffmpeg / winget install ffmpeg');
Future<String> ffprobe() =>
    findTool('ffprobe', install: 'brew install ffmpeg / winget install ffmpeg');
Future<String> whisperCli() =>
    findTool('whisper-cli', install: whisperInstallHint);
