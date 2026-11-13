import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../settings/app_settings.dart';
import '../subtitle/bilingual_cue.dart';
import 'tools.dart';

const _vadFile = 'ggml-silero-v6.2.0.bin';
const _vadUrl =
    'https://huggingface.co/ggml-org/whisper-vad/resolve/main/$_vadFile';

/// 진행 중인 모델 다운로드. 다른 영상을 열어도 같은 파일을 두 번 받지 않는다.
class _ModelDownload {
  final listeners = <void Function(double)>{};
  late final Future<File> done;
}

final _downloads = <String, _ModelDownload>{};

/// 모델 파일을 앱 지원 폴더 `models/`에 내려받는다 (이미 있으면 그대로).
Future<File> ensureModelFile(
  String fileName,
  String url, {
  int? expectedBytes,
  void Function(double)? onProgress,
}) async {
  final dir = Directory('${(await AppSettings.supportDir()).path}/models');
  await dir.create(recursive: true);
  return downloadModelFile(
    File('${dir.path}/$fileName'),
    url,
    expectedBytes: expectedBytes,
    onProgress: onProgress,
  );
}

/// [file]이 온전히 있으면 그대로 돌려주고, 없으면 받는다.
/// 끊기면 받은 곳부터 이어서 받으며, 다음에 다시 시도할 때도 이어서 받는다.
Future<File> downloadModelFile(
  File file,
  String url, {
  int? expectedBytes,
  void Function(double)? onProgress,
  Duration retryDelay = const Duration(seconds: 2),
}) async {
  if (await file.exists() &&
      (expectedBytes == null || await file.length() == expectedBytes)) {
    return file;
  }
  final running = _downloads[file.path];
  if (running != null) {
    if (onProgress != null) running.listeners.add(onProgress);
    return running.done;
  }
  final download = _ModelDownload();
  if (onProgress != null) download.listeners.add(onProgress);
  _downloads[file.path] = download;
  download.done = _downloadWithRetry(file, url, expectedBytes, retryDelay, (p) {
    for (final l in download.listeners.toList()) {
      l(p);
    }
  }).whenComplete(() => _downloads.remove(file.path));
  return download.done;
}

const _maxDownloadAttempts = 6;

Future<File> _downloadWithRetry(
  File file,
  String url,
  int? expectedBytes,
  Duration retryDelay,
  void Function(double) onProgress,
) async {
  final part = File('${file.path}.part');
  for (var attempt = 1; ; attempt++) {
    try {
      await _downloadOnce(part, url, expectedBytes, onProgress);
      return await part.rename(file.path);
    } on IOException catch (e) {
      if (attempt >= _maxDownloadAttempts) rethrow;
      debugPrint('model download retry $attempt: $e');
      await Future<void>.delayed(retryDelay * attempt);
    }
  }
}

Future<void> _downloadOnce(
  File part,
  String url,
  int? expectedBytes,
  void Function(double) onProgress,
) async {
  var have = await part.exists() ? await part.length() : 0;
  if (expectedBytes != null && have == expectedBytes) return;
  if (expectedBytes != null && have > expectedBytes) {
    await part.delete();
    have = 0;
  }
  final uri = Uri.parse(url);
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    if (have > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$have-');
    final res = await request.close();
    if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      await res.drain<void>();
      await part.delete();
      throw HttpException('받던 파일을 이어받을 수 없어 처음부터 받습니다', uri: uri);
    }
    final resumed = res.statusCode == HttpStatus.partialContent;
    if (!resumed && res.statusCode != HttpStatus.ok) {
      throw HttpException('모델 다운로드 실패 HTTP ${res.statusCode}', uri: uri);
    }
    if (!resumed) have = 0; // 서버가 이어받기를 지원하지 않으면 처음부터
    final total =
        expectedBytes ??
        (res.contentLength > 0 ? have + res.contentLength : null);
    final sink = part.openWrite(
      mode: resumed ? FileMode.append : FileMode.write,
    );
    var got = have;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (total != null) onProgress(got / total);
      }
    } finally {
      await sink.close(); // 끊겨도 받은 만큼은 남겨 이어받는다
    }
    if (total != null && got != total) {
      throw HttpException('모델 다운로드가 중간에 끊겼습니다 ($got/$total)', uri: uri);
    }
  } finally {
    client.close();
  }
}

Future<File> ensureWhisperModel(
  WhisperModel m, {
  void Function(double)? onProgress,
}) => ensureModelFile(
  m.file,
  m.url,
  expectedBytes: m.bytes,
  onProgress: onProgress,
);

Future<File> ensureVadModel() => ensureModelFile(_vadFile, _vadUrl);

final _segLine = RegExp(
  r'^\[(\d+):(\d{2}):(\d{2})\.(\d{3}) --> (\d+):(\d{2}):(\d{2})\.(\d{3})\]\s*(.*)$',
);

Duration _d(String h, String m, String s, String ms) => Duration(
  hours: int.parse(h),
  minutes: int.parse(m),
  seconds: int.parse(s),
  milliseconds: int.parse(ms),
);

/// whisper-cli 표준 출력 한 줄 `[00:00:01.000 --> 00:00:04.000]  text` 해석
BilingualCue? parseWhisperLine(String line) {
  final m = _segLine.firstMatch(line.trim());
  if (m == null) return null;
  final text = m[9]!.trim();
  if (text.isEmpty) return null;
  return BilingualCue(
    start: _d(m[1]!, m[2]!, m[3]!, m[4]!),
    end: _d(m[5]!, m[6]!, m[7]!, m[8]!),
    original: text,
  );
}

final _progressRe = RegExp(r'progress\s*=\s*(\d+)%');
final _langRe = RegExp(
  r'auto-detected language:\s*([a-z]{2,3})(?:\s*\(p\s*=\s*([\d.]+))?',
);

/// 언어가 바뀌었다고 믿을 최소 확신도. 말이 적은 구간은 0.5~0.7로 엉뚱한 언어가 나온다.
const minLanguageConfidence = 0.8;

/// whisper-cli 로그 한 줄에서 감지한 언어와 확신도를 읽는다
(String, double?)? parseDetectedLanguage(String line) {
  final m = _langRe.firstMatch(line);
  if (m == null) return null;
  return (m[1]!, m[2] == null ? null : double.tryParse(m[2]!));
}

/// 확신이 낮은데 직전 언어와 다르면 잘못 감지한 것으로 보고 직전 언어로 다시 인식한다
bool shouldRetryLanguage(
  String detected,
  double? confidence,
  String? fallback,
) =>
    fallback != null &&
    detected != fallback &&
    confidence != null &&
    confidence < minLanguageConfidence;

sealed class SttEvent {}

class SttCue extends SttEvent {
  SttCue(this.cue);
  final BilingualCue cue;
}

class SttProgress extends SttEvent {
  SttProgress(this.fraction);
  final double fraction;
}

class SttLanguage extends SttEvent {
  SttLanguage(this.code);
  final String code;
}

/// 이 구간에 소리가 없음 (영상 끝)
class SttEnd extends SttEvent {}

/// whisper-cli로 음성 인식. 인식되는 대로 큐를 내보낸다.
Stream<SttEvent> transcribe({
  required String wavPath,
  required File model,
  File? vadModel,
  String language = 'auto',
  String? fallbackLanguage,
}) async* {
  final args = [
    '-m',
    model.path,
    '-f',
    wavPath,
    '-l',
    language,
    '-t',
    '${Platform.numberOfProcessors.clamp(2, 8)}',
    '-pp',
    // 앞 문장을 문맥으로 넘기지 않는다. 넘기면 긴 영상 중간부터 구두점/대문자가 사라지고
    // 문장이 길게 이어지는 현상이 생긴다 (Knight Rider 96분 실측: 482줄 → 1,252줄)
    '-mc',
    '0',
    if (vadModel != null) ...[
      '--vad',
      '-vm',
      vadModel.path,
      // 말소리 구간을 15초 이하로 잘라 자막 한 줄이 너무 길어지지 않게 한다
      '-vmsd',
      '15',
    ],
  ];
  final p = await Process.start(await whisperCli(), args);
  // 듣는 쪽이 그만두면(재생 위치를 옮김) whisper도 끝낸다. 끝날 때까지 기다려야
  // 다음 조각이 같은 wav 파일을 덮어쓸 수 있다 (Windows는 열린 파일을 못 덮어씀).
  final events = StreamController<SttEvent>(
    onCancel: () async {
      p.kill();
      await p.exitCode;
    },
  );
  final errTail = <String>[];
  var retry = false;

  final out = p.stdout
      .transform(lenientUtf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
        final c = parseWhisperLine(l);
        if (c != null) events.add(SttCue(c));
      });
  final err = p.stderr
      .transform(lenientUtf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
        final pm = _progressRe.firstMatch(l);
        if (pm != null) events.add(SttProgress(int.parse(pm[1]!) / 100));
        final lang = parseDetectedLanguage(l);
        if (lang != null) {
          if (shouldRetryLanguage(lang.$1, lang.$2, fallbackLanguage)) {
            retry = true;
            p.kill();
          } else {
            events.add(SttLanguage(lang.$1));
          }
        }
        errTail.add(l);
        if (errTail.length > 5) errTail.removeAt(0);
      });

  unawaited(
    Future.wait([out.asFuture<void>(), err.asFuture<void>()]).then((_) async {
      final code = await p.exitCode;
      if (code != 0 && !retry) {
        events.addError(
          ProcessException('whisper-cli', args, errTail.join('\n'), code),
        );
      }
      await events.close();
    }),
  );
  yield* events.stream;
  if (retry) {
    debugPrint('[stt] low-confidence language, retry as $fallbackLanguage');
    yield* transcribe(
      wavPath: wavPath,
      model: model,
      vadModel: vadModel,
      language: fallbackLanguage!,
    );
  }
}
