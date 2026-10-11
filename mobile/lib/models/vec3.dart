import 'dart:math' as math;

/// A 3D vector in ARKit world space: metres (or SI units per metre), +y up
/// against gravity. The backend sends these as `{"x", "y", "z"}`.
///
/// Like [Vec2], kept free of Flutter imports.
class Vec3 {
  const Vec3(this.x, this.y, this.z);

  final double x;
  final double y;
  final double z;

  static const Vec3 zero = Vec3(0, 0, 0);

  double get length => math.sqrt(x * x + y * y + z * z);

  /// Unit vector in the same direction, or [zero] for a zero-length vector.
  Vec3 get normalized {
    final len = length;
    return len == 0 ? zero : Vec3(x / len, y / len, z / len);
  }

  Vec3 operator +(Vec3 other) => Vec3(x + other.x, y + other.y, z + other.z);
  Vec3 operator -(Vec3 other) => Vec3(x - other.x, y - other.y, z - other.z);
  Vec3 operator *(double scale) => Vec3(x * scale, y * scale, z * scale);

  /// Parses `{"x": .., "y": .., "z": ..}`. Returns null for anything else,
  /// so a missing or malformed field never crashes the stream.
  static Vec3? tryParse(Object? json) {
    if (json is! Map) return null;
    final x = json['x'];
    final y = json['y'];
    final z = json['z'];
    if (x is! num || y is! num || z is! num) return null;
    return Vec3(x.toDouble(), y.toDouble(), z.toDouble());
  }

  Map<String, double> toJson() => {'x': x, 'y': y, 'z': z};

  /// `[x, y, z]`, the form the native ARKit code reads.
  List<double> toList() => [x, y, z];

  @override
  bool operator ==(Object other) =>
      other is Vec3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'Vec3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, '
      '${z.toStringAsFixed(3)})';
}
