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
    this.provisional = false,
    this.ruby,
  });

  final Duration start;
  final Duration end;
  final String original;
  final String? translation;

  /// 학습 단어. null = 아직 안 만듦, [] = 고를 단어 없음
  final List<VocabItem>? words;

  /// AI로 다시 번역하는 중인 줄. 새 번역이 올 때까지 기존 번역을 보여 준다.
  final bool provisional;

  /// 일본어 읽는 법 ([rubyMarkup] 형식). null = 아직 안 만듦
  final String? ruby;

  bool contains(Duration t) => t >= start && t < end;

  BilingualCue withTranslation(String? t, {bool provisional = false}) =>
      BilingualCue(
        start: start,
        end: end,
        original: original,
        translation: t,
        words: words,
        provisional: provisional,
        ruby: ruby,
      );

  BilingualCue withWords(List<VocabItem>? w) => BilingualCue(
    start: start,
    end: end,
    original: original,
    translation: translation,
    words: w,
    provisional: provisional,
    ruby: ruby,
  );

  BilingualCue withTimes(Duration s, Duration e) => BilingualCue(
    start: s,
    end: e,
    original: original,
    translation: translation,
    words: words,
    provisional: provisional,
    ruby: ruby,
  );

  BilingualCue withRuby(String? r) => BilingualCue(
    start: start,
    end: end,
    original: original,
    translation: translation,
    words: words,
    provisional: provisional,
    ruby: r,
  );

  Map<String, Object?> toJson() => {
    's': start.inMilliseconds,
    'e': end.inMilliseconds,
    'o': original,
    if (translation != null) 't': translation,
    if (words != null) 'w': [for (final w in words!) w.toJson()],
    if (provisional) 'p': 1,
    if (ruby != null) 'r': ruby,
  };

  factory BilingualCue.fromJson(Map<String, dynamic> j) => BilingualCue(
    start: Duration(milliseconds: j['s'] as int),
    end: Duration(milliseconds: j['e'] as int),
    original: j['o'] as String,
    translation: j['t'] as String?,
    words: (j['w'] as List?)
        ?.map((e) => VocabItem.fromJson(e as List<dynamic>))
        .toList(),
    provisional: j['p'] == 1,
    ruby: j['r'] as String?,
  );
}

// 읽는 법은 유니코드 행간 주석 문자로 원문 안에 표시한다: ￹글자￺읽기￻
const _rubyAnchor = '￹', _rubySep = '￺', _rubyEnd = '￻';

/// (글, 읽기) 조각들 → 저장 형식. 읽기가 빈 조각은 그대로 둔다.
String rubyMarkup(List<(String, String)> segments) => [
  for (final (t, r) in segments)
    r.isEmpty || r == t ? t : '$_rubyAnchor$t$_rubySep$r$_rubyEnd',
].join();

/// 저장 형식 → (글, 읽기) 조각들. 읽기가 없는 조각은 읽기가 빈 글.
List<(String, String)> rubySegments(String markup) {
  final out = <(String, String)>[];
  final re = RegExp(
    '$_rubyAnchor([^$_rubySep]*)$_rubySep([^$_rubyEnd]*)$_rubyEnd',
  );
  var p = 0;
  for (final m in re.allMatches(markup)) {
    if (m.start > p) out.add((markup.substring(p, m.start), ''));
    out.add((m.group(1)!, m.group(2)!));
    p = m.end;
  }
  if (p < markup.length) out.add((markup.substring(p), ''));
  return out;
}

/// 글자의 절반 이상이 한글인 문장 (번역할 필요가 없다)
bool isMostlyKorean(String text) {
  final letters = RegExp(r'\p{L}', unicode: true).allMatches(text).length;
  if (letters == 0) return false;
  return RegExp('[가-힣]').allMatches(text).length * 2 >= letters;
}

/// 인코딩이 잘못되어 깨진 한국어인지 (한글 없이 라틴 확장 문자·대체 문자만 있는 줄)
bool isBrokenKorean(String text) =>
    RegExp(r'[\u0080-\u00ff\ufffd]').hasMatch(text) &&
    !RegExp(r'[\uac00-\ud7a3]').hasMatch(text);

/// 음성 인식 자막의 끝을 말이 끝날 무렵으로 줄인다.
/// whisper는 문장 끝을 뒤따르는 침묵까지(흔히 다음 문장 시작까지) 늘려 잡아,
/// 말이 멈춘 뒤에도 자막이 오래 남았다. 글자 수로 말하는 데 걸릴 시간을 어림잡고
/// 그보다 넉넉히(1.4배 + 0.8초, 최소 1.5초) 보여 준 뒤 닫는다.
/// (한·중·일 글자 1자 ≈ 0.16초, 그 밖의 글자·숫자 1자 ≈ 0.065초)
BilingualCue trimLingeringEnd(BilingualCue c) {
  var speakMs = 0;
  for (final r in c.original.runes) {
    final ch = String.fromCharCode(r);
    if (_cjk.hasMatch(ch)) {
      speakMs += 160;
    } else if (_letterOrDigit.hasMatch(ch)) {
      speakMs += 65;
    }
  }
  final showMs = (speakMs * 1.4 + 800).round();
  final maxEnd =
      c.start + Duration(milliseconds: showMs < 1500 ? 1500 : showMs);
  if (c.end <= maxEnd) return c;
  return BilingualCue(
    start: c.start,
    end: maxEnd,
    original: c.original,
    translation: c.translation,
    words: c.words,
    provisional: c.provisional,
    ruby: c.ruby,
  );
}

final _cjk = RegExp(r'[぀-ヿ㐀-䶿一-鿿가-힣ｦ-ﾟ]');
final _letterOrDigit = RegExp(r'[\p{L}\p{N}]', unicode: true);

/// 재생 위치에 표시할 큐를 찾는다. (큐는 start 기준 정렬되어 있다고 가정)
///
/// [linger]: 자막이 끝난 뒤 더 보여 줄 시간. 단, 다음 자막이 시작하면 거기서 끝낸다.
/// 예) linger 1초 → min(끝 + 1초, 다음 자막 시작)까지 표시
BilingualCue? cueAt(
  List<BilingualCue> cues,
  Duration t, {
  Duration linger = Duration.zero,
}) {
  final i = lastCueIndexBefore(cues, t);
  if (i < 0) return null;
  final c = cues[i];
  var until = c.end + linger;
  if (i + 1 < cues.length && cues[i + 1].start < until) {
    until = cues[i + 1].start;
  }
  return t < until ? c : null;
}

/// start <= [t] 인 마지막 큐의 번호. 없으면 -1. (큐는 start 기준 정렬)
int lastCueIndexBefore(List<BilingualCue> cues, Duration t) {
  var lo = 0, hi = cues.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (cues[mid].start <= t) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo - 1;
}

/// 문장 단위로 이동할 때 문장 시작보다 이만큼 앞에서 재생한다 (첫소리를 잘 듣도록)
const sentenceLeadIn = Duration(milliseconds: 500);

/// 뒤로 갈 때 한 번에 건너가는 문장 수 (지금 문장에서 이만큼 앞 문장의 처음으로 간다)
const _backStep = 1;

/// [pos]에서 [direction](1: 다음 문장, -1: [_backStep]문장 앞) 으로 갈 재생 위치. 갈 문장이 없으면 null.
Duration? sentenceSeekTarget(
  List<BilingualCue> cues,
  Duration pos,
  int direction,
) {
  // 앞서 문장 시작보다 앞으로 옮겨 온 경우에도 그 문장에 있는 것으로 본다
  final at = pos + sentenceLeadIn + const Duration(milliseconds: 50);
  var current = -1;
  for (var i = 0; i < cues.length && cues[i].start <= at; i++) {
    current = i;
  }
  final int target;
  if (direction > 0) {
    target = current + 1;
    if (target >= cues.length) return null;
  } else {
    if (current < 0) return null;
    target = current < _backStep ? 0 : current - _backStep;
  }
  final t = cues[target].start - sentenceLeadIn;
  return t < Duration.zero ? Duration.zero : t;
}
