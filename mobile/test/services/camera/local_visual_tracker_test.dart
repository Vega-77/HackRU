import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/services/camera/local_visual_tracker.dart';
import 'package:image/image.dart' as img;

GrayFrame ball(
  double t,
  int x,
  int y, {
  int brightness = 0,
  bool absent = false,
  bool duplicate = false,
}) {
  final pixels = Uint8List(160 * 90);
  for (var py = 0; py < 90; py++) {
    for (var px = 0; px < 160; px++) {
      var value = 45;
      final distance = (px - x) * (px - x) + (py - y) * (py - y);
      if (!absent && distance <= 100) value = 155 + (px - x) * 3 - (py - y) * 2;
      if (duplicate &&
          (px - x - 25) * (px - x - 25) + (py - y) * (py - y) <= 100) {
        value = 155 + (px - x - 25) * 3 - (py - y) * 2;
      }
      pixels[py * 160 + px] = (value + brightness).clamp(0, 255);
    }
  }
  return GrayFrame(pixels, 160, 90, t);
}

void main() {
  for (final direction in ['stationary', 'horizontal', 'vertical']) {
    test(
      'local image matching follows $direction motion with original identity',
      () {
        final tracker = LocalVisualTracker();
        expect(
          tracker.anchor(ball(0, 40, 25), const PixelRect(30, 15, 20, 20)),
          isTrue,
        );
        for (var i = 1; i <= 8; i++) {
          final x = 40 + (direction == 'horizontal' ? i * 9 : 0);
          final y = 25 + (direction == 'vertical' ? i * 6 : 0);
          final estimate = tracker.update(
            ball(i / 30, x, y, brightness: i * 2),
          );
          expect(estimate, isNotNull);
          expect(estimate!.box.centre.x, closeTo(x, 1));
          expect(estimate.box.centre.y, closeTo(y, 1));
        }
      },
    );
  }
  test(
    'absence and long capture gap withhold estimates until server anchor',
    () {
      final tracker = LocalVisualTracker();
      tracker.anchor(ball(0, 40, 40), const PixelRect(30, 30, 20, 20));
      expect(tracker.update(ball(.033, 40, 40, absent: true)), isNull);
      expect(tracker.update(ball(.066, 44, 40)), isNull);
      expect(
        tracker.anchor(ball(.066, 44, 40), const PixelRect(34, 30, 20, 20)),
        isTrue,
      );
      expect(tracker.update(ball(.1, 50, 40)), isNotNull);
      expect(tracker.update(ball(.5, 55, 40)), isNull);
    },
  );
  test(
    'two similar nearby bodies are ambiguous rather than an identity switch',
    () {
      final tracker = LocalVisualTracker();
      tracker.anchor(ball(0, 40, 40), const PixelRect(30, 30, 20, 20));
      expect(tracker.update(ball(.066, 40, 40, duplicate: true)), isNull);
    },
  );
  test('recorded gray sphere can seed outline match, recorded shirt cannot reacquire it', () {
    GrayFrame read(String file, double t) {
      final image = img.copyResize(
        img.decodePng(
          File('../backend/tests/fixtures/gray_ball_oct11/$file')
              .readAsBytesSync(),
        )!,
        width: 160,
      );
      final bytes = Uint8List(image.width * image.height);
      for (final p in image) {
        bytes[p.y * image.width + p.x] = img.getLuminance(p).round();
      }
      return GrayFrame(bytes, image.width, image.height, t);
    }

    final tracker = LocalVisualTracker();
    final selected = read('22.13.png', 0);
    expect(
      tracker.anchor(selected, const PixelRect(94.5, 22.5, 18, 18)),
      isTrue,
    );
    final same = tracker.update(GrayFrame(selected.pixels, 160, 90, .033));
    expect(same, isNotNull);
    expect(same!.box.centre.x, closeTo(103.5, 1));
    expect(tracker.update(read('47.png', .066)), isNull);
  });
  test('irregular times never produce an extrapolated box', () {
    final tracker = LocalVisualTracker();
    tracker.anchor(ball(1, 40, 40), const PixelRect(30, 30, 20, 20));
    expect(tracker.update(ball(1, 90, 40)), isNull);
    expect(tracker.update(ball(.9, 90, 40)), isNull);
    final moved = tracker.update(ball(1.08, 56, 40));
    expect(moved!.box.centre.x, closeTo(56, 1));
  });
}
