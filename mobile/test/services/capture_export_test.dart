import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/network/capture_export.dart';
import 'package:hands_on_physics/services/network/recorded_analysis.dart';

void main() {
  test(
    'bundle preserves original frames, calibration and measured diagnostics',
    () {
      final jpeg = Uint8List.fromList([255, 216, 1, 2, 255, 217]);
      EncodedFrame frame(double t) => EncodedFrame(
        jpeg: jpeg,
        size: const FrameSize(320, 180),
        captureTime: t,
        encodeMs: 3.4,
      );
      const config = SessionConfig(
        mode: ExperimentMode.freeFall,
        massKg: .1,
        frameSize: FrameSize(320, 180),
        pxPerM: 304.9791856751825,
        targetPx: Vec2(226.94, 98.936),
        targetBbox: PixelRect(203, 76, 47, 44),
      );
      final sequence = RecordedSequence([frame(1867.6539), frame(1867.6899)]);
      final observations = [
        const PhysicsState(
          frameId: 1,
          t: 1867.6539,
          tracked: true,
          velocity: Vec2(.1, -.2),
          acceleration: Vec2(0, -2.939),
          bbox: PixelRect(211, 86, 26, 24),
          physicsQuality: {'acceleration_valid': true},
          trackingDebug: {'reason': 'detected'},
          processMs: 9.5,
          queueMs: .1,
          timingMs: {'tracking': 8.7},
        ),
        const PhysicsState(frameId: 2, t: 1867.6899, tracked: false),
      ];
      CaptureExport export(List<PhysicsState> states, {String? error}) =>
          exportCapture(
            sequence: sequence,
            selection: frame(1829.396),
            config: config,
            capturedAt: DateTime.utc(2026, 10, 11, 20, 5),
            ruler: {'length_m': .3},
            observations: states,
            analysisError: error,
          );
      final file = export(observations);
      final data = jsonDecode(utf8.decode(file.bytes)) as Map<String, dynamic>;
      expect(file.filename, 'HandsOnPhysics-2026-10-11T20-05-00-000Z.hop.json');
      expect(data['config'], config.toJson());
      expect(data['ruler'], {'length_m': .3});
      expect(data['selection']['timestamp'], 1829.396);
      expect(base64Decode(data['selection']['jpeg_base64']), jpeg);
      for (var i = 0; i < 2; i++) {
        expect(data['frames'][i]['frame_id'], i + 1);
        expect(data['frames'][i]['timestamp'], sequence.frames[i].captureTime);
        expect(base64Decode(data['frames'][i]['jpeg_base64']), jpeg);
      }
      final analysis = data['analysis'];
      expect(analysis['complete'], true);
      final row = analysis['observations'][0];
      expect(row['velocity'], {'x': .1, 'y': -.2});
      expect(row['acceleration'], {'x': 0.0, 'y': -2.939});
      expect(row['bbox'], {'x': 211.0, 'y': 86.0, 'w': 26.0, 'h': 24.0});
      expect(row['physics_quality'], {'acceleration_valid': true});
      expect(row['tracking_debug'], {'reason': 'detected'});
      expect(row['process_ms'], 9.5);
      expect(row['queue_ms'], .1);
      expect(row['timing_ms'], {'tracking': 8.7});
      expect(analysis['observations'][1]['tracked'], false);
      final partial = jsonDecode(
        utf8.decode(
          export(observations.take(1).toList(), error: 'connection lost').bytes,
        ),
      );
      expect(partial['analysis']['complete'], false);
      expect(partial['analysis']['error'], 'connection lost');
      expect(partial['frames'], hasLength(2));
    },
  );
}
