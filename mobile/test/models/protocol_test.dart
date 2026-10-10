import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/calibration.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';

/// These tests pin the wire format described in docs/protocol.md.
/// If one fails after a protocol change, update the doc and Dev 4 too.
void main() {
  group('ServerMessage.parse', () {
    test('parses a full state message', () {
      const raw = '''
      {
        "type": "state", "frame_id": 42, "timestamp": 12.345, "tracked": true,
        "pixel": {"x": 161.0, "y": 118.5},
        "bbox": {"x": 150, "y": 108, "w": 22, "h": 21},
        "position": {"x": 0.21, "y": 0.35},
        "velocity": {"x": 0.84, "y": -0.42},
        "acceleration": {"x": 2.1, "y": -1.05},
        "forces": [
          {"name": "gravity", "x": 0.0, "y": -0.981},
          {"name": "net", "x": 0.21, "y": -0.105}
        ],
        "energy": {"kinetic": 0.044, "potential": 0.343, "thermal": 0.012},
        "extras": {"angle_deg": 26.6, "mu": 0.18}
      }''';

      final message = ServerMessage.parse(raw);
      expect(message, isA<StateMessage>());
      final state = (message as StateMessage).state;

      expect(state.frameId, 42);
      expect(state.t, closeTo(12.345, 1e-9));
      expect(state.tracked, isTrue);
      expect(state.pixel, const Vec2(161, 118.5));
      expect(state.bbox!.w, 22);
      expect(state.velocity, const Vec2(0.84, -0.42));
      expect(state.forces, hasLength(2));
      expect(state.forces.last.kind, ForceKind.net);
      expect(state.forces.first.kind, ForceKind.component);
      expect(state.energy!.total, closeTo(0.399, 1e-9));
      expect(state.extras['angle_deg'], 26.6);
    });

    test('an untracked frame with no vectors still parses', () {
      final message = ServerMessage.parse(
        '{"type":"state","frame_id":7,"timestamp":1.0,"tracked":false}',
      );
      final state = (message as StateMessage).state;
      expect(state.tracked, isFalse);
      expect(state.velocity, isNull);
      expect(state.forces, isEmpty);
      expect(state.energy, isNull);
    });

    test('malformed fields are dropped instead of throwing', () {
      final message = ServerMessage.parse(
        '{"type":"state","frame_id":1,"timestamp":0,"tracked":true,'
        '"velocity":{"x":"fast"},"forces":[{"x":1},{"name":"normal","x":0,"y":1}]}',
      );
      final state = (message as StateMessage).state;
      expect(state.velocity, isNull);
      expect(state.forces.single.name, 'normal');
    });

    test('error messages carry their text', () {
      final message = ServerMessage.parse(
        '{"type":"error","message":"No object found"}',
      );
      expect((message as ErrorMessage).message, 'No object found');
      expect(message.frameId, isNull);
    });

    test('a frame decode error names the frame', () {
      final message = ServerMessage.parse(
        '{"type":"error","message":"could not decode image bytes","frame_id":9}',
      );
      expect(message.frameId, 9);
    });

    test("parses the CV engine's frame report", () {
      // Shape taken from backend/app.py (Dev 2).
      const raw = '''
      {"type": "frame", "frame_id": 12, "timestamp": 1728575000.12,
       "size": [640, 360], "source_size": [960, 540], "scale": 0.66667,
       "objects": [], "process_ms": 4.4, "latency_ms": 4.6,
       "stats": {"received": 13, "dropped": 0, "processed": 13, "decode_errors": 0}}''';
      final message = ServerMessage.parse(raw);
      expect(message, isA<FrameAckMessage>());
      expect(message.frameId, 12);
      expect((message as FrameAckMessage).processMs, 4.4);
      expect(message.objects, isEmpty);
    });

    test('a frame report turns its target into a position-only state', () {
      // Object shape from Dev 2's backend/README.md.
      const raw = '''
      {"type": "frame", "frame_id": 7, "timestamp": 2.5, "tracked": true,
       "target_id": 1,
       "objects": [
         {"id": 2, "label": "blue", "target": false,
          "pixel": {"x": 10, "y": 10}, "bbox": {"x": 0, "y": 0, "w": 20, "h": 20}},
         {"id": 1, "label": "red", "target": true,
          "pixel": {"x": 160.5, "y": 120}, "bbox": {"x": 150, "y": 110, "w": 21, "h": 20},
          "position": {"x": 0.2, "y": 0.15}}
       ]}''';
      final message = ServerMessage.parse(raw) as FrameAckMessage;
      final target = message.target!;
      expect(target.frameId, 7);
      expect(target.t, 2.5);
      expect(target.tracked, isTrue);
      expect(target.pixel!.x, 160.5);
      expect(target.bbox!.w, 21);
      expect(target.position!.y, 0.15);
      expect(target.velocity, isNull, reason: 'CV knows place, not motion');
    });

    test('a frame report without a target has no state', () {
      const raw = '''
      {"type": "frame", "frame_id": 3, "tracked": false, "objects": [
        {"id": 2, "target": false, "pixel": {"x": 1, "y": 2}}]}''';
      expect((ServerMessage.parse(raw) as FrameAckMessage).target, isNull);
    });

    test('garbage becomes UnknownMessage', () {
      expect(ServerMessage.parse('not json'), isA<UnknownMessage>());
      expect(ServerMessage.parse('[1,2]'), isA<UnknownMessage>());
      expect(ServerMessage.parse('{"type":"hello"}'), isA<UnknownMessage>());
    });
  });

  group('SessionConfig', () {
    test('encodes the documented config message', () {
      const config = SessionConfig(
        mode: ExperimentMode.ramp,
        massKg: 0.1,
        frameSize: FrameSize(320, 240),
        pxPerM: 812.5,
        targetPx: Vec2(161, 118.5),
      );
      expect(jsonDecode(config.encode()), {
        'type': 'config',
        'mode': 'ramp',
        'mass_kg': 0.1,
        'px_per_m': 812.5,
        'target_px': {'x': 161.0, 'y': 118.5},
        'frame_size': {'w': 320, 'h': 240},
      });
    });

    test('uncalibrated fields are sent as null', () {
      const config = SessionConfig(
        mode: ExperimentMode.freeFall,
        massKg: 0.2,
        frameSize: FrameSize(320, 180),
      );
      final json = jsonDecode(config.encode()) as Map;
      expect(json['mode'], 'free_fall');
      expect(json.containsKey('px_per_m'), isTrue);
      expect(json['px_per_m'], isNull);
      expect(json['target_px'], isNull);
    });
  });

  group('FrameMetadata', () {
    test('encodes the text message sent before each JPEG', () {
      const meta = FrameMetadata(frameId: 258, timestamp: 3.5);
      expect(jsonDecode(meta.encode()), {'frame_id': 258, 'timestamp': 3.5});
    });
  });

  group('ExperimentMode', () {
    test('wire names round-trip', () {
      for (final mode in ExperimentMode.values) {
        expect(ExperimentMode.fromWire(mode.wireName), mode);
      }
    });
  });

  group('Calibration', () {
    test('pxPerM comes from ruler length', () {
      const calibration = Calibration(
        rulerStart: Vec2(10, 100),
        rulerEnd: Vec2(250, 100),
        rulerLengthM: 0.30,
      );
      expect(calibration.pxPerM, closeTo(800, 1e-9));
    });

    test('no scale until both ends are placed', () {
      expect(const Calibration(rulerStart: Vec2(0, 0)).pxPerM, isNull);
      expect(
        const Calibration(rulerStart: Vec2(5, 5), rulerEnd: Vec2(5, 5)).pxPerM,
        isNull,
      );
    });
  });
}
