import 'dart:convert';
import 'dart:typed_data';

import 'experiment_mode.dart';
import 'vec2.dart';

/// Pixel dimensions of the JPEG frames we stream.
class FrameSize {
  const FrameSize(this.width, this.height);

  final int width;
  final int height;

  double get aspectRatio => width / height;

  Map<String, int> toJson() => {'w': width, 'h': height};

  @override
  bool operator ==(Object other) =>
      other is FrameSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

/// The `config` message from `docs/protocol.md`.
class SessionConfig {
  const SessionConfig({
    required this.mode,
    required this.massKg,
    required this.frameSize,
    this.pxPerM,
    this.targetPx,
  });

  final ExperimentMode mode;
  final double massKg;
  final FrameSize frameSize;

  /// Frame pixels per metre, from the ruler calibration. Null until calibrated.
  final double? pxPerM;

  /// Where the user tapped the object, in frame pixels. Null means auto-detect.
  final Vec2? targetPx;

  Map<String, dynamic> toJson() => {
        'type': 'config',
        'mode': mode.wireName,
        'mass_kg': massKg,
        'px_per_m': pxPerM,
        'target_px': targetPx?.toJson(),
        'frame_size': frameSize.toJson(),
      };

  String encode() => jsonEncode(toJson());
}

/// One JPEG frame ready to send, produced by a `FrameSource`.
class EncodedFrame {
  const EncodedFrame({
    required this.jpeg,
    required this.size,
    required this.captureTime,
  });

  final Uint8List jpeg;
  final FrameSize size;

  /// Seconds on the phone's monotonic clock.
  final double captureTime;
}

/// Binary frame packet: 12-byte big-endian header + JPEG.
///
/// ```
/// offset 0  uint32  seq
/// offset 4  float64 capture time (s)
/// offset 12 bytes   JPEG
/// ```
abstract final class FramePacket {
  static const int headerLength = 12;

  static Uint8List encode(int seq, double captureTime, Uint8List jpeg) {
    final packet = Uint8List(headerLength + jpeg.length);
    ByteData.sublistView(packet)
      ..setUint32(0, seq, Endian.big)
      ..setFloat64(4, captureTime, Endian.big);
    packet.setRange(headerLength, packet.length, jpeg);
    return packet;
  }

  /// Splits a packet back into its parts (used by tests and the mock server).
  static ({int seq, double captureTime, Uint8List jpeg}) decode(
    Uint8List packet,
  ) {
    final header = ByteData.sublistView(packet, 0, headerLength);
    return (
      seq: header.getUint32(0, Endian.big),
      captureTime: header.getFloat64(4, Endian.big),
      jpeg: Uint8List.sublistView(packet, headerLength),
    );
  }
}
