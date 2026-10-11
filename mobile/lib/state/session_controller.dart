import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/logging/debug_log.dart';
import '../models/calibration.dart';
import '../models/experiment_mode.dart';
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
    this.serverErrorCount = 0,
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
  final ErrorMessage? serverError;

  /// How many times in a row the backend sent [serverError]'s message, so a
  /// one-off glitch reads differently from a crash on every frame.
  final int serverErrorCount;

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
    ErrorMessage? serverError,
    int? serverErrorCount,
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
    serverErrorCount: clearErrors
        ? 0
        : (serverErrorCount ?? this.serverErrorCount),
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
/// Every step goes to the debug log, one line per frame sent and received.
class SessionController extends Notifier<SessionState> {
  /// A 4:3 frame at the streaming width, assumed until the camera reports
  /// its real size.
  static const fallbackFrameSize = FrameSize(AppConfig.frameWidth, 240);

  /// Repeated camera problems are logged the first time and every this
  /// many times after, so a dead camera doesn't fill the log.
  static const _repeatLogEvery = 30;

  final TelemetryBuffer telemetry = TelemetryBuffer();

  PhysicsSocket? _socket;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _frameTimer;
  Timer? _statsTimer;
  bool _capturing = false;
  EncodedFrame? _selectionFrame;

  /// The second collision object's picture, sent after [_selectionFrame]:
  /// initializing the first object makes the backend forget the second.
  EncodedFrame? _secondSelectionFrame;
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

  // Counters for the debug log only.
  final _sessionClock = Stopwatch();
  int _framesSent = 0;
  int _replies = 0;
  int _errors = 0;
  int _missingFrames = 0;
  int _failedCaptures = 0;
  int _waitingTicks = 0;
  int _encodingTicks = 0;
  bool? _tracking;
  bool _foundOnce = false;
  String? _notSendingBecause;

  FrameSource get _camera => ref.read(frameSourceProvider);

  @override
  SessionState build() {
    ref.onDispose(_teardown);
    log.context = _logContext;
    ref.onDispose(() {
      if (log.context == _logContext) log.context = null;
    });

    ref.listen(experimentSettingsProvider, (previous, next) {
      if (!state.isActive || previous == null) return;
      if (previous.backendUrl != next.backendUrl) {
        log.i('Backend changed mid-session to ${next.backendUrl}');
        _startSocket(next.backendUrl);
      } else if (previous.mode != next.mode ||
          previous.massKg != next.massKg ||
          previous.slidingBody != next.slidingBody) {
        telemetry.clear();
        _sendConfig('mode, mass or ramp body changed');
      }
    });
    ref.listen(calibrationProvider, (previous, next) {
      if (previous?.selectionFrame != next.selectionFrame ||
          previous?.targetBbox != next.targetBbox) {
        _selectionFrame = next.selectionFrame;
        _secondSelectionFrame = _secondFrame(next);
      } else if (previous?.second != next.second) {
        _secondSelectionFrame = _secondFrame(next);
      }
      if (_socket != null) _sendConfig('calibration changed');
    });

    return const SessionState();
  }

  Future<void> start() async {
    final stopping = _stopInProgress;
    if (stopping != null) {
      log.d('Start waits for the previous session to stop');
      await stopping;
    }
    if (!ref.mounted) return;
    if (state.phase == SessionPhase.starting || state.isActive) {
      log.d('Start ignored: the session is already ${state.phase.name}');
      return;
    }
    _sessionEpoch++;
    _resetCounters();
    final settings = ref.read(experimentSettingsProvider);
    final calibration = ref.read(calibrationProvider);
    log.markSession('Session $_sessionEpoch: ${settings.mode.label}');
    log.i(
      'Starting: mode ${settings.mode.wireName}, mass ${settings.massKg} kg, '
      'backend ${settings.backendUrl}',
    );
    log.i(
      'Calibration: '
      '${calibration.pxPerM?.toStringAsFixed(1) ?? 'no'} px/m, '
      'ruler ${calibration.rulerStart} to ${calibration.rulerEnd} '
      '(${calibration.rulerLengthM} m), target ${calibration.target}, '
      'surface ${calibration.surface == null ? 'none' : 'set'}',
    );
    state = state.copyWith(phase: SessionPhase.starting, clearErrors: true);
    telemetry.clear();

    _ownsCamera = !_camera.isRunning;
    log.i(
      _ownsCamera
          ? 'Opening the ${_camera.name}'
          : 'Reusing the ${_camera.name} that setup opened',
    );
    final opening = Stopwatch()..start();
    try {
      await _camera.start();
    } on CameraUnavailableException catch (e, stack) {
      log.e('Camera did not start', e, stack);
      if (ref.mounted) {
        state = state.copyWith(
          phase: SessionPhase.failed,
          cameraError: e.message,
        );
      }
      return;
    } catch (e, stack) {
      log.e('Camera start threw', e, stack);
      rethrow;
    }
    if (!ref.mounted) {
      log.w('The session closed while the camera was opening');
      return;
    }

    final frameSize = _camera.frameSize;
    _selectionFrame = calibration.selectionFrame?.size == frameSize
        ? calibration.selectionFrame
        : null;
    _secondSelectionFrame = _secondFrame(calibration)?.size == frameSize
        ? _secondFrame(calibration)
        : null;
    log.i(
      'Camera ready in ${opening.elapsedMilliseconds} ms, frames '
      '${frameSize ?? '$fallbackFrameSize (assumed, none reported yet)'}',
    );
    state = state.copyWith(
      phase: SessionPhase.running,
      frameSize: frameSize ?? fallbackFrameSize,
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
      log.i('Paused');
      state = state.copyWith(phase: SessionPhase.paused);
    }
  }

  void resume() {
    if (state.phase == SessionPhase.paused) {
      log.i('Resumed');
      state = state.copyWith(phase: SessionPhase.running);
    }
  }

  /// Hides the last backend error banner until a new error arrives.
  void dismissServerError() {
    if (state.serverError == null) return;
    log.d('Backend error banner dismissed');
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
    if (!ref.mounted) return Future.value();
    // A screen from an older route transition must not stop a newer session.
    if (onlyIfEpoch != null && onlyIfEpoch != _sessionEpoch) {
      log.d(
        'Stop skipped: it was for session $onlyIfEpoch, '
        'session $_sessionEpoch is running',
      );
      return Future.value();
    }
    if (_stopInProgress != null) return _stopInProgress!;
    // Setup may already have restarted the shared camera after this session.
    if (state.phase == SessionPhase.idle) return Future.value();
    log.i('Stopping session $_sessionEpoch (${state.phase.name})');
    return _stopInProgress = _stopSession().whenComplete(() {
      _stopInProgress = null;
    });
  }

  Future<void> _stopSession() async {
    _teardown();
    if (_ownsCamera) {
      _ownsCamera = false;
      await _camera.stop();
      log.i('Camera closed');
    } else {
      log.i('Camera left on for setup');
    }
    log.i(
      'Session $_sessionEpoch ended after '
      '${(_sessionClock.elapsedMilliseconds / 1000).toStringAsFixed(1)} s: '
      '$_framesSent frames sent, $_replies replies, $_errors errors',
    );
    if (ref.mounted) state = const SessionState();
  }

  /// Connects to [url], replacing any socket that is already open.
  void _startSocket(String url) {
    _stopSocket();
    _hasPhysics = false;
    _tracking = null;
    _foundOnce = false;
    final socket = PhysicsSocket(url);
    _socket = socket;
    _subscriptions
      ..add(
        socket.statusChanges.listen((status) {
          if (status == ConnectionStatus.live) {
            final calibration = ref.read(calibrationProvider);
            _selectionFrame = calibration.selectionFrame;
            _secondSelectionFrame = _secondFrame(calibration);
          }
          state = state.copyWith(connection: status);
        }),
      )
      ..add(
        socket.messages.listen((message) {
          switch (message) {
            case StateMessage(state: final physics):
              _logState(physics, socket.lastRttMs);
              _hasPhysics = true;
              _onState(physics);
            // Until the physics stage answers, the CV report still says
            // where the object is, so the marker and x(t) chart work.
            case FrameAckMessage():
              _logReport(message, socket.lastRttMs);
              if (message.target case final target? when !_hasPhysics) {
                _onState(target);
              }
            case final ErrorMessage error:
              _onServerError(error);
            case InitializationMessage():
              break;
            case UnknownMessage(:final raw):
              log.w('Unrecognised message from the backend: ${_clip(raw)}');
          }
        }),
      );
    _sendConfig('session start');
    socket.connect();
    _frameTimer = Timer.periodic(
      Duration(microseconds: 1000000 ~/ AppConfig.targetFps),
      (_) => _pumpFrame(),
    );
  }

  /// Sends one frame if the socket has room. Called at the target FPS.
  Future<void> _pumpFrame() async {
    final socket = _socket;
    if (socket == null) return;
    if (state.phase != SessionPhase.running) {
      return _noteNotSending('the session is ${state.phase.name}');
    }
    if (socket.status != ConnectionStatus.live) {
      return _noteNotSending('the backend is ${socket.status.name}');
    }
    _noteNotSending(null);
    // Both are normal: the encoder or the backend is still busy. They are
    // counted into the once-a-second summary instead.
    if (_capturing) {
      _encodingTicks++;
      return;
    }
    if (!socket.canSendFrame) {
      _waitingTicks++;
      return;
    }
    _capturing = true;
    final capturing = Stopwatch()..start();
    try {
      final second = _selectionFrame == null;
      if (_selectionFrame ?? _secondSelectionFrame case final selected?) {
        try {
          final ack = await socket.initialize(selected, second: second);
          if (!ref.mounted || socket != _socket) return;
          log.i(
            '${second ? 'Second object initialization' : 'Initialization'} '
            '${ack.status}: ${ack.reason}, frame ${ack.frameId}, capture ${selected.captureTime}',
          );
          if (ack.status != 'initialized') {
            _onServerError(
              ErrorMessage(
                'Object initialization failed (${ack.reason}). Return to setup and retry selection.',
              ),
            );
            state = state.copyWith(phase: SessionPhase.failed);
            return;
          }
          if (second) {
            _secondSelectionFrame = null;
          } else {
            _selectionFrame = null;
          }
          _framesSent++;
          _framesSentThisSecond++;
        } catch (error, stack) {
          if (!ref.mounted || socket != _socket) return;
          log.w('Initialization handshake failed', error, stack);
          _onServerError(
            const ErrorMessage(
              'Object initialization was not acknowledged. Return to setup and retry selection.',
            ),
          );
          state = state.copyWith(phase: SessionPhase.failed);
        }
        return;
      }
      final frame = await _camera.capture();
      if (frame == null) {
        _missingFrames++;
        if (_missingFrames % _repeatLogEvery == 1) {
          log.w('The camera had no frame to send ($_missingFrames so far)');
        }
      } else if (socket.sendFrame(frame)) {
        _selectionFrame = null;
        _framesSentThisSecond++;
        _framesSent++;
        log.d(
          'Frame ${socket.lastFrameId} sent: '
          '${(frame.jpeg.length / 1024).toStringAsFixed(1)} KB, ${frame.size}, '
          'captured in ${capturing.elapsedMilliseconds} ms, '
          '${socket.framesInFlight} in flight'
          '${frame.pose == null ? '' : ', with ARKit pose'}',
        );
      } else {
        log.d('Frame dropped: the backend got busy while it was captured');
      }
    } catch (e, stack) {
      _failedCaptures++;
      if (_failedCaptures % _repeatLogEvery == 1) {
        log.e('Capturing a frame failed ($_failedCaptures so far)', e, stack);
      }
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

  void _onServerError(ErrorMessage error) {
    _errors++;
    final repeat = error.message == state.serverError?.message;
    state = state.copyWith(
      serverError: error,
      serverErrorCount: repeat ? state.serverErrorCount + 1 : 1,
    );
    log.e(
      'Backend error'
      '${error.frameId == null ? '' : ' on frame ${error.frameId}'}'
      ' (${state.serverErrorCount} in a row): ${error.message}'
      '${error.where == null ? '' : ', at ${error.where}'}'
      '${error.serverVersion == null ? '' : ', backend ${error.serverVersion}'}',
    );
  }

  void _tickStats() {
    if (!ref.mounted) return;
    state = state.copyWith(
      sendFps: _framesSentThisSecond.toDouble(),
      latencyMs: _socket?.latencyMs,
    );
    log.d(
      'Last second: $_framesSentThisSecond frames sent, latency '
      '${_socket?.latencyMs?.toStringAsFixed(0) ?? '?'} ms, '
      '${_socket?.framesInFlight ?? 0} in flight, waited $_waitingTicks '
      'ticks for replies and $_encodingTicks for the encoder, '
      '${state.phase.name}, ${state.connection.name}',
    );
    _framesSentThisSecond = 0;
    _waitingTicks = 0;
    _encodingTicks = 0;
  }

  void _sendConfig(String why) {
    final config = _config();
    log.i('Config ($why): ${config.encode()}');
    _socket?.sendConfig(config);
  }

  /// The second object's picture, when this experiment follows it.
  EncodedFrame? _secondFrame(Calibration calibration) =>
      _followsSecond(calibration) ? calibration.second!.frame : null;

  bool _followsSecond(Calibration calibration) =>
      ref.read(experimentSettingsProvider).mode == ExperimentMode.collision &&
      calibration.selectionFrame != null &&
      (calibration.second?.confirmed ?? false);

  SessionConfig _config() {
    final settings = ref.read(experimentSettingsProvider);
    final calibration = ref.read(calibrationProvider);
    final second = _followsSecond(calibration) ? calibration.second : null;
    return SessionConfig(
      mode: settings.mode,
      massKg: settings.massKg,
      frameSize: state.frameSize ?? fallbackFrameSize,
      pxPerM: calibration.pxPerM,
      targetPx: calibration.target,
      targetBbox: calibration.targetBbox,
      secondTargetPx: second?.point,
      secondTargetBbox: second?.box,
      debugTracking: const bool.fromEnvironment('TRACKING_DIAGNOSTICS'),
      initializationRequired: calibration.selectionFrame != null,
      surface: calibration.surface,
      slidingBody: settings.slidingBody,
    );
  }

  void _logState(PhysicsState s, double? rttMs) {
    _replies++;
    if (s.trackingDebug.isNotEmpty) {
      log.d('Tracking decision: ${jsonEncode(s.trackingDebug)}');
    }
    log.d(
      'Frame ${s.frameId} state${_rtt(rttMs)}: '
      '${s.tracked ? 'tracked' : 'not tracked'}, '
      't ${s.t.toStringAsFixed(3)} s, pixel ${s.pixel}, '
      'position ${s.position}, v ${s.velocity}, a ${s.acceleration}, '
      '${s.forces.length} forces',
    );
    _noteTracking(s.tracked, s.frameId);
  }

  void _logReport(FrameAckMessage report, double? rttMs) {
    _replies++;
    log.d(
      'Frame ${report.frameId} report${_rtt(rttMs)}: '
      '${report.processMs?.toStringAsFixed(1) ?? '?'} ms on the backend, '
      'target ${report.target?.pixel}, '
      'objects ${_clip(jsonEncode(report.objects))}',
    );
    if (!_hasPhysics) _noteTracking(report.target != null, report.frameId);
  }

  /// Logs only when the target is found or lost, not on every frame.
  void _noteTracking(bool tracked, int frameId) {
    if (tracked == _tracking) return;
    final first = _tracking == null;
    _tracking = tracked;
    if (tracked) {
      log.i('Target ${_foundOnce ? 'found again' : 'found'} at frame $frameId');
      _foundOnce = true;
    } else {
      log.w(
        first
            ? 'The first reply (frame $frameId) has no target'
            : 'Target lost at frame $frameId',
      );
    }
  }

  /// Logs only when the reason frames aren't going out changes.
  void _noteNotSending(String? because) {
    if (because == _notSendingBecause) return;
    _notSendingBecause = because;
    log.d(because == null ? 'Sending frames' : 'Not sending frames: $because');
  }

  void _resetCounters() {
    _sessionClock
      ..reset()
      ..start();
    _framesSent = 0;
    _replies = 0;
    _errors = 0;
    _missingFrames = 0;
    _failedCaptures = 0;
    _waitingTicks = 0;
    _encodingTicks = 0;
    _notSendingBecause = null;
  }

  /// The top of a copied log: what the session is set up to do right now.
  Map<String, Object?> _logContext() {
    final settings = ref.read(experimentSettingsProvider);
    final calibration = ref.read(calibrationProvider);
    return {
      'backend': settings.backendUrl,
      'mode': settings.mode.wireName,
      'mass_kg': settings.massKg,
      'px_per_m': calibration.pxPerM?.toStringAsFixed(1),
      'target_px': calibration.target,
      'ar_surface': calibration.surface != null,
      'camera': _camera.name,
      'session':
          '$_sessionEpoch, ${state.phase.name}, ${state.connection.name}',
      'frame_size': state.frameSize,
    };
  }

  static String _rtt(double? ms) =>
      ms == null ? '' : ' after ${ms.toStringAsFixed(0)} ms';

  static String _clip(String text) =>
      text.length <= 300 ? text : '${text.substring(0, 300)}...';

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
