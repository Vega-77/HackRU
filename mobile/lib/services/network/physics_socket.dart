import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/config/app_config.dart';
import '../../core/logging/debug_log.dart';
import '../../models/physics_state.dart';
import '../../models/session_config.dart';

enum ConnectionStatus {
  /// Not started, or stopped on purpose.
  idle,
  connecting,
  live,

  /// Lost or refused; a reconnect is scheduled.
  offline,
}

/// WebSocket client for the physics backend (see docs/protocol.md).
///
/// * Reconnects automatically and re-sends the last config.
/// * Each frame goes out as two messages: a [FrameMetadata] text, then the
///   JPEG bytes.
/// * Flow control: a bounded window covering one measured round trip, at
///   most [AppConfig.maxFramesInFlight] frames awaiting a
///   reply. The backend only processes the newest frame it has, so a reply
///   to frame N also settles every older frame. A frame with no reply after
///   [AppConfig.frameTimeout] is forgotten, so the stream can never stall.
/// * Measures round-trip latency from the echoed `frame_id`.
class PhysicsSocket {
  PhysicsSocket(
    this.url, {
    WebSocketChannel Function(Uri uri)? connector,
    Duration Function()? clock,
  }) : _connector = connector ?? WebSocketChannel.connect,
       _clock = clock ?? _stopwatchClock();

  final String url;
  final WebSocketChannel Function(Uri uri) _connector;
  final Duration Function() _clock;

  final _messages = StreamController<ServerMessage>.broadcast();
  final _status = StreamController<ConnectionStatus>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;
  SessionConfig? _lastConfig;
  bool _wanted = false;
  Completer<InitializationMessage>? _initialization;
  int? _initializationFrameId;
  int _nextFrameId = 0;

  /// frame_id → time it was sent, for frames still awaiting a reply.
  final Map<int, Duration> _inFlight = {};
  final Map<int, double> _captureAges = {};
  double? _lastCaptureTime;
  int _lastDeliveredId = -1;
  int _lastStateId = -1;
  double? _lastStateTime;

  ConnectionStatus _currentStatus = ConnectionStatus.idle;
  ConnectionStatus get status => _currentStatus;
  Stream<ConnectionStatus> get statusChanges => _status.stream;

  /// Every message from the server, already parsed.
  Stream<ServerMessage> get messages => _messages.stream;

  /// Smoothed round-trip time in milliseconds, or null before the first reply.
  double? get latencyMs => _latencyMs;
  double? _latencyMs;

  /// Round trip of the newest reply, unsmoothed. Null when that reply was
  /// for a frame already settled (the backend sends two messages a frame).
  double? get lastRttMs => _lastRttMs;
  double? _lastRttMs;
  double? get lastObservationAgeMs => _lastObservationAgeMs;
  double? _lastObservationAgeMs;

  /// Enough credits for the capture cadence during one RTT. Two credits
  /// alone cap a 600 ms connection at 3.3 FPS even when CV is fast.
  int get frameWindow => _latencyMs == null
      ? AppConfig.initialFramesInFlight
      : (1 + (_latencyMs! * AppConfig.targetFps / 1000).ceil()).clamp(
          AppConfig.initialFramesInFlight,
          AppConfig.maxFramesInFlight,
        );

  /// The id of the newest frame sent, or null before the first.
  int? get lastFrameId => _nextFrameId == 0 ? null : _nextFrameId - 1;

  /// When the current connection attempt began, for the handshake time.
  final _opening = Stopwatch();

  int get framesInFlight {
    _expireStaleFrames();
    return _inFlight.length;
  }

  /// True when a frame may be sent right now.
  bool get canSendFrame =>
      _currentStatus == ConnectionStatus.live &&
      _initialization == null &&
      framesInFlight < frameWindow;

  /// Opens the connection and keeps it open until [disconnect].
  void connect() {
    _wanted = true;
    if (_channel == null) _open();
  }

  void disconnect() {
    if (_wanted) log.i('Disconnecting from $url');
    _wanted = false;
    _reconnectTimer?.cancel();
    _closeChannel();
    _setStatus(ConnectionStatus.idle);
  }

  /// Sends the session config now (if connected) and after every reconnect.
  void sendConfig(SessionConfig config) {
    _lastConfig = config;
    if (_currentStatus == ConnectionStatus.live) {
      _channel!.sink.add(config.encode());
    }
  }

  /// Sends one frame. Returns false, and sends nothing, if flow control
  /// says the backend is still busy.
  bool sendFrame(EncodedFrame frame) {
    if (!canSendFrame) return false;
    if (!frame.captureTime.isFinite ||
        (_lastCaptureTime != null && frame.captureTime <= _lastCaptureTime!)) {
      return false;
    }
    _lastCaptureTime = frame.captureTime;
    final frameId = _nextFrameId++;
    _inFlight[frameId] = _clock();
    _captureAges[frameId] = frame.ageAtEncodingMs;
    final sink = _channel!.sink;
    sink.add(
      FrameMetadata(
        frameId: frameId,
        timestamp: frame.captureTime,
        pose: frame.pose,
      ).encode(),
    );
    sink.add(frame.jpeg);
    return true;
  }

  /// Sends the picture a selection was made in, so the backend can learn
  /// the object from it. [second] is for the other object in a collision.
  Future<InitializationMessage> initialize(
    EncodedFrame frame, {
    bool second = false,
  }) async {
    if (!canSendFrame) {
      throw StateError('The connection is not ready for initialization');
    }
    final completer = Completer<InitializationMessage>();
    _initialization = completer;
    final id = _nextFrameId++;
    _initializationFrameId = id;
    _inFlight[id] = _clock();
    _channel!.sink.add(
      jsonEncode({
        ...FrameMetadata(
          frameId: id,
          timestamp: frame.captureTime,
          pose: frame.pose,
        ).toJson(),
        'type': 'initialize',
        'selection_id': '$id',
        if (second) 'target': 'second',
      }),
    );
    _channel!.sink.add(frame.jpeg);
    try {
      return await completer.future.timeout(const Duration(seconds: 15));
    } finally {
      _initialization = null;
      _initializationFrameId = null;
      _inFlight.remove(id);
    }
  }

  /// Opens and closes one connection to [url], for "Test connection" in
  /// Settings. Returns how long the handshake took, or throws if it failed
  /// or took longer than [timeout].
  static Future<Duration> probe(
    String url, {
    Duration timeout = const Duration(seconds: 3),
    WebSocketChannel Function(Uri uri) connector = WebSocketChannel.connect,
  }) async {
    final stopwatch = Stopwatch()..start();
    final channel = connector(Uri.parse(url));
    try {
      await channel.ready.timeout(timeout);
      return stopwatch.elapsed;
    } finally {
      // Ignore close errors: a refused socket has nothing to close.
      unawaited(channel.sink.close().catchError((_) {}));
    }
  }

  Future<void> dispose() async {
    disconnect();
    await _messages.close();
    await _status.close();
  }

  void _open() {
    _setStatus(ConnectionStatus.connecting);
    final Uri uri;
    try {
      uri = Uri.parse(url);
    } on FormatException catch (e) {
      log.e('Not a valid WebSocket address: "$url"', e);
      _messages.add(ErrorMessage('"$url" is not a valid WebSocket address.'));
      _scheduleReconnect();
      return;
    }

    log.i('Connecting to $uri');
    _opening
      ..reset()
      ..start();
    final channel = _connector(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _onData,
      onError: (Object error, StackTrace stack) =>
          _onClosed(channel, error, stack),
      onDone: () => _onClosed(channel),
    );
    channel.ready.then(
      (_) {
        if (_channel != channel) return;
        _inFlight.clear();
        _captureAges.clear();
        _lastCaptureTime = null;
        _lastDeliveredId = _lastStateId = -1;
        _lastStateTime = null;
        log.i('Connected in ${_opening.elapsedMilliseconds} ms');
        _setStatus(ConnectionStatus.live);
        final config = _lastConfig;
        if (config != null) {
          log.d('Config re-sent on connect');
          channel.sink.add(config.encode());
        }
      },
      onError: (Object error, StackTrace stack) =>
          _onClosed(channel, error, stack),
    );
  }

  void _onData(dynamic data) {
    // The server only sends text.
    if (data is! String) {
      log.w('Ignored a ${data.runtimeType} message: the backend sends text');
      return;
    }
    final message = ServerMessage.parse(data);
    if (message is InitializationMessage) {
      if (message.frameId == _initializationFrameId &&
          _initialization?.isCompleted == false) {
        _recordReply(message.frameId);
        _initialization?.complete(message);
      }
      return;
    }
    if (message is ErrorMessage &&
        message.frameId == _initializationFrameId &&
        _initialization?.isCompleted == false) {
      _initialization!.completeError(StateError(message.message));
      return;
    }
    final frameId = message.frameId;
    if (frameId != null) _recordReply(frameId);
    if (message is StateMessage || message is FrameAckMessage) {
      if (frameId != null && frameId < _lastDeliveredId) return;
      if (message is StateMessage) {
        final s = message.state;
        if (s.frameId <= _lastStateId ||
            !s.t.isFinite ||
            (_lastStateTime != null && s.t <= _lastStateTime!)) {
          return;
        }
        _lastStateId = s.frameId;
        _lastStateTime = s.t;
      }
      if (frameId != null) _lastDeliveredId = frameId;
    }
    _messages.add(message);
  }

  void _recordReply(int frameId) {
    final sentAt = _inFlight[frameId];
    final captureAge = _captureAges[frameId] ?? 0;
    // Older frames were dropped by the backend in favour of this one.
    _inFlight.removeWhere((id, _) => id <= frameId);
    _captureAges.removeWhere((id, _) => id <= frameId);
    _lastRttMs = null;
    _lastObservationAgeMs = null;
    if (sentAt == null) return;
    final rttMs = (_clock() - sentAt).inMicroseconds / 1000;
    _lastRttMs = rttMs;
    _lastObservationAgeMs = rttMs + captureAge;
    // Exponential moving average so the latency chip doesn't flicker.
    _latencyMs = _latencyMs == null ? rttMs : _latencyMs! * 0.8 + rttMs * 0.2;
  }

  void _expireStaleFrames() {
    final now = _clock();
    final timeout = Duration(
      milliseconds: math.max(
        AppConfig.frameTimeout.inMilliseconds,
        ((_latencyMs ?? 0) * 3).ceil(),
      ),
    );
    final stale = [
      for (final MapEntry(key: id, value: sentAt) in _inFlight.entries)
        if (now - sentAt > timeout) id,
    ];
    if (stale.isEmpty) return;
    stale.forEach(_inFlight.remove);
    stale.forEach(_captureAges.remove);
    log.w(
      'No reply within ${timeout.inMilliseconds} ms for '
      'frame${stale.length == 1 ? '' : 's'} ${stale.join(', ')}, '
      'forgotten so frames keep flowing',
    );
  }

  void _onClosed(WebSocketChannel channel, [Object? error, StackTrace? stack]) {
    if (_channel != channel) return; // An old channel we already replaced.
    final code = channel.closeCode;
    final reason = channel.closeReason;
    final how = [
      if (code != null) 'code $code',
      if (reason != null && reason.isNotEmpty) 'reason "$reason"',
    ].join(', ');
    final message =
        '${error == null ? 'Connection closed' : 'Connection failed'}'
        '${how.isEmpty ? '' : ' ($how)'}'
        ' after ${_opening.elapsedMilliseconds} ms';
    if (error == null) {
      log.w(message);
    } else {
      log.e(message, error, stack);
    }
    _closeChannel();
    if (_wanted) {
      _setStatus(ConnectionStatus.offline);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    log.i('Reconnecting in ${AppConfig.reconnectDelay.inMilliseconds} ms');
    _reconnectTimer = Timer(AppConfig.reconnectDelay, () {
      if (_wanted && _channel == null) _open();
    });
  }

  void _closeChannel() {
    if (_initialization case final pending? when !pending.isCompleted) {
      pending.completeError(
        StateError('The connection closed during initialization'),
      );
    }
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _inFlight.clear();
    _captureAges.clear();
  }

  void _setStatus(ConnectionStatus next) {
    if (_currentStatus == next || _status.isClosed) return;
    _currentStatus = next;
    _status.add(next);
  }

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }
}
