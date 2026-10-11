# Gray-ball camera-scene regression

Source: `diagnostics/logs/Screen Recording 2026-10-10 at 7.39.52 PM.mov`.
The exact SHA-256 is in `manifest.json`. Extract with `extract_ball_recording.py`.

These are **reconstructed visible camera pixels, not the transmitted JPEGs**.
The recording is 2940 × 1912. Camera panels use CSS `cover`; their visible part
is mapped into the central 240 pixels of a 320 × 180 frame. The missing side
strips are black. Coordinate labels refer to this reconstruction.

The selection crosshair, selection outline, top controls, loading banner, and
the wrist overlay at 45 seconds are removed using explicitly annotated masks
and OpenCV inpainting before downsampling. The backend never receives these UI
graphics. Inpainted pixels are approximations; the actual ball is outside the
loading/banner masks. The selection crosshair covers a small part of its marking.

Manual labels:

| Time (s) | Ball center | Approximate diameter | Observation |
|---|---|---|---|
| 20 | (234, 94) | 48 | Selected ball plus fingers/background |
| 45 | (136, 72) | 52 | Ball on left; recorded overlay follows wrist on right |
| 58 | (131, 44) | 46 | Ball above head, marking partially visible |
| 65 | (156, 60) | 32 | Ball farther away, marking out of view |
| 68.5–68.6 | (240, 75) | 32 | Held ball near lamp; glare and low contrast |
| 68.7 | (240, 80) | 32 | Release starts |
| 68.8 | (240, 130) | 32 | Moving ball visibly blurred |
| 69.1 | absent | n/a | Ball has left the visible frame |

The original tracker from commit `3358083` detects (229,116) at 45 seconds and
fails on the 58- and 65-second frames using the same reconstructed initialization.
The regression requires the actual ball's region, rejects the wrist, and checks
that release detections remain on the ball. It explicitly permits a lost result
when blur/glare prevents reliable confirmation. It does not establish full recall
through a real drop or validate camera-to-overlay latency.
