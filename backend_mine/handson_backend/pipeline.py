"""Small interfaces for Dev 2 tracking and Dev 3 physics implementations."""

from dataclasses import dataclass
from typing import Optional, Protocol

from .protocol import ClientConfig, FramePacket, FrameResult, Measurement, Vec2


@dataclass(frozen=True)
class TrackedObject:
    x_px: float
    y_px: float
    confidence: float


@dataclass(frozen=True)
class Kinematics:
    position_m: Optional[Vec2] = None
    velocity_m_s: Optional[Vec2] = None
    acceleration_m_s2: Optional[Vec2] = None


class Tracker(Protocol):
    def track(self, jpeg: bytes, config: ClientConfig) -> Optional[TrackedObject]:
        """Return a centroid in the transmitted image's pixel coordinates."""


class PhysicsEngine(Protocol):
    def update(
        self, capture_timestamp_ms: int, tracked: TrackedObject, config: ClientConfig
    ) -> Kinematics:
        """Update session state using the original camera capture timestamp."""


class UnconfiguredTracker:
    """Explicit placeholder until Dev 2's tracker is connected."""

    def track(self, jpeg: bytes, config: ClientConfig) -> Optional[TrackedObject]:
        return None


class UnconfiguredPhysics:
    """Explicit placeholder until Dev 3's physics engine is connected."""

    def update(
        self, capture_timestamp_ms: int, tracked: TrackedObject, config: ClientConfig
    ) -> Kinematics:
        return Kinematics()


class Pipeline:
    def __init__(self, tracker: Tracker, physics: PhysicsEngine, tracker_ready: bool):
        self.tracker = tracker
        self.physics = physics
        self.tracker_ready = tracker_ready

    def process(self, frame: FramePacket, dropped_frames: int) -> FrameResult:
        from time import perf_counter

        start = perf_counter()
        tracked = self.tracker.track(frame.jpeg, frame.config)
        measurement = None
        if tracked is not None:
            if not 0 <= tracked.confidence <= 1:
                raise ValueError("tracker confidence must be between 0 and 1")
            motion = self.physics.update(
                frame.capture_timestamp_ms, tracked, frame.config
            )
            measurement = Measurement(
                x_px=tracked.x_px,
                y_px=tracked.y_px,
                confidence=tracked.confidence,
                position_m=motion.position_m,
                velocity_m_s=motion.velocity_m_s,
                acceleration_m_s2=motion.acceleration_m_s2,
            )
        return FrameResult(
            frame_id=frame.frame_id,
            capture_timestamp_ms=frame.capture_timestamp_ms,
            server_received_timestamp_ms=frame.server_received_timestamp_ms,
            processing_ms=round((perf_counter() - start) * 1000, 3),
            dropped_frames=dropped_frames,
            status=(
                "tracked"
                if tracked is not None
                else "tracking_lost" if self.tracker_ready else "tracking_unavailable"
            ),
            measurement=measurement,
        )
