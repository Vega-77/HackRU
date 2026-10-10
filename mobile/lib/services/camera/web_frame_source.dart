import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../core/config/app_config.dart';
import '../../models/session_config.dart';
import 'frame_source.dart';

/// Browser camera for development in Chrome.
///
/// The `camera` plugin cannot stream frames on web, so this talks to
/// getUserMedia directly. A dedicated video feeds [capture], while each
/// [HtmlElementView] gets its own preview element. Reusing one DOM element in
/// two views makes the preview freeze when navigating between screens.
class WebFrameSource implements FrameSource {
  static int _nextViewId = 0;

  final String _viewType = 'hands-on-camera-${_nextViewId++}';
  final web.HTMLVideoElement _captureVideo = web.HTMLVideoElement();
  final Set<web.HTMLVideoElement> _previews = {};
  final web.HTMLCanvasElement _canvas = web.HTMLCanvasElement();
  web.MediaStream? _stream;
  bool _registered = false;

  @override
  bool get isRunning => _stream != null;

  @override
  FrameSize? get frameSize {
    if (!isRunning || _captureVideo.videoWidth == 0) return null;
    return _sizeForWidth(AppConfig.frameWidth);
  }

  @override
  Future<void> start() async {
    if (isRunning) return;

    final devices = web.window.navigator.mediaDevices;
    final constraints = web.MediaStreamConstraints(
      audio: false.toJS,
      video: {
        // Prefer the rear camera on phones; laptops ignore this.
        'facingMode': {'ideal': 'environment'},
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
      }.jsify()!,
    );

    try {
      _stream = await devices.getUserMedia(constraints).toDart;
    } catch (e) {
      throw CameraUnavailableException(
        'Camera access was blocked or no camera was found. '
        'Allow camera access in the browser and try again.',
      );
    }

    _captureVideo
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true')
      ..srcObject = _stream;

    if (!_registered) {
      ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
        final preview = web.HTMLVideoElement()
          ..autoplay = true
          ..muted = true
          ..setAttribute('playsinline', 'true')
          ..srcObject = _stream;
        preview.style
          ..width = '100%'
          ..height = '100%'
          ..objectFit = 'cover'
          ..pointerEvents = 'none';
        _previews.add(preview);
        return preview;
      });
      _registered = true;
    }

    await _captureVideo.play().toDart;
    // videoWidth is 0 until the first frame's metadata arrives.
    while (_captureVideo.videoWidth == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  @override
  Future<void> stop() async {
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    for (final preview in _previews) {
      preview.pause();
      preview.srcObject = null;
    }
    _previews.clear();
    _captureVideo.pause();
    _captureVideo.srcObject = null;
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
  }

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) async {
    if (!isRunning || _captureVideo.videoWidth == 0) return null;

    final size = _sizeForWidth(width);
    _canvas
      ..width = size.width
      ..height = size.height;
    final context = _canvas.getContext('2d') as web.CanvasRenderingContext2D;
    context.drawImage(_captureVideo, 0, 0, size.width, size.height);

    // toDataURL is synchronous and fast at 320 px wide.
    final dataUrl = _canvas.toDataURL('image/jpeg', AppConfig.jpegQuality.toJS);
    final jpeg = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));

    return EncodedFrame(
      jpeg: jpeg,
      size: size,
      captureTime: web.window.performance.now() / 1000,
    );
  }

  @override
  Widget buildPreview(BuildContext context) =>
      HtmlElementView(viewType: _viewType);

  FrameSize _sizeForWidth(int width) {
    final height =
        (width * _captureVideo.videoHeight / _captureVideo.videoWidth).round();
    return FrameSize(width, height);
  }
}

FrameSource createPlatformFrameSource() => WebFrameSource();
