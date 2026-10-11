import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../models/physics_state.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';

class AcquisitionProposal {
  const AcquisitionProposal(this.box, this.reason);
  final PixelRect? box;
  final String reason;
}

class AcquisitionClient {
  Future<AcquisitionProposal> propose(
    String url,
    Vec2 point,
    EncodedFrame frame,
  ) async {
    final channel = WebSocketChannel.connect(Uri.parse(url));
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    try {
      await channel.ready.timeout(const Duration(seconds: 10));
      final reply = channel.stream.first.timeout(const Duration(seconds: 15));
      channel.sink.add(
        jsonEncode({
          'type': 'acquire',
          'selection_id': id,
          'frame_id': 0,
          'timestamp': frame.captureTime,
          'target_px': point.toJson(),
        }),
      );
      channel.sink.add(frame.jpeg);
      final data = jsonDecode(await reply as String) as Map<String, dynamic>;
      if (data['type'] != 'acquisition' || data['selection_id'] != id) {
        throw const FormatException(
          'The backend did not acknowledge this selection',
        );
      }
      return AcquisitionProposal(
        data['status'] == 'proposed' ? PixelRect.tryParse(data['bbox']) : null,
        '${data['reason'] ?? 'no_clear_boundary'}',
      );
    } finally {
      // Closing a socket that never connected can wait forever, which would
      // leave setup stuck on finding the boundary. The reply is all we need.
      unawaited(channel.sink.close().catchError((Object _) => null));
    }
  }
}

final acquisitionClientProvider = Provider<AcquisitionClient>(
  (ref) => AcquisitionClient(),
);
