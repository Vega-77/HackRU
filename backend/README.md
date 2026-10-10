# HandsOn Physics CV engine (backend)

Python backend that receives camera frames from the mobile app over a WebSocket,
downsamples and color-converts them, detects and tracks objects with stable IDs,
and maps them to metric coordinates on the plane of motion for the kinematics stage.

## Setup

```bash
cd backend
python -m pip install -r requirements.txt
```

## Run

```bash
uvicorn app:app --host 0.0.0.0 --port 8000
```

Then, in another terminal, stream frames to it the way the app will:

```bash
python stream_client.py --source synthetic      # moving red ball, no camera needed
python stream_client.py --source 0              # laptop webcam
python stream_client.py --source clip.mp4 --fps 30
```

The client prints send rate, bandwidth, frames dropped by the server, and latency.
Use `--send-width` and `--quality` to tune how much the phone downsamples and compresses.
`CV_WORKING_WIDTH` (default 640) sets the resolution the server processes at.

## Debug view and sample clips

**Live, from the phone or the test client:** while frames are streaming, open
`http://<server>:8000/debug` in any browser. It shows the newest connection's frames with
boxes, IDs, motion trails, metric positions, the calibrated plane grid and +X/+Y axes,
plus processing time, latency and dropped frames. Everything drawn comes from the same JSON
the app receives, so if it looks right here, the app is getting the right data.

**Offline, on a video file:**

```bash
python run_clip.py samples/pendulum.mp4 --aruco 0.60 0.40           # writes samples/pendulum_debug.mp4
python run_clip.py my_clip.mp4 --aruco 0.30 0.20 --show              # also a live window (desktop only)
```

It writes an annotated video and a `<clip>_tracks.csv` with every tracked position (pixels
and meters), which is handy test input for the kinematics stage.

**Sample clips** in `samples/` simulate the three experiments filmed by a tilted, slightly
shaky phone, on a 0.60 x 0.40 m board with ArUco markers. Each has a `_truth.csv` with the
true positions from the physics simulation, and `run_clip.py` scores against it:

| clip | motion | found | ID switches | position error (rms) |
|---|---|---|---|---|
| `ramp.mp4` | red ball rolling down a 25 degree incline | 44/45 frames | 0 | 0.4 mm |
| `pendulum.mp4` | blue bob, L = 0.28 m, from 30 degrees | 119/120 | 0 | 0.3 mm |
| `carts.mp4` | red cart hits resting green cart (elastic) | 89/90 each | 0 | 0.5 / 0.3 mm |

The one missed frame per object is the first one, since new tracks are confirmed on their
second frame. These are clean synthetic videos, so expect larger errors on real footage
(lighting, motion blur, the ball sitting slightly in front of the board).
Regenerate them with `python samples/generate_samples.py`.

## Detection and tracking

Two detectors, picked with `CV_DETECTOR` (or `"detector"` in a config message, see below):

| detector | what it runs | cost on a laptop CPU |
|---|---|---|
| `color` (default) | HSV thresholding + contours for colored objects (`red`, `orange`, `yellow`, `green`, `blue`, `purple`) | ~2-3 ms/frame |
| `mediapipe` | MediaPipe EfficientDet-Lite0, 80 COCO classes (`sports ball`, `bottle`, `cup`, ...) | ~25-30 ms/frame |
| `both` | both of the above | ~30 ms/frame |

The color detector is the reliable choice for lab setups: use a brightly colored ball, or stick
colored tape on carts and pendulum bobs. `CV_COLORS=red,blue` limits which colors are tracked.
The MediaPipe model (4.6 MB) downloads to `models/` on first use.
On a headless Linux server MediaPipe also needs `libegl1` and `libgles2` from apt.

A centroid tracker then assigns each object an ID that stays the same across frames. It
matches against each track's predicted position, so fast-moving objects keep their ID, and it
holds an ID through up to 10 missed frames (brief occlusion or motion blur). A new object
is reported only once it has been seen in 2 frames, which filters out one-frame noise.

## Spatial mapping (pixels to meters)

A perspective transform (homography) maps image pixels onto the flat plane the object
moves in, in meters. It is exact for motion *in* that plane, so calibrate the right one:
the tabletop for carts, or a vertical board behind the ramp or pendulum, parallel to its swing.

World axes: origin at the bottom-left corner of the calibration rectangle, +X right, +Y up
(on a vertical board +Y points against gravity). Units are meters.

**ArUco markers (recommended).** Run `python make_markers.py`, print the four markers, and tape
them at the corners of a rectangle on that plane: 0 top-left, 1 top-right, 2 bottom-right,
3 bottom-left as the camera sees them. Measure width and height between marker *centers*.
The markers are re-detected every frame, so the phone can be handheld. If a marker is briefly
covered, the last fit is kept for 15 frames (status `held`) before the plane is reported lost
(`searching`). `python make_markers.py --sheet 0.18 0.12` makes a single printable page instead.

```json
{"type": "calibrate", "method": "aruco", "width_m": 0.60, "height_m": 0.40}
```

**Manual.** Send four image points (e.g. table corners the user taps) in TL, TR, BR, BL order,
in the pixels of the image you send, or as 0-1 fractions with `"normalized": true`.
Use `world_points` instead of `width_m`/`height_m` for a non-rectangular layout, or more than four points.

```json
{"type": "calibrate", "method": "manual", "image_points": [[212, 80], [590, 95], [610, 400], [190, 390]],
 "width_m": 0.60, "height_m": 0.40}
```

**From the app's ruler (`px_per_m`).** If the app's config message has `px_per_m`, the server
uses a plain scale: `x = px / px_per_m`, `y = (frame_h - py) / px_per_m`, origin at the frame's
bottom-left. That assumes the phone faces the plane of motion squarely; ArUco or manual
calibration, when set, takes priority over it.

`{"type": "calibrate", "method": "none"}` turns mapping off. The server answers with
`{"type": "calibration", "calibration": {...}}`, or an error (the previous calibration stays).

On synthetic tilted views the mapped ball position is within 0.5 mm of the truth.
Mapping adds about 1-2 ms per frame.

To try it with the test client: `python stream_client.py --source 0 --aruco 0.60 0.40`.

## WebSocket protocol (`/ws/frames`)

Client to server, per frame:
1. *(optional)* a text message with JSON metadata, e.g. `{"frame_id": 12, "timestamp": 1728575000.12}`.
   Any extra fields (such as AR anchor data) are passed through to later stages.
2. a binary message with the JPEG bytes.

The app sends a `config` message on connect and whenever a setting changes
(see `docs/protocol.md` on Dev1); it applies from the next frame:

```json
{"type": "config", "mode": "ramp", "mass_kg": 0.1, "px_per_m": 812.5,
 "target_px": {"x": 161.0, "y": 118.5}, "frame_size": {"w": 320, "h": 240}}
```

- `px_per_m` turns on scale calibration (see Spatial mapping); `null` turns it off.
- `target_px` is where the user tapped the object, in frame pixels. The nearest tracked object
  (within 20% of the frame width) becomes the target and is followed by ID from then on,
  re-acquired near its last position if lost. `null` means auto: the longest-tracked object.
- `mode` (`free_fall`, `ramp`, `pendulum`, `collision`) and `mass_kg` are kept for the physics stage.
- Optional tracking keys can ride along: `detector`, `colors`, `min_area`, `mediapipe_labels`,
  `mediapipe_score`, `max_distance`, `max_missed`, `min_hits`.

A valid config gets no reply (the app treats unknown message types as errors). An invalid one
gets an `error` message and changes nothing.

Server to client, per processed frame:

```json
{"type": "frame", "frame_id": 12, "timestamp": 41.237,
 "size": [640, 360], "source_size": [960, 540], "scale": 0.66667,
 "tracked": true, "target_id": 1,
 "objects": [
   {"id": 1, "label": "red", "source": "color", "score": 0.98, "target": true,
    "pixel": {"x": 329.6, "y": 292.9}, "bbox": {"x": 298.5, "y": 262.5, "w": 63.0, "h": 63.0},
    "pixel_norm": {"x": 0.34336, "y": 0.54239}, "bbox_norm": {"x": 0.31094, "y": 0.48611, "w": 0.06563, "h": 0.11667},
    "area": 3080.0, "hits": 57, "position": {"x": 0.3301, "y": 0.1622}, "width_m": 0.0401}
 ],
 "calibration": {"method": "aruco", "status": "ok", "space": "px",
   "image_points": [[...], [...], [...], [...]], "world_points": [[0, 0.4], [0.6, 0.4], [0.6, 0], [0, 0]],
   "world_to_image": [[...], [...], [...]], "reprojection_error_px": 0.0, "frames_since_seen": 0,
   "settings": {"method": "aruco", "width_m": 0.6, "height_m": 0.4}},
 "process_ms": 6.5, "latency_ms": 6.6,
 "stats": {"received": 13, "dropped": 0, "processed": 13, "decode_errors": 0}}
```

If frames arrive faster than the server can process them, only the newest one is
kept and the rest are counted in `dropped`, so latency never builds up. Every processed
frame gets a reply, with `"tracked": false` and empty `objects` when nothing is found.

`pixel` (the object's center) and `bbox` are in the pixel space of the image the client sent
(x right, y down); the `_norm` versions are 0-1 fractions of the frame. `position` is the
center in meters on the calibrated plane (y up) and `width_m` the object's width there; both
are `null` while there is no calibration. `target` marks the object the app should follow.

`calibration.world_to_image` is the 3x3 homography from meters to image pixels (the space
named by `space`: `px` for the image you sent, `norm` for 0-1 fractions). The AR renderer can
use it to draw a vector computed in meters: multiply `[X, Y, 1]` by the matrix and divide by
the third component.

## Tests

```bash
python -m pytest
```
