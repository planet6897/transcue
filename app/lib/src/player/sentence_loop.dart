import '../subtitle/bilingual_cue.dart';

/// 문장 반복 횟수
enum SentenceRepeat {
  forever('계속 반복', 0),
  two('2번씩', 2),
  three('3번씩', 3),
  five('5번씩', 5);

  const SentenceRepeat(this.label, this.times);
  final String label;

  /// 한 문장을 들을 횟수 (처음 듣는 것 포함). 0 = 끝없이
  final int times;
}

/// 반복할 구간의 크기: 문장 몇 개, 또는 직접 정한 A–B 구간
enum LoopSpan {
  one('한 문장', 1),
  two('두 문장', 2),
  three('세 문장', 3),
  custom('직접 지정 (A–B)', 0);

  const LoopSpan(this.label, this.sentences);
  final String label;

  /// 한 번에 반복하는 문장 수. 0 = 직접 정한 구간
  final int sentences;
}

/// 문장·구간 반복 (쉐도잉용).
///
/// 재생 위치가 들어올 때마다 [onPosition]을 부르면, 고정한 문장의 끝에 닿았을 때
/// 돌아갈 위치를 돌려준다. [SentenceRepeat.times]만큼 들었으면 다음 문장으로 넘어가
/// 같은 방식으로 반복한다. 문장은 위치(시작·끝)로 기억한다. 음성 인식이 줄을 끼워
/// 넣어 목록의 순서가 바뀌어도 같은 문장을 반복하기 위해서다.
class SentenceLoop {
  SentenceLoop(this.repeat, {this.sentences = 1});

  /// 직접 정한 구간 [a, b]를 반복한다
  SentenceLoop.range(this.repeat, Duration a, Duration b)
    : sentences = 0,
      _range = (a, b);

  SentenceRepeat repeat;

  /// 한 번에 반복하는 문장 수 (직접 정한 구간이면 0)
  int sentences;

  /// 직접 정한 구간. 문장 단위 반복이면 null.
  (Duration, Duration)? get range => _range;
  (Duration, Duration)? _range;

  /// 직접 정한 구간을 정한 횟수만큼 다 들었는지 (그러면 반복을 끝낸다)
  bool get finished => _finished;
  bool _finished = false;

  /// 고정한 문장. 아직 없으면(자막이 없는 구간 등) null.
  BilingualCue? get cue => _cue;
  BilingualCue? _cue;

  /// 이 문장을 들은 횟수 (지금 듣는 것 포함, 1부터)
  int get round => _round;
  int _round = 1;

  /// 문장 끝을 이만큼 지나면 되돌아간다 (마지막 소리가 잘리지 않게)
  static const tail = Duration(milliseconds: 250);

  /// 고정한 문장에서 이만큼 벗어나면 사용자가 옮긴 것으로 보고 그 자리 문장으로 바꾼다
  static const _away = Duration(seconds: 2);

  /// 되돌아가라고 한 뒤 아직 재생 위치가 바뀌지 않았는지 (같은 끝에서 두 번 세지 않게)
  bool _seeking = false;

  /// 문장 시작보다 조금 앞 (첫소리를 잘 듣도록, [sentenceLeadIn])
  static Duration _startOf(BilingualCue c) {
    final t = c.start - sentenceLeadIn;
    return t < Duration.zero ? Duration.zero : t;
  }

  /// [pos]의 문장(없으면 그 뒤 첫 문장)으로 고정하고 횟수를 새로 센다.
  /// 문장 이동(←/→)처럼 사용자가 직접 옮겼을 때도 부른다.
  void lockAt(List<BilingualCue> cues, Duration pos) {
    if (_range != null) return; // 직접 정한 구간은 문장 이동과 상관없다
    _cue = _cueFor(cues, pos);
    _round = 1;
    _seeking = false;
  }

  /// 재생 위치가 바뀔 때마다 부른다. 돌아갈 위치를 돌려주거나, 그대로 두면 null.
  Duration? onPosition(List<BilingualCue> cues, Duration pos) {
    if (_range case (final a, final b)) return _onRangePosition(a, b, pos);
    var c = _cue;
    if (c == null || !_present(cues, c)) {
      lockAt(cues, pos);
      c = _cue;
      if (c == null) return null;
    }
    final last = _blockLast(cues, c);
    final end = last.end;
    if (_seeking) {
      // 되돌아간 위치가 들어오기 전에는 지난 위치가 한두 번 더 온다
      if (pos < end) _seeking = false;
      return null;
    }
    // 사용자가 다른 곳으로 옮겼으면 그 자리 문장으로
    if (pos < _startOf(c) - _away || pos > end + _away) {
      lockAt(cues, pos);
      return null;
    }
    if (pos < end + tail) return null;

    // 문장 끝: 더 들을지, 다음 문장으로 갈지
    final times = repeat.times;
    if (times == 0 || _round < times) {
      _round++;
      _seeking = true;
      return _startOf(c);
    }
    _cue = _next(cues, last);
    _round = 1;
    return null; // 이어서 재생하면 다음 문장이 나온다
  }

  /// 직접 정한 구간: 끝(B)에 닿으면 시작(A)으로. 정한 횟수를 다 들으면 끝낸다.
  Duration? _onRangePosition(Duration a, Duration b, Duration pos) {
    if (_finished) return null;
    if (_seeking) {
      if (pos < b) _seeking = false;
      return null;
    }
    // 구간 밖으로 옮겼으면 그대로 둔다 (다시 구간에 들어오면 반복한다)
    if (pos < a - _away || pos > b + _away) return null;
    if (pos < b) return null;
    final times = repeat.times;
    if (times == 0 || _round < times) {
      _round++;
      _seeking = true;
      return a;
    }
    _finished = true;
    return null;
  }

  /// [c]부터 [sentences]개 문장 중 마지막 (뒤에 문장이 모자라면 있는 데까지)
  BilingualCue _blockLast(List<BilingualCue> cues, BilingualCue c) {
    var last = c;
    for (var i = 1; i < sentences; i++) {
      final n = _next(cues, last);
      if (n == null) break;
      last = n;
    }
    return last;
  }

  /// 같은 문장이 아직 목록에 있는지 (자막을 다시 만들면 바뀔 수 있다)
  static bool _present(List<BilingualCue> cues, BilingualCue c) =>
      cues.any((x) => x.start == c.start && x.end == c.end);

  static BilingualCue? _cueFor(List<BilingualCue> cues, Duration pos) {
    // 문장 이동은 시작보다 [sentenceLeadIn] 앞으로 가므로 그만큼 뒤에서 찾는다
    final at = pos + sentenceLeadIn;
    for (final c in cues) {
      if (c.start <= at && at < c.end) return c;
    }
    for (final c in cues) {
      if (c.start > pos) return c;
    }
    return null;
  }

  static BilingualCue? _next(List<BilingualCue> cues, BilingualCue c) {
    for (final x in cues) {
      if (x.start > c.start) return x;
    }
    return null;
  }
}
