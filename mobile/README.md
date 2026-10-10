# HandsOn Physics app (Flutter)

The phone side of HandsOn Physics. The camera watches an experiment, frames
stream to the backend over a WebSocket, and the app draws the physics it gets
back (velocity, acceleration, forces) over the live picture, with charts and
energy bars underneath.

The message format between app and backend is in
[`../docs/protocol.md`](../docs/protocol.md). Change it there first, then in
`lib/models/`.

## Open it

**[vega-77.github.io/HackRU](https://vega-77.github.io/HackRU/)** runs the
latest `main` in any browser, nothing to install. It streams the camera to
the hosted backend: open the link and allow camera access. It is rebuilt
each time `main` changes (`../.github/workflows/deploy-web.yml`).

## Run it

To work on the app, you need Flutter 3.47 or newer on the stable channel (`flutter --version`;
update with `flutter upgrade`). Then, from `mobile/`:

```bash
flutter pub get
```

### In Chrome (any laptop, no phone needed)

```bash
flutter run -d chrome
```

It streams the laptop's webcam to the hosted backend (see
[Against the backend](#against-the-backend)). To see a phone-sized window, open Chrome DevTools and turn on the device
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

The backend is hosted on Render (`../render.yaml`), and the app streams to
it by default. Opening Settings tests the connection straight away. Nothing
to run on a laptop.

- If nobody has used it for 15 minutes the server is asleep, and the first
  connection takes up to a minute. The app waits and says so.
- The iOS Simulator and laptops without a webcam have no camera. The app
  then streams a test video instead: a red ball swinging on a string, which
  the backend tracks like a real one.

To deploy it the first time (one teammate, once): sign in to
[render.com](https://render.com) with GitHub, choose New > Blueprint, and
pick this repo. If the URL Render gives is not
`handson-physics-backend.onrender.com`, update `defaultBackendUrl` in
`lib/core/config/app_config.dart`.

To use a backend on a laptop instead:

1. Put the laptop running the backend and the phone on the **same Wi-Fi**.
2. Find the laptop's IP (`ipconfig` on Windows, `ipconfig getifaddr en0` on
   a Mac).
3. In Settings, enter `ws://<that IP>:8000/ws/frames`. Press **Test connection**. **Use the
   hosted backend** switches back.

To set the address at build time instead:

```bash
flutter run --dart-define=BACKEND_URL=ws://192.168.1.20:8000/ws/frames
```

The backend's own README (`../backend/README.md`) says how to start it. To
work on the app without it, `tool/mock_server.py` speaks the same protocol on
the same port and path and sends back a made-up trajectory. Point Settings at
`ws://localhost:8000/ws/frames`:

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

## Debug log

The app keeps a hidden log of what it does, so you can see what happened
when an experiment goes wrong. To get it, press the copy button in the
experiment screen's top bar, or "Copy log" on a backend error banner, or
"Copy debug log" in Settings. Then paste it into chat or an issue. Settings
also shows how many entries there are, and "Clear" empties it.

Each line has the time, the seconds since the experiment started, a level
(`D` detail, `I` info, `W` warning, `E` error), the method and `file:line`
that logged it, then the message:

```text
14:02:07.415 +3.204s I SessionController._sendConfig (state/session_controller.dart:512) Config (session start): {"type":"config",...}
```

A web release build minifies method names, so there the caller shows as
`?`. Debug builds and the iPhone show it in full.

The copy starts with the app and protocol versions, the platform, and the
current backend, mode, mass and calibration. Each experiment starts with a
`======== Session N ========` line. It logs the camera and connection
opening and closing, every config sent, every frame sent and every reply
(with round trip and backend time), backend errors with where they
happened, tracking found and lost, setup and settings changes, screens
opened, uncaught errors and anything printed. It keeps the last 20,000
lines, about eleven minutes of an experiment. In `flutter run` and the
Xcode console the same lines are printed as they happen.

## How the code is laid out

Each layer only uses the layers below it in this list, so you can read the
app from the bottom up.

| Folder | What lives there |
|---|---|
| `lib/models/` | Plain Dart types that mirror `docs/protocol.md`: `PhysicsState`, `SessionConfig`, `Calibration`, `Vec2`. No Flutter. |
| `lib/services/camera/` | `FrameSource`: start the camera, grab a JPEG frame, show a preview. One version for iOS (`native_`), one for Chrome (`web_`), and a drawn test video (`test_video_`) for devices with no camera. |
| `lib/services/network/` | `PhysicsSocket`: the WebSocket client, with reconnect and flow control. |
| `lib/state/` | Riverpod controllers: experiment settings, calibration, the running session, and the rolling telemetry buffer for charts. |
| `lib/features/` | One folder per screen: `home`, `calibration`, `experiment`, `settings`. Screen-only widgets sit in each `widgets/`. The moving diagrams on the home screen (`PreviewPhysics`) only illustrate each experiment; every measurement comes from the backend. |
| `lib/core/` | App-wide pieces: config constants, routes, theme tokens, icons. |
| `test/` | Mirrors `lib/`. `test/widgets/app_flow_test.dart` clicks through the whole flow at iPhone size, with a fake camera. |

### What happens when you press Start

1. `SessionController.start()` opens the camera, builds a `SessionConfig`
   from the settings and calibration, and opens a `PhysicsSocket`.
2. It grabs a camera frame about 15 times a second, keeping at
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
