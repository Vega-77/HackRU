import 'camera_pose.dart';
import 'vec2.dart';

/// The result of the calibration screen, all in frame pixels.
///
/// The user drags a line over a ruler of known length ([rulerLengthM]), which
/// gives the pixel-to-metre scale, and taps the object to track. On iOS the
/// user can instead pick the AR [surface] the object moves on, which gives
/// real 3D positions and keeps working while the phone moves.
class Calibration {
  const Calibration({
    this.rulerStart,
    this.rulerEnd,
    this.rulerLengthM = 0.30,
    this.target,
    this.surface,
  });

  final Vec2? rulerStart;
  final Vec2? rulerEnd;
  final double rulerLengthM;
  final Vec2? target;
  final ArSurface? surface;

  /// Frame pixels per metre, or null until both ruler ends are placed.
  double? get pxPerM {
    if (rulerStart == null || rulerEnd == null || rulerLengthM <= 0) {
      return null;
    }
    final pixels = rulerStart!.distanceTo(rulerEnd!);
    return pixels < 1 ? null : pixels / rulerLengthM;
  }

  bool get hasScale => pxPerM != null;

  /// Whether positions can be measured in metres, by either method.
  bool get isMetric => hasScale || surface != null;

  Calibration copyWith({
    Vec2? rulerStart,
    Vec2? rulerEnd,
    double? rulerLengthM,
    Vec2? target,
    ArSurface? surface,
  }) => Calibration(
    rulerStart: rulerStart ?? this.rulerStart,
    rulerEnd: rulerEnd ?? this.rulerEnd,
    rulerLengthM: rulerLengthM ?? this.rulerLengthM,
    target: target ?? this.target,
    surface: surface ?? this.surface,
  );

  Calibration clearTarget() => Calibration(
    rulerStart: rulerStart,
    rulerEnd: rulerEnd,
    rulerLengthM: rulerLengthM,
    surface: surface,
  );

  Calibration clearSurface() => Calibration(
    rulerStart: rulerStart,
    rulerEnd: rulerEnd,
    rulerLengthM: rulerLengthM,
    target: target,
  );
}
