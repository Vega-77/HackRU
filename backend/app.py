"""FastAPI backend: receives camera frames from the mobile app over a WebSocket.

Protocol on ws://<host>:8000/ws/frames
  client -> server
    text   (optional) JSON metadata for the next image, e.g.
           {"frame_id": 12, "timestamp": 1728575000.123, "anchor": {...}}
           iOS ARKit clients add the camera: "intrinsics": {fx, fy, cx, cy} and
           "camera_to_world": [16 numbers, row-major] (see cv_engine/ar_plane.py)
    binary JPEG (or PNG) bytes of one downsampled camera frame
    text   (on connect, and whenever settings change) the app's session settings,
           plus optional tracking settings, applied from the next frame:
           {"type": "config", "mode": "ramp", "mass_kg": 0.1, "px_per_m": 812.5,
            "target_px": {"x": 161, "y": 118}, "frame_size": {"w": 320, "h": 240},
            "ar_plane": {"point": [x, y, z], "normal": [x, y, z]} | null,
            "detector": "motion", ...}  (or "color" with "colors": ["red", "blue"])
           No reply on success (the app treats unknown message types as errors);
           an invalid config gets {"type": "error"} and changes nothing.
    text   (any time) plane calibration for metric coordinates:
           {"type": "calibrate", "method": "aruco", "width_m": 0.6, "height_m": 0.4}
           {"type": "calibrate", "method": "manual", "image_points": [[x, y] x4],
            "width_m": 0.6, "height_m": 0.4}
           answered with {"type": "calibration", "calibration": {...}}
  server -> client
    text   JSON result for each frame that was processed ("state" with a mode):
           {"type": "frame", "frame_id", "timestamp", "size": [w, h],
            "source_size": [w, h], "scale", "latency_ms", "process_ms",
            "stats": {"received", "processed", "dropped", "decode_errors", "processing_errors"},
            "tracked", "target_id",
            "objects": [{"id", "label", "source", "score", "target",
                         "pixel": {x, y}, "bbox": {x, y, w, h},  (client frame pixels)
                         "pixel_norm", "bbox_norm", "area", "hits",
                         "position": {x, y} | null, "width_m",  (meters, y up)
                         "screen_axes": {"x": {x, y}, "y": {x, y}} | null,
                         "position_3d": {x, y, z} | null}],  (ARKit world, meters)
            "calibration": {"method", "status", "world_to_image", ...}}
           or {"type": "error", "message": ...} for a bad message. A frame that crashes
           the engine adds "error": {"kind", "detail", "where", "server"} (see describe_failure).

Frames that arrive while the engine is busy are dropped in favour of the newest
one, so the client never builds up lag. Dropped frames are never decoded.

Debug view: open http://<host>:8000/debug in a browser to watch the annotated stream
(boxes, IDs, trails, calibrated plane) of the most recent phone connection.

Run with:  uvicorn app:app --host 0.0.0.0 --port 8000 --ws-max-size 1048576
"""

from __future__ import annotations

import asyncio
import itertools
import json
import logging
import math
import os
import time
import traceback
from uuid import uuid4
from collections.abc import Callable
from dataclasses import dataclass

import cv2
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse, StreamingResponse

from cv_engine.frame_slot import LatestFrameSlot
from cv_engine.overlay import TrailHistory, draw_overlay
from cv_engine.pipeline import PipelineConfig, TrackingPipeline
from cv_engine.preprocess import PreprocessedFrame, decode_jpeg, preprocess_frame
from physics_stage import PhysicsSession

WORKING_WIDTH = int(os.environ.get("CV_WORKING_WIDTH", "640"))
MAX_FRAME_BYTES = 512 * 1024
MAX_CONTROL_CHARS = 4096
logger = logging.getLogger(__name__)

# Render sets RENDER_GIT_COMMIT to the deployed commit, so /health and error
# reports show whether a fix is live yet.
SERVER_VERSION = os.environ.get("RENDER_GIT_COMMIT", "")[:7] or "local"
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_OWN_CODE = tuple(os.path.join(_REPO_ROOT, d) + os.sep for d in ("backend", "physics_engine"))


class FrameDecodeError(ValueError):
    """The incoming image bytes could not be decoded."""


def describe_failure(exc: BaseException) -> dict:
    """What a crash was and where, for the client: the exception and the innermost
    line of our own code it went through (numpy, OpenCV and stdlib frames skipped)."""
    where = None
    for entry in reversed(traceback.extract_tb(exc.__traceback__)):
        path = os.path.abspath(entry.filename)
        if path.startswith(_OWN_CODE):
            where = f"{os.path.relpath(path, _REPO_ROOT).replace(os.sep, '/')}:{entry.lineno} in {entry.name}"
            break
    return {"kind": type(exc).__name__, "detail": str(exc)[:300], "where": where, "server": SERVER_VERSION}

# Takes a preprocessed frame and returns result fields ("objects", "calibration").
FrameAnalyzer = Callable[[PreprocessedFrame], dict]


def default_config() -> PipelineConfig:
    config = PipelineConfig(detector=os.environ.get("CV_DETECTOR", "motion"))
    if colors := os.environ.get("CV_COLORS"):
        config.colors = [c.strip() for c in colors.split(",") if c.strip()]
    return config


@dataclass
class IncomingFrame:
    data: bytes
    meta: dict
    received_at: float


app = FastAPI(title="HandsOn Physics CV engine")
app.state.pipeline_factory = lambda: TrackingPipeline(default_config())
app.state.active_sessions = set()


@dataclass
class DebugSnapshot:
    image: np.ndarray  # the decoded image the client sent
    result: dict
    trails: dict


# Latest frame + result per open connection, for the /debug view.
app.state.debug = {}
_connection_ids = itertools.count(1)


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "working_width": WORKING_WIDTH,
            "active_sessions": len(app.state.active_sessions), "commit": SERVER_VERSION}


@app.websocket("/ws/frames")
async def frames_ws(ws: WebSocket) -> None:
    await ws.accept()
    slot: LatestFrameSlot[IncomingFrame] = LatestFrameSlot()
    stats = {"processed": 0, "decode_errors": 0, "processing_errors": 0}
    pipeline = ws.app.state.pipeline_factory()
    session_id = str(uuid4())
    ws.app.state.active_sessions.add(session_id)
    physics = PhysicsSession()
    next_id = 0
    conn_id = next(_connection_ids)
    trails = TrailHistory()
    send_lock = asyncio.Lock()

    async def send(payload: dict) -> None:
        async with send_lock:
            await ws.send_json(payload)

    async def receive_loop() -> None:
        nonlocal next_id
        pending_meta: dict = {}
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    return
                if msg.get("text") is not None:
                    if len(msg["text"]) > MAX_CONTROL_CHARS:
                        pending_meta = {}
                        await send({"type": "error", "message": "control message too large"})
                        continue
                    try:
                        data = json.loads(msg["text"])
                        if not isinstance(data, dict):
                            raise ValueError("metadata must be a JSON object")
                    except ValueError as e:
                        pending_meta = {}
                        await send({"type": "error", "message": f"bad metadata: {e}"})
                        continue
                    if data.get("type") == "config":
                        await apply_config(data)
                    elif data.get("type") == "calibrate":
                        await apply_calibration(data)
                    else:
                        pending_meta = data
                elif msg.get("bytes") is not None:
                    if len(msg["bytes"]) > MAX_FRAME_BYTES:
                        rejected_id = pending_meta.get("frame_id")
                        pending_meta = {}
                        error = {"type": "error", "message": "frame exceeds 512 KiB"}
                        if rejected_id is not None:
                            error["frame_id"] = rejected_id
                        await send(error)
                        continue
                    frame_id = pending_meta.get("frame_id", next_id)
                    timestamp = pending_meta.get("timestamp")
                    if type(frame_id) is not int or frame_id < next_id:
                        pending_meta = {}
                        await send({"type": "error", "message": "frame_id must be an increasing nonnegative integer"})
                        continue
                    if timestamp is not None and (
                        isinstance(timestamp, bool)
                        or not isinstance(timestamp, (int, float))
                        or abs(timestamp) > 1e15
                        or not math.isfinite(timestamp)
                    ):
                        pending_meta = {}
                        await send({"type": "error", "message": "timestamp must be a finite number", "frame_id": frame_id})
                        continue
                    pending_meta["frame_id"] = frame_id
                    next_id = frame_id + 1
                    slot.put(IncomingFrame(msg["bytes"], pending_meta, time.time()))
                    pending_meta = {}
        finally:
            slot.close()

    # Serializes reconfiguration with frame processing, which runs in a worker thread.
    pipeline_lock = asyncio.Lock()

    async def apply_config(message: dict) -> None:
        try:
            async with pipeline_lock:
                await asyncio.to_thread(pipeline.apply_config, message)
        except (TypeError, ValueError, OSError, RuntimeError) as e:
            await send({"type": "error", "message": f"bad config: {e}"})

    async def apply_calibration(request: dict) -> None:
        try:
            async with pipeline_lock:
                status = pipeline.calibrate(request)
        except (TypeError, ValueError) as e:
            await send({"type": "error", "message": f"bad calibration: {e}"})
            return
        await send({"type": "calibration", "calibration": status})

    async def process_loop() -> None:
        while (frame := await slot.get()) is not None:
            t0 = time.perf_counter()
            try:
                async with pipeline_lock:
                    result, image = await asyncio.to_thread(_process_with_physics, frame, pipeline, physics)
            except FrameDecodeError as e:
                stats["decode_errors"] += 1
                await send({"type": "error", "message": str(e), "frame_id": frame.meta["frame_id"]})
                continue
            except Exception as exc:
                stats["processing_errors"] += 1
                logger.exception("Frame processing failed in session %s", session_id)
                failure = describe_failure(exc)
                summary = f"{failure['kind']}: {failure['detail']}" if failure["detail"] else failure["kind"]
                await send({"type": "error", "message": f"could not process frame: {summary}",
                            "frame_id": frame.meta["frame_id"], "error": failure})
                continue
            stats["processed"] += 1
            result["process_ms"] = round((time.perf_counter() - t0) * 1000, 2)
            result["latency_ms"] = round((time.time() - frame.received_at) * 1000, 2)
            result["stats"] = {"received": slot.received, "dropped": slot.dropped, **stats}
            ws.app.state.debug[conn_id] = DebugSnapshot(image, result, dict(trails.update(result["objects"])))
            await send(result)

    receiver = asyncio.create_task(receive_loop())
    processor = asyncio.create_task(process_loop())
    try:
        await asyncio.gather(receiver, processor)
    except (WebSocketDisconnect, RuntimeError):
        # Client went away mid-send; nothing left to deliver.
        pass
    finally:
        receiver.cancel()
        processor.cancel()
        pipeline.close()
        ws.app.state.debug.pop(conn_id, None)
        ws.app.state.active_sessions.discard(session_id)


def _process(frame: IncomingFrame, analyzer: FrameAnalyzer) -> tuple[dict, np.ndarray]:
    try:
        img = decode_jpeg(frame.data)
    except ValueError as exc:
        raise FrameDecodeError(str(exc)) from exc
    pf = preprocess_frame(
        img,
        frame_id=int(frame.meta["frame_id"]),
        timestamp=frame.meta.get("timestamp", frame.received_at),
        working_width=WORKING_WIDTH,
        meta=frame.meta,
    )
    return {
        "type": "frame",
        "frame_id": pf.frame_id,
        "timestamp": pf.timestamp,
        "size": list(pf.size),
        "source_size": list(pf.source_size),
        "scale": round(pf.scale, 5),
        **analyzer(pf),
    }, img


def _process_with_physics(
    frame: IncomingFrame, pipeline: TrackingPipeline, physics: PhysicsSession
) -> tuple[dict, np.ndarray]:
    result, image = _process(frame, pipeline)
    session_settings = pipeline.session
    if session_settings.get("mode") is not None:
        result = physics.process_frame(result, session_settings)
    return result, image


DEBUG_PAGE = """<!doctype html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>HandsOn Physics Debug</title>
<style>
:root {
  --bg: #07111f;
  --panel: rgba(12, 22, 35, 0.9);
  --panel-alt: rgba(17, 31, 49, 0.9);
  --border: rgba(148, 163, 184, 0.18);
  --text: #e5eefb;
  --muted: #9bb0ca;
  --accent: #7dd3fc;
  --accent-strong: #38bdf8;
  --glow: rgba(56, 189, 248, 0.25);
}
* { box-sizing: border-box; }
html, body {
  margin: 0;
  min-height: 100%;
  background:
    radial-gradient(circle at top, rgba(56, 189, 248, 0.18), transparent 36%),
    linear-gradient(135deg, #040b14, var(--bg) 42%, #0b1526);
  color: var(--text);
  font-family: Inter, "Segoe UI", sans-serif;
}
body {
  display: grid;
  place-items: center;
  padding: 32px 20px 48px;
}
.app-shell {
  width: min(1200px, 100%);
  padding: 24px;
  border: 1px solid var(--border);
  border-radius: 24px;
  background: rgba(5, 12, 20, 0.75);
  backdrop-filter: blur(16px);
  box-shadow: 0 30px 70px rgba(2, 6, 23, 0.55), inset 0 1px 0 rgba(255,255,255,0.04);
}
.topbar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 16px;
  margin-bottom: 20px;
  flex-wrap: wrap;
}
.brand {
  display: flex;
  align-items: center;
  gap: 14px;
}
.brand-mark {
  width: 42px;
  height: 42px;
  border-radius: 14px;
  background: linear-gradient(135deg, var(--accent), var(--accent-strong));
  box-shadow: 0 0 30px var(--glow);
  display: grid;
  place-items: center;
  font-weight: 800;
  color: #07111f;
}
.brand h1 {
  margin: 0;
  font-size: clamp(1.5rem, 2vw, 2.2rem);
  letter-spacing: -0.04em;
}
.status {
  display: inline-flex;
  align-items: center;
  gap: 10px;
  padding: 8px 12px;
  border: 1px solid rgba(125, 211, 252, 0.35);
  border-radius: 999px;
  background: rgba(14, 116, 144, 0.18);
  color: #cfeffc;
  font-size: 0.82rem;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}
.dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  background: #34d399;
  box-shadow: 0 0 16px rgba(52, 211, 153, 0.8);
  animation: pulse 2s infinite ease-in-out;
}
@keyframes pulse {
  0%, 100% { transform: scale(0.9); opacity: 1; }
  50% { transform: scale(1.2); opacity: 0.75; }
}
.live-panel {
  display: grid;
  grid-template-columns: minmax(0, 1.8fr) minmax(220px, 0.7fr);
  gap: 22px;
  align-items: stretch;
}
.frame-card, .meta-card {
  background: linear-gradient(180deg, var(--panel), var(--panel-alt));
  border: 1px solid var(--border);
  border-radius: 20px;
  overflow: hidden;
}
.frame-card {
  padding: 18px;
}
.stage {
  position: relative;
  border-radius: 16px;
  overflow: hidden;
  border: 1px solid rgba(125, 211, 252, 0.2);
  background:
    linear-gradient(135deg, rgba(15, 23, 42, 0.9), rgba(15, 23, 42, 0.6)),
    repeating-linear-gradient(
      90deg,
      rgba(125,211,252,0.05),
      rgba(125,211,252,0.05) 2px,
      transparent 2px,
      transparent 18px
    );
  min-height: 420px;
  display: grid;
  place-items: center;
}
.stage img {
  display: block;
  width: 100%;
  height: auto;
  max-height: 72vh;
  object-fit: contain;
  background: rgba(15, 23, 42, 0.55);
}
.caption {
  margin-top: 15px;
  color: var(--muted);
  font-size: 0.96rem;
  line-height: 1.5;
}
.meta-card {
  padding: 18px 18px 12px;
}
.meta-card h2 {
  margin: 0 0 14px;
  font-size: 1.02rem;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  color: var(--muted);
}
.info-list {
  display: grid;
  gap: 12px;
}
.info-item {
  padding: 12px 12px 10px;
  border-radius: 12px;
  border: 1px solid rgba(148,163,184,0.14);
  background: rgba(15, 23, 42, 0.36);
}
.info-label {
  display: block;
  font-size: 0.74rem;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--muted);
  margin-bottom: 6px;
}
.info-value {
  font-weight: 700;
  color: var(--text);
  font-size: 1.05rem;
}
@media (max-width: 820px) {
  .live-panel { grid-template-columns: 1fr; }
  .app-shell { padding: 18px; }
  .stage { min-height: 260px; }
}
</style>
</head>
<body>
  <main class="app-shell">
    <header class="topbar">
      <div class="brand">
        <div class="brand-mark">H</div>
        <h1>HandsOn Physics</h1>
      </div>
      <div class="status"><span class="dot"></span><span id="status-text">Live feed</span></div>
    </header>

    <section class="live-panel">
      <div class="frame-card">
        <div class="stage">
          <img src="/debug/stream" alt="Annotated stream of the latest connection">
        </div>
        <div class="caption">
          Annotated stream of the latest connection. Boxes, IDs, and trails are rendered from the same JSON the app receives.
        </div>
      </div>

      <aside class="meta-card">
        <h2>Session</h2>
        <div class="info-list">
          <div class="info-item">
            <span class="info-label">Source</span>
            <span class="info-value">Latest connected device</span>
          </div>
          <div class="info-item">
            <span class="info-label">Mode</span>
            <span class="info-value">Vision overlay</span>
          </div>
          <div class="info-item">
            <span class="info-label">Refresh</span>
            <span class="info-value">MJPEG stream</span>
          </div>
        </div>
      </aside>
    </section>
  </main>

  <script>
    const statusText = document.getElementById('status-text');
    async function syncStatus() {
      try {
        const response = await fetch('/health');
        const data = await response.json();
        statusText.textContent = data && data.status === 'ok' ? 'Live feed' : 'Checking…';
      } catch (error) {
        statusText.textContent = 'Waiting';
      }
    }
    syncStatus();
    setInterval(syncStatus, 5000);
  </script>
</body>
</html>"""


@app.get("/debug", response_class=HTMLResponse)
def debug_page() -> str:
    return DEBUG_PAGE


@app.get("/debug/stream")
async def debug_stream(fps: float = 15.0) -> StreamingResponse:
    """MJPEG stream of the newest connection's frames with the overlay drawn on."""

    async def frames():
        last = None
        while True:
            snaps = app.state.debug
            snap = snaps[max(snaps)] if snaps else None
            if snap is not None and snap is not last:
                last = snap
                annotated = await asyncio.to_thread(draw_overlay, snap.image, snap.result, snap.trails)
                ok, jpg = cv2.imencode(".jpg", annotated, [cv2.IMWRITE_JPEG_QUALITY, 80])
                if ok:
                    yield b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + jpg.tobytes() + b"\r\n"
            await asyncio.sleep(1 / fps)

    return StreamingResponse(frames(), media_type="multipart/x-mixed-replace; boundary=frame")
