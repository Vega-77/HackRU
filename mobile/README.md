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

### On an iPhone from Windows (no Mac)

GitHub builds the app on a Mac for every change to `mobile/ios` on Dev1
(the "iOS build" workflow). To build the latest code, open Actions > iOS
build > Run workflow and pick Dev1.

1. Open the finished run and download the `HandsOnPhysics-ios-...`
   artifact. Unzip it to get `HandsOnPhysics-unsigned.ipa`.
2. Install Apple Devices (or iTunes) from the Microsoft Store, so Windows
   can see the phone, and install Sideloadly from sideloadly.io.
3. Plug in the iPhone and tap Trust on it. In Sideloadly, pick the `.ipa`,
   enter your Apple ID, and press Start.
4. On the iPhone, turn on Settings > Privacy & Security > Developer Mode,
   then trust your Apple ID under Settings > General > VPN & Device
   Management.

With a free Apple ID the app stops opening after 7 days. Install it again
to renew it. The same artifact has `HandsOnPhysics-simulator.zip`, which
runs in a browser simulator like Appetize.io: no camera or ARKit there, so
the app plays its test video.

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

#### Faster: a laptop on the same Wi-Fi

The hosted server is free, so it is slow: a frame takes 100 to 300 ms to
come back and the app gets 4 to 9 frames a second, which loses a ball
thrown at any real speed. A laptop on the same Wi-Fi answers in 20 to 40 ms
at the full 30 frames a second.

1. Put the laptop and the phone on the **same Wi-Fi**.
2. On the laptop, after the backend's setup (`../backend/README.md`), run
   this from `backend/`:

   ```bash
   python serve_lan.py
   ```

   It prints the address to use, like `ws://192.168.1.20:8000/ws/frames`.
3. In the app's Settings, enter that address (`192.168.1.20` on its own is
   enough) and press **Test connection**. **Use the hosted backend**
   switches back.

If the test fails:

- Open `http://192.168.1.20:8000/health` (with the laptop's address) in the
  phone's browser. If that fails too, the phone can't reach the laptop.
- On Windows, allow Python through the firewall on private networks, and
  set the Wi-Fi to Private (Settings > Network & internet).
- Venue Wi-Fi often keeps devices apart. Turn on Mobile Hotspot on the
  Windows laptop, join it from the phone, and use `192.168.137.1`.

This needs the iPhone app. The web app on GitHub Pages is an https page,
and browsers don't let one open an unencrypted `ws://` connection to
another computer, so Settings says so. Chrome on the laptop itself can use
`ws://localhost:8000/ws/frames`.

Wherever it can, the camera runs at 60 frames a second, and on iOS 16 or
newer the iPhone keeps each exposure to 1/120 s or less, so a moving ball
smears less. In a dim room the picture gets darker or grainier; more light
fixes that.

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
| `lib/models/` | Plain Dart types that mirror `docs/protocol.md`: `PhysicsState`, `SessionConfig`, `Calibration`, `Vec2`, `Vec3`, and the `ArVectorScene` sent to the native AR view. No Flutter. |
| `lib/services/camera/` | `FrameSource`: start the camera, grab a JPEG frame, show a preview. One version for iOS (`native_`), one for Chrome (`web_`), and a drawn test video (`test_video_`) for devices with no camera. |
| `lib/services/network/` | `PhysicsSocket`: the WebSocket client, with reconnect and flow control. |
| `lib/state/` | Riverpod controllers: experiment settings, calibration, the running session, and the rolling telemetry buffer for charts. |
| `lib/features/` | One folder per screen: `home`, `calibration`, `experiment`, `settings`. Screen-only widgets sit in each `widgets/`. The moving diagrams on the home screen (`PreviewPhysics`) only illustrate each experiment; every measurement comes from the backend. |
| `lib/core/` | App-wide pieces: config constants, routes, theme tokens, icons. |
| `test/` | Mirrors `lib/`. `test/widgets/app_flow_test.dart` clicks through the whole flow at iPhone size, with a fake camera. |

### What happens when you press Start

1. `SessionController.start()` opens the camera, builds a `SessionConfig`
   from the settings and calibration, and opens a `PhysicsSocket`.
2. It sends the newest camera frame up to 30 times a second (the camera
   itself runs at 60), keeping at most 4 frames waiting for an answer. The
   backend works on the newest frame only, so the picture never lags behind.
3. Each `state` message from the backend lands in `SessionState.latest` and
   in the `TelemetryBuffer`.
4. `ExperimentStage` maps the backend's frame pixels to screen pixels
   (`CoordinateMapper`), eases the arrows towards the new values
   (`OverlayFrame`), and paints them (`VectorOverlayPainter`).

### 3D arrows on an iPhone

With ARKit and a picked surface, the backend also sends `position_3d`,
`velocity_3d`, `acceleration_3d` and `forces_3d` in ARKit world metres.
Then the arrows are drawn in 3D instead of 2D:

1. `ArVectorLayer` turns each reply into an `ArVectorScene`
   (`ArVectorSceneBuilder`) and sends it over the `setVectors` channel
   method.
2. `ios/Runner/ArVectorNode.swift` draws each arrow as SceneKit nodes in
   the camera preview, anchored at the object. SceneKit redraws them from
   the live camera pose every screen refresh, so they stay on the object
   while the phone moves, and they glide between replies.
3. An invisible sphere the size of the ball (from its bounding box) sits
   at the anchor and fills only the depth buffer, so the real ball hides
   the parts of the arrows inside or behind it. Hands don't hide arrows:
   ARKit people occlusion adds work on every frame, and the build that
   had it lost the ball more often.
4. Between replies, `ios/Runner/ArObjectFollower.swift` tracks the ball
   on every camera frame with Vision's object tracker. Each reply's box
   (with the timestamp of the frame it describes) starts the tracker, or
   restarts it when the two disagree. The anchor and the sphere then sit
   where the ball is on the newest frame, not where the backend saw it a
   few frames ago, so the arrows stay centred on it while it moves. If the
   tracker loses the ball, the arrows glide back to the backend's position
   until the next reply.
5. The 2D overlay keeps the marker and trail, and stops drawing arrows.
   The marker follows the same on-device box (`ArVectorDisplay.followedBox`).

Lengths use the 2D proportions: every frame the native side scales the
arrows by the object's distance, so they look as long on screen as the 2D
overlay's, near or far. Shaft thickness is
`ArVectorSceneBuilder.radiusPerWidthPx`.

On Chrome, devices without ARKit, without a surface, or if the native side
fails, the 2D arrows are used as before.

## Design rules

- Colour means a physical quantity, and only that: velocity green,
  acceleration red, forces blue and yellow. Everything else is neutral.
  The colours live in `lib/core/theme/tokens.dart`; never hard-code one.
- One type family (Archivo). Physics symbols are italic, like a textbook.
- Panels use a 14 px radius, buttons and chips are full pills.
- Copy is sentence case, says what happens ("Start experiment", not
  "Submit"), and avoids em dashes.
- Every animation checks `MediaQuery.disableAnimations`.
