# HandsOn Physics WebSocket protocol (draft v0.2)

This is the contract between the Flutter app (Dev 1) and the FastAPI backend
(Devs 2-4). If either side needs a change, edit this file in the same commit
as the code so both sides stay in sync.

Status: **draft**. v0.2 adopts the frame transport Dev 2 built in
`backend/app.py` (branch `Dev2`). The app and `mobile/tool/mock_server.py`
speak it, and `mobile/test/integration/live_backend_test.dart` checks a running
backend against it. Open questions are listed at the end.

## Connection

- Endpoint: `ws://<host>:8000/ws/frames`. Health check: `GET /health`.
- One WebSocket per phone. The server keeps one tracking session per socket.
- The client sends a `config` message first, then streams frames.

## Units and coordinate systems

| Space | Origin | Axes | Units | Used for |
|---|---|---|---|---|
| Frame pixels | top-left of the JPEG the client sent | x right, y **down** | px | `pixel`, `bbox`, `target_px` |
| World | wherever the backend puts it (first tracked point is fine) | x right, y **up** | SI (m, m/s, m/s², N, J) | everything physical |

The app maps frame pixels to screen pixels itself (it knows how the preview is
scaled), so the backend never needs to know the phone's screen size.

The backend may process frames at a different width (`CV_WORKING_WIDTH`), but
every pixel coordinate it sends back must be in the **client's** frame pixels
(`PreprocessedFrame.to_source_coords`). The app sends 320 px wide frames, so
with the default working width of 640 no scaling happens.

## Client to server

### `config` (text, JSON)

Sent once after connecting, after every reconnect, and whenever the user
changes a setting.

```json
{
  "type": "config",
  "mode": "ramp",
  "mass_kg": 0.1,
  "px_per_m": 812.5,
  "target_px": { "x": 161.0, "y": 118.5 },
  "frame_size": { "w": 320, "h": 240 }
}
```

| Field | Type | Notes |
|---|---|---|
| `mode` | string | `free_fall`, `ramp`, `pendulum`, `collision` |
| `mass_kg` | number | user input, default `0.1` |
| `px_per_m` | number or null | from the ruler calibration, in **frame** pixels; null until calibrated |
| `target_px` | `{x,y}` or null | where the user tapped the object, frame pixels; null means "auto-detect" |
| `frame_size` | `{w,h}` | size of the JPEGs that follow |

The backend applies `config` separately from frame metadata. Valid settings
apply from the next frame without an acknowledgement; invalid settings get an
`error` message and leave the previous configuration unchanged.

### Video frame (two messages)

1. Text, JSON metadata for the image that follows:

   ```json
   { "frame_id": 12, "timestamp": 41.237 }
   ```

   | Field | Notes |
   |---|---|
   | `frame_id` | counter starting at 0 for each connection, +1 per frame |
   | `timestamp` | capture time in seconds on the phone's **monotonic** clock. Only differences are meaningful (use it for dt); it is not Unix time |

2. Binary: the JPEG bytes, `frame_size.w` x `frame_size.h`, quality 0.7.

The backend accepts binary frames up to 512 KiB. An oversized frame receives
an `error` response, including its `frame_id` when metadata supplied one.

### Flow control

The client keeps **at most 2 frames in flight**: it sends a new frame only when
fewer than 2 are awaiting a reply. The server keeps only the newest frame and
drops older ones while busy, so a reply to frame N tells the client that every
frame up to N is settled. A frame with no reply after 1 s is forgotten.

So the server must reply to **every frame it processes**, even when nothing is
tracked (`"tracked": false`). Otherwise the client sends at most 2 frames per
second.

## Server to client

Every reply to a frame carries that frame's `frame_id`. The client uses it for
flow control and to measure round-trip latency.

### `frame` (text, JSON): CV engine report

What `backend/app.py` sends today, before the physics stage exists. The full
field list is in `backend/README.md` (Dev 2). The app uses every report for
flow control and latency. Until it receives its first `state`, it also draws
the marker and the x(t) chart from the object marked `"target": true`:

```json
{"type": "frame", "frame_id": 12, "timestamp": 41.237, "tracked": true,
 "target_id": 1,
 "objects": [
   {"id": 1, "label": "red", "target": true,
    "pixel": {"x": 164.8, "y": 146.5}, "bbox": {"x": 149.2, "y": 131.2, "w": 31.5, "h": 31.5},
    "position": {"x": 0.3301, "y": 0.1622}}
 ],
 "process_ms": 4.4, "latency_ms": 4.6}
```

- `pixel` and `bbox` are in the pixels of the frame the app sent (x right,
  y down), the same space as `target_px`.
- `position` is in metres (y up), or `null` without a calibration.

### `state` (text, JSON): physics result, one per processed frame

Replaces `frame` once the kinematics stage is in. This is what the app draws.

```json
{
  "type": "state",
  "frame_id": 42,
  "timestamp": 1.4,
  "tracked": true,
  "pixel": { "x": 172.3, "y": 96.1 },
  "bbox": { "x": 160.0, "y": 84.0, "w": 24.0, "h": 24.0 },
  "position": { "x": 0.212, "y": 0.104 },
  "velocity": { "x": 0.84, "y": -0.31 },
  "acceleration": { "x": 2.95, "y": -1.07 },
  "forces": [
    { "name": "gravity", "x": 0.0, "y": -0.981 },
    { "name": "normal", "x": 0.336, "y": 0.922 },
    { "name": "friction", "x": -0.05, "y": 0.018 },
    { "name": "net", "x": 0.295, "y": -0.107 }
  ],
  "energy": { "kinetic": 0.0405, "potential": 0.102, "thermal": 0.0031 },
  "extras": { "angle_deg": 20.0, "mu": 0.06 }
}
```

| Field | Notes |
|---|---|
| `frame_id` | echo of the frame's `frame_id` |
| `timestamp` | echo of the frame's capture `timestamp` (s) |
| `tracked` | false means everything below may be missing or null |
| `pixel`, `bbox` | client frame pixels |
| `position`, `velocity`, `acceleration` | world space, SI, already smoothed |
| `forces` | list; known names: `gravity`, `normal`, `friction`, `tension`, `gravity_parallel`, `gravity_perpendicular`, `net`. Unknown names are drawn in a neutral colour |
| `energy` | joules; any key may be omitted |
| `extras` | mode-specific values the app shows as readouts (`angle_deg`, `mu`, `theta_deg`, `momentum`, `restitution`, ...) |

Extra fields (`process_ms`, `stats`, ...) are allowed and ignored.

### `error` (text, JSON)

```json
{ "type": "error", "message": "could not decode image bytes", "frame_id": 12 }
```

`frame_id` is present when the error is about one frame; the app then counts
that frame as answered.

## Open questions

1. Is a 320 px JPEG at quality 0.7 and about 15 fps enough for tracking a
   tennis ball? The app can send wider frames if needed (`AppConfig.frameWidth`).
2. ~~Shape of the entries in `objects`.~~ Settled by Dev 2: see `frame`
   above.
3. Collision mode needs two objects: proposal is `"objects": [state, state]` in
   a later version.

## Changelog

- **v0.2, later**: documented the `objects` entries in `frame` reports; the
  app now shows the tracked target from them. No wire changes.
- **v0.2**: endpoint `/ws/frames`; per-frame metadata text + raw JPEG instead
  of a 12-byte binary header; `seq`/`t` renamed to `frame_id`/`timestamp`;
  added the `frame` report; replies settle all older frames; `error` may carry
  `frame_id`.
- **v0.1**: first draft.
