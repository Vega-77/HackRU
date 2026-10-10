# HandsOn Physics CV engine (backend)

Python backend that receives camera frames from the mobile app over a WebSocket,
downsamples and color-converts them, and (in later steps) tracks objects and maps
them to tabletop coordinates for the kinematics stage.

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

## WebSocket protocol (`/ws/frames`)

Client to server, per frame:
1. *(optional)* a text message with JSON metadata, e.g. `{"frame_id": 12, "timestamp": 1728575000.12}`.
   Any extra fields (such as AR anchor data) are passed through to later stages.
2. a binary message with the JPEG bytes.

Server to client, per processed frame:

```json
{"type": "frame", "frame_id": 12, "timestamp": 1728575000.12,
 "size": [640, 360], "source_size": [960, 540], "scale": 0.66667,
 "objects": [], "process_ms": 4.4, "latency_ms": 4.6,
 "stats": {"received": 13, "dropped": 0, "processed": 13, "decode_errors": 0}}
```

If frames arrive faster than the server can process them, only the newest one is
kept and the rest are counted in `dropped`, so latency never builds up.
`objects` stays empty until the tracking step lands.

## Tests

```bash
python -m pytest
```
