import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import '../../core/config/app_config.dart';
import '../../core/logging/debug_log.dart';
import '../../models/session_config.dart';
import 'arkit_frame_source.dart';
import 'frame_source.dart';

/// iOS camera through the `camera` plugin, for devices without ARKit
/// world tracking (see `ArKitFrameSource`).
///
/// The plugin streams raw BGRA frames. We keep only the newest one and,
/// when [capture] is called, downsample and JPEG-encode it in a background
/// isolate so the UI thread never stalls.
///
/// On iOS the plugin already rotates streamed frames to match the device
/// orientation, so frames are upright in both portrait and landscape.
class NativeFrameSource implements FrameSource {
  CameraController? _controller;
  Future<void>? _starting;
  CameraImage? _latest;
  double _latestTime = 0;
  final Stopwatch _clock = Stopwatch()..start();

  @override
  String get name => 'iOS camera';

  @override
  bool get isRunning => _controller?.value.isInitialized ?? false;

  @override
  FrameSize? get frameSize {
    final image = _latest;
    if (image == null) return null;
    return _sizeForWidth(image, AppConfig.frameWidth);
  }

  /// Setup and the session both start the camera; a second call while the
  /// first is still opening waits for it instead of opening the camera twice.
  @override
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (isRunning) return;

    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (e, stack) {
      log.e('Listing cameras failed: ${e.code}', e, stack);
      throw CameraUnavailableException(e.description ?? e.code);
    }
    if (cameras.isEmpty) {
      log.w('This device has no camera');
      throw const NoCameraException();
    }

    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    log.i(
      'Opening ${back.name} (${back.lensDirection.name}) of '
      '${cameras.length} cameras',
    );

    // Medium (480p) is plenty: we send 320 px frames and the preview is
    // covered by the overlay anyway. Higher presets cost battery and heat.
    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      // The plugin picks the closest rate the camera supports.
      fps: AppConfig.captureFps,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await controller.initialize();
    } on CameraException catch (e, stack) {
      log.e('Camera init failed: ${e.code}', e, stack);
      await controller.dispose();
      throw CameraUnavailableException(
        e.code == 'CameraAccessDenied'
            ? 'Camera access is off. Turn it on in Settings, then try again.'
            : (e.description ?? e.code),
      );
    }

    _controller = controller;
    log.i('Camera preview is ${controller.value.previewSize}');
    final firstFrame = Completer<void>();
    await controller.startImageStream((image) {
      if (_latest == null) {
        log.i(
          'First camera frame: ${image.width}x${image.height}, '
          '${image.format.group.name}',
        );
      }
      _latest = image;
      _latestTime = _clock.elapsedMicroseconds / 1e6;
      if (!firstFrame.isCompleted) firstFrame.complete();
    });
    // frameSize comes from the first frame, and setup lays out the stage
    // with it, so the camera has not started until there is one.
    try {
      await firstFrame.future.timeout(AppConfig.cameraFirstFrameTimeout);
    } on TimeoutException {
      if (!identical(_controller, controller)) return; // Stopped meanwhile.
      log.w('The camera opened but sent no frame');
      await stop();
      throw const CameraUnavailableException(
        'It opened but sent no picture. Close other apps using the camera, '
        'then try again.',
      );
    }
  }

  @override
  Future<void> stop() async {
    final controller = _controller;
    _controller = null;
    _latest = null;
    if (controller == null) return;
    log.i('Closing the camera');
    if (controller.value.isStreamingImages) {
      await controller.stopImageStream();
    }
    await controller.dispose();
  }

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) async {
    final image = _latest;
    if (image == null) return null;

    final plane = image.planes.first;
    final job = _EncodeJob(
      // Copy: the plugin reuses this buffer for the next frame.
      bytes: Uint8List.fromList(plane.bytes),
      width: image.width,
      height: image.height,
      rowStride: plane.bytesPerRow,
      targetWidth: width,
      quality: (AppConfig.jpegQuality * 100).round(),
    );
    final captureTime = _latestTime;
    final jpeg = await Isolate.run(() => _encode(job));

    return EncodedFrame(
      jpeg: jpeg,
      size: _sizeForWidth(image, width),
      captureTime: captureTime,
      ageAtEncodingMs: (_clock.elapsedMicroseconds / 1e6 - captureTime) * 1000,
    );
  }

  @override
  Widget buildPreview(BuildContext context) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.expand();
    }
    // CameraPreview sizes itself by aspect ratio; FittedBox makes it cover
    // the parent the same way the web <video> does with object-fit: cover.
    final preview = controller.value.previewSize!;
    final portrait = MediaQuery.orientationOf(context) == Orientation.portrait;
    final longSide = preview.longestSide;
    final shortSide = preview.shortestSide;
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: portrait ? shortSide : longSide,
          height: portrait ? longSide : shortSide,
          child: CameraPreview(controller),
        ),
      ),
    );
  }

  static FrameSize _sizeForWidth(CameraImage image, int width) =>
      FrameSize(width, (width * image.height / image.width).round());
}

class _EncodeJob {
  const _EncodeJob({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rowStride,
    required this.targetWidth,
    required this.quality,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final int rowStride;
  final int targetWidth;
  final int quality;
}

/// Runs in a background isolate: BGRA → downsample → JPEG.
Uint8List _encode(_EncodeJob job) {
  final full = img.Image.fromBytes(
    width: job.width,
    height: job.height,
    bytes: job.bytes.buffer,
    rowStride: job.rowStride,
    numChannels: 4,
    order: img.ChannelOrder.bgra,
  );
  final small = img.copyResize(
    full,
    width: job.targetWidth,
    interpolation: img.Interpolation.average,
  );
  return img.encodeJpg(small, quality: job.quality);
}

FrameSource createPlatformFrameSource() =>
    ArKitFrameSource(fallback: NativeFrameSource());
