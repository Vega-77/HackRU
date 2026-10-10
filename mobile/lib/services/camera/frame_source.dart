import 'package:flutter/widgets.dart';

import '../../core/config/app_config.dart';
import '../../models/camera_pose.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';

/// A camera that can show a live preview and hand out JPEG frames on demand.
///
/// It is a pull model: the session asks for a frame only when the socket
/// has room (see flow control in docs/protocol.md), so frames never queue.
///
/// Implementations:
/// * `WebFrameSource`: browser getUserMedia, used for development in Chrome.
/// * `ArKitFrameSource`: an ARKit session on iOS, which also reports the
///   camera pose with every frame ([SurfaceFinder]).
/// * `NativeFrameSource`: the `camera` plugin on iOS, used when the device
///   has no ARKit world tracking.
abstract class FrameSource {
  /// Opens the camera. Throws [CameraUnavailableException] if there is no
  /// camera or the user denied permission.
  Future<void> start();

  /// Releases the camera. Safe to call more than once.
  Future<void> stop();

  bool get isRunning;

  /// Size of the frames [capture] returns at the default width, or null
  /// before [start] completes. Its aspect ratio matches the preview.
  FrameSize? get frameSize;

  /// Grabs the current camera image as a JPEG [width] pixels wide.
  /// Returns null if no image is available yet.
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth});

  /// The live preview, filling its parent like `BoxFit.cover`. The overlay's
  /// coordinate mapper assumes exactly this fit.
  Widget buildPreview(BuildContext context);
}

/// A frame source that knows where the camera is in 3D (ARKit) and can find
/// real surfaces in the picture.
abstract interface class SurfaceFinder {
  /// False until [FrameSource.start] completes, and on devices without
  /// ARKit world tracking.
  bool get canFindSurfaces;

  /// The surface seen at [framePixel] (frame pixels), or null if ARKit has
  /// not found one there yet.
  Future<ArSurface?> findSurface(Vec2 framePixel);
}

class CameraUnavailableException implements Exception {
  const CameraUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}
