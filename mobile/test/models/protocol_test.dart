import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/calibration.dart';
import 'package:hands_on_physics/models/camera_pose.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/models/vec3.dart';

/// These tests pin the wire format described in docs/protocol.md.
/// If one fails after a protocol change, update the doc and Dev 4 too.
void main() {
  group('ServerMessage.parse', () {
    test('reads the second collision object with its velocity', () {
      final message = ServerMessage.parse(
        jsonEncode({
          'type': 'state',
          'frame_id': 3,
          'timestamp': .2,
          'tracked': true,
          'pixel': {'x': 40, 'y': 120},
          'objects': [
            {
              'id': 1,
              'label': 'selected',
              'target': true,
              'pixel': {'x': 40, 'y': 120},
            },
            {
              'id': 2,
              'label': 'selected_2',
              'target': false,
              'pixel': {'x': 200, 'y': 121},
              'bbox': {'x': 187, 'y': 108, 'w': 26, 'h': 26},
            },
          ],
          'collision_objects': [
            {
              'id': 2,
              'velocity': {'x': .3, 'y': 0},
            },
          ],
        }),
      );
      final partner = (message as StateMessage).state.partner!;
      expect(partner.pixel, const Vec2(200, 121));
      expect(partner.bbox?.w, 26);
      expect(partner.velocity, const Vec2(.3, 0));
      expect(partner.tracked, isTrue);
    });

    test('has no partner without a second selected object', () {
      final message = ServerMessage.parse(
        jsonEncode({
          'type': 'frame',
          'frame_id': 3,
          'objects': [
            {
              'id': 1,
              'label': 'selected',
              'target': true,
              'pixel': {'x': 40, 'y': 120},
            },
          ],
        }),
      );
      expect((message as FrameAckMessage).target?.partner, isNull);
    });

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

    test('a contact force keeps its out-of-plane part', () {
      final message = ServerMessage.parse(
        jsonEncode({
          'type': 'state',
          'tracked': true,
          'forces': [
            {'name': 'normal', 'x': 0, 'y': 0, 'z': 0.98},
            {'name': 'normal_contact', 'x': -0.2, 'y': 0},
          ],
        }),
      );
      final forces = (message as StateMessage).state.forces;
      expect(forces.first.z, 0.98);
      expect(forces.first.isNormal, isTrue);
      expect(forces.last.z, 0);
      expect(forces.last.isNormal, isTrue);
      expect(forces.first.toJson()['z'], 0.98);
      expect(forces.last.toJson().containsKey('z'), isFalse);
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

    test('a crashed frame says where the backend failed', () {
      final message = ServerMessage.parse(
        '{"type":"error","message":"could not process frame: ValueError: x",'
        '"frame_id":4,"error":{"kind":"ValueError","detail":"x",'
        '"where":"backend/cv_engine/universal.py:69 in detect",'
        '"server":"209bcec"}}',
      );
      final error = message as ErrorMessage;
      expect(error.frameId, 4);
      expect(error.where, 'backend/cv_engine/universal.py:69 in detect');
      expect(error.serverVersion, '209bcec');
    });

    test('a malformed error object is ignored', () {
      final message = ServerMessage.parse(
        '{"type":"error","message":"oops","error":"not an object"}',
      );
      expect((message as ErrorMessage).where, isNull);
      expect(message.serverVersion, isNull);
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
    test('sends the second collision object', () {
      final json = SessionConfig(
        mode: ExperimentMode.collision,
        massKg: .1,
        frameSize: const FrameSize(320, 240),
        targetPx: const Vec2(40, 120),
        secondTargetPx: const Vec2(200, 120),
        secondTargetBbox: const PixelRect(187, 107, 26, 26),
      ).toJson();
      expect(json['second_target_px'], {'x': 200.0, 'y': 120.0});
      expect(json['second_target_bbox'], {
        'x': 187.0,
        'y': 107.0,
        'w': 26.0,
        'h': 26.0,
      });
    });

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
        'target_bbox': null,
        'second_target_px': null,
        'second_target_bbox': null,
        'frame_size': {'w': 320, 'h': 240},
        'ar_plane': null,
      });
    });

    test('sends the planes ARKit found, with the AR surface only', () {
      const floor = ArSurface(
        point: [0, -0.5, -1],
        normal: [0, 1, 0],
        id: 'floor',
      );
      const board = ArSurface(point: [0, 0, -1], normal: [0, 0, 1]);
      final json = const SessionConfig(
        mode: ExperimentMode.ramp,
        massKg: 0.1,
        frameSize: FrameSize(320, 240),
        surface: board,
        arSurfaces: [floor],
      ).toJson();
      expect(json['ar_surfaces'], [
        {
          'id': 'floor',
          'point': [0, -0.5, -1],
          'normal': [0, 1, 0],
        },
      ]);
      const none = SessionConfig(
        mode: ExperimentMode.ramp,
        massKg: 0.1,
        frameSize: FrameSize(320, 240),
      );
      expect(none.toJson().containsKey('ar_surfaces'), isFalse);
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
      expect(json.containsKey('target_bbox'), isTrue);
      expect(json['target_bbox'], isNull);
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

  group('ARKit pose', () {
    const pose = CameraPose(
      fx: 250,
      fy: 250,
      cx: 160,
      cy: 213.5,
      cameraToWorld: [1, 0, 0, 0.1, 0, 1, 0, 0.2, 0, 0, 1, 0.8, 0, 0, 0, 1],
    );

    test('frame metadata carries intrinsics and the camera transform', () {
      final json = jsonDecode(
        const FrameMetadata(frameId: 3, timestamp: 1.5, pose: pose).encode(),
      ) as Map<String, dynamic>;
      expect(json['frame_id'], 3);
      expect(json['intrinsics'], {
        'fx': 250.0,
        'fy': 250.0,
        'cx': 160.0,
        'cy': 213.5,
      });
      expect(json['camera_to_world'], hasLength(16));
      expect(json['camera_to_world'][3], 0.1);
    });

    test('frame metadata without a pose stays as before', () {
      final json = jsonDecode(
        const FrameMetadata(frameId: 3, timestamp: 1.5).encode(),
      );
      expect(json, {'frame_id': 3, 'timestamp': 1.5});
    });

    test('pose parses from the platform channel', () {
      final parsed = CameraPose.fromMap({
        'intrinsics': [250, 251, 160, 213.5],
        'camera_to_world': pose.cameraToWorld,
      });
      expect(parsed.fy, 251);
      expect(parsed.cameraToWorld[11], 0.8);
    });

    test('config sends the surface as ar_plane', () {
      const surface = ArSurface(
        point: [0, 0, -1],
        normal: [0, 0, 1],
        vertical: true,
      );
      final config = SessionConfig(
        mode: ExperimentMode.ramp,
        massKg: 0.1,
        frameSize: const FrameSize(320, 427),
        surface: surface.withOffset(0.02),
      );
      expect(config.toJson()['ar_plane'], {
        'point': [0.0, 0.0, -1.0],
        'normal': [0.0, 0.0, 1.0],
        'offset_m': 0.02,
      });
    });

    test('a calibration with a surface is metric without a ruler', () {
      const calibration = Calibration(
        surface: ArSurface(point: [0, 0, 0], normal: [0, 1, 0]),
      );
      expect(calibration.hasScale, isFalse);
      expect(calibration.isMetric, isTrue);
      expect(calibration.clearTarget().surface, isNotNull);
      expect(calibration.clearSurface().surface, isNull);
    });

    test('state and frame reports parse screen axes', () {
      final state = (ServerMessage.parse('''
            {"type": "state", "frame_id": 1, "timestamp": 0.1, "tracked": true,
             "pixel": {"x": 10, "y": 20},
             "screen_axes": {"x": {"x": 250, "y": 3}, "y": {"x": -2, "y": -248}}}
          ''') as StateMessage).state;
      expect(state.screenAxes!.x, const Vec2(250, 3));
      expect(state.screenAxes!.project(const Vec2(0, 1)), const Vec2(-2, -248));

      final ack = ServerMessage.parse('''
            {"type": "frame", "frame_id": 2, "timestamp": 0.2, "tracked": true,
             "objects": [{"id": 1, "target": true, "pixel": {"x": 5, "y": 6},
               "screen_axes": {"x": {"x": 1, "y": 0}, "y": {"x": 0, "y": -1}}}]}
          ''') as FrameAckMessage;
      expect(ack.target!.screenAxes, isNotNull);
    });
  });

  group('3D vectors', () {
    test('a state message parses the ARKit world fields', () {
      final state = (ServerMessage.parse('''
            {"type": "state", "frame_id": 4, "timestamp": 0.4, "tracked": true,
             "pixel": {"x": 10, "y": 20},
             "position_3d": {"x": 0.12, "y": 0.8, "z": -0.45},
             "velocity_3d": {"x": 0.5, "y": 0, "z": -0.1},
             "acceleration_3d": {"x": 0, "y": -9.81, "z": 0},
             "forces_3d": [
               {"name": "gravity", "x": 0, "y": -0.981, "z": 0},
               {"name": "bad", "x": 1},
               {"x": 1, "y": 2, "z": 3}
             ]}
          ''') as StateMessage).state;
      expect(state.position3d, const Vec3(0.12, 0.8, -0.45));
      expect(state.velocity3d, const Vec3(0.5, 0, -0.1));
      expect(state.acceleration3d!.y, -9.81);
      expect(state.forces3d, hasLength(1), reason: 'malformed forces drop');
      expect(state.forces3d.single.name, 'gravity');
      expect(state.forces3d.single.vector, const Vec3(0, -0.981, 0));
    });

    test('without an ar_plane the 3D fields are absent', () {
      final state = (ServerMessage.parse(
        '{"type": "state", "frame_id": 1, "timestamp": 0, "tracked": true}',
      ) as StateMessage).state;
      expect(state.position3d, isNull);
      expect(state.velocity3d, isNull);
      expect(state.forces3d, isEmpty);
      expect(state.toJson().keys, isNot(contains('position_3d')));
    });

    test('3D fields round-trip through toJson', () {
      const state = PhysicsState(
        frameId: 2,
        t: 0.2,
        tracked: true,
        position3d: Vec3(1, 2, 3),
        velocity3d: Vec3(0, 1, 0),
        acceleration3d: Vec3(0, 0, -1),
        forces3d: [ForceVector3('normal', Vec3(0, 0.5, 0))],
      );
      final back = PhysicsState.fromJson(
        jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
      );
      expect(back.position3d, state.position3d);
      expect(back.velocity3d, state.velocity3d);
      expect(back.acceleration3d, state.acceleration3d);
      expect(back.forces3d.single.name, 'normal');
      expect(back.forces3d.single.vector, const Vec3(0, 0.5, 0));
    });

    test('a frame report carries the target position in 3D', () {
      final ack = ServerMessage.parse('''
            {"type": "frame", "frame_id": 5, "timestamp": 0.5, "tracked": true,
             "objects": [{"id": 1, "target": true, "pixel": {"x": 5, "y": 6},
               "position_3d": {"x": 0.1, "y": 0.2, "z": 0.3}}]}
          ''') as FrameAckMessage;
      expect(ack.target!.position3d, const Vec3(0.1, 0.2, 0.3));
    });
  });
}
