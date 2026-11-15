import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// YouTube 소리 파일을 조각(Range) 요청으로 나눠 받는다.
///
/// 한 번에 통째로 여는 요청은 YouTube가 재생 속도 정도로만 보내 줘서, Android에서
/// 음성 인식 구간마다 소리를 받는 데 10~30초가 걸렸다 (갤럭시 탭 S9, 2026-11 실측).
/// 조각으로 나눠 받으면 빠르게 받아지므로 미리 받아 두고 파일에서 읽는다.
Future<File> downloadInRanges(
  String url,
  Map<String, String> headers,
  File out, {
  int chunkBytes = 1 << 20,
  bool Function()? cancelled,
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  final sink = out.openWrite();
  final watch = Stopwatch()..start();
  var pos = 0;
  int? total;
  try {
    while (total == null || pos < total) {
      if (cancelled?.call() ?? false) throw const HttpException('cancelled');
      var tries = 0;
      while (true) {
        try {
          final req = await client.getUrl(Uri.parse(url));
          headers.forEach(req.headers.set);
          req.headers.set(
            HttpHeaders.rangeHeader,
            'bytes=$pos-${pos + chunkBytes - 1}',
          );
          final res = await req.close().timeout(const Duration(seconds: 30));
          if (res.statusCode == 200) {
            // 조각 요청을 받지 않는 서버: 통째로 받는다
            if (pos != 0) throw HttpException('range ignored at $pos');
            await res.timeout(const Duration(seconds: 30)).pipe(sink);
            debugPrint('[audio] downloaded whole ${watch.elapsedMilliseconds}ms');
            return out;
          }
          if (res.statusCode == 416) {
            await res.drain<void>();
            total = pos;
            break;
          }
          if (res.statusCode != 206) {
            await res.drain<void>();
            throw HttpException('HTTP ${res.statusCode}');
          }
          final range = res.headers.value(HttpHeaders.contentRangeHeader);
          final t = int.tryParse(range?.split('/').last ?? '');
          if (t != null) total = t;
          // 조각을 다 받은 뒤에 파일에 쓴다 (중간에 끊기면 그 조각만 다시 받는다)
          final buf = BytesBuilder(copy: false);
          await for (final b in res.timeout(const Duration(seconds: 30))) {
            buf.add(b);
          }
          final got = buf.length;
          sink.add(buf.takeBytes());
          pos += got;
          if (got == 0) total = pos;
          total ??= got < chunkBytes ? pos : null;
          break;
        } on Exception {
          if (++tries >= 3) rethrow;
        }
      }
    }
    debugPrint(
      '[audio] downloaded ${pos ~/ 1024}KB in ${watch.elapsedMilliseconds}ms',
    );
    return out;
  } finally {
    await sink.close();
    client.close(force: true);
  }
}
