import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/network/mock_physics_stream.dart';

/// The mock is what judges see in demo mode, so it must obey physics.
void main() {
  const frame = FrameSize(320, 240);

  double totalEnergy(ExperimentMode mode, double t) =>
      MockPhysics.sample(mode, t, frameSize: frame).energy!.total;

  for (final mode in ExperimentMode.values) {
    test('${mode.label}: energy is conserved (including thermal)', () {
      final reference = totalEnergy(mode, 0.01);
      for (var t = 0.02; t < 1.0; t += 0.07) {
        final state = MockPhysics.sample(mode, t, frameSize: frame);
        // Skip the brief contact in a collision: elastic energy is stored
        // in the bumper then, which we don't model.
        if (state.forces.any((f) => f.name == 'normal') &&
            mode == ExperimentMode.collision) {
          continue;
        }
        // Collisions hand energy to the parked cart, so only check before.
        if (mode == ExperimentMode.collision && state.velocity!.x < 0) break;
        expect(
          totalEnergy(mode, t),
          closeTo(reference, reference * 0.02),
          reason: 't = $t',
        );
      }
    });

    test('${mode.label}: net force equals m·a', () {
      final state = MockPhysics.sample(mode, 0.3, frameSize: frame, massKg: 0.2);
      final net = state.forces.firstWhere((f) => f.name == 'net').vector;
      expect(net.x, closeTo(state.acceleration!.x * 0.2, 1e-9));
      expect(net.y, closeTo(state.acceleration!.y * 0.2, 1e-9));
    });

    test('${mode.label}: object stays inside the frame', () {
      for (var t = 0.0; t < 6; t += 0.05) {
        final p = MockPhysics.sample(mode, t, frameSize: frame).pixel!;
        expect(p.x, inInclusiveRange(0, frame.width), reason: 't = $t');
        expect(p.y, inInclusiveRange(0, frame.height), reason: 't = $t');
      }
    });
  }

  test('free fall accelerates at g, straight down', () {
    final a = MockPhysics.sample(ExperimentMode.freeFall, 0.2).acceleration!;
    expect(a.x, 0);
    expect(a.y, closeTo(-9.81, 1e-9));
  });
}
