import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/state/telemetry_buffer.dart';

PhysicsState _at(double t, {bool tracked = true}) => PhysicsState(
      frameId: 0,
      t: t,
      tracked: tracked,
      position: tracked ? Vec2(t, 0) : null,
    );

void main() {
  test('keeps only the last window of samples', () {
    final buffer = TelemetryBuffer(window: const Duration(seconds: 2));
    for (var t = 0.0; t <= 5.0; t += 0.5) {
      buffer.add(_at(t));
    }
    expect(buffer.samples.first.t, 3.0);
    expect(buffer.latest!.t, 5.0);
  });

  test('skips untracked frames', () {
    final buffer = TelemetryBuffer()
      ..add(_at(0))
      ..add(_at(0.1, tracked: false))
      ..add(_at(0.2));
    expect(buffer.length, 2);
  });

  test('clears when time goes backwards', () {
    final buffer = TelemetryBuffer()
      ..add(_at(4))
      ..add(_at(5))
      ..add(_at(0.5));
    expect(buffer.length, 1);
    expect(buffer.latest!.t, 0.5);
  });
}
