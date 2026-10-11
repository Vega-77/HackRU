import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/features/experiment/widgets/ar_vector_layer.dart';
import 'package:hands_on_physics/features/experiment/widgets/vector_overlay_painter.dart';
import 'package:hands_on_physics/models/ar_vectors.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/vec3.dart';
import 'package:hands_on_physics/services/camera/frame_source.dart';

class _Display implements ArVectorDisplay {
  final List<ArVectorScene?> shown = [];

  @override
  bool get canShowArVectors => true;

  @override
  Future<void> showArVectors(ArVectorScene? scene) async => shown.add(scene);

  @override
  final followedBox = ValueNotifier<PixelRect?>(null);
}

PhysicsState _state(int frame, {bool tracked = true}) => PhysicsState(
  frameId: frame,
  t: frame / 15,
  tracked: tracked,
  position3d: const Vec3(0, 0.5, -1),
  velocity3d: Vec3(frame.toDouble(), 0, 0),
);

void main() {
  late _Display display;

  Widget layer(PhysicsState? state, {OverlayLayers? layers}) => MediaQuery(
    data: const MediaQueryData(disableAnimations: true),
    child: ArVectorLayer(
      display: display,
      state: state,
      massKg: 0.1,
      layers: layers ?? const OverlayLayers(),
    ),
  );

  setUp(() => display = _Display());

  testWidgets('pushes each reply and hides when removed', (tester) async {
    await tester.pumpWidget(layer(_state(1)));
    expect(display.shown, hasLength(1));
    expect(display.shown.single!.easeSeconds, 0, reason: 'reduced motion');

    await tester.pumpWidget(layer(_state(2)));
    expect(display.shown, hasLength(2));
    expect(display.shown.last!.arrows.single.id, 'velocity');

    // A lost object clears the arrows but keeps the layer.
    await tester.pumpWidget(layer(_state(3, tracked: false)));
    expect(display.shown.last, isNull);

    await tester.pumpWidget(layer(_state(4), layers: OverlayLayers.none));
    expect(display.shown.last!.arrows, isEmpty);

    await tester.pumpWidget(const SizedBox());
    expect(display.shown.last, isNull);
  });

  testWidgets('the same reply is not sent twice', (tester) async {
    final state = _state(1);
    await tester.pumpWidget(layer(state));
    await tester.pumpWidget(layer(state));
    expect(display.shown, hasLength(1));
  });
}
