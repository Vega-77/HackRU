import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/widgets/vector_overlay.dart';
import 'package:hands_on_physics/features/experiment/widgets/vector_overlay_painter.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec2.dart';

void main() {
  testWidgets('live marker and trail contain only confirmed camera positions', (
    tester,
  ) async {
    Widget overlay(PhysicsState state) => MediaQuery(
      data: const MediaQueryData(),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: VectorOverlay(
          state: state,
          frameSize: const FrameSize(320, 180),
          massKg: .1,
        ),
      ),
    );
    VectorOverlayPainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<VectorOverlayPainter>()
        .single;
    await tester.pumpWidget(
      overlay(
        const PhysicsState(
          frameId: 1,
          t: 1,
          tracked: true,
          pixel: Vec2(50, 40),
          velocity: Vec2(0, -1),
        ),
      ),
    );
    await tester.pumpWidget(
      overlay(
        const PhysicsState(
          frameId: 2,
          t: 1.1,
          tracked: true,
          pixel: Vec2(50, 140),
          velocity: Vec2(0, -2),
        ),
      ),
    );
    expect(painter().frame.value.pixel, const Vec2(50, 140));
    expect(painter().trail!.value, hasLength(1));
    final trail = painter().trail!.value.toList();
    await tester.pump(const Duration(milliseconds: 150));
    expect(painter().frame.value.pixel, const Vec2(50, 140));
    expect(painter().trail!.value, trail);
    await tester.pumpWidget(
      overlay(const PhysicsState(frameId: 3, t: 1.2, tracked: false)),
    );
    expect(painter().frame.value.visibility, 0);
    expect(painter().trail!.value, isEmpty);
  });
}
