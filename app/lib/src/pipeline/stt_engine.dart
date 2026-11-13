import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../subtitle/bilingual_cue.dart';
import 'media_tools.dart';
import 'parakeet.dart';
import 'subsync.dart';
import 'tools.dart';
import 'whisper.dart';

/// 이 기기에서 음성 인식을 할 수 있는지
/// (데스크톱: ffmpeg + whisper-cli, Android: 앱에 내장한 whisper.cpp)
final bool canTranscribe = hasDesktopTools || Platform.isAndroid;

const _channel = MethodChannel('transcue/whisper');

/// 영상 [input]의 [start]부터 [length]만큼 받아 적는다.
/// 큐 시간은 [start] 기준(0부터). 소리가 없으면(영상 끝) [SttEnd].
Stream<SttEvent> transcribeRange({
  required String input,
  Map<String, String> httpHeaders = const {},
  required Duration start,
  required Duration length,
  required File model,
  File? vadModel,
  String language = 'auto',
  String? fallbackLanguage,
  required Directory tmp,

  /// 있으면 whisper 대신 Parakeet으로 인식한다 (영어로 확인된 구간, 데스크톱만)
  File? parakeetModel,
}) async* {
  if (Platform.isAndroid) {
    yield* _transcribeAndroid(input, start, length, model, vadModel, language);
    return;
  }
  final wav = '${tmp.path}/chunk.wav';
  await extractAudio(
    input,
    wav,
    httpHeaders: httpHeaders,
    start: start,
    length: length,
  );
  if (await File(wav).length() < 32000) {
    yield SttEnd();
    return;
  }
  if (parakeetModel != null) {
    yield* transcribeParakeet(wavPath: wav, model: parakeetModel);
    return;
  }
  yield* transcribe(
    wavPath: wav,
    model: model,
    vadModel: vadModel,
    language: language,
    fallbackLanguage: fallbackLanguage,
  );
}

/// 이 기기에서 말소리 구간을 찾을 수 있는지 (재생 중 싱크 확인)
final bool canDetectSpeech = hasDesktopTools || Platform.isAndroid;

/// 영상 [input]의 [start]부터 [length] 사이 말소리 구간 (밀리초, [start] 기준).
/// 소리가 없으면(영상 끝) 빈 목록.
Future<List<(int, int)>> speechInRange({
  required String input,
  required Duration start,
  required Duration length,
  required File vadModel,
  required Directory tmp,
}) async {
  if (Platform.isAndroid) {
    final r = await _channel.invokeListMethod<int>('speech', {
      'path': input,
      'startMs': start.inMilliseconds,
      'lengthMs': length.inMilliseconds,
      'vad': vadModel.path,
    });
    return pairSegments(r ?? const []);
  }
  final wav = '${tmp.path}/speech.wav';
  await extractAudio(input, wav, start: start, length: length);
  return detectSpeech(wav, vadModel);
}

/// 네이티브 결과 [시작, 끝, 시작, 끝, ...] → 구간 목록
List<(int, int)> pairSegments(List<int> ms) => [
  for (var i = 0; i + 1 < ms.length; i += 2) (ms[i], ms[i + 1]),
];

Stream<SttEvent> _transcribeAndroid(
  String path,
  Duration start,
  Duration length,
  File model,
  File? vad,
  String language,
) async* {
  final r = await _channel.invokeMapMethod<String, Object?>('transcribe', {
    'path': path,
    'startMs': start.inMilliseconds,
    'lengthMs': length.inMilliseconds,
    'model': model.path,
    'vad': vad?.path,
    'lang': language,
    // threads: 생략 → 빠른 코어 수 (WhisperBridge.bigCores)
  });
  debugPrint(
    '[stt] android ${start.inSeconds}s+${length.inSeconds}s: '
    'audio ${r?['audioMs']}ms decode ${r?['decodeMs']}ms whisper ${r?['whisperMs']}ms',
  );
  final text = r?['text'] as String?;
  if (text == null) {
    yield SttEnd();
    return;
  }
  for (final e in parseNativeStt(text)) {
    yield e;
  }
}

/// 네이티브 결과: 첫 줄 언어, 이후 "시작ms\t끝ms\t문장"
List<SttEvent> parseNativeStt(String text) {
  final lines = text.split('\n');
  final out = <SttEvent>[];
  if (lines.isNotEmpty && lines.first.trim().isNotEmpty) {
    out.add(SttLanguage(lines.first.trim()));
  }
  for (final l in lines.skip(1)) {
    final p = l.split('\t');
    if (p.length < 3) continue;
    final s = int.tryParse(p[0]), e = int.tryParse(p[1]);
    final t = p.sublist(2).join(' ').trim();
    if (s == null || e == null || t.isEmpty) continue;
    // whisper가 소리 없는 구간에 내는 표시 ([음악], (웃음) 등)는 뺀다
    if (RegExp(r'^[\[\(♪].*[\]\)♪]$').hasMatch(t)) continue;
    out.add(
      SttCue(
        BilingualCue(
          start: Duration(milliseconds: s),
          end: Duration(milliseconds: e),
          original: t,
        ),
      ),
    );
  }
  return out;
}
