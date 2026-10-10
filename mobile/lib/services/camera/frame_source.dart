import 'package:flutter/widgets.dart';

import '../../core/config/app_config.dart';
import '../../models/session_config.dart';

/// A camera that can show a live preview and hand out JPEG frames on demand.
///
/// It is a pull model: the session asks for a frame only when the socket
/// has room (see flow control in docs/protocol.md), so frames never queue.
///
/// Implementations:
/// * `WebFrameSource`: browser getUserMedia, used for development in Chrome.
/// * `NativeFrameSource`: the `camera` plugin on iOS.
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

class CameraUnavailableException implements Exception {
  const CameraUnavailableException(this.message);
  final String message;

  @override
  String toString() => message;
}
