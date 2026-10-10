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

## Detection and tracking

Two detectors, picked with `CV_MODE` (or a config message, see below):

| mode | what it runs | cost on a laptop CPU |
|---|---|---|
| `color` (default) | HSV thresholding + contours for colored objects (`red`, `orange`, `yellow`, `green`, `blue`, `purple`) | ~2-3 ms/frame |
| `mediapipe` | MediaPipe EfficientDet-Lite0, 80 COCO classes (`sports ball`, `bottle`, `cup`, ...) | ~25-30 ms/frame |
| `both` | both of the above | ~30 ms/frame |

Color mode is the reliable choice for lab setups: use a brightly colored ball, or stick
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

At any time the client can change tracking settings, effective from the next frame:

```json
{"type": "config", "mode": "both", "colors": ["red", "blue"], "mediapipe_labels": ["sports ball"]}
```

Other keys: `min_area`, `mediapipe_score`, `max_distance`, `max_missed`, `min_hits`.
The server replies `{"type": "config", "config": {...}}` with the full settings, or an
error message if a value is invalid (the previous settings stay in place).

Server to client, per processed frame:

```json
{"type": "frame", "frame_id": 12, "timestamp": 1728575000.12,
 "size": [640, 360], "source_size": [960, 540], "scale": 0.66667,
 "objects": [
   {"id": 1, "label": "red", "source": "color", "score": 0.98,
    "centroid": [329.6, 292.9], "bbox": [298.5, 262.5, 63.0, 63.0],
    "centroid_norm": [0.34336, 0.54239], "bbox_norm": [0.31094, 0.48611, 0.06563, 0.11667],
    "area": 3080.0, "hits": 57, "world": [0.3301, 0.1622], "world_width": 0.0401}
 ],
 "calibration": {"method": "aruco", "status": "ok", "space": "px",
   "image_points": [[...], [...], [...], [...]], "world_points": [[0, 0.4], [0.6, 0.4], [0.6, 0], [0, 0]],
   "world_to_image": [[...], [...], [...]], "reprojection_error_px": 0.0, "frames_since_seen": 0,
   "settings": {"method": "aruco", "width_m": 0.6, "height_m": 0.4}},
 "process_ms": 6.5, "latency_ms": 6.6,
 "stats": {"received": 13, "dropped": 0, "processed": 13, "decode_errors": 0}}
```

If frames arrive faster than the server can process them, only the newest one is
kept and the rest are counted in `dropped`, so latency never builds up.

`centroid` and `bbox` (`[x, y, w, h]`) are in the pixel space of the image the client sent;
the `_norm` versions are 0-1 fractions of the frame, which is the easiest form for drawing
overlays at any resolution. `world` is the centroid in meters on the calibrated plane and
`world_width` the object's width there; both are `null` while there is no calibration.

`calibration.world_to_image` is the 3x3 homography from meters to image pixels (the space
named by `space`: `px` for the image you sent, `norm` for 0-1 fractions). The AR renderer can
use it to draw a vector computed in meters: multiply `[X, Y, 1]` by the matrix and divide by
the third component.

## Tests

```bash
python -m pytest
```
