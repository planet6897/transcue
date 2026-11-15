import 'package:flutter_test/flutter_test.dart';
import 'package:transcue/src/pipeline/subtitle_job.dart' show startSyncPlan;
import 'package:transcue/src/pipeline/text_sync.dart';
import 'package:transcue/src/subtitle/bilingual_cue.dart';

BilingualCue cue(int startMs, int endMs, String text) => BilingualCue(
  start: Duration(milliseconds: startMs),
  end: Duration(milliseconds: endMs),
  original: text,
);

/// 실제 강연 앞부분 (Richard St. John, "Success is a continuous journey")
const _talk = [
  'Why do so many people reach success and then fail?',
  'One of the big reasons is, we think success is a one-way street.',
  'So we do everything that leads up to success,',
  "but then we get there. We figure we've made it,",
  'we sit back in our comfort zone,',
  'and we actually stop doing everything that made us successful.',
  "And it doesn't take long to go downhill.",
  'And I can tell you this happens, because it happened to me.',
  'Reaching success, I worked hard, I pushed myself.',
  'But then I stopped, because I figured, "Oh, you know, I made it.',
  'I can just sit back and relax."',
];

/// 한 줄 3초씩, [startMs]부터
List<BilingualCue> lines(int startMs, {List<String> text = _talk}) => [
  for (var i = 0; i < text.length; i++)
    cue(startMs + i * 3000, startMs + (i + 1) * 3000, text[i]),
];

void main() {
  test('자막이 빠르면 늦추는 값을 잰다', () {
    // 말은 19.5초부터, 자막은 0초부터
    final r = estimateTextOffset(lines(19500), lines(0))!;
    expect(r.offset, const Duration(milliseconds: 19500));
    expect(r.significant, isTrue);
    expect(r.describe(), '+19.5초');
  });

  test('자막이 늦으면 앞당기는 값을 잰다', () {
    final r = estimateTextOffset(lines(2000), lines(6000))!;
    expect(r.offset, const Duration(milliseconds: -4000));
    expect(r.describe(), '-4.0초');
  });

  test('줄을 다르게 나눠도 같은 값이 나온다', () {
    // 음성 인식은 자막과 다른 곳에서 줄을 끊는다: 두 줄씩 붙인다
    final spoken = [
      for (var i = 0; i + 1 < _talk.length; i += 2)
        cue(
          10000 + i * 3000,
          10000 + (i + 2) * 3000,
          '${_talk[i]} ${_talk[i + 1]}',
        ),
    ];
    final r = estimateTextOffset(spoken, lines(0))!;
    expect((r.offset.inMilliseconds - 10000).abs(), lessThan(700));
  });

  test('맞는 자막은 옮길 만큼 어긋났다고 보지 않는다', () {
    final r = estimateTextOffset(lines(300), lines(0))!;
    expect(r.significant, isFalse);
  });

  test('같은 말이 거의 없으면 판단하지 않는다', () {
    final other = lines(
      0,
      text: [
        for (var i = 0; i < 11; i++) 'completely different words number $i',
      ],
    );
    expect(estimateTextOffset(lines(5000), other), isNull);
    expect(estimateTextOffset(const [], lines(0)), isNull);
    expect(estimateTextOffset(lines(0), const []), isNull);
  });

  test('구간마다 다르게 어긋난 자막은 판단하지 않는다', () {
    // 앞 절반은 +2초, 뒤 절반은 +12초 (광고가 빠진 다른 편집본)
    final cues = [
      ...lines(0).take(6),
      ...lines(0)
          .skip(6)
          .map(
            (c) => c.withTimes(
              c.start - const Duration(seconds: 10),
              c.end - const Duration(seconds: 10),
            ),
          ),
    ];
    expect(estimateTextOffset(lines(2000), cues), isNull);
  });

  test('찾는 범위 밖의 자막과는 짝짓지 않는다', () {
    // 같은 말이 10분 뒤에 있는 자막
    expect(estimateTextOffset(lines(0), lines(600000)), isNull);
  });

  test('기기별 재는 방법: PC는 1분씩 3번까지, Android는 30초 한 번, TV는 스레드 2개', () {
    final pc = startSyncPlan(android: false, tv: false);
    expect(pc.window, const Duration(seconds: 60));
    expect((pc.tries, pc.threads), (3, null));

    final phone = startSyncPlan(android: true, tv: false);
    expect(phone.window, const Duration(seconds: 30));
    expect((phone.tries, phone.threads), (1, null));

    final tv = startSyncPlan(android: true, tv: true);
    expect(tv.window, const Duration(seconds: 30));
    expect((tv.tries, tv.threads), (1, 2));
  });
}
