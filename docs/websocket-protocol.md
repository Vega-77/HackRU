# HandsOn Physics WebSocket protocol (v1)

Connect to `ws://<host>:8000/ws`. The server sends a `hello` JSON message with a
session ID and default configuration. Each connection owns its tracker, physics
state, and a one-frame pending queue. Reconnects create a fresh session.

Send configuration as a text JSON message:

```json
{"type":"config","version":1,"mode":"ramp","mass_kg":0.1,"meters_per_pixel":0.0005,"rotation_degrees":0}
```

Modes are `ramp` and `free_fall`. Calibration is optional; omit
`meters_per_pixel` until a known scale is measured. The server replies with
`config_ack` containing the active configuration. Each config message replaces
the previous configuration; include settings you want to retain. An update applies to
frames received after it. The client should rotate and downsample images before
transmission; `rotation_degrees` records the rotation applied so adapters can
interpret the image consistently. The image coordinate origin is top-left,
with x rightward and y downward. Metric vectors follow the same axes.

Send each frame as one binary WebSocket message:

| Bytes | Value |
| --- | --- |
| 0–3 | Unsigned 32-bit `frame_id`, big endian; strictly increasing per connection |
| 4–11 | Unsigned 64-bit Unix capture timestamp in milliseconds, big endian; strictly increasing per connection |
| 12 onward | JPEG bytes, including SOI and EOI markers |

The complete binary message must be no larger than 512 KiB. For the MVP, aim
for 640×480 JPEG at 10–15 FPS. The backend drops queued frames when processing
falls behind, keeping the newest frame. Do not use server arrival times for
physics derivatives.

For every processed frame, the server sends JSON:

```json
{
  "type":"result","version":1,"frame_id":7,
  "capture_timestamp_ms":1234,"server_received_timestamp_ms":1260,
  "processing_ms":2.1,"dropped_frames":0,"status":"tracked",
  "measurement":{
    "x_px":12.0,"y_px":34.0,"confidence":0.9,
    "position_m":{"x":0.12,"y":0.34},
    "velocity_m_s":null,"acceleration_m_s2":null
  }
}
```

`status` is `tracked`, `tracking_lost`, or `tracking_unavailable`. `measurement`
is `null` when there is no tracked object. Fields awaiting calibration or the
physics adapter are `null`. `processing_ms` measures backend processing only,
not network round-trip time. `dropped_frames` is cumulative for the session.

Malformed messages receive `{ "type":"error", "version":1, "code":"...", "detail":"..." }`.
The connection stays open for recoverable input errors. The default server
currently reports `tracking_unavailable` until Dev 2's tracker is connected;
it does not produce synthetic coordinates.

## Integration contracts

Dev 2 supplies a per-session tracker factory whose object implements
`track(jpeg: bytes, config: ClientConfig) -> TrackedObject | None`. `TrackedObject`
contains `x_px`, `y_px`, and `confidence` (0–1). JPEG decoding and object
detection belong in that adapter.

Dev 3 supplies a per-session physics factory whose object implements
`update(capture_timestamp_ms: int, tracked: TrackedObject, config: ClientConfig)
-> Kinematics`. The engine should reset on a new session and use capture
timestamps. `Kinematics` currently contains optional metric position, velocity,
and acceleration vectors; mode-specific force and energy fields can be added
once their team contract is settled.

Pass the factories to `create_app(tracker_factory=..., physics_factory=...)`.
The server runs the pipeline in a worker thread so image processing does not
block other WebSocket clients. This deployment uses one Uvicorn worker because
session state is local to the process.
