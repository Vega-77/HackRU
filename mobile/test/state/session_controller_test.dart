import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';

class _FakeCamera implements FrameSource {
  @override
  bool isRunning = false;

  @override
  Future<void> start() async => isRunning = true;

  @override
  Future<void> stop() async => isRunning = false;

  @override
  FrameSize? get frameSize => isRunning ? const FrameSize(320, 240) : null;

  @override
  Future<EncodedFrame?> capture({int width = 320}) async => null;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();
}

void main() {
  late _FakeCamera camera;
  late ProviderContainer container;

  setUp(() {
    camera = _FakeCamera();
    container = ProviderContainer(
      overrides: [frameSourceProvider.overrideWithValue(camera)],
    );
    addTearDown(container.dispose);
    // Nothing listens here, so the socket just fails to connect.
    container
        .read(experimentSettingsProvider.notifier)
        .setBackendUrl('ws://127.0.0.1:9/ws/frames');
  });

  SessionController session() => container.read(sessionProvider.notifier);

  test(
    'leaves the camera on for calibration when the experiment ends',
    () async {
      // Calibration opens the camera and stays mounted under the experiment.
      await camera.start();

      await session().start();
      await session().stop();

      expect(camera.isRunning, isTrue);
    },
  );

  test('releases the camera it opened itself', () async {
    await session().start();
    expect(camera.isRunning, isTrue);

    await session().stop();

    expect(camera.isRunning, isFalse);
  });
}
