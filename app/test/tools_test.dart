import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/tools.dart';

void main() {
  test('where 출력에서 .cmd를 건너뛰고 .exe를 고른다', () {
    expect(
      pickWindowsExecutable(
        'C:\\tools\\yt-dlp.cmd\r\nC:\\Python\\Scripts\\yt-dlp.EXE\r\n',
      ),
      'C:\\Python\\Scripts\\yt-dlp.EXE',
    );
    expect(pickWindowsExecutable('C:\\tools\\yt-dlp.cmd\r\n'), isNull);
    expect(pickWindowsExecutable(''), isNull);
  });

  test('환경 변수가 있는 Windows 설치 폴더만 후보에 넣는다', () {
    expect(windowsToolDirs({'LOCALAPPDATA': r'C:\L'}), [
      r'C:\L\Programs\whisper.cpp',
      r'C:\L\Microsoft\WinGet\Links',
    ]);
    expect(windowsToolDirs({}), isEmpty);
  });

  test('lenientUtf8은 끊긴 UTF-8에서 예외를 내지 않는다', () {
    // '한'(ED 95 9C)의 앞 2바이트만 있는 토큰
    expect(lenientUtf8.decode([0x41, 0xED, 0x95]), startsWith('A'));
  });

  test('deleteTempDir는 폴더를 지우고, 이미 없어도 예외를 내지 않는다', () async {
    final dir = await Directory.systemTemp.createTemp('transcue_test_');
    await File('${dir.path}/a.wav').writeAsString('x');
    await deleteTempDir(dir);
    expect(await dir.exists(), isFalse);
    await deleteTempDir(dir);
  });
}
