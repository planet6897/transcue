import 'dart:io';

import 'package:dualcue/src/player/resume.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('dualcue_resume');
    file = File('${dir.path}/positions.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  const hour = Duration(hours: 1);

  test('기록한 위치를 다시 읽음 (파일 저장 후 새로 열어도)', () async {
    final p = PlaybackPositions(file);
    expect(
      await p.put('file:/a.mkv', const Duration(minutes: 12), hour),
      isTrue,
    );
    await p.save();
    final again = PlaybackPositions(file);
    expect(await again.get('file:/a.mkv'), const Duration(minutes: 12));
    expect(await again.get('file:/b.mkv'), isNull);
  });

  test('앞부분 10초 이내나 끝 1분 이내면 지움 (다 본 영상은 처음부터)', () async {
    final p = PlaybackPositions(file);
    await p.put('k', const Duration(minutes: 30), hour);
    expect(await p.put('k', hour - const Duration(seconds: 20), hour), isTrue);
    expect(await p.get('k'), isNull);
    await p.put('k', const Duration(seconds: 5), hour);
    expect(await p.get('k'), isNull);
  });

  test('1초 미만 변화는 저장하지 않음', () async {
    final p = PlaybackPositions(file);
    await p.put('k', const Duration(seconds: 100), hour);
    expect(
      await p.put('k', const Duration(milliseconds: 100500), hour),
      isFalse,
    );
  });

  test('깨진 파일이어도 동작', () async {
    file.writeAsStringSync('{broken');
    final p = PlaybackPositions(file);
    expect(await p.get('k'), isNull);
    expect(await p.put('k', const Duration(minutes: 1), hour), isTrue);
  });

  test('시간 표시', () {
    expect(formatPosition(const Duration(minutes: 12, seconds: 34)), '12:34');
    expect(
      formatPosition(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });
}
