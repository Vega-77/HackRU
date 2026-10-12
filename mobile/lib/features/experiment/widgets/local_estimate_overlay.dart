import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/session_config.dart';
import '../../../services/camera/frame_source.dart';
import '../../../services/camera/local_visual_tracker.dart';
import 'coordinate_mapper.dart';

class LocalEstimateOverlay extends StatelessWidget {
  const LocalEstimateOverlay({
    super.key,
    required this.source,
    required this.frameSize,
  });
  final LocalVisualSource source;
  final FrameSize frameSize;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: ValueListenableBuilder<VisualEstimate?>(
      valueListenable: source.visualEstimate,
      builder: (context, estimate, _) => estimate == null
          ? const SizedBox.shrink()
          : Semantics(
              label: 'Local visual estimate, not a physics measurement',
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _EstimatePainter(estimate, frameSize),
                  size: Size.infinite,
                ),
              ),
            ),
    ),
  );
}

class _EstimatePainter extends CustomPainter {
  _EstimatePainter(this.estimate, this.frameSize);
  final VisualEstimate estimate;
  final FrameSize frameSize;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = CoordinateMapper(
      frameSize: frameSize,
      viewSize: size,
    ).rectToScreen(estimate.box);
    final paint = Paint()
      ..color = AppColors.instrumentAccentDark
      ..strokeWidth = 1.5;
    // Dashed outline distinguishes the estimate from the measured marker.
    for (final pair in [
      (rect.topLeft, rect.topRight),
      (rect.topRight, rect.bottomRight),
      (rect.bottomRight, rect.bottomLeft),
      (rect.bottomLeft, rect.topLeft),
    ]) {
      final delta = pair.$2 - pair.$1;
      final length = delta.distance;
      for (var d = 0.0; d < length; d += 9) {
        canvas.drawLine(
          pair.$1 + delta * (d / length),
          pair.$1 + delta * ((d + 5).clamp(0, length) / length),
          paint,
        );
      }
    }
    final label = TextPainter(
      text: TextSpan(
        text: 'Local estimate',
        style: AppType.caption.copyWith(color: AppColors.vellum),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    final point = Offset(
      rect.left.clamp(
        8,
        (size.width - label.width - 8).clamp(8, double.infinity),
      ),
      (rect.top - label.height - 8).clamp(
        8,
        (size.height - label.height - 8).clamp(8, double.infinity),
      ),
    );
    canvas.drawRect(
      Rect.fromLTWH(
        point.dx - 4,
        point.dy - 2,
        label.width + 8,
        label.height + 4,
      ),
      Paint()..color = AppColors.graphiteDeep,
    );
    label.paint(canvas, point);
  }

  @override
  bool shouldRepaint(_EstimatePainter oldDelegate) =>
      oldDelegate.estimate != estimate || oldDelegate.frameSize != frameSize;
}
