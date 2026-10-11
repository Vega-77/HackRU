# Tracking performance: local estimates and recorded Free Fall

## Repository and evidence

October 11, 2026. Fetched and fast-forwarded local **main to 814bbe6**, the latest origin/main at the start of implementation. Retained teammates' browser capture fallback, selected-object optimization, Free Fall/bounce fixes, vectors, surfaces, and Learn screens. The existing Xcode project edit and untracked `.DS_Store`, `.codex/`, and `AGENTS.md` were preserved and excluded from commits. No push, PR, deployment, reset, or infrastructure change.

Read both tracking handoffs, current capture/transport/backend/physics code, relevant commits, and the populated `ball_free_fall_log_3.txt`. Inspected the reconstructed selection, blurred release, and absent-ball shirt frames from the October 11 recording. Did not claim continuous playback, access to original camera JPEGs, or new physical-camera verification. The screen reconstruction contains overlays/inpainting/cropped black areas; its timestamps cannot supply physical acceleration ground truth.

## Supported diagnoses

1. **A server-only browser marker remains delayed.** `SessionController._pumpFrame` sends images and `_onState` waits for server observations. Native ARKit has a follower; the browser previously had none. Adaptive credits, newest-frame dropping, fresh-image initialization, timestamp ordering, and stale-observation expiry already existed and remain intact. More credits cannot remove propagation delay. Local estimates now describe recent browser pixels; server markers/vectors/physics still describe confirmed earlier observations.
2. **Scene-specific CV can dominate local processing.** Added stage timing in `backend/app.py:_process` and `_process_with_physics`. The reconstructed JPEG stress replay took about 41 ms median worker time, mostly tracking. Generated gray-ball JPEGs took roughly 10–11 ms median WebSocket `process_ms`. These are laptop results, not Render measurements.
3. **Latest-frame dropping cannot preserve a short fall's observations.** It remains appropriate for live latency, but dropped images never supply physics. Older logs showed 5.29 and 7.89 capture-time updates/s and loss during release; those are not today's deployed FPS. The new recorder captures before transmission, so replies do not determine temporal sampling.
4. **Twelve samples cover too little time at 60 FPS.** Existing main had expanded Free Fall history for 30 FPS. At 60 FPS twelve samples span only 0.183 s. A deterministic 220 px/m drop with 2 px jitter produced zero accepted accelerations in seven tested late-flight samples, with standard errors around 2.50–2.91 m/s². Allowing 24 samples within the unchanged 0.35 s time window fixes that reproduced case without relaxing uncertainty or forcing gravity.
5. **Gray-ball blur/localization remains unresolved.** Original recorded regressions still pass. JPEG recompression of the reconstructed screen sequence worsens recall/localization. A local follower cannot repair a wrong seed or guarantee identity against arbitrary lookalikes. This task does not retune backend acquisition, foreground, appearance verification, or full-frame recovery.

## Latency instrumentation and interpretation

Backend `timing_ms` reports decode, preprocess, tracking, and physics durations using a local monotonic clock. Existing `queue_ms` covers waiting; `process_ms` includes worker scheduling/processing. Frontend diagnostics report JPEG encoding, capture/encoding age, stage timings, and **transport/response = RTT - process_ms - queue_ms**. That residual also includes serialization, response handling, and browser scheduling. It is not pure network ping or a one-way latency measurement.

Three local runs of `backend/benchmark_tracking.py`, reconstructed October 11 frames recompressed at JPEG quality 70:

| Stage | Median ms | p95 ms |
| --- | ---: | ---: |
| Decode | 0.187 | 0.220 |
| Preprocess | 0.155 | 0.198 |
| Tracking | 41.107 | 54.383 |
| Physics | 0.024 | 0.188 |
| Total worker operation | 41.469 | 54.836 |

Initialization: 242.848 ms first run, 58.226/57.730 ms warmed runs. Initialization was already excluded from live RTT sizing. The Pages URL returned HTTP 200; a read-only Render health request timed out after 20 seconds. The deployed 250–300 ms breakdown was **not measured**. We cannot establish its region, load, plan, or cold-start contribution from this session.

The stress replay finds 10/14 visible centers within annotation tolerance, misses three visible frames, and detects one visible center outside tolerance: `30.5.png`, error 12.369 px. It produces **zero labeled absent-ball detections**, so that localization error is not a proven identity switch. RMS center error over detected visible frames is 4.70 px. It initializes from the reconstructed PNG and follows recompressed JPEG crops; it is not a faithful raw-camera initialization/encoding benchmark. The established PNG regression still accepts at least 12/14 visible frames with no labeled absent detections. Obtain raw camera JPEGs before further blur/identity tuning.

## Changes implemented

### Browser-local visual estimate

- `LocalVisualTracker` matches the **server-confirmed object-sized boundary and surrounding context**, not a fixed 48×48 tap patch. Seeds only from the exact cached frame corresponding to a confirmed bbox.
- 160 px wide grayscale frames; immutable 12×12 sampled outline/context reference with 10% surrounding context; brightness-normalized correlation supports neutral objects without an HSV-only rule.
- Bounded time-aware translation search, minimum score 0.90, competing-peak margin 0.06, contrast/brightness checks. Both leading separated peaks get pixel refinement; an odd-pixel duplicate cannot evade ambiguity rejection.
- Gaps over 0.2 s, ambiguous matches, disappearance, or failed checks withhold estimates. Recovery waits for server guidance; backend full-frame reacquisition remains unchanged.
- At most 120 cached downsampled frames align delayed validations. Corrections replay intervening pixels and preserve reference appearance. Boxes are never placed on unrelated timestamps.
- Dashed copper **Local estimate** outline is separate from observed markers/vectors. Estimates never enter physics, telemetry, measured trails, or measured vectors. No extrapolated-position display.
- Publication expires after 150 ms without updates; identity cannot continue indefinitely without server validation. Pause/teardown clear estimates. Browser diagnostics expose frame/match counts, compute time, and publication age.
- No runtime dependency, native OpenCV Web assumption, tracking JS bundle, Worker, or WASM asset. Existing camera callback fallback retained.

Initial matching allocated a normalized patch for every candidate. Browser profiling measured 12–21 ms p95. The final implementation calculates equivalent normalized correlation from sums and the fixed reference, avoiding those allocations; final p95 is 6–8 ms in the same harness. A Worker remains a future option if actual phone profiling shows main-thread contention. Laptop performance does not establish phone suitability.

### Recorded Free Fall and physics validity

- **Record 3 s** captures independently of socket credits/replies, polling up to the existing 60 FPS hint. Actual hardware FPS is not guaranteed. Duplicate timestamps are discarded, resolution changes rejected, and retention capped at 180 images/8 MiB. Logs include actual capture FPS and maximum gap.
- Freezes config/calibration/selected image; retains original image timestamps and optional native camera poses.
- Dedicated `RecordedAnalyzer` uses the existing `PhysicsSocket` config/initialization/JPEG/state protocol. Sends one saved image per acknowledgement, preventing the normal latest-frame slot from replacing recorded samples. No new endpoint or protocol mode.
- Progress, Cancel, and Retry analysis are available. Errors retain frames for retry; retry initializes a new isolated analysis. Connection interruption fails rather than joining partial physics across reconnects. Resume/mode changes are blocked while busy; leaving cancels.
- Recorded charts/readouts show server observations after completion; historical states do not move the current live marker. Resume clears recorded charts and returns to live measurements. Lost observations/withheld derivatives break chart lines. Recorded charts label their final sample **end**, not **now**.
- `FREE_FALL_MAX_SAMPLES` is now 24. The 0.35 s cutoff, four-sample/0.12 s minimum, one-pixel localization floor, and 2 m/s² acceleration uncertainty gate remain unchanged. Measured acceleration is not forced to 9.81.

Recordings remain in page memory until downloaded: refresh/leaving discards them. The new **Download capture** action exports exact JPEGs, timestamps, frozen calibration and measurements (see Capture export below). Serial analysis deliberately trades completion time for compatibility/reliability; a long recording may take tens of seconds under remote RTT. A batch endpoint is a possible later improvement, not an implemented feature.

## Performance measurements

### Real browser code, generated canvas/video scene

Chrome runs the actual frame source/matcher on a 30 FPS generated gray sphere. Server bboxes come from known scene coordinates and are delayed; server CV/real network are not part of this harness. Counts over two seconds include warmup, so are not steady-state FPS. Age means **estimate publication age**, not independently measured sensor/screen-paint latency.

| Simulated reply RTT | Estimate publications / 2 s | Median age ms | Matching p95 ms | Median center error px |
| --- | ---: | ---: | ---: | ---: |
| 50 ms | 54 | 10.2 | 6.6 | 1.52 |
| 150 ms | 50 | 9.9 | 6.4 | 1.45 |
| 300 ms | 45 | 8.9 | 8.1 | 1.43 |
| 500 ms | 38 | 9.0 | 6.7 | 1.45 |

Before: browser overlays depended on delayed server replies. After: the explicitly labeled local estimate no longer has that dependency. Server-confirmed measurement age remains RTT-dependent. These results do not prove physical-camera reliability.

### Flutter → ordered delay proxy → Python, generated gray-ball fall

25 real JPEGs captured synthetically at 60 FPS, 220 px/m, acceleration -9.81 m/s². Actual `RecordedAnalyzer` and backend, four fixed added-RTT conditions. All 25 frames returned with original timestamps and centers within 2 px under every condition, without frame substitution/drop.

| Added RTT | Analysis completion ms | Median server process ms | End velocity m/s | End acceleration m/s² |
| --- | ---: | ---: | ---: | ---: |
| 50 ms | 1928 | 10.17 | -3.93466 | -9.85841 |
| 150 ms | 4340 | 10.68 | -3.93466 | -9.85841 |
| 300 ms | 8259 | 11.16 | -3.93466 | -9.85841 |
| 500 ms | 13465 | 11.36 | -3.93466 | -9.85841 |

Expected velocity -3.924 m/s; absolute error about 0.0107 m/s. Acceleration error about 0.0484 m/s². Delay changes completion time, not sampling/physics values. Synthetic success does not establish a phone's exposure, actual FPS, calibration accuracy, blur, or identity reliability.

## Verification

- Baseline focused backend/physics: **28 passed**, including the recorded-scene regressions.
- Final full backend/physics: **250 passed**, 15 existing dependency deprecation warnings.
- Final full Flutter VM suite: **254 passed**, three opt-in integration cases skipped in that run.
- Separate delayed real Flutter/Python recorded integration: **4 passed** (50/150/300/500 ms).
- Chrome browser camera/matching: **5 passed** (four latency cases plus stable timestamp/encoding test).
- Flutter analysis: **no issues found**; formatting and `git diff --check` pass.
- One release Web build passes. Existing CupertinoIcons font-family warning and JS-interoperability WASM dry-run warnings remain; JavaScript is the built web target. No native iOS/Safari hardware verification.
- Recording actions/states pass widget interaction tests at 390×844 and 1366×768. They caught and resolved the mobile retry-action overflow by wrapping actions.
- Rendered production homepage and mobile live workspace in headless Chrome with a fake camera. This macOS host exposes a 1×1 native Flutter host despite viewport emulation, making coordinate click-through unreliable. New recording states were verified by widget interactions, not claimed as a complete browser click-through or physical-camera check. Temporary screenshots live under `/tmp/hop-*.png`.

Existing suites cover appearance/identity, rapid motion, background distractors, occlusion/recovery, irregular timestamps, dropped/late/duplicate responses, queue congestion, initialization races, stale results, and reconnects. New cases cover local matching, recorded image order/time, frozen capture rejection, independent recording, 60 FPS jitter, and actual JPEG-to-physics Free Fall. Fixed-delay tests do not simulate bandwidth limits or real TCP congestion/jitter. Heavy blur, local scale/rotation changes, and arbitrary lookalikes remain limitations.

Reproduce from repo root:

```sh
backend/.venv/bin/python -m pytest backend/tests tests -q
backend/.venv/bin/python backend/benchmark_tracking.py
cd mobile
flutter analyze
flutter test
CHROME_EXECUTABLE=/tmp/hop-chrome-test flutter test --platform chrome test/services/camera/browser_latency_test.dart test/services/camera/web_frame_source_test.dart
RECORDED_BACKEND_URLS=ws://127.0.0.1:8850/ws/frames,ws://127.0.0.1:8950/ws/frames,ws://127.0.0.1:9100/ws/frames,ws://127.0.0.1:9300/ws/frames flutter test test/integration/recorded_backend_test.dart
```

The temporary Chrome wrapper launches Chrome with `--use-fake-device-for-media-stream --use-fake-ui-for-media-stream`. Start proxies with `backend/latency_proxy.py --upstream ws://127.0.0.1:8002/ws/frames --port PORT --rtt-ms RTT`. Active ports: 8850/8950/9100/9300 correspond to 50/150/300/500 ms. The proxy preserves order, bytes, and timestamps.

## Modified files

- Backend: `backend/app.py`, `backend/benchmark_tracking.py`; physics: `physics_engine/session.py`.
- Camera: `mobile/lib/services/camera/{frame_source,camera_or_test_video,web_frame_source,local_visual_tracker}.dart`.
- Recorded transport: `mobile/lib/services/network/recorded_analysis.dart`.
- Models: `mobile/lib/models/{session_config,physics_state}.dart`; state: `mobile/lib/state/{session_controller,telemetry_buffer}.dart`.
- Presentation: `experiment_screen.dart`, `widgets/{experiment_stage,local_estimate_overlay,telemetry_chart,telemetry_panel}.dart` under `mobile/lib/features/experiment/`.
- Tests: backend capture/physics and recorded-sequence tests; Flutter local/browser tracking, recorded analyzer/backend integration, recording controls, and telemetry buffer tests.
- Docs: this report and `docs/protocol.md`.

## Physical-camera test and local launch

App **http://127.0.0.1:8086/**; updated backend **ws://127.0.0.1:8002/ws/frames**. Older servers on 8000/8001/8080/8082 were left alone. Reload and explicitly verify port 8002 in Settings; saved settings override build defaults.

Restart from root if needed, separate terminals:

```sh
backend/.venv/bin/python -m uvicorn app:app --app-dir backend --host 127.0.0.1 --port 8002
backend/.venv/bin/python -m http.server 8086 --bind 127.0.0.1 --directory mobile/build/web
```

1. Chrome, Free Fall, fixed camera, bright diffuse light, distinct background. Put a real ruler in the ball's motion plane; align endpoints and enter its actual distance. Untouched defaults do not establish physical scale.
2. Tap the gray ball, inspect/confirm its proposed boundary. If ambiguous, draw a box around its entire outline with little background and confirm. Hold until a newer live frame confirms tracking. Record tap versus manual selection.
3. Move horizontally/vertically, briefly occlude/remove, and return elsewhere. The dashed local outline should respond before server vectors while confident. A face/hand/shirt must not take either marker when the ball is absent. Record misses, wrong objects, and recovery.
4. Fit a measured 0.5–1 m path fully inside view with margin, in the calibration plane. Move camera back/recalibrate if needed. Choose **Record 3 s**, hold about 0.5 s, release without a push, keep camera still. Wait for analysis and inspect position/velocity/acceleration charts. Repeat three drops.
5. Compare only **free-flight** samples, excluding held/release/contact/impact/reacquisition. Y is upward, so downward motion has negative velocity/acceleration. Expect quadratic y(t), nearly linear v(t); compare measured acceleration with -9.81 using uncertainty. Valid numerical acceleration does not identify ideal free flight; a held ball can correctly measure near zero.
6. Repeat after switching to proxy endpoints on ports 8850/8950/9100/9300. Reinitialize after endpoint changes. Server markers remain delayed. Local estimates should stay responsive while confident; saved capture FPS/gaps should not follow RTT, though analysis waits grow. Test retry after an analysis connection failure without recapturing.
7. Choose **Download capture** after each analysis succeeds or fails, before recording again or leaving. Send the `.hop.json` file and Copy Debug Log, plus browser/phone/camera model, ruler length, drop height, lighting and wrong-marker incidents. A separate screen recording can help show calibration/interaction, but is not required to inspect the exported camera frames.

A phone browser needs a trusted HTTPS frontend; ordinary LAN HTTP does not grant camera access, and phone localhost refers to the phone. No public tunnel/certificate was created. Use an existing trusted development setup, or approve deployment first and test Pages HTTPS against the approved backend. Native iOS LAN testing needs the computer's LAN IP, but was not tested here.

## Remaining limitations and recommendations

- The physical gray-ball test reviewed below shows unresolved live tracking failures. Physical success of saved-frame analysis, low-end phone performance, Safari, real network, and Render CPU performance remain unverified. Main-thread matching competes with CanvasKit/encoding. Use the new diagnostics before adding a Worker/WASM dependency.
- Camera hints do not guarantee 60 FPS or short exposure. Availability timestamps substitute when capture metadata is absent. Sensor delay/jitter, rolling shutter, perspective, blur bias, calibration error, and systematic localization error remain outside current fit uncertainty.
- Missing acceleration is correct when sampling/precision is insufficient. More images do not make an incorrect identity valid. Preserve rejection/uncertainty gates during further work.
- Serial recorded analysis can be slow. A bounded batch upload/analysis endpoint could remove per-frame RTT later using identical timestamps/tracker/physics; it is proposed, not implemented.
- Profile Render with actual camera logs before changing hosting. Consider a closer region if transport residual dominates, reserved CPU/always-on if processing/wake-up dominates. No plan/region recommendation is justified from these laptop measurements alone. Existing main's LAN backend tooling provides a useful nearby comparison.

Anti-Slop scope: existing Kinetic Laboratory tokens/layout retained. R-17/R-36 PASS: metrics identify their harnesses and limits. R-26/R-27 PASS: start/cancel/retry and recording states exercised. R-03 PASS for changed controls: phone/desktop tests caught and fixed overflow. R-35 PASS for executable checks: build, full Flutter, browser camera/matching, and backend integration ran. Browser click-through limitations are explicit; no comprehensive visual audit or physical success claimed.

## Physical-camera follow-up: ball_freefall4

Reviewed October 11 after local commit `ebe7b4f`. Evidence:

- `diagnostics/logs/ball_freefall4.txt`: 2,224 lines; release web build, Free Fall, backend `ws://127.0.0.1:8002/ws/frames`, 320×180 analysis frames.
- `diagnostics/logs/Screen Recording 2026-10-11 at 3.43.34 PM.mov`: directly decoded with OpenCV. 1,553 screen-recording frames; last decoded presentation timestamp 30.600 s. Inspected full-screen samples and a closer sequence around both drops. Temporary review images are in `/tmp/hop-freefall4/`; they are not committed fixtures or raw camera images.

The external screen recording is correctly longer than three seconds. It shows calibration, live tracking, two drops, and tracking-unavailable states. **Record 3 s was not activated**: the button stays available and the log contains no saved capture/analysis session. This verifies a physical failure of the live path, not success or failure of the separate recorded-analysis path. No source-code correction, test rerun, or build was performed during this evidence review.

### Measured live pipeline

Values below come from this physical-camera log, not a synthetic benchmark. There are 383 returned state/timing records over a 35.371 s capture-timestamp span, approximately 10.80 returned states/s. Of these, 210 report tracking and 173 report `appearance_rejected`. The 210/383 fraction is **not tracking accuracy**: absent-ball frames are included and rejecting those can be correct. No identity-switch rate can be established from these counts alone.

| Quantity | Median ms | p95 ms |
| --- | ---: | ---: |
| Capture-to-observation age | 122.80 | 284.39 |
| Backend CV/physics processing | 65.40 | 200.17 |
| Backend queue wait | 13.70 | 86.66 |
| Transport/response residual | 3.30 | 16.39 |
| Tracking stage | 63.48 | 198.43 |
| Physics stage | 0.27 | 0.63 |
| JPEG encoding, 758 sends | 3.10 | 8.91 |
| Capture age at send, 758 sends | 25.70 | 44.17 |

Medians of components do not sum to the median total. The residual includes frontend handling and scheduling; it is not pure network ping. This localhost evidence identifies **tracking computation, particularly failed full-frame recovery, as the dominant backend cost**. It does not measure Render or establish the deployed connection's transport delay. Successful detections have median processing 34.9 ms and observation age 82.0 ms; rejected detections have median processing 126.6 ms and age 190.0 ms. Queueing further delays recovery. Example: frame 83 spends 163.856 ms in tracking; frame 85 adds 98.7 ms queue wait. At the second drop, frame 381 spends 224.537 ms in tracking (`ball_freefall4.txt` lines 402–410 and 1402–1405).

### Confirmed failures and limits

1. **Acquisition succeeds; fast-motion tracking remains inadequate.** Initialization is acknowledged at log line 50, and a subsequent frame confirms the selected ball. The two visible releases then produce only a short series of falling observations before loss. Frame 318 is lost after frame 317; frame 381 is lost after frame 380. Neither a null selection box nor an initialization overwrite explains this test.
2. **The browser-local estimate stops recovering.** The cumulative `local_matches` counter reaches 65 by session second 7 and stays there through second 35 despite subsequent server detections. The recording also shows the dashed local outline disappear. `LocalVisualTracker.anchor` (`mobile/lib/services/camera/local_visual_tracker.dart:40`) rejects a new reference patch below 0.90 correlation to its immutable initial patch; `lose()` preserves that reference. `WebFrameSource.validateLocalEstimate` (`mobile/lib/services/camera/web_frame_source.dart:371`) withholds the estimate on a failed anchor. The visible rotation, changed background and changing object size are consistent with this limitation. The exact rejection cause is **not logged**, so permanent reference rejection is a supported hypothesis, not a proven per-frame diagnosis. Do not lower identity thresholds or replace the reference blindly.
3. **The live derivative window includes held motion before release.** Before the first drop, frames 310–314 show nearly stationary observations. Frames 315–317 then have capture timestamps 69.773, 69.807, and 69.877 s, and vertical pixel positions 60.5, 75.5, and 123.5. Those three clearly falling observations span only 0.104 s. Frame 317 nevertheless reports seven fit samples spanning 0.3307 s and acceleration −6.276 m/s²: its fit includes pre-release positions. `PhysicsSession` configures a 0.35 s window and a four-sample/0.12 s minimum (`physics_engine/session.py:126`). A numerically accepted mixed held/falling fit is not a measurement of ideal free flight. The second drop similarly ends at frame 380 with −3.281 m/s². Do not force either estimate toward gravity; isolated flight samples and adequate sampling are required.
4. **Absolute scale was not established.** Ruler endpoints remain the exact defaults (96,63) to (224,63), with 0.3 m entered and 426.6667 px/m. The visible calibration screen has no physical ruler corresponding to these endpoints. This is adequate for testing pixel tracking but cannot verify SI velocity or acceleration. Camera angle, perspective and the ball's depth changes add further uncertainty.
5. **The theory summary does not identify free flight.** The recording shows a historical theory comparison while current speed/acceleration are unavailable. `fallingAcceleration` (`mobile/lib/state/theory_check.dart:125`) averages samples with downward velocity below −0.1 m/s and a reported acceleration. It does not distinguish release from downward hand motion and does not require current tracking. Therefore the displayed run comparison, including the visible 3.84 m/s², is not independent evidence of gravity accuracy. This interpretation needs to be made explicit before treating it as an experiment result.

The moving marker can lag the ball because observations correspond to earlier camera frames. A marker visibly displaced from the current ball is not by itself proof of a wrong-object identity switch. Raw images bound to the reported timestamps are still needed to evaluate such candidates confidently.

### Next physical test and focused engineering steps

1. Keep using `http://127.0.0.1:8086/` and confirm backend port 8002. Fix the camera and use bright diffuse light and a contrasting plain background.
2. Put a measured ruler in the same plane as the drop. Align both calibration endpoints with an actual measured segment and enter its length; do not leave the default line as a physical calibration. Keep the full drop inside the camera view with margin.
3. Select/confirm the whole gray ball and wait for a newer-frame detection. Perform horizontal movement and removal/return first to document the local outline's recovery separately from the drop.
4. Activate **Record 3 s inside the app**, hold briefly, then release without pushing. Wait for the saved-frame analysis to finish. Repeat three times. The external screen recording should cover the whole session, including calibration, the recording/analysis states and final results; it need not be three seconds long.
5. Save the debug log after analysis. It must contain the recorded frame count, actual capture FPS and maximum gap. Inspect position and velocity curves during actual flight only, excluding held, release, contact and recovery portions. Missing acceleration is a valid outcome if the isolated flight is too short or noisy.
6. Download the actual saved JPEGs and original capture timestamps with **Download capture** before further identity/blur tuning. Screen-recording pixels include overlays, cropping and their own presentation timestamps and cannot substitute for exact captured JPEGs in a physics replay.

Priorities for the next implementation: use the new saved-JPEG export to reproduce local recovery rejection with logged anchor reasons and this scene; profile failed full-frame search without weakening identity checks; then evaluate recorded physical flight and mixed pre-release fitting. The latest evidence does **not** justify replacing the tracker wholesale or claiming either the local estimate or recorded Free Fall is physically verified.

## Capture export (October 11 follow-up)

Implemented **Download capture** in the browser's Free Fall controls. The action appears when saved-frame analysis completes or fails; it retains partial returned observations on analysis failure. It uses a local Blob download, with no new server endpoint or upload. The original saved frames are left available for retry/download. Native file sharing is not implemented; the download control is hidden on native builds.

Each `HandsOnPhysics-<UTC time>.hop.json` file contains format/version, UTC capture-start time, exact JPEG bytes as base64, original client-monotonic timestamps, ordered frame IDs, dimensions, encoding diagnostics, the original selection JPEG/region, frozen session configuration and ruler endpoints/length. Capture summary includes actual FPS and maximum gap. Analysis includes completion/error, parsed observations with positions, velocity, acceleration, forces, energy, tracking decisions, quality and stage timings. Missing observations/derivatives remain missing. This is a portable image sequence, not a MOV video or a fabricated raw-camera stream; the images are the actual JPEGs used for analysis.

Find the file in the browser's configured Downloads location and attach it to the conversation. On iPhone/iPad Safari, check the Downloads button and Files app's configured Downloads folder. Download each trial before another recording, calibration change, cancellation, refresh or leaving; there is no recording library or recovery of already discarded captures. Previously logged trials cannot be reconstructed byte-for-byte from text logs.

Extract and replay from the repository root (the output directory must be new):

```sh
backend/.venv/bin/python backend/extract_capture_bundle.py ~/Downloads/HandsOnPhysics-<time>.hop.json /tmp/hop-drop-1
backend/.venv/bin/python backend/replay_tracking.py /tmp/hop-drop-1/manifest.json --out /tmp/hop-drop-1/replay.json
```

Replace the example filename with the downloaded filename, quoted if it contains spaces. Extraction writes `selection.jpg`, ordered `frame_0001.jpg` onward, `manifest.json`, `analysis.json` and `capture.json`. Replay initializes from the selection before tracking saved frames; it tests CV, while `analysis.json` preserves the original physics results. Label visible ball centers/diameters in manifest `truth` entries before interpreting recall/precision; unlabeled replay cannot establish accuracy. Do not use replay processing time as physical time.

Before: no export UI; only text logs and in-memory captures. After: exact saved frames plus diagnostics can be downloaded after success/failure. No FPS, latency or physical-accuracy improvement is claimed for this export change. Base64 adds about one-third to JPEG storage size; existing capture limits remain 180 frames/8 MiB. Recorded debug logs now also include bbox, velocity, acceleration and tracking decisions.

Files: `mobile/lib/services/network/capture_export.dart`, `mobile/lib/services/download/capture_download*.dart`, `mobile/lib/services/network/recorded_analysis.dart`, `mobile/lib/state/session_controller.dart`, `mobile/lib/features/experiment/experiment_screen.dart`, `backend/extract_capture_bundle.py`, focused service/widget/Python tests and this report. The existing Xcode edit remains excluded.

UI decision: place the action beside existing recording controls so saved data can be retrieved without a separate screen. Reuse the existing button typography, contrast, focus treatment, accent and wrapping layout. No new visual motif or animation; existing laboratory style retained (ENERGY 1 / RHYTHM 1 / MOTION 1).

Export verification:

- Focused Flutter VM run: **27 passed** (export serialization, recorded scheduling and partial-observation callback, session regressions and recording controls). Additional error-state widget test brought focused coverage to **28 distinct passing cases**; the controls rerun passed all **11** cases at phone/desktop sizes.
- Chrome: **1 passed**, executing the actual Blob/anchor helper and verifying filename, MIME type, exact UTF-8 content, attached click target and anchor cleanup. The test intercepts the click to inspect its bytes; it does not establish OS Downloads behavior on Safari/iPhone.
- Python extraction/replay: **5 passed**, preserving exact JPEGs, IDs, irregular timestamps, calibration, partial observations; rejecting malformed base64/order/version before writes and refusing to overwrite a capture.
- `flutter analyze`: **no issues found**. Release Web build and WASM dry run succeed. Existing missing CupertinoIcons font-family warning remains. Local frontend HTTP 200 and backend health OK. `git diff --check` passes. No additional performance claim or native/phone hardware verification.

Reproduce the export checks:

```sh
backend/.venv/bin/python -m pytest backend/tests/test_extract_capture_bundle.py backend/tests/test_replay_tracking.py -q
cd mobile
flutter test test/services/capture_export_test.dart test/services/recorded_analysis_test.dart test/widgets/recording_controls_test.dart test/state/session_controller_test.dart
flutter test --platform chrome test/services/capture_download_web_test.dart
flutter analyze
flutter build web --release --dart-define=BACKEND_URL=ws://127.0.0.1:8002/ws/frames --dart-define=TRACKING_DIAGNOSTICS=true
```

Antislop delivery gate for the changed recording controls:

- Hard gate **PASS**: real download action and visible failure feedback; success/failure/busy/empty visibility and phone/desktop overflow checked by widget interactions; actual download helper exercised in Chrome, release app built.
- Purpose gate **PASS**: action location and reuse of existing control styles justified above; no new decorative technique or asset.
- Liveliness **PASS**: retained laboratory direction, declared 1/1/1 dials, existing camera focal point, structural spacing and copper control accent.
- Craftsmanship **PASS**: concrete action label, wrapped controls, retry after download failure tested, original data preserved; no invented performance/accuracy claims. Phone/Safari download behavior remains a documented validation step after approved deployment.

After deployment approval: deploy the reviewed commit through the existing process, reload Pages, verify the build and backend endpoint, make a new trial, download its bundle and extract it using the commands above. Compare frame count/FPS/timestamps against Copy Debug Log; inspect release/missing/reacquired JPEGs before diagnosing identity or computing free-flight acceleration. Do not push main just to test the browser download.
