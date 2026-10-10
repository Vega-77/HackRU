"""Tap initialized grayscale tracker for objects outside detector categories."""

from __future__ import annotations

import cv2
import numpy as np

from cv_engine.detect import Detection
from cv_engine.preprocess import PreprocessedFrame


class ManualTracker:
    """Match a selected grayscale image patch near its previous location.

    A drag box gives the best fit. A tap uses a small square around the tap. The
    patch is held through brief loss and never updated from a weak match.
    """

    def __init__(self, search_radius: int = 70, min_score: float = 0.68) -> None:
        self.search_radius = search_radius
        self.min_score = min_score
        self.template: np.ndarray | None = None
        self.bbox: tuple[int, int, int, int] | None = None

    def reset(self) -> None:
        self.template = None
        self.bbox = None

    def select(self, frame: PreprocessedFrame, point: tuple[float, float], box: dict | None = None) -> Detection | None:
        width, height = frame.size
        if box is None:
            side = min(48, width, height)
            x = round(point[0] - side / 2)
            y = round(point[1] - side / 2)
            w = h = side
        else:
            x, y, w, h = (round(box[k] * frame.scale) for k in ("x", "y", "w", "h"))
        x, y = max(0, x), max(0, y)
        w, h = min(w, width - x), min(h, height - y)
        if w < 8 or h < 8 or not (x <= point[0] <= x + w and y <= point[1] <= y + h):
            self.reset()
            return None
        patch = frame.gray[y:y + h, x:x + w]
        if float(patch.std()) < 3:
            self.reset()
            return None
        self.template = patch.copy()
        self.bbox = (x, y, w, h)
        return self._detection(self.bbox, 1.0)

    def detect(self, frame: PreprocessedFrame) -> Detection | None:
        if self.template is None or self.bbox is None:
            return None
        x, y, w, h = self.bbox
        radius = self.search_radius
        left, top = max(0, x - radius), max(0, y - radius)
        right = min(frame.size[0], x + w + radius)
        bottom = min(frame.size[1], y + h + radius)
        search = frame.gray[top:bottom, left:right]
        best = None
        for scale in (0.85, 1.0, 1.15):
            tw, th = max(8, round(w * scale)), max(8, round(h * scale))
            if search.shape[0] < th or search.shape[1] < tw:
                continue
            template = self.template if self.template.shape[::-1] == (tw, th) else cv2.resize(self.template, (tw, th))
            scores = cv2.matchTemplate(search, template, cv2.TM_SQDIFF_NORMED)
            _, _, location, _ = cv2.minMaxLoc(scores)
            matched = search[location[1]:location[1] + th, location[0]:location[0] + tw]
            rms = float(np.sqrt(np.mean((matched.astype(np.float32) - template.astype(np.float32)) ** 2)))
            confidence = max(0.0, 1.0 - rms / (2 * max(float(template.std()), 5.0)))
            if best is None or confidence > best[0]:
                best = (confidence, left + location[0], top + location[1], tw, th)
        if best is None:
            return None
        confidence, bx, by, bw, bh = best
        if confidence < self.min_score:
            return None
        self.bbox = (bx, by, bw, bh)
        if confidence > 0.85:
            self.template = frame.gray[by:by + bh, bx:bx + bw].copy()
        return self._detection(self.bbox, confidence)

    @staticmethod
    def _detection(box: tuple[int, int, int, int], score: float) -> Detection:
        x, y, w, h = box
        return Detection("selected", (x + w / 2, y + h / 2), box, float(w * h), score, "manual")
