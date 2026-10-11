# Continue HandsOnPhysics tracking from devFour

Read `docs/TRACKING_OVERNIGHT_REPORT.md` and applicable `AGENTS.md`/Anti-Slop instructions first. Check branch, status, and latest commits. Preserve the existing iOS project edit and untracked local configuration files. Do not merge into main or deploy until the user verifies the physical gray ball.

## Already completed; do not repeat the initial investigation

- `d25fdde` and `f92e3f0` are the original preserved WIP. The newer commits complete verification and targeted corrections.
- The five older recorded tests passed at baseline. There is now a regression through production initialization/tracking for the October 11 fixture.
- Tight selected boxes can prevent a round reference; the padded segmentation fallback remains.
- The remaining shirt match at 47 seconds was reproduced and rejected by checking for contradictory foreground evidence across the expected boundary. Latest replay: 12/14 visible frames found, zero labeled false detections, two misses, RMS center error 3.13 px. The blurred drop at `30.6.png` and subsequent reacquisition remain detected.
- `ball_free_fall_log_3.txt` is now populated; the older claim that it was empty is obsolete. It shows 5.29 and 7.89 processed capture-time updates/s in the substantial sessions and a drop followed by loss before enough free-fall observations existed. The default ruler calibration is not physically verified.
- Capture timestamps, adaptive in-flight credits, newest-frame dropping, stale response rejection and Free Fall fit-quality limits from the WIP have focused regressions. Successful initialization now requires a newer capture before live confirmation. Segmentation time is excluded from live RTT sizing.
- The marker and trail use observed positions, no interpolated trail points. Displayed observations expire after one second without injecting fake telemetry. Explicitly paused snapshots are retained.
- Debug logs include observation age, backend process/queue duration and physics quality. The protocol documents them.
- A local latency proxy is available, preserving message order, payloads and capture timestamps. It adds fixed RTT only.

## Verification to retain

Final full suites: **215 backend/physics tests passed; 164 Flutter tests passed with two opt-in live tests skipped**. Those two integration tests passed separately against the local backend, directly and with 600 ms added RTT. Original five recorded tests plus the latest sequence passed. Chrome's synthetic-camera test confirmed stable timestamps for repeated encodes. Final analysis and release build passed. The delayed live Flutter/Python run located the synthetic ball in all 29 state replies; expected speed 0.133 m/s, reported 0.134 m/s. This is not physical-camera validation.

The live integration fixture now generates position from capture time. Do not restore the older frame-index-based motion under variable backpressure; it changes actual speed and invalidates a constant-speed expectation.

## Next action

Obtain the physical-camera verification using the exact procedure in the report before changing more algorithms. The local app is http://127.0.0.1:8080, backend ws://127.0.0.1:8001/ws/frames, delay proxy ws://127.0.0.1:8765/ws/frames. Saved settings may override the compiled backend URL. The older service on 8000 was deliberately left alone. Restart commands are in the report.

Get a non-empty new debug log and screen recording with measured ruler calibration, three complete drops, horizontal/vertical motion, temporary occlusion, and an absent-ball interval. Prefer original backend JPEGs and metadata if available. The existing reconstructed screen frames retain overlays and missing crop regions; their timestamps cannot supply physical acceleration ground truth.

## Remaining risks

Two visible misses (`44.26.png`, `45.png`), unlabeled partial-edge frames, similar neutral distractors, glare/blur/clipping, bandwidth-limited TCP buffering, Safari/native camera timing and real sensor-to-display age are not solved or fully verified. Fit uncertainty excludes calibration/perspective/blur bias. Do not force acceleration to gravity or count predictions as measurements. Do not hide missing observations with smoothing.

If new evidence reproduces a problem, implement a small testable correction with an identity/coordinate assertion. Preserve full-frame recovery, original reference preservation and illumination tolerance. Run focused tests during edits, then required integration checks. Avoid another broad investigation or speculative architecture replacement. Keep results and test limitations in the report; commit and push only devFour when authorized.
