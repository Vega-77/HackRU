@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/camera/web_frame_source.dart';
import 'package:web/web.dart' as web;

// Real canvas/video/browser matching with simulated delayed server boxes.
// Server identity is supplied from the generated scene, not a real detector.
void main() {
  for (final rtt in [50, 150, 300, 500]) {
    test('browser estimates use current images at $rtt ms simulated RTT', () async {
      final canvas = web.HTMLCanvasElement()
        ..width = 320
        ..height = 180;
      final context = canvas.getContext('2d') as web.CanvasRenderingContext2D;
      var x = 60.0;
      var y = 70.0;
      void draw() {
        context
          ..fillStyle = '#303030'.toJS
          ..fillRect(0, 0, 320, 180);
        context
          ..fillStyle = '#a0a0a0'.toJS
          ..beginPath()
          ..arc(x, y, 14, 0, 6.2832)
          ..fill();
        context
          ..fillStyle = '#cccccc'.toJS
          ..beginPath()
          ..arc(x - 4, y - 4, 4, 0, 6.2832)
          ..fill();
      }

      draw();
      final stream = canvas.captureStream(30);
      final camera = WebFrameSource(openStream: () async => stream);
      final timers = <Timer>[];
      addTearDown(() async {
        for (final timer in timers) {
          timer.cancel();
        }
        await camera.stop();
      });
      await camera.start();
      camera.enableLocalEstimates(true);
      var estimates = 0;
      final ages = <double>[], costs = <double>[], errors = <double>[];
      camera.visualEstimate.addListener(() {
        final estimate = camera.visualEstimate.value;
        if (estimate == null) return;
        estimates++;
        ages.add(camera.localVisualStats['local_frame_age_ms']!.toDouble());
        costs.add(estimate.computeMs);
        errors.add(estimate.box.centre.distanceTo(Vec2(x, y)));
      });
      // First live observation is delayed too. It must anchor the exact cached
      // frame and replay intervening images, not paste a box onto today's image.
      Future<void> observe() async {
        final frame = await camera.capture();
        if (frame == null) return;
        final box = PixelRect(x - 14, y - 14, 28, 28);
        timers.add(
          Timer(Duration(milliseconds: rtt), () {
            camera.validateLocalEstimate(
              PhysicsState(
                frameId: 1,
                t: frame.captureTime,
                tracked: true,
                bbox: box,
              ),
            );
          }),
        );
      }

      await observe();
      var tick = 0;
      timers.add(
        Timer.periodic(const Duration(milliseconds: 33), (_) {
          tick++;
          x = 60 + tick * 1.3;
          y = 70 + tick * .35;
          draw();
          if (tick % 6 == 0) unawaited(observe());
        }),
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(estimates, greaterThan(20));
      ages.sort();
      costs.sort();
      errors.sort();
      expect(errors[errors.length ~/ 2], lessThan(6));
      expect(ages[ages.length ~/ 2], lessThan(100));
      // ignore: avoid_print
      print(
        'BROWSER rtt=$rtt count=$estimates '
        'age_median_ms=${ages[ages.length ~/ 2].toStringAsFixed(2)} '
        'match_p95_ms=${costs[(costs.length * .95).floor()].toStringAsFixed(2)} '
        'error_median_px=${errors[errors.length ~/ 2].toStringAsFixed(2)}',
      );
    });
  }
}
