import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/config/app_config.dart';
import '../../models/camera_pose.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';
import 'frame_source.dart';

/// iOS camera through an ARKit session (`ios/Runner/ArSessionPlugin.swift`).
///
/// Every frame carries the camera's intrinsics and its pose in the world, so
/// the backend can turn a 2D centroid into a 3D point on a real surface. On
/// devices without ARKit world tracking it hands everything to [fallback].
///
/// ARKit owns the camera while it runs, so this never runs at the same time
/// as the `camera` plugin.
class ArKitFrameSource implements FrameSource, SurfaceFinder {
  ArKitFrameSource({required this.fallback});

  static const _channel = MethodChannel('handson/arkit');
  static const viewType = 'handson/arkit_view';

  final FrameSource fallback;

  bool? _supported;
  bool _running = false;
  FrameSize? _frameSize;

  bool get _useFallback => _supported == false;

  @override
  bool get isRunning => _useFallback ? fallback.isRunning : _running;

  @override
  bool get canFindSurfaces => _running && _supported == true;

  @override
  FrameSize? get frameSize => _useFallback ? fallback.frameSize : _frameSize;

  @override
  Future<void> start() async {
    _supported ??= await _isSupported();
    if (_useFallback) return fallback.start();
    if (_running) return;
    try {
      final size = await _channel.invokeMapMethod<String, Object?>('start', {
        'width': AppConfig.frameWidth,
      });
      _frameSize = FrameSize(size!['width']! as int, size['height']! as int);
      _running = true;
    } on PlatformException catch (e) {
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
    return EncodedFrame(
      jpeg: frame['jpeg']! as Uint8List,
      size: FrameSize(frame['width']! as int, frame['height']! as int),
      captureTime: (frame['timestamp']! as num).toDouble(),
      pose: CameraPose.fromMap(frame),
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
    return hit == null ? null : ArSurface.fromMap(hit);
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
