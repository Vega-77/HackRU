# Tracking and physics handoff, October 11, 2026

## Current status

Work continues on `devFour` from `d25fdde` (capture/physics WIP) and `f92e3f0` (foreground WIP). Both were present before editing. The implementation now has recorded-scene regressions, capture-time physics tests, simulated RTT coverage, browser camera coverage, and a local app for testing. **No physical-camera success is claimed. Do not merge or deploy before the user's camera verification.**

The pre-existing `mobile/ios/Runner.xcodeproj/project.pbxproj` edit, `.codex/`, `AGENTS.md`, and `.DS_Store` remain untouched and excluded from commits.

## Evidence recovered and corrections to the prior handoff

- Read both previous handoffs in full, inspected their commits and relevant current code. The five earlier recorded gray-ball tests still passed at baseline. Targeted backend baseline: 25 passed; standalone physics baseline: 22 passed.
- The previous handoff said `diagnostics/logs/ball_free_fall_log_3.txt` was empty. **It is now populated** (about 125 KB), copied at `2026-10-11T00:40:09.529`, using the remote Render backend. This new evidence supersedes that statement.
- Reviewed extracted camera regions from `Screen Recording 2026-10-11 at 12.38.05 AM.mov`, specifically selection, blurred release and the absent-ball shirt frame. The actual filename contains a narrow space before AM. The checked-in manifest identifies the source by SHA-256. This session inspected extracted images, not continuous playback of the entire recording.
- The screen reconstruction in `backend/tests/fixtures/gray_ball_oct11/` contains 27 frames, with 14 labeled visible-ball frames, nine labeled absent frames, three partially visible/unlabeled edge frames, and initialization. Its timestamps are screen-video timestamps, **not original camera capture timestamps**. Use it for identity regression, not as free-fall ground truth.
- Reconstructing the screen requires reversing `BoxFit.cover`; cropped-away areas are black. Calibration graphics were inpainted on the initialization frame, and live graphics remain. Raw backend JPEGs would be better evidence.

## Confirmed causes and limits

### 1. Throughput was limited by two outstanding frames

At RTT 600 ms, two outstanding frames permit at most 2 / 0.6 = 3.33 sends/s, even if CV is fast. `mobile/lib/services/network/physics_socket.dart:85` now sizes a bounded window from measured live RTT and the 30 FPS capture target, up to 32 frames. The backend retains a one-frame pending slot, so queued live frames still drop in favor of the newest received frame.

The newly available log supports the throughput diagnosis:

| Log session | State replies | Reported tracked replies | Capture-time update rate | Capture interval median / p95 | RTT median / p95 / max |
|---|---:|---:|---:|---|---|
| 1 | 99 | 47 | 5.29/s | 194 / 397 ms | 378 / 582.2 / 634 ms |
| 2 | 281 | 258 | 7.89/s | 100 / 307 ms | 180 / 569 / 895 ms |

Rates use first-to-last state capture timestamps, not elapsed UI session time (which includes pauses). `tracked` counts are the old backend's assertions, not verified identity counts. The log lacks backend process/queue timing, so RTT cannot be divided reliably into network and CV costs.

### 2. Tight selection and incomplete identity verification

The previous padded-ROI fallback in `backend/cv_engine/universal.py` remains intact. Tight boxes could cut the object at GrabCut's hard-background border and prevent creation of a round-object reference. The fallback keeps the original seed/selection while retrying with surrounding context, accepting only a verified round mask. It is exercised by the new production initialization regression.

The remaining false detection at `47.png` was a shirt/arm region, not the ball. `RoundReference.verify` accepted three supported quadrants even when the remaining quadrant contradicted the outline: foreground evidence was stronger outside that quarter of the proposed ball. The new check in `backend/cv_engine/foreground.py:128` rejects a quadrant whose inside-minus-outside evidence is below -0.05, while preserving the existing three-supported-quadrant requirement. The reproduced false candidate had roughly -0.10 in its contradictory quadrant; the retained blurred-ball candidate had roughly -0.02. This is a bounded appearance check, not a learned object classifier or proof against every distractor.

The preserved scene-lightness adjustment expands the allowed lightness difference by the absolute bounded scene shift. The earlier report's description as a signed exposure correction was too strong. That mechanism was preserved rather than retuned in this session.

### 3. The recorded fall does not contain enough reliable motion samples

At `ball_free_fall_log_3.txt:588`, frame 134 moves down to pixel `(217, 61)` at capture time 231.671 s; at line 590, frame 135 is untracked. At line 616, frame 146 reappears near `(160.5, 34.5)`, consistent with the later identity drift. A derivative through missing/wrong-object positions cannot describe the falling ball.

The configured scale is 426.7 px/m from the default 128-pixel ruler labeled 0.3 m; the log only records the initial ruler placement. It does not establish that those endpoints matched a physical 30 cm reference. At that scale, the 180-pixel image spans only about 0.42 m vertically. If accurate, a drop from rest traverses that height in about 0.29 s, yielding only a few frames at the logged rates. The real calibration must be checked.

Previous seven-sample fits could span much of a second or longer and blend holding, release, falling, and wrong identity. The preserved WIP in `physics_engine/session.py:115` bounds Free Fall history to 0.35 s and requires four samples spanning at least 0.12 s. `physics_engine/kinematics.py:216` uses actual sample times, normalizes fit time for numerical stability, estimates localization/fit uncertainty, and withholds acceleration when its standard-error estimate exceeds 2 m/s². These are quality criteria, not proof that any accepted segment is ideal free fall. They do not force acceleration toward gravity.

### 4. Presentation added lag and invented trail positions

The live marker previously eased between measured positions; trail points were sampled from that animation. Those intermediate coordinates were not observations. `vector_overlay.dart` now anchors the marker and trail to incoming observed positions. Vector lengths still ease for readability. Losing tracking clears the marker/trail immediately.

A stalled connection could leave the last marker indefinitely. `SessionController._onState` now expires the displayed observation at one second of measured age, using local capture/encoding age plus RTT. Expiry changes only display status, not recorded telemetry, and does not remove a user's paused snapshot. It does not predict a new position. The UI explicitly says that the observation is delayed.

### 5. Initialization could reuse a frozen image as confirmation

Initialization was acknowledged separately, but both timestamp guards initially allowed the same capture again as the first live frame. Client and backend now require live captures to be newer than successfully initialized selection images. Two-object initialization retains the newest selection timestamp. A frozen camera can no longer manufacture visual confirmation from the selection image.

## What was implemented or completed

Preserved and verified the previous capture/physics work:

- Web camera pixels are copied in `requestVideoFrameCallback`, paired with `mediaTime`, and retained through encoding. Duplicate captures cannot acquire new timestamps. Native capture retains frame-availability timing through encoding.
- Timestamp ordering is enforced by backend and client. Old state IDs/timestamps do not replace newer observations.
- Adaptive frame credits retain low-latency backend dropping. Initialization segmentation duration is now excluded from live RTT sizing.
- Backend `process_ms`, `queue_ms`, and timestamp provenance use monotonic local timing. Missing capture timestamps withhold motion derivatives.
- Free-fall fits use actual capture intervals and expose fit quality. Measured acceleration and theoretical gravity remain separate.

New completion work:

- Contradictory foreground-boundary rejection and a regression through actual selection/tracking on the latest fixture.
- Fresh-capture requirement after initialization, including backend and client tests.
- Observed-only marker/trail, display expiry, and tests that expiry adds no fake telemetry.
- Frontend diagnostic logging for observation age, processing time, queue time, and `physics_quality`. Frame-skip text now distinguishes duplicate captures/transport credits from encoder failure.
- `backend/latency_proxy.py`: a local, bounded, ordered bidirectional WebSocket delay proxy using an existing dependency. It delays messages concurrently; it does not impose a delay per message or rewrite timestamps. It simulates fixed delay only, not bandwidth limits or packet loss.
- Fixed test fixtures that reused one capture timestamp. Also corrected the live integration fixture to generate positions from capture time, rather than frame number: the old fixture's physical speed changed under backpressure, invalidating a single expected-speed assertion.
- Extended `docs/protocol.md` for the optional diagnostics and timestamp/flow-control behavior.

No CV algorithm replacement, new runtime dependency, backend deployment, or UI redesign was made. Full-frame recovery, retained original references, and existing experiment models remain.

## Measurements

| Test | Preserved checkpoint | Current work |
|---|---:|---:|
| October 11 correct visible detections | 12 / 14 | 12 / 14 |
| October 11 labeled wrong detections | 1 | 0 |
| October 11 visible misses | 2 | 2 |
| October 11 center RMS error, detected visible frames | 2.75 px | 3.13 px |
| 600 ms RTT send cadence | two-credit theoretical ceiling 3.33/s | deterministic socket test verifies at least 28/s after startup |

The replay trades a small localization change for eliminating the reproduced false identity. It still misses `44.26.png` and `45.png`, and does not guarantee identity in the three partially clipped, unlabeled frames. The returned ball is detected in the first annotated visible frame after absence; sparse recording sampling prevents a recovery-time-in-seconds claim.

Live Flutter-to-Python integration with synthetic JPEGs, current code:

- Direct backend: 29 state replies from 30 frames including initialization, about 6.3 ms RTT. Expected 0.133 m/s; last reported 0.142 m/s.
- Through added 600 ms RTT: 29 state replies from 30 frames including initialization, about 609.6 ms RTT. All 29 replies located the synthetic ball; 27 had velocity. Expected 0.133 m/s; last reported 0.134 m/s.
- These are short loopback runs with generated red-ball images, not camera or wide-area throughput benchmarks. The deterministic cadence test isolates scheduling from encoder/CV cost.
- Offline replay FPS varied with concurrent builds/tests; no speedup or slowdown is claimed from those timings. Old pre-WIP numbers in the previous report were not independently rerun because that diagnosis was already completed.

## Verification

- Baseline recorded tests: original 5/5 passed. New October 11 test added; focused tracking set: 54 passed.
- Final full backend/physics suite: **215 passed**, with 15 dependency deprecation warnings, including the proxy's API compatible with the project's websockets >=12 requirement. This includes the new initialization and proxy tests.
- Full Flutter suite: 164 passed, two opt-in live-backend tests skipped. Both live integration tests subsequently passed directly and through the delay proxy.
- Chrome browser camera test: 1 passed using Chrome's synthetic camera. Confirms frame identity/timestamp stability and progression; does not test a physical camera or Safari.
- Flutter analysis: no issues found. Modified Dart files formatted; `git diff --check` passed.
- Final release web build passed. An existing CupertinoIcons font-family warning remains; no font/style change was made. The second build incorporates the final initialization guard in the app served locally.
- No native iOS build, device camera test, Safari test, or real-network jitter/bandwidth test was performed.

Final verification commands:

```sh
backend/.venv/bin/python -m pytest backend/tests tests -q
cd mobile
flutter analyze
flutter test
LIVE_BACKEND_URL=ws://127.0.0.1:8001/ws/frames flutter test test/integration/live_backend_test.dart
LIVE_BACKEND_URL=ws://127.0.0.1:8765/ws/frames flutter test test/integration/live_backend_test.dart
```

The browser-specific test is `flutter test --platform chrome test/services/camera/web_frame_source_test.dart`, with `CHROME_EXECUTABLE` pointing to a wrapper that launches Chrome with `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`. That fixture deliberately uses a synthetic camera. The last full Flutter run remained 164 passed / 2 live-test skips after the final guard; focused handshake/controller tests also passed (24), and backend handshake/collision/physics tests passed (19). A Dart block-braces lint introduced during the final edit was corrected before the successful final analysis and build.

## Relevant files

New/updated this session:

- Backend: `backend/app.py`, `backend/cv_engine/foreground.py`, `backend/latency_proxy.py`.
- Backend tests: `test_recorded_gray_ball.py`, `test_capture_physics.py`, `test_selection_handshake.py`, `test_latency_proxy.py` under `backend/tests/`.
- Flutter: `mobile/lib/services/network/physics_socket.dart`, `state/session_controller.dart`, `models/physics_state.dart`, `core/config/app_config.dart`, `features/experiment/widgets/vector_overlay.dart`, `features/experiment/experiment_screen.dart` (paths relative to `mobile/lib` after the first).
- Flutter tests: socket, session controller, live integration, browser frame source, and observed overlay tests.
- Docs: this report, `CONTINUE_TOMORROW.md`, and `protocol.md`.

Earlier checkpoint files retained without another algorithm rewrite include `physics_engine/kinematics.py`, `physics_engine/session.py`, `backend/cv_engine/universal.py`, web/native frame sources, and the recording extractor/fixture.

## Physical-camera test, exact procedure

The app is served at **http://127.0.0.1:8080/**. The updated backend is **ws://127.0.0.1:8001/ws/frames**. The delay proxy is **ws://127.0.0.1:8765/ws/frames**. An older server was already on 8000; it was left untouched. In app Settings, explicitly select port 8001 because saved settings may override the build default. Reload the page after this session completes.

To restart from the repository root, use separate terminals:

```sh
cd backend
.venv/bin/uvicorn app:app --host 0.0.0.0 --port 8001
```

```sh
cd mobile
flutter build web --release --dart-define=BACKEND_URL=ws://127.0.0.1:8001/ws/frames --dart-define=TRACKING_DIAGNOSTICS=true
cd ..
backend/.venv/bin/python -m http.server 8080 --bind 127.0.0.1 --directory mobile/build/web
```

```sh
backend/.venv/bin/python backend/latency_proxy.py --rtt-ms 600
```

1. Use Chrome on this computer at localhost, allow the webcam, select Free Fall and the local backend. The current run is built with tracking diagnostics enabled.
2. Fix the camera. Use bright diffuse light and keep the background distinct from the gray ball. Put a real ruler in the ball's motion plane, align both calibration endpoints, and enter the actual distance. Do not treat untouched default endpoints as a calibration.
3. Tap the ball and inspect the proposal. If ambiguous, draw a rectangle around the entire ball, including its boundary but little hand/background, and confirm. Record whether tap or box selection was used. Initialization must precede tracking; a newer camera frame must confirm it.
4. Hold still for two seconds, move slowly and then quickly horizontally and vertically across the view, briefly cover the ball, then return it at a different location. Remove it entirely for two seconds. A face, hand or shirt must not acquire its marker. Note any recovery and misses.
5. For gravity, use a measured 0.5 to 1 m drop if the full path fits the view with margin. Move the camera back as needed and recalibrate. Keep the ruler and ball path in one plane, avoid camera motion, release without a push, and keep the ball away from the image boundaries. Record at least three drops. A lower resolution/distant ball may be harder to localize, so check the proposed mask at the new distance.
6. Interpret downward velocity/acceleration as negative because physical Y is upward. Inspect capture-time y(t) for a quadratic segment and velocity for a near-linear change during actual free flight, excluding the held and impact intervals. Compare measured acceleration with -9.81 m/s² using reported uncertainty; do not expect a single frame or a very short fall to yield a valid estimate. Missing acceleration is the correct outcome when samples/precision are insufficient.
7. Repeat the same test after switching Settings to `ws://127.0.0.1:8765/ws/frames` for about 600 ms added RTT. Reinitialize the selection. The overlay will visibly lag the current camera: remote processing cannot remove propagation delay. Check sent/processed cadence and capture timestamps in diagnostics, and compare measurements at the same capture times. Switch back to 8001 afterward.
8. Save **Copy Debug Log** to a new non-empty text file and record the screen from calibration through the fall and absent-ball interval. Include app/backend commit, backend URL, camera model, ruler distance, drop height, lighting, and whether the proxy was active. Capture original backend JPEGs plus their metadata if a capture facility is available; the new proxy does not save images. Do not substitute screenshot timestamps for capture timestamps.

For a native phone, use the computer's LAN address and backend port 8001; localhost on the phone points at the phone. A browser on a phone requires a trusted HTTPS camera context for a non-localhost host, so ordinary LAN HTTP is not a valid browser-camera test. The proxy intentionally binds only to loopback; the documented high-latency test is on this computer.

## Unresolved work and architecture recommendation

- Physical gray-ball reliability remains unverified. Full-frame identity is still based on appearance and shape; similar neutral objects, strong glare, heavy blur, and clipping can defeat it. Do not loosen confidence gates simply to increase `tracked=true` counts.
- Two visible misses remain in the latest reconstructed fixture. The three edge frames lack center labels. Obtain raw camera frames before broadening those gates or claiming successful free-fall tracking.
- Dynamic credits address RTT-induced starvation, not bandwidth saturation. TCP buffering, jitter, true camera exposure timing, and heavy backend load require measurement with the new diagnostics. The proxy covers fixed delay only.
- Browser `mediaTime` is a frame presentation timestamp; `captureTime` metadata may be absent. Native fallback timing begins at frame availability. Unknown sensor delay is not included in reported age. Browser callback semantics were checked against the [API documentation](https://developer.mozilla.org/en-US/docs/Web/API/HTMLVideoElement/requestVideoFrameCallback).
- Free-fall uncertainty assumes a quadratic segment and a one-pixel localization floor. It does not include calibration error, systematic center drift, rolling shutter, perspective or motion blur bias. Camera tests must assess those separately.
- Use the local backend for the next experiment to remove avoidable network delay. If the eventual mobile product needs an accurately aligned live overlay on a remote connection, evaluate client-local tracking in a Web Worker/WASM or native-specific implementation only after replaying raw frames and profiling it. A native-only CV package does not establish Flutter Web support. No client tracker was introduced in this task.

Anti-Slop scope: no visual redesign. Existing design tokens and layouts retained. R-17/R-36 PASS: metrics above come from logs or named tests, with limitations. R-26/R-27 PASS for the changed behavior: the stalled-stream and observed-overlay tests exercise delayed/lost states. R-35 PASS for build verification: release web build, widget suite and synthetic browser camera test passed. These are scoped checks; no full visual audit or physical-camera click-through is claimed.
