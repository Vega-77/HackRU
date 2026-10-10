import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../models/physics_state.dart';
import '../models/session_config.dart';
import '../services/camera/frame_source_factory.dart';
import '../services/network/physics_socket.dart';
import 'calibration_controller.dart';
import 'experiment_settings.dart';
import 'telemetry_buffer.dart';

enum SessionPhase { idle, starting, running, paused, failed }

/// Everything the experiment screen needs to know about the live session.
class SessionState {
  const SessionState({
    this.phase = SessionPhase.idle,
    this.connection = ConnectionStatus.idle,
    this.latest,
    this.frameSize,
    this.cameraError,
    this.serverError,
    this.latencyMs,
    this.sendFps = 0,
    this.telemetryVersion = 0,
  });

  final SessionPhase phase;
  final ConnectionStatus connection;

  /// Newest state from the backend.
  final PhysicsState? latest;

  /// Size of the frames we stream; overlay coordinates are in these pixels.
  final FrameSize? frameSize;

  /// Set when the camera could not start.
  final String? cameraError;

  /// The last `error` message from the backend.
  final String? serverError;

  final double? latencyMs;
  final double sendFps;

  /// Increments whenever [SessionController.telemetry] changes.
  final int telemetryVersion;

  bool get isActive =>
      phase == SessionPhase.running || phase == SessionPhase.paused;

  SessionState copyWith({
    SessionPhase? phase,
    ConnectionStatus? connection,
    PhysicsState? latest,
    FrameSize? frameSize,
    String? cameraError,
    String? serverError,
    double? latencyMs,
    double? sendFps,
    int? telemetryVersion,
    bool clearErrors = false,
  }) => SessionState(
    phase: phase ?? this.phase,
    connection: connection ?? this.connection,
    latest: latest ?? this.latest,
    frameSize: frameSize ?? this.frameSize,
    cameraError: clearErrors ? null : (cameraError ?? this.cameraError),
    serverError: clearErrors ? null : (serverError ?? this.serverError),
    latencyMs: latencyMs ?? this.latencyMs,
    sendFps: sendFps ?? this.sendFps,
    telemetryVersion: telemetryVersion ?? this.telemetryVersion,
  );
}

/// The one camera for the whole app, shared by calibration and experiment.
final frameSourceProvider = Provider<FrameSource>((ref) {
  final source = createFrameSource();
  ref.onDispose(source.stop);
  return source;
});

/// Runs an experiment session: camera → [PhysicsSocket] → backend → states
/// back.
///
/// Incoming states update [SessionState.latest] and feed [telemetry].
/// Changing settings or calibration mid-session re-sends the config.
class SessionController extends Notifier<SessionState> {
  /// A 4:3 frame at the streaming width, assumed until the camera reports
  /// its real size.
  static const fallbackFrameSize = FrameSize(AppConfig.frameWidth, 240);

  final TelemetryBuffer telemetry = TelemetryBuffer();

  PhysicsSocket? _socket;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _frameTimer;
  Timer? _statsTimer;
  bool _capturing = false;
  Future<void>? _stopInProgress;
  int _sessionEpoch = 0;

  int get sessionEpoch => _sessionEpoch;

  /// Set once the backend sends a real `state`; from then on CV-only
  /// reports are ignored so the two never fight over the overlay.
  bool _hasPhysics = false;
  int _framesSentThisSecond = 0;

  /// Whether [start] opened the camera. Calibration usually has it open
  /// already and is still on screen under the experiment, so [stop] must
  /// leave it running then.
  bool _ownsCamera = false;

  FrameSource get _camera => ref.read(frameSourceProvider);

  @override
  SessionState build() {
    ref.onDispose(_teardown);

    ref.listen(experimentSettingsProvider, (previous, next) {
      if (!state.isActive || previous == null) return;
      if (previous.backendUrl != next.backendUrl) {
        _startSocket(next.backendUrl);
      } else if (previous.mode != next.mode || previous.massKg != next.massKg) {
        telemetry.clear();
        _socket?.sendConfig(_config());
      }
    });
    ref.listen(calibrationProvider, (_, _) => _socket?.sendConfig(_config()));

    return const SessionState();
  }

  Future<void> start() async {
    final stopping = _stopInProgress;
    if (stopping != null) await stopping;
    if (!ref.mounted) return;
    if (state.phase == SessionPhase.starting || state.isActive) return;
    _sessionEpoch++;
    state = state.copyWith(phase: SessionPhase.starting, clearErrors: true);
    telemetry.clear();

    _ownsCamera = !_camera.isRunning;
    try {
      await _camera.start();
    } on CameraUnavailableException catch (e) {
      if (ref.mounted) {
        state = state.copyWith(
          phase: SessionPhase.failed,
          cameraError: e.message,
        );
      }
      return;
    }
    if (!ref.mounted) return;

    state = state.copyWith(
      phase: SessionPhase.running,
      frameSize: _camera.frameSize ?? fallbackFrameSize,
    );
    _startSocket(ref.read(experimentSettingsProvider).backendUrl);
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickStats(),
    );
  }

  /// Freezes the overlay and stops sending frames. The camera keeps running.
  void pause() {
    if (state.phase == SessionPhase.running) {
      state = state.copyWith(phase: SessionPhase.paused);
    }
  }

  void resume() {
    if (state.phase == SessionPhase.paused) {
      state = state.copyWith(phase: SessionPhase.running);
    }
  }

  /// Hides the last backend error banner until a new error arrives.
  void dismissServerError() {
    if (state.serverError == null) return;
    state = SessionState(
      phase: state.phase,
      connection: state.connection,
      latest: state.latest,
      frameSize: state.frameSize,
      cameraError: state.cameraError,
      latencyMs: state.latencyMs,
      sendFps: state.sendFps,
      telemetryVersion: state.telemetryVersion,
    );
  }

  Future<void> stop({int? onlyIfEpoch}) {
    // A screen from an older route transition must not stop a newer session.
    if (!ref.mounted || (onlyIfEpoch != null && onlyIfEpoch != _sessionEpoch)) {
      return Future.value();
    }
    if (_stopInProgress != null) return _stopInProgress!;
    // Setup may already have restarted the shared camera after this session.
    if (state.phase == SessionPhase.idle) return Future.value();
    return _stopInProgress = _stopSession().whenComplete(() {
      _stopInProgress = null;
    });
  }

  Future<void> _stopSession() async {
    _teardown();
    if (_ownsCamera) {
      _ownsCamera = false;
      await _camera.stop();
    }
    if (ref.mounted) state = const SessionState();
  }

  /// Connects to [url], replacing any socket that is already open.
  void _startSocket(String url) {
    _stopSocket();
    _hasPhysics = false;
    final socket = PhysicsSocket(url);
    _socket = socket;
    _subscriptions
      ..add(
        socket.statusChanges.listen((status) {
          state = state.copyWith(connection: status);
        }),
      )
      ..add(
        socket.messages.listen((message) {
          switch (message) {
            case StateMessage(state: final physics):
              _hasPhysics = true;
              _onState(physics);
            // Until the physics stage answers, the CV report still says
            // where the object is, so the marker and x(t) chart work.
            case FrameAckMessage(:final target?) when !_hasPhysics:
              _onState(target);
            case ErrorMessage(:final message):
              state = state.copyWith(serverError: message);
            case FrameAckMessage() || UnknownMessage():
              break;
          }
        }),
      );
    socket
      ..sendConfig(_config())
      ..connect();
    _frameTimer = Timer.periodic(
      Duration(microseconds: 1000000 ~/ AppConfig.targetFps),
      (_) => _pumpFrame(),
    );
  }

  /// Sends one frame if the socket has room. Called at the target FPS.
  Future<void> _pumpFrame() async {
    final socket = _socket;
    if (socket == null ||
        _capturing ||
        state.phase != SessionPhase.running ||
        !socket.canSendFrame) {
      return;
    }
    _capturing = true;
    try {
      final frame = await _camera.capture();
      if (frame != null && socket.sendFrame(frame)) _framesSentThisSecond++;
    } finally {
      _capturing = false;
    }
  }

  void _onState(PhysicsState physics) {
    if (!ref.mounted || state.phase != SessionPhase.running) return;
    telemetry.add(physics);
    state = state.copyWith(
      latest: physics,
      telemetryVersion: state.telemetryVersion + 1,
    );
  }

  void _tickStats() {
    if (!ref.mounted) return;
    state = state.copyWith(
      sendFps: _framesSentThisSecond.toDouble(),
      latencyMs: _socket?.latencyMs,
    );
    _framesSentThisSecond = 0;
  }

  SessionConfig _config() {
    final settings = ref.read(experimentSettingsProvider);
    final calibration = ref.read(calibrationProvider);
    return SessionConfig(
      mode: settings.mode,
      massKg: settings.massKg,
      frameSize: state.frameSize ?? fallbackFrameSize,
      pxPerM: calibration.pxPerM,
      targetPx: calibration.target,
      surface: calibration.surface,
    );
  }

  void _stopSocket() {
    _frameTimer?.cancel();
    _frameTimer = null;
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    _socket?.dispose();
    _socket = null;
  }

  void _teardown() {
    _stopSocket();
    _statsTimer?.cancel();
    _statsTimer = null;
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
