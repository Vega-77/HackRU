"""Appearance matching for an explicitly selected object."""

from __future__ import annotations

import cv2
import numpy as np

from cv_engine.detect import Detection
from cv_engine.foreground import RoundReference, selected_foreground
from cv_engine.preprocess import PreprocessedFrame


def weighted_scores(search, references, weights):
    """Normalized correlation with shared weighted image moments across references."""
    pixels = search.astype(np.float32)
    total = float(weights.sum())
    mean_sum = cv2.matchTemplate(pixels, weights, cv2.TM_CCORR)
    variance = cv2.matchTemplate(pixels * pixels, weights, cv2.TM_CCORR) - mean_sum * mean_sum / total
    variance = np.maximum(variance, 0)
    best = np.full(variance.shape, -1, np.float32)
    for reference in references:
        reference = reference.astype(np.float32)
        centered = reference - float(np.sum(reference * weights)) / total
        energy = float(np.sum(centered * centered * weights))
        denominator = np.sqrt(variance * energy)
        numerator = cv2.matchTemplate(pixels, centered * weights, cv2.TM_CCORR)
        scores = np.divide(numerator, denominator, out=np.full_like(numerator, -1), where=denominator > 1)
        best = np.maximum(best, np.clip(scores, -1, 1))
    return best


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
        self.foreground: np.ndarray | None = None
        self.round_reference: RoundReference | None = None
        self.silhouette: np.ndarray | None = None
        self.match_channel: int | None = None
        self._verified_masks: dict = {}
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
            # Different colors can have identical grayscale brightness.
            lab = cv2.cvtColor(frame.bgr[y:bottom, x:right], cv2.COLOR_BGR2LAB)
            channel = 1 + int(np.argmax(lab[:, :, 1:].std(axis=(0, 1))))
            if float(lab[:, :, channel].std()) < 3:
                self.debug = {"reason": "insufficient_contrast"}
                return
            self.match_channel = channel
            patch = lab[:, :, channel]
        self.original = patch.copy()
        self.template = patch.copy()
        self.original_color = frame.bgr[y:bottom, x:right].copy()
        seed = (min(w - 2, max(1, round(point[0] - x))),
                min(h - 2, max(1, round(point[1] - y))))
        self.foreground = selected_foreground(self.original_color, seed)
        self.round_reference = RoundReference.from_mask(self.original_color, self.foreground)
        if self.round_reference is not None:
            silhouette = np.full(patch.shape, np.median(patch[self.foreground == 0]), np.uint8)
            silhouette[self.foreground > 0] = np.median(patch[self.foreground > 0])
            self.silhouette = cv2.GaussianBlur(silhouette, (5, 5), 0)
        self.bbox = (x, y, w, h)
        self.debug = {"reason": "initialized", "bbox": list(self.bbox)}

    def _search(self, frame: PreprocessedFrame, bounds: tuple[int, int, int, int], global_search: bool):
        left, top, right, bottom = bounds
        appearance = self._appearance(frame)
        search = appearance[top:bottom, left:right]
        oh, ow = self.original.shape
        candidates = []
        for scale in (0.55, 0.7, 0.85, 1.0, 1.15, 1.35):
            tw, th = max(8, round(ow * scale)), max(8, round(oh * scale))
            if search.shape[0] < th or search.shape[1] < tw:
                continue
            reference = cv2.resize(self.original, (tw, th))
            weights = None
            if self.foreground is not None:
                foreground = cv2.resize(self.foreground, (tw, th), interpolation=cv2.INTER_NEAREST)
                # Retain a narrow silhouette transition without matching the whole background.
                weights = (foreground.astype(np.float32) + .2 * cv2.dilate(foreground, np.ones((5, 5), np.uint8))).astype(np.float32)
                if self.round_reference is not None:
                    ring = cv2.dilate(foreground, np.ones((3, 3), np.uint8)) - cv2.erode(foreground, np.ones((3, 3), np.uint8))
                    weights = (.1 * foreground + ring).astype(np.float32)
            if weights is None:
                scores = cv2.matchTemplate(search, reference, cv2.TM_CCOEFF_NORMED)
            else:
                references = [reference]
                if self.silhouette is not None:
                    references.append(cv2.resize(self.silhouette, (tw, th)))
                    if not np.array_equal(self.template, self.original):
                        references.append(cv2.resize(self.template, (tw, th)))
                scores = weighted_scores(search, references, weights * weights)
            scores = np.nan_to_num(scores, nan=-1.0, posinf=-1.0, neginf=-1.0)
            for _ in range(3):
                _, score, _, location = cv2.minMaxLoc(scores)
                bx, by = left + location[0], top + location[1]
                matched = appearance[by:by + th, bx:bx + tw]
                threshold = self.min_score
                if score >= threshold and float(matched.std()) >= max(3.0, float(reference.std()) * 0.35):
                    color = frame.bgr[by:by + th, bx:bx + tw].astype(np.float32)
                    if self.round_reference is not None:
                        if self.round_reference.appearance_matches(color.astype(np.uint8), foreground):
                            candidates.append((float(score), bx, by, tw, th))
                        sx, sy = location
                        scores[max(0, sy - th // 2):sy + th // 2 + 1,
                               max(0, sx - tw // 2):sx + tw // 2 + 1] = -1
                        continue
                    reference_color = cv2.resize(self.original_color, (tw, th)).astype(np.float32)
                    # Compare chroma so exposure changes do not hide color identity.
                    chroma_difference = np.abs(
                        (color - color.mean(axis=2, keepdims=True))
                        - (reference_color - reference_color.mean(axis=2, keepdims=True))
                    )
                    chroma_error = float(np.mean(chroma_difference[foreground > 0])
                                         if weights is not None else np.mean(chroma_difference))
                    if chroma_error <= 20.0:
                        candidates.append((float(score), bx, by, tw, th))
                sx, sy = location
                scores[max(0, sy - th // 2):sy + th // 2 + 1,
                       max(0, sx - tw // 2):sx + tw // 2 + 1] = -1
        candidates.sort(reverse=True)
        if self.round_reference is not None:
            verified_candidates = []
            for candidate in candidates:
                score, bx, by, tw, th = candidate
                if verified_candidates and verified_candidates[0][0] - score >= .08:
                    break
                foreground = cv2.resize(self.foreground, (tw, th), interpolation=cv2.INTER_NEAREST)
                verified = self.round_reference.verify(frame.bgr[by:by + th, bx:bx + tw], foreground)
                if verified is not None:
                    mask, inside, outside = verified
                    # Weak neutral-color evidence needs a stronger appearance match.
                    if score < .76 and not (inside >= .85 and inside - outside >= .4):
                        continue
                    self._verified_masks[(bx, by, tw, th)] = mask
                    verified_candidates.append(candidate)
            candidates = verified_candidates
        self.debug = {"search": list(bounds), "global": global_search,
                      "candidates": len(candidates), "missed": self.missed,
                      "method": "foreground_verified" if self.round_reference is not None else
                                "masked_template" if self.foreground is not None else "template"}
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

    def _appearance(self, frame: PreprocessedFrame) -> np.ndarray:
        if self.match_channel is None:
            return frame.gray
        return cv2.cvtColor(frame.bgr, cv2.COLOR_BGR2LAB)[:, :, self.match_channel]

    def detect(self, frame: PreprocessedFrame) -> Detection | None:
        if self.original is None or self.bbox is None:
            return None
        x, y, w, h = self.bbox
        self._verified_masks.clear()
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
        center = (bx + bw / 2, by + bh / 2)
        verified = self._verified_masks.get(self.bbox)
        if verified is not None:
            moments = cv2.moments(verified)
            center = (bx + moments['m10'] / moments['m00'], by + moments['m01'] / moments['m00'])
            if confidence >= .9:
                # Update only a visually verified foreground; preserve the immutable original.
                update = cv2.resize(self._appearance(frame)[by:by + bh, bx:bx + bw],
                                    (self.original.shape[1], self.original.shape[0]))
                self.template[self.foreground > 0] = update[self.foreground > 0]
        return Detection("selected", center, self.bbox,
                         float(bw * bh), confidence, "manual")
