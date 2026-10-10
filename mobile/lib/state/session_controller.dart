import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../models/physics_state.dart';
import '../models/session_config.dart';
import '../services/camera/frame_source_factory.dart';
import '../services/network/mock_physics_stream.dart';
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

  /// Newest state from the backend or the mock.
  final PhysicsState? latest;

  /// Size of the frames we stream; overlay coordinates are in these pixels.
  final FrameSize? frameSize;

  /// Set when the camera could not start. In demo mode the session still
  /// runs, over a plain grid instead of the camera.
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
  }) =>
      SessionState(
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

/// Runs an experiment session:
///
/// * demo mode: camera preview (if available) + [mockPhysicsStream];
/// * live mode: camera → [PhysicsSocket] → backend → states back.
///
/// Incoming states update [SessionState.latest] and feed [telemetry].
/// Changing settings or calibration mid-session re-sends the config.
class SessionController extends Notifier<SessionState> {
  final TelemetryBuffer telemetry = TelemetryBuffer();

  PhysicsSocket? _socket;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  StreamSubscription<PhysicsState>? _mock;
  Timer? _frameTimer;
  Timer? _statsTimer;
  bool _capturing = false;
  int _framesSentThisSecond = 0;

  FrameSource get _camera => ref.read(frameSourceProvider);

  @override
  SessionState build() {
    ref.onDispose(_teardown);

    ref.listen(experimentSettingsProvider, (previous, next) {
      if (!state.isActive || previous == null) return;
      final sourceChanged = previous.demoMode != next.demoMode ||
          previous.backendUrl != next.backendUrl;
      if (sourceChanged) {
        _restartDataSource();
      } else if (previous.mode != next.mode || previous.massKg != next.massKg) {
        telemetry.clear();
        if (next.demoMode) _startMock();
        _socket?.sendConfig(_config());
      }
    });
    ref.listen(calibrationProvider, (_, _) => _socket?.sendConfig(_config()));

    return const SessionState();
  }

  Future<void> start() async {
    if (state.phase == SessionPhase.starting || state.isActive) return;
    state = state.copyWith(phase: SessionPhase.starting, clearErrors: true);
    telemetry.clear();

    String? cameraError;
    try {
      await _camera.start();
    } on CameraUnavailableException catch (e) {
      cameraError = e.message;
    }
    if (!ref.mounted) return;

    final demo = ref.read(experimentSettingsProvider).demoMode;
    if (cameraError != null && !demo) {
      state = state.copyWith(phase: SessionPhase.failed, cameraError: cameraError);
      return;
    }

    state = state.copyWith(
      phase: SessionPhase.running,
      frameSize: _camera.frameSize ?? const FrameSize(320, 240),
      cameraError: cameraError,
    );
    _restartDataSource();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickStats());
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

  Future<void> stop() async {
    _teardown();
    await _camera.stop();
    if (ref.mounted) state = const SessionState();
  }

  void _restartDataSource() {
    _stopDataSource();
    final settings = ref.read(experimentSettingsProvider);
    if (settings.demoMode) {
      state = state.copyWith(connection: ConnectionStatus.idle);
      _startMock();
    } else {
      _startSocket(settings.backendUrl);
    }
  }

  void _startMock() {
    _mock?.cancel();
    final settings = ref.read(experimentSettingsProvider);
    _mock = mockPhysicsStream(
      mode: settings.mode,
      frameSize: state.frameSize ?? const FrameSize(320, 240),
      massKg: settings.massKg,
    ).listen(_onState);
  }

  void _startSocket(String url) {
    final socket = PhysicsSocket(url);
    _socket = socket;
    _subscriptions
      ..add(socket.statusChanges.listen((status) {
        state = state.copyWith(connection: status);
      }))
      ..add(socket.messages.listen((message) {
        switch (message) {
          case StateMessage(state: final physics):
            _onState(physics);
          case ErrorMessage(:final message):
            state = state.copyWith(serverError: message);
          // CV-only reports carry no physics yet; the socket already used
          // them for flow control and latency.
          case FrameAckMessage() || UnknownMessage():
            break;
        }
      }));
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
      frameSize: state.frameSize ?? const FrameSize(320, 240),
      pxPerM: calibration.pxPerM,
      targetPx: calibration.target,
    );
  }

  void _stopDataSource() {
    _mock?.cancel();
    _mock = null;
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
    _stopDataSource();
    _statsTimer?.cancel();
    _statsTimer = null;
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
