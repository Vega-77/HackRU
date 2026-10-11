import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/core/logging/debug_log.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/network/physics_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class _FakeSink extends Fake implements WebSocketSink {
  final List<Object?> sent = [];

  @override
  void add(Object? data) => sent.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}
}

/// A channel we drive by hand: [server] pushes messages to the client.
class _FakeChannel extends Fake implements WebSocketChannel {
  final server = StreamController<dynamic>();
  final _ready = Completer<void>();
  @override
  final _FakeSink sink = _FakeSink();
  @override
  int? closeCode;
  @override
  String? closeReason;

  void open() => _ready.complete();

  void refuse() => _ready.completeError(const SocketRefused());

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => server.stream;
}

class SocketRefused implements Exception {
  const SocketRefused();
}

void main() {
  late _FakeChannel channel;
  late PhysicsSocket socket;
  var now = Duration.zero;

  const config = SessionConfig(
    mode: ExperimentMode.ramp,
    massKg: 0.1,
    frameSize: FrameSize(320, 240),
  );
  final frame = EncodedFrame(
    jpeg: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xD9]),
    size: const FrameSize(320, 240),
    captureTime: 1.0,
  );
  var captureTime = 1.0;
  EncodedFrame nextFrame({double age = 0}) => EncodedFrame(
    jpeg: frame.jpeg,
    size: frame.size,
    captureTime: captureTime += 1 / 30,
    ageAtEncodingMs: age,
  );

  String reply(int frameId) => jsonEncode({
    'type': 'state',
    'frame_id': frameId,
    'timestamp': 1.0 + frameId / 30,
    'tracked': true,
  });

  setUp(() async {
    now = Duration.zero;
    captureTime = 1.0;
    channel = _FakeChannel();
    socket = PhysicsSocket(
      'ws://test:8000/ws/frames',
      connector: (_) => channel,
      clock: () => now,
    );
    socket.sendConfig(config);
    socket.connect();
    channel.open();
    await pumpEventQueue();
  });

  tearDown(() => socket.dispose());

  test(
    'initialization blocks live frames until matching acknowledgement',
    () async {
      final pending = socket.initialize(frame);
      now = const Duration(seconds: 1);
      expect(socket.sendFrame(frame), isFalse);
      expect(
        jsonDecode(
          channel.sink.sent[channel.sink.sent.length - 2] as String,
        )['type'],
        'initialize',
      );
      channel.server.add(
        jsonEncode({
          'type': 'initialization',
          'frame_id': 99,
          'status': 'initialized',
        }),
      );
      await pumpEventQueue();
      expect(socket.canSendFrame, isFalse);
      channel.server.add(
        jsonEncode({
          'type': 'initialization',
          'frame_id': 0,
          'status': 'initialized',
          'reason': 'initialized',
        }),
      );
      expect((await pending).status, 'initialized');
      expect(
        socket.frameWindow,
        2,
        reason: 'initial segmentation must not inflate live RTT',
      );
      expect(
        socket.sendFrame(frame),
        isFalse,
        reason: 'selection is not a new observation',
      );
      expect(socket.sendFrame(nextFrame()), isTrue);
    },
  );

  test('failed initialization can retry on the same connection', () async {
    final pending = socket.initialize(frame);
    channel.server.add(
      jsonEncode({
        'type': 'initialization',
        'frame_id': 0,
        'status': 'failed',
        'reason': 'insufficient_contrast',
      }),
    );
    expect((await pending).status, 'failed');
    final retry = socket.initialize(frame);
    channel.server.add(
      jsonEncode({
        'type': 'initialization',
        'frame_id': 1,
        'status': 'initialized',
        'reason': 'initialized',
      }),
    );
    expect((await retry).status, 'initialized');
  });

  test('goes live and sends the config first', () {
    expect(socket.status, ConnectionStatus.live);
    expect(channel.sink.sent, hasLength(1));
    expect(jsonDecode(channel.sink.sent.first as String)['type'], 'config');
  });

  test('starts with two credits for distinct camera frames', () {
    expect(socket.sendFrame(frame), isTrue);
    expect(socket.sendFrame(nextFrame()), isTrue);
    expect(socket.sendFrame(nextFrame()), isFalse);
    expect(socket.framesInFlight, 2);
  });

  test('each frame is a metadata text followed by the JPEG bytes', () {
    socket.sendFrame(frame);
    final [_, meta, jpeg] = channel.sink.sent;
    expect(jsonDecode(meta as String), {'frame_id': 0, 'timestamp': 1.0});
    expect(jpeg, frame.jpeg);
  });

  test('a reply to a newer frame settles the older ones', () async {
    socket
      ..sendFrame(frame)
      ..sendFrame(nextFrame());
    channel.server.add(reply(1)); // the backend dropped frame 0
    await pumpEventQueue();
    expect(socket.framesInFlight, 0);
  });

  test('a CV frame report or a frame error also frees a slot', () async {
    socket
      ..sendFrame(frame)
      ..sendFrame(nextFrame());
    channel.server.add('{"type":"frame","frame_id":0,"objects":[]}');
    channel.server.add('{"type":"error","message":"bad jpeg","frame_id":1}');
    await pumpEventQueue();
    expect(socket.framesInFlight, 0);
  });

  test('a reply frees a slot and measures latency', () async {
    socket
      ..sendFrame(frame)
      ..sendFrame(nextFrame());
    now = const Duration(milliseconds: 40);
    channel.server.add(reply(0));
    await pumpEventQueue();

    expect(socket.framesInFlight, 1);
    expect(socket.canSendFrame, isTrue);
    expect(socket.latencyMs, closeTo(40, 1e-9));
  });

  test('frames with no reply expire after the timeout', () {
    socket
      ..sendFrame(frame)
      ..sendFrame(nextFrame());
    now = const Duration(milliseconds: 1100);
    expect(socket.framesInFlight, 0);
    expect(socket.canSendFrame, isTrue);
  });

  test('parsed messages are forwarded', () async {
    final received = <ServerMessage>[];
    final sub = socket.messages.listen(received.add);
    channel.server.add(reply(5));
    channel.server.add('{"type":"error","message":"lost the ball"}');
    await pumpEventQueue();
    await sub.cancel();

    expect((received[0] as StateMessage).state.frameId, 5);
    expect((received[1] as ErrorMessage).message, 'lost the ball');
  });

  test('rejects repeat captures and out-of-order states', () async {
    expect(socket.sendFrame(frame), isTrue);
    expect(socket.sendFrame(frame), isFalse);
    expect(socket.sendFrame(nextFrame()), isTrue);
    final delivered = <ServerMessage>[];
    final sub = socket.messages.listen(delivered.add);
    channel.server
      ..add(reply(1))
      ..add(reply(0))
      ..add(reply(1))
      ..add(jsonEncode({'type': 'state', 'frame_id': 2, 'timestamp': .5}));
    await pumpEventQueue();
    expect(delivered.map((m) => m.frameId), [1]);
    await sub.cancel();
  });

  test('600 ms RTT sustains capture cadence with bounded credits', () async {
    final due = <int, Duration>{};
    var steadySent = 0;
    var peak = 0;
    for (var tick = 0; tick < 180; tick++) {
      now = Duration(microseconds: tick * 33334);
      for (final id in due.keys.toList()) {
        if (due[id]! <= now) {
          channel.server.add(reply(id));
          due.remove(id);
        }
      }
      await Future<void>.delayed(Duration.zero);
      if (socket.sendFrame(nextFrame(age: 8))) {
        due[socket.lastFrameId!] = now + const Duration(milliseconds: 600);
        if (tick >= 60) steadySent++;
      }
      if (socket.framesInFlight > peak) peak = socket.framesInFlight;
    }
    // Two fixed credits allow at most 3.33 FPS at this RTT.
    expect(steadySent / 4, greaterThanOrEqualTo(28));
    expect(peak, lessThanOrEqualTo(20));
    expect(socket.frameWindow, 20);
    expect(socket.lastObservationAgeMs, closeTo(608, 1));
  });

  test(
    'a dropped-frame acknowledgement retires older credits without replay',
    () async {
      socket.sendFrame(frame);
      now = const Duration(milliseconds: 600);
      channel.server.add(reply(0));
      await pumpEventQueue();
      for (var i = 0; i < 10; i++) {
        expect(socket.sendFrame(nextFrame()), isTrue);
      }
      channel.server.add(reply(10));
      await pumpEventQueue();
      expect(socket.framesInFlight, 0);
      expect(socket.sendFrame(nextFrame()), isTrue);
    },
  );

  test('goes offline when the server closes the connection', () async {
    log.clear();
    channel
      ..closeCode = 1011
      ..closeReason = 'internal error';
    await channel.server.close();
    await pumpEventQueue();
    expect(socket.status, ConnectionStatus.offline);
    expect(socket.canSendFrame, isFalse);
    expect(
      log.entries.map((e) => e.message),
      contains(
        startsWith(
          'Connection closed (code 1011, reason "internal error") after ',
        ),
      ),
    );
  });

  group('probe', () {
    test('returns how long the connection took', () async {
      final probed = _FakeChannel()..open();
      Uri? asked;
      final time = await PhysicsSocket.probe(
        'ws://10.0.0.5:8000/ws/frames',
        connector: (uri) {
          asked = uri;
          return probed;
        },
      );
      expect(asked.toString(), 'ws://10.0.0.5:8000/ws/frames');
      expect(time, greaterThanOrEqualTo(Duration.zero));
    });

    test('fails when the backend refuses', () {
      final probed = _FakeChannel()..refuse();
      expect(
        PhysicsSocket.probe('ws://10.0.0.5:8000', connector: (_) => probed),
        throwsA(isA<SocketRefused>()),
      );
    });

    test('gives up after the timeout', () {
      expect(
        PhysicsSocket.probe(
          'ws://10.0.0.5:8000',
          timeout: const Duration(milliseconds: 20),
          connector: (_) => _FakeChannel(),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}
