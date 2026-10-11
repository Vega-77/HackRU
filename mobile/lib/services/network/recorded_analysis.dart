import 'dart:async';

import '../../core/config/app_config.dart';
import '../../models/physics_state.dart';
import '../../models/session_config.dart';
import '../camera/frame_source.dart';
import 'physics_socket.dart';

enum RecordingPhase { idle, recording, analyzing, complete, failed }

class RecordedSequence {
  RecordedSequence(List<EncodedFrame> frames)
    : frames = List.unmodifiable(frames);
  final List<EncodedFrame> frames;
  double get fps =>
      (frames.length - 1) /
      (frames.last.captureTime - frames.first.captureTime);
  double get maxGapMs {
    var maximum = 0.0;
    for (var i = 1; i < frames.length; i++) {
      final gap = (frames[i].captureTime - frames[i - 1].captureTime) * 1000;
      if (gap > maximum) maximum = gap;
    }
    return maximum;
  }
}

/// Captures first, sends later. No socket credit or reply gates this loop.
class SequenceRecorder {
  Future<RecordedSequence> collect(
    FrameSource camera, {
    Duration duration = const Duration(seconds: 3),
    bool Function()? cancelled,
    void Function(double)? progress,
  }) async {
    final clock = Stopwatch()..start();
    final frames = <EncodedFrame>[];
    var bytes = 0;
    while (clock.elapsed < duration) {
      if (cancelled?.call() == true || !camera.isRunning) {
        throw StateError('Recording cancelled.');
      }
      final frame = await camera.capture();
      if (frame != null &&
          frame.captureTime.isFinite &&
          (frames.isEmpty || frame.captureTime > frames.last.captureTime)) {
        bytes += frame.jpeg.length;
        if (bytes > 8 * 1024 * 1024 || frames.length >= 180) break;
        if (frames.isNotEmpty && frame.size != frames.first.size) {
          throw StateError('Camera resolution changed. Record again.');
        }
        frames.add(frame);
      }
      progress?.call(clock.elapsedMicroseconds / duration.inMicroseconds);
      await Future<void>.delayed(
        const Duration(microseconds: 1000000 ~/ AppConfig.captureFps),
      );
    }
    if (frames.length < 4 ||
        frames.last.captureTime - frames.first.captureTime < .12) {
      throw StateError(
        'Too few fresh camera frames. Check the camera and retry.',
      );
    }
    return RecordedSequence(frames);
  }
}

/// Uses the existing initialization and state protocol on an isolated socket.
/// One acknowledged image at a time prevents the live latest-frame slot from
/// dropping recorded samples. Arrival time never supplies physics time.
class RecordedAnalyzer {
  RecordedAnalyzer({PhysicsSocket Function(String)? socketFactory})
    : _factory = socketFactory ?? PhysicsSocket.new;
  final PhysicsSocket Function(String) _factory;
  PhysicsSocket? _socket;

  Future<List<PhysicsState>> analyze({
    required String url,
    required SessionConfig config,
    required EncodedFrame selection,
    required RecordedSequence sequence,
    void Function(double)? progress,
  }) async {
    final socket = _factory(url);
    _socket = socket;
    try {
      final connected = socket.statusChanges.firstWhere(
        (s) => s == ConnectionStatus.live,
      );
      socket
        ..sendConfig(config)
        ..connect();
      await connected.timeout(const Duration(seconds: 10));
      final initialization = await socket.initialize(selection);
      if (initialization.status != 'initialized') {
        throw StateError(
          'Recorded object initialization failed: ${initialization.reason}',
        );
      }
      final states = <PhysicsState>[];
      for (var i = 0; i < sequence.frames.length; i++) {
        final frame = sequence.frames[i];
        if (frame.captureTime <= selection.captureTime) {
          throw StateError('Recording must be newer than the selected image.');
        }
        final expected = (socket.lastFrameId ?? -1) + 1;
        final message = await _reply(socket, expected, frame);
        if (message case StateMessage(:final state)) {
          if ((state.t - frame.captureTime).abs() > .000001) {
            throw StateError('Backend did not preserve capture timestamps.');
          }
          states.add(state);
        } else {
          throw StateError(
            message is ErrorMessage
                ? message.message
                : 'Backend does not support physics analysis.',
          );
        }
        progress?.call((i + 1) / sequence.frames.length);
      }
      return states;
    } finally {
      await socket.dispose();
      if (identical(_socket, socket)) _socket = null;
    }
  }

  Future<ServerMessage> _reply(
    PhysicsSocket socket,
    int id,
    EncodedFrame frame,
  ) async {
    final pending = Completer<ServerMessage>();
    final messages = socket.messages.listen((message) {
      if (message.frameId == id && !pending.isCompleted) {
        pending.complete(message);
      }
    });
    final status = socket.statusChanges.listen((status) {
      if (status != ConnectionStatus.live && !pending.isCompleted) {
        pending.completeError(
          StateError('Analysis connection interrupted. Retry saved frames.'),
        );
      }
    });
    try {
      if (!socket.sendFrame(frame)) {
        throw StateError('Analysis connection interrupted. Retry analysis.');
      }
      return await pending.future.timeout(const Duration(seconds: 10));
    } finally {
      await messages.cancel();
      await status.cancel();
    }
  }

  void cancel() => _socket?.disconnect();
}
