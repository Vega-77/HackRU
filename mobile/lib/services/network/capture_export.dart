import 'dart:convert';
import 'dart:typed_data';

import '../../models/physics_state.dart';
import '../../models/session_config.dart';
import 'recorded_analysis.dart';

class CaptureExport {
  const CaptureExport(this.filename, this.bytes);
  final String filename;
  final Uint8List bytes;
}

/// A portable JPEG sequence, with capture times independent of analysis time.
CaptureExport exportCapture({
  required RecordedSequence sequence,
  required EncodedFrame selection,
  required SessionConfig config,
  required DateTime capturedAt,
  required Map<String, dynamic> ruler,
  required List<PhysicsState> observations,
  String? analysisError,
}) {
  Map<String, dynamic> image(EncodedFrame frame, int id) => {
    'frame_id': id,
    'timestamp': frame.captureTime,
    'frame_size': frame.size.toJson(),
    'jpeg_base64': base64Encode(frame.jpeg),
    'encode_ms': frame.encodeMs,
    'age_at_encoding_ms': frame.ageAtEncodingMs,
    ...?frame.pose?.toJson(),
  };
  final utc = capturedAt.toUtc();
  final document = {
    'format': 'hands-on-physics-capture',
    'version': 1,
    'captured_at_utc': utc.toIso8601String(),
    'timestamp_clock': 'client_monotonic_seconds',
    'pixel_coordinates': 'x_right_y_down',
    'world_coordinates': 'metres_y_up',
    'config': config.toJson(),
    'ruler': ruler,
    'selection': image(selection, 0),
    'capture': {
      'frame_count': sequence.frames.length,
      'duration_s':
          sequence.frames.last.captureTime - sequence.frames.first.captureTime,
      'fps': sequence.fps,
      'max_gap_ms': sequence.maxGapMs,
    },
    'frames': [
      for (var i = 0; i < sequence.frames.length; i++)
        image(sequence.frames[i], i + 1),
    ],
    'analysis': {
      'complete': observations.length == sequence.frames.length,
      'error': analysisError,
      'observations': [
        for (final s in observations)
          {
            ...s.toJson(),
            'tracking_status': s.trackingStatus,
            'tracking_debug': s.trackingDebug,
            'physics_quality': s.physicsQuality,
            'process_ms': s.processMs,
            'queue_ms': s.queueMs,
            'timing_ms': s.timingMs,
          },
      ],
    },
  };
  final stamp = utc.toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
  return CaptureExport(
    'HandsOnPhysics-$stamp.hop.json',
    Uint8List.fromList(utf8.encode(jsonEncode(document))),
  );
}
