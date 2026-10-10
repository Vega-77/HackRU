import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/logging/debug_log.dart';
import '../models/experiment_mode.dart';

/// What the user has chosen for the current experiment: mode, mass, which
/// vectors to draw, and which backend measures it.
class ExperimentSettings {
  const ExperimentSettings({
    this.mode = ExperimentMode.ramp,
    this.massKg = AppConfig.defaultMassKg,
    this.showVelocity = true,
    this.showAcceleration = true,
    this.showForces = true,
    this.backendUrl = AppConfig.defaultBackendUrl,
  });

  final ExperimentMode mode;
  final double massKg;
  final bool showVelocity;
  final bool showAcceleration;
  final bool showForces;
  final String backendUrl;

  ExperimentSettings copyWith({
    ExperimentMode? mode,
    double? massKg,
    bool? showVelocity,
    bool? showAcceleration,
    bool? showForces,
    String? backendUrl,
  }) => ExperimentSettings(
    mode: mode ?? this.mode,
    massKg: massKg ?? this.massKg,
    showVelocity: showVelocity ?? this.showVelocity,
    showAcceleration: showAcceleration ?? this.showAcceleration,
    showForces: showForces ?? this.showForces,
    backendUrl: backendUrl ?? this.backendUrl,
  );
}

class ExperimentSettingsController extends Notifier<ExperimentSettings> {
  @override
  ExperimentSettings build() => const ExperimentSettings();

  void setMode(ExperimentMode mode) {
    state = state.copyWith(mode: mode);
    log.i('Mode set to ${mode.wireName}');
  }

  /// Mass is clamped to a sensible tabletop range: 1 g to 10 kg.
  void setMass(double kg) {
    state = state.copyWith(massKg: kg.clamp(0.001, 10.0));
    log.i('Mass set to ${state.massKg} kg');
  }

  void toggleVelocity() {
    state = state.copyWith(showVelocity: !state.showVelocity);
    log.i('Velocity arrows ${state.showVelocity ? 'on' : 'off'}');
  }

  void toggleAcceleration() {
    state = state.copyWith(showAcceleration: !state.showAcceleration);
    log.i('Acceleration arrows ${state.showAcceleration ? 'on' : 'off'}');
  }

  void toggleForces() {
    state = state.copyWith(showForces: !state.showForces);
    log.i('Force arrows ${state.showForces ? 'on' : 'off'}');
  }

  void setBackendUrl(String url) {
    state = state.copyWith(backendUrl: url.trim());
    log.i('Backend set to ${state.backendUrl}');
  }
}

final experimentSettingsProvider =
    NotifierProvider<ExperimentSettingsController, ExperimentSettings>(
      ExperimentSettingsController.new,
    );
