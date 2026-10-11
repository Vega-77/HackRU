# Gray-ball tracking correction, 2026-10-10

## Evidence and diagnosis

This continues the acquisition and initialization work at `3358083` on `devFour`.
The latest rectangle-selection log, `diagnostics/logs/new_ball2.txt`, shows successful
initialization followed by 535 appearance rejections and 30 detections from 569
global searches. Global recovery already searches outside the original selection.
The selection area is not a permanent spatial constraint.

The screen recording shows the actual identity failure: at 45 seconds the ball is
on the left while the overlay follows the wrist on the right. At 65 seconds the
ball is smaller and its marking has rotated out of view. Around 68.8 seconds the
falling ball is visibly blurred. No separately saved log accompanies that video.

The old `ManualTracker` copied and matched the entire rectangle, including fingers
and background (`universal.py` at `3358083`, lines 44–46 and 59–75). Neutral chroma
did not identify which part of that rectangle was the ball. A local false match
prevented global recovery (`detect`, lines 100–104). Its minimum template scale
was 0.85, although the recorded ball shrinks from roughly 48 to 32 pixels in the
reconstruction, about 0.67 of its selected size. These mechanisms are supported by
the recording and source, rather than a hypothetical drag serialization failure.

Replaying the same reconstructed initialization against the original code gives
the wrist at (229,116) at 45 seconds, and no ball at 58 or 65 seconds. The corrected
code locates the ball near the manually labeled centers below.

## Targeted changes

- `backend/cv_engine/foreground.py:29`: initialize a tap-seeded GrabCut mask inside
  the confirmed rectangle, once per selection. Keep the component containing the
  seed and reject tiny islands or regions with no separable background. This uses
  foreground/background evidence, without a predefined neutral or HSV color.
- `backend/cv_engine/universal.py:13`: weighted, normalized correlation excludes
  most selection background and tolerates additive exposure changes. Image moments
  are shared across reference variants to limit matching cost.
- `universal.py:95`: search scales 0.55–1.35, retaining local search and full-frame
  recovery. Nonround objects use their masked appearance. If segmentation fails,
  the existing confirmed-region matcher remains available.
- `foreground.py:64`: only a sufficiently round selected mask enables a silhouette
  reference alongside the immutable original. The silhouette can remain visible
  when a printed marking turns away. No Hough circle detector or new tracker is used.
- `foreground.py:91`: verify candidates against frozen foreground/background color
  models, interior versus exterior contrast, and support around at least three
  silhouette quadrants. Similar wrist colors alone cannot establish ball identity.
  These are heuristic evidence scores, not calibrated object probabilities.
- `universal.py:205`: return the verified foreground centroid. A high-scoring match
  may update foreground pixels of a separate appearance template; the original
  reference and selected color models remain unchanged.
- `universal.py:62`: if grayscale contrast is insufficient, use the stronger Lab
  chroma channel for appearance matching. The live Flutter fixture revealed a red
  ball whose grayscale brightness nearly equals its gray background; rejecting
  it as empty was incorrect. Color contrast must also be insufficient before the
  selection fails. The normal grayscale path for the recorded ball is unchanged.
- `mobile/lib/core/config/app_config.dart:16`: request 30 rather than 15 capture
  FPS to provide more opportunities during short drops. Keep 320-pixel frame width,
  JPEG quality, two-frame backpressure, and latest-live-frame dropping. Processing
  and overlay FPS can be lower than the requested capture rate.

Initialization acknowledgment, frozen selection image, manual retry, physics and
the existing WebSocket contract remain in place. The only diagnostic addition is
the matching `method` in the existing opt-in `tracking_debug` object.

Candidate-by-candidate GrabCut was investigated and rejected because it cost roughly
100–250 ms on these small images. It is used only at initialization. Circle voting
and global color contours were also inadequate in the supplied cluttered scene.
The retained method verifies the selected object's appearance and silhouette.

## Why previous tests missed the failure

Earlier fixtures used uniform backgrounds, tight object boxes, fixed scale and
unchanging appearance. Those conditions let a whole-rectangle template succeed.
They did not reproduce a hand in the selected patch, a different background behind
the moving ball, rotation of its marking, or the actual smaller ball overhead.
Successful acquisition and initialization acknowledgment did not establish tracking
identity in later frames.

The new regressions include these mechanisms and camera-scene frames. The five
recording tests require the ball's labeled region and reject the recorded wrist
match. The release test checks every accepted detection against the ball and
requires recovery at release start; it explicitly permits loss on difficult frames.

## Reproducible checks and results

`backend/extract_ball_recording.py` extracts nine annotated timestamps from the
supplied `.mov`. The committed fixture's manifest records its source SHA-256;
its README documents the crop, coordinates and removed overlay pixels. These are
reconstructed screen pixels, **not exact backend JPEGs**. Missing camera side strips
and inpainted UI regions limit the result. The tests do not measure continuous-video
recall, network delay, or capture-to-overlay age.

| Time | Labeled ball center | Corrected replay |
| --- | --- | --- |
| 45 s | (136,72) | Ball detected; local wrist rejected and global recovery used |
| 58 s | (131,44) | Ball detected after forced loss |
| 65 s | (156,60) | Smaller ball detected with marking turned away |
| 68.5–68.6 s | (240,75) | Lost under glare/low contrast |
| 68.7 s | (240,80) | Ball detected at release start |
| 68.8 s | (240,130) | Lost on the blurred falling frame |
| 69.1 s | Absent | No target reported |

Observed offline processing ranged roughly 20–80 ms per reconstructed frame.
Foreground verification adds processing work; full-frame recovery can therefore
still cause stutter. These timings are not a live-camera performance guarantee.
Uninterrupted free-fall tracking is **not verified** and is not an acceptance claim.

Run from `backend`:

```sh
.venv/bin/python -m pytest -q
.venv/bin/python -m pytest ../tests -q
```

Run from `mobile`:

```sh
flutter analyze
flutter test --reporter expanded
```

Backend tests cover acquisition, initialization ordering and retries as well as
the new tracking regressions. Root tests cover physics. Flutter tests cover the
selection/confirmation flow, sockets, state and overlays. Synthetic success does
not establish real-camera reliability.

Validation for this revision: 153 backend tests and 22 physics tests passed;
130 Flutter tests passed, including both live-backend tests enabled with
`LIVE_BACKEND_URL=ws://127.0.0.1:8000/ws/frames`. Flutter analysis found no issues.
Backend warnings are existing Matplotlib/Pyparsing deprecations.

The live integration harness now acknowledges the exact initialization image
before streaming, matching the application's current workflow. That check exposed
the equal-luminance red-object failure above. Its accepted detections were on the
drawn ball and its velocity matched the fixture within the existing tolerance.
This validates transport and physics with generated JPEGs, not camera reliability.

## Next physical-camera check

1. Open the locally launched app and allow the camera. Select a new gray ball by
   tapping its body. Check the proposed box before confirming. If its boundaries
   include another object or look wrong, adjust/draw a box around the ball.
2. Move it slowly far left and right, then overhead and farther from the camera.
   Rotate the marking away. The overlay must stay on the ball, not the hand.
3. Hide it briefly, then bring it back at a different location without selecting again.
4. Try several short drops in bright, even light. Check for missing frames, delayed
   overlays, and any switch to the hand, face or ceiling.
5. Save a screen recording. The local Flutter launch also saves diagnostic output
   to `diagnostics/logs/foreground_camera_test_2026-10-10.txt` for this run.

Acceptance requires correct physical-object identity and useful capture during the
drop, with prompt recovery after loss. Failed blur/glare frames in the supplied
recording remain a known limitation. No merge into `main` is authorized until the
user confirms the physical-camera result.

## Antislop gate for this change

Scope is tracking code, its comments, tests and technical documentation; the UI
layout, typography, colors, controls and interaction flow were not redesigned.
PASS R-02/R-16: comments and instructions use ordinary punctuation and specific
operations. PASS R-17/R-36/R-38/C-5: measurements identify their source and limits,
and no real-camera success is claimed. PASS R-33: changes are source patches.
PASS C-1/C-3/R-31: each algorithm change addresses the recorded identity or scale
failure above. UI-specific visual and interaction gates are not applicable to the
capture-rate constant or backend code. No fresh UI click-through audit is claimed.
