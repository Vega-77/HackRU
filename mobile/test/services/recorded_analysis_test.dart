import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/services/network/physics_socket.dart';
import 'package:hands_on_physics/services/network/recorded_analysis.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

EncodedFrame frame(double t) => EncodedFrame(
  jpeg: Uint8List.fromList([1, 2, 3]),
  size: const FrameSize(320, 240),
  captureTime: t,
);

class ReplySink extends Fake implements WebSocketSink {
  ReplySink(this.channel);
  final ReplyChannel channel;
  Map<String, dynamic>? metadata;
  @override
  void add(Object? data) {
    if (data is String) {
      final parsed = jsonDecode(data) as Map<String, dynamic>;
      if (parsed['type'] != 'config') metadata = parsed;
    } else {
      final m = metadata!;
      channel.sent.add(m);
      channel.outstanding++;
      channel.peak = channel.outstanding > channel.peak
          ? channel.outstanding
          : channel.peak;
      final t = (m['timestamp'] as num).toDouble();
      Timer(channel.delay, () {
        channel.outstanding--;
        channel.server.add(
          jsonEncode(
            m['type'] == 'initialize'
                ? {
                    'type': 'initialization',
                    'frame_id': m['frame_id'],
                    'status': 'initialized',
                  }
                : {
                    'type': 'state',
                    'frame_id': m['frame_id'],
                    'timestamp': t,
                    'tracked': true,
                    'pixel': {
                      'x': 140,
                      'y': 30 + 4.905 * 220 * (t - 3) * (t - 3),
                    },
                    'position': {
                      'x': 140 / 220,
                      'y': (240 - 30) / 220 - 4.905 * (t - 3) * (t - 3),
                    },
                  },
          ),
        );
      });
    }
  }

  @override
  Future<void> close([int? code, String? reason]) async {}
}

class ReplyChannel extends Fake implements WebSocketChannel {
  ReplyChannel(this.delay) {
    sink = ReplySink(this);
  }
  final Duration delay;
  final server = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  int outstanding = 0, peak = 0;
  @override
  late final ReplySink sink;
  @override
  Future<void> get ready async {}
  @override
  Stream<dynamic> get stream => server.stream;
  @override
  int? get closeCode => null;
  @override
  String? get closeReason => null;
}

class FreshCamera extends Fake implements FrameSource {
  var time = 1.0;
  bool duplicate = false;
  @override
  bool get isRunning => true;
  @override
  Future<EncodedFrame?> capture({int width = 320}) async =>
      frame(duplicate ? time : time += 1 / 60);
}

void main() {
  const config = SessionConfig(
    mode: ExperimentMode.freeFall,
    massKg: .1,
    frameSize: FrameSize(320, 240),
    pxPerM: 220,
    initializationRequired: true,
  );
  for (final ms in [50, 150, 300, 500]) {
    test('saved frames retain original time and order at $ms ms RTT', () async {
      final channel = ReplyChannel(Duration(milliseconds: ms));
      final analyzer = RecordedAnalyzer(
        socketFactory: (url) => PhysicsSocket(url, connector: (_) => channel),
      );
      final saved = RecordedSequence([
        for (var i = 0; i < 8; i++) frame(3 + i / 30),
      ]);
      final results = await analyzer.analyze(
        url: 'ws://test',
        config: config,
        selection: frame(1),
        sequence: saved,
      );
      expect(results, hasLength(8));
      expect(
        channel.peak,
        1,
        reason: 'no latest-frame overwrite of recorded samples',
      );
      for (var i = 0; i < 8; i++) {
        expect(results[i].t, saved.frames[i].captureTime);
        expect(
          results[i].position!.y,
          closeTo((240 - 30) / 220 - 4.905 * (i / 30) * (i / 30), 1e-8),
        );
      }
      expect(saved.fps, closeTo(30, 1e-6));
      await channel.server.close();
    });
  }
  test(
    'capture continues without any backend and keeps only fresh frames',
    () async {
      final camera = FreshCamera();
      final saved = await SequenceRecorder().collect(
        camera,
        duration: const Duration(milliseconds: 250),
      );
      expect(saved.frames.length, greaterThanOrEqualTo(4));
      expect(saved.fps, closeTo(60, .01));
      expect(saved.maxGapMs, closeTo(1000 / 60, .01));
    },
  );
  test(
    'frozen camera cannot create samples or a successful recording',
    () async {
      expect(
        SequenceRecorder().collect(
          FreshCamera()..duplicate = true,
          duration: const Duration(milliseconds: 150),
        ),
        throwsStateError,
      );
    },
  );
  test('cancelled capture returns no partial physics result', () async {
    expect(
      SequenceRecorder().collect(FreshCamera(), cancelled: () => true),
      throwsStateError,
    );
  });
}
