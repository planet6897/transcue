/// 원문 + 번역문을 한 쌍으로 갖는 자막 큐.
///
/// 최종적으로는 Rust 코어(`core/`)의 `BilingualCue`가 flutter_rust_bridge로
/// 노출될 예정이며, 이 클래스는 M1 단계의 임시 Dart 모델이다.
/// 학습용 단어 하나 (자막 속 표현 + 이 장면에서의 뜻)
class VocabItem {
  const VocabItem({
    required this.text,
    required this.lemma,
    required this.pos,
    required this.meaning,
  });

  /// 자막에 나온 그대로 (강조 표시용)
  final String text;

  /// 사전형 (예: abducted → abduct)
  final String lemma;

  /// 품사 (명, 동, 형, 부, 구 …)
  final String pos;

  /// 이 문맥에서의 한국어 뜻
  final String meaning;

  List<String> toJson() => [text, lemma, pos, meaning];

  factory VocabItem.fromJson(List<dynamic> j) => VocabItem(
    text: '${j[0]}',
    lemma: '${j[1]}',
    pos: '${j[2]}',
    meaning: '${j[3]}',
  );

  @override
  bool operator ==(Object other) =>
      other is VocabItem &&
      other.text == text &&
      other.lemma == lemma &&
      other.pos == pos &&
      other.meaning == meaning;

  @override
  int get hashCode => Object.hash(text, lemma, pos, meaning);
}

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
    this.words,
  });

  final Duration start;
  final Duration end;
  final String original;
  final String? translation;

  /// 학습 단어. null = 아직 안 만듦, [] = 고를 단어 없음
  final List<VocabItem>? words;

  bool contains(Duration t) => t >= start && t < end;

  BilingualCue withTranslation(String? t) => BilingualCue(
    start: start,
    end: end,
    original: original,
    translation: t,
    words: words,
  );

  BilingualCue withWords(List<VocabItem>? w) => BilingualCue(
    start: start,
    end: end,
    original: original,
    translation: translation,
    words: w,
  );

  BilingualCue withTimes(Duration s, Duration e) => BilingualCue(
    start: s,
    end: e,
    original: original,
    translation: translation,
    words: words,
  );

  Map<String, Object?> toJson() => {
    's': start.inMilliseconds,
    'e': end.inMilliseconds,
    'o': original,
    if (translation != null) 't': translation,
    if (words != null) 'w': [for (final w in words!) w.toJson()],
  };

  factory BilingualCue.fromJson(Map<String, dynamic> j) => BilingualCue(
    start: Duration(milliseconds: j['s'] as int),
    end: Duration(milliseconds: j['e'] as int),
    original: j['o'] as String,
    translation: j['t'] as String?,
    words: (j['w'] as List?)
        ?.map((e) => VocabItem.fromJson(e as List<dynamic>))
        .toList(),
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
