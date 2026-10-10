import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/experiment_mode.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';
import '../../../services/network/mock_physics_stream.dart';
import 'coordinate_mapper.dart';

/// The background for demo mode: graph paper at a true scale with the
/// simulated apparatus (ramp, floor, pendulum mount, second cart) drawn in
/// engineering-drawing style.
///
/// Uses [BoxFit.contain], so the overlay on top must too.
class DemoScene extends StatelessWidget {
  const DemoScene({
    super.key,
    required this.mode,
    required this.frameSize,
    this.t = 0,
    this.showGrid = true,
  });

  static const BoxFit fit = BoxFit.contain;

  /// Grid squares are this many metres, so the paper doubles as a ruler.
  static const double gridSquareM = 0.05;

  final ExperimentMode mode;
  final FrameSize frameSize;

  /// Simulation time, for moving parts such as the second cart.
  final double t;
  final bool showGrid;

  /// The pendulum pivot in frame pixels, for the overlay's string.
  static Vec2? tetherFor(ExperimentMode mode, FrameSize frameSize) {
    final pivot = MockPhysics.scenery(mode, 0).pivot;
    return pivot == null ? null : MockPhysics.worldToFrame(pivot, frameSize);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _DemoScenePainter(
          mode: mode,
          // Only the collision scene moves; elsewhere pin t so the painter
          // can skip repaints.
          t: mode == ExperimentMode.collision ? t : 0,
          frameSize: frameSize,
          showGrid: showGrid,
        ),
      ),
    );
  }
}

class _DemoScenePainter extends CustomPainter {
  _DemoScenePainter({
    required this.mode,
    required this.t,
    required this.frameSize,
    required this.showGrid,
  });

  final ExperimentMode mode;
  final double t;
  final FrameSize frameSize;
  final bool showGrid;

  static const _paper = AppColors.graphiteDeep;
  static const _gridMinor = Color(0xFF232A31);
  static const _gridMajor = Color(0xFF2E363E);
  static const _ink = AppColors.inkMutedDark;

  @override
  void paint(Canvas canvas, Size size) {
    final scenery = MockPhysics.scenery(mode, t);
    final mapper = CoordinateMapper(
      frameSize: frameSize,
      viewSize: size,
      fit: DemoScene.fit,
    );
    Offset world(Vec2 p) =>
        mapper.toScreen(MockPhysics.worldToFrame(p, frameSize));
    final metre = MockPhysics.pxPerM(frameSize) * mapper.scale;

    canvas.drawRect(Offset.zero & size, Paint()..color = _paper);
    if (showGrid) {
      _grid(canvas, size, world(Vec2.zero), DemoScene.gridSquareM * metre);
    }

    final line = Paint()
      ..color = _ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final hatch = Paint()
      ..color = _ink.withValues(alpha: 0.45)
      ..strokeWidth = 1;

    for (final solid in scenery.solids) {
      final path = Path()..addPolygon([for (final p in solid) world(p)], true);
      canvas
        ..drawPath(path, Paint()..color = AppColors.graphiteRaised)
        ..drawPath(path, line);
    }
    for (final (a, b) in scenery.ground) {
      _hatched(canvas, world(a), world(b), line, hatch, below: true);
    }
    for (final (a, b) in scenery.ceiling) {
      _hatched(canvas, world(a), world(b), line, hatch, below: false);
    }

    final pivot = scenery.pivot;
    if (pivot != null) {
      // The string itself is drawn by the overlay, so it stays attached
      // to the smoothed marker.
      final p = world(pivot);
      canvas
        ..drawCircle(p, 3.5, Paint()..color = AppColors.graphiteDeep)
        ..drawCircle(p, 3.5, line);
    }

    for (final box in scenery.boxes) {
      final rect = Rect.fromPoints(
        world(box.center - box.half),
        world(box.center + box.half),
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));
      canvas
        ..drawRRect(rrect, Paint()..color = AppColors.graphiteRaised)
        ..drawRRect(rrect, line);
      final label = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: '2m',
          style: AppType.variable.copyWith(
            color: _ink,
            fontSize: (rect.height * 0.42).clamp(9, 15),
          ),
        ),
      )..layout();
      label.paint(
        canvas,
        rect.center - Offset(label.width / 2, label.height / 2),
      );
    }
  }

  /// Graph paper: minor lines every square, major lines every second one,
  /// aligned so a grid line passes through the world origin.
  void _grid(Canvas canvas, Size size, Offset origin, double step) {
    if (step < 4) return; // too dense to read; plain paper instead
    final minor = Paint()
      ..color = _gridMinor
      ..strokeWidth = 1;
    final major = Paint()
      ..color = _gridMajor
      ..strokeWidth = 1;

    final firstX = (origin.dx / step).floor();
    for (var i = -firstX - 1; origin.dx + i * step <= size.width; i++) {
      final x = origin.dx + i * step;
      if (x < 0) continue;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        i.isEven ? major : minor,
      );
    }
    final firstY = ((size.height - origin.dy) / step).floor();
    for (var j = -1; j <= firstY + (origin.dy / step).ceil() + 1; j++) {
      final y = origin.dy - j * step;
      if (y < 0 || y > size.height) continue;
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        j.isEven ? major : minor,
      );
    }
  }

  /// A surface line with drafting hatch marks on its solid side.
  void _hatched(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint line,
    Paint hatch, {
    required bool below,
  }) {
    canvas.drawLine(a, b, line);
    const spacing = 8.0;
    const depth = 6.0;
    final length = (b - a).distance;
    if (length == 0) return;
    final dir = (b - a) / length;
    final side = below ? 1.0 : -1.0;
    for (var s = spacing / 2; s < length; s += spacing) {
      final p = a + dir * s;
      canvas.drawLine(p, p + Offset(-depth * 0.7, depth * side), hatch);
    }
  }

  @override
  bool shouldRepaint(_DemoScenePainter old) =>
      old.frameSize != frameSize ||
      old.showGrid != showGrid ||
      old.mode != mode ||
      old.t != t;
}
