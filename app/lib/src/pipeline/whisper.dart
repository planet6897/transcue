import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../settings/app_settings.dart';
import '../subtitle/bilingual_cue.dart';
import 'tools.dart';

const _vadFile = 'ggml-silero-v6.2.0.bin';
const _vadUrl =
    'https://huggingface.co/ggml-org/whisper-vad/resolve/main/$_vadFile';

/// 모델 파일을 앱 지원 폴더 `models/`에 내려받는다 (이미 있으면 그대로).
Future<File> ensureModelFile(
  String fileName,
  String url, {
  int? expectedBytes,
  void Function(double)? onProgress,
}) async {
  final dir = Directory('${(await AppSettings.supportDir()).path}/models');
  await dir.create(recursive: true);
  final file = File('${dir.path}/$fileName');
  if (await file.exists() &&
      (expectedBytes == null || await file.length() == expectedBytes)) {
    return file;
  }
  final part = File('${file.path}.part');
  final client = HttpClient();
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) {
      throw HttpException(
        '모델 다운로드 실패 HTTP ${res.statusCode}',
        uri: Uri.parse(url),
      );
    }
    final total = res.contentLength > 0 ? res.contentLength : expectedBytes;
    final sink = part.openWrite();
    var got = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (total != null) onProgress?.call(got / total);
    }
    await sink.close();
    if (total != null && got != total) {
      throw HttpException('모델 다운로드가 중간에 끊겼습니다 ($got/$total)');
    }
    await part.rename(file.path);
    return file;
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
final _langRe = RegExp(r'auto-detected language:\s*([a-z]{2,3})');

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
  final events = StreamController<SttEvent>();
  final errTail = <String>[];

  final out = p.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
        final c = parseWhisperLine(l);
        if (c != null) events.add(SttCue(c));
      });
  final err = p.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((l) {
        final pm = _progressRe.firstMatch(l);
        if (pm != null) events.add(SttProgress(int.parse(pm[1]!) / 100));
        final lm = _langRe.firstMatch(l);
        if (lm != null) events.add(SttLanguage(lm[1]!));
        errTail.add(l);
        if (errTail.length > 5) errTail.removeAt(0);
      });

  unawaited(
    Future.wait([out.asFuture<void>(), err.asFuture<void>()]).then((_) async {
      final code = await p.exitCode;
      if (code != 0) {
        events.addError(
          ProcessException('whisper-cli', args, errTail.join('\n'), code),
        );
      }
      await events.close();
    }),
  );
  yield* events.stream;
}
