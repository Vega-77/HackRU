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
/// getUserMedia directly. [capture] draws from a private `<video>` that is
/// never put on screen, and every [buildPreview] gets its own `<video>` on the
/// same stream.
///
/// The previews must not share an element: calibration stays mounted under
/// the experiment route, and handing one element to two platform views moves
/// it in the DOM, which pauses it and freezes both the picture and the frames
/// sent to the backend.
class WebFrameSource implements FrameSource {
  WebFrameSource() {
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final preview = _newVideo();
      preview.style
        ..width = '100%'
        ..height = '100%'
        ..objectFit = 'cover'
        ..pointerEvents = 'none';
      _previews.add(preview);
      _attach(preview);
      return preview;
    });
  }

  static int _nextViewId = 0;

  final String _viewType = 'hands-on-camera-${_nextViewId++}';
  final web.HTMLVideoElement _video = _newVideo();
  final Set<web.HTMLVideoElement> _previews = {};
  final web.HTMLCanvasElement _canvas = web.HTMLCanvasElement();
  web.MediaStream? _stream;

  @override
  bool get isRunning => _stream != null;

  @override
  FrameSize? get frameSize {
    if (!isRunning || _video.videoWidth == 0) return null;
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

    // Previews from closed screens have left the page; the ones still on
    // screen (calibration, back from an experiment) need the new stream.
    _previews
      ..removeWhere((preview) => !preview.isConnected)
      ..forEach(_attach);
    _attach(_video);
    // videoWidth is 0 until the first frame's metadata arrives.
    while (_video.videoWidth == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  @override
  Future<void> stop() async {
    final stream = _stream;
    _stream = null;
    if (stream == null) return;
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
    _video.srcObject = null;
    for (final preview in _previews) {
      preview.srcObject = null;
    }
  }

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) async {
    if (!isRunning || _video.videoWidth == 0) return null;

    final size = _sizeForWidth(width);
    _canvas
      ..width = size.width
      ..height = size.height;
    final context = _canvas.getContext('2d') as web.CanvasRenderingContext2D;
    context.drawImage(_video, 0, 0, size.width, size.height);

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

  /// Plays the camera stream in [video], if the camera is running.
  void _attach(web.HTMLVideoElement video) {
    final stream = _stream;
    if (stream == null) return;
    video.srcObject = stream;
    _play(video);
  }

  FrameSize _sizeForWidth(int width) {
    final height = (width * _video.videoHeight / _video.videoWidth).round();
    return FrameSize(width, height);
  }

  static web.HTMLVideoElement _newVideo() {
    final video = web.HTMLVideoElement()
      ..autoplay = true
      ..muted = true
      ..setAttribute('playsinline', 'true');
    // Browsers pause a video when it leaves the document, and autoplay does
    // not restart it, so a preview Flutter re-parents would stay frozen.
    video.addEventListener(
      'pause',
      ((web.Event _) {
        if (video.srcObject != null) _play(video);
      }).toJS,
    );
    return video;
  }

  /// play() rejects if the element is removed again before it starts; the
  /// pause listener retries, so the rejection is not an error.
  static void _play(web.HTMLVideoElement video) {
    unawaited(video.play().toDart.catchError((Object _) => null));
  }
}

FrameSource createPlatformFrameSource() => WebFrameSource();
