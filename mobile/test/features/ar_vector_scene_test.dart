import 'package:flutter_test/flutter_test.dart';
import 'package:hands_on_physics/core/theme/tokens.dart';
import 'package:hands_on_physics/features/experiment/widgets/ar_vector_scene.dart';
import 'package:hands_on_physics/features/experiment/widgets/vector_overlay_painter.dart';
import 'package:hands_on_physics/models/physics_state.dart';
import 'package:hands_on_physics/models/session_config.dart';
import 'package:hands_on_physics/models/vec3.dart';

PhysicsState _state({
  bool tracked = true,
  Vec3? position = const Vec3(0.1, 0.8, -0.5),
  Vec3? velocity = const Vec3(1, 0, 0),
  Vec3? acceleration = const Vec3(0, -2, 0),
  List<ForceVector3> forces = const [
    ForceVector3('gravity', Vec3(0, -0.981, 0)),
    ForceVector3('gravity_parallel', Vec3(0.49, -0.49, 0)),
  ],
  PixelRect? bbox,
}) => PhysicsState(
  frameId: 9,
  t: 1,
  tracked: tracked,
  position3d: position,
  velocity3d: velocity,
  acceleration3d: acceleration,
  forces3d: forces,
  bbox: bbox,
);

void main() {
  const mass = 0.1;

  test('nothing to anchor means no scene', () {
    expect(ArVectorSceneBuilder.build(null, massKg: mass), isNull);
    expect(
      ArVectorSceneBuilder.build(_state(tracked: false), massKg: mass),
      isNull,
    );
    expect(
      ArVectorSceneBuilder.build(_state(position: null), massKg: mass),
      isNull,
    );
  });

  test('arrows are rooted at the object with world lengths', () {
    final scene = ArVectorSceneBuilder.build(_state(), massKg: mass)!;
    expect(scene.origin, const Vec3(0.1, 0.8, -0.5));
    final byId = {for (final a in scene.arrows) a.id: a};
    expect(byId.keys, [
      'force:gravity',
      'force:gravity_parallel',
      'acceleration',
      'velocity',
    ]);

    // 1 m/s is 12 cm, and the weight is 9 cm.
    expect(byId['velocity']!.lengthM, closeTo(0.12, 1e-9));
    expect(byId['force:gravity']!.lengthM, closeTo(0.09, 1e-9));
    expect(byId['acceleration']!.lengthM, closeTo(0.06, 1e-9));

    expect(byId['velocity']!.direction, const Vec3(1, 0, 0));
    expect(byId['acceleration']!.direction, const Vec3(0, -1, 0));
    expect(byId['force:gravity_parallel']!.direction.length, closeTo(1, 1e-9));

    expect(
      byId['velocity']!.radiusM,
      closeTo(3.5 * ArVectorSceneBuilder.radiusPerWidthPx, 1e-12),
    );
  });

  test('carries the object size so the ball can hide arrows', () {
    expect(
      ArVectorSceneBuilder.build(_state(), massKg: mass)!.objectRadiusPx,
      0,
    );
    final scene = ArVectorSceneBuilder.build(
      _state(bbox: const PixelRect(100, 80, 40, 50)),
      massKg: mass,
    )!;
    // The smaller side, halved, a little inside a loose box.
    expect(
      scene.objectRadiusPx,
      closeTo(20 * ArVectorSceneBuilder.boxRadiusFactor, 1e-9),
    );
  });

  test('carries the box and its frame so the native view can follow', () {
    final scene = ArVectorSceneBuilder.build(
      _state(bbox: const PixelRect(100, 80, 40, 50)),
      massKg: mass,
    )!;
    expect(scene.capturedAt, 1);
    final map = scene.toMap(frameSize: const FrameSize(200, 400));
    expect(map['box'], [0.5, 0.2, 0.2, 0.125]);
    expect(map['captured_at'], 1);
    expect(map['box_radius_factor'], ArVectorSceneBuilder.boxRadiusFactor);
    // Nothing to normalize against without the frame size.
    expect(scene.toMap(), isNot(contains('box')));
    expect(
      ArVectorSceneBuilder.build(
        _state(),
        massKg: mass,
      )!.toMap(frameSize: const FrameSize(200, 400)),
      isNot(contains('box')),
    );
  });

  test('colours and labels follow the 2D overlay', () {
    final scene = ArVectorSceneBuilder.build(_state(), massKg: mass)!;
    final byId = {for (final a in scene.arrows) a.id: a};
    expect(byId['velocity']!.argb, AppColors.velocity.toARGB32());
    expect(byId['acceleration']!.argb, AppColors.acceleration.toARGB32());
    expect(byId['force:gravity']!.argb, AppColors.forceComponent.toARGB32());
    expect(byId['force:gravity']!.subscript, 'g');
    expect(byId['force:gravity']!.dashed, isFalse);
    expect(byId['force:gravity_parallel']!.dashed, isTrue);
    expect(scene.haloArgb, AppColors.graphiteDeep.toARGB32());
  });

  test('hidden layers and tiny vectors are left out', () {
    final scene = ArVectorSceneBuilder.build(
      _state(velocity: const Vec3(0.001, 0, 0)),
      massKg: mass,
      layers: const OverlayLayers(forces: false),
    )!;
    expect(scene.arrows.map((a) => a.id), ['acceleration']);

    final none = ArVectorSceneBuilder.build(
      _state(),
      massKg: mass,
      layers: OverlayLayers.none,
    )!;
    expect(none.arrows, isEmpty);
  });

  test('reduced motion snaps instead of easing', () {
    expect(
      ArVectorSceneBuilder.build(_state(), massKg: mass)!.easeSeconds,
      ArVectorSceneBuilder.easeSeconds,
    );
    expect(
      ArVectorSceneBuilder.build(
        _state(),
        massKg: mass,
        reduceMotion: true,
      )!.easeSeconds,
      0,
    );
  });

  test('encodes the setVectors arguments', () {
    final map = ArVectorSceneBuilder.build(
      _state(forces: const [], acceleration: null),
      massKg: mass,
    )!.toMap();
    expect(map['origin'], [0.1, 0.8, -0.5]);
    expect(map['ease_s'], ArVectorSceneBuilder.easeSeconds);
    expect(map['labels'], isTrue);
    expect(map['halo'], AppColors.graphiteDeep.toARGB32());
    expect(map['occluder_radius'], 0);
    final arrow = (map['arrows']! as List).single as Map;
    expect(arrow.keys, [
      'id',
      'direction',
      'length',
      'radius',
      'color',
      'symbol',
      'subscript',
      'dashed',
    ]);
    expect(arrow['direction'], [1.0, 0.0, 0.0]);
    expect(arrow['symbol'], 'v');
  });
}
