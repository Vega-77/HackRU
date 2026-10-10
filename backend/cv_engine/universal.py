"""Appearance matching for an explicitly selected object."""

from __future__ import annotations

import cv2
import numpy as np

from cv_engine.detect import Detection
from cv_engine.preprocess import PreprocessedFrame


class ManualTracker:
    """Keep the selected appearance as an identity reference during recovery."""

    def __init__(self, search_radius: int = 70, min_score: float = 0.68) -> None:
        self.search_radius = search_radius
        self.min_score = min_score
        self.reset()

    def reset(self) -> None:
        self.template: np.ndarray | None = None
        self.original: np.ndarray | None = None
        self.original_color: np.ndarray | None = None
        self.bbox: tuple[int, int, int, int] | None = None
        self.missed = 0
        self.debug: dict = {"reason": "selection_required"}

    def select(self, frame: PreprocessedFrame, point: tuple[float, float], box: dict | None = None) -> None:
        self.reset()
        if box is None:
            return
        width, height = frame.size
        x, y, w, h = (round(box[k] * frame.scale) for k in ("x", "y", "w", "h"))
        right, bottom = min(width, x + w), min(height, y + h)
        x, y = max(0, x), max(0, y)
        w, h = right - x, bottom - y
        if w < 8 or h < 8 or not (x <= point[0] < right and y <= point[1] < bottom):
            self.debug = {"reason": "invalid_selection"}
            return
        patch = frame.gray[y:bottom, x:right]
        if float(patch.std()) < 3:
            self.debug = {"reason": "insufficient_contrast"}
            return
        self.original = patch.copy()
        self.template = patch.copy()
        self.original_color = frame.bgr[y:bottom, x:right].copy()
        self.bbox = (x, y, w, h)
        self.debug = {"reason": "initialized", "bbox": list(self.bbox)}

    def _search(self, frame: PreprocessedFrame, bounds: tuple[int, int, int, int], global_search: bool):
        left, top, right, bottom = bounds
        search = frame.gray[top:bottom, left:right]
        oh, ow = self.original.shape
        candidates = []
        for scale in (0.85, 1.0, 1.15, 1.35):
            tw, th = max(8, round(ow * scale)), max(8, round(oh * scale))
            if search.shape[0] < th or search.shape[1] < tw:
                continue
            reference = cv2.resize(self.original, (tw, th))
            scores = cv2.matchTemplate(search, reference, cv2.TM_CCOEFF_NORMED)
            scores = np.nan_to_num(scores, nan=-1.0, posinf=-1.0, neginf=-1.0)
            for _ in range(3):
                _, score, _, location = cv2.minMaxLoc(scores)
                bx, by = left + location[0], top + location[1]
                matched = frame.gray[by:by + th, bx:bx + tw]
                if score >= self.min_score and float(matched.std()) >= max(3.0, float(reference.std()) * 0.35):
                    color = frame.bgr[by:by + th, bx:bx + tw].astype(np.float32)
                    reference_color = cv2.resize(self.original_color, (tw, th)).astype(np.float32)
                    # Compare chroma so exposure changes do not hide color identity.
                    chroma_error = float(np.mean(np.abs(
                        (color - color.mean(axis=2, keepdims=True))
                        - (reference_color - reference_color.mean(axis=2, keepdims=True))
                    )))
                    if chroma_error <= 20.0:
                        candidates.append((float(score), bx, by, tw, th))
                sx, sy = location
                scores[max(0, sy - th // 2):sy + th // 2 + 1,
                       max(0, sx - tw // 2):sx + tw // 2 + 1] = -1
        candidates.sort(reverse=True)
        self.debug = {"search": list(bounds), "global": global_search,
                      "candidates": len(candidates), "missed": self.missed}
        if not candidates:
            self.debug["reason"] = "appearance_rejected"
            return None
        best = candidates[0]
        self.debug["score"] = round(best[0], 3)
        for other in candidates[1:]:
            distance = np.hypot((other[1] + other[3] / 2) - (best[1] + best[3] / 2),
                                (other[2] + other[4] / 2) - (best[2] + best[4] / 2))
            if distance > max(best[3], best[4]) * 0.6 and best[0] - other[0] < 0.08:
                self.debug["reason"] = "ambiguous_match"
                return None
        return best

    def detect(self, frame: PreprocessedFrame) -> Detection | None:
        if self.original is None or self.bbox is None:
            return None
        x, y, w, h = self.bbox
        fw, fh = frame.size
        r = self.search_radius
        bounds = (max(0, x - r), max(0, y - r), min(fw, x + w + r), min(fh, y + h + r))
        best = None if self.missed else self._search(frame, bounds, False)
        if best is None:
            # Verify appearance across the full frame instead of taking a nearby blob.
            best = self._search(frame, (0, 0, fw, fh), True)
        if best is None:
            self.missed += 1
            self.debug["missed"] = self.missed
            return None
        confidence, bx, by, bw, bh = best
        self.bbox = (bx, by, bw, bh)
        self.missed = 0
        self.debug.update(reason="detected", bbox=list(self.bbox))
        return Detection("selected", (bx + bw / 2, by + bh / 2), self.bbox,
                         float(bw * bh), confidence, "manual")
