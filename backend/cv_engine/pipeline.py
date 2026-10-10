"""Per-connection tracking pipeline: detectors + tracker + spatial mapping -> JSON.

Each WebSocket connection gets its own TrackingPipeline so tracker state (IDs,
history) and calibration never leak between phones.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field

import numpy as np

from cv_engine.detect import DEFAULT_COLORS, ColorDetector, Detection, MediaPipeDetector
from cv_engine.preprocess import PreprocessedFrame
from cv_engine.spatial import SpatialMapper
from cv_engine.tracker import CentroidTracker, Track

log = logging.getLogger(__name__)

MODES = ("color", "mediapipe", "both")


@dataclass
class PipelineConfig:
    mode: str = "color"  # which detectors to run: color, mediapipe or both
    colors: list[str] = field(default_factory=lambda: list(DEFAULT_COLORS))
    min_area: float = 80.0
    mediapipe_labels: list[str] | None = None  # e.g. ["sports ball"]; None = all COCO classes
    mediapipe_score: float = 0.35
    max_distance: float = 80.0
    max_missed: int = 10
    min_hits: int = 2

    def updated(self, changes: dict) -> PipelineConfig:
        unknown = set(changes) - set(self.__dataclass_fields__)
        if unknown:
            raise ValueError(f"unknown config keys {sorted(unknown)}")
        merged = PipelineConfig(**{**self.__dict__, **changes})
        if merged.mode not in MODES:
            raise ValueError(f"mode must be one of {MODES}")
        return merged


class TrackingPipeline:
    def __init__(self, config: PipelineConfig | None = None) -> None:
        self._mediapipe: MediaPipeDetector | None = None
        self.spatial = SpatialMapper()
        self.configure(config or PipelineConfig())

    def configure(self, config: PipelineConfig) -> None:
        """Apply new settings. Builds everything first, so a failure keeps the old setup."""
        old = getattr(self, "config", None)
        color = ColorDetector(config.colors, min_area=config.min_area)
        mp_settings_changed = old is None or (old.mediapipe_labels, old.mediapipe_score) != (
            config.mediapipe_labels,
            config.mediapipe_score,
        )
        mediapipe = self._mediapipe
        if config.mode != "color" and (mediapipe is None or mp_settings_changed):
            mediapipe = MediaPipeDetector(score_threshold=config.mediapipe_score, allow_labels=config.mediapipe_labels)
        elif config.mode == "color":
            mediapipe = None
        if self._mediapipe is not None and self._mediapipe is not mediapipe:
            self._mediapipe.close()

        self.config = config
        self.color = color
        self._mediapipe = mediapipe
        self.tracker = CentroidTracker(config.max_distance, config.max_missed, config.min_hits)

    def detect(self, frame: PreprocessedFrame) -> list[Detection]:
        dets: list[Detection] = []
        if self.config.mode in ("color", "both"):
            dets += self.color.detect(frame)
        if self.config.mode in ("mediapipe", "both") and self._mediapipe:
            dets += self._mediapipe.detect(frame)
        return dets

    def __call__(self, frame: PreprocessedFrame) -> dict:
        """Process one frame; returns the "objects" and "calibration" parts of the result."""
        self.spatial.update(frame)
        tracks = self.tracker.update(self.detect(frame))
        return {
            "objects": [track_to_json(t, frame, self.spatial) for t in tracks],
            "calibration": self.spatial.status(),
        }

    def calibrate(self, request: dict) -> dict:
        return self.spatial.calibrate(request)

    def close(self) -> None:
        if self._mediapipe:
            self._mediapipe.close()
            self._mediapipe = None


def track_to_json(t: Track, frame: PreprocessedFrame, spatial: SpatialMapper | None = None) -> dict:
    """Report positions in the client's own pixel space, normalized 0-1 coords and,
    when the plane is calibrated, meters on that plane ("world")."""
    s = frame.scale
    w, h = frame.size
    x, y, bw, bh = t.bbox
    cx, cy = t.centroid
    world = world_width = None
    if spatial is not None and spatial.mapping is not None:
        world = spatial.to_world((cx / s, cy / s), (cx / w, cy / h))
        # Object width on the plane, from the left and right edges at centroid height.
        left = spatial.to_world((x / s, cy / s), (x / w, cy / h))
        right = spatial.to_world(((x + bw) / s, cy / s), ((x + bw) / w, cy / h))
        world_width = round(float(np.hypot(right[0] - left[0], right[1] - left[1])), 4)
    return {
        "id": t.id,
        "label": t.label,
        "source": t.source,
        "score": round(t.score, 3),
        "centroid": [round(cx / s, 2), round(cy / s, 2)],
        "bbox": [round(x / s, 1), round(y / s, 1), round(bw / s, 1), round(bh / s, 1)],
        "centroid_norm": [round(cx / w, 5), round(cy / h, 5)],
        "bbox_norm": [round(x / w, 5), round(y / h, 5), round(bw / w, 5), round(bh / h, 5)],
        "area": round(t.area / (s * s), 1),
        "hits": t.hits,
        "world": world,
        "world_width": world_width,
    }
