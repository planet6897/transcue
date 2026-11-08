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
}

/// 재생 위치에 해당하는 큐를 찾는다. (큐는 start 기준 정렬되어 있다고 가정)
BilingualCue? cueAt(List<BilingualCue> cues, Duration t) {
  var lo = 0, hi = cues.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final c = cues[mid];
    if (t < c.start) {
      hi = mid - 1;
    } else if (t >= c.end) {
      lo = mid + 1;
    } else {
      return c;
    }
  }
  return null;
}
