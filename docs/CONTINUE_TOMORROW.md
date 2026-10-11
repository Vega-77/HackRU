# Resume HandsOnPhysics tracking work

Continue from the WIP on branch `devFour`; do not repeat the initial investigation. Read `docs/TRACKING_OVERNIGHT_REPORT.md` first. Do not merge into `main` until the user reviews and verifies physical-camera tracking.

The October 11 recording showed a gray ball initially selected, delayed marker updates at release, and later identity drift to the person's face/neck/torso while the ball was absent. The associated `ball_free_fall_log_3.txt` is empty. The most likely acquisition/identity causes and evidence are documented in the report.

Preserved changes:

- WIP commit `d25fdde` carries capture timestamp/pacing and physics investigation edits. They are unverified; inspect this diff before relying on it.
- The current worktree changes to `backend/cv_engine/foreground.py` and `backend/cv_engine/universal.py` add bounded scene-lightness compensation and padded-ROI segmentation fallback for a clipped round target.
- `backend/extract_oct11_recording.py` and `backend/tests/fixtures/gray_ball_oct11/` support a reconstructed screen-recording replay. This is not raw backend input.

Last focused test result: `backend/.venv/bin/python -m pytest backend/tests/test_recorded_gray_ball.py -q` passed 5/5. The reconstructed clip replay improved from 2 correct / 21 wrong identities to 12 correct / 1 wrong / 2 missed among 14 labeled-visible frames, with center RMS error decreasing from 37.32 px to 2.75 px. It still loses the ball during fast blurred movement and produced a false identity around 47 seconds. Synthetic/reconstructed success does not verify a real camera. No full backend or Flutter suite, analysis, or build was run.

Next steps:

1. Review the recorded WIP and the current foreground/tracker diffs; preserve all user work.
2. Add a test that exercises the exact production tracking path against the extracted fixture and asserts target identity and absent-ball behavior.
3. Ask the user to run the physical-camera procedure in `docs/TRACKING_OVERNIGHT_REPORT.md`, saving a non-empty diagnostics log and original backend frames if possible.
4. Measure capture-to-display age, processing time, dropped/stale frames, and capture timestamp ordering. Do not infer physical time from response arrival time.
5. Address fast-motion loss and absent-target false matches only from reproduced evidence. Keep predictions distinct from confirmed detections.
6. Validate free-fall estimates from reliable capture-time observations and report uncertainty; never force acceleration to 9.81 m/s².
7. Run focused backend tests first, then the needed full backend and Flutter checks. Report real-camera validation separately from synthetic/reconstructed results.

Do not merge or deploy without the user's physical-camera verification.
