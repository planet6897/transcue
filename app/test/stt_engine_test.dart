import 'package:transcue/src/pipeline/stt_engine.dart';
import 'package:transcue/src/pipeline/whisper.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('네이티브 결과 해석: 언어 + 줄, 소리 표시는 제외', () {
    final ev = parseNativeStt(
      "en\n0\t2500\t Michael, wake up.\n3000\t4200\t[Music]\n5000\t7000\t It's KITT.\n\n",
    );
    expect((ev.first as SttLanguage).code, 'en');
    final cues = ev.whereType<SttCue>().map((e) => e.cue).toList();
    expect(cues.map((c) => c.original), ['Michael, wake up.', "It's KITT."]);
    expect(cues.first.end, const Duration(milliseconds: 2500));
  });
}
