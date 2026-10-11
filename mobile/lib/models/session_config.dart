import 'dart:convert';
import 'dart:typed_data';

import 'camera_pose.dart';
import 'experiment_mode.dart';
import 'physics_state.dart';
import 'vec2.dart';

/// Pixel dimensions of the JPEG frames we stream.
class FrameSize {
  const FrameSize(this.width, this.height);

  final int width;
  final int height;

  double get aspectRatio => width / height;

  Map<String, int> toJson() => {'w': width, 'h': height};

  @override
  bool operator ==(Object other) =>
      other is FrameSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The `config` message from `docs/protocol.md`.
class SessionConfig {
  const SessionConfig({
    required this.mode,
    required this.massKg,
    required this.frameSize,
    this.pxPerM,
    this.targetPx,
    this.targetBbox,
    this.secondTargetPx,
    this.secondTargetBbox,
    this.debugTracking = false,
    this.initializationRequired = false,
    this.surface,
    this.slidingBody = false,
    this.arSurfaces = const [],
  });

  final ExperimentMode mode;
  final double massKg;
  final FrameSize frameSize;

  /// Frame pixels per metre, from the ruler calibration. Null until calibrated.
  final double? pxPerM;

  /// Where the user tapped the object, in frame pixels. Null means auto-detect.
  final Vec2? targetPx;
  final PixelRect? targetBbox;

  /// The other object in a collision, marked like [targetPx]. The backend
  /// follows it only in collision mode.
  final Vec2? secondTargetPx;
  final PixelRect? secondTargetBbox;
  final bool debugTracking;
  final bool initializationRequired;

  /// The AR surface the object moves on, iOS only. When set, the backend
  /// maps positions with the camera pose instead of [pxPerM].
  final ArSurface? surface;

  /// Ramp only: the object slides rather than rolls, so the backend reports
  /// friction and thermal energy.
  final bool slidingBody;

  /// Every plane ARKit has found, iOS only: what the object can rest
  /// against, for normal forces.
  final List<ArSurface> arSurfaces;

  Map<String, dynamic> toJson() => {
    'type': 'config',
    'mode': mode.wireName,
    'mass_kg': massKg,
    'px_per_m': pxPerM,
    'target_px': targetPx?.toJson(),
    'target_bbox': targetBbox == null
        ? null
        : {
            'x': targetBbox!.x,
            'y': targetBbox!.y,
            'w': targetBbox!.w,
            'h': targetBbox!.h,
          },
    'second_target_px': secondTargetPx?.toJson(),
    'second_target_bbox': secondTargetBbox?.toJson(),
    'frame_size': frameSize.toJson(),
    'ar_plane': surface?.toJson(),
    if (mode == ExperimentMode.ramp) 'sliding_body': slidingBody,
    if (arSurfaces.isNotEmpty)
      'ar_surfaces': [for (final s in arSurfaces) s.toSurfaceJson()],
    if (debugTracking) 'debug_tracking': true,
    if (initializationRequired) 'initialization_required': true,
  };

  String encode() => jsonEncode(toJson());
}

/// One JPEG frame ready to send, produced by a `FrameSource`.
class EncodedFrame {
  const EncodedFrame({
    required this.jpeg,
    required this.size,
    required this.captureTime,
    this.pose,
    this.ageAtEncodingMs = 0,
  });

  final Uint8List jpeg;
  final FrameSize size;

  /// Seconds on the phone's monotonic clock.
  final double captureTime;

  /// Time already spent waiting for capture/encoding on the client. When
  /// exposure time is unavailable, this starts at frame availability.
  final double ageAtEncodingMs;

  /// The camera that took this frame, when ARKit is running.
  final CameraPose? pose;
}

/// The text message sent just before each JPEG, so the backend knows which
/// frame it is and when it was captured.
class FrameMetadata {
  const FrameMetadata({
    required this.frameId,
    required this.timestamp,
    this.pose,
  });

  final int frameId;

  /// Capture time in seconds on the phone's monotonic clock.
  final double timestamp;

  final CameraPose? pose;

  Map<String, dynamic> toJson() => {
    'frame_id': frameId,
    'timestamp': timestamp,
    ...?pose?.toJson(),
  };

  String encode() => jsonEncode(toJson());
}
