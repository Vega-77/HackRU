"""Tracking for the object the user selected in the app.

The selection gives one picture of the object. Each frame it is found again from three
cues, because each one alone fails on real experiments:

  * appearance: normalized cross-correlation with the original picture and with a copy
    that is slowly updated, since a rolling ball or a swinging bob turns as it moves;
  * colour: for coloured objects, a hue-saturation model of the object against the rest
    of the picture, back-projected into the frame. It survives rotation and motion blur;
  * motion: a constant-velocity prediction, so the search follows a fast object and a
    lookalike elsewhere in the picture cannot win while the object is in view.

If the object is not near its prediction, the whole frame is searched; a match there
must be strong, of the right colour, and clearly better than any other candidate.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import cv2
import numpy as np

from cv_engine.detect import Detection
from cv_engine.preprocess import PreprocessedFrame

HIST_CHANNELS = [0, 1]
HIST_BINS = [18, 16]  # hue, saturation
HIST_RANGES = [0, 180, 0, 256]
COLOR_FLOOR = 0.01
# Template scales tried near the prediction and across the whole frame.
LOCAL_SCALES = (0.85, 1.0, 1.15)
GLOBAL_SCALES = (0.7, 0.85, 1.0, 1.2, 1.4)


@dataclass
class _Candidate:
    cx: float
    cy: float
    w: float
    h: float
    appearance: float  # best correlation with the original or updated picture, -1 to 1
    color: float  # mean colour probability over the candidate, 0 to 1 (0 without a model)
    from_color: bool = False  # found as a blob of the object's colour, not by its picture

    def confidence(self, has_color: bool) -> float:
        a = max(0.0, self.appearance)
        if not has_color:
            return a
        # Independent evidence: either cue alone can vouch for the object.
        return 1.0 - (1.0 - a) * (1.0 - self.color)


class ManualTracker:
    """Follows one selected object. The original picture is kept unchanged as the
    identity reference; `template` adapts to the object's current look."""

    def __init__(self, local_score: float = 0.6, global_score: float = 0.8,
                 min_color: float = 0.3) -> None:
        self.local_score = local_score
        self.global_score = global_score
        self.min_color = min_color
        self.reset()

    def reset(self) -> None:
        self.template: np.ndarray | None = None
        self.original: np.ndarray | None = None
        self.color_model: np.ndarray | None = None
        self.bbox: tuple[int, int, int, int] | None = None
        self.missed = 0
        self.debug: dict = {"reason": "selection_required"}
        self._center = (0.0, 0.0)
        self._size = (0.0, 0.0)
        self._velocity = (0.0, 0.0)  # working px per second
        self._time = 0.0

    # Selection

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
        color_model = _color_model(frame, x, y, w, h)
        if float(patch.std()) < 3 and color_model is None:
            self.debug = {"reason": "insufficient_contrast"}
            return
        self.original = patch.copy()
        self.template = patch.astype(np.float32)
        self.color_model = color_model
        self.bbox = (x, y, w, h)
        self._center = (x + w / 2, y + h / 2)
        self._size = (float(w), float(h))
        self._time = frame.timestamp
        self.debug = {"reason": "initialized", "bbox": list(self.bbox)}

    # Tracking

    def detect(self, frame: PreprocessedFrame) -> Detection | None:
        if self.original is None or self.bbox is None:
            return None
        fw, fh = frame.size
        dt = min(1.0, max(0.0, frame.timestamp - self._time))
        px = self._center[0] + self._velocity[0] * dt
        py = self._center[1] + self._velocity[1] * dt
        speed = math.hypot(*self._velocity) * dt
        w, h = self._size
        reach = max(w, h) / 2 + 24 + 0.75 * speed + 12 * min(self.missed, 6)
        bounds = (max(0, int(px - reach - w / 2)), max(0, int(py - reach - h / 2)),
                  min(fw, int(px + reach + w / 2) + 1), min(fh, int(py + reach + h / 2) + 1))

        best = None
        if bounds[2] - bounds[0] >= 8 and bounds[3] - bounds[1] >= 8:
            best = self._search(frame, bounds, (px, py), reach, global_search=False)
        if best is None:
            best = self._search(frame, (0, 0, fw, fh), (px, py), reach, global_search=True)
        if best is None:
            self.missed += 1
            self.debug["missed"] = self.missed
            return None

        confidence = best.confidence(self.color_model is not None)
        self._update(frame, best, dt)
        self.missed = 0
        self.debug.update(reason="detected", bbox=list(self.bbox), score=round(confidence, 3))
        x, y, bw, bh = self.bbox
        return Detection("selected", (best.cx, best.cy), self.bbox, float(bw * bh), confidence, "manual")

    def _search(self, frame: PreprocessedFrame, bounds, predicted, reach, global_search: bool):
        left, top, right, bottom = bounds
        has_color = self.color_model is not None
        prob = _back_project(frame, self.color_model, bounds) if has_color else None
        candidates = self._template_candidates(frame, bounds, prob, global_search)
        if has_color:
            candidates += self._color_candidates(frame, bounds, prob)

        threshold = self.global_score if global_search else self.local_score
        passing = []
        for c in candidates:
            if has_color and c.color < self.min_color:
                continue  # the right shape in the wrong colour
            # Far from the prediction there is no motion to go on, so both the picture
            # and the colour have to match well on their own.
            if global_search and (c.appearance < 0.65 or (has_color and c.color < 0.5)):
                continue
            score = c.confidence(has_color)
            if score < threshold:
                continue
            distance = math.hypot(c.cx - predicted[0], c.cy - predicted[1]) / max(reach, 1.0)
            if not global_search and distance > 1.0:
                continue
            # Near the prediction, prefer the closer of two good matches.
            rank = score if global_search else score * (1.0 - 0.3 * min(1.0, distance) ** 2)
            passing.append((rank, score, c))
        passing.sort(key=lambda item: item[0], reverse=True)
        self.debug = {"search": [int(left), int(top), int(right), int(bottom)], "global": global_search,
                      "candidates": len(passing), "missed": self.missed}
        if not passing:
            self.debug["reason"] = "appearance_rejected"
            return None
        rank, score, best = passing[0]
        self.debug["score"] = round(score, 3)
        if global_search:
            size = max(best.w, best.h)
            for other_rank, _, other in passing[1:]:
                if math.hypot(other.cx - best.cx, other.cy - best.cy) > size * 0.6 and rank - other_rank < 0.08:
                    self.debug["reason"] = "ambiguous_match"
                    return None
        if not best.from_color:
            # A picture match can sit a few pixels off on a blurred, turning ball; the
            # colour blob around it marks the middle, so split the difference.
            size = max(best.w, best.h)
            blobs = [c for _, _, c in passing
                     if c.from_color and math.hypot(c.cx - best.cx, c.cy - best.cy) < size * 0.5]
            if blobs:
                blob = blobs[0]
                best = _Candidate((best.cx + blob.cx) / 2, (best.cy + blob.cy) / 2, best.w, best.h,
                                  best.appearance, max(best.color, blob.color))
        return best

    def _template_candidates(self, frame, bounds, prob, global_search: bool) -> list[_Candidate]:
        left, top, right, bottom = bounds
        search = frame.gray[top:bottom, left:right].astype(np.float32)
        w, h = self._size
        references = [self.original.astype(np.float32)]
        if self.template is not None:
            references.append(self.template)
        out = []
        for scale in GLOBAL_SCALES if global_search else LOCAL_SCALES:
            tw, th = max(8, round(w * scale)), max(8, round(h * scale))
            if search.shape[0] < th or search.shape[1] < tw:
                continue
            mask = _ellipse_mask(tw, th)
            scores = None
            for reference in references:
                s = cv2.matchTemplate(search, cv2.resize(reference, (tw, th)), cv2.TM_CCOEFF_NORMED, mask=mask)
                s = np.nan_to_num(s, nan=-1.0, posinf=-1.0, neginf=-1.0)
                scores = s if scores is None else np.maximum(scores, s)
            for _ in range(3):
                _, score, _, (sx, sy) = cv2.minMaxLoc(scores)
                if score < 0.3:
                    break
                matched = search[sy:sy + th, sx:sx + tw]
                if float(matched.std()) >= max(3.0, float(self.original.std()) * 0.35):
                    cx, cy = left + sx + tw / 2, top + sy + th / 2
                    out.append(_Candidate(cx, cy, tw, th, float(score),
                                          _mean_in_ellipse(prob, cx - left, cy - top, tw, th)))
                scores[max(0, sy - th // 2):sy + th // 2 + 1, max(0, sx - tw // 2):sx + tw // 2 + 1] = -1
        return out

    def _color_candidates(self, frame, bounds, prob) -> list[_Candidate]:
        """Blobs of the object's colour: the centre of a turning, blurred ball."""
        left, top = bounds[0], bounds[1]
        w, h = self._size
        expected = w * h * 0.6
        mask = (cv2.GaussianBlur(prob, (5, 5), 0) >= 0.5).astype(np.uint8)
        n, _, stats, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
        out = []
        for i in range(1, n):
            area = stats[i, cv2.CC_STAT_AREA]
            if not 0.2 * expected <= area <= 4 * expected:
                continue
            cx, cy = centroids[i]
            color = _mean_in_ellipse(prob, cx, cy, w, h)
            appearance = self._appearance_at(frame, left + cx, top + cy)
            out.append(_Candidate(left + cx, top + cy, w, h, appearance, color, from_color=True))
        return out

    def _appearance_at(self, frame: PreprocessedFrame, cx: float, cy: float) -> float:
        """Best correlation within a few pixels of (cx, cy)."""
        w, h = round(self._size[0]), round(self._size[1])
        fw, fh = frame.size
        slack = 3
        x0, y0 = int(round(cx - w / 2)) - slack, int(round(cy - h / 2)) - slack
        x1, y1 = x0 + w + 2 * slack, y0 + h + 2 * slack
        if x0 < 0 or y0 < 0 or x1 > fw or y1 > fh:
            return 0.0
        region = frame.gray[y0:y1, x0:x1].astype(np.float32)
        mask = _ellipse_mask(w, h)
        best = -1.0
        for reference in (self.original.astype(np.float32), self.template):
            if reference is None:
                continue
            s = cv2.matchTemplate(region, cv2.resize(reference, (w, h)), cv2.TM_CCOEFF_NORMED, mask=mask)
            best = max(best, float(np.nan_to_num(s, nan=-1.0, posinf=-1.0, neginf=-1.0).max()))
        return best

    def _update(self, frame: PreprocessedFrame, best: _Candidate, dt: float) -> None:
        cx, cy = best.cx, best.cy
        if dt > 0 and self.missed < 3:
            vx, vy = (cx - self._center[0]) / dt, (cy - self._center[1]) / dt
            # Follow changes in speed quickly (a falling ball), but not frame-to-frame jitter.
            self._velocity = (0.4 * self._velocity[0] + 0.6 * vx, 0.4 * self._velocity[1] + 0.6 * vy)
        else:
            self._velocity = (0.0, 0.0)
        oh, ow = self.original.shape
        w = float(np.clip(0.7 * self._size[0] + 0.3 * best.w, 0.5 * ow, 2.0 * ow))
        h = float(np.clip(0.7 * self._size[1] + 0.3 * best.h, 0.5 * oh, 2.0 * oh))
        self._center, self._size, self._time = (cx, cy), (w, h), frame.timestamp
        fw, fh = frame.size
        x = int(round(min(max(cx - w / 2, 0), fw - w)))
        y = int(round(min(max(cy - h / 2, 0), fh - h)))
        self.bbox = (x, y, int(round(w)), int(round(h)))
        # Learn the current look only from a confident, clearly visible match.
        if best.appearance >= 0.55 and (self.color_model is None or best.color >= 0.5):
            patch = frame.gray[y:y + self.bbox[3], x:x + self.bbox[2]]
            if patch.shape[0] >= 4 and patch.shape[1] >= 4:
                th, tw = self.template.shape
                self.template = 0.8 * self.template + 0.2 * cv2.resize(patch.astype(np.float32), (tw, th))


def _color_model(frame: PreprocessedFrame, x: int, y: int, w: int, h: int) -> np.ndarray | None:
    """How likely each hue-saturation bin is to be the object rather than the rest of the
    picture, or None when the object's colour does not set it apart (grey objects, or
    colours that are all over the background)."""
    core = np.zeros((h, w), np.uint8)
    cv2.ellipse(core, (w // 2, h // 2), (max(1, w * 2 // 5), max(1, h * 2 // 5)), 0, 0, 360, 255, -1)
    outside = np.full(frame.hsv.shape[:2], 255, np.uint8)
    outside[y:y + h, x:x + w] = 0
    obj = cv2.calcHist([frame.hsv[y:y + h, x:x + w]], HIST_CHANNELS, core, HIST_BINS, HIST_RANGES)
    rest = cv2.calcHist([frame.hsv], HIST_CHANNELS, outside, HIST_BINS, HIST_RANGES)
    # Blur along saturation only: light changes saturation, but hue is what tells a red
    # ball from a skin-coloured hand.
    obj = cv2.GaussianBlur(obj / max(float(obj.sum()), 1.0), (3, 1), 0)
    rest = cv2.GaussianBlur(rest / max(float(rest.sum()), 1.0), (3, 1), 0)
    # The floor stands in for colours not in this picture yet (a hand that reaches in
    # later): a colour the object barely has must not count as the object.
    model = (obj / (obj + rest + COLOR_FLOOR)).astype(np.float32)
    prob = _back_project(frame, model, (0, 0) + frame.size)
    inside = _mean_in_ellipse(prob, x + w / 2, y + h / 2, w, h)
    pad = max(w, h) // 2 + 4
    ring = np.zeros(prob.shape, np.uint8)
    ring[max(0, y - pad):y + h + pad, max(0, x - pad):x + w + pad] = 1
    ring[y:y + h, x:x + w] = 0
    around = float(prob[ring > 0].mean()) if ring.any() else 0.0
    if inside < 0.5 or inside - around < 0.3:
        return None
    return model


def _ellipse_mask(w: int, h: int) -> np.ndarray:
    """The ellipse inside a w x h box. Matching only inside it keeps the background in the
    corners of the selection from pulling the match off the object as it moves."""
    mask = np.zeros((h, w), np.float32)
    cv2.ellipse(mask, (w // 2, h // 2), (max(1, round(w * 0.47)), max(1, round(h * 0.47))), 0, 0, 360, 1.0, -1)
    return mask


def _back_project(frame: PreprocessedFrame, model: np.ndarray, bounds) -> np.ndarray:
    left, top, right, bottom = bounds
    hsv = frame.hsv[top:bottom, left:right]
    # The result has the image's depth (uint8), so scale the 0-1 model up and back down.
    return cv2.calcBackProject([hsv], HIST_CHANNELS, model, HIST_RANGES, scale=255).astype(np.float32) / 255


def _mean_in_ellipse(prob: np.ndarray | None, cx: float, cy: float, w: float, h: float) -> float:
    if prob is None:
        return 0.0
    ph, pw = prob.shape
    x0, y0 = max(0, int(cx - w / 2)), max(0, int(cy - h / 2))
    x1, y1 = min(pw, int(cx + w / 2) + 1), min(ph, int(cy + h / 2) + 1)
    if x1 <= x0 or y1 <= y0:
        return 0.0
    mask = np.zeros((y1 - y0, x1 - x0), np.uint8)
    cv2.ellipse(mask, (int(cx - x0), int(cy - y0)), (max(1, int(w * 0.4)), max(1, int(h * 0.4))),
                0, 0, 360, 1, -1)
    region = prob[y0:y1, x0:x1]
    return float(region[mask > 0].mean()) if mask.any() else 0.0


def box_from_tap(frame: PreprocessedFrame, point: tuple[float, float]) -> tuple[int, int, int, int] | None:
    """The box of the object under a tap (working pixels), or None if nothing there
    stands out from its surroundings, such as a tap on a bare or evenly textured table.

    Tries squares of growing size around the tap, and around points a little off it since
    a finger rarely lands in the middle. From the squares whose colours differ most from
    the ring around them, it fits the box to the pixels of those colours. That region has
    to be enclosed by the ring: a patch of table runs on past it, an object does not."""
    fw, fh = frame.size
    step = 5 * fw / 320
    found = []
    for dx, dy in ((0, 0), (step, step), (-step, step), (step, -step), (-step, -step)):
        centre = (point[0] + dx, point[1] + dy)
        tries = []
        for fraction in (0.04, 0.055, 0.075, 0.1, 0.13, 0.17, 0.22):
            half = fraction * fw / 2
            inner = _clip_box(centre[0] - half, centre[1] - half, centre[0] + half, centre[1] + half, fw, fh)
            outer = _clip_box(centre[0] - 2 * half, centre[1] - 2 * half,
                              centre[0] + 2 * half, centre[1] + 2 * half, fw, fh)
            if inner is None or outer is None:
                continue
            inside, around = _tap_histograms(frame, inner, outer)
            if inside is None:
                continue
            distance = cv2.compareHist(inside, around, cv2.HISTCMP_BHATTACHARYYA)
            if distance >= TAP_MIN_DISTANCE:
                tries.append((distance, inner, outer, inside, around))
        for distance, inner, outer, inside, around in sorted(tries, key=lambda t: t[0], reverse=True)[:3]:
            box = _enclosed_region(frame, point, inner, outer, inside, around)
            if box is not None:
                found.append((distance, box))
                break
    return max(found)[1] if found else None


def _enclosed_region(frame, point, inner, outer, inside, around):
    model = (inside / (inside + around + 1e-6)).astype(np.float32)
    x0, y0, x1, y1 = outer
    # Looked up in numpy: OpenCV reads a 3D numpy histogram as a 2D image with channels.
    hsv = frame.hsv[y0:y1, x0:x1].astype(np.int32)
    prob = model[hsv[..., 0] * TAP_BINS[0] // 180, hsv[..., 1] * TAP_BINS[1] // 256, hsv[..., 2] * TAP_BINS[2] // 256]
    mask = (cv2.GaussianBlur(prob, (3, 3), 0) >= 0.5).astype(np.uint8)
    mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    ix0, iy0, ix1, iy1 = (inner[0] - x0, inner[1] - y0, inner[2] - x0, inner[3] - y0)
    overlap = np.bincount(labels[iy0:iy1, ix0:ix1].ravel(), minlength=n)
    overlap[0] = 0
    label = int(overlap.argmax())
    if overlap[label] == 0:
        return None
    x, y, w, h, area = (int(v) for v in stats[label])
    fw, fh = frame.size
    side = (inner[2] - inner[0]) * (inner[3] - inner[1])
    # Touching the edge of the search square means it carries on beyond it. At the edge of
    # the picture there is no telling, and a cut-off object is a poor selection anyway.
    touches = x == 0 or y == 0 or x + w == x1 - x0 or y + h == y1 - y0
    if touches or area < 0.25 * side or area > 2.5 * side:
        return None
    tx, ty = point[0] - x0, point[1] - y0
    if not (x - 3 <= tx <= x + w + 3 and y - 3 <= ty <= y + h + 3):
        return None  # the tap was beside the object, not on it
    # An object has a sharp outline most of the way round; a blotch on the table fades out,
    # and is only sharp where it happens to run along something else.
    gray = frame.gray[y0:y1, x0:x1].astype(np.float32)
    edges = cv2.magnitude(cv2.Sobel(gray, cv2.CV_32F, 1, 0), cv2.Sobel(gray, cv2.CV_32F, 0, 1))
    region = (labels == label).astype(np.uint8)
    outline = edges[cv2.morphologyEx(region, cv2.MORPH_GRADIENT, np.ones((3, 3), np.uint8)) > 0]
    typical = max(float(np.median(edges)), 4.0)
    if outline.mean() < TAP_MIN_EDGE * typical or (outline > TAP_MIN_EDGE * typical).mean() < TAP_MIN_SHARP:
        return None
    x, y = max(0, x + x0 - 2), max(0, y + y0 - 2)
    w, h = min(fw - x, w + 4), min(fh - y, h + 4)
    return (x, y, w, h) if w >= 8 and h >= 8 else None


TAP_MIN_DISTANCE = 0.55
TAP_MIN_EDGE = 2.5  # outline gradient over the window's median gradient
TAP_MIN_SHARP = 0.3  # share of the outline that is that sharp
TAP_BINS = [8, 3, 4]  # hue, saturation, value: coarse, since the squares are small


def _clip_box(x0, y0, x1, y1, fw, fh):
    x0, y0, x1, y1 = max(0, int(x0)), max(0, int(y0)), min(fw, int(x1)), min(fh, int(y1))
    return (x0, y0, x1, y1) if x1 - x0 >= 6 and y1 - y0 >= 6 else None


def _tap_histograms(frame, inner, outer):
    x0, y0, x1, y1 = outer
    ring = np.full((y1 - y0, x1 - x0), 255, np.uint8)
    ring[inner[1] - y0:inner[3] - y0, inner[0] - x0:inner[2] - x0] = 0
    if not ring.any():
        return None, None
    ranges = [0, 180, 0, 256, 0, 256]
    inside = cv2.calcHist([frame.hsv[inner[1]:inner[3], inner[0]:inner[2]]], [0, 1, 2], None, TAP_BINS, ranges)
    around = cv2.calcHist([frame.hsv[y0:y1, x0:x1]], [0, 1, 2], ring, TAP_BINS, ranges)
    return inside / max(float(inside.sum()), 1.0), around / max(float(around.sum()), 1.0)
