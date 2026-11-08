// 앱 아이콘 원본(PNG) 생성: flutter test tool/make_icon_test.dart
// 재생 버튼 + 이중 자막(원문 흰색, 번역 청록색) — 앱의 학습 단어 강조색과 같은 색.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _top = Color(0xFF1E3A8A);
const _bottom = Color(0xFF0B1120);
const _cyan = Color(0xFF80DEEA);

/// [rect] 안에 재생 버튼과 자막 두 줄을 그린다
void _content(Canvas c, Rect r) {
  final w = r.width, x = r.left, y = r.top;
  // 재생 삼각형 (살짝 둥근 모서리)
  final tri = Path()
    ..moveTo(x + w * 0.40, y + w * 0.16)
    ..lineTo(x + w * 0.40, y + w * 0.52)
    ..lineTo(x + w * 0.68, y + w * 0.34)
    ..close();
  c.drawPath(
    tri,
    Paint()
      ..color = Colors.white
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = w * 0.05
      ..style = PaintingStyle.fill,
  );
  c.drawPath(
    tri,
    Paint()
      ..color = Colors.white
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = w * 0.05
      ..style = PaintingStyle.stroke,
  );
  final h = w * 0.085;
  RRect bar(double l, double t, double rr) => RRect.fromRectAndRadius(
    Rect.fromLTRB(x + w * l, y + w * t, x + w * rr, y + w * t + h),
    Radius.circular(h / 2),
  );
  c.drawRRect(bar(0.14, 0.66, 0.86), Paint()..color = Colors.white);
  c.drawRRect(bar(0.24, 0.80, 0.76), Paint()..color = _cyan);
}

Paint _bg(Rect r) => Paint()
  ..shader = ui.Gradient.linear(r.topCenter, r.bottomCenter, [_top, _bottom]);

Future<void> _save(String path, void Function(Canvas) draw) async {
  final rec = ui.PictureRecorder();
  draw(Canvas(rec));
  final img = await rec.endRecording().toImage(1024, 1024);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File(path).writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  test('make icons', () async {
    const full = Rect.fromLTWH(0, 0, 1024, 1024);
    // 정사각형 (Android 구형·Windows): 가득 채움
    await _save('assets/icon/icon.png', (c) {
      c.drawRect(full, _bg(full));
      _content(c, full.deflate(150));
    });
    // macOS: Apple 규격 (1024 캔버스에 824 둥근 사각형 + 그림자 여백)
    await _save('assets/icon/icon_macos.png', (c) {
      final body = Rect.fromCenter(center: full.center, width: 824, height: 824);
      final rr = RRect.fromRectAndRadius(body, const Radius.circular(185));
      c.drawRRect(
        rr.shift(const Offset(0, 10)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
      c.drawRRect(rr, _bg(body));
      _content(c, body.deflate(120));
    });
    // Android 적응형 아이콘 전경: 안전 영역(가운데 66%) 안에
    await _save('assets/icon/icon_fg.png', (c) {
      _content(c, full.deflate(250));
    });
  });
}
