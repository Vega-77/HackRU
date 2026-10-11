# HandsOn Physics WebSocket protocol (draft v0.3)

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
| ARKit world (iOS) | where the AR session started | ARKit's: y **up** against gravity, x and z level | m | `camera_to_world`, `ar_plane`, every `*_3d` field |

With an AR surface, "world" is 2D coordinates on that surface: on a vertical
board x is right and y is straight up; on a table x is right and y points away
from the camera. The `*_3d` fields give the same values in ARKit world space.

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
| `target_bbox` | `{x,y,w,h}` or null | optional box around the tapped object in frame pixels; helps track objects outside detector categories |
| `second_target_px`, `second_target_bbox` | as above, optional | collision mode only: the other object, selected the same way. It is followed the same way as the first and reported in `objects` with `label: "selected_2"`; the first is `label: "selected"` and stays the `target` |
| `debug_tracking` | boolean, optional | return numeric search bounds, candidate count, score and rejection reason; no images are stored |
| `frame_size` | `{w,h}` | size of the JPEGs that follow |
| `ar_plane` | object or null | iOS only: the surface the object moves on, from an ARKit raycast. `{"point": [x,y,z], "normal": [x,y,z], "offset_m": 0.0}` in ARKit world metres. `offset_m` moves it towards the camera, such as by a ball's radius. Takes priority over `px_per_m`; null removes it |

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
   | `intrinsics` | iOS with ARKit: `{fx, fy, cx, cy}` of the camera, in the pixels of the JPEG that follows |
   | `camera_to_world` | iOS with ARKit: 16 numbers, a row-major 4x4 transform from camera axes (x right, y up, z towards the viewer, for the image as sent) to ARKit world |

   With both pose fields and an `ar_plane`, the backend casts a ray through
   the object's centroid and intersects it with the surface, so positions are
   true 3D and the phone may move during the experiment.

2. Binary: the JPEG bytes, `frame_size.w` x `frame_size.h`, quality 0.7.

The backend accepts binary frames up to 512 KiB. An oversized frame receives
an `error` response, including its `frame_id` when metadata supplied one.
Frame IDs must be increasing nonnegative integers and capture timestamps must
be finite numbers. Invalid frame metadata gets an `error` without ending the
WebSocket session.

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
- `screen_axes` (when calibrated): where world +x and +y point in the frame
  at the object, in frame pixels per metre (y down). The app draws a vector
  `(vx, vy)` along `vx * x + vy * y`, so arrows lie on a tilted surface.
- `position_3d` (with an `ar_plane`): the same point in ARKit world space.
- `source` identifies `motion`, `manual`, `color`, or `mediapipe` observations.
  `tracking_status` distinguishes `detected`, `low_confidence`, `searching`, and `lost`;
  a selected patch first reports `initialized` with `tracked: false` until a later
  image verifies it. A tap without `target_bbox` is boxed by the backend when the
  object under it stands out from its surroundings with a clear outline; a tap on
  bare or evenly textured background, or on an object cut off by the frame edge,
  reports `selection_required`: draw an object box. Invalid or flat boxes report
  `invalid_selection` or `insufficient_contrast`. The selected object keeps one `id`
  for as long as it is followed, and gets a new one when the selection changes. Its
  `bbox` is the object the backend separated inside the user's box (not the fingers
  or table the box also took in), so it can be smaller than `target_bbox`.
  After loss, recovery compares the retained original appearance across the full
  frame and rejects ambiguous or different-color matches.
  `confidence` equals the object's existing `score`. No predicted or demo objects are sent.

### Selection proposal and initialization handshake

Selection messages use the same WebSocket and metadata-plus-JPEG framing.
Coordinates are in the attached JPEG's pixels. Each request includes a
`selection_id`, increasing `frame_id`, and original capture `timestamp`.

1. Send metadata with `type: "acquire"` and `target_px: {x,y}`, then the exact
   selected JPEG. The reply is `type: "acquisition"`, echoing the IDs and timestamp,
   with `status: "proposed"`, `bbox: {x,y,w,h}`, and a `reason`. Unclear regions
   return `status: "manual_required"` and `bbox: null`; malformed images return
   `status: "failed"`. All proposal replies have `tracked: false`.
2. Display the proposed box on that image and obtain user confirmation. Allow a
   manual replacement. Send normal `config` with the confirmed `target_px`,
   `target_bbox`, `frame_size`, and `initialization_required: true`.
3. Send metadata with `type: "initialize"`, then the same selected JPEG. This
   image bypasses the replaceable live-frame slot and is processed under the
   pipeline lock. The reply is `type: "initialization"`, echoing the request IDs
   and timestamp, with `status: "initialized"` or `"failed"`, `reason`, `bbox`,
   and `tracked: false`. Wait for this acknowledgment before sending live frames.
   In collision mode with a second object, send a second `initialize` with
   `"target": "second"` and the picture that object was selected in, after the
   first one is acknowledged (initializing the first clears the second). The
   reply echoes `target`. Live frames wait until both are initialized.
4. After success, send ordinary live frames. Only a subsequent image can report
   visual detection. After failure, stop live frames and offer reselection; a
   new config and initialization request can retry on the same connection.

Normal frames retain the latest-frame dropping policy. Reconnects require
initialization again. Legacy clients that omit `initialization_required` retain
their existing frame flow; the new frontend always uses the handshake for a
captured manual selection. No fixed-size tap template is created.

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
| `screen_axes` | as in `frame` objects; the app draws vectors along them when present |
| `position_3d`, `velocity_3d`, `acceleration_3d`, `forces_3d` | with an `ar_plane` only: the same vectors in ARKit world space, for a renderer that anchors arrows in 3D |
| `energy` | joules; any key may be omitted |
| `extras` | mode-specific values the app shows as readouts (`angle_deg`, `mu`, `theta_deg`, `momentum`, `restitution`, ...) |

Additional diagnostic fields are optional and backward compatible:

- `timestamp_source`: `capture` when the client supplied its frame timestamp,
  otherwise `server_receive`. The latter allows pixel tracking but withholds
  motion derivatives. Live capture timestamps must strictly increase.
- `process_ms`: backend CV and physics duration. `queue_ms`: wait before that
  processing starts. `latency_ms`: backend receive-to-result duration, not
  network RTT. All three use the server's monotonic clock.
- `physics_quality`: fit sample count, `span_s`, `position_residual_m`,
  `acceleration_std_mps2`, derivative validity flags and `reason`.
  Missing/uncertain acceleration is omitted, never replaced with gravity.
  Reasons include `insufficient_samples`, `insufficient_time_span`,
  `acceleration_uncertain`, and `capture_timestamp_missing`.
- `stats`: cumulative received, processed, dropped, and error counters.

The client logs observation age as local capture/encoding age plus frame RTT;
it does not subtract clocks on different machines. Where the camera API only
supplies frame presentation/availability time, that age excludes unknown
sensor delay. A live marker older than one second is cleared with local status
`stale`, without adding a fabricated sample to telemetry.

Transport starts with two frame credits and expands to cover one measured live
RTT at the requested capture cadence, capped at 32. Initialization duration
does not size this window. Regular frames still use the backend's latest-frame
slot; a response retires all older outstanding IDs. Duplicate captures and
out-of-order state IDs/timestamps are discarded by the client.

### `error` (text, JSON)

```json
{ "type": "error", "message": "could not decode image bytes", "frame_id": 12 }
```

`frame_id` is present when the error is about one frame; the app then counts
that frame as answered.

When processing a frame crashes, the error also carries an `error` object so
the cause can be found from a screenshot of the app:

```json
{
  "type": "error",
  "message": "could not process frame: ValueError: operands could not be broadcast",
  "frame_id": 12,
  "error": {
    "kind": "ValueError",
    "detail": "operands could not be broadcast",
    "where": "backend/cv_engine/universal.py:69 in detect",
    "server": "209bcec"
  }
}
```

- `kind`: the exception class. `detail`: its message, at most 300 characters.
- `where`: the innermost line of `backend/` or `physics_engine/` code the
  crash went through, or null if there is none.
- `server`: the first 7 characters of the deployed commit, or `local` when
  the backend runs outside Render. `GET /health` reports the same value as
  `commit`.

The app shows all of it in its error banner, plus how many frames in a row
gave the same error.

## Open questions

1. Is a 320 px JPEG at quality 0.7 and about 15 fps enough for tracking a
   tennis ball? The app can send wider frames if needed (`AppConfig.frameWidth`).
2. ~~Shape of the entries in `objects`.~~ Settled by Dev 2: see `frame`
   above.
3. Collision mode needs two objects: proposal is `"objects": [state, state]` in
   a later version.

## Changelog

- **v0.3, collisions**: collision mode can follow two selected objects:
  `config` takes `second_target_px` and `second_target_bbox`, and
  `initialize` takes `"target": "second"`. Clients that send neither see no change.

- **v0.3, tracking fixes**: a tap without a box is boxed by the backend when the
  object stands out; the selected object keeps its `id` through misses and
  re-acquisition; `state` keeps velocity through gaps up to 0.5 s instead of
  restarting after one missed frame. No wire changes.
- **v0.3, later**: crash errors carry an `error` object (`kind`, `detail`,
  `where`, `server`) and `/health` reports `commit`. Both are additions.
- **v0.3**: iOS ARKit support. Frame metadata may carry `intrinsics` and
  `camera_to_world`; `config` may carry `ar_plane`; replies add
  `screen_axes`, `position_3d` and the other `*_3d` vectors. Clients that send
  none of these see v0.2 behaviour plus `screen_axes`.

- **v0.2, later**: documented the `objects` entries in `frame` reports; the
  app now shows the tracked target from them. No wire changes.
- **v0.2**: endpoint `/ws/frames`; per-frame metadata text + raw JPEG instead
  of a 12-byte binary header; `seq`/`t` renamed to `frame_id`/`timestamp`;
  added the `frame` report; replies settle all older frames; `error` may carry
  `frame_id`.
- **v0.1**: first draft.
