/// 원문 + 번역문을 한 쌍으로 갖는 자막 큐.
///
/// 최종적으로는 Rust 코어(`core/`)의 `BilingualCue`가 flutter_rust_bridge로
/// 노출될 예정이며, 이 클래스는 M1 단계의 임시 Dart 모델이다.
class BilingualCue {
  const BilingualCue({
    required this.start,
    required this.end,
    required this.original,
    this.translation,
  });

  final Duration start;
  final Duration end;
  final String original;
  final String? translation;

  bool contains(Duration t) => t >= start && t < end;

  BilingualCue withTranslation(String? t) =>
      BilingualCue(start: start, end: end, original: original, translation: t);

  Map<String, Object?> toJson() => {
    's': start.inMilliseconds,
    'e': end.inMilliseconds,
    'o': original,
    if (translation != null) 't': translation,
  };

  factory BilingualCue.fromJson(Map<String, dynamic> j) => BilingualCue(
    start: Duration(milliseconds: j['s'] as int),
    end: Duration(milliseconds: j['e'] as int),
    original: j['o'] as String,
    translation: j['t'] as String?,
  );
}

/// 재생 위치에 표시할 큐를 찾는다. (큐는 start 기준 정렬되어 있다고 가정)
///
/// [linger]: 자막이 끝난 뒤 더 보여 줄 시간. 단, 다음 자막이 시작하면 거기서 끝낸다.
/// 예) linger 1초 → min(끝 + 1초, 다음 자막 시작)까지 표시
BilingualCue? cueAt(
  List<BilingualCue> cues,
  Duration t, {
  Duration linger = Duration.zero,
}) {
  // start <= t 인 마지막 큐
  var lo = 0, hi = cues.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (cues[mid].start <= t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  final i = lo - 1;
  if (i < 0) return null;
  final c = cues[i];
  var until = c.end + linger;
  if (i + 1 < cues.length && cues[i + 1].start < until) {
    until = cues[i + 1].start;
  }
  return t < until ? c : null;
}
