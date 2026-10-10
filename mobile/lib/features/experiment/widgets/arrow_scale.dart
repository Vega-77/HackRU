import 'dart:math' as math;
import 'dart:ui' show Size;

import '../../../models/vec2.dart';

/// Turns physical magnitudes into arrow lengths in screen pixels.
///
/// Each quantity has its own scale, chosen so a tabletop experiment fills a
/// phone screen without arrows leaving it:
///
/// | Quantity | Scale (on a 390 pt wide phone) |
/// |---|---|
/// | velocity | 120 px per m/s |
/// | acceleration | 30 px per m/s² |
/// | force | the object's weight *mg* is 90 px |
///
/// Velocity and acceleration grow linearly up to [_kneePx], then ease
/// towards [maxPx] so a fast throw never shoots off screen. Forces are
/// scaled together, linearly, so a free-body diagram still adds up: if the
/// largest force would be longer than [maxPx], all of them shrink by the
/// same factor.
///
/// [unit] scales everything to the view, so the home screen's small
/// diagrams use the same proportions as the full experiment screen.
class ArrowScale {
  const ArrowScale({required this.unit, required this.weightN});

  /// Scale for a view of [size] showing an object of [massKg].
  factory ArrowScale.forView(Size size, {required double massKg}) => ArrowScale(
    unit: (size.shortestSide / referenceWidth).clamp(0.3, 1.4),
    weightN: math.max(massKg, 1e-6) * 9.81,
  );

  /// The phone width the base scales were tuned on.
  static const double referenceWidth = 390;

  static const double velocityPxPerMps = 120;
  static const double accelerationPxPerMps2 = 30;
  static const double weightPx = 90;
  static const double _maxPx = 200;
  static const double _kneePx = 140;

  /// Arrows shorter than this are not drawn: they would be all head.
  static const double _minPx = 4;

  final double unit;

  /// The object's weight *mg*, the reference length for forces.
  final double weightN;

  double get maxPx => _maxPx * unit;
  double get minPx => _minPx * unit;

  double velocity(Vec2 v) => _eased(v.length * velocityPxPerMps * unit);

  double acceleration(Vec2 a) =>
      _eased(a.length * accelerationPxPerMps2 * unit);

  /// Lengths for a set of forces, by name, sharing one linear scale.
  Map<String, double> forces(Map<String, Vec2> forces) {
    final pxPerN = weightPx * unit / weightN;
    final longest = forces.values.fold<double>(
      0,
      (longest, f) => math.max(longest, f.length * pxPerN),
    );
    final shrink = longest > maxPx ? maxPx / longest : 1.0;
    return {
      for (final e in forces.entries) e.key: e.value.length * pxPerN * shrink,
    };
  }

  /// Whether an arrow of [length] px is worth drawing.
  bool visible(double length) => length >= minPx;

  /// Linear up to the knee, then an exponential ease that approaches
  /// [maxPx] without reaching it. Continuous with slope 1 at the knee.
  double _eased(double raw) {
    final knee = _kneePx * unit;
    if (raw <= knee) return raw;
    final room = maxPx - knee;
    return knee + room * (1 - math.exp(-(raw - knee) / room));
  }
}
