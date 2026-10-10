import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';
import 'package:hands_on_physics/services/camera/arkit_frame_source.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';

class _FallbackCamera implements FrameSource {
  @override
  String get name => 'fake camera';

  int starts = 0;

  @override
  Future<void> start() async => starts++;

  @override
  Future<void> stop() async {}

  @override
  bool get isRunning => starts > 0;

  @override
  FrameSize? get frameSize => const FrameSize(320, 240);

  @override
  Future<EncodedFrame?> capture({int width = 320}) async => null;

  @override
  Widget buildPreview(BuildContext context) => const SizedBox.expand();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('handson/arkit');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late _FallbackCamera fallback;

  void answer(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(() {
    calls = [];
    fallback = _FallbackCamera();
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('streams frames with the camera pose', () async {
    answer(
      (call) => switch (call.method) {
        'isSupported' => true,
        'start' => {'width': 320, 'height': 427},
        'capture' => {
          'jpeg': Uint8List.fromList([1, 2, 3]),
          'width': 320,
          'height': 427,
          'timestamp': 12.5,
          'intrinsics': [250.0, 250.0, 160.0, 213.5],
          'camera_to_world': List<double>.generate(
            16,
            (i) => i % 5 == 0 ? 1 : 0,
          ),
        },
        _ => null,
      },
    );
    final source = ArKitFrameSource(fallback: fallback);
    await source.start();
    expect(source.isRunning, isTrue);
    expect(source.canFindSurfaces, isTrue);
    expect(source.frameSize, const FrameSize(320, 427));

    final frame = (await source.capture())!;
    expect(frame.jpeg, [1, 2, 3]);
    expect(frame.captureTime, 12.5);
    expect(frame.pose!.cy, 213.5);
    expect(frame.pose!.cameraToWorld[15], 1);
    expect(fallback.starts, 0);
  });

  test('finds a surface at a frame pixel', () async {
    answer(
      (call) => switch (call.method) {
        'isSupported' => true,
        'start' => {'width': 320, 'height': 427},
        'raycast' => {
          'point': [0.0, 0.1, -0.9],
          'normal': [0.0, 0.0, 1.0],
          'vertical': true,
        },
        _ => null,
      },
    );
    final source = ArKitFrameSource(fallback: fallback);
    await source.start();
    final surface = await source.findSurface(const Vec2(160, 213.5));
    expect(surface!.vertical, isTrue);
    expect(surface.point, [0.0, 0.1, -0.9]);
    final raycast = calls.singleWhere((c) => c.method == 'raycast');
    expect(raycast.arguments, {'x': 160.0, 'y': 213.5, 'width': 320});
  });

  test('uses the plain camera on devices without ARKit', () async {
    answer((call) => call.method == 'isSupported' ? false : null);
    final source = ArKitFrameSource(fallback: fallback);
    await source.start();
    expect(fallback.starts, 1);
    expect(source.frameSize, const FrameSize(320, 240));
    expect(source.canFindSurfaces, isFalse);
    expect(calls.map((c) => c.method), ['isSupported']);
  });

  test('uses the plain camera when the plugin is missing', () async {
    final source = ArKitFrameSource(fallback: fallback);
    await source.start();
    expect(fallback.starts, 1);
  });

  test('a denied camera explains how to fix it', () async {
    answer(
      (call) => call.method == 'isSupported'
          ? true
          : throw PlatformException(code: 'denied'),
    );
    final source = ArKitFrameSource(fallback: fallback);
    expect(
      source.start,
      throwsA(
        isA<CameraUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('Settings'),
        ),
      ),
    );
  });
}
