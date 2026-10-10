"""FastAPI WebSocket endpoint and per-connection session management."""

import asyncio
import json
import logging
import time
from typing import Callable, Optional
from uuid import uuid4

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from .pipeline import PhysicsEngine, Pipeline, Tracker, UnconfiguredPhysics, UnconfiguredTracker
from .protocol import (
    MAX_CONTROL_CHARS,
    ClientConfig,
    FramePacket,
    PROTOCOL_VERSION,
    decode_frame,
)


logger = logging.getLogger(__name__)
TrackerFactory = Callable[[], Tracker]
PhysicsFactory = Callable[[], PhysicsEngine]


class Session:
    def __init__(self, websocket: WebSocket, pipeline: Pipeline):
        self.id = str(uuid4())
        self.websocket = websocket
        self.pipeline = pipeline
        self.config = ClientConfig()
        self.pending: asyncio.Queue[FramePacket] = asyncio.Queue(maxsize=1)
        self.send_lock = asyncio.Lock()
        self.last_frame_id = -1
        self.last_capture_timestamp_ms = -1
        self.dropped_frames = 0

    async def send(self, payload: dict) -> None:
        async with self.send_lock:
            await self.websocket.send_json(payload)

    async def error(self, code: str, detail: str) -> None:
        await self.send({"type": "error", "version": PROTOCOL_VERSION, "code": code, "detail": detail})

    def enqueue(self, frame: FramePacket) -> None:
        if self.pending.full():
            self.pending.get_nowait()
            self.pending.task_done()
            self.dropped_frames += 1
        self.pending.put_nowait(frame)

    async def process_frames(self) -> None:
        while True:
            frame = await self.pending.get()
            try:
                result = await asyncio.to_thread(
                    self.pipeline.process, frame, self.dropped_frames
                )
                await self.send(result.model_dump())
            except Exception:
                logger.exception("Frame processing failed for session %s", self.id)
                await self.error("processing_failed", "Could not process frame %d" % frame.frame_id)
            finally:
                self.pending.task_done()


def create_app(
    tracker_factory: Optional[TrackerFactory] = None,
    physics_factory: Optional[PhysicsFactory] = None,
) -> FastAPI:
    app = FastAPI(title="HandsOn Physics Backend", version="0.1.0")
    app.state.sessions = set()
    make_tracker = tracker_factory or UnconfiguredTracker
    make_physics = physics_factory or UnconfiguredPhysics

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok", "active_sessions": len(app.state.sessions)}

    @app.websocket("/ws")
    async def stream(websocket: WebSocket) -> None:
        await websocket.accept()
        try:
            pipeline = Pipeline(make_tracker(), make_physics(), tracker_factory is not None)
        except Exception:
            logger.exception("Could not initialize session pipeline")
            await websocket.close(code=1011, reason="Pipeline initialization failed")
            return
        session = Session(websocket, pipeline)
        app.state.sessions.add(session.id)
        worker = asyncio.create_task(session.process_frames())
        try:
            await session.send(
                {
                    "type": "hello",
                    "version": PROTOCOL_VERSION,
                    "session_id": session.id,
                    "frame_format": "uint32_be_frame_id + uint64_be_unix_ms + jpeg",
                    "config": session.config.model_dump(),
                }
            )
            while True:
                message = await websocket.receive()
                if message["type"] == "websocket.disconnect":
                    break
                if message.get("text") is not None:
                    raw = message["text"]
                    if len(raw) > MAX_CONTROL_CHARS:
                        await session.error("control_too_large", "Control message exceeds 4096 characters")
                        continue
                    try:
                        data = json.loads(raw)
                        if not isinstance(data, dict) or data.get("type") != "config":
                            await session.error("unknown_message", "Expected a config object")
                            continue
                        session.config = ClientConfig.model_validate(data)
                    except ValueError as exc:
                        await session.error("invalid_config", str(exc))
                        continue
                    await session.send({"type": "config_ack", "version": PROTOCOL_VERSION, "config": session.config.model_dump()})
                elif message.get("bytes") is not None:
                    try:
                        frame = decode_frame(
                            message["bytes"], session.config.model_copy(deep=True), int(time.time() * 1000)
                        )
                    except ValueError as exc:
                        await session.error(str(exc), "Invalid frame packet")
                        continue
                    if frame.frame_id <= session.last_frame_id:
                        await session.error("out_of_order_frame", "frame_id must increase within a session")
                        continue
                    if frame.capture_timestamp_ms <= session.last_capture_timestamp_ms:
                        await session.error("non_monotonic_timestamp", "Capture timestamps must increase within a session")
                        continue
                    session.last_frame_id = frame.frame_id
                    session.last_capture_timestamp_ms = frame.capture_timestamp_ms
                    session.enqueue(frame)
        except WebSocketDisconnect:
            pass
        finally:
            worker.cancel()
            try:
                await worker
            except asyncio.CancelledError:
                pass
            app.state.sessions.discard(session.id)

    return app


app = create_app()
