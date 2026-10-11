# Tracking overnight handoff — October 11, 2026

**Status: WIP, unverified on a physical camera.** The changes are preserved on `devFour`. Nothing was merged into `main`.

## Bugs and likely root causes

### Gray-ball identity loss

The October 11 screen recording shows the ball initially acquired, then the displayed marker lags during release and later appears on the person's face/neck/torso after the ball is no longer visible. `ball_free_fall_log_3.txt` is empty, so it provides no backend timing or tracker evidence.

The likely tracker failure is identity drift after a tight manual selection. Segmentation can cut off the ball where the selection touches its edge; its round-object reference then fails validation. The manual tracker falls back to a selected/adaptive template without robust round identity verification and can settle on a visually similar background region. Frame age and network latency may contribute to visible lag, but this recording alone cannot quantify that pipeline.

### Foreground segmentation around a clipped selection

The primary segmentation marks the selection boundary as hard background. When a tight box clips the ball, the resulting mask can lose enough of the round shape that the round reference is rejected. The new fallback retries segmentation in a padded ROI, while constraining probable foreground to the original selected box and retaining the tap seed. It accepts the fallback only if the resulting mask passes the round-shape gate.

### Camera-scene brightness changes

Appearance verification compared candidates against expected appearance too rigidly when the camera scene's exposure/lightness changed. The update compensates for a full-scene median LAB lightness shift, bounded by existing thresholds and spread, so scene-wide exposure changes are not mistaken for object identity changes.

## Changes preserved

- `backend/cv_engine/foreground.py`: scene lightness adaptation for appearance verification.
- `backend/cv_engine/universal.py`: padded-ROI segmentation fallback for a clipped round target.
- `backend/extract_oct11_recording.py` and `backend/tests/fixtures/gray_ball_oct11/`: extract and label frames from the screen recording for repeatable offline replay. These are reconstructed screen pixels, not the original backend JPEG stream.
- A separate WIP commit preserves capture timing, frame pacing, and physics investigation changes in `backend/app.py`, mobile capture/socket pacing code, and `physics_engine/{kinematics.py,session.py}`. These changes are **unverified** and need review before relying on them.

## Verification and recorded gray-ball tests

The last focused run of `backend/.venv/bin/python -m pytest backend/tests/test_recorded_gray_ball.py -q` passed **5/5 tests** in 0.64 seconds. No tests were run as part of this preservation-only pass.

On the reconstructed 27-frame recording sequence, offline replay changed from 2 correct target frames, 21 wrong-identity frames, and 0 misses among 14 visible labeled frames (center RMS error 37.32 px) to 12 correct, 1 wrong identity, and 2 misses (center RMS error 2.75 px). The labels and reconstructed frames are approximate. The replay includes screen overlays and is not the backend's original JPEG input; offline processing FPS excludes network and real-time camera behavior. The ball is still lost during fast, blurred release, and one false match occurs around 47 seconds when the ball is absent. These results support the segmentation/identity improvement on this sequence, but do not establish real-camera reliability.

Earlier iterations had failing recorded-scene tests while the scene-brightness tolerance was being adjusted. Those were superseded by the final 5/5 focused run. No full backend suite, Flutter analysis/tests/build, or physical-camera test is claimed as passing.

## High-latency tracking and free fall

Capture timestamp, pacing, and physics changes have been preserved as WIP, but have not been validated against measured capture-to-display age or irregular real network delivery. No quantitative end-to-end latency result is available. Do not treat network arrival times as physical time; physics must use capture timestamps.

Free-fall calculations remain unverified. The available screen recording has no accompanying backend diagnostic log, and the object is not reliably tracked through the fast release. There is not enough evidence to claim a reliable acceleration estimate. Do not force measured acceleration to 9.81 m/s² or present theoretical gravity as an observation.

## Remaining work

1. Review the capture/pacing/physics WIP diff before relying on it; test that capture timestamps survive transport and are used for physics.
2. Add a regression test that replays the new extracted fixture through the exact production selection/tracking path and asserts object identity, including absent-ball frames. The five existing recorded tests passed, but do not by themselves cover this new screen-recording fixture.
3. Repeat tests using original backend frame payloads plus diagnostic timestamps, queue/drop counters, processing duration, response age, and tracker confidence. The screen recording is not a substitute for these inputs.
4. Fix the residual fast-motion/blur loss and false match when the ball is absent. A prediction must never be shown as a confirmed detection.
5. Validate horizontal and vertical motion, occlusion/reacquisition, and free fall with a physical camera before merging. `main` has not been changed by this work.

## Tomorrow's physical-camera test

1. Check out `devFour` and note the commit hash. Start the backend using the repository's normal local development command, then start the Flutter app with diagnostics enabled. For a phone on the same Wi-Fi, configure the backend URL with the computer's LAN address; `127.0.0.1` on the phone refers to the phone itself. Record the exact backend URL and app/backend commit hashes.
2. Fix the camera and lighting. Place a ruler in the object's motion plane and calibrate against a distance measured with that ruler. Keep the ball well inside the camera frame and large enough to see clearly. Avoid hands or other moving objects near the ball after selection.
3. Draw a tight rectangle around the entire gray ball without clipping it, accept the proposed selection, and hold the ball still for two seconds. Confirm the marker remains on the ball.
4. Move the ball horizontally in both directions and toward/away from the camera at slow, then brisk, speeds. Briefly occlude it and return it. Record whether the marker follows the ball, how long recovery takes, and any false marker when the ball is out of frame.
5. Perform several vertical drops from a measured height. Keep the full fall in frame, avoid imparting a push, and repeat at least three times. Check position against capture-time samples and inspect whether the fitted trajectory is approximately quadratic. Treat acceleration as an experimental estimate with uncertainty; compare with gravity without forcing equality.
6. Save the app's diagnostic log (the prior `ball_free_fall_log_3.txt` was empty) and a screen recording showing selection and the complete motions. Preserve the raw backend frame/log data if available. Note lighting, camera distance, calibration distance, release height, network type, and any pauses or dropped frames.

