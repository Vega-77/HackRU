import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import '../../core/config/app_config.dart';
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
  CameraImage? _latest;
  double _latestTime = 0;
  final Stopwatch _clock = Stopwatch()..start();

  @override
  bool get isRunning => _controller?.value.isInitialized ?? false;

  @override
  FrameSize? get frameSize {
    final image = _latest;
    if (image == null) return null;
    return _sizeForWidth(image, AppConfig.frameWidth);
  }

  @override
  Future<void> start() async {
    if (isRunning) return;

    final List<CameraDescription> cameras;
    try {
      cameras = await availableCameras();
    } on CameraException catch (e) {
      throw CameraUnavailableException(e.description ?? e.code);
    }
    if (cameras.isEmpty) throw const NoCameraException();

    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    // Medium (480p) is plenty: we send 320 px frames and the preview is
    // covered by the overlay anyway. Higher presets cost battery and heat.
    final controller = CameraController(
      back,
      ResolutionPreset.medium,
      enableAudio: false,
      fps: 30,
      imageFormatGroup: ImageFormatGroup.bgra8888,
    );

    try {
      await controller.initialize();
    } on CameraException catch (e) {
      await controller.dispose();
      throw CameraUnavailableException(
        e.code == 'CameraAccessDenied'
            ? 'Camera access is off. Turn it on in Settings, then try again.'
            : (e.description ?? e.code),
      );
    }

    _controller = controller;
    await controller.startImageStream((image) {
      _latest = image;
      _latestTime = _clock.elapsedMicroseconds / 1e6;
    });
  }

  @override
  Future<void> stop() async {
    final controller = _controller;
    _controller = null;
    _latest = null;
    if (controller == null) return;
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
