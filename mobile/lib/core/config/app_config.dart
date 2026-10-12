/// App-wide constants. Values the user can change at runtime (backend URL,
/// mass) start from here and live in `state/experiment_settings.dart`.
abstract final class AppConfig {
  static const String appVersion = '0.1.0';
  static const String protocolVersion = 'v0.3';

  /// Default backend WebSocket URL: the team's backend on Render (see
  /// `render.yaml` at the repo root). Override at build time with
  /// `flutter run --dart-define=BACKEND_URL=ws://192.168.1.20:8000/ws/frames`.
  static const String defaultBackendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: 'wss://handson-physics-backend.onrender.com/ws/frames',
  );

  // Frame streaming, see docs/protocol.md.
  static const int targetFps = 30;
  static const int frameWidth = 320;
  static const double jpegQuality = 0.7;
  static const int initialFramesInFlight = 2;
  static const int maxFramesInFlight = 32;

  /// The camera runs faster than frames are sent. At 60 fps no exposure is
  /// longer than 1/60 s, so a fast object smears less, and each frame sent
  /// is at most 17 ms old. Cameras that can't do 60 use their fastest rate.
  static const int captureFps = 60;

  static const bool showRecordingUi = bool.fromEnvironment('SHOW_RECORDING_UI');

  static const Duration frameTimeout = Duration(seconds: 1);
  static const Duration observationExpiry = Duration(seconds: 1);
  static const Duration reconnectDelay = Duration(seconds: 2);

  /// How long an opened camera may take to deliver its first picture before
  /// setup says so, instead of waiting on a blank stage.
  static const Duration cameraFirstFrameTimeout = Duration(seconds: 6);

  // Experiment defaults.
  static const double defaultMassKg = 0.1;
  static const double defaultRulerLengthM = 0.30;

  /// How much history the telemetry charts keep.
  static const Duration telemetryWindow = Duration(seconds: 10);
}
