import '../../models/experiment_mode.dart';

/// Which arrow on the overlay a note explains. Each has its own colour.
enum VectorKind { velocity, acceleration, netForce, component }

/// How to read one arrow in this experiment.
class ArrowNote {
  const ArrowNote(this.kind, this.name, this.text);
  final VectorKind kind;
  final String name, text;
}

/// One force acting in the experiment and what it does.
class ForceNote {
  const ForceNote(this.name, this.formula, this.text);
  final String name;

  /// Written for [Formula], so `_x` is a subscript.
  final String formula;
  final String text;
}

/// A symbol in an equation and what it stands for.
class SymbolNote {
  const SymbolNote(this.symbol, this.meaning);
  final String symbol, meaning;
}

class LessonEquation {
  const LessonEquation(this.formula, this.meaning, [this.symbols = const []]);

  /// Written for [Formula], so `_x` is a subscript.
  final String formula;
  final String meaning;
  final List<SymbolNote> symbols;
}

class Mistake {
  const Mistake(this.mistake, this.fix);
  final String mistake, fix;
}

/// A page of theory for one experiment, or for the ideas they all share.
///
/// Pure content, separate from the camera, so a student can read it before
/// setting anything up.
class Lesson {
  const Lesson({
    required this.id,
    required this.number,
    required this.title,
    required this.summary,
    this.mode,
    required this.why,
    required this.idea,
    required this.arrows,
    required this.forces,
    required this.equations,
    this.equipment = const [],
    this.steps = const [],
    required this.expect,
    required this.mistakes,
  });

  /// Used in the route, `/learn/<id>`.
  final String id;
  final String number, title, summary;

  /// The experiment this lesson leads into. Null for the basics.
  final ExperimentMode? mode;
  final String why;
  final List<String> idea;
  final List<ArrowNote> arrows;
  final List<ForceNote> forces;
  final List<LessonEquation> equations;
  final List<String> equipment, steps, expect;
  final List<Mistake> mistakes;

  static const basicsId = 'basics';

  static Lesson byId(String id) =>
      all.firstWhere((l) => l.id == id, orElse: () => all.first);

  static Lesson forMode(ExperimentMode mode) =>
      all.firstWhere((l) => l.mode == mode);

  /// The lesson after this one, or null after the last.
  Lesson? get next {
    final i = all.indexOf(this);
    return i + 1 < all.length ? all[i + 1] : null;
  }

  /// Every piece of copy, so tests can check it against the style rules.
  Iterable<String> get copy sync* {
    yield* [title, summary, why, ...idea, ...equipment, ...steps, ...expect];
    for (final a in arrows) {
      yield* [a.name, a.text];
    }
    for (final f in forces) {
      yield* [f.name, f.formula, f.text];
    }
    for (final e in equations) {
      yield* [e.formula, e.meaning];
      for (final s in e.symbols) {
        yield* [s.symbol, s.meaning];
      }
    }
    for (final m in mistakes) {
      yield* [m.mistake, m.fix];
    }
  }

  static const all = [_basics, _freeFall, _ramp, _pendulum, _collision];
}

const _basics = Lesson(
  id: Lesson.basicsId,
  number: '00',
  title: 'Vectors and forces',
  summary: 'The language every experiment in this lab is written in.',
  why:
      'A number like 3 m/s says how fast, but not which way. Motion always '
      'has a direction, so physics describes it with vectors: arrows with a '
      'size and a direction. Once you can read the arrows, every experiment '
      'here tells the same story. Forces cause acceleration, and acceleration '
      'changes velocity.',
  idea: [
    'A vector has a magnitude, its length, and a direction. Two vectors add '
        'tip to tail. Any vector can be split into components along two '
        'directions at right angles, which is how slopes and swings become '
        'simple.',
    'Velocity is how fast position changes, and in which direction. '
        'Acceleration is how fast velocity changes. An object moving at a '
        'steady speed still accelerates if its direction is turning.',
    "Newton's second law ties them together: the net force on an object "
        'equals its mass times its acceleration. Net force and acceleration '
        'always point the same way. Velocity does not have to.',
    "Newton's third law says forces come in pairs. When the table pushes up "
        'on a ball, the ball pushes down on the table just as hard.',
  ],
  arrows: [
    ArrowNote(
      VectorKind.velocity,
      'Velocity',
      'Points the way the object is moving right now. Its length is the '
          'speed. It always runs along the path.',
    ),
    ArrowNote(
      VectorKind.acceleration,
      'Acceleration',
      'Points the way velocity is changing. Along the velocity, the object '
          'speeds up. Against it, the object slows down. Sideways, the path '
          'curves.',
    ),
    ArrowNote(
      VectorKind.netForce,
      'Net force',
      'The sum of every force on the object. It points the same way as the '
          'acceleration, and its size is mass times acceleration.',
    ),
    ArrowNote(
      VectorKind.component,
      'Forces and components',
      'The individual forces, or their parts along useful directions: weight '
          'split along and into a slope, the push of a surface, friction, and '
          'string tension.',
    ),
  ],
  forces: [
    ForceNote(
      'Weight',
      'W = mg',
      'Gravity pulls every object toward the centre of the Earth, in '
          'proportion to its mass. Near the ground g is about 9.81 m/s², so a '
          '0.1 kg ball weighs about 0.98 N.',
    ),
    ForceNote(
      'Normal force',
      'F_N',
      'A surface pushes back on anything pressing into it, at right angles '
          'to the surface. Normal means perpendicular. It grows only as large '
          'as it must to stop the object sinking in, so on a level table it '
          'matches the weight, and on a slope it is smaller.',
    ),
    ForceNote(
      'Friction',
      'f = μF_N',
      'Surfaces resist sliding over each other. Friction acts along the '
          'surface, against the sliding. Its size is the friction coefficient '
          'μ times the normal force, so pressing harder means more friction.',
    ),
    ForceNote(
      'Tension',
      'F_T',
      'A string can only pull, and only along its own length. It supplies '
          'whatever force keeps the object on the end of the string.',
    ),
    ForceNote(
      'Air resistance',
      'F_{drag}',
      'Drag grows with speed and points against the motion. For a small, '
          'dense ball over a short distance it is tiny, which is why the '
          'models here leave it out.',
    ),
  ],
  equations: [
    LessonEquation(
      'F_{net} = ma',
      "Newton's second law. The net force decides the acceleration.",
      [
        SymbolNote('F_{net}', 'Net force, the sum of all forces, in newtons'),
        SymbolNote('m', 'Mass, in kilograms'),
        SymbolNote('a', 'Acceleration, in metres per second squared'),
      ],
    ),
    LessonEquation(
      'v = Δx / Δt',
      'Velocity is the change in position over a short time. The app works '
          'it out from where the object is in each frame.',
      [
        SymbolNote('Δx', 'Change in position, in metres'),
        SymbolNote('Δt', 'Time between frames, in seconds'),
      ],
    ),
    LessonEquation(
      'a = Δv / Δt',
      'Acceleration is the change in velocity over a short time.',
      [SymbolNote('Δv', 'Change in velocity, in metres per second')],
    ),
    LessonEquation(
      'W_∥ = mg sin θ',
      'On a slope of angle θ, the part of the weight pulling along the slope. '
          'The part pressing into the slope is mg cos θ.',
      [SymbolNote('θ', 'Angle of the slope from level')],
    ),
  ],
  expect: [
    'Free fall: weight is the only force, so the acceleration is g, straight '
        'down.',
    'Ramp: weight, the normal force and friction. Only the parts along the '
        'slope are left over.',
    'Pendulum: weight and tension. Together they pull the bob back to the '
        'middle and keep it on its arc.',
    'Collision: a short, strong contact force between the two objects, equal '
        'and opposite on each.',
  ],
  mistakes: [
    Mistake(
      'Thinking a moving object needs a force to keep moving.',
      'Forces change motion, they do not sustain it. With no net force an '
          'object keeps its velocity. Things slow down on Earth because '
          'friction and drag are forces.',
    ),
    Mistake(
      'Drawing velocity and acceleration the same way.',
      "They often differ. At the top of a throw, the ball's velocity is "
          'sideways or zero, but its acceleration still points straight down.',
    ),
    Mistake(
      'Treating the normal force as always equal to the weight.',
      'It only matches the weight on a level surface with nothing else '
          'pushing. On a slope it is mg cos θ.',
    ),
    Mistake(
      'Counting the weight twice on a slope.',
      'Use either the weight or its two components, never both. The app '
          'draws the components on the ramp for this reason.',
    ),
  ],
);

const _freeFall = Lesson(
  id: 'free-fall',
  number: '01',
  mode: ExperimentMode.freeFall,
  title: 'Free fall',
  summary: 'Follow a flight and measure gravity with a ball and a phone.',
  why:
      'Gravity acts on everything around you, and free fall is the one place '
      'you can see it on its own. Heavy and light objects fall at the same '
      'rate once air resistance is small, the idea Galileo tested 400 years '
      'ago. Here you measure g yourself.',
  idea: [
    'Once the object leaves your hand, the only force that matters is its '
        'weight. So its acceleration points straight down and has the same '
        'size for every mass: g, about 9.81 m/s².',
    'Horizontal and vertical motion are independent. Sideways nothing '
        'pushes, so the horizontal velocity stays the same. Vertically, the '
        'velocity changes by 9.81 m/s every second. Together they trace a '
        'parabola.',
    'At the top of a throw the vertical velocity is zero for an instant, but '
        'the acceleration is still g, downward. That is the moment that '
        'surprises most people.',
  ],
  arrows: [
    ArrowNote(
      VectorKind.velocity,
      'Velocity',
      'Runs along the curved path. Its horizontal part keeps the same length, '
          'while its vertical part shrinks on the way up and grows on the way '
          'down.',
    ),
    ArrowNote(
      VectorKind.acceleration,
      'Acceleration',
      'Straight down and the same length for the whole flight, even at the '
          'very top.',
    ),
    ArrowNote(
      VectorKind.netForce,
      'Net force',
      'Equal to the weight, mg, straight down. Nothing else acts on the '
          'object in flight.',
    ),
    ArrowNote(
      VectorKind.component,
      'Forces',
      'In the air, weight is the only force, so it sits on top of the net '
          "force. Once the object rests on the floor, the floor's normal force "
          'appears and cancels it.',
    ),
  ],
  forces: [
    ForceNote(
      'Weight',
      'W = mg',
      'Pulls straight down the whole time. Doubling the mass doubles the '
          'weight, but also doubles the mass to accelerate, so g stays the '
          'same.',
    ),
    ForceNote(
      'Normal force',
      'F_N = mg',
      'Only while the object rests in your hand or on the floor. It balances '
          'the weight, so the net force and acceleration are zero.',
    ),
    ForceNote(
      'Air resistance',
      'F_{drag}',
      'Small for a dense ball. A sheet of paper falls slowly because drag '
          'grows to match its small weight.',
    ),
  ],
  equations: [
    LessonEquation(
      'a_y = −g',
      'The vertical acceleration is constant and downward. The minus sign '
          'means down, with up counted as positive.',
      [
        SymbolNote('a_y', 'Vertical acceleration'),
        SymbolNote('g', 'Gravitational acceleration, 9.81 m/s²'),
      ],
    ),
    LessonEquation(
      'v_y = v_{0y} − gt',
      'The vertical velocity drops by the same amount every second.',
      [
        SymbolNote('v_{0y}', 'Vertical velocity at release'),
        SymbolNote('t', 'Time since release, in seconds'),
      ],
    ),
    LessonEquation(
      'y = y_0 + v_{0y}t − ½gt²',
      'Height over time is a parabola.',
      [SymbolNote('y_0', 'Height at release')],
    ),
    LessonEquation(
      'x = x_0 + v_{0x}t',
      'Horizontal position changes at a steady rate.',
      [SymbolNote('v_{0x}', 'Horizontal velocity, which never changes')],
    ),
  ],
  equipment: [
    'A small, dense ball, such as a tennis ball or a bouncy ball',
    'A ruler or tape measure to set the scale',
    'A plain wall behind the flight that contrasts with the ball',
    'A steady place for the phone, such as a stack of books',
  ],
  steps: [
    'Prop the phone up so the whole flight fits in the picture, and keep it '
        'level and still.',
    'Hold the ruler where the ball will fly, at the same distance from the '
        'camera, and drag both ends of the line onto it.',
    'Tap the ball to mark it, check that the box fits, and confirm.',
    'Enter the mass if you know it. It changes the forces, not the motion.',
    'Start the experiment, then drop or toss the ball across the picture.',
  ],
  expect: [
    'An acceleration close to 9.81 m/s², downward, while the ball is in the '
        'air. The theory check averages only the falling frames.',
    'Within 5 to 10 percent is a good run. Motion blur, a tilted phone and a '
        'ruler out of line with the ball all add error.',
    'In a toss, the horizontal speed barely changes from start to end.',
  ],
  mistakes: [
    Mistake(
      'Holding the ruler closer to the camera than the ball.',
      'Things look bigger closer to the lens. Hold the ruler in the plane '
          'the ball moves in, or every speed comes out off by the same factor.',
    ),
    Mistake(
      'Tilting the phone.',
      'Down in the picture is then not down in the world, and part of g '
          'shows up as sideways acceleration. Level the phone first.',
    ),
    Mistake(
      'Thinking heavier objects fall faster.',
      'Weight grows with mass, but so does the mass to accelerate. They '
          'cancel, so g is the same for both.',
    ),
    Mistake(
      'Expecting zero acceleration at the top.',
      'The velocity is zero there for an instant. The acceleration never '
          'stops being g.',
    ),
  ],
);

const _ramp = Lesson(
  id: 'ramp',
  number: '02',
  mode: ExperimentMode.ramp,
  title: 'Inclined ramp',
  summary: 'Split gravity into parts and meet the normal force and friction.',
  why:
      'A ramp slows gravity down enough to measure, which is exactly how '
      'Galileo studied falling. Slopes are everywhere, from roads and slides '
      'to wheelchair ramps. They are also the classic place to learn how to '
      'split a force into components, and to see the normal force and '
      'friction at work.',
  idea: [
    'Gravity pulls straight down, but the object can only move along the '
        'surface. So split the weight in two: mg sin θ pulls along the slope, '
        'and mg cos θ presses into it.',
    'The ramp pushes back with a normal force that cancels the part pressing '
        'into it exactly. That is why the object neither sinks into the ramp '
        'nor lifts off.',
    'Along the slope, friction acts uphill, against the sliding. What is '
        'left over sets the acceleration. For a sliding block that is '
        'a = g(sin θ − μ cos θ).',
    'A rolling ball is different. Part of its energy goes into spinning, so '
        'a solid ball speeds up at only 5/7 of the frictionless rate. '
        'Friction at the contact point makes it roll instead of skid, and '
        'takes no energy away.',
  ],
  arrows: [
    ArrowNote(
      VectorKind.velocity,
      'Velocity',
      'Points down the slope, along the surface, and grows steadily.',
    ),
    ArrowNote(
      VectorKind.acceleration,
      'Acceleration',
      'Also along the slope, and constant. It is shorter than g, because '
          'only part of gravity acts along the ramp.',
    ),
    ArrowNote(
      VectorKind.netForce,
      'Net force',
      'Down the slope. The parts across the slope cancel, so nothing is left '
          'pushing into the ramp.',
    ),
    ArrowNote(
      VectorKind.component,
      'Components and contact forces',
      'The two parts of the weight, the normal force out of the surface, and '
          'friction pointing up the slope.',
    ),
  ],
  forces: [
    ForceNote(
      'Weight along the slope',
      'W_∥ = mg sin θ',
      'The part of gravity that drives the motion. It grows as the ramp gets '
          'steeper, up to the full weight at 90°.',
    ),
    ForceNote(
      'Weight into the slope',
      'W_⊥ = mg cos θ',
      'The part of gravity pressing the object into the ramp. It does not '
          'move the object, but it sets how hard the surfaces press together.',
    ),
    ForceNote(
      'Normal force',
      'F_N = mg cos θ',
      'Perpendicular to the ramp, pointing out of it. It is smaller than the '
          'weight and shrinks as the ramp gets steeper, reaching zero at 90°.',
    ),
    ForceNote(
      'Friction',
      'f = μF_N',
      'On a sliding block it points up the slope, against the motion. Since '
          'the normal force shrinks on steeper ramps, so does friction.',
    ),
    ForceNote(
      'Rolling grip',
      'f_s',
      'Static friction at the contact point spins a ball up as it rolls. It '
          'does no work, but the spin takes a share of the energy, which is '
          'why a ball is slower than a frictionless block.',
    ),
  ],
  equations: [
    LessonEquation(
      'a = g(sin θ − μ cos θ)',
      'A block sliding down with kinetic friction.',
      [
        SymbolNote('θ', 'Angle of the ramp from level'),
        SymbolNote('μ', 'Coefficient of kinetic friction, with no unit'),
      ],
    ),
    LessonEquation(
      'a = 5/7 g sin θ',
      'A solid ball rolling without slipping.',
      [SymbolNote('5/7', 'The share of its energy that moves it forward')],
    ),
    LessonEquation(
      'F_N = mg cos θ',
      'The normal force on the slope, for any object.',
    ),
    LessonEquation(
      'μ = tan θ − a / (g cos θ)',
      'The first equation turned around. A measured acceleration gives you '
          'the friction coefficient, which is how the app reports μ.',
    ),
  ],
  equipment: [
    'A board, shelf or large book propped up as a ramp',
    'A ball to roll, or a small block to slide',
    'A ruler to set the scale',
    'A protractor, only if you want to check the angle the app measures',
  ],
  steps: [
    'Prop the ramp at 10° to 30°. Steeper runs are fast and blur.',
    'Put the phone to the side, square to the ramp, so the ramp runs across '
        'the picture.',
    'Hold the ruler against the side of the ramp to set the scale.',
    'Mark the ball or block and confirm the box.',
    'Start, then release the object from rest near the top. In the '
        'measurement panel, choose rolling ball or sliding block so the '
        'prediction uses the right model.',
  ],
  expect: [
    'At 20°, a rolling ball accelerates at about 2.4 m/s², while a '
        'frictionless block would reach 3.4 m/s².',
    'The angle comes from the picture. If the numbers look off, check it '
        'with a protractor.',
    'A sliding block comes in under g sin θ. The gap is friction, and the app '
        'reports the μ that explains it.',
  ],
  mistakes: [
    Mistake(
      'Using g sin θ for a rolling ball.',
      'That formula assumes nothing spins. A rolling ball is about 30 '
          'percent slower, so choose rolling ball in the panel.',
    ),
    Mistake(
      'Thinking the normal force equals mg.',
      'On a slope it is mg cos θ. Only on level ground is it the full weight.',
    ),
    Mistake(
      'Drawing friction down the slope.',
      'Friction opposes the sliding, so for an object moving down it points '
          'up the slope.',
    ),
    Mistake(
      'Filming the ramp at an angle.',
      'If the camera is not square to the ramp, the angle in the picture is '
          'not the real one, and every prediction shifts with it.',
    ),
  ],
);

const _pendulum = Lesson(
  id: 'pendulum',
  number: '03',
  mode: ExperimentMode.pendulum,
  title: 'Pendulum',
  summary: 'Watch tension, gravity and energy trade places in every swing.',
  why:
      'Pendulums kept the world on time for nearly three centuries, because '
      'a swing takes about the same time whether it is wide or narrow. They '
      'are also the clearest picture of energy changing form: height becomes '
      'speed and speed becomes height, over and over.',
  idea: [
    'The bob moves on a circle around the pivot. Two forces act on it: its '
        'weight, straight down, and the tension in the string, pulling toward '
        'the pivot.',
    'Split the weight along the string and across it. The part across it, '
        'mg sin θ, pulls the bob back toward the bottom. That restoring force '
        'is what makes it swing.',
    'Along the string, tension does more than hold up the weight. It also '
        'supplies the inward pull that keeps the bob on its circle, mv²/L. So '
        'tension is largest at the bottom, where the bob is fastest.',
    'For small swings, the time for one full swing depends only on the '
        'string length and g. Mass and the width of the swing barely matter.',
    'Energy trades back and forth: all potential at the ends, all kinetic at '
        'the bottom. A little is lost to the air and the pivot each swing, so '
        'the swing slowly shrinks.',
  ],
  arrows: [
    ArrowNote(
      VectorKind.velocity,
      'Velocity',
      'Along the arc. Longest at the bottom, and zero at each end of the '
          'swing.',
    ),
    ArrowNote(
      VectorKind.acceleration,
      'Acceleration',
      'Never zero. At the ends it points along the arc, back toward the '
          'middle. At the bottom it points straight up at the pivot, because '
          'the bob is turning.',
    ),
    ArrowNote(
      VectorKind.netForce,
      'Net force',
      'Follows the acceleration. At the bottom it is the extra tension that '
          'keeps the bob on its circle.',
    ),
    ArrowNote(
      VectorKind.component,
      'Forces',
      'Weight straight down, and tension along the string. Their sum is the '
          'net force.',
    ),
  ],
  forces: [
    ForceNote(
      'Weight',
      'W = mg',
      'Straight down, always the same size. Its part across the string '
          'drives the swing.',
    ),
    ForceNote(
      'Tension',
      'F_T = mg cos θ + mv²/L',
      'Along the string, toward the pivot. It changes through the swing: '
          'smallest at the ends, largest at the bottom.',
    ),
    ForceNote(
      'Restoring force',
      'mg sin θ',
      'The part of the weight across the string. The further out the bob, '
          'the harder it pulls back to the middle.',
    ),
    ForceNote(
      'Damping',
      'F_{drag}',
      'Air drag and friction at the pivot take a little energy every swing, '
          'so the swing narrows over time.',
    ),
  ],
  equations: [
    LessonEquation(
      'T = 2π √(L / g)',
      'The period for small swings, up to about 20°.',
      [
        SymbolNote('T', 'Period, the time for one full swing there and back'),
        SymbolNote('L', 'Length from the pivot to the centre of the bob'),
      ],
    ),
    LessonEquation(
      'F_T − mg cos θ = mv²/L',
      'Along the string, tension minus the weight component is the inward '
          'force that keeps the bob on its circle.',
      [
        SymbolNote('F_T', 'Tension in the string, in newtons'),
        SymbolNote('θ', 'Angle of the string from straight down'),
      ],
    ),
    LessonEquation(
      'mgh = ½mv²',
      'The height the bob drops turns into speed at the bottom.',
      [SymbolNote('h', 'Height of the release point above the bottom')],
    ),
  ],
  equipment: [
    'A string 30 cm to 1 m long',
    'A small, heavy bob, such as a nut, a key ring or a fishing weight',
    'Something solid to tie it to that will not move',
    'A ruler to set the scale and measure the string',
  ],
  steps: [
    'Hang the bob and let it settle. Measure from the pivot to the centre of '
        'the bob.',
    'Put the phone square to the swing, with the pivot and the whole swing '
        'in the picture.',
    'Hold the ruler in the plane of the swing to set the scale.',
    'Mark the bob and confirm the box.',
    'Pull it aside 15° to 20° and let go without pushing. Start the '
        'experiment and let it swing at least twice.',
  ],
  expect: [
    'A 0.45 m string gives a period near 1.35 s. The app works out the '
        'pivot and string length from the swing itself.',
    'The theory check times whole swings, so give it at least two.',
    'Wide swings run a little slow. At 30° the real period is almost 2 '
        'percent longer than the formula.',
  ],
  mistakes: [
    Mistake(
      'Measuring only the string.',
      'L runs from the pivot to the centre of the bob. Leaving out half the '
          'bob makes the predicted period too short.',
    ),
    Mistake(
      'Thinking a heavier bob swings faster.',
      'Mass cancels, just as in free fall. Only the length and g set the '
          'period.',
    ),
    Mistake(
      'Thinking tension equals the weight.',
      'Only when it hangs still. While swinging, tension is larger at the '
          'bottom and smaller at the ends.',
    ),
    Mistake(
      'Thinking the acceleration is zero at the bottom.',
      'The speed stops changing there for an instant, but the direction does '
          'not. The acceleration points up at the pivot.',
    ),
    Mistake(
      'Releasing with a push or a twist.',
      'A push adds energy, and a twist sends the bob round in an oval that '
          'the camera sees as a shorter swing.',
    ),
  ],
);

const _collision = Lesson(
  id: 'collision',
  number: '04',
  mode: ExperimentMode.collision,
  title: 'Collision',
  summary: 'Trace momentum through an impact and see where the energy goes.',
  why:
      'Car safety, sport, rocket launches and particle physics all rest on '
      'one rule: in a collision, the total momentum does not change. It works '
      'even when you know nothing about the forces during the impact, which '
      'makes it one of the most useful laws in physics.',
  idea: [
    'Momentum is mass times velocity, p = mv. It is a vector, so direction '
        'matters: with right as positive, an object moving left has negative '
        'momentum.',
    'During the impact the two objects push on each other with equal and '
        'opposite forces, for the same short time. So whatever momentum one '
        'gains, the other loses, and the total stays the same.',
    'Force times time is called impulse, and it equals the change in '
        'momentum. Crumple zones and airbags make the impact last longer, so '
        'the force is smaller for the same change.',
    'Kinetic energy is different. A perfectly elastic collision keeps it, '
        'but a real one turns some into sound, heat and bending. The '
        'coefficient of restitution measures how bouncy the impact was.',
  ],
  arrows: [
    ArrowNote(
      VectorKind.velocity,
      'Velocity',
      'Before the impact, only the rolled object has one. Afterwards, the '
          'arrows show how the motion was shared out.',
    ),
    ArrowNote(
      VectorKind.acceleration,
      'Acceleration',
      'Almost zero while the objects roll freely, then a sharp spike during '
          'the impact, pointing away from the other object.',
    ),
    ArrowNote(
      VectorKind.netForce,
      'Net force',
      'The contact push during the impact. It is equal and opposite on the '
          "two objects, which is Newton's third law.",
    ),
    ArrowNote(
      VectorKind.component,
      'Forces',
      "Weight and the table's normal force cancel vertically. Between "
          'impacts, rolling friction slowly slows each object.',
    ),
  ],
  forces: [
    ForceNote(
      'Contact force',
      'F_{12} = −F_{21}',
      'Each object pushes on the other just as hard, in opposite directions, '
          'for exactly the same time.',
    ),
    ForceNote(
      'Impulse',
      'J = FΔt = Δp',
      'The total push of the impact. The same impulse changes the velocity '
          'of a light object more than a heavy one.',
    ),
    ForceNote(
      'Weight and normal force',
      'F_N = mg',
      'They cancel on a level table, so they do not change the horizontal '
          'momentum.',
    ),
    ForceNote(
      'Rolling friction',
      'f',
      'A force from outside the two objects, so it slowly drains momentum. '
          'Comparing just before and just after the impact keeps its effect '
          'small.',
    ),
  ],
  equations: [
    LessonEquation(
      'm_1u_1 + m_2u_2 = m_1v_1 + m_2v_2',
      'Total momentum before the impact equals total momentum after.',
      [
        SymbolNote('m_1, m_2', 'Masses of the two objects'),
        SymbolNote('u_1, u_2', 'Velocities before the impact'),
        SymbolNote('v_1, v_2', 'Velocities after the impact'),
      ],
    ),
    LessonEquation('p = mv', 'Momentum of one object, in kg m/s.'),
    LessonEquation(
      'e = (v_2 − v_1) / (u_1 − u_2)',
      'Coefficient of restitution: how fast they separate over how fast they '
          'approached. 1 is perfectly elastic, 0 means they stick together.',
    ),
  ],
  equipment: [
    'Two balls or toy cars on a smooth, level table',
    'A ruler to set the scale',
    'A kitchen scale, if you want real masses',
  ],
  steps: [
    'Place the phone so both objects and their whole path are in the '
        'picture.',
    'Lay the ruler along the path and set the scale.',
    'Mark the object you will roll first, then mark the object it will hit.',
    'Enter the mass. Weigh the objects if you can.',
    'Start, then roll the first object gently into the second.',
  ],
  expect: [
    'Total momentum after the impact within about 10 percent of before. The '
        'theory check compares the two.',
    'A coefficient of restitution between about 0.5 and 0.9 for most balls '
        'and toy cars.',
    'Less kinetic energy after than before. The rest became sound, heat and '
        'bending.',
  ],
  mistakes: [
    Mistake(
      'Forgetting that momentum has a direction.',
      'An object that bounces back has negative momentum. Adding speeds '
          'instead of velocities makes momentum seem to appear from nowhere.',
    ),
    Mistake(
      'Expecting kinetic energy to be conserved too.',
      'Momentum always is, when nothing outside pushes. Kinetic energy is '
          'only kept in a perfectly elastic collision.',
    ),
    Mistake(
      'Thinking the heavier object pushes harder.',
      'The forces are equal and opposite. The lighter object just changes '
          'velocity more, because the same impulse moves less mass.',
    ),
    Mistake(
      'Rolling too fast.',
      'Fast objects blur, and the impact can fall between frames. A gentle '
          'roll tracks cleanly.',
    ),
  ],
);
