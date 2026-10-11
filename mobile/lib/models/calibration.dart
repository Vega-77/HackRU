import 'camera_pose.dart';
import 'physics_state.dart';
import 'session_config.dart';
import 'vec2.dart';

/// The other object in a collision, marked the same way as the first: a tap
/// that the backend proposes a box for, or a drawn box, then confirmed.
class ObjectSelection {
  const ObjectSelection({
    required this.point,
    required this.frame,
    this.box,
    this.pending = false,
    this.confirmed = false,
  });

  final Vec2 point;

  /// The picture the object was marked in. [point] and [box] are in it.
  final EncodedFrame frame;

  /// Null while the backend is still finding the object's boundary.
  final PixelRect? box;
  final bool pending;
  final bool confirmed;

  ObjectSelection copyWith({bool? pending, bool? confirmed}) => ObjectSelection(
    point: point,
    frame: frame,
    box: box,
    pending: pending ?? this.pending,
    confirmed: confirmed ?? this.confirmed,
  );
}

/// The result of the calibration screen, all in frame pixels.
///
/// The user drags a line over a ruler of known length ([rulerLengthM]), which
/// gives the pixel-to-metre scale, and taps the object to track. On iOS the
/// user can instead pick the AR [surface] the object moves on, which gives
/// real 3D positions and keeps working while the phone moves. A collision
/// also marks the [second] object.
class Calibration {
  const Calibration({
    this.rulerStart,
    this.rulerEnd,
    this.rulerLengthM = 0.30,
    this.target,
    this.targetBbox,
    this.selectionFrame,
    this.selectionPending = false,
    this.selectionConfirmed = false,
    this.selectionError,
    this.surface,
    this.second,
    this.secondError,
  });

  final Vec2? rulerStart;
  final Vec2? rulerEnd;
  final double rulerLengthM;
  final Vec2? target;
  final PixelRect? targetBbox;
  final EncodedFrame? selectionFrame;
  final bool selectionPending;
  final bool selectionConfirmed;
  final String? selectionError;
  final ArSurface? surface;
  final ObjectSelection? second;
  final String? secondError;

  /// Whether both collision objects are marked and confirmed.
  bool get pairConfirmed => selectionConfirmed && (second?.confirmed ?? false);

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
    PixelRect? targetBbox,
    EncodedFrame? selectionFrame,
    bool? selectionPending,
    bool? selectionConfirmed,
    String? selectionError,
    ArSurface? surface,
  }) => Calibration(
    rulerStart: rulerStart ?? this.rulerStart,
    rulerEnd: rulerEnd ?? this.rulerEnd,
    rulerLengthM: rulerLengthM ?? this.rulerLengthM,
    target: target ?? this.target,
    targetBbox: targetBbox ?? this.targetBbox,
    selectionFrame: selectionFrame ?? this.selectionFrame,
    selectionPending: selectionPending ?? this.selectionPending,
    selectionConfirmed: selectionConfirmed ?? this.selectionConfirmed,
    selectionError: selectionError ?? this.selectionError,
    surface: surface ?? this.surface,
    second: second,
    secondError: secondError,
  );

  /// Replaces the second object, or clears it with a null [selection].
  Calibration withSecond(ObjectSelection? selection, {String? error}) =>
      Calibration(
        rulerStart: rulerStart,
        rulerEnd: rulerEnd,
        rulerLengthM: rulerLengthM,
        target: target,
        targetBbox: targetBbox,
        selectionFrame: selectionFrame,
        selectionPending: selectionPending,
        selectionConfirmed: selectionConfirmed,
        selectionError: selectionError,
        surface: surface,
        second: selection,
        secondError: error,
      );

  /// Clears both objects: the second is marked after the first.
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
    targetBbox: targetBbox,
    selectionFrame: selectionFrame,
    selectionPending: selectionPending,
    selectionConfirmed: selectionConfirmed,
    selectionError: selectionError,
    second: second,
    secondError: secondError,
  );
}
