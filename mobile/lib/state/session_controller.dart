import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/logging/debug_log.dart';
import '../models/calibration.dart';
import '../models/camera_pose.dart';
import '../models/experiment_mode.dart';
import '../services/network/recorded_analysis.dart';
import '../services/network/capture_export.dart';
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
    this.recordingPhase = RecordingPhase.idle,
    this.recordingProgress = 0,
    this.recordingMessage,
    this.recordedLatest,
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
  final RecordingPhase recordingPhase;
  final double recordingProgress;
  final String? recordingMessage;
  final PhysicsState? recordedLatest;
  bool get recordingBusy =>
      recordingPhase == RecordingPhase.recording ||
      recordingPhase == RecordingPhase.analyzing;

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
    RecordingPhase? recordingPhase,
    double? recordingProgress,
    String? recordingMessage,
    PhysicsState? recordedLatest,
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
    recordingPhase: recordingPhase ?? this.recordingPhase,
    recordingProgress: recordingProgress ?? this.recordingProgress,
    recordingMessage: recordingMessage ?? this.recordingMessage,
    recordedLatest: recordedLatest ?? this.recordedLatest,
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
  Timer? _observationTimer;
  bool _capturing = false;
  EncodedFrame? _selectionFrame;
  final RecordedAnalyzer _recordedAnalyzer = RecordedAnalyzer();
  RecordedSequence? _recordedSequence;
  EncodedFrame? _recordedSelection;
  SessionConfig? _recordedConfig;
  DateTime? _recordedAt;
  Map<String, dynamic> _recordedRuler = const {};
  final List<PhysicsState> _recordedObservations = [];
  String? _recordedAnalysisError;
  int _recordingEpoch = 0;

  /// The second collision object's picture, sent after [_selectionFrame]:
  /// initializing the first object makes the backend forget the second.
  EncodedFrame? _secondSelectionFrame;
  Future<void>? _stopInProgress;

  /// Every plane ARKit has found, re-read while the session runs, so the
  /// backend can tell what the object rests against (normal forces).
  List<ArSurface> _arSurfaces = const [];
  bool _readingSurfaces = false;

  /// The backend accepts this many planes; ARKit rarely finds more.
  static const _maxArSurfaces = 32;
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

  late FrameSource _camera;

  @override
  SessionState build() {
    _camera = ref.read(frameSourceProvider);
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
        _cancelRecording();
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
    _setLocalEstimates(true);
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
      _setLocalEstimates(false);
    }
  }

  void resume() {
    if (state.recordingBusy) return;
    if (state.phase == SessionPhase.paused) {
      if (state.recordingPhase != RecordingPhase.idle) {
        telemetry.clear();
        state = state.copyWith(
          recordingPhase: RecordingPhase.idle,
          telemetryVersion: state.telemetryVersion + 1,
        );
      }
      log.i('Resumed');
      state = state.copyWith(phase: SessionPhase.running);
      _setLocalEstimates(true);
    }
  }

  void _setLocalEstimates(bool enabled) {
    if (_camera case final LocalVisualSource source) {
      source.enableLocalEstimates(enabled);
    }
  }

  Future<void> recordFreeFall() async {
    if (state.recordingBusy ||
        !state.isActive ||
        ref.read(experimentSettingsProvider).mode != ExperimentMode.freeFall) {
      return;
    }
    final calibration = ref.read(calibrationProvider);
    final selection = calibration.selectionFrame;
    if (selection == null || calibration.pxPerM == null) {
      state = state.copyWith(
        recordingPhase: RecordingPhase.failed,
        recordingMessage:
            'Calibrate the ruler and confirm an object selection first.',
      );
      return;
    }
    final epoch = ++_recordingEpoch;
    pause();
    _observationTimer?.cancel();
    _recordedSelection = selection;
    _recordedConfig = _config();
    _recordedSequence = null;
    _recordedAt = DateTime.now().toUtc();
    _recordedRuler = {
      'start': calibration.rulerStart?.toJson(),
      'end': calibration.rulerEnd?.toJson(),
      'length_m': calibration.rulerLengthM,
    };
    _recordedObservations.clear();
    _recordedAnalysisError = null;
    state = state.copyWith(
      recordingPhase: RecordingPhase.recording,
      recordingProgress: 0,
      latest: const PhysicsState(
        frameId: -1,
        t: 0,
        tracked: false,
        trackingStatus: 'recording',
      ),
      recordingMessage:
          'Hold briefly, then release. Keep the full fall in view.',
    );
    try {
      _recordedSequence = await SequenceRecorder().collect(
        _camera,
        cancelled: () => !ref.mounted || epoch != _recordingEpoch,
        progress: (p) {
          if (ref.mounted && epoch == _recordingEpoch) {
            state = state.copyWith(recordingProgress: p.clamp(0, 1));
          }
        },
      );
      if (!ref.mounted || epoch != _recordingEpoch) return;
      log.i(
        'Recorded ${_recordedSequence!.frames.length} fresh frames, '
        '${_recordedSequence!.fps.toStringAsFixed(1)} FPS, '
        'maximum gap ${_recordedSequence!.maxGapMs.toStringAsFixed(1)} ms',
      );
      await retryRecordedAnalysis();
    } catch (error) {
      if (ref.mounted && epoch == _recordingEpoch) {
        state = state.copyWith(
          recordingPhase: RecordingPhase.failed,
          recordingMessage: '$error',
        );
      }
    }
  }

  Future<void> retryRecordedAnalysis() async {
    final sequence = _recordedSequence;
    final selection = _recordedSelection;
    final config = _recordedConfig;
    if (sequence == null ||
        selection == null ||
        config == null ||
        state.recordingPhase == RecordingPhase.analyzing) {
      return;
    }
    final epoch = _recordingEpoch;
    _recordedObservations.clear();
    _recordedAnalysisError = null;
    state = state.copyWith(
      recordingPhase: RecordingPhase.analyzing,
      recordingProgress: 0,
      recordingMessage: 'Analyzing saved frames. Capture times are preserved.',
    );
    try {
      final states = await _recordedAnalyzer.analyze(
        url: ref.read(experimentSettingsProvider).backendUrl,
        config: config,
        selection: selection,
        sequence: sequence,
        onObservation: (observation) {
          if (ref.mounted && epoch == _recordingEpoch) {
            _recordedObservations.add(observation);
          }
        },
        progress: (p) {
          if (ref.mounted && epoch == _recordingEpoch) {
            state = state.copyWith(recordingProgress: p);
          }
        },
      );
      if (!ref.mounted || epoch != _recordingEpoch) return;
      telemetry.clear();
      for (final observation in states) {
        telemetry.add(observation);
        log.d(
          'Recorded frame ${observation.frameId}, t=${observation.t}, '
          'pixel=${observation.pixel}, bbox=${observation.bbox?.toJson()}, '
          'v=${observation.velocity}, a=${observation.acceleration}, '
          'tracking=${jsonEncode(observation.trackingDebug)}, '
          'quality=${jsonEncode(observation.physicsQuality)}',
        );
      }
      final located = states
          .where((s) => s.tracked && s.position != null)
          .length;
      final acceleration = states.where((s) => s.acceleration != null).length;
      state = state.copyWith(
        recordingPhase: RecordingPhase.complete,
        recordedLatest: states.lastWhere(
          (s) => s.tracked && s.position != null,
          orElse: () => const PhysicsState(frameId: -1, t: 0, tracked: false),
        ),
        telemetryVersion: state.telemetryVersion + 1,
        recordingMessage:
            '$located/${states.length} measured positions at '
            '${sequence.fps.toStringAsFixed(1)} capture FPS. '
            '$acceleration acceleration estimates passed quality checks. '
            'Charts show the saved recording.',
      );
    } catch (error) {
      if (ref.mounted && epoch == _recordingEpoch) {
        _recordedAnalysisError = '$error';
        state = state.copyWith(
          recordingPhase: RecordingPhase.failed,
          recordingMessage: '$error. Saved frames remain available for retry.',
        );
      }
    }
  }

  bool get canRetryRecordedAnalysis => _recordedSequence != null;

  bool get canExportRecording =>
      !state.recordingBusy &&
      _recordedSequence != null &&
      _recordedSelection != null &&
      _recordedConfig != null &&
      _recordedAt != null;

  CaptureExport exportRecording() {
    if (!canExportRecording) {
      throw StateError('No completed capture to download.');
    }
    return exportCapture(
      sequence: _recordedSequence!,
      selection: _recordedSelection!,
      config: _recordedConfig!,
      capturedAt: _recordedAt!,
      ruler: _recordedRuler,
      observations: _recordedObservations,
      analysisError: _recordedAnalysisError,
    );
  }

  void cancelRecording() {
    _cancelRecording();
    state = state.copyWith(
      recordingMessage:
          'Recording cancelled. Resume live tracking or record again.',
    );
  }

  void _cancelRecording() {
    _recordingEpoch++;
    _recordedAnalyzer.cancel();
    _recordedSequence = null;
    _recordedSelection = null;
    _recordedConfig = null;
    _recordedAt = null;
    _recordedRuler = const {};
    _recordedObservations.clear();
    _recordedAnalysisError = null;
    if (ref.mounted) {
      state = state.copyWith(recordingPhase: RecordingPhase.idle);
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
      recordingPhase: state.recordingPhase,
      recordingProgress: state.recordingProgress,
      recordingMessage: state.recordingMessage,
      recordedLatest: state.recordedLatest,
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
          'JPEG encode ${frame.encodeMs.toStringAsFixed(2)} ms, '
          'age at send ${frame.ageAtEncodingMs.toStringAsFixed(2)} ms, '
          '${socket.framesInFlight} in flight'
          '${frame.pose == null ? '' : ', with ARKit pose'}',
        );
      } else {
        log.d('Frame skipped: duplicate capture or no transport credit');
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
    if (_camera case final LocalVisualSource source) {
      source.validateLocalEstimate(physics);
    }
    _observationTimer?.cancel();
    telemetry.add(physics);
    state = state.copyWith(
      latest: physics,
      telemetryVersion: state.telemetryVersion + 1,
    );
    if (!physics.tracked) return;
    final remainingMs =
        AppConfig.observationExpiry.inMilliseconds -
        (_socket?.lastObservationAgeMs ?? 0);
    void expire() {
      if (!ref.mounted ||
          state.phase != SessionPhase.running ||
          !identical(state.latest, physics)) {
        return;
      }
      state = state.copyWith(
        latest: PhysicsState(
          frameId: physics.frameId,
          t: physics.t,
          tracked: false,
          trackingStatus: 'stale',
        ),
      );
      log.w(
        'Observation ${physics.frameId} expired; waiting for a fresh camera frame',
      );
    }

    if (remainingMs <= 0) {
      expire();
    } else {
      _observationTimer = Timer(
        Duration(milliseconds: remainingMs.ceil()),
        expire,
      );
    }
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
    unawaited(_refreshSurfaces());
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
    if (_camera case final LocalVisualSource source
        when source.supportsLocalEstimates) {
      log.d(
        'Browser capture/local timings: ${jsonEncode(source.localVisualStats)}',
      );
    }
    _framesSentThisSecond = 0;
    _waitingTicks = 0;
    _encodingTicks = 0;
  }

  Future<void> _refreshSurfaces() async {
    final finder = switch (_camera) {
      final SurfaceFinder f when f.canFindSurfaces => f,
      _ => null,
    };
    if (_readingSurfaces ||
        finder == null ||
        ref.read(calibrationProvider).surface == null) {
      return;
    }
    _readingSurfaces = true;
    try {
      final found = (await finder.allSurfaces()).take(_maxArSurfaces).toList();
      if (!ref.mounted || _socket == null) return;
      if (_sameSurfaces(found, _arSurfaces)) return;
      _arSurfaces = found;
      _sendConfig('AR surfaces changed, ${found.length} found');
    } catch (e, st) {
      log.w('Could not read the AR surfaces', e, st);
    } finally {
      _readingSurfaces = false;
    }
  }

  /// ARKit keeps refining planes as it sees more of them. Small changes
  /// don't move where the object touches them, so they aren't resent.
  static bool _sameSurfaces(List<ArSurface> a, List<ArSurface> b) {
    if (a.length != b.length) return false;
    final byId = {for (final s in b) s.id: s};
    for (final s in a) {
      final old = byId[s.id];
      if (old == null) return false;
      var moved = 0.0, turned = 0.0;
      for (var i = 0; i < 3; i++) {
        moved += (s.point[i] - old.point[i]) * (s.point[i] - old.point[i]);
        turned += s.normal[i] * old.normal[i];
      }
      if (moved > 0.05 * 0.05 || turned < 0.995) return false;
    }
    return true;
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
      arSurfaces: calibration.surface == null ? const [] : _arSurfaces,
    );
  }

  void _logState(PhysicsState s, double? rttMs) {
    _replies++;
    if (s.trackingDebug.isNotEmpty) {
      log.d('Tracking decision: ${jsonEncode(s.trackingDebug)}');
    }
    log.d(
      'Frame ${s.frameId} timing: observation age '
      '${_socket?.lastObservationAgeMs?.toStringAsFixed(1) ?? "?"} ms, '
      'CV/physics ${s.processMs?.toStringAsFixed(1) ?? "?"} ms, '
      'queue ${s.queueMs?.toStringAsFixed(1) ?? "?"} ms; '
      'stages ${jsonEncode(s.timingMs)}, '
      'transport/response ${rttMs == null || s.processMs == null || s.queueMs == null ? "?" : (rttMs - s.processMs! - s.queueMs!).clamp(0, double.infinity).toStringAsFixed(1)} ms; '
      'physics quality ${jsonEncode(s.physicsQuality)}',
    );
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
    _arSurfaces = const [];
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
    _observationTimer?.cancel();
    _observationTimer = null;
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
    _recordingEpoch++;
    _recordedAnalyzer.cancel();
    _setLocalEstimates(false);
    _stopSocket();
    _statsTimer?.cancel();
    _statsTimer = null;
  }
}

final sessionProvider = NotifierProvider<SessionController, SessionState>(
  SessionController.new,
);
