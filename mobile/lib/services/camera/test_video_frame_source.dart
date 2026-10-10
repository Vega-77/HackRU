import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import '../../core/config/app_config.dart';
import '../../core/theme/tokens.dart';
import '../../models/session_config.dart';
import '../../models/vec2.dart';
import 'frame_source.dart';

/// A drawn video of a red ball on a string, for devices with no camera
/// (the iOS Simulator, a laptop without a webcam).
///
/// The frames go to the backend like camera frames, so the app works end
/// to end: the backend's colour tracker finds the ball and measures a real
/// pendulum swing. The preview draws the same scene at the same moment, so
/// the overlay lines up with it.
class TestVideoFrameSource implements FrameSource {
  /// Portrait, like a phone held upright: height over width.
  static const double aspect = 4 / 3;

  /// Seconds for one swing there and back.
  static const double period = 2.0;

  final Stopwatch _clock = Stopwatch();

  @override
  bool get isRunning => _clock.isRunning;

  @override
  FrameSize? get frameSize => isRunning ? sizeFor(AppConfig.frameWidth) : null;

  /// Seconds since [start].
  double get elapsed => _clock.elapsedMicroseconds / 1e6;

  @override
  Future<void> start() async {
    if (isRunning) return;
    _clock
      ..reset()
      ..start();
  }

  @override
  Future<void> stop() async => _clock.stop();

  @override
  Future<EncodedFrame?> capture({int width = AppConfig.frameWidth}) async {
    if (!isRunning) return null;
    final time = elapsed;
    final size = sizeFor(width);
    final jpeg = await compute(_render, _RenderJob(time, size));
    return EncodedFrame(jpeg: jpeg, size: size, captureTime: time);
  }

  @override
  Widget buildPreview(BuildContext context) =>
      isRunning ? _TestVideoPreview(this) : const SizedBox.expand();

  static FrameSize sizeFor(int width) =>
      FrameSize(width, (width * aspect).round());

  /// Where the string hangs from, in frame pixels.
  static Vec2 pivot(FrameSize size) => Vec2(size.width / 2, size.height * 0.14);

  /// The ball's radius in frame pixels: 14 px in a 320 px frame, the size
  /// the backend's live test tracks.
  static double ballRadius(FrameSize size) => size.width * 0.044;

  /// The centre of the ball [time] seconds after [start], in frame pixels.
  static Vec2 ballAt(double time, FrameSize size) {
    final length = size.height * 0.55;
    final angle = 0.45 * math.sin(2 * math.pi * time / period);
    final top = pivot(size);
    return Vec2(
      top.x + length * math.sin(angle),
      top.y + length * math.cos(angle),
    );
  }
}

// The scene's colours stand in for a red ball over a grey table, picked so
// the backend's red detector finds the ball and nothing else. They are
// picture content, not interface colours, so they live here and not in the
// theme.
const _background = (90, 90, 90);
const _string = (150, 150, 150);
const _ball = (220, 30, 30);

Color _color((int, int, int) rgb) =>
    Color.fromARGB(255, rgb.$1, rgb.$2, rgb.$3);

img.Color _imgColor((int, int, int) rgb) =>
    img.ColorRgb8(rgb.$1, rgb.$2, rgb.$3);

class _RenderJob {
  const _RenderJob(this.time, this.size);

  final double time;
  final FrameSize size;
}

/// Draws one frame and encodes it as JPEG. Runs off the UI thread on iOS.
Uint8List _render(_RenderJob job) {
  final size = job.size;
  final top = TestVideoFrameSource.pivot(size);
  final ball = TestVideoFrameSource.ballAt(job.time, size);
  final image = img.Image(width: size.width, height: size.height)
    ..clear(_imgColor(_background));
  img.drawLine(
    image,
    x1: top.x.round(),
    y1: top.y.round(),
    x2: ball.x.round(),
    y2: ball.y.round(),
    color: _imgColor(_string),
    thickness: 2,
  );
  img.fillCircle(
    image,
    x: ball.x.round(),
    y: ball.y.round(),
    radius: TestVideoFrameSource.ballRadius(size).round(),
    color: _imgColor(_ball),
  );
  return img.encodeJpg(image, quality: (AppConfig.jpegQuality * 100).round());
}

/// The scene, redrawn every screen frame from the source's clock.
class _TestVideoPreview extends StatefulWidget {
  const _TestVideoPreview(this.source);

  final TestVideoFrameSource source;

  @override
  State<_TestVideoPreview> createState() => _TestVideoPreviewState();
}

class _TestVideoPreviewState extends State<_TestVideoPreview>
    with SingleTickerProviderStateMixin {
  late final ValueNotifier<double> _time = ValueNotifier(widget.source.elapsed);
  late final Ticker _ticker = createTicker(
    (_) => _time.value = widget.source.elapsed,
  );

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = TestVideoFrameSource.sizeFor(AppConfig.frameWidth);
    // The same fit as a camera preview, so the overlay's mapping holds. The
    // caption sits outside the fit, so cropping never cuts it off.
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: size.width.toDouble(),
              height: size.height.toDouble(),
              child: CustomPaint(painter: _ScenePainter(_time, size)),
            ),
          ),
        ),
        Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.all(AppSpace.sm),
            child: Text(
              'Test video. This device has no camera.',
              style: AppType.caption.copyWith(color: AppColors.vellum),
            ),
          ),
        ),
      ],
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter(this.time, this.frame) : super(repaint: time);

  final ValueListenable<double> time;
  final FrameSize frame;

  @override
  void paint(Canvas canvas, Size size) {
    final top = TestVideoFrameSource.pivot(frame);
    final ball = TestVideoFrameSource.ballAt(time.value, frame);
    canvas
      ..drawColor(_color(_background), BlendMode.src)
      ..drawLine(
        Offset(top.x, top.y),
        Offset(ball.x, ball.y),
        Paint()
          ..color = _color(_string)
          ..strokeWidth = 2,
      )
      ..drawCircle(
        Offset(ball.x, ball.y),
        TestVideoFrameSource.ballRadius(frame),
        Paint()..color = _color(_ball),
      );
  }

  @override
  bool shouldRepaint(_ScenePainter old) => old.frame != frame;
}
