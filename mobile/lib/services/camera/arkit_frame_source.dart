import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/config/app_config.dart';
import '../../core/logging/debug_log.dart';
import '../../models/ar_vectors.dart';
import '../../models/camera_pose.dart';
import '../../models/physics_state.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';
import 'frame_source.dart';

/// iOS camera through an ARKit session (`ios/Runner/ArSessionPlugin.swift`).
///
/// Every frame carries the camera's intrinsics and its pose in the world, so
/// the backend can turn a 2D centroid into a 3D point on a real surface. On
/// devices without ARKit world tracking it hands everything to [fallback].
///
/// The preview also draws arrows anchored in the world ([showArVectors]),
/// so they stay on the object while the phone moves. It follows the
/// object on every camera frame between replies and reports where
/// ([followedBox]), so the 2D marker can stay on it too.
///
/// ARKit owns the camera while it runs, so this never runs at the same time
/// as the `camera` plugin.
class ArKitFrameSource implements FrameSource, SurfaceFinder, ArVectorDisplay {
  ArKitFrameSource({required this.fallback});

  static const _channel = MethodChannel('handson/arkit');
  static const viewType = 'handson/arkit_view';

  final FrameSource fallback;

  bool? _supported;
  bool _running = false;
  FrameSize? _frameSize;

  /// Whether the native view has arrows on screen, so a hide is sent once
  /// and a failure is logged once, not on every reply.
  bool _vectorsShown = false;
  bool _vectorsFailed = false;

  /// The newest frame's camera, to size the object for [showArVectors].
  CameraPose? _pose;

  final _followedBox = ValueNotifier<PixelRect?>(null);

  /// Followed frames and restarts since [_statsSince], for a once a second
  /// summary in the log.
  int _followedFrames = 0;
  int _followRestarts = 0;
  double? _statsSince;

  bool get _useFallback => _supported == false;

  @override
  String get name => _useFallback ? fallback.name : 'ARKit camera';

  @override
  bool get isRunning => _useFallback ? fallback.isRunning : _running;

  @override
  bool get canFindSurfaces => _running && _supported == true;

  @override
  bool get canShowArVectors =>
      _running && _supported == true && !_vectorsFailed;

  @override
  FrameSize? get frameSize => _useFallback ? fallback.frameSize : _frameSize;

  @override
  ValueListenable<PixelRect?> get followedBox => _followedBox;

  @override
  Future<void> start() async {
    if (_supported == null) {
      _supported = await _isSupported();
      log.i(
        _supported!
            ? 'ARKit world tracking is available'
            : 'No ARKit world tracking, using the ${fallback.name}',
      );
    }
    if (_useFallback) return fallback.start();
    if (_running) return;
    try {
      final size = await _channel.invokeMapMethod<String, Object?>('start', {
        'width': AppConfig.frameWidth,
      });
      _frameSize = FrameSize(size!['width']! as int, size['height']! as int);
      _running = true;
      _channel.setMethodCallHandler(_onNativeCall);
      log.i('ARKit session started, frames $_frameSize');
    } on PlatformException catch (e, stack) {
      log.e('ARKit session failed to start: ${e.code}', e, stack);
      throw CameraUnavailableException(
        e.code == 'denied'
            ? 'Camera access is off. Turn it on in Settings, then try again.'
            : (e.message ?? e.code),
      );
    }
  }

  @override
  Future<void> stop() async {
    if (_useFallback) return fallback.stop();
    if (!_running) return;
    _running = false;
    // The native side hides the arrows and stops following when it stops.
    _vectorsShown = false;
    _stopFollowing();
    log.i('Stopping the ARKit session');
    await _channel.invokeMethod<void>('stop');
  }

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) async {
    if (_useFallback) return fallback.capture(width: width);
    if (!_running) return null;
    final frame = await _channel.invokeMapMethod<String, Object?>('capture', {
      'width': width,
      'quality': AppConfig.jpegQuality,
    });
    if (frame == null) return null;
    final pose = _pose = CameraPose.fromMap(frame);
    return EncodedFrame(
      jpeg: frame['jpeg']! as Uint8List,
      size: FrameSize(frame['width']! as int, frame['height']! as int),
      captureTime: (frame['timestamp']! as num).toDouble(),
      pose: pose,
    );
  }

  @override
  Future<ArSurface?> findSurface(Vec2 framePixel) async {
    if (!canFindSurfaces) return null;
    final hit = await _channel.invokeMapMethod<String, Object?>('raycast', {
      'x': framePixel.x,
      'y': framePixel.y,
      'width': _frameSize!.width,
    });
    final surface = hit == null ? null : ArSurface.fromMap(hit);
    log.i(
      surface == null
          ? 'No AR surface at $framePixel'
          : 'AR surface at $framePixel: '
                '${surface.vertical ? 'vertical' : 'horizontal'}, '
                'point ${surface.point}, normal ${surface.normal}',
    );
    return surface;
  }

  @override
  Future<void> showArVectors(ArVectorScene? scene) async {
    if (!canShowArVectors) return;
    if (scene == null && !_vectorsShown) return;
    try {
      if (scene == null) {
        _vectorsShown = false;
        _stopFollowing();
        await _channel.invokeMethod<void>('hideVectors');
      } else {
        if (!_vectorsShown) log.i('Showing 3D arrows');
        _vectorsShown = true;
        // Without a box the native side stops following.
        if (scene.box == null) _stopFollowing();
        await _channel.invokeMethod<void>(
          'setVectors',
          scene.toMap(
            occluderRadiusM: _occluderRadius(scene),
            frameSize: _frameSize,
          ),
        );
      }
    } on PlatformException catch (e, stack) {
      // The 2D overlay would be hidden, so stop sending and say why.
      _vectorsFailed = true;
      log.e('The AR view could not draw arrows: ${e.code}', e, stack);
    } on MissingPluginException catch (e, stack) {
      _vectorsFailed = true;
      log.e('This build has no 3D arrow support', e, stack);
    }
  }

  /// The object's real radius at its anchor, from its size in the newest
  /// frame. 0 before any frame, which draws the arrows over the object.
  double _occluderRadius(ArVectorScene scene) {
    final pose = _pose;
    if (pose == null || scene.objectRadiusPx <= 0) return 0;
    return pose.metresAcross(scene.objectRadiusPx, scene.origin);
  }

  Future<void> _onNativeCall(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'objectFollowed' when args is Map:
        _followed(args);
      case 'objectLost':
        if (_followedBox.value == null) return;
        _stopFollowing();
        final reason = args is Map ? args['reason'] : null;
        log.i(
          'On-device tracking lost the object ($reason). The arrows go back '
          'to the backend position until its next reply.',
        );
    }
  }

  void _followed(Map<Object?, Object?> args) {
    final size = _frameSize;
    final box = args['box'];
    final timestamp = args['timestamp'];
    // A late call after the arrows were hidden would bring the marker back.
    if (size == null || !_vectorsShown || timestamp is! num) return;
    if (box is! List || box.length != 4 || box.any((v) => v is! num)) return;
    final [x, y, w, h] = box.cast<num>().map((v) => v.toDouble()).toList();
    if (_followedBox.value == null) log.i('Following the object on device');
    _followedBox.value = PixelRect(
      x * size.width,
      y * size.height,
      w * size.width,
      h * size.height,
    );

    _followedFrames++;
    if (args['restarted'] == true) _followRestarts++;
    final now = timestamp.toDouble();
    final since = _statsSince ??= now;
    if (now - since >= 1) {
      log.d(
        'On-device tracking: $_followedFrames frames, '
        '$_followRestarts restarts from the backend box in '
        '${(now - since).toStringAsFixed(1)} s, confidence '
        '${(args['confidence'] as num? ?? 0).toStringAsFixed(2)}',
      );
      _followedFrames = 0;
      _followRestarts = 0;
      _statsSince = now;
    }
  }

  void _stopFollowing() {
    _followedBox.value = null;
    _followedFrames = 0;
    _followRestarts = 0;
    _statsSince = null;
  }

  @override
  Widget buildPreview(BuildContext context) {
    if (_useFallback) return fallback.buildPreview(context);
    if (!_running) return const SizedBox.expand();
    // ARSCNView fills its bounds like BoxFit.cover, as the overlay expects.
    return const UiKitView(viewType: viewType);
  }

  static Future<bool> _isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    }
  }
}
