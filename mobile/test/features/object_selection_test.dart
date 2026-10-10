import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hands_on_physics/features/calibration/widgets/calibration_stage.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';
import 'package:hands_on_physics/state/session_controller.dart';

class _Camera implements FrameSource {
  final frame = EncodedFrame(
    jpeg: img.encodeJpg(img.Image(width: 320, height: 180)),
    size: const FrameSize(320, 180),
    captureTime: 1,
  );
  @override
  String get name => 'selection test camera';
  @override
  bool get isRunning => true;
  @override
  FrameSize get frameSize => frame.size;
  @override
  Future<EncodedFrame> capture({int width = 320}) async => frame;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Widget buildPreview(BuildContext context) => const SizedBox();
}

void main() {
  testWidgets(
    'drawing a box preserves its frame and clear restores live view',
    (tester) async {
      final camera = _Camera();
      final container = ProviderContainer(
        overrides: [frameSourceProvider.overrideWithValue(camera)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 320,
                  height: 180,
                  child: CalibrationStage(
                    frameSize: FrameSize(320, 180),
                    fit: BoxFit.cover,
                    background: ColoredBox(color: Colors.black),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final stage = find.byType(CalibrationStage);
      final origin = tester.getTopLeft(stage);
      final gesture = await tester.startGesture(origin + const Offset(50, 40));
      await gesture.moveTo(origin + const Offset(70, 60));
      await tester.pump();
      await gesture.moveTo(origin + const Offset(120, 100));
      await gesture.up();
      await tester.pumpAndSettle();
      final calibration = container.read(calibrationProvider);
      expect(calibration.targetBbox, isNotNull);
      expect(calibration.targetBbox!.w, greaterThan(8));
      expect(calibration.selectionFrame, same(camera.frame));
      expect(find.byType(Image), findsOneWidget);
      container.read(calibrationProvider.notifier).clearTarget();
      await tester.pumpAndSettle();
      expect(container.read(calibrationProvider).selectionFrame, isNull);
      expect(container.read(calibrationProvider).targetBbox, isNull);
      expect(find.byType(Image), findsNothing);
      final gestureWidget = find.descendant(
        of: stage,
        matching: find.byType(GestureDetector),
      );
      Focus.of(tester.element(gestureWidget)).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      final before = container.read(calibrationProvider).targetBbox!;
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(container.read(calibrationProvider).targetBbox!.x, before.x + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.equal);
      await tester.pump();
      expect(container.read(calibrationProvider).targetBbox!.w, before.w + 2);
    },
  );
}
