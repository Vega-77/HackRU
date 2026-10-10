import 'dart:math' as math;

/// A small immutable 2D vector used for every physical and pixel quantity
/// in the app.
///
/// Kept free of Flutter imports so models can be unit tested on the plain
/// Dart VM. Convert to an `Offset` at the UI edge.
class Vec2 {
  const Vec2(this.x, this.y);

  final double x;
  final double y;

  static const Vec2 zero = Vec2(0, 0);

  double get length => math.sqrt(x * x + y * y);

  /// Unit vector in the same direction, or [zero] for a zero-length vector.
  Vec2 get normalized {
    final len = length;
    return len == 0 ? zero : Vec2(x / len, y / len);
  }

  /// This vector rotated 90 degrees counter-clockwise (in a y-up frame).
  Vec2 get perpendicular => Vec2(-y, x);

  Vec2 operator +(Vec2 other) => Vec2(x + other.x, y + other.y);
  Vec2 operator -(Vec2 other) => Vec2(x - other.x, y - other.y);
  Vec2 operator *(double scale) => Vec2(x * scale, y * scale);
  Vec2 operator -() => Vec2(-x, -y);

  double dot(Vec2 other) => x * other.x + y * other.y;

  double distanceTo(Vec2 other) => (this - other).length;

  /// Linear interpolation: t = 0 gives [a], t = 1 gives [b].
  static Vec2 lerp(Vec2 a, Vec2 b, double t) =>
      Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);

  /// Parses `{"x": .., "y": ..}`. Returns null for anything else, so a
  /// missing or malformed field never crashes the stream.
  static Vec2? tryParse(Object? json) {
    if (json is! Map) return null;
    final x = json['x'];
    final y = json['y'];
    if (x is! num || y is! num) return null;
    return Vec2(x.toDouble(), y.toDouble());
  }

  Map<String, double> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)})';
}
