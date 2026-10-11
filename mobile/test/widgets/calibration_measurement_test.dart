import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/core/theme/app_theme.dart';
import 'package:hands_on_physics/core/routing/router.dart';
import 'package:hands_on_physics/features/calibration/widgets/calibration_stage.dart';
import 'package:hands_on_physics/features/calibration/widgets/measurement_chrome.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/features/experiment/widgets/coordinate_mapper.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';

import '../../tool/calibration_review.dart' as fixture;

class _StartingSession extends SessionController {
  @override
  SessionState build() => const SessionState(phase: SessionPhase.starting);
}

void main() {
  Future<ProviderContainer> open(
    WidgetTester tester,
    Size size, {
    bool failure = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final camera = fixture.MeasurementCameraFixture(failFirst: failure);
    final container = ProviderContainer(
      overrides: [frameSourceProvider.overrideWithValue(camera)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          theme: AppTheme.dark(),
          routerConfig: buildAppRouter(initialLocation: Routes.calibrate),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return container;
  }

  Future<void> close(WidgetTester tester) async =>
      tester.pumpWidget(const SizedBox());
  for (final size in [
    const Size(1440, 1000),
    const Size(960, 800),
    const Size(390, 844),
    const Size(320, 568),
    const Size(844, 390),
  ]) {
    testWidgets(
      'measurement states fit $size without changing the chosen frame',
      (tester) async {
        final container = await open(tester, size);
        final camera = container.read(
          frameSourceProvider,
        ) as fixture.MeasurementCameraFixture;
        final controller = container.read(calibrationProvider.notifier);
        expect(find.text('No object selected'), findsWidgets);
        controller.beginAcquisition(const Vec2(160, 160), camera.frame);
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Finding boundary'), findsWidgets);
        controller.selectObject(
          const Vec2(160, 160),
          const PixelRect(134, 134, 52, 52),
          camera.frame,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Review selection'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text('Confirm object'),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Confirm object'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(container.read(calibrationProvider).selectionConfirmed, true);
        expect(
          container.read(calibrationProvider).selectionFrame,
          same(camera.frame),
        );
        expect(find.text('Region confirmed'), findsWidgets);
        await tester.scrollUntilVisible(
          find.text('Select again'),
          100,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Select again'));
        await tester.pump();
        expect(container.read(calibrationProvider).selectionFrame, isNull);
        controller.beginAcquisition(const Vec2(160, 160), camera.frame);
        controller.acquisitionFailed('Draw a box around the object, or retry.');
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Selection needs attention'), findsWidgets);
        expect(tester.takeException(), isNull);
        await close(tester);
      },
    );
  }
  testWidgets('ruler drag preserves scale and centimetre validation', (
    tester,
  ) async {
    final container = await open(tester, const Size(1440, 1000));
    final stage = find.byType(CalibrationStage);
    final bounds = tester.getRect(stage);
    final camera =
        container.read(frameSourceProvider) as fixture.MeasurementCameraFixture;
    final mapper = CoordinateMapper(
      frameSize: camera.frame.size,
      viewSize: bounds.size,
      fit: BoxFit.cover,
    );
    final before = container.read(calibrationProvider);
    final start = mapper.toScreen(before.rulerStart!);
    final dest = mapper.toScreen(const Vec2(64, 84));
    final gesture = await tester.startGesture(bounds.topLeft + start);
    // Preserve the existing grab offset once the pan threshold is crossed.
    await gesture.moveBy(const Offset(-20, 0));
    await tester.pump();
    await gesture.moveTo(bounds.topLeft + dest - const Offset(20, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    final after = container.read(calibrationProvider);
    expect(after.rulerStart!.x, closeTo(64, .001));
    expect(after.rulerStart!.y, closeTo(84, .001));
    expect(
      after.pxPerM,
      closeTo(
        after.rulerStart!.distanceTo(after.rulerEnd!) / after.rulerLengthM,
        1e-9,
      ),
    );
    await tester.enterText(find.byType(TextField), '12,5');
    await tester.pump();
    expect(container.read(calibrationProvider).rulerLengthM, .125);
    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    expect(container.read(calibrationProvider).rulerLengthM, .125);
    expect(find.text('Use 1 to 500 cm'), findsOneWidget);
    await close(tester);
  });
  testWidgets('camera failure can retry without leaving setup', (tester) async {
    await open(tester, const Size(390, 844), failure: true);
    expect(find.text('Camera unavailable'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CalibrationStage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets('mass controls preserve the existing increments', (tester) async {
    final container = await open(tester, const Size(390, 844));
    final initial = container.read(experimentSettingsProvider).massKg;
    await tester.scrollUntilVisible(
      find.byTooltip('Heavier'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('Heavier'));
    await tester.pump();
    expect(container.read(experimentSettingsProvider).massKg, initial + .01);
    await tester.tap(find.byTooltip('Lighter'));
    await tester.pump();
    expect(container.read(experimentSettingsProvider).massKg, initial);
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets('measurement panel remains readable with enlarged text', (
    tester,
  ) async {
    await open(tester, const Size(320, 568), textScale: 1.6);
    expect(
      MediaQuery.textScalerOf(tester.element(find.byType(CalibrationStage)))
          .scale(1),
      1.6,
    );
    await tester.scrollUntilVisible(
      find.byTooltip('Heavier'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byTooltip('Heavier'));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await close(tester);
  });
  testWidgets('initialization status reflects the actual session phase', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sessionProvider.overrideWith(_StartingSession.new)],
        child: const MaterialApp(
          home: Scaffold(
            body: CameraStatusStrip(
              frame: FrameSize(320, 240),
              unavailable: false,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Initializing experiment'), findsOneWidget);
    await close(tester);
  });
}
