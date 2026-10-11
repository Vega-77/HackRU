import '../../../models/experiment_mode.dart';

class Investigation {
  const Investigation(
    this.mode,
    this.number,
    this.description,
    this.equation,
    this.conditions,
    this.concepts,
    this.question,
  );
  final ExperimentMode mode;
  final String number, description, equation, conditions, concepts, question;
  static const all = [
    Investigation(
      ExperimentMode.freeFall,
      '01',
      'Follow a flight. Reveal gravity.',
      'a_y = −g',
      'Projectile · no air resistance',
      'Trajectory / velocity / gravity',
      'What changes during a flight?',
    ),
    Investigation(
      ExperimentMode.ramp,
      '02',
      'Resolve gravity along a slope.',
      'a = g(sin θ − μ cos θ)',
      'θ = 25° · μ = 0.15',
      'Components / friction / acceleration',
      'How does a slope change motion?',
    ),
    Investigation(
      ExperimentMode.pendulum,
      '03',
      'Watch energy move through a swing.',
      'T − mg cos θ = mv²/L',
      'L = 0.45 m · release = 35° · no damping',
      'Oscillation / tension / energy',
      'Where does a swing gain speed?',
    ),
    Investigation(
      ExperimentMode.collision,
      '04',
      'Trace momentum through an impact.',
      'm₁u₁ + m₂u₂ = m₁v₁ + m₂v₂',
      'Elastic impact · m₂ = 2m₁ · rolling friction',
      'Momentum / impulse / transfer',
      'Where does momentum go?',
    ),
  ];
  static Investigation forMode(ExperimentMode mode) =>
      all.firstWhere((item) => item.mode == mode);
}
