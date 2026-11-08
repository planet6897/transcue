import 'bilingual_cue.dart';

final _timeLine = RegExp(
  r'^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})\s+-->\s+((?:\d+:)?\d{1,2}:\d{2}[.,]\d{3})',
);
final _tags = RegExp(r'<[^>]*>');

Duration _ts(String s) {
  final parts = s.replaceAll(',', '.').split(':');
  final sec = parts.removeLast().split('.');
  var ms = int.parse(sec[0]) * 1000 + int.parse(sec[1]);
  var mult = 60000;
  for (final p in parts.reversed) {
    ms += int.parse(p) * mult;
    mult *= 60;
  }
  return Duration(milliseconds: ms);
}

String _clean(String line) => line
    .replaceAll(_tags, '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .trim();

/// WebVTT를 파싱한다 (원문만 채움).
///
/// YouTube 자동 생성 자막은 한 줄이 다음 큐에 반복되는 "롤링" 형식이라
/// 이미 나온 줄은 제거하고, 10ms짜리 전환용 큐는 버린다.
List<BilingualCue> parseWebVtt(String input) {
  final lines = input
      .replaceAll('\r\n', '\n')
      .replaceFirst('\u{feff}', '')
      .split('\n');

  final cues = <BilingualCue>[];
  String? lastLine;
  Duration? start, end;
  var text = <String>[];

  void flush() {
    if (start != null &&
        end! - start! >= const Duration(milliseconds: 50) &&
        text.isNotEmpty) {
      lastLine = text.last;
      cues.add(
        BilingualCue(start: start!, end: end!, original: text.join('\n')),
      );
    }
    start = end = null;
    text = [];
  }

  // 블록을 빈 줄로 나누지 않고 타임코드 줄 기준으로 읽는다.
  // (YouTube 자동 자막은 큐 안에 공백 한 칸짜리 줄이 있어 블록 분할이 불안정)
  var open = false; // 현재 큐의 텍스트를 받는 중인지
  for (final raw in lines) {
    final m = _timeLine.firstMatch(raw);
    if (m != null) {
      flush();
      start = _ts(m[1]!);
      end = _ts(m[2]!);
      open = true;
    } else if (raw.isEmpty) {
      open = false; // 완전히 빈 줄 = 큐 종료. 이후 번호/NOTE/STYLE은 무시
    } else if (open && start != null) {
      final l = _clean(raw);
      // 10ms 전환 큐(나중에 버려짐)는 중복 판정에 쓰지 않는다
      if (l.isNotEmpty && l != lastLine) text.add(l);
    }
  }
  flush();
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

/// 원문 큐에 번역 큐를 시간 기준으로 합친다.
/// 번역 큐의 중간 시점이 원문 큐 구간 안에 있으면 그 원문에 붙인다.
List<BilingualCue> mergeTranslation(
  List<BilingualCue> original,
  List<BilingualCue> translation,
) {
  return [
    for (final o in original)
      o.withTranslation(() {
        final hits = translation
            .where((t) => o.contains(t.start + (t.end - t.start) ~/ 2))
            .map((t) => t.original)
            .toList();
        return hits.isEmpty ? o.translation : hits.join(' ');
      }()),
  ];
}
