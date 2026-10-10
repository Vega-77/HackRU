import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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

  void open() => _ready.complete();

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => server.stream;
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

  String reply(int seq) =>
      jsonEncode({'type': 'state', 'seq': seq, 't': 1.0, 'tracked': true});

  setUp(() async {
    now = Duration.zero;
    channel = _FakeChannel();
    socket = PhysicsSocket(
      'ws://test:8000/ws',
      connector: (_) => channel,
      clock: () => now,
    );
    socket.sendConfig(config);
    socket.connect();
    channel.open();
    await pumpEventQueue();
  });

  tearDown(() => socket.dispose());

  test('goes live and sends the config first', () {
    expect(socket.status, ConnectionStatus.live);
    expect(channel.sink.sent, hasLength(1));
    expect(jsonDecode(channel.sink.sent.first as String)['type'], 'config');
  });

  test('allows at most two frames in flight', () {
    expect(socket.sendFrame(frame), isTrue);
    expect(socket.sendFrame(frame), isTrue);
    expect(socket.sendFrame(frame), isFalse);
    expect(socket.framesInFlight, 2);

    final packet = channel.sink.sent[1] as Uint8List;
    expect(FramePacket.decode(packet).seq, 0);
  });

  test('a reply frees a slot and measures latency', () async {
    socket
      ..sendFrame(frame)
      ..sendFrame(frame);
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
      ..sendFrame(frame);
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

    expect((received[0] as StateMessage).state.seq, 5);
    expect((received[1] as ErrorMessage).message, 'lost the ball');
  });

  test('goes offline when the server closes the connection', () async {
    await channel.server.close();
    await pumpEventQueue();
    expect(socket.status, ConnectionStatus.offline);
    expect(socket.canSendFrame, isFalse);
  });
}
