import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../core/config/app_config.dart';
import '../../core/logging/debug_log.dart';
import '../../models/ar_vectors.dart';
import '../../models/camera_pose.dart';
import '../../models/physics_state.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';
import 'frame_source.dart';
import 'test_video_frame_source.dart';

/// The device camera, or the [TestVideoFrameSource] when the device has
/// none, so the iOS Simulator still streams something the backend can
/// track.
///
/// Only a missing camera switches to the test video. Any other failure,
/// like camera access being turned off, is passed on so the user can fix it.
///
/// Surface finding and 3D arrows are passed through when the camera
/// supports them (ARKit), so wrapping never hides them.
class CameraOrTestVideo implements FrameSource, SurfaceFinder, ArVectorDisplay {
  CameraOrTestVideo(this._camera, {TestVideoFrameSource? testVideo})
    : _testVideo = testVideo ?? TestVideoFrameSource();

  final FrameSource _camera;
  final TestVideoFrameSource _testVideo;
  late FrameSource _active = _camera;

  bool get usingTestVideo => identical(_active, _testVideo);

  @override
  String get name => _active.name;

  @override
  Future<void> start() async {
    if (isRunning) return;
    try {
      await _camera.start();
      _active = _camera;
    } on NoCameraException {
      log.w('No camera, so the test video stands in');
      _active = _testVideo;
      await _testVideo.start();
    }
  }

  @override
  Future<void> stop() => _active.stop();

  @override
  bool get isRunning => _active.isRunning;

  @override
  FrameSize? get frameSize => _active.frameSize;

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) =>
      _active.capture(width: width);

  @override
  Widget buildPreview(BuildContext context) => _active.buildPreview(context);

  @override
  bool get canFindSurfaces => switch (_active) {
    final SurfaceFinder f => f.canFindSurfaces,
    _ => false,
  };

  @override
  Future<ArSurface?> findSurface(Vec2 framePixel) async => switch (_active) {
    final SurfaceFinder f => f.findSurface(framePixel),
    _ => null,
  };

  @override
  bool get canShowArVectors => switch (_active) {
    final ArVectorDisplay d => d.canShowArVectors,
    _ => false,
  };

  @override
  Future<void> showArVectors(ArVectorScene? scene) async {
    if (_active case final ArVectorDisplay d) await d.showArVectors(scene);
  }

  /// The test video never follows anything, so the camera's box is right
  /// either way: it stays null while the camera is idle.
  @override
  ValueListenable<PixelRect?> get followedBox => switch (_camera) {
    final ArVectorDisplay d => d.followedBox,
    _ => _noBox,
  };

  static final _noBox = ValueNotifier<PixelRect?>(null);
}
