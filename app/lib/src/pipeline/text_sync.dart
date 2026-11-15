import '../subtitle/bilingual_cue.dart';
import 'speech_check.dart' show speechWords;

/// 받아 적은 말과 자막에서 같은 단어열이 나오는 시각을 비교해 잰 어긋남.
class TextOffset {
  const TextOffset(this.offset, this.matches);

  /// 자막을 이만큼 옮기면 음성과 맞는다 (+ = 자막이 빨라서 늦춰야 함)
  final Duration offset;

  /// 근거가 된 단어열 수
  final int matches;

  /// 0.7초 미만은 측정 오차 수준이라 건드리지 않는다
  /// (실측: 싱크가 맞는 YouTube 자막 2편, 1분씩 4번 → 0.01~0.30초)
  bool get significant => offset.inMilliseconds.abs() >= 700;

  String describe() {
    final s = offset.inMilliseconds / 1000;
    return '${s >= 0 ? '+' : ''}${s.toStringAsFixed(1)}초';
  }
}

const _gram = 3;

/// 믿을 만하다고 보는 최소 단어열 수 (실측: 말이 이어지는 1분에서 80~160개)
const _minMatches = 12;

/// 가운데 값에서 이 안에 든 것만 같은 어긋남으로 센다.
/// 단어 시각은 줄 안에서 고르게 나눈 추정이라 1초쯤은 흔들린다.
const _spreadMs = 1500;

/// 단어마다 시각을 붙인다. 줄 안에서는 고르게 말한 것으로 본다.
List<(String, double)> _timedWords(Iterable<BilingualCue> cues) {
  final out = <(String, double)>[];
  for (final c in cues) {
    final w = speechWords(c.original);
    final a = c.start.inMilliseconds, len = (c.end - c.start).inMilliseconds;
    for (var i = 0; i < w.length; i++) {
      out.add((w[i], a + len * i / w.length));
    }
  }
  return out;
}

/// 세 단어 연속 → 나온 시각들
Map<String, List<double>> _grams(List<(String, double)> words) {
  final out = <String, List<double>>{};
  for (var i = 0; i + _gram <= words.length; i++) {
    final key = [for (var k = 0; k < _gram; k++) words[i + k].$1].join(' ');
    (out[key] ??= []).add(words[i].$2);
  }
  return out;
}

/// 자막 전체가 음성보다 얼마나 밀렸는지. 판단할 근거가 모자라면 null.
///
/// VAD 겹침([findBestSync])은 말이 쉬지 않고 이어지는 강연에서 어긋남을 가리기 어렵다.
/// 여기서는 [spoken](음성 인식 결과, 영상 시간 기준)과 [cues]에 한 번씩만 나오는
/// 세 단어 연속을 짝지어 시각 차이의 가운데 값을 쓴다.
///
/// 실사례: TED 강연 YouTube 자막이 인트로 없는 판본 기준이라 18.6초 빠름.
TextOffset? estimateTextOffset(
  List<BilingualCue> spoken,
  List<BilingualCue> cues, {
  Duration maxOffset = const Duration(seconds: 90),
}) {
  if (spoken.isEmpty || cues.isEmpty) return null;
  final from = spoken.first.start - maxOffset;
  final to = spoken.last.end + maxOffset;
  final heard = _grams(_timedWords(spoken));
  final written = _grams(
    _timedWords(cues.where((c) => c.end > from && c.start < to)),
  );
  final diffs = <double>[
    for (final e in heard.entries)
      if (e.value.length == 1)
        if (written[e.key] case [final t]) e.value.single - t,
  ]..sort();
  if (diffs.length < _minMatches) return null;
  final median = diffs[diffs.length ~/ 2];
  final close = [
    for (final d in diffs)
      if ((d - median).abs() <= _spreadMs) d,
  ];
  // 값이 흩어져 있으면 구간마다 다르게 어긋난 자막(다른 편집본)이라 한 번에 못 맞춘다
  if (close.length < _minMatches || close.length < diffs.length * 0.6) {
    return null;
  }
  return TextOffset(
    Duration(milliseconds: close[close.length ~/ 2].round()),
    close.length,
  );
}
