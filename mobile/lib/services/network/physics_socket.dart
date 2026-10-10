import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/config/app_config.dart';
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
/// * Flow control: at most [AppConfig.maxFramesInFlight] frames awaiting a
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
  int _nextFrameId = 0;

  /// frame_id → time it was sent, for frames still awaiting a reply.
  final Map<int, Duration> _inFlight = {};

  ConnectionStatus _currentStatus = ConnectionStatus.idle;
  ConnectionStatus get status => _currentStatus;
  Stream<ConnectionStatus> get statusChanges => _status.stream;

  /// Every message from the server, already parsed.
  Stream<ServerMessage> get messages => _messages.stream;

  /// Smoothed round-trip time in milliseconds, or null before the first reply.
  double? get latencyMs => _latencyMs;
  double? _latencyMs;

  int get framesInFlight {
    _expireStaleFrames();
    return _inFlight.length;
  }

  /// True when a frame may be sent right now.
  bool get canSendFrame =>
      _currentStatus == ConnectionStatus.live &&
      framesInFlight < AppConfig.maxFramesInFlight;

  /// Opens the connection and keeps it open until [disconnect].
  void connect() {
    _wanted = true;
    if (_channel == null) _open();
  }

  void disconnect() {
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
    final frameId = _nextFrameId++;
    _inFlight[frameId] = _clock();
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
    } on FormatException {
      _messages.add(ErrorMessage('"$url" is not a valid WebSocket address.'));
      _scheduleReconnect();
      return;
    }

    final channel = _connector(uri);
    _channel = channel;
    _subscription = channel.stream.listen(
      _onData,
      onError: (_) => _onClosed(channel),
      onDone: () => _onClosed(channel),
    );
    channel.ready.then((_) {
      if (_channel != channel) return;
      _inFlight.clear();
      _setStatus(ConnectionStatus.live);
      final config = _lastConfig;
      if (config != null) channel.sink.add(config.encode());
    }, onError: (_) => _onClosed(channel));
  }

  void _onData(dynamic data) {
    if (data is! String) return; // The server only sends text.
    final message = ServerMessage.parse(data);
    final frameId = message.frameId;
    if (frameId != null) _recordReply(frameId);
    _messages.add(message);
  }

  void _recordReply(int frameId) {
    final sentAt = _inFlight[frameId];
    // Older frames were dropped by the backend in favour of this one.
    _inFlight.removeWhere((id, _) => id <= frameId);
    if (sentAt == null) return;
    final rttMs = (_clock() - sentAt).inMicroseconds / 1000;
    // Exponential moving average so the latency chip doesn't flicker.
    _latencyMs = _latencyMs == null ? rttMs : _latencyMs! * 0.8 + rttMs * 0.2;
  }

  void _expireStaleFrames() {
    final now = _clock();
    _inFlight.removeWhere((_, sentAt) => now - sentAt > AppConfig.frameTimeout);
  }

  void _onClosed(WebSocketChannel channel) {
    if (_channel != channel) return; // An old channel we already replaced.
    _closeChannel();
    if (_wanted) {
      _setStatus(ConnectionStatus.offline);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(AppConfig.reconnectDelay, () {
      if (_wanted && _channel == null) _open();
    });
  }

  void _closeChannel() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _inFlight.clear();
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
