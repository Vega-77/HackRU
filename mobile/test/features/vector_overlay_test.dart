import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/widgets/vector_overlay.dart';
import 'package:hands_on_physics/features/experiment/widgets/vector_overlay_painter.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';

const _state = PhysicsState(
  frameId: 1,
  t: 1,
  tracked: true,
  pixel: Vec2(100, 100),
  bbox: PixelRect(90, 90, 20, 20),
  velocity: Vec2(1, 0),
);

void main() {
  late ValueNotifier<PixelRect?> live;

  setUp(() => live = ValueNotifier(null));

  Widget overlay({bool reduceMotion = false}) => MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: VectorOverlay(
        state: _state,
        frameSize: const FrameSize(320, 240),
        massKg: 0.1,
        liveBox: live,
      ),
    ),
  );

  Vec2? marker(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(VectorOverlay),
        matching: find.byType(CustomPaint),
      ),
    );
    return (paint.painter! as VectorOverlayPainter).frame.value.pixel;
  }

  testWidgets('the marker sits on the followed box at once', (tester) async {
    await tester.pumpWidget(overlay());
    expect(marker(tester), const Vec2(100, 100));

    live.value = const PixelRect(150, 60, 20, 30);
    expect(marker(tester), const Vec2(160, 75));
    await tester.pump(const Duration(milliseconds: 100));
    expect(marker(tester), const Vec2(160, 75));

    // Losing the box eases back to the backend's position.
    live.value = null;
    await tester.pump(const Duration(milliseconds: 16));
    final easing = marker(tester)!;
    expect(easing.x, lessThan(160));
    expect(easing.x, greaterThan(100));
    await tester.pumpAndSettle();
    expect(marker(tester), const Vec2(100, 100));
  });

  testWidgets('follows without animation under reduced motion', (tester) async {
    await tester.pumpWidget(overlay(reduceMotion: true));
    live.value = const PixelRect(150, 60, 20, 30);
    expect(marker(tester), const Vec2(160, 75));
    expect(tester.hasRunningAnimations, isFalse);
    live.value = null;
    expect(marker(tester), const Vec2(100, 100));
  });

  group('force direction', () {
    const origin = Offset(100, 100);

    test('tension runs along the string to the pivot', () {
      // The backend's vector still points straight up, a reply behind.
      final d = VectorOverlayPainter.forceDirection(
        'tension',
        const Vec2(0, 1),
        null,
        origin,
        const Offset(130, 60),
      );
      expect(d.dx, closeTo(0.6, 1e-9));
      expect(d.dy, closeTo(-0.8, 1e-9));
    });

    test('other forces and a missing pivot keep the world vector', () {
      final gravity = VectorOverlayPainter.forceDirection(
        'gravity',
        const Vec2(0, -1),
        null,
        origin,
        const Offset(130, 60),
      );
      expect(gravity, const Offset(0, 1));
      final tension = VectorOverlayPainter.forceDirection(
        'tension',
        const Vec2(0, 1),
        null,
        origin,
        null,
      );
      expect(tension, const Offset(0, -1));
    });
  });
}
