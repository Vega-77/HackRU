# HandsOn Physics app (Flutter)

The phone side of HandsOn Physics. The camera watches an experiment, frames
stream to the backend over a WebSocket, and the app draws the physics it gets
back (velocity, acceleration, forces) over the live picture, with charts and
energy bars underneath.

The message format between app and backend is in
[`../docs/protocol.md`](../docs/protocol.md). Change it there first, then in
`lib/models/`.

## Run it

You need Flutter 3.47 or newer on the stable channel (`flutter --version`;
update with `flutter upgrade`). Then, from `mobile/`:

```bash
flutter pub get
```

### In Chrome (any laptop, no phone needed)

```bash
flutter run -d chrome
```

The app starts in **demo mode**: simulated experiments, no camera or backend.
To see a phone-sized window, open Chrome DevTools and turn on the device
toolbar (iPhone 12/13/14 is 390 x 844).

### On an iPhone (needs a Mac)

1. Install Xcode from the App Store and open it once to accept the licence.
2. On the iPhone, turn on Settings > Privacy & Security > Developer Mode, and
   plug it into the Mac.
3. Open `ios/Runner.xcworkspace` in Xcode. Under Runner > Signing &
   Capabilities, pick your personal team (a free Apple ID works). If the
   bundle id `edu.hackru.handsOnPhysics` is taken, add your initials to it.
4. From `mobile/`, run:

   ```bash
   flutter run
   ```

5. The first time, trust the developer on the phone: Settings > General >
   VPN & Device Management.

### Against the backend

1. Put the laptop running the backend and the phone on the **same Wi-Fi**.
2. Find the laptop's IP (`ipconfig` on Windows, `ipconfig getifaddr en0` on
   a Mac).
3. In the app, open Settings, choose **Live backend**, and enter
   `ws://<that IP>:8000/ws/frames`. Press **Test connection**.

To set the address at build time instead:

```bash
flutter run --dart-define=BACKEND_URL=ws://192.168.1.20:8000/ws/frames --dart-define=DEMO_MODE=false
```

The backend's own README (`../backend/README.md`) says how to start it. To
try the app without it, `tool/mock_server.py` speaks the same protocol on the
same port and path and sends back a made-up trajectory:

```bash
pip install websockets
python tool/mock_server.py
```

## Check your work

```bash
dart format lib test
```

```bash
flutter analyze
```

```bash
flutter test
```

The live test streams a drawn red ball to a running backend, and checks that
it finds the ball and measures its speed. It is skipped unless you give it an
address:

```bash
LIVE_BACKEND_URL=ws://localhost:8000/ws/frames flutter test test/integration
```

Against the mock server, add `LIVE_BACKEND_MOCK=1`. The mock ignores the
image, so only the connection checks run.

## How the code is laid out

Each layer only uses the layers below it in this list, so you can read the
app from the bottom up.

| Folder | What lives there |
|---|---|
| `lib/models/` | Plain Dart types that mirror `docs/protocol.md`: `PhysicsState`, `SessionConfig`, `Calibration`, `Vec2`. No Flutter. |
| `lib/services/camera/` | `FrameSource`: start the camera, grab a JPEG frame, show a preview. One version for iOS (`native_`), one for Chrome (`web_`). |
| `lib/services/network/` | `PhysicsSocket` (the WebSocket client, with reconnect and flow control) and `MockPhysics` (the demo data). |
| `lib/state/` | Riverpod controllers: experiment settings, calibration, the running session, and the rolling telemetry buffer for charts. |
| `lib/features/` | One folder per screen: `home`, `calibration`, `experiment`, `settings`. Screen-only widgets sit in each `widgets/`. |
| `lib/core/` | App-wide pieces: config constants, routes, theme tokens, icons. |
| `test/` | Mirrors `lib/`. `test/widgets/app_flow_test.dart` clicks through the whole demo flow at iPhone size. |

### What happens when you press Start

1. `SessionController.start()` builds a `SessionConfig` from the settings and
   calibration, and opens a `PhysicsSocket` (or `MockPhysics` in demo mode).
2. In live mode, it grabs a camera frame about 15 times a second, keeping at
   most 2 frames waiting for an answer, so the picture never lags behind.
3. Each `state` message from the backend lands in `SessionState.latest` and
   in the `TelemetryBuffer`.
4. `ExperimentStage` maps the backend's frame pixels to screen pixels
   (`CoordinateMapper`), eases the arrows towards the new values
   (`OverlayFrame`), and paints them (`VectorOverlayPainter`).

## Design rules

- Colour means a physical quantity, and only that: velocity green,
  acceleration red, forces blue and yellow. Everything else is neutral.
  The colours live in `lib/core/theme/tokens.dart`; never hard-code one.
- One type family (Archivo). Physics symbols are italic, like a textbook.
- Panels use a 14 px radius, buttons and chips are full pills.
- Copy is sentence case, says what happens ("Start experiment", not
  "Submit"), and avoids em dashes.
- Every animation checks `MediaQuery.disableAnimations`.
