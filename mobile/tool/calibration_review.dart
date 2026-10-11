// Development-only camera fixture for visual and interaction review.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:hands_on_physics/app.dart';
import 'package:hands_on_physics/core/routing/router.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/services/network/acquisition_client.dart';
import 'package:hands_on_physics/state/calibration_controller.dart';
import 'package:hands_on_physics/state/experiment_settings.dart';
import 'package:hands_on_physics/state/session_controller.dart';

class MeasurementCameraFixture implements FrameSource {
  MeasurementCameraFixture({this.failFirst = false, bool bright = false}) {
    final image = img.Image(width: 320, height: 240);
    img.fill(
      image,
      color: img.ColorRgb8(
        bright ? 224 : 58,
        bright ? 224 : 61,
        bright ? 220 : 64,
      ),
    );
    img.fillRect(
      image,
      x1: 0,
      y1: 186,
      x2: 319,
      y2: 239,
      color: img.ColorRgb8(
        bright ? 186 : 44,
        bright ? 190 : 47,
        bright ? 188 : 49,
      ),
    );
    img.fillRect(
      image,
      x1: 55,
      y1: 65,
      x2: 265,
      y2: 80,
      color: img.ColorRgb8(204, 199, 181),
    );
    for (var x = 60; x <= 260; x += 10) {
      img.drawLine(
        image,
        x1: x,
        y1: 66,
        x2: x,
        y2: x % 50 == 10 ? 77 : 72,
        color: img.ColorRgb8(55, 55, 50),
      );
    }
    img.fillCircle(
      image,
      x: 160,
      y: 160,
      radius: 26,
      color: img.ColorRgb8(40, 42, 44),
    );
    img.fillCircle(
      image,
      x: 160,
      y: 160,
      radius: 24,
      color: img.ColorRgb8(144, 148, 151),
    );
    frame = EncodedFrame(
      jpeg: img.encodeJpg(image),
      size: const FrameSize(320, 240),
      captureTime: 1,
    );
  }
  late final EncodedFrame frame;
  final bool failFirst;
  bool running = false;
  int starts = 0;
  @override
  String get name => 'Synthetic UI camera';
  @override
  bool get isRunning => running;
  @override
  FrameSize? get frameSize => running ? frame.size : null;
  @override
  Future<void> start() async {
    starts++;
    if (failFirst && starts == 1) {
      throw const CameraUnavailableException(
        'Camera access is unavailable. Allow access and retry.',
      );
    }
    running = true;
  }

  @override
  Future<void> stop() async {
    running = false;
  }

  @override
  Future<EncodedFrame> capture({int width = 320}) async => frame;
  @override
  Widget buildPreview(BuildContext context) =>
      Image.memory(frame.jpeg, fit: BoxFit.cover);
}

class MeasurementAcquisitionFixture extends AcquisitionClient {
  @override
  Future<AcquisitionProposal> propose(
    String url,
    Vec2 point,
    EncodedFrame frame,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return AcquisitionProposal(
      PixelRect(point.x - 26, point.y - 26, 52, 52),
      'UI fixture',
    );
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final scenario = Uri.base.queryParameters['state'];
  final camera = MeasurementCameraFixture(
    failFirst: scenario == 'camera_error',
    bright: Uri.base.queryParameters['lighting'] == 'bright',
  );
  final container = ProviderContainer(
    overrides: [
      frameSourceProvider.overrideWithValue(camera),
      acquisitionClientProvider.overrideWithValue(
        MeasurementAcquisitionFixture(),
      ),
    ],
  );
  final controller = container.read(calibrationProvider.notifier);
  container
      .read(experimentSettingsProvider.notifier)
      .setBackendUrl('ws://127.0.0.1:8000/ws/frames');
  controller
    ..setRulerStart(const Vec2(60, 72))
    ..setRulerEnd(const Vec2(260, 72));
  if (scenario == 'pending' || scenario == 'error') {
    controller.beginAcquisition(const Vec2(160, 160), camera.frame);
    if (scenario == 'error') {
      controller.acquisitionFailed(
        'No clear object boundary. Draw a box around the object, or retry.',
      );
    }
  } else if (scenario == 'selected' || scenario == 'confirmed') {
    controller.selectObject(
      const Vec2(160, 160),
      const PixelRect(134, 134, 52, 52),
      camera.frame,
    );
    if (scenario == 'confirmed') controller.confirmSelection();
  }
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Banner(
          message: 'UI fixture',
          location: BannerLocation.topEnd,
          child: HandsOnPhysicsApp(
            router: buildAppRouter(initialLocation: Routes.calibrate),
          ),
        ),
      ),
    ),
  );
}
