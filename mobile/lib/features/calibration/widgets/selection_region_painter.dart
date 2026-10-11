import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';

/// Corner marks describe the existing region; adjustment still uses redraw
/// or the stage's existing keyboard controls, not new handle hit testing.
class SelectionRegionPainter extends CustomPainter {
  SelectionRegionPainter({
    required this.box,
    this.confirmed = false,
    this.drawing = false,
  });
  final Rect box;
  final bool confirmed, drawing;
  @override
  void paint(Canvas canvas, Size size) {
    final ink = confirmed ? AppColors.instrumentAccentDark : AppColors.vellum;
    final edge = Paint()
      ..color = AppColors.graphiteDeep
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4;
    canvas.drawRect(box, edge);
    canvas.drawRect(
      box,
      Paint()
        ..color = ink.withValues(alpha: .65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
    final reach = math.min(16.0, math.min(box.width, box.height) / 3);
    final corners = Path();
    for (final (p, direction) in [
      (box.topLeft, const Offset(1, 1)),
      (box.topRight, const Offset(-1, 1)),
      (box.bottomLeft, const Offset(1, -1)),
      (box.bottomRight, const Offset(-1, -1)),
    ]) {
      corners
        ..moveTo(p.dx + reach * direction.dx, p.dy)
        ..lineTo(p.dx, p.dy)
        ..lineTo(p.dx, p.dy + reach * direction.dy);
    }
    canvas.drawPath(corners, edge..strokeWidth = 5);
    canvas.drawPath(
      corners,
      Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    // The status strip carries this label when the camera is too small to
    // separate it from the ruler and object without obscuring either.
    if (drawing || size.width < 360 || size.height < 260) return;
    final text = TextPainter(
      text: TextSpan(
        text: confirmed ? 'Region confirmed' : 'Review object region',
        style: AppType.caption.copyWith(color: ink),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: math.max(1, size.width - 24));
    final width = text.width + 16, height = text.height + 10;
    final left = box.left
        .clamp(4.0, math.max(4.0, size.width - width - 4))
        .toDouble();
    final top = (box.top - height - 8)
        .clamp(4.0, math.max(4.0, size.height - height - 4))
        .toDouble();
    final label = Rect.fromLTWH(left, top, width, height);
    canvas.drawRRect(
      RRect.fromRectAndRadius(label, const Radius.circular(4)),
      Paint()..color = AppColors.graphiteDeep,
    );
    text.paint(canvas, label.topLeft + const Offset(8, 5));
  }

  @override
  bool shouldRepaint(SelectionRegionPainter old) =>
      old.box != box || old.confirmed != confirmed || old.drawing != drawing;
}
