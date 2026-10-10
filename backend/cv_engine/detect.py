"""Object detection on preprocessed frames.

Two detectors share one output type:
  * ColorDetector  - HSV thresholding + contours. Fast (~1 ms) and very reliable for
                     brightly colored lab objects: balls, cart markers, pendulum bobs.
  * MediaPipeDetector - EfficientDet-Lite0 via MediaPipe Tasks, for everyday objects
                     that have no distinctive color (e.g. "sports ball", "bottle").

All coordinates are in working-frame pixels (see PreprocessedFrame).
"""

from __future__ import annotations

import logging
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np

from cv_engine.preprocess import PreprocessedFrame

log = logging.getLogger(__name__)


@dataclass
class Detection:
    label: str
    centroid: tuple[float, float]  # (x, y)
    bbox: tuple[int, int, int, int]  # (x, y, w, h)
    area: float  # pixel area of the mask/contour (bbox area for MediaPipe)
    score: float  # 0-1 confidence
    source: str  # "color" or "mediapipe"


# OpenCV HSV ranges: H 0-179, S 0-255, V 0-255. Red wraps around 0, so it has two ranges.
COLOR_RANGES: dict[str, list[tuple[tuple[int, int, int], tuple[int, int, int]]]] = {
    "red": [((0, 120, 70), (8, 255, 255)), ((170, 120, 70), (179, 255, 255))],
    "orange": [((9, 120, 90), (20, 255, 255))],
    "yellow": [((21, 100, 100), (34, 255, 255))],
    "green": [((35, 80, 50), (85, 255, 255))],
    "blue": [((95, 120, 50), (130, 255, 255))],
    "purple": [((131, 80, 50), (160, 255, 255))],
}

DEFAULT_COLORS = ("red", "green", "blue", "yellow")


class ColorDetector:
    def __init__(
        self,
        colors: tuple[str, ...] | list[str] = DEFAULT_COLORS,
        min_area: float = 80.0,
        max_per_color: int = 3,
        custom_ranges: dict | None = None,
    ) -> None:
        self.ranges = {**COLOR_RANGES, **(custom_ranges or {})}
        unknown = [c for c in colors if c not in self.ranges]
        if unknown:
            raise ValueError(f"unknown colors {unknown}; known: {sorted(self.ranges)}")
        self.colors = list(colors)
        self.min_area = min_area
        self.max_per_color = max_per_color
        self._kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))

    def mask(self, hsv: np.ndarray, color: str) -> np.ndarray:
        mask = np.zeros(hsv.shape[:2], np.uint8)
        for lo, hi in self.ranges[color]:
            mask |= cv2.inRange(hsv, np.array(lo, np.uint8), np.array(hi, np.uint8))
        # Open removes speckle noise, close fills small holes from glare.
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, self._kernel)
        return cv2.morphologyEx(mask, cv2.MORPH_CLOSE, self._kernel)

    def detect(self, frame: PreprocessedFrame) -> list[Detection]:
        out: list[Detection] = []
        for color in self.colors:
            contours, _ = cv2.findContours(self.mask(frame.hsv, color), cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
            found = []
            for c in contours:
                area = cv2.contourArea(c)
                if area < self.min_area:
                    continue
                m = cv2.moments(c)
                if m["m00"] == 0:
                    continue
                cx, cy = m["m10"] / m["m00"], m["m01"] / m["m00"]
                x, y, w, h = cv2.boundingRect(c)
                # Solidity (area / convex hull area) rewards compact blobs over ragged noise.
                hull_area = cv2.contourArea(cv2.convexHull(c)) or area
                found.append(Detection(color, (cx, cy), (x, y, w, h), area, min(1.0, area / hull_area), "color"))
            found.sort(key=lambda d: d.area, reverse=True)
            out.extend(found[: self.max_per_color])
        return out


MODEL_URL = "https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/int8/1/efficientdet_lite0.tflite"
DEFAULT_MODEL_PATH = Path(__file__).resolve().parent.parent / "models" / "efficientdet_lite0.tflite"


def ensure_model(path: Path = DEFAULT_MODEL_PATH, url: str = MODEL_URL) -> Path:
    """Download the MediaPipe detector model on first use."""
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        log.info("downloading %s -> %s", url, path)
        tmp = path.with_suffix(".part")
        urllib.request.urlretrieve(url, tmp)
        tmp.rename(path)
    return path


class MediaPipeDetector:
    """General object detector (COCO classes) using MediaPipe Tasks."""

    def __init__(
        self,
        model_path: Path | str | None = None,
        score_threshold: float = 0.35,
        max_results: int = 5,
        allow_labels: list[str] | None = None,
    ) -> None:
        from mediapipe.tasks.python import BaseOptions, vision

        path = Path(model_path) if model_path else ensure_model()
        options = vision.ObjectDetectorOptions(
            base_options=BaseOptions(model_asset_path=str(path)),
            running_mode=vision.RunningMode.IMAGE,
            score_threshold=score_threshold,
            max_results=max_results,
            category_allowlist=allow_labels,
        )
        self._detector = vision.ObjectDetector.create_from_options(options)

    def detect(self, frame: PreprocessedFrame) -> list[Detection]:
        import mediapipe as mp

        rgb = cv2.cvtColor(frame.bgr, cv2.COLOR_BGR2RGB)
        result = self._detector.detect(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb))
        out = []
        for d in result.detections:
            b = d.bounding_box
            cat = d.categories[0]
            x, y, w, h = b.origin_x, b.origin_y, b.width, b.height
            out.append(
                Detection(cat.category_name or "object", (x + w / 2, y + h / 2), (x, y, w, h), float(w * h), cat.score, "mediapipe")
            )
        return out

    def close(self) -> None:
        self._detector.close()
