import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/network/acquisition_client.dart';

void main() {
  for (final succeeds in [true, false]) {
    test(
      'selection request binds tap and original image; proposal=$succeeds',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final received = <dynamic>[];
        server.transform(WebSocketTransformer()).listen((ws) {
          Map<String, dynamic>? metadata;
          ws.listen((message) {
            received.add(message);
            if (message is String) {
              metadata = jsonDecode(message) as Map<String, dynamic>;
            } else {
              ws.add(
                jsonEncode({
                  'type': 'acquisition',
                  'selection_id': metadata!['selection_id'],
                  'status': succeeds ? 'proposed' : 'manual_required',
                  'reason': succeeds
                      ? 'stable_seeded_region'
                      : 'no_clear_boundary',
                  'bbox': succeeds
                      ? {'x': 64, 'y': 74, 'w': 32, 'h': 32}
                      : null,
                }),
              );
            }
          });
        });
        final frame = EncodedFrame(
          jpeg: Uint8List.fromList([1, 2, 3]),
          size: const FrameSize(320, 180),
          captureTime: 12.5,
        );
        final proposal = await AcquisitionClient().propose(
          'ws://127.0.0.1:${server.port}/ws/frames',
          const Vec2(80, 90),
          frame,
        );
        final metadata = jsonDecode(received.first as String);
        expect(metadata['type'], 'acquire');
        expect(metadata['target_px'], {'x': 80.0, 'y': 90.0});
        expect(metadata['timestamp'], 12.5);
        expect(received.last, [1, 2, 3]);
        expect(
          proposal.box?.toJson(),
          succeeds ? {'x': 64.0, 'y': 74.0, 'w': 32.0, 'h': 32.0} : null,
        );
        expect(
          proposal.reason,
          succeeds ? 'stable_seeded_region' : 'no_clear_boundary',
        );
      },
    );
  }
}
