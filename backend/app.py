"""FastAPI backend: receives camera frames from the mobile app over a WebSocket.

Protocol on ws://<host>:8000/ws/frames
  client -> server
    text   (optional) JSON metadata for the next image, e.g.
           {"frame_id": 12, "timestamp": 1728575000.123, "anchor": {...}}
    binary JPEG (or PNG) bytes of one downsampled camera frame
    text   (any time) tracking settings, applied from the next frame:
           {"type": "config", "mode": "color", "colors": ["red", "blue"], ...}
           answered with {"type": "config", "config": {...}}
    text   (any time) plane calibration for metric coordinates:
           {"type": "calibrate", "method": "aruco", "width_m": 0.6, "height_m": 0.4}
           {"type": "calibrate", "method": "manual", "image_points": [[x, y] x4],
            "width_m": 0.6, "height_m": 0.4}
           answered with {"type": "calibration", "calibration": {...}}
  server -> client
    text   JSON result for each frame that was processed:
           {"type": "frame", "frame_id", "timestamp", "size": [w, h],
            "source_size": [w, h], "scale", "latency_ms", "process_ms",
            "stats": {"received", "processed", "dropped", "decode_errors"},
            "objects": [{"id", "label", "source", "score", "centroid", "bbox",
                         "centroid_norm", "bbox_norm", "area", "hits",
                         "world", "world_width"}],
            "calibration": {"method", "status", "world_to_image", ...}}
           or {"type": "error", "message": ...} for a bad message.

Frames that arrive while the engine is busy are dropped in favour of the newest
one, so the client never builds up lag. Dropped frames are never decoded.

Debug view: open http://<host>:8000/debug in a browser to watch the annotated stream
(boxes, IDs, trails, calibrated plane) of the most recent phone connection.

Run with:  uvicorn app:app --host 0.0.0.0 --port 8000
"""

from __future__ import annotations

import asyncio
import itertools
import json
import os
import time
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

WORKING_WIDTH = int(os.environ.get("CV_WORKING_WIDTH", "640"))

# Takes a preprocessed frame and returns result fields ("objects", "calibration").
FrameAnalyzer = Callable[[PreprocessedFrame], dict]


def default_config() -> PipelineConfig:
    config = PipelineConfig(mode=os.environ.get("CV_MODE", "color"))
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
    return {"status": "ok", "working_width": WORKING_WIDTH}


@app.websocket("/ws/frames")
async def frames_ws(ws: WebSocket) -> None:
    await ws.accept()
    slot: LatestFrameSlot[IncomingFrame] = LatestFrameSlot()
    stats = {"processed": 0, "decode_errors": 0}
    pipeline = ws.app.state.pipeline_factory()
    next_id = 0
    conn_id = next(_connection_ids)
    trails = TrailHistory()

    async def receive_loop() -> None:
        nonlocal next_id
        pending_meta: dict = {}
        try:
            while True:
                msg = await ws.receive()
                if msg["type"] == "websocket.disconnect":
                    return
                if msg.get("text") is not None:
                    try:
                        data = json.loads(msg["text"])
                        if not isinstance(data, dict):
                            raise ValueError("metadata must be a JSON object")
                    except ValueError as e:
                        pending_meta = {}
                        await ws.send_json({"type": "error", "message": f"bad metadata: {e}"})
                        continue
                    if data.get("type") == "config":
                        await apply_config({k: v for k, v in data.items() if k != "type"})
                    elif data.get("type") == "calibrate":
                        await apply_calibration(data)
                    else:
                        pending_meta = data
                elif msg.get("bytes") is not None:
                    if "frame_id" not in pending_meta:
                        pending_meta["frame_id"] = next_id
                    next_id = int(pending_meta["frame_id"]) + 1
                    slot.put(IncomingFrame(msg["bytes"], pending_meta, time.time()))
                    pending_meta = {}
        finally:
            slot.close()

    # Serializes reconfiguration with frame processing, which runs in a worker thread.
    pipeline_lock = asyncio.Lock()

    async def apply_config(changes: dict) -> None:
        try:
            async with pipeline_lock:
                new = pipeline.config.updated(changes)
                await asyncio.to_thread(pipeline.configure, new)
        except (TypeError, ValueError, OSError, RuntimeError) as e:
            await ws.send_json({"type": "error", "message": f"bad config: {e}"})
            return
        await ws.send_json({"type": "config", "config": pipeline.config.__dict__})

    async def apply_calibration(request: dict) -> None:
        try:
            async with pipeline_lock:
                status = pipeline.calibrate(request)
        except (TypeError, ValueError) as e:
            await ws.send_json({"type": "error", "message": f"bad calibration: {e}"})
            return
        await ws.send_json({"type": "calibration", "calibration": status})

    async def process_loop() -> None:
        while (frame := await slot.get()) is not None:
            t0 = time.perf_counter()
            try:
                async with pipeline_lock:
                    result, image = await asyncio.to_thread(_process, frame, pipeline)
            except ValueError as e:
                stats["decode_errors"] += 1
                await ws.send_json({"type": "error", "message": str(e), "frame_id": frame.meta["frame_id"]})
                continue
            stats["processed"] += 1
            result["process_ms"] = round((time.perf_counter() - t0) * 1000, 2)
            result["latency_ms"] = round((time.time() - frame.received_at) * 1000, 2)
            result["stats"] = {"received": slot.received, "dropped": slot.dropped, **stats}
            ws.app.state.debug[conn_id] = DebugSnapshot(image, result, dict(trails.update(result["objects"])))
            await ws.send_json(result)

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


def _process(frame: IncomingFrame, analyzer: FrameAnalyzer) -> tuple[dict, np.ndarray]:
    img = decode_jpeg(frame.data)
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


DEBUG_PAGE = """<!doctype html><html><head><meta name="viewport" content="width=device-width">
<title>CV engine debug</title><style>body{margin:0;background:#111;color:#ccc;font:14px sans-serif}
img{display:block;max-width:100%;margin:auto}p{text-align:center}</style></head><body>
<img src="/debug/stream" alt="waiting for frames"><p>Annotated stream of the latest connection.
Boxes, IDs and trails come from the same JSON the app receives.</p></body></html>"""


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
