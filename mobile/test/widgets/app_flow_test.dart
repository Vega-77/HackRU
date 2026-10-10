import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/app.dart';
import 'package:hands_on_physics/core/config/app_config.dart';
import 'package:hands_on_physics/core/routing/router.dart';
import 'package:hands_on_physics/features/settings/backend_url.dart';
import 'package:hands_on_physics/models/camera_pose.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';

/// Counts how often the app tries to open the camera.
class _FakeCamera implements FrameSource {
  int starts = 0;
  int stops = 0;
  bool running = false;

  @override
  Future<void> start() async {
    if (running) return;
    starts++;
    running = true;
  }

  @override
  Future<void> stop() async {
    if (!running) return;
    stops++;
    running = false;
  }

  @override
  bool get isRunning => running;

  @override
  FrameSize? get frameSize => running ? const FrameSize(320, 240) : null;

  @override
  Future<EncodedFrame?> capture({int width = 320}) async => null;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();
}

/// An ARKit camera: knows its pose and finds a board wherever it looks.
class _FakeArCamera extends _FakeCamera implements SurfaceFinder {
  final List<Vec2> searches = [];

  @override
  bool get canFindSurfaces => running;

  @override
  Future<ArSurface?> findSurface(Vec2 framePixel) async {
    searches.add(framePixel);
    return const ArSurface(
      point: [0, 0, -1],
      normal: [0, 0, 1],
      vertical: true,
    );
  }
}

/// Smoke tests for the whole flow, at iPhone size, with a fake camera. They
/// catch layout overflows and crashes that unit tests can't see.
void main() {
  late _FakeCamera camera;

  setUp(() => camera = _FakeCamera());

  Future<ProviderContainer> pumpApp(
    WidgetTester tester, {
    String at = Routes.home,
  }) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          frameSourceProvider.overrideWithValue(camera),
          backendTestProvider.overrideWithValue(
            (url) async => const Duration(milliseconds: 12),
          ),
        ],
        child: HandsOnPhysicsApp(router: buildAppRouter(initialLocation: at)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
  }

  /// Unmounts the app so its tickers and timers stop before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  testWidgets('home lists every experiment and picks one', (tester) async {
    final container = await pumpApp(tester);

    expect(find.text('Choose an experiment'), findsOneWidget);
    // The list is lazy: scroll the row into existence first.
    await tester.scrollUntilVisible(
      find.text('Pendulum'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Pendulum'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(container.read(experimentSettingsProvider).mode.label, 'Pendulum');
    expect(find.text('Set up pendulum'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('flow runs from home to the experiment on the camera', (
    tester,
  ) async {
    final container = await pumpApp(tester);
    expect(find.textContaining('Live from'), findsOneWidget);

    await tester.tap(find.textContaining('Set up'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Start experiment'), findsOneWidget);
    expect(find.text('Set the scale'), findsOneWidget);
    expect(camera.isRunning, isTrue, reason: 'setup shows the camera');

    await tester.tap(find.text('Start experiment'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));

    expect(container.read(sessionProvider).phase, SessionPhase.running);
    expect(camera.starts, 1, reason: 'the experiment reuses the setup camera');

    await unmount(tester);
  });

  testWidgets('settings checks the backend address', (tester) async {
    final container = await pumpApp(tester, at: Routes.settings);

    expect(find.text('Backend address'), findsOneWidget);
    // The form tests the address after its first frame.
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Connected in 12 ms'),
      findsOneWidget,
      reason: 'opening settings checks the hosted backend straight away',
    );
    expect(find.text('Use the hosted backend'), findsNothing);

    await tester.enterText(find.byType(TextField), 'http://10.0.0.5:8000');
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Use ws:// or wss://, not http://'), findsOneWidget);
    expect(
      container.read(experimentSettingsProvider).backendUrl,
      isNot('http://10.0.0.5:8000'),
      reason: 'an invalid address is never saved',
    );

    await tester.enterText(find.byType(TextField), 'ws://10.0.0.5:8000/ws');
    await tester.pump(const Duration(seconds: 1));
    expect(
      container.read(experimentSettingsProvider).backendUrl,
      'ws://10.0.0.5:8000/ws',
    );

    await tester.tap(find.text('Use the hosted backend'));
    await tester.pump(const Duration(seconds: 1));
    expect(
      container.read(experimentSettingsProvider).backendUrl,
      AppConfig.defaultBackendUrl,
    );

    await unmount(tester);
  });

  testWidgets('camera stays on for setup after an experiment', (tester) async {
    final container = await pumpApp(tester);
    tester.view.physicalSize = const Size(600, 900) * 3;
    await tester.pump();

    await tester.tap(find.textContaining('Set up'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(camera.isRunning, isTrue);

    await tester.tap(find.text('Start experiment'));
    await tester.pump(const Duration(milliseconds: 600));
    expect(container.read(sessionProvider).phase, SessionPhase.running);
    expect(camera.isRunning, isTrue);

    container
        .read(experimentSettingsProvider.notifier)
        .setMode(ExperimentMode.freeFall);
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(experimentSettingsProvider).mode.label, 'Free fall');
    expect(camera.isRunning, isTrue);
    expect(camera.stops, 0);

    await tester.tap(find.byTooltip('Back'));
    await tester.pump(const Duration(milliseconds: 600));
    // Setup opened the camera, so the session leaves it running throughout.
    expect(camera.isRunning, isTrue);
    expect(camera.starts, 1);
    expect(camera.stops, 0);

    await unmount(tester);
  });

  testWidgets('with ARKit, setup finds the surface instead of a ruler', (
    tester,
  ) async {
    final ar = _FakeArCamera();
    camera = ar;
    final container = await pumpApp(tester);

    await tester.tap(find.textContaining('Set up'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(); // the camera's frame size arrives after start()
    expect(find.text('Find the surface'), findsOneWidget);
    expect(find.text('No surface yet'), findsOneWidget);

    await tester.tap(find.text('Find'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(ar.searches, [const Vec2(160, 120)], reason: 'middle of frame');
    expect(container.read(calibrationProvider).surface, isNotNull);
    expect(find.text('Using a vertical board'), findsOneWidget);
    expect(find.textContaining('Not needed while a surface'), findsOneWidget);

    await unmount(tester);
  });

  testWidgets('experiment screen fits a landscape phone', (tester) async {
    await pumpApp(tester, at: Routes.experiment);
    tester.view.physicalSize = const Size(844, 390) * 3;
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
