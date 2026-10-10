import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/widgets/coordinate_mapper.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';

void main() {
  const frame = FrameSize(320, 240);

  group('CoordinateMapper', () {
    test('cover fills a tall view and crops the sides', () {
      final mapper = CoordinateMapper(
        frameSize: frame,
        viewSize: const Size(300, 600),
      );
      expect(mapper.scale, 2.5); // 600 / 240
      expect(mapper.offset, const Offset(-250, 0)); // (300 - 800) / 2
      expect(mapper.toScreen(const Vec2(160, 120)), const Offset(150, 300));
    });

    test('contain shows the whole frame with bars', () {
      final mapper = CoordinateMapper(
        frameSize: frame,
        viewSize: const Size(300, 600),
        fit: BoxFit.contain,
      );
      expect(mapper.scale, closeTo(0.9375, 1e-9)); // 300 / 320
      expect(mapper.frameRect.left, 0);
      expect(mapper.frameRect.width, closeTo(300, 1e-9));
      expect(mapper.frameRect.center.dy, closeTo(300, 1e-9));
    });

    test('toFrame undoes toScreen', () {
      for (final fit in [BoxFit.cover, BoxFit.contain]) {
        final mapper = CoordinateMapper(
          frameSize: frame,
          viewSize: const Size(390, 520),
          fit: fit,
        );
        const p = Vec2(37, 201);
        final back = mapper.toFrame(mapper.toScreen(p));
        expect(back.x, closeTo(p.x, 1e-9));
        expect(back.y, closeTo(p.y, 1e-9));
      }
    });

    test('clampToVisible keeps points inside the cropped frame', () {
      final mapper = CoordinateMapper(
        frameSize: frame,
        viewSize: const Size(300, 600),
      );
      // The view shows frame x from 100 to 220 (300 px / 2.5).
      final p = mapper.clampToVisible(const Vec2(10, 500));
      expect(p.x, closeTo(100, 1e-9));
      expect(p.y, 240);
    });

    test('flips world y so up on the bench is up on screen', () {
      expect(
        CoordinateMapper.worldToScreenDirection(const Vec2(1, 2)),
        const Offset(1, -2),
      );
    });
  });

  group('screenDirection', () {
    test('without axes, world y up is screen y down', () {
      final d = CoordinateMapper.screenDirection(const Vec2(0, 2), null);
      expect(d.dx, closeTo(0, 1e-9));
      expect(d.dy, closeTo(-1, 1e-9));
    });

    test('follows the axes of a tilted surface', () {
      // A board turned away from the camera: world +x runs right and a
      // little up on screen, world +y straight up.
      const axes = ScreenAxes(Vec2(400, -100), Vec2(0, -300));
      final d = CoordinateMapper.screenDirection(const Vec2(1, 0), axes);
      expect(d.dx, closeTo(400 / 412.31, 1e-4));
      expect(d.dy, closeTo(-100 / 412.31, 1e-4));
      final up = CoordinateMapper.screenDirection(const Vec2(0, 1), axes);
      expect(up, const Offset(0, -1));
    });

    test('falls back when the axes squash the vector to nothing', () {
      const axes = ScreenAxes(Vec2.zero, Vec2.zero);
      final d = CoordinateMapper.screenDirection(const Vec2(1, 0), axes);
      expect(d, const Offset(1, 0));
    });
  });
}
