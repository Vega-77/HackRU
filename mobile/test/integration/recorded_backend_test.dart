import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/network/recorded_analysis.dart';
import 'package:image/image.dart' as img;

EncodedFrame ball(double captureTime, double flightTime) {
  final y = 30 + 4.905 * 220 * flightTime * flightTime;
  final image = img.Image(width: 320, height: 240)
    ..clear(img.ColorRgb8(45, 45, 45));
  img.fillCircle(
    image,
    x: 140,
    y: y.round(),
    radius: 13,
    color: img.ColorRgb8(160, 160, 160),
  );
  img.fillCircle(
    image,
    x: 136,
    y: y.round() - 4,
    radius: 4,
    color: img.ColorRgb8(190, 190, 190),
  );
  return EncodedFrame(
    jpeg: img.encodeJpg(image, quality: 70),
    size: const FrameSize(320, 240),
    captureTime: captureTime,
  );
}

void main() {
  final urls = Platform.environment['RECORDED_BACKEND_URLS']?.split(',') ?? [];
  for (final url in urls.isEmpty ? ['unset'] : urls) {
    test('analyzes every saved gray-ball JPEG through $url', () async {
      final sequence = RecordedSequence([
        for (var i = 0; i < 25; i++) ball(3 + i / 60, i / 60),
      ]);
      final clock = Stopwatch()..start();
      final states = await RecordedAnalyzer().analyze(
        url: url,
        config: const SessionConfig(
          mode: ExperimentMode.freeFall,
          massKg: .1,
          frameSize: FrameSize(320, 240),
          pxPerM: 220,
          targetPx: Vec2(140, 30),
          targetBbox: PixelRect(124, 14, 32, 32),
          initializationRequired: true,
        ),
        selection: ball(1, 0),
        sequence: sequence,
      );
      expect(states.length, 25);
      for (var i = 0; i < 25; i++) {
        expect(states[i].t, closeTo(sequence.frames[i].captureTime, 1e-9));
        expect(states[i].tracked, isTrue);
        expect(states[i].pixel!.x, closeTo(140, 2));
        expect(
          states[i].pixel!.y,
          closeTo(30 + 4.905 * 220 * (i / 60) * (i / 60), 2),
        );
      }
      expect(states.last.velocity!.y, closeTo(-9.81 * .4, .15));
      expect(states.last.acceleration!.y, closeTo(-9.81, 1));
      final processing = states.map((s) => s.processMs!).toList()..sort();
      // ignore: avoid_print
      print(
        'RECORDED $url frames=${states.length}, capture_fps=${sequence.fps.toStringAsFixed(1)}, '
        'analysis_ms=${clock.elapsedMilliseconds}, process_median_ms=${processing[12]}, '
        'velocity_y=${states.last.velocity!.y}, acceleration_y=${states.last.acceleration!.y}',
      );
    }, skip: urls.isEmpty ? 'set RECORDED_BACKEND_URLS' : false);
  }
}
