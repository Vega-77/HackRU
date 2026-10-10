import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/services/camera/camera_or_test_video.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';
import 'package:hands_on_physics/services/camera/test_video_frame_source.dart';
import 'package:image/image.dart' as img;

/// A camera that fails to open with [error].
class _BrokenCamera implements FrameSource {
  @override
  String get name => 'fake camera';

  _BrokenCamera(this.error);

  final CameraUnavailableException error;

  @override
  Future<void> start() async => throw error;

  @override
  Future<void> stop() async {}

  @override
  bool get isRunning => false;

  @override
  FrameSize? get frameSize => null;

  @override
  Future<EncodedFrame?> capture({int width = 320}) async => null;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();
}

void main() {
  group('TestVideoFrameSource', () {
    test('sends nothing until started', () async {
      final video = TestVideoFrameSource();
      expect(video.frameSize, isNull);
      expect(await video.capture(), isNull);
    });

    test('draws the ball where ballAt says it is', () async {
      final video = TestVideoFrameSource();
      await video.start();
      final frame = (await video.capture())!;

      expect(frame.size, const FrameSize(320, 427));
      final image = img.decodeJpg(frame.jpeg)!;
      expect((image.width, image.height), (320, 427));

      final ball = TestVideoFrameSource.ballAt(frame.captureTime, frame.size);
      final centre = image.getPixel(ball.x.round(), ball.y.round());
      expect(centre.r, greaterThan(180));
      expect(centre.g, lessThan(80));
      // Well away from the ball, the frame is the grey background.
      final corner = image.getPixel(10, image.height - 10);
      expect(corner.r, closeTo(90, 12));
      expect(corner.g, closeTo(90, 12));
    });

    test('swings like a pendulum, staying in the frame', () {
      const size = FrameSize(320, 427);
      final rest = TestVideoFrameSource.ballAt(0, size);
      final quarter = TestVideoFrameSource.ballAt(
        TestVideoFrameSource.period / 4,
        size,
      );
      final full = TestVideoFrameSource.ballAt(
        TestVideoFrameSource.period,
        size,
      );

      expect(rest.x, closeTo(160, 0.01), reason: 'starts at the bottom');
      expect(quarter.x, greaterThan(250));
      expect(quarter.x, lessThan(320 - TestVideoFrameSource.ballRadius(size)));
      expect(quarter.y, lessThan(rest.y), reason: 'rises at the end');
      expect(full.x, closeTo(rest.x, 0.01));
    });
  });

  group('CameraOrTestVideo', () {
    test('plays the test video when the device has no camera', () async {
      final source = CameraOrTestVideo(
        _BrokenCamera(const NoCameraException()),
      );
      await source.start();

      expect(source.usingTestVideo, isTrue);
      expect(source.isRunning, isTrue);
      expect(source.frameSize, const FrameSize(320, 427));
      expect(await source.capture(), isNotNull);

      await source.stop();
      expect(source.isRunning, isFalse);
    });

    test('passes on other camera failures so the user can fix them', () {
      final source = CameraOrTestVideo(
        _BrokenCamera(
          const CameraUnavailableException('Camera access is off.'),
        ),
      );

      expect(
        source.start(),
        throwsA(
          isA<CameraUnavailableException>().having(
            (e) => e.message,
            'message',
            'Camera access is off.',
          ),
        ),
      );
    });
  });
}
