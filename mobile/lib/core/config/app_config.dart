/// App-wide constants. Values the user can change at runtime (backend URL,
/// demo mode) start from here and live in `state/experiment_settings.dart`.
abstract final class AppConfig {
  /// Default backend WebSocket URL. Override at build time with
  /// `flutter run --dart-define=BACKEND_URL=ws://192.168.1.20:8000/ws/frames`.
  static const String defaultBackendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'ws://localhost:8000/ws/frames',
  );

  /// Start in demo mode (synthetic data, no backend) unless told otherwise.
  static const bool startInDemoMode = bool.fromEnvironment(
    'DEMO_MODE',
    defaultValue: true,
  );

  // Frame streaming, see docs/protocol.md.
  static const int targetFps = 15;
  static const int frameWidth = 320;
  static const double jpegQuality = 0.7;
  static const int maxFramesInFlight = 2;
  static const Duration frameTimeout = Duration(seconds: 1);
  static const Duration reconnectDelay = Duration(seconds: 2);

  // Experiment defaults.
  static const double defaultMassKg = 0.1;
  static const double defaultRulerLengthM = 0.30;

  /// How much history the telemetry charts keep.
  static const Duration telemetryWindow = Duration(seconds: 10);
}
