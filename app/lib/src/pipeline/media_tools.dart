import 'dart:convert';
import 'dart:io';

import '../subtitle/bilingual_cue.dart';
import '../subtitle/webvtt.dart';
import 'tools.dart';

/// 동영상 파일 안의 자막 트랙.
class SubtitleStream {
  const SubtitleStream({
    required this.index,
    required this.codec,
    this.language,
    this.title,
  });

  /// 자막 트랙 순번 (ffmpeg `0:s:N`의 N)
  final int index;
  final String codec;
  final String? language;
  final String? title;
}

/// 텍스트 기반 자막 코덱만 사용 (PGS/DVD 같은 이미지 자막은 OCR이 필요해 제외)
const _textCodecs = {
  'subrip',
  'srt',
  'ass',
  'ssa',
  'webvtt',
  'mov_text',
  'text',
};

class MediaInfo {
  const MediaInfo({
    required this.duration,
    required this.subtitles,
    this.audioLanguage,
  });

  final Duration duration;
  final List<SubtitleStream> subtitles;

  /// 첫 음성 트랙의 언어 태그 (예: eng)
  final String? audioLanguage;

  /// ffprobe `-show_streams -show_format -of json` 결과 해석
  factory MediaInfo.fromProbeJson(Map<String, dynamic> j) {
    final secs =
        double.tryParse('${(j['format'] as Map?)?['duration'] ?? ''}') ?? 0;
    final subs = <SubtitleStream>[];
    String? audioLang;
    var n = 0;
    for (final s in (j['streams'] as List? ?? []).cast<Map>()) {
      if (s['codec_type'] == 'audio') {
        audioLang ??= ((s['tags'] as Map?) ?? {})['language'] as String?;
      }
      if (s['codec_type'] != 'subtitle') continue;
      final idx = n++;
      final codec = '${s['codec_name']}';
      if (!_textCodecs.contains(codec)) continue;
      final tags = (s['tags'] as Map?) ?? {};
      subs.add(
        SubtitleStream(
          index: idx,
          codec: codec,
          language: tags['language'] as String?,
          title: tags['title'] as String?,
        ),
      );
    }
    return MediaInfo(
      duration: Duration(milliseconds: (secs * 1000).round()),
      subtitles: subs,
      audioLanguage: audioLang == 'und' ? null : audioLang,
    );
  }

  /// 원어 자막으로 쓸 트랙. 한국어가 아닌 첫 트랙 (영어 우선).
  SubtitleStream? get originalTrack {
    final nonKo = subtitles.where((s) => !_isKo(s.language)).toList();
    return nonKo.where((s) => s.language == 'eng').firstOrNull ??
        nonKo.firstOrNull;
  }

  /// 한국어 자막 트랙 (있으면 번역 대신 사용)
  SubtitleStream? get koreanTrack =>
      subtitles.where((s) => _isKo(s.language)).firstOrNull;

  static bool _isKo(String? l) => l == 'kor' || l == 'ko';
}

Future<String> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args, stdoutEncoding: utf8);
  if (r.exitCode != 0) {
    final err = '${r.stderr}'.trim().split('\n').last;
    throw ProcessException(exe, args, err, r.exitCode);
  }
  return r.stdout as String;
}

Future<MediaInfo> probe(String input) async {
  final out = await _run(await ffprobe(), [
    '-v',
    'error',
    '-show_streams',
    '-show_format',
    '-of',
    'json',
    input,
  ]);
  return MediaInfo.fromProbeJson(jsonDecode(out) as Map<String, dynamic>);
}

/// 내장 텍스트 자막을 꺼내 큐로 만든다.
Future<List<BilingualCue>> extractEmbeddedSubtitle(
  String input,
  SubtitleStream s,
) async {
  final vtt = await _run(await ffmpeg(), [
    '-v',
    'error',
    '-i',
    input,
    '-map',
    '0:s:${s.index}',
    '-f',
    'webvtt',
    'pipe:1',
  ]);
  return parseWebVtt(vtt);
}

/// 음성을 whisper 입력 형식(16kHz mono 16-bit WAV)으로 추출한다.
/// [input]은 파일 경로 또는 URL(YouTube 스트림 등). [onProgress]는 0~1.
Future<void> extractAudio(
  String input,
  String outWav, {
  Map<String, String> httpHeaders = const {},
  Duration? duration,
  void Function(double)? onProgress,
  Duration? start,
  Duration? length,
}) async {
  final args = [
    '-v',
    'error',
    '-y',
    if (httpHeaders.isNotEmpty) ...[
      '-headers',
      httpHeaders.entries.map((e) => '${e.key}: ${e.value}\r\n').join(),
    ],
    // -i 앞의 -ss/-t: 빠르게 해당 구간만 읽는다 (조각 단위 음성 인식)
    if (start != null) ...[
      '-ss',
      (start.inMilliseconds / 1000).toStringAsFixed(3),
    ],
    if (length != null) ...[
      '-t',
      (length.inMilliseconds / 1000).toStringAsFixed(3),
    ],
    '-i',
    input,
    '-vn',
    '-ac',
    '1',
    '-ar',
    '16000',
    '-c:a',
    'pcm_s16le',
    '-progress',
    'pipe:1',
    '-nostats',
    outWav,
  ];
  final p = await Process.start(await ffmpeg(), args);
  final err = StringBuffer();
  p.stderr.transform(utf8.decoder).listen(err.write);
  await for (final line
      in p.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
    // out_time_us=123456789
    if (duration != null && line.startsWith('out_time_us=')) {
      final us = int.tryParse(line.substring(12));
      if (us != null && duration.inMicroseconds > 0) {
        onProgress?.call((us / duration.inMicroseconds).clamp(0, 1));
      }
    }
  }
  final code = await p.exitCode;
  if (code != 0) {
    throw ProcessException('ffmpeg', args, err.toString().trim(), code);
  }
}
