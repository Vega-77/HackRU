import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import '../../../core/theme/tokens.dart';
import '../../../models/physics_state.dart';
import '../../../models/session_config.dart';
import '../../../models/vec2.dart';
import 'arrow_scale.dart';
import 'coordinate_mapper.dart';
import 'overlay_frame.dart';

/// Which groups of arrows to draw. Mirrors the toggles on the experiment
/// screen.
class OverlayLayers {
  const OverlayLayers({
    this.velocity = true,
    this.acceleration = true,
    this.forces = true,
  });

  /// Only the marker and trail, as when the AR view draws the arrows.
  static const none = OverlayLayers(
    velocity: false,
    acceleration: false,
    forces: false,
  );

  final bool velocity;
  final bool acceleration;
  final bool forces;

  @override
  bool operator ==(Object other) =>
      other is OverlayLayers &&
      other.velocity == velocity &&
      other.acceleration == acceleration &&
      other.forces == forces;

  @override
  int get hashCode => Object.hash(velocity, acceleration, forces);
}

/// How one named force is drawn: textbook symbol, colour, solid or dashed.
class ForceStyle {
  const ForceStyle(
    this.symbol,
    this.subscript,
    this.color, {
    this.dashed = false,
  });

  final String symbol;
  final String subscript;
  final Color color;

  /// Components of another force (gravity split along a ramp) are dashed,
  /// so they read as "parts of" rather than extra forces.
  final bool dashed;

  static ForceStyle of(String name) => switch (name) {
    'net' => const ForceStyle('F', 'net', AppColors.forceNet),
    'gravity' => const ForceStyle('F', 'g', AppColors.forceComponent),
    'normal' => const ForceStyle('F', 'N', AppColors.forceComponent),
    'friction' => const ForceStyle('F', 'f', AppColors.forceComponent),
    'tension' => const ForceStyle('T', '', AppColors.forceComponent),
    'gravity_parallel' => const ForceStyle(
      'F',
      'g∥',
      AppColors.forceComponent,
      dashed: true,
    ),
    'gravity_perpendicular' => const ForceStyle(
      'F',
      'g⊥',
      AppColors.forceComponent,
      dashed: true,
    ),
    // A force the app doesn't know yet: neutral, labelled by name.
    _ => ForceStyle('F', name, AppColors.thermal),
  };
}

/// One past position of the object, for the stroboscopic trail.
class TrailDot {
  const TrailDot(this.pixel, this.age);

  /// Frame pixels.
  final Vec2 pixel;

  /// 0 for the newest dot, 1 for the oldest still shown.
  final double age;
}

/// Draws the object marker, its trail, and colour-coded arrows for
/// velocity, acceleration and forces, on top of the camera or a preview.
///
/// Inputs are already smoothed (see `OverlayFrame.approach`); this class
/// only draws. It repaints whenever [frame] changes, without a widget
/// rebuild.
class VectorOverlayPainter extends CustomPainter {
  VectorOverlayPainter({
    required this.frame,
    required this.frameSize,
    required this.massKg,
    this.fit = BoxFit.cover,
    this.layers = const OverlayLayers(),
    this.trail,
    this.tether,
    this.showLabels = true,
    this.haloColor = AppColors.graphiteDeep,
    this.markerColor = AppColors.vellum,
    this.textScale = 1,
  }) : super(repaint: Listenable.merge([frame, trail]));

  final ValueListenable<OverlayFrame> frame;
  final ValueListenable<List<TrailDot>>? trail;

  /// Frame pixel the object hangs from, such as a pendulum pivot. A string
  /// is drawn from here to the marker.
  final Vec2? tether;

  /// Size of the frames the [frame] pixels refer to.
  final FrameSize frameSize;

  /// How the background fills the view; see [CoordinateMapper].
  final BoxFit fit;
  final double massKg;
  final OverlayLayers layers;
  final bool showLabels;

  /// Drawn under every arrow and label so they read on any background.
  final Color haloColor;
  final Color markerColor;
  final double textScale;

  @override
  void paint(Canvas canvas, Size size) {
    final f = frame.value;
    final center = f.pixel;
    if (center == null || f.visibility <= 0.01) return;

    final mapper = CoordinateMapper(
      frameSize: frameSize,
      viewSize: size,
      fit: fit,
    );
    final scale = ArrowScale.forView(size, massKg: massKg);
    final origin = mapper.toScreen(center);
    final u = scale.unit;
    final labels = _LabelLayout(
      halo: haloColor,
      textScale: textScale * u.clamp(0.8, 1.1),
    );

    canvas.save();
    canvas.clipRect(Offset.zero & size);

    _paintTrail(canvas, mapper, u);
    final tether = this.tether;
    if (tether != null) {
      _paintTether(
        canvas,
        mapper.toScreen(tether),
        origin,
        f.markerRadius * mapper.scale,
        f.visibility,
        u,
      );
    }
    _paintMarker(
      canvas,
      origin,
      f.markerRadius * mapper.scale,
      f.visibility,
      u,
    );

    if (layers.forces) {
      final lengths = scale.forces(f.forces);
      // Components and the net force go behind the individual forces.
      final order = f.forces.keys.toList()
        ..sort((a, b) => _depth(a).compareTo(_depth(b)));
      for (final name in order) {
        final length = lengths[name]!;
        if (!scale.visible(length)) continue;
        final style = ForceStyle.of(name);
        final tip = _arrow(
          canvas,
          origin,
          f.forces[name]!,
          length,
          style.color.withValues(alpha: f.visibility),
          unit: u,
          axes: f.axes,
          width: style.dashed ? 2.2 : 3,
          dashed: style.dashed,
        );
        // Tiny components would only add clutter around the marker.
        if (showLabels && length > 18 * u) {
          labels.add(style.symbol, style.subscript, style.color, tip, origin);
        }
      }
    }

    if (layers.acceleration) {
      final length = scale.acceleration(f.acceleration);
      if (scale.visible(length)) {
        final tip = _arrow(
          canvas,
          origin,
          f.acceleration,
          length,
          AppColors.acceleration.withValues(alpha: f.visibility),
          unit: u,
          axes: f.axes,
          width: 3.5,
        );
        if (showLabels) {
          labels.add('a', '', AppColors.acceleration, tip, origin);
        }
      }
    }

    if (layers.velocity) {
      final length = scale.velocity(f.velocity);
      if (scale.visible(length)) {
        final tip = _arrow(
          canvas,
          origin,
          f.velocity,
          length,
          AppColors.velocity.withValues(alpha: f.visibility),
          unit: u,
          axes: f.axes,
          width: 3.5,
        );
        if (showLabels) labels.add('v', '', AppColors.velocity, tip, origin);
      }
    }

    labels.paint(canvas, size, f.visibility);
    canvas.restore();
  }

  /// Paint order for forces: lower is drawn first (further back).
  static int _depth(String name) => switch (name) {
    'gravity_parallel' || 'gravity_perpendicular' => 0,
    'net' => 2,
    _ => 1,
  };

  void _paintTrail(Canvas canvas, CoordinateMapper mapper, double u) {
    final dots = trail?.value;
    if (dots == null || dots.isEmpty) return;
    final paint = Paint()..style = PaintingStyle.fill;
    for (final dot in dots) {
      paint.color = markerColor.withValues(alpha: 0.42 * (1 - dot.age));
      canvas.drawCircle(
        mapper.toScreen(dot.pixel),
        3.2 * u.clamp(0.6, 1.0),
        paint,
      );
    }
  }

  /// A thin string from [anchor] to the edge of the marker ring.
  void _paintTether(
    Canvas canvas,
    Offset anchor,
    Offset c,
    double radius,
    double alpha,
    double u,
  ) {
    final span = c - anchor;
    final r = math.max(radius + 4 * u, 9 * u);
    if (span.distance <= r + 4) return;
    final end = c - span / span.distance * r;
    final start = anchor + span / span.distance * 4;
    canvas
      ..drawLine(
        start,
        end,
        Paint()
          ..color = haloColor.withValues(alpha: 0.4 * alpha)
          ..strokeWidth = 3,
      )
      ..drawLine(
        start,
        end,
        Paint()
          ..color = markerColor.withValues(alpha: 0.7 * alpha)
          ..strokeWidth = 1.2,
      );
  }

  /// A drafting-style crosshair ring around the tracked object.
  void _paintMarker(
    Canvas canvas,
    Offset c,
    double radius,
    double alpha,
    double u,
  ) {
    final r = math.max(radius + 4 * u, 9 * u);
    final tick = 5 * u;
    final halo = Paint()
      ..color = haloColor.withValues(alpha: 0.5 * alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5 * u.clamp(0.6, 1.0);
    final ink = Paint()
      ..color = markerColor.withValues(alpha: 0.95 * alpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5 * u.clamp(0.6, 1.0);
    for (final p in [halo, ink]) {
      canvas.drawCircle(c, r, p);
      canvas
        ..drawLine(
          c.translate(0, -r - tick),
          c.translate(0, -r + tick * 0.4),
          p,
        )
        ..drawLine(c.translate(0, r - tick * 0.4), c.translate(0, r + tick), p)
        ..drawLine(
          c.translate(-r - tick, 0),
          c.translate(-r + tick * 0.4, 0),
          p,
        )
        ..drawLine(c.translate(r - tick * 0.4, 0), c.translate(r + tick, 0), p);
    }
    canvas.drawCircle(
      c,
      1.8 * u.clamp(0.6, 1.0),
      Paint()..color = markerColor.withValues(alpha: alpha),
    );
  }

  /// Draws an arrow from [from] along world vector [world], [length] px
  /// long, and returns the tip.
  Offset _arrow(
    Canvas canvas,
    Offset from,
    Vec2 world,
    double length,
    Color color, {
    required double unit,
    required double width,
    ScreenAxes? axes,
    bool dashed = false,
  }) {
    final d = CoordinateMapper.screenDirection(world, axes);
    final tip = from + d * length;
    final w = width * unit.clamp(0.55, 1.1);
    final head = math.min(11 * unit.clamp(0.55, 1.1) + w, length * 0.45);
    final halfHead = head * 0.42;
    final base = tip - d * head;
    final side = Offset(-d.dy, d.dx) * halfHead;
    final shaftEnd = tip - d * (head * 0.8);

    final headPath = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + side.dx, base.dy + side.dy)
      ..lineTo(base.dx - side.dx, base.dy - side.dy)
      ..close();

    final halo = Paint()
      ..color = haloColor.withValues(alpha: 0.55 * color.a)
      ..style = PaintingStyle.stroke
      ..strokeWidth = w + 3
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final shaft = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = dashed ? StrokeCap.butt : StrokeCap.round;

    if (dashed) {
      _dashed(canvas, from, shaftEnd, halo, unit);
      _dashed(canvas, from, shaftEnd, shaft, unit);
    } else {
      canvas
        ..drawLine(from, shaftEnd, halo)
        ..drawLine(from, shaftEnd, shaft);
    }
    canvas
      ..drawPath(headPath, halo)
      ..drawPath(headPath, Paint()..color = color);
    return tip;
  }

  void _dashed(Canvas canvas, Offset a, Offset b, Paint paint, double unit) {
    final total = (b - a).distance;
    if (total == 0) return;
    final dir = (b - a) / total;
    final dash = 7 * unit.clamp(0.6, 1.0);
    final gap = 5 * unit.clamp(0.6, 1.0);
    for (var s = 0.0; s < total; s += dash + gap) {
      canvas.drawLine(a + dir * s, a + dir * math.min(s + dash, total), paint);
    }
  }

  @override
  bool shouldRepaint(VectorOverlayPainter old) =>
      old.frame != frame ||
      old.trail != trail ||
      old.tether != tether ||
      old.frameSize != frameSize ||
      old.fit != fit ||
      old.massKg != massKg ||
      old.layers != layers ||
      old.showLabels != showLabels ||
      old.haloColor != haloColor ||
      old.markerColor != markerColor ||
      old.textScale != textScale;
}

/// Places arrow labels just past each tip, nudging them sideways when two
/// would overlap (common on a ramp, where v, a and two forces all point
/// down the slope).
class _LabelLayout {
  _LabelLayout({required this.halo, required this.textScale});

  final Color halo;
  final double textScale;
  final List<_Label> _labels = [];

  void add(
    String symbol,
    String subscript,
    Color color,
    Offset tip,
    Offset origin,
  ) {
    final dir = tip - origin;
    final d = dir.distance == 0 ? const Offset(0, -1) : dir / dir.distance;
    _labels.add(_Label(symbol, subscript, color, tip, d));
  }

  void paint(Canvas canvas, Size size, double alpha) {
    final placed = <Rect>[];
    for (final label in _labels) {
      final text = _SymbolPainter(label, alpha, textScale, null);
      final outline = _SymbolPainter(label, alpha, textScale, halo);
      final sz = text.size;
      final gap = 6 + sz.longestSide / 2;
      final normal = Offset(-label.dir.dy, label.dir.dx);
      final anchor = label.tip + label.dir * gap;

      Rect rectAt(Offset c) =>
          Rect.fromCenter(center: c, width: sz.width, height: sz.height);
      var rect = rectAt(anchor);
      for (final k in const [1.0, -1.0, 2.0, -2.0]) {
        if (!placed.any((p) => p.overlaps(rect.inflate(1)))) break;
        rect = rectAt(anchor + normal * (sz.height * k));
      }
      // Keep labels on screen.
      final dx = rect.left < 2
          ? 2 - rect.left
          : (rect.right > size.width - 2 ? size.width - 2 - rect.right : 0.0);
      final dy = rect.top < 2
          ? 2 - rect.top
          : (rect.bottom > size.height - 2
                ? size.height - 2 - rect.bottom
                : 0.0);
      rect = rect.shift(Offset(dx, dy));

      placed.add(rect);
      outline.paint(canvas, rect.topLeft);
      text.paint(canvas, rect.topLeft);
    }
  }
}

/// An italic symbol with an optional upright subscript, such as F with a
/// small N. Painted twice per label: once as a dark outline ([halo] set),
/// then filled in the quantity's colour.
class _SymbolPainter {
  _SymbolPainter(_Label label, double alpha, double textScale, Color? halo) {
    TextStyle style(TextStyle s) => halo == null
        ? s.copyWith(color: label.color.withValues(alpha: alpha))
        : s.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3.2
              ..strokeJoin = StrokeJoin.round
              ..color = halo.withValues(alpha: 0.8 * alpha),
          );

    _main = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: label.symbol,
        style: style(AppType.variable.copyWith(fontSize: 17 * textScale)),
      ),
    )..layout();
    if (label.subscript.isNotEmpty) {
      _sub = TextPainter(
        textDirection: TextDirection.ltr,
        text: TextSpan(
          text: label.subscript,
          style: style(AppType.label.copyWith(fontSize: 11 * textScale)),
        ),
      )..layout();
    }
  }

  late final TextPainter _main;
  TextPainter? _sub;

  /// How far the subscript sits below the symbol's baseline area.
  double get _subDrop => _main.height * 0.45;

  Size get size {
    final sub = _sub;
    if (sub == null) return _main.size;
    return Size(
      _main.width + sub.width + 1,
      math.max(_main.height, _subDrop + sub.height),
    );
  }

  void paint(Canvas canvas, Offset topLeft) {
    _main.paint(canvas, topLeft);
    _sub?.paint(canvas, topLeft + Offset(_main.width + 1, _subDrop));
  }
}

class _Label {
  _Label(this.symbol, this.subscript, this.color, this.tip, this.dir);

  final String symbol;
  final String subscript;
  final Color color;
  final Offset tip;
  final Offset dir;
}
