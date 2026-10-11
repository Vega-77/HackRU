import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../core/config/app_config.dart';
import '../../core/logging/debug_log.dart';
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
  @override
  String get name => 'browser camera';

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
  final web.HTMLVideoElement _captureVideo = _newVideo();
  final Set<web.HTMLVideoElement> _previews = {};
  final web.HTMLCanvasElement _canvas = web.HTMLCanvasElement();
  web.MediaStream? _stream;
  Future<void>? _starting;
  int? _frameCallback;
  double? _frameTime;
  double _frameAvailableAt = 0;
  double _lastCallbackAt = 0;

  /// Set when the browser has no frame callbacks, or sends none for a video
  /// that is not on the page: [capture] then draws the current picture
  /// itself, timed by the page clock, so frames keep flowing.
  bool _drawOnCapture = false;

  /// How long a playing camera may go without a frame callback.
  static const Duration _callbackGrace = Duration(seconds: 1);

  @override
  bool get isRunning => _stream != null;

  @override
  FrameSize? get frameSize {
    if (!isRunning || _captureVideo.videoWidth == 0) return null;
    return _sizeForWidth(AppConfig.frameWidth);
  }

  /// A second call while the first is still opening waits for it, so the
  /// browser is not asked for the camera twice.
  @override
  Future<void> start() =>
      _starting ??= _start().whenComplete(() => _starting = null);

  Future<void> _start() async {
    if (isRunning) return;

    final devices = web.window.navigator.mediaDevices;
    final constraints = web.MediaStreamConstraints(
      audio: false.toJS,
      video: {
        // Prefer the rear camera on phones; laptops ignore this.
        'facingMode': {'ideal': 'environment'},
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        // A hint: most laptop webcams stop at 30.
        'frameRate': {'ideal': AppConfig.captureFps},
      }.jsify()!,
    );

    log.i('Asking the browser for the camera');
    try {
      _stream = await devices.getUserMedia(constraints).toDart;
    } catch (error, stack) {
      log.w('getUserMedia failed', error, stack);
      if (!await _hasCamera()) {
        log.w('The browser lists no camera');
        throw const NoCameraException();
      }
      throw const CameraUnavailableException(
        'Camera access was blocked. '
        'Allow camera access in the browser and try again.',
      );
    }

    // Previews from closed screens have left the page; the ones still on
    // screen (calibration, back from an experiment) need the new stream.
    _previews
      ..removeWhere((preview) => !preview.isConnected)
      ..forEach(_attach);
    _attach(_captureVideo);
    _drawOnCapture = !_captureVideo.has('requestVideoFrameCallback');
    if (_drawOnCapture) {
      log.w('No video frame callbacks in this browser, drawing on capture');
    } else {
      _watchFrames();
    }
    // videoWidth is 0 until the first frame's metadata arrives. A camera
    // another app holds can open and never deliver one.
    final waiting = Stopwatch()..start();
    while (_drawOnCapture
        ? _captureVideo.videoWidth == 0
        : _frameTime == null) {
      if (_stream == null) return; // Stopped meanwhile.
      if (!_drawOnCapture &&
          _captureVideo.videoWidth > 0 &&
          waiting.elapsed > _callbackGrace) {
        log.w(
          'The camera plays but sends no frame callbacks, drawing on capture',
        );
        _cancelFrameCallback();
        _drawOnCapture = true;
        break;
      }
      if (waiting.elapsed > AppConfig.cameraFirstFrameTimeout) {
        log.w('The browser camera opened but sent no frame');
        await stop();
        throw const CameraUnavailableException(
          'It opened but sent no picture. Close other tabs or apps using '
          'the camera, then try again.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    log.i(
      'Browser camera is ${_captureVideo.videoWidth}x'
      '${_captureVideo.videoHeight}, ${_previews.length} previews',
    );
  }

  @override
  Future<void> stop() async {
    final stream = _stream;
    _stream = null;
    _cancelFrameCallback();
    _frameTime = null;
    if (stream == null) return;
    log.i('Stopping the browser camera');
    // srcObject goes first, so the pause listener does not restart them.
    for (final video in [..._previews, _captureVideo]) {
      video
        ..srcObject = null
        ..pause();
    }
    for (final track in stream.getTracks().toDart) {
      track.stop();
    }
  }

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) async {
    if (!isRunning) return null;
    if (!_drawOnCapture &&
        _frameTime != null &&
        web.window.performance.now() - _lastCallbackAt >
            _callbackGrace.inMilliseconds) {
      // A live camera never stops sending frames, so the callbacks did.
      log.w('Video frame callbacks stopped, drawing on capture');
      _cancelFrameCallback();
      _drawOnCapture = true;
    }
    if (_drawOnCapture) {
      if (_captureVideo.videoWidth == 0) return null;
      _drawCurrentFrame();
      _frameAvailableAt = web.window.performance.now();
      _frameTime = _frameAvailableAt / 1000;
    }
    final timestamp = _frameTime;
    if (timestamp == null) return null;

    final size = _sizeForWidth(width);
    var canvas = _canvas;
    if (width != _canvas.width) {
      canvas = web.HTMLCanvasElement()
        ..width = size.width
        ..height = size.height;
      (canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(
        _canvas,
        0,
        0,
        size.width,
        size.height,
      );
    }

    // toDataURL is synchronous and fast at 320 px wide.
    final dataUrl = canvas.toDataURL('image/jpeg', AppConfig.jpegQuality.toJS);
    final jpeg = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));

    return EncodedFrame(
      jpeg: jpeg,
      size: size,
      captureTime: timestamp,
      ageAtEncodingMs: web.window.performance.now() - _frameAvailableAt,
    );
  }

  void _watchFrames() {
    _frameCallback = _captureVideo.requestVideoFrameCallback(
      ((double now, _VideoFrameTiming metadata) {
        if (!isRunning || _drawOnCapture) return;
        _lastCallbackAt = now;
        // The page clock: mediaTime of a live camera is not known to advance
        // in every browser, and a repeated time stops the stream as
        // duplicate frames.
        final availableAt = metadata.captureTime ?? metadata.presentationTime;
        final time = availableAt / 1000;
        if (_frameTime == null || time > _frameTime!) {
          // Copy pixels in the callback for this exact frame time. Encoding
          // and network scheduling must not change motion time.
          _drawCurrentFrame();
          _frameTime = time;
          _frameAvailableAt = availableAt;
        }
        _watchFrames();
      }).toJS,
    );
  }

  void _drawCurrentFrame() {
    final size = _sizeForWidth(AppConfig.frameWidth);
    _canvas
      ..width = size.width
      ..height = size.height;
    (_canvas.getContext('2d') as web.CanvasRenderingContext2D).drawImage(
      _captureVideo,
      0,
      0,
      size.width,
      size.height,
    );
  }

  void _cancelFrameCallback() {
    final callback = _frameCallback;
    if (callback != null) _captureVideo.cancelVideoFrameCallback(callback);
    _frameCallback = null;
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

  /// Whether the browser knows of any camera. Only asked after getUserMedia
  /// fails: before permission some browsers list devices sparsely, but a
  /// list with no camera at all is reliable.
  static Future<bool> _hasCamera() async {
    try {
      final devices = await web.window.navigator.mediaDevices
          .enumerateDevices()
          .toDart;
      return devices.toDart.any((device) => device.kind == 'videoinput');
    } catch (_) {
      return true; // Can't tell, so don't hide a real problem.
    }
  }

  FrameSize _sizeForWidth(int width) {
    final height =
        (width * _captureVideo.videoHeight / _captureVideo.videoWidth).round();
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

extension type _VideoFrameTiming._(JSObject _) implements JSObject {
  external double get mediaTime;
  external double get presentationTime;
  external double? get captureTime;
}
