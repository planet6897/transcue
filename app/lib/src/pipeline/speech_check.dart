import 'dart:io';

import '../subtitle/bilingual_cue.dart';
import 'media_tools.dart';
import 'whisper.dart';

/// 자막이 실제 음성과 같은 내용인지 대조한다.
///
/// 영상 몇 군데(30초씩)를 로컬 whisper로 받아 적고, 그 구간 자막에
/// 같은 두 단어 연속(bigram)이 얼마나 나오는지 본다. 자막 시간이 아직 안 맞아도
/// 되도록 앞뒤로 넉넉히(자동 싱크 탐색 범위 2분 + 여유) 비교한다.
///
/// 실측 (30초 표본):
///   2 Broke Girls S01E02 + 맞는 자막       → 87~100%
///   Knight Rider(1982) S01E03 + 2008판 자막 → 0~11%
class SpeechCheck {
  const SpeechCheck({
    required this.matched,
    required this.pairs,
    required this.samples,
  });

  /// 자막에서 찾은 단어 쌍 / 받아 적은 단어 쌍
  final int matched;
  final int pairs;

  /// 대조에 쓴 구간 수 (말소리가 충분했던 구간만)
  final int samples;

  double get ratio => pairs == 0 ? 0 : matched / pairs;

  /// 판단할 만큼 말소리가 있었는지
  bool get conclusive => pairs >= minPairs;

  /// 같은 작품의 자막인지. 판단할 수 없으면 믿는다.
  bool get matches => !conclusive || ratio >= threshold;

  static const threshold = 0.35;
  static const minPairs = 30;

  String describe() =>
      conclusive ? '음성 대조 ${(ratio * 100).round()}% 일치' : '음성 대조 불가 (말소리 부족)';
}

const _sampleLen = Duration(seconds: 30);

/// 자막 시간이 틀어져 있어도 찾도록 비교 범위를 넓힌다
const _window = Duration(seconds: 150);

/// 말소리가 이보다 적은 구간은 판단에서 뺀다 (음악·액션 장면)
const _minWordsPerSample = 12;

final _wordRe = RegExp(r"[\p{L}\p{N}]+", unicode: true);

List<String> speechWords(String s) => [
  for (final m in _wordRe.allMatches(
    s.toLowerCase().replaceAll(RegExp(r"['’]"), ''),
  ))
    m[0]!,
];

/// [spoken]의 단어 쌍 중 [from, to] 근처 자막에 나오는 개수
({int matched, int pairs}) compareWithCues(
  List<String> spoken,
  List<BilingualCue> cues,
  Duration from,
  Duration to, {
  Duration window = _window,
}) {
  final text = [
    for (final c in cues)
      if (c.end > from - window && c.start < to + window) c.original,
  ].join(' ');
  final w = speechWords(text);
  final have = {for (var i = 0; i + 1 < w.length; i++) '${w[i]} ${w[i + 1]}'};
  var matched = 0, pairs = 0;
  for (var i = 0; i + 1 < spoken.length; i++) {
    pairs++;
    if (have.contains('${spoken[i]} ${spoken[i + 1]}')) matched++;
  }
  return (matched: matched, pairs: pairs);
}

/// 영상의 20~80% 사이 여러 곳을 받아 적어 자막과 대조한다.
/// 말소리가 충분히 모이면(단어 쌍 80개, 2구간 이상) 일찍 끝낸다.
Future<SpeechCheck> checkAgainstSpeech({
  required String input,
  required List<BilingualCue> cues,
  required Duration duration,
  required File model,
  File? vadModel,
  String language = 'auto',
}) async {
  final tmp = await Directory.systemTemp.createTemp('dualcue_check_');
  var matched = 0, pairs = 0, samples = 0;
  try {
    for (final f in [0.25, 0.5, 0.75, 0.35, 0.65, 0.15, 0.85]) {
      if (samples >= 2 && pairs >= 80) break;
      final from = duration * f;
      if (from + _sampleLen > duration) continue;
      final wav = '${tmp.path}/s.wav';
      await extractAudio(input, wav, start: from, length: _sampleLen);
      final spoken = <String>[];
      await for (final ev in transcribe(
        wavPath: wav,
        model: model,
        vadModel: vadModel,
        language: language,
      )) {
        if (ev is SttCue) spoken.addAll(speechWords(ev.cue.original));
      }
      if (spoken.length < _minWordsPerSample) continue;
      final r = compareWithCues(spoken, cues, from, from + _sampleLen);
      matched += r.matched;
      pairs += r.pairs;
      samples++;
    }
  } finally {
    await tmp.delete(recursive: true);
  }
  return SpeechCheck(matched: matched, pairs: pairs, samples: samples);
}

/// 한국어 자막이 붙은 원문 줄 비율 (시간이 맞는 한국어 자막이면 대부분 채워진다)
double koreanCoverage(List<BilingualCue> cues) => cues.isEmpty
    ? 0
    : cues.where((c) => c.translation != null).length / cues.length;
