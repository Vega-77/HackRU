import 'dart:math' as math;

import '../../../models/physics_state.dart';
import '../../../models/vec2.dart';

/// What the vector overlay draws in one paint: the object's position and
/// the vectors attached to it.
///
/// The overlay never paints a [PhysicsState] directly. It keeps a displayed
/// [OverlayFrame] and moves it a little closer to the newest state on every
/// screen refresh ([approach]), so arrows glide instead of jumping at the
/// 15 Hz the backend replies at.
class OverlayFrame {
  const OverlayFrame({
    this.pixel,
    this.markerRadius = 0,
    this.velocity = Vec2.zero,
    this.acceleration = Vec2.zero,
    this.forces = const {},
    this.visibility = 0,
  });

  /// Object centre in frame pixels, or null before anything was tracked.
  final Vec2? pixel;

  /// Half the larger side of the bounding box, frame pixels.
  final double markerRadius;

  /// World space, SI units, y up.
  final Vec2 velocity;
  final Vec2 acceleration;

  /// Force name → newtons, world space. Keeps the backend's order.
  final Map<String, Vec2> forces;

  /// 1 while tracked, fading to 0 when the object is lost.
  final double visibility;

  static const OverlayFrame empty = OverlayFrame();

  factory OverlayFrame.fromState(PhysicsState? state) {
    if (state == null || !state.tracked || state.pixel == null) {
      return const OverlayFrame();
    }
    final box = state.bbox;
    return OverlayFrame(
      pixel: state.pixel,
      markerRadius: box == null ? 10 : math.max(box.w, box.h) / 2,
      velocity: state.velocity ?? Vec2.zero,
      acceleration: state.acceleration ?? Vec2.zero,
      forces: {for (final f in state.forces) f.name: f.vector},
      visibility: 1,
    );
  }

  /// Moves this frame towards [target].
  ///
  /// [vectorT] and [positionT] are the fraction of the remaining distance
  /// to close (1 snaps). Position uses a faster rate than the vectors so
  /// the marker stays on the object in the camera feed.
  ///
  /// When [target] is untracked, the marker stays where it was and fades
  /// out, and every vector shrinks to nothing. Forces that disappear also
  /// shrink away instead of vanishing.
  OverlayFrame approach(
    OverlayFrame target, {
    required double vectorT,
    required double positionT,
  }) {
    final targetPixel = target.pixel;
    final Vec2? nextPixel;
    if (targetPixel == null) {
      nextPixel = pixel;
    } else if (pixel == null || visibility == 0) {
      nextPixel = targetPixel; // first sighting: appear in place
    } else {
      nextPixel = Vec2.lerp(pixel!, targetPixel, positionT);
    }

    final nextForces = <String, Vec2>{};
    for (final entry in target.forces.entries) {
      final from = forces[entry.key] ?? Vec2.zero;
      nextForces[entry.key] = Vec2.lerp(from, entry.value, vectorT);
    }
    for (final entry in forces.entries) {
      if (target.forces.containsKey(entry.key)) continue;
      final shrunk = entry.value * (1 - vectorT);
      if (shrunk.length > _epsilon) nextForces[entry.key] = shrunk;
    }

    return OverlayFrame(
      pixel: nextPixel,
      markerRadius: _lerp(
        markerRadius,
        target.pixel == null ? markerRadius : target.markerRadius,
        positionT,
      ),
      velocity: Vec2.lerp(velocity, target.velocity, vectorT),
      acceleration: Vec2.lerp(acceleration, target.acceleration, vectorT),
      forces: nextForces,
      visibility: _lerp(visibility, target.visibility, vectorT),
    );
  }

  /// True when this frame is visually indistinguishable from [other], so
  /// the overlay can stop animating.
  bool settledOn(OverlayFrame other) {
    if ((visibility - other.visibility).abs() > 0.01) return false;
    if (_far(velocity, other.velocity) ||
        _far(acceleration, other.acceleration)) {
      return false;
    }
    final a = pixel, b = other.pixel;
    if (b != null && (a == null || a.distanceTo(b) > 0.25)) return false;
    if (forces.length != other.forces.length) return false;
    for (final entry in other.forces.entries) {
      final mine = forces[entry.key];
      if (mine == null || _far(mine, entry.value)) return false;
    }
    return true;
  }

  static const double _epsilon = 1e-4;

  static bool _far(Vec2 a, Vec2 b) => a.distanceTo(b) > 1e-3;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;
}
