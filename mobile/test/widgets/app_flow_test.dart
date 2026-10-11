import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hands_on_physics/app.dart';
import 'package:hands_on_physics/core/config/app_config.dart';
import 'package:hands_on_physics/core/logging/debug_log.dart';
import 'package:hands_on_physics/core/routing/router.dart';
import 'package:hands_on_physics/features/settings/backend_url.dart';
import 'package:hands_on_physics/models/camera_pose.dart';
import 'package:hands_on_physics/models/experiment_mode.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/services/network/acquisition_client.dart';
import 'package:hands_on_physics/features/calibration/widgets/calibration_stage.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';

/// Counts how often the app tries to open the camera.
class _FakeCamera implements FrameSource {
  @override
  String get name => 'fake camera';

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
  Future<EncodedFrame?> capture({int width = 320}) async => EncodedFrame(
    jpeg: img.encodeJpg(img.Image(width: 320, height: 240)),
    size: const FrameSize(320, 240),
    captureTime: 1,
  );

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();
}

class _Acquisition extends AcquisitionClient {
  _Acquisition({this.fail = false});
  final bool fail;
  @override
  Future<AcquisitionProposal> propose(
    String url,
    Vec2 point,
    EncodedFrame frame,
  ) async => AcquisitionProposal(
    fail ? null : PixelRect(point.x - 16, point.y - 16, 32, 32),
    fail ? 'no_clear_boundary' : 'enclosing_contour',
  );
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
    AcquisitionClient? acquisition,
  }) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          frameSourceProvider.overrideWithValue(camera),
          acquisitionClientProvider.overrideWithValue(
            acquisition ?? _Acquisition(),
          ),
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

  /// Catches what the app puts on the clipboard.
  List<String> mockClipboard(WidgetTester tester) {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    return copied;
  }

  /// Unmounts the app so its tickers and timers stop before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  Future<void> selectAndConfirm(WidgetTester tester) async {
    await tester.pump();
    await tester.tap(find.byType(CalibrationStage));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.scrollUntilVisible(
      find.text('Confirm object'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Confirm object'));
    await tester.pump();
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

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start experiment'),
          )
          .onPressed,
      isNull,
    );
    await selectAndConfirm(tester);

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

    await selectAndConfirm(tester);
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

  testWidgets('failed tap requests a box and retry restores live selection', (
    tester,
  ) async {
    final container = await pumpApp(
      tester,
      acquisition: _Acquisition(fail: true),
    );
    await tester.tap(find.textContaining('Set up'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    await tester.tap(find.byType(CalibrationStage));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      container.read(calibrationProvider).selectionError,
      contains('Draw a box'),
    );
    expect(container.read(calibrationProvider).targetBbox, isNull);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Start experiment'),
          )
          .onPressed,
      isNull,
    );
    final held = container.read(calibrationProvider).selectionFrame;
    final stage = find.byType(CalibrationStage);
    final bounds = tester.getRect(stage);
    final drag = await tester.startGesture(
      bounds.topLeft + Offset(bounds.width * .2, bounds.height * .6),
    );
    await drag.moveTo(
      bounds.topLeft + Offset(bounds.width * .3, bounds.height * .7),
    );
    await tester.pump();
    await drag.moveTo(
      bounds.topLeft + Offset(bounds.width * .5, bounds.height * .9),
    );
    await drag.up();
    await tester.pump();
    expect(container.read(calibrationProvider).targetBbox, isNotNull);
    expect(container.read(calibrationProvider).selectionError, isNull);
    expect(container.read(calibrationProvider).selectionFrame, same(held));
    await tester.scrollUntilVisible(
      find.text('Confirm object'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Confirm object'));
    await tester.pump();
    expect(container.read(calibrationProvider).selectionConfirmed, isTrue);
    await tester.scrollUntilVisible(
      find.text('Retry selection'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Retry selection'));
    await tester.pump();
    expect(container.read(calibrationProvider).selectionFrame, isNull);
    expect(container.read(calibrationProvider).selectionError, isNull);
    await unmount(tester);
  });

  testWidgets('experiment screen fits a landscape phone', (tester) async {
    await pumpApp(tester, at: Routes.experiment);
    tester.view.physicalSize = const Size(844, 390) * 3;
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    await unmount(tester);
  });

  testWidgets('experiment screen copies the debug log', (tester) async {
    final copied = mockClipboard(tester);
    await pumpApp(tester, at: Routes.experiment);

    await tester.tap(find.byTooltip('Copy debug log'));
    await tester.pump();

    expect(copied, hasLength(1));
    expect(
      copied.single,
      startsWith('HandsOn Physics ${AppConfig.appVersion}'),
    );
    expect(copied.single, contains('======== Session '));
    expect(copied.single, contains('Config (session start): '));
    expect(
      find.textContaining(RegExp(r'^Copied [\d,]+ log lines$')),
      findsOneWidget,
    );
    await unmount(tester);
  });

  testWidgets('settings copies and clears the debug log', (tester) async {
    final copied = mockClipboard(tester);
    log.i('Something worth reading');
    await pumpApp(tester, at: Routes.settings);

    await tester.scrollUntilVisible(
      find.text('Copy debug log'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Copy debug log'));
    await tester.pump();
    expect(copied.single, contains('Something worth reading'));

    log.i('Logged while Settings is open');
    final shown = find.textContaining('entries so far');
    final before = tester.widget<Text>(shown).data;
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Text>(shown).data, isNot(before));

    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(log.entries.map((e) => e.message), ['Debug log cleared']);
    expect(find.text('1 entry so far'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await unmount(tester);
  });
}
