/// The four experiments the app supports.
///
/// [wireName] is the exact string used in `docs/protocol.md`.
enum ExperimentMode {
  freeFall('free_fall', 'Free fall'),
  ramp('ramp', 'Inclined ramp'),
  pendulum('pendulum', 'Pendulum'),
  collision('collision', 'Collision');

  const ExperimentMode(this.wireName, this.label);

  final String wireName;
  final String label;

  static ExperimentMode fromWire(String value) =>
      ExperimentMode.values.firstWhere(
        (m) => m.wireName == value,
        orElse: () => ExperimentMode.ramp,
      );
}
