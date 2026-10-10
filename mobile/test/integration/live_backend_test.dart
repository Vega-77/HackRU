import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/network/physics_socket.dart';
import 'package:image/image.dart' as img;

/// Talks to a real, running backend. Skipped unless LIVE_BACKEND_URL is set:
///
///     cd backend && uvicorn app:app --port 8000
///     LIVE_BACKEND_URL=ws://localhost:8000/ws/frames flutter test test/integration
void main() {
  final url = Platform.environment['LIVE_BACKEND_URL'];

  test('streams real JPEGs and every reply is matched to a frame', () async {
    const size = FrameSize(320, 240);
    final socket = PhysicsSocket(url!);
    final replies = <ServerMessage>[];
    final sub = socket.messages.listen(replies.add);
    addTearDown(() async {
      await sub.cancel();
      await socket.dispose();
    });

    socket
      ..sendConfig(
        const SessionConfig(
          mode: ExperimentMode.ramp,
          massKg: 0.1,
          frameSize: size,
        ),
      )
      ..connect();
    await socket.statusChanges
        .firstWhere((s) => s == ConnectionStatus.live)
        .timeout(const Duration(seconds: 5));

    // Push 30 frames of a red ball, as fast as flow control allows.
    final clock = Stopwatch()..start();
    var sent = 0;
    while (sent < 30 && clock.elapsed < const Duration(seconds: 10)) {
      final frame = EncodedFrame(
        jpeg: _ballFrame(size, sent),
        size: size,
        captureTime: clock.elapsedMicroseconds / 1e6,
      );
      if (socket.sendFrame(frame)) sent++;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(sent, 30, reason: 'flow control stalled');
    expect(replies, isNotEmpty);
    expect(replies.whereType<ErrorMessage>(), isEmpty);
    expect(replies.whereType<UnknownMessage>(), isEmpty);
    for (final reply in replies) {
      expect(reply.frameId, inInclusiveRange(0, sent - 1));
    }
    expect(socket.latencyMs, isNotNull);
    // ignore: avoid_print
    print(
      '${replies.length} replies to $sent frames, '
      'latency ${socket.latencyMs!.toStringAsFixed(1)} ms',
    );
  }, skip: url == null ? 'set LIVE_BACKEND_URL to run' : false);
}

Uint8List _ballFrame(FrameSize size, int i) {
  final image = img.Image(width: size.width, height: size.height)
    ..clear(img.ColorRgb8(90, 90, 90));
  img.fillCircle(
    image,
    x: 20 + i * 9,
    y: size.height ~/ 2,
    radius: 14,
    color: img.ColorRgb8(220, 30, 30),
  );
  return img.encodeJpg(image, quality: 70);
}
