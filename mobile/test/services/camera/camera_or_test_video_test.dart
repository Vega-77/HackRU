import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/camera_pose.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/camera/camera_or_test_video.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';

class _ArCamera implements FrameSource, SurfaceFinder {
  @override
  String get name => 'fake camera';

  bool running = false;
  bool hasCamera = true;

  @override
  Future<void> start() async {
    if (!hasCamera) throw const NoCameraException();
    running = true;
  }

  @override
  Future<void> stop() async => running = false;

  @override
  bool get isRunning => running;

  @override
  FrameSize? get frameSize => const FrameSize(320, 427);

  @override
  Future<EncodedFrame?> capture({int width = 320}) async => null;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();

  @override
  bool get canFindSurfaces => running;

  @override
  Future<ArSurface?> findSurface(Vec2 framePixel) async =>
      const ArSurface(point: [0, 0, -1], normal: [0, 0, 1], vertical: true);
}

void main() {
  test('passes surface finding through from an AR camera', () async {
    final source = CameraOrTestVideo(_ArCamera());
    expect(source.canFindSurfaces, isFalse);
    await source.start();
    expect(source.canFindSurfaces, isTrue);
    final surface = await source.findSurface(const Vec2(160, 213));
    expect(surface!.vertical, isTrue);
  });

  test('the test video finds no surfaces', () async {
    final source = CameraOrTestVideo(_ArCamera()..hasCamera = false);
    await source.start();
    expect(source.usingTestVideo, isTrue);
    expect(source.canFindSurfaces, isFalse);
    expect(await source.findSurface(const Vec2(160, 120)), isNull);
    await source.stop();
  });
}
