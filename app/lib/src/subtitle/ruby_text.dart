import 'package:flutter/material.dart';

import 'bilingual_cue.dart';

/// 읽는 법이 달린 원문([rubyMarkup] 형식)을 글자 위에 작은 글씨로 읽기를 얹어 그린다.
/// [style]은 본문 글자 모양 (글자 크기가 있어야 읽기 크기를 정할 수 있다).
List<InlineSpan> rubySpans(String markup, TextStyle style) {
  final size = style.fontSize ?? 16;
  final readingStyle = style.copyWith(
    fontSize: size * 0.48,
    fontWeight: FontWeight.w500,
    height: 1.0,
  );
  return [
    for (final (text, reading) in rubySegments(markup))
      if (reading.isEmpty)
        TextSpan(text: text)
      else
        WidgetSpan(
          alignment: PlaceholderAlignment.bottom,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(reading, style: readingStyle, textAlign: TextAlign.center),
              Text(text, style: style),
            ],
          ),
        ),
  ];
}

/// 듣기 연습에서 가려 둔 줄 자리에 보이는 표시
class HiddenLine extends StatelessWidget {
  const HiddenLine({super.key, required this.fontSize, this.hint = true});

  final double fontSize;

  /// 여는 방법 안내를 붙일지
  final bool hint;

  @override
  Widget build(BuildContext context) => Text(
    hint ? '· · ·   (D 또는 눌러서 보기)' : '· · ·',
    textAlign: TextAlign.center,
    style: TextStyle(
      fontSize: fontSize,
      color: Colors.white54,
      fontStyle: FontStyle.italic,
      decoration: TextDecoration.none,
    ),
  );
}
