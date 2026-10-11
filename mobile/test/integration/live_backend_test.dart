import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/network/physics_socket.dart';
import 'package:image/image.dart' as img;

/// Talks to a real, running backend. Skipped unless LIVE_BACKEND_URL is set:
///
///     cd backend && uvicorn app:app --port 8000
///     LIVE_BACKEND_URL=ws://localhost:8000/ws/frames flutter test test/integration
///
/// Against tool/mock_server.py, also set LIVE_BACKEND_MOCK=1: the mock
/// ignores the image, so the checks on what the backend saw are skipped.
void main() {
  final url = Platform.environment['LIVE_BACKEND_URL'];
  final mock = Platform.environment['LIVE_BACKEND_MOCK'] != null;

  // Both tests look at the same stream, so it only runs once.
  Future<_Run>? run;
  Future<_Run> streamed() => run ??= _streamBall(url!, handshake: !mock);

  test('streams real JPEGs and every reply is matched to a frame', () async {
    final r = await streamed();

    expect(r.sent, _frames, reason: 'flow control stalled');
    expect(r.replies, isNotEmpty);
    expect(r.replies.whereType<ErrorMessage>(), isEmpty);
    expect(r.replies.whereType<UnknownMessage>(), isEmpty);
    for (final reply in r.replies) {
      expect(reply.frameId, inInclusiveRange(0, r.sent - 1));
    }
    expect(r.latencyMs, isNotNull);
    // ignore: avoid_print
    print(
      '${r.replies.length} replies to ${r.sent} frames, '
      'latency ${r.latencyMs!.toStringAsFixed(1)} ms',
    );
  }, skip: url == null ? 'set LIVE_BACKEND_URL to run' : false);

  test(
    'finds the drawn ball and measures its velocity',
    () async {
      final r = await streamed();
      final states = [
        for (final reply in r.replies)
          if (reply case StateMessage(:final state)) state,
      ];
      // A backend with only the CV stage reports where the ball is in
      // `frame` messages instead.
      final located = [
        ...states.where((s) => s.pixel != null),
        for (final reply in r.replies)
          if (reply case FrameAckMessage(:final target?)) target,
      ];

      expect(located, isNotEmpty, reason: 'the red ball was never found');
      for (final state in located) {
        final drawnAt = _ballCentre(state.frameId);
        expect(state.pixel!.x, closeTo(drawnAt.x, 12));
        expect(state.pixel!.y, closeTo(drawnAt.y, 12));
        // World y points up, measured from the bottom of the frame.
        final height = (_size.height - drawnAt.y) / _pxPerM;
        expect(state.position?.y, closeTo(height, 12 / _pxPerM));
      }
      if (states.isEmpty) return;

      // The ball moves right at a steady speed, so once the backend has a
      // few samples its velocity should match what we drew.
      final moving = [for (final s in states) ?s.velocity];
      expect(moving, isNotEmpty, reason: 'no velocity was ever reported');
      final drawnSpeed = r.drawnSpeedPxPerS / _pxPerM;
      final settled = moving.skip(moving.length ~/ 2).toList();
      for (final v in settled) {
        expect(v.x, closeTo(drawnSpeed, drawnSpeed * 0.25));
        expect(v.y.abs(), lessThan(drawnSpeed * 0.25));
      }
      final withEnergy = states.where((s) => s.energy?.kinetic != null);
      expect(withEnergy, isNotEmpty, reason: 'no kinetic energy reported');
      // ignore: avoid_print
      print(
        '${located.length} replies located the ball, ${moving.length} with '
        'velocity; drew ${drawnSpeed.toStringAsFixed(3)} m/s, got '
        '${settled.last.x.toStringAsFixed(3)} m/s',
      );
    },
    skip: url == null
        ? 'set LIVE_BACKEND_URL to run'
        : mock
        ? 'the mock server ignores the image'
        : false,
  );
}

const _frames = 30;
const _size = FrameSize(320, 240);

/// A plausible ruler calibration: 30 cm across 270 px.
const _pxPerM = 900.0;

/// Roughly a phone camera's frame rate.
const _frameInterval = Duration(milliseconds: 33);

/// Where frame [i]'s ball is drawn: moving right along the middle.
Vec2 _ballCentre(int i) => Vec2(20.0 + i * 9, 120);

class _Run {
  _Run(this.replies, this.sent, this.latencyMs, this.drawnSpeedPxPerS);

  final List<ServerMessage> replies;
  final int sent;
  final double? latencyMs;

  /// Pixels per second, from the capture times the frames were sent with.
  final double drawnSpeedPxPerS;
}

Future<_Run> _streamBall(String url, {required bool handshake}) async {
  final socket = PhysicsSocket(url);
  final replies = <ServerMessage>[];
  final sub = socket.messages.listen(replies.add);
  try {
    socket
      ..sendConfig(
        SessionConfig(
          mode: ExperimentMode.ramp,
          massKg: 0.1,
          frameSize: _size,
          pxPerM: _pxPerM,
          targetPx: _ballCentre(0),
          initializationRequired: handshake,
        ),
      )
      ..connect();
    await socket.statusChanges
        .firstWhere((s) => s == ConnectionStatus.live)
        .timeout(const Duration(seconds: 5));

    final captureTimes = <double>[];
    if (handshake) {
      final ack = await socket.initialize(
        EncodedFrame(jpeg: _ballFrame(0), size: _size, captureTime: 0),
      );
      expect(ack.frameId, 0);
      expect(ack.status, 'initialized', reason: ack.reason);
      captureTimes.add(0);
    }
    final clock = Stopwatch()..start();
    while (captureTimes.length < _frames &&
        clock.elapsed < const Duration(seconds: 10)) {
      final i = captureTimes.length;
      final t = clock.elapsedMicroseconds / 1e6;
      final frame = EncodedFrame(
        jpeg: _ballFrame(i),
        size: _size,
        captureTime: t,
      );
      if (socket.sendFrame(frame)) {
        captureTimes.add(t);
        await Future<void>.delayed(_frameInterval);
      } else {
        // Two frames already in flight: wait for an answer.
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    final sent = captureTimes.length;
    final elapsed = sent > 1 ? captureTimes.last - captureTimes.first : 1;
    final travelled = _ballCentre(sent - 1).x - _ballCentre(0).x;
    return _Run(replies, sent, socket.latencyMs, travelled / elapsed);
  } finally {
    await sub.cancel();
    await socket.dispose();
  }
}

Uint8List _ballFrame(int i) {
  final image = img.Image(width: _size.width, height: _size.height)
    ..clear(img.ColorRgb8(90, 90, 90));
  final centre = _ballCentre(i);
  img.fillCircle(
    image,
    x: centre.x.round(),
    y: centre.y.round(),
    radius: 14,
    color: img.ColorRgb8(220, 30, 30),
  );
  return img.encodeJpg(image, quality: 70);
}
