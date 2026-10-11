import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/vec3.dart';

void main() {
  test('length and normalized', () {
    const v = Vec3(2, 3, 6);
    expect(v.length, 7);
    expect(v.normalized.length, closeTo(1, 1e-12));
    expect(Vec3.zero.normalized, Vec3.zero);
  });

  test('arithmetic', () {
    expect(const Vec3(1, 2, 3) + const Vec3(1, 1, 1), const Vec3(2, 3, 4));
    expect(const Vec3(1, 2, 3) - const Vec3(1, 1, 1), const Vec3(0, 1, 2));
    expect(const Vec3(1, 2, 3) * 2, const Vec3(2, 4, 6));
  });

  test('parses the wire shape and rejects anything else', () {
    expect(Vec3.tryParse({'x': 1, 'y': 2.5, 'z': -3}), const Vec3(1, 2.5, -3));
    expect(Vec3.tryParse({'x': 1, 'y': 2}), isNull);
    expect(Vec3.tryParse({'x': '1', 'y': 2, 'z': 3}), isNull);
    expect(Vec3.tryParse([1, 2, 3]), isNull);
    expect(Vec3.tryParse(null), isNull);
  });

  test('round-trips and lists for the native side', () {
    const v = Vec3(0.1, -0.2, 0.3);
    expect(Vec3.tryParse(v.toJson()), v);
    expect(v.toList(), [0.1, -0.2, 0.3]);
  });
}
