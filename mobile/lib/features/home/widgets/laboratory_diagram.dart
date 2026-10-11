import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/experiment_mode.dart';
import '../../../models/physics_state.dart';
import '../../../models/vec2.dart';
import 'preview_physics.dart';

/// Presentation of the existing illustrative model, independent of live tracking.
class LaboratoryDiagram extends CustomPainter {
  LaboratoryDiagram(this.mode, this.state, {required this.forces});
  final ExperimentMode mode;
  final PhysicsState state;
  final bool forces;

  @override
  void paint(Canvas canvas, Size size) {
    final collision = mode == ExperimentMode.collision;
    final scale = math.min(
      (size.width - 64) / (collision ? 1.3 : .86),
      (size.height - 100) / .65,
    );
    final origin = Offset(
      (size.width - (collision ? 1.3 : .86) * scale) / 2,
      size.height / 2 + .325 * scale,
    );
    Offset point(Vec2 v) => origin + Offset(v.x, -v.y) * scale;
    final pen = Paint()
      ..color = AppColors.inkMutedDark
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final faint = Paint()
      ..color = AppColors.ruleDark
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final scenery = PreviewPhysics.scenery(mode, state.t);
    for (final solid in scenery.solids) {
      final path = Path()..addPolygon(solid.map(point).toList(), true);
      canvas.drawPath(path, Paint()..color = AppColors.graphiteRaised);
      canvas.drawPath(path, pen);
    }
    for (final (a, b) in [...scenery.ground, ...scenery.ceiling]) {
      final start = point(a), end = point(b);
      canvas.drawLine(start, end, pen);
      for (double x = start.dx; x < end.dx; x += 10) {
        canvas.drawLine(
          Offset(x, start.dy + 3),
          Offset(x - 4, start.dy + 8),
          faint,
        );
      }
    }
    final trajectory = Path();
    final endTime = switch (mode) {
      ExperimentMode.freeFall => .54,
      ExperimentMode.ramp => .66,
      ExperimentMode.pendulum => 1.4,
      ExperimentMode.collision => .58,
    };
    for (var i = 0; i <= 100; i++) {
      final p = point(PreviewPhysics.sample(mode, endTime * i / 100).position!);
      if (i == 0) {
        trajectory.moveTo(p.dx, p.dy);
      } else {
        trajectory.lineTo(p.dx, p.dy);
      }
    }
    canvas.drawPath(trajectory, faint..strokeWidth = 2);
    if (mode == ExperimentMode.freeFall) {
      for (var i = 0; i < 8; i++) {
        canvas.drawCircle(
          point(PreviewPhysics.sample(mode, .065 * i).position!),
          2,
          Paint()..color = AppColors.inkMutedDark,
        );
      }
      _label(canvas, 'Equal time intervals', point(const Vec2(.43, .43)), size);
      _label(canvas, 'g = 9.81 m/s²', point(const Vec2(.5, .28)), size);
      _arrow(
        canvas,
        point(const Vec2(.6, .24)),
        const Offset(0, 52),
        AppColors.acceleration,
      );
    }
    final p = point(state.position!);
    if (scenery.pivot case final Vec2 pivot) {
      final top = point(pivot);
      canvas.drawLine(top, p, pen);
      canvas.drawCircle(top, 4, Paint()..color = AppColors.vellum);
      canvas.drawLine(top, point(pivot + const Vec2(0, -.45)), faint);
      final angle = state.extras['theta_deg']! * math.pi / 180;
      canvas.drawArc(
        Rect.fromCircle(center: top, radius: 44),
        math.pi / 2,
        -angle,
        false,
        pen,
      );
      _label(
        canvas,
        'θ = ${state.extras['theta_deg']!.toStringAsFixed(1)}°',
        top + const Offset(48, 40),
        size,
      );
      _label(canvas, 'L = 0.45 m', top + const Offset(-105, 60), size);
    }
    if (mode == ExperimentMode.ramp) {
      final bottom = point(scenery.solids.first[1]);
      canvas.drawArc(
        Rect.fromCircle(center: bottom, radius: 32),
        math.pi,
        25 * math.pi / 180,
        false,
        pen,
      );
      _label(canvas, 'θ = 25°', bottom - const Offset(76, 36), size);
      _label(canvas, 'μ = 0.15', point(const Vec2(.08, .14)), size);
    }
    for (final box in scenery.boxes) {
      final rect = Rect.fromPoints(
        point(box.center - box.half),
        point(box.center + box.half),
      );
      canvas.drawRect(rect, Paint()..color = AppColors.graphiteRaised);
      canvas.drawRect(rect, pen);
      _label(canvas, '2m', rect.topLeft - const Offset(0, 26), size);
      if (!forces) {
        // Scenery supplies the second body's motion from the same model.
        const step = .001;
        final next = PreviewPhysics.scenery(
          mode,
          state.t + step,
        ).boxes.first.center;
        final velocity = (next - box.center) * (1 / step);
        // Suppress the discontinuous reset at the end of the model loop.
        if (velocity.length > .001 && velocity.length < 2) {
          _arrow(
            canvas,
            point(box.center),
            Offset(velocity.x, -velocity.y) * (.1 * scale),
            AppColors.velocity,
          );
        }
      }
    }
    if (collision || mode == ExperimentMode.ramp) {
      canvas.save();
      canvas.translate(p.dx, p.dy);
      if (mode == ExperimentMode.ramp) canvas.rotate(25 * math.pi / 180);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset.zero,
            width: .05 * scale,
            height: .05 * scale,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = AppColors.vellum,
      );
      canvas.restore();
      if (collision) _label(canvas, 'm', p - const Offset(5, 28), size);
    } else {
      canvas.drawCircle(p, .025 * scale, Paint()..color = AppColors.vellum);
      canvas.drawCircle(
        p,
        .01 * scale,
        Paint()..color = AppColors.graphiteDeep,
      );
    }
    _physicalVectors(canvas, p, scale);
    final rulerStart = Offset(32, size.height - 20);
    final rulerEnd = rulerStart + Offset(.1 * scale, 0);
    canvas.drawLine(rulerStart, rulerEnd, pen);
    for (final x in [rulerStart.dx, rulerEnd.dx]) {
      canvas.drawLine(
        Offset(x, rulerStart.dy - 4),
        Offset(x, rulerStart.dy + 4),
        pen,
      );
    }
    _label(canvas, '0.10 m', rulerEnd + const Offset(8, -8), size);
  }

  void _physicalVectors(Canvas canvas, Offset origin, double scale) {
    void draw(Vec2 value, double displayScale, Color color) {
      final displacement = Offset(value.x, -value.y) * displayScale;
      if (displacement.distance > 1) {
        _arrow(canvas, origin, displacement, color);
      }
    }

    if (forces) {
      final duringImpact =
          mode == ExperimentMode.collision &&
          state.forces.any((force) => force.name == 'normal');
      for (final force in state.forces) {
        if (force.name == 'net') continue;
        // Use projections instead of counting weight a second time.
        if (mode == ExperimentMode.ramp && force.name == 'gravity') continue;
        // The illustrative contact model isolates the impact impulse.
        if (duringImpact && force.name == 'friction') continue;
        draw(force.vector, .08 * scale, AppColors.forceComponent);
      }
      draw(state.acceleration! * .1, .08 * scale, AppColors.forceNet);
    } else {
      draw(state.velocity!, .1 * scale, AppColors.velocity);
      draw(state.acceleration!, .013 * scale, AppColors.acceleration);
    }
  }

  void _arrow(Canvas canvas, Offset start, Offset delta, Color color) {
    final end = start + delta;
    final angle = math.atan2(delta.dy, delta.dx);
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(start, end, paint);
    for (final direction in [-1, 1]) {
      final a = angle + direction * .5;
      canvas.drawLine(end, end - Offset(math.cos(a), math.sin(a)) * 7, paint);
    }
  }

  void _label(Canvas canvas, String text, Offset at, Size size) {
    final label = TextPainter(
      text: TextSpan(
        text: text,
        style: AppType.caption.copyWith(color: AppColors.inkMutedDark),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    label.paint(
      canvas,
      Offset(
        at.dx.clamp(8, size.width - label.width - 8),
        at.dy.clamp(4, size.height - label.height - 4),
      ),
    );
  }

  @override
  bool shouldRepaint(LaboratoryDiagram old) =>
      old.mode != mode || old.state != state || old.forces != forces;
}
