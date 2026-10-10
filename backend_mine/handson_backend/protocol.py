"""Version 1 WebSocket message and frame definitions."""

import struct
from dataclasses import dataclass
from typing import Literal, Optional

from pydantic import BaseModel, ConfigDict, Field


PROTOCOL_VERSION = 1
FRAME_HEADER = struct.Struct(">IQ")  # uint32 frame ID, uint64 capture time in Unix ms
MAX_FRAME_BYTES = 512 * 1024
MAX_CONTROL_CHARS = 4096


class ClientConfig(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    type: Literal["config"] = "config"
    version: Literal[1] = PROTOCOL_VERSION
    mode: Literal["free_fall", "ramp"] = "free_fall"
    mass_kg: float = Field(default=0.1, gt=0, le=1000)
    meters_per_pixel: Optional[float] = Field(default=None, gt=0)
    rotation_degrees: Literal[0, 90, 180, 270] = 0


class Vec2(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)

    x: float
    y: float


class Measurement(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)

    x_px: float
    y_px: float
    confidence: float = Field(ge=0, le=1)
    position_m: Optional[Vec2] = None
    velocity_m_s: Optional[Vec2] = None
    acceleration_m_s2: Optional[Vec2] = None


class FrameResult(BaseModel):
    type: Literal["result"] = "result"
    version: Literal[1] = PROTOCOL_VERSION
    frame_id: int
    capture_timestamp_ms: int
    server_received_timestamp_ms: int
    processing_ms: float
    dropped_frames: int
    status: Literal["tracked", "tracking_lost", "tracking_unavailable"]
    measurement: Optional[Measurement] = None


@dataclass(frozen=True)
class FramePacket:
    frame_id: int
    capture_timestamp_ms: int
    jpeg: bytes
    server_received_timestamp_ms: int
    config: ClientConfig


def decode_frame(data: bytes, config: ClientConfig, received_ms: int) -> FramePacket:
    if len(data) > MAX_FRAME_BYTES:
        raise ValueError("frame_too_large")
    if len(data) < FRAME_HEADER.size + 4:
        raise ValueError("frame_too_short")
    frame_id, capture_timestamp_ms = FRAME_HEADER.unpack_from(data)
    jpeg = data[FRAME_HEADER.size :]
    if not jpeg.startswith(b"\xff\xd8") or not jpeg.endswith(b"\xff\xd9"):
        raise ValueError("invalid_jpeg")
    return FramePacket(frame_id, capture_timestamp_ms, jpeg, received_ms, config)
