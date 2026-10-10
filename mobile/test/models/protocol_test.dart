import 'dart:convert';
import 'dart:typed_data';

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
        "type": "state", "seq": 42, "t": 12.345, "tracked": true,
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

      expect(state.seq, 42);
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
        '{"type":"state","seq":7,"t":1.0,"tracked":false}',
      );
      final state = (message as StateMessage).state;
      expect(state.tracked, isFalse);
      expect(state.velocity, isNull);
      expect(state.forces, isEmpty);
      expect(state.energy, isNull);
    });

    test('malformed fields are dropped instead of throwing', () {
      final message = ServerMessage.parse(
        '{"type":"state","seq":1,"t":0,"tracked":true,'
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

  group('FramePacket', () {
    test('header is 12 bytes big-endian and round-trips', () {
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]);
      final packet = FramePacket.encode(258, 3.5, jpeg);

      expect(packet.length, 16);
      // seq = 258 = 0x00000102, big-endian.
      expect(packet.sublist(0, 4), [0, 0, 1, 2]);
      // 3.5 as a big-endian IEEE 754 double is 0x400C000000000000.
      expect(packet.sublist(4, 12), [0x40, 0x0C, 0, 0, 0, 0, 0, 0]);

      final decoded = FramePacket.decode(packet);
      expect(decoded.seq, 258);
      expect(decoded.captureTime, 3.5);
      expect(decoded.jpeg, jpeg);
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
