import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/whisper.dart';

/// 처음 [dropsLeft]번은 데이터 절반만 보내고 연결을 끊는 서버
class FlakyServer {
  FlakyServer(this.body, {this.dropsLeft = 0, this.supportsRange = true});

  final Uint8List body;
  int dropsLeft;
  final bool supportsRange;
  late HttpServer _server;
  final ranges = <String?>[];

  String get url => 'http://127.0.0.1:${_server.port}/model.bin';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest r) async {
    final range = r.headers.value(HttpHeaders.rangeHeader);
    ranges.add(range);
    var from = 0;
    if (supportsRange && range != null) {
      from = int.parse(range.substring(6, range.length - 1));
    }
    final rest = body.sublist(from);
    if (dropsLeft > 0) {
      dropsLeft--;
      final status = from > 0 ? '206 Partial Content' : '200 OK';
      final socket = await r.response.detachSocket(writeHeaders: false);
      socket.write(
        'HTTP/1.1 $status\r\nContent-Length: ${rest.length}\r\n\r\n',
      );
      socket.add(rest.sublist(0, rest.length ~/ 2));
      await socket.flush();
      socket.destroy();
      return;
    }
    if (from > 0) r.response.statusCode = HttpStatus.partialContent;
    r.response.contentLength = rest.length;
    r.response.add(rest);
    await r.response.close();
  }
}

void main() {
  late Directory dir;
  late File file;
  final body = Uint8List.fromList(List.generate(4000, (i) => i % 251));
  setUp(() {
    dir = Directory.systemTemp.createTempSync('transcue_model');
    file = File('${dir.path}/model.bin');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<File> get(FlakyServer s, {void Function(double)? onProgress}) =>
      downloadModelFile(
        file,
        s.url,
        expectedBytes: body.length,
        onProgress: onProgress,
        retryDelay: Duration.zero,
      );

  test('끊기면 받은 곳부터 이어서 받아 온전한 파일을 만든다', () async {
    final s = FlakyServer(body, dropsLeft: 2);
    await s.start();
    addTearDown(s.stop);
    await get(s);
    expect(await file.readAsBytes(), body);
    expect(s.ranges.first, isNull);
    expect(s.ranges.skip(1).every((r) => r != null), isTrue);
    expect(File('${file.path}.part').existsSync(), isFalse);
  });

  test('이전 실행에서 받다 만 파일을 이어받는다', () async {
    File('${file.path}.part').writeAsBytesSync(body.sublist(0, 1000));
    final s = FlakyServer(body);
    await s.start();
    addTearDown(s.stop);
    await get(s);
    expect(s.ranges, ['bytes=1000-']);
    expect(await file.readAsBytes(), body);
  });

  test('이미 온전히 있으면 받지 않는다', () async {
    file.writeAsBytesSync(body);
    final s = FlakyServer(body);
    await s.start();
    addTearDown(s.stop);
    await get(s);
    expect(s.ranges, isEmpty);
  });

  test('크기가 다른 파일은 다시 받는다', () async {
    file.writeAsBytesSync([1, 2, 3]);
    final s = FlakyServer(body);
    await s.start();
    addTearDown(s.stop);
    await get(s);
    expect(await file.readAsBytes(), body);
  });

  test('동시에 요청해도 한 번만 받고 양쪽 모두 진행률을 받는다', () async {
    final s = FlakyServer(body);
    await s.start();
    addTearDown(s.stop);
    var a = 0.0, b = 0.0;
    await Future.wait([
      get(s, onProgress: (p) => a = p),
      get(s, onProgress: (p) => b = p),
    ]);
    expect(s.ranges.length, 1);
    expect(await file.readAsBytes(), body);
    expect(a, 1.0);
    expect(b, 1.0);
  });

  test('서버가 이어받기를 지원하지 않으면 처음부터 받는다', () async {
    File('${file.path}.part').writeAsBytesSync(List.filled(1000, 9));
    final s = FlakyServer(body, supportsRange: false);
    await s.start();
    addTearDown(s.stop);
    await get(s);
    expect(await file.readAsBytes(), body);
  });

  test('끝까지 실패하면 예외를 내고 받은 부분은 남긴다', () async {
    final s = FlakyServer(body, dropsLeft: 100);
    await s.start();
    addTearDown(s.stop);
    await expectLater(get(s), throwsA(isA<IOException>()));
    expect(File('${file.path}.part').existsSync(), isTrue);
  });
}
