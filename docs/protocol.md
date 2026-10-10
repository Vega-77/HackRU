# HandsOn Physics WebSocket protocol (draft v0.1)

This is the contract between the Flutter app (Dev 1) and the FastAPI backend
(Devs 2-4). The app is written against exactly this document; if the backend
needs a change, edit this file in the same commit as the code so both sides
stay in sync.

Status: **draft, owned by Dev 1 + Dev 4**. Open questions are listed at the end.

## Connection

- Endpoint: `ws://<host>:8000/ws` (default port 8000, path `/ws`).
- One WebSocket per phone. The server keeps one tracking session per socket.
- The client sends a `config` message first, then starts streaming frames.

## Units and coordinate systems

| Space | Origin | Axes | Units | Used for |
|---|---|---|---|---|
| Frame pixels | top-left of the JPEG the client sent | x right, y **down** | px | `pixel`, `bbox`, `target_px` |
| World | wherever the backend puts it (first tracked point is fine) | x right, y **up** | SI (m, m/s, m/s², N, J) | everything physical |

The app maps frame pixels to screen pixels itself (it knows how the preview is
scaled), so the backend never needs to know the phone's screen size.

## Client to server

### `config` (text, JSON)

Sent once after connecting and again whenever the user changes a setting.

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

### Video frame (binary)

```
offset  size  type             meaning
0       4     uint32 BE        seq (frame counter, starts at 0)
4       8     float64 BE       capture time, seconds (monotonic clock on the phone)
12      ...   bytes            JPEG image, frame_size.w x frame_size.h
```

Python: `seq, t = struct.unpack(">Id", data[:12]); jpeg = data[12:]`
then `cv2.imdecode(np.frombuffer(jpeg, np.uint8), cv2.IMREAD_COLOR)`.

The client keeps **at most 2 frames in flight**: it sends the next frame only
after a `state` with a recent `seq` arrives. So the server should reply to
every frame (with `"tracked": false` if nothing was found), or the client will
stall for up to 1 second before it gives up waiting.

## Server to client

### `state` (text, JSON), one per received frame

```json
{
  "type": "state",
  "seq": 42,
  "t": 1.4,
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
| `seq` | echo of the frame's `seq`, used for latency and flow control |
| `t` | echo of the frame's capture time (s) |
| `tracked` | false means everything below may be missing or null |
| `pixel`, `bbox` | frame pixels |
| `position`, `velocity`, `acceleration` | world space, SI, already smoothed |
| `forces` | list; known names: `gravity`, `normal`, `friction`, `tension`, `gravity_parallel`, `gravity_perpendicular`, `net`. Unknown names are drawn in a neutral colour |
| `energy` | joules; any key may be omitted |
| `extras` | mode-specific values the app shows as readouts (`angle_deg`, `mu`, `theta_deg`, `momentum`, `restitution`, ...) |

### `error` (text, JSON)

```json
{ "type": "error", "message": "px_per_m is required for ramp mode" }
```

## Open questions for Dev 4

1. Port and path OK (`:8000/ws`)?
2. Frame size: the client sends 320 px wide JPEGs at quality 0.7, about 15 fps. Is that enough for tracking a tennis ball?
3. Collision mode needs two objects: proposal is `objects: [state, state]` in a later version.
