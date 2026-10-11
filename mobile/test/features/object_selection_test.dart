import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hands_on_physics/features/calibration/widgets/calibration_stage.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';

class _Camera implements FrameSource {
  final frame = EncodedFrame(
    jpeg: img.encodeJpg(img.Image(width: 320, height: 180)),
    size: const FrameSize(320, 180),
    captureTime: 1,
  );

  /// False for a camera that is open but has not delivered a picture yet.
  bool hasPicture = true;
  @override
  String get name => 'selection test camera';
  @override
  bool get isRunning => true;
  @override
  FrameSize get frameSize => frame.size;
  @override
  Future<EncodedFrame?> capture({int width = 320}) async =>
      hasPicture ? frame : null;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
  @override
  Widget buildPreview(BuildContext context) => const SizedBox();
}

const _stage = MaterialApp(
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
);

/// The stage on its own, with [camera]. The held selection picture is the
/// only [Image] on it; without one it shows the live camera.
Future<ProviderContainer> _pumpStage(
  WidgetTester tester,
  _Camera camera, {
  void Function(ProviderContainer)? before,
}) async {
  final container = ProviderContainer(
    overrides: [frameSourceProvider.overrideWithValue(camera)],
  );
  addTearDown(container.dispose);
  before?.call(container);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: _stage),
  );
  return container;
}

Future<void> _drag(WidgetTester tester, Offset from, Offset to) async {
  final origin = tester.getTopLeft(find.byType(CalibrationStage));
  final gesture = await tester.startGesture(origin + from);
  await gesture.moveTo(origin + from + (to - from) / 2);
  await tester.pump();
  await gesture.moveTo(origin + to);
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a drag too small for a box goes back to the live camera', (
    tester,
  ) async {
    final container = await _pumpStage(tester, _Camera());
    // Past the touch slop, so it is a drag, then back near where it began.
    final origin = tester.getTopLeft(find.byType(CalibrationStage));
    final gesture = await tester.startGesture(origin + const Offset(50, 40));
    await gesture.moveTo(origin + const Offset(90, 40));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget, reason: 'held for drawing');
    await gesture.moveTo(origin + const Offset(53, 42));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(container.read(calibrationProvider).target, isNull);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('confirming the object goes back to the live camera', (
    tester,
  ) async {
    final container = await _pumpStage(tester, _Camera());
    await _drag(tester, const Offset(50, 40), const Offset(120, 100));
    expect(find.byType(Image), findsOneWidget, reason: 'held to confirm');
    container.read(calibrationProvider.notifier).confirmSelection();
    await tester.pumpAndSettle();
    expect(container.read(calibrationProvider).targetBbox, isNotNull);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('back from an experiment the stage shows the live camera', (
    tester,
  ) async {
    final camera = _Camera();
    await _pumpStage(
      tester,
      camera,
      before: (container) {
        container.read(calibrationProvider.notifier)
          ..selectObject(
            const Vec2(80, 60),
            const PixelRect(60, 40, 40, 40),
            camera.frame,
          )
          ..confirmSelection();
      },
    );
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a tap before the camera has a picture says so', (tester) async {
    final camera = _Camera()..hasPicture = false;
    final container = await _pumpStage(tester, camera);
    await tester.tap(find.byType(CalibrationStage));
    await tester.pumpAndSettle();
    expect(
      container.read(calibrationProvider).selectionError,
      contains('no picture yet'),
    );
    expect(find.byType(Image), findsNothing);
    await _drag(tester, const Offset(50, 40), const Offset(120, 100));
    expect(container.read(calibrationProvider).targetBbox, isNull);
    expect(find.byType(Image), findsNothing);
  });

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

  testWidgets('in a collision a second box marks the other object', (
    tester,
  ) async {
    final container = await _pumpStage(
      tester,
      _Camera(),
      before: (c) => c
          .read(experimentSettingsProvider.notifier)
          .setMode(ExperimentMode.collision),
    );
    final controller = container.read(calibrationProvider.notifier);
    await _drag(tester, const Offset(20, 40), const Offset(80, 100));
    controller.confirmSelection();
    await tester.pumpAndSettle();
    final first = container.read(calibrationProvider).targetBbox;
    expect(controller.choosingSecond, isTrue);

    await _drag(tester, const Offset(200, 40), const Offset(260, 100));
    var c = container.read(calibrationProvider);
    expect(c.targetBbox, first, reason: 'the first object stays marked');
    expect(c.second?.box?.x, greaterThan(first!.x + first.w));
    expect(c.pairConfirmed, isFalse);
    expect(find.byType(Image), findsOneWidget, reason: 'held to confirm');

    controller.confirmSelection();
    await tester.pumpAndSettle();
    c = container.read(calibrationProvider);
    expect(c.pairConfirmed, isTrue);
    expect(find.byType(Image), findsNothing);

    controller.clearSecond();
    c = container.read(calibrationProvider);
    expect(c.second, isNull);
    expect(c.selectionConfirmed, isTrue);
    controller.clearTarget();
    expect(container.read(calibrationProvider).target, isNull);
  });

  testWidgets('outside a collision a new box replaces the object', (
    tester,
  ) async {
    final container = await _pumpStage(tester, _Camera());
    final controller = container.read(calibrationProvider.notifier);
    await _drag(tester, const Offset(20, 40), const Offset(80, 100));
    controller.confirmSelection();
    await tester.pumpAndSettle();
    await _drag(tester, const Offset(200, 40), const Offset(260, 100));
    final c = container.read(calibrationProvider);
    expect(c.second, isNull);
    expect(c.targetBbox!.x, greaterThan(150));
  });
}
