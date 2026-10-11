import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import '../../core/config/app_config.dart';
import '../../core/logging/debug_log.dart';
import '../../models/session_config.dart';
import '../../models/physics_state.dart';
import 'frame_source.dart';
import 'local_visual_tracker.dart';

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
class WebFrameSource implements FrameSource, LocalVisualSource {
  @override
  String get name => 'browser camera';

  WebFrameSource({this.openStream}) {
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
  final Future<web.MediaStream> Function()? openStream;

  final String _viewType = 'hands-on-camera-${_nextViewId++}';
  final web.HTMLVideoElement _captureVideo = _newVideo();
  final Set<web.HTMLVideoElement> _previews = {};
  final web.HTMLCanvasElement _canvas = web.HTMLCanvasElement();
  final web.HTMLCanvasElement _localCanvas = web.HTMLCanvasElement();
  final LocalVisualTracker _localTracker = LocalVisualTracker();
  final List<GrayFrame> _history = [];
  final Map<double, VisualEstimate> _estimates = {};
  final _visualEstimate = ValueNotifier<VisualEstimate?>(null);
  bool _localEnabled = false;
  double _validatedAt = 0;
  double _lastLocalAt = double.negativeInfinity;
  Timer? _estimateExpiry;
  int _localFrames = 0;
  int _localMatches = 0;
  double _localTotalMs = 0;
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
      _stream =
          await (openStream?.call() ??
              devices.getUserMedia(constraints).toDart);
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
    enableLocalEstimates(false);
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
      _updateLocal(_frameTime!);
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
    final encoding = Stopwatch()..start();
    final dataUrl = canvas.toDataURL('image/jpeg', AppConfig.jpegQuality.toJS);
    final jpeg = base64Decode(dataUrl.substring(dataUrl.indexOf(',') + 1));

    return EncodedFrame(
      jpeg: jpeg,
      size: size,
      captureTime: timestamp,
      ageAtEncodingMs: web.window.performance.now() - _frameAvailableAt,
      encodeMs: encoding.elapsedMicroseconds / 1000,
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
          _updateLocal(time);
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
  bool get supportsLocalEstimates => true;
  @override
  ValueNotifier<VisualEstimate?> get visualEstimate => _visualEstimate;

  @override
  void enableLocalEstimates(bool enabled) {
    _localEnabled = enabled;
    _estimateExpiry?.cancel();
    _localFrames = _localMatches = 0;
    _localTracker.clear();
    _history.clear();
    _estimates.clear();
    _visualEstimate.value = null;
    _lastLocalAt = double.negativeInfinity;
  }

  void _updateLocal(double timestamp) {
    if (!_localEnabled || timestamp <= _lastLocalAt) return;
    final clock = Stopwatch()..start();
    _lastLocalAt = timestamp;
    _localFrames++;
    final height = (_canvas.height / 2).round();
    _localCanvas
      ..width = 160
      ..height = height;
    final context =
        _localCanvas.getContext('2d') as web.CanvasRenderingContext2D;
    context.drawImage(_canvas, 0, 0, 160, height);
    final rgba = context.getImageData(0, 0, 160, height).data.toDart;
    final gray = Uint8List(160 * height);
    for (var i = 0; i < gray.length; i++) {
      gray[i] =
          (rgba[i * 4] * 77 + rgba[i * 4 + 1] * 150 + rgba[i * 4 + 2] * 29) >>
          8;
    }
    final frame = GrayFrame(gray, 160, height, timestamp);
    _history.add(frame);
    while (_history.length > 120) {
      _estimates.remove(_history.removeAt(0).t);
    }
    // A disconnected server cannot indefinitely validate a local identity.
    if (web.window.performance.now() - _validatedAt > 1000) {
      _localTracker.lose();
      _visualEstimate.value = null;
      return;
    }
    final estimate = _localTracker.update(frame);
    if (estimate != null) _localMatches++;
    _localTotalMs = clock.elapsedMicroseconds / 1000;
    _publish(estimate);
  }

  void _publish(VisualEstimate? estimate) {
    _estimateExpiry?.cancel();
    if (estimate == null) {
      _visualEstimate.value = null;
      return;
    }
    _estimates[estimate.t] = estimate;
    final box = estimate.box;
    _visualEstimate.value = VisualEstimate(
      PixelRect(box.x * 2, box.y * 2, box.w * 2, box.h * 2),
      estimate.t,
      estimate.score,
      estimate.computeMs,
    );
    _estimateExpiry = Timer(const Duration(milliseconds: 150), () {
      _visualEstimate.value = null;
    });
  }

  @override
  Map<String, num> get localVisualStats => {
    'camera_frames': _localFrames,
    'local_matches': _localMatches,
    'local_total_ms': _localTotalMs,
    if (_visualEstimate.value case final estimate?)
      'local_frame_age_ms': (web.window.performance.now() - estimate.t * 1000)
          .clamp(0, double.infinity),
  };

  @override
  void validateLocalEstimate(PhysicsState observation) {
    if (!_localEnabled) return;
    final box = observation.bbox;
    if (!observation.tracked || box == null) {
      _localTracker.lose();
      _visualEstimate.value = null;
      return;
    }
    final index = _history.indexWhere(
      (f) => (f.t - observation.t).abs() < .000001,
    );
    if (index < 0) return; // Never put an old box on different image pixels.
    _validatedAt = web.window.performance.now();
    final smallBox = PixelRect(box.x / 2, box.y / 2, box.w / 2, box.h / 2);
    final previous = _estimates[observation.t];
    if (previous != null &&
        _visualEstimate.value != null &&
        (previous.box.centre - smallBox.centre).length < smallBox.w * .3) {
      return;
    }
    if (!_localTracker.anchor(_history[index], smallBox)) {
      _localTracker.lose();
      _visualEstimate.value = null;
      return;
    }
    _estimates.removeWhere((t, _) => t >= observation.t);
    VisualEstimate? current;
    for (final frame in _history.skip(index + 1)) {
      current = _localTracker.update(frame);
      if (current == null) break;
      _estimates[frame.t] = current;
    }
    _publish(current);
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
