import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/core/logging/debug_log.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';

class _FakeCamera implements FrameSource {
  EncodedFrame? liveFrame;
  int captures = 0;
  @override
  String get name => 'fake camera';

  @override
  bool isRunning = false;

  @override
  Future<void> start() async => isRunning = true;

  @override
  Future<void> stop() async => isRunning = false;

  @override
  FrameSize? get frameSize => isRunning ? const FrameSize(320, 240) : null;

  @override
  Future<EncodedFrame?> capture({int width = 320}) async {
    captures++;
    return liveFrame;
  }

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();
}

void main() {
  late _FakeCamera camera;
  late ProviderContainer container;

  setUp(() {
    camera = _FakeCamera();
    container = ProviderContainer(
      overrides: [frameSourceProvider.overrideWithValue(camera)],
    );
    addTearDown(container.dispose);
    // Nothing listens here, so the socket just fails to connect.
    container
        .read(experimentSettingsProvider.notifier)
        .setBackendUrl('ws://127.0.0.1:9/ws/frames');
  });

  SessionController session() => container.read(sessionProvider.notifier);

  test(
    'sends the selected image before live capture with its ROI and timestamp',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = <dynamic>[];
      WebSocket? peer;
      server.transform(WebSocketTransformer()).listen((ws) {
        peer = ws;
        ws.listen(received.add);
      });
      final frame = EncodedFrame(
        jpeg: Uint8List.fromList([1, 2, 3]),
        size: const FrameSize(320, 240),
        captureTime: .25,
      );
      container
          .read(calibrationProvider.notifier)
          .selectObject(
            const Vec2(80, 90),
            const PixelRect(64, 74, 32, 32),
            frame,
          );
      container
          .read(experimentSettingsProvider.notifier)
          .setBackendUrl('ws://127.0.0.1:${server.port}/ws/frames');
      await session().start();
      for (var i = 0; i < 50 && received.length < 3; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received, hasLength(3));
      expect(jsonDecode(received[0] as String)['target_bbox'], {
        'x': 64.0,
        'y': 74.0,
        'w': 32.0,
        'h': 32.0,
      });
      expect(jsonDecode(received[1] as String)['timestamp'], .25);
      expect(jsonDecode(received[1] as String)['type'], 'initialize');
      expect(received[2], [1, 2, 3]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        received,
        hasLength(3),
        reason: 'no live frames before the acknowledgement',
      );
      expect(camera.captures, 0);
      camera.liveFrame = EncodedFrame(
        jpeg: Uint8List.fromList([4, 5, 6]),
        size: frame.size,
        captureTime: .5,
      );
      peer!.add(
        jsonEncode({
          'type': 'initialization',
          'frame_id': 0,
          'status': 'initialized',
          'reason': 'initialized',
        }),
      );
      for (var i = 0; i < 50 && received.length < 6; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(received.length, greaterThanOrEqualTo(6));
      expect(received[4], [4, 5, 6]);
      await session().stop();
    },
  );

  test('in a collision initializes both objects before live frames', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final configs = <Map<String, dynamic>>[];
    final initialized = <String>[];
    var liveFrames = 0;
    server.transform(WebSocketTransformer()).listen((ws) {
      Map<String, dynamic>? meta;
      ws.listen((message) {
        if (message is String) {
          final data = jsonDecode(message) as Map<String, dynamic>;
          if (data['type'] == 'config') configs.add(data);
          meta = data;
        } else if (meta?['type'] == 'initialize') {
          initialized.add('${meta!['target'] ?? 'first'}');
          ws.add(
            jsonEncode({
              'type': 'initialization',
              'frame_id': meta!['frame_id'],
              'status': 'initialized',
              'reason': 'initialized',
            }),
          );
          meta = null;
        } else {
          liveFrames++;
        }
      });
    });
    EncodedFrame picture(int byte, double t) => EncodedFrame(
      jpeg: Uint8List.fromList([byte]),
      size: const FrameSize(320, 240),
      captureTime: t,
    );
    container
        .read(experimentSettingsProvider.notifier)
        .setMode(ExperimentMode.collision);
    container.read(calibrationProvider.notifier)
      ..selectObject(
        const Vec2(40, 120),
        const PixelRect(27, 107, 26, 26),
        picture(1, 1),
      )
      ..confirmSelection()
      ..selectObject(
        const Vec2(200, 120),
        const PixelRect(187, 107, 26, 26),
        picture(2, 2),
      )
      ..confirmSelection();
    camera.liveFrame = picture(3, 3);
    container
        .read(experimentSettingsProvider.notifier)
        .setBackendUrl('ws://127.0.0.1:${server.port}/ws/frames');
    await session().start();
    for (var i = 0; i < 100 && liveFrames == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(initialized, ['first', 'second']);
    expect(liveFrames, greaterThan(0));
    expect(configs.last['second_target_px'], {'x': 200.0, 'y': 120.0});
    expect(configs.last['second_target_bbox']['x'], 187.0);
    await session().stop();
  });

  test(
    'leaves the camera on for calibration when the experiment ends',
    () async {
      // Calibration opens the camera and stays mounted under the experiment.
      await camera.start();

      await session().start();
      await session().stop();

      expect(camera.isRunning, isTrue);
    },
  );

  test(
    'failed initialization stops capture and a new attempt can initialize',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var connections = 0;
      server.transform(WebSocketTransformer()).listen((ws) {
        final fails = ++connections == 1;
        Map<String, dynamic>? meta;
        ws.listen((message) {
          if (message is String) {
            final data = jsonDecode(message) as Map<String, dynamic>;
            if (data['type'] == 'initialize') meta = data;
          } else if (meta != null) {
            ws.add(
              jsonEncode({
                'type': 'initialization',
                'frame_id': meta!['frame_id'],
                'status': fails ? 'failed' : 'initialized',
                'reason': fails ? 'insufficient_contrast' : 'initialized',
              }),
            );
            meta = null;
          }
        });
      });
      container
          .read(calibrationProvider.notifier)
          .selectObject(
            const Vec2(80, 90),
            const PixelRect(64, 74, 32, 32),
            EncodedFrame(
              jpeg: Uint8List.fromList([1, 2, 3]),
              size: const FrameSize(320, 240),
              captureTime: 1,
            ),
          );
      container
          .read(experimentSettingsProvider.notifier)
          .setBackendUrl('ws://127.0.0.1:${server.port}/ws/frames');
      await session().start();
      for (
        var i = 0;
        i < 50 && container.read(sessionProvider).phase != SessionPhase.failed;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(container.read(sessionProvider).phase, SessionPhase.failed);
      expect(
        container.read(sessionProvider).serverError?.message,
        contains('retry selection'),
      );
      expect(camera.captures, 0);
      await session().stop();
      await session().start();
      for (var i = 0; i < 50 && camera.captures == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(container.read(sessionProvider).phase, SessionPhase.running);
      expect(camera.captures, greaterThan(0));
      expect(container.read(sessionProvider).serverError, isNull);
      await session().stop();
    },
  );

  test('releases the camera it opened itself', () async {
    await session().start();
    expect(camera.isRunning, isTrue);

    await session().stop();

    expect(camera.isRunning, isFalse);
  });

  test('counts the same backend error on frames in a row', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.transform(WebSocketTransformer()).listen((ws) {
      String error(String message) =>
          jsonEncode({'type': 'error', 'message': message});
      ws
        ..add(jsonEncode({'type': 'frame', 'frame_id': 0, 'process_ms': 4.2}))
        ..add(error('could not process frame: ValueError: x'))
        ..add(error('could not process frame: ValueError: x'))
        ..add(error('could not process frame: ValueError: x'))
        ..add(error('could not decode image bytes'));
    });
    container
        .read(experimentSettingsProvider.notifier)
        .setBackendUrl('ws://127.0.0.1:${server.port}/ws/frames');

    log.clear();
    final counts = <int>[];
    container.listen(
      sessionProvider.select((s) => s.serverErrorCount),
      (_, count) => counts.add(count),
    );
    await session().start();
    for (var i = 0; i < 50 && counts.length < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    expect(counts, [1, 2, 3, 1], reason: 'a different error starts again');
    expect(
      container.read(sessionProvider).serverError?.message,
      'could not decode image bytes',
    );
    await session().stop();

    final logged = log.entries.map((e) => e.message).join('\n');
    expect(logged, contains('======== Session 1: '));
    expect(logged, contains('Config (session start): {"type":"config"'));
    expect(logged, contains('Connected in '));
    expect(logged, contains('Frame 0 report: 4.2 ms on the backend'));
    expect(
      logged,
      contains('(3 in a row): could not process frame: ValueError: x'),
    );
    expect(logged, contains('frames sent, 1 replies, 4 errors'));
    expect(
      log.entries.firstWhere((e) => e.message.startsWith('Config')).caller,
      startsWith('SessionController._sendConfig (state/session_controller'),
    );
  });
}
