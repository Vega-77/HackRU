import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/widgets/overlay_frame.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec2.dart';

void main() {
  const target = OverlayFrame(
    pixel: Vec2(100, 100),
    markerRadius: 12,
    velocity: Vec2(1, 0),
    forces: {'gravity': Vec2(0, -1)},
    visibility: 1,
  );

  test('movedTo moves the object and keeps its vectors', () {
    final moved = target.movedTo(const Vec2(40, 50), 7);
    expect(moved.pixel, const Vec2(40, 50));
    expect(moved.markerRadius, 7);
    expect(moved.velocity, target.velocity);
    expect(moved.forces, target.forces);
    expect(moved.visibility, 1);
  });

  test('a support pushing out of the screen becomes support', () {
    const state = PhysicsState(
      frameId: 1,
      t: 0,
      tracked: true,
      pixel: Vec2(10, 10),
      forces: [
        ForceVector('gravity', Vec2(0, 0), z: -0.98),
        ForceVector('normal', Vec2(0, 0), z: 0.98),
      ],
    );
    expect(OverlayFrame.fromState(state).support, 0.98);
    final half = OverlayFrame.fromState(state)
        .approach(OverlayFrame.empty, vectorT: 0.5, positionT: 0.5);
    expect(half.support, closeTo(0.49, 1e-9));
  });

  group('OverlayFrame.approach', () {
    test('appears in place on first sighting', () {
      final next = OverlayFrame.empty.approach(
        target,
        vectorT: 0.2,
        positionT: 0.5,
      );
      expect(next.pixel!.x, 100);
      expect(next.pixel!.y, 100);
      expect(next.velocity.x, closeTo(0.2, 1e-9));
    });

    test('glides towards the target and settles on it', () {
      var frame = OverlayFrame.empty;
      var steps = 0;
      while (!frame.settledOn(target)) {
        frame = frame.approach(target, vectorT: 0.25, positionT: 0.5);
        steps++;
        expect(steps, lessThan(100), reason: 'never settled');
      }
      expect(steps, greaterThan(1));
    });

    test('fades out and shrinks vectors when tracking is lost', () {
      final lost = target.approach(
        OverlayFrame.empty,
        vectorT: 0.5,
        positionT: 0.5,
      );
      expect(lost.pixel!.x, 100, reason: 'the marker stays put');
      expect(lost.visibility, 0.5);
      expect(lost.velocity.x, closeTo(0.5, 1e-9));
      expect(lost.forces['gravity']!.y, closeTo(-0.5, 1e-9));
    });

    test('a force that disappears shrinks away instead of vanishing', () {
      final next = target.approach(
        const OverlayFrame(pixel: Vec2(100, 100), visibility: 1),
        vectorT: 0.5,
        positionT: 1,
      );
      expect(next.forces['gravity']!.y, closeTo(-0.5, 1e-9));
    });
  });
}
