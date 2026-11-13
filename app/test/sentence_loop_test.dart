import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/player/sentence_loop.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

Duration s(num sec) => Duration(milliseconds: (sec * 1000).round());

BilingualCue cue(num a, num b, String t) =>
    BilingualCue(start: s(a), end: s(b), original: t);

void main() {
  // 문장 사이가 붙어 있는 곳(B→C)과 떨어진 곳(A→B, C→D)이 섞여 있다
  final cues = [
    cue(10, 12, 'A'),
    cue(15, 17, 'B'),
    cue(17.3, 19, 'C'),
    cue(30, 33, 'D'),
  ];

  /// [from]부터 [to]까지 0.1초씩 재생하며 되돌아간 위치를 모은다
  List<Duration> play(SentenceLoop loop, num from, num to) {
    final jumps = <Duration>[];
    var t = s(from);
    while (t <= s(to)) {
      final back = loop.onPosition(cues, t);
      if (back != null) {
        jumps.add(back);
        // 플레이어는 되돌아간 뒤에도 지난 위치를 한 번 더 보낸다
        expect(loop.onPosition(cues, t), isNull);
        t = back;
      } else {
        t += s(0.1);
      }
      if (jumps.length > 20) break;
    }
    return jumps;
  }

  test('계속 반복: 문장 끝에서 시작 0.5초 앞으로 돌아간다', () {
    final loop = SentenceLoop(SentenceRepeat.forever)..lockAt(cues, s(10.5));
    expect(loop.cue?.original, 'A');
    final jumps = <Duration>[];
    var t = s(10.5);
    for (var i = 0; i < 200 && jumps.length < 3; i++) {
      final back = loop.onPosition(cues, t);
      if (back != null) {
        jumps.add(back);
        t = back;
      } else {
        t += s(0.1);
      }
    }
    expect(jumps, [s(9.5), s(9.5), s(9.5)]);
    expect(loop.cue?.original, 'A');
    expect(loop.round, 4);
  });

  test('3번씩: 세 번 듣고 다음 문장으로 넘어가 다시 세 번', () {
    final loop = SentenceLoop(SentenceRepeat.three)..lockAt(cues, s(10));
    // A를 3번(되돌아가기 2번) → B를 3번(2번) → 붙어 있는 C도 3번(2번)
    final jumps = play(loop, 10, 25);
    expect(jumps, [s(9.5), s(9.5), s(14.5), s(14.5), s(16.8), s(16.8)]);
    expect(loop.cue?.original, 'D');
  });

  test('문장 사이 빈 구간에서 켜면 다음 문장을 반복한다', () {
    final loop = SentenceLoop(SentenceRepeat.two)..lockAt(cues, s(13));
    expect(loop.cue?.original, 'B');
    expect(play(loop, 13, 18.1), [s(14.5)]);
  });

  test('문장 이동은 시작 0.5초 앞으로 가므로 그 문장으로 고정한다', () {
    final loop = SentenceLoop(SentenceRepeat.forever)..lockAt(cues, s(14.5));
    expect(loop.cue?.original, 'B');
  });

  test('사용자가 다른 곳으로 옮기면 그 자리 문장을 처음부터 센다', () {
    final loop = SentenceLoop(SentenceRepeat.three)..lockAt(cues, s(10));
    expect(loop.onPosition(cues, s(12.3)), s(9.5)); // A 1번째 끝
    expect(loop.onPosition(cues, s(9.5)), isNull);
    expect(loop.round, 2);
    // 탐색 바로 D로
    expect(loop.onPosition(cues, s(31)), isNull);
    expect(loop.cue?.original, 'D');
    expect(loop.round, 1);
    expect(loop.onPosition(cues, s(33.3)), s(29.5));
  });

  test('자막이 없으면 아무것도 하지 않다가, 생기면 그 문장을 반복한다', () {
    final loop = SentenceLoop(SentenceRepeat.forever)..lockAt(const [], s(10));
    expect(loop.cue, isNull);
    expect(loop.onPosition(const [], s(12.5)), isNull);
    expect(loop.onPosition(cues, s(11)), isNull);
    expect(loop.cue?.original, 'A');
    expect(loop.onPosition(cues, s(12.3)), s(9.5));
  });

  test('마지막 문장까지 다 들으면 더 돌아가지 않는다', () {
    final loop = SentenceLoop(SentenceRepeat.two)..lockAt(cues, s(31));
    expect(play(loop, 31, 40), [s(29.5)]);
    expect(loop.cue, isNull);
  });

  test('자막을 다시 만들어 고정한 문장이 사라지면 그 자리 문장으로', () {
    final loop = SentenceLoop(SentenceRepeat.forever)..lockAt(cues, s(10));
    final remade = [cue(9.8, 12.4, 'A2'), ...cues.skip(1)];
    expect(loop.onPosition(remade, s(11)), isNull);
    expect(loop.cue?.original, 'A2');
  });

  test('처음 0.5초 안의 문장은 0초로 돌아간다', () {
    final loop = SentenceLoop(SentenceRepeat.forever)
      ..lockAt([cue(0.2, 2, 'X')], s(1));
    expect(loop.onPosition([cue(0.2, 2, 'X')], s(2.3)), Duration.zero);
  });
}
