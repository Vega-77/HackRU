"""Tracking for the object the user selected in the app.

The selection gives one picture of the object. Inside the user's box the object is first
separated from whatever else the box took in (the fingers holding a ball, the table), and
only the object is followed. Each frame it is found again from these cues, because each
one alone fails on real experiments:

  * appearance: normalized cross-correlation over the object's own pixels with the
    original picture and with a copy that is slowly updated, since a rolling ball or a
    swinging bob turns as it moves;
  * outline: for a round object, its silhouette against the background, which is still
    there when its markings turn out of view, and a check that a match has the object's
    colours inside a round outline (so a wrist or a face is not taken for a grey ball);
  * colour: for coloured objects, a hue-saturation model of the object against the rest
    of the picture, back-projected into the frame. It survives rotation and motion blur;
  * motion: a constant-velocity prediction, so the search follows a fast object and a
    lookalike elsewhere in the picture cannot win while the object is in view.

If the object is not near its prediction, or was lost, the whole frame is searched; a
match there must be strong, of the right colour, and clearly better than any other.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import cv2
import numpy as np

from cv_engine.detect import Detection
from cv_engine.foreground import RoundReference, selected_foreground
from cv_engine.preprocess import PreprocessedFrame

HIST_CHANNELS = [0, 1]
HIST_BINS = [18, 16]  # hue, saturation
HIST_RANGES = [0, 180, 0, 256]
# Red sits on both sides of OpenCV's hue wrap (0 and 179), and a blurred or relit red ball
# flickers across it from frame to frame. For a red object hue is turned by half a bin
# before binning, so reds from 175 to 4 share one bin instead of being split between the
# first and the last.
RED_HUE_SHIFT = 5
COLOR_FLOOR = 0.01
MIN_SATURATION = 50  # of 255: below this an object is neutral and gets no colour model
# Template scales tried near the prediction and across the whole frame.
LOCAL_SCALES = (0.85, 1.0, 1.15)
GLOBAL_SCALES = (0.55, 0.7, 0.85, 1.0, 1.2, 1.4)
ROUND_GLOBAL_SCORE = 0.7  # far from the prediction, for a round object checked by its outline
REFERENCE_FPS = 15.0  # the search margin is sized for frames this far apart
UNKNOWN_SPEED = 400.0  # px/s at 320 px wide: how fast an object of unknown speed may go
MAX_GAP_S = 0.34  # about 3 fps: the slowest stream the search margin still widens for
RECENT_FIX_S = 0.5  # a recovery this soon after the last fix still tells the speed


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
        self.hue_shift = 0  # added to hue before the colour model's bins (see RED_HUE_SHIFT)
        self.foreground: np.ndarray | None = None  # the object's pixels in the user's box
        self.round_reference: RoundReference | None = None
        self.silhouette: np.ndarray | None = None
        self.match_channel: int | None = None  # Lab channel matched instead of brightness
        self.bbox: tuple[int, int, int, int] | None = None
        self.missed = 0
        self.debug: dict = {"reason": "selection_required"}
        self._mask: np.ndarray | None = None  # matching weights: the object's shape in the box
        self._outline: np.ndarray | None = None  # matching weights for the silhouette
        self._center = (0.0, 0.0)
        self._size = (0.0, 0.0)
        self._velocity = (0.0, 0.0)  # working px per second
        self._velocity_known = False
        self._time = 0.0
        self._image: np.ndarray | None = None  # this frame in the matched channel
        self._scene_lightness = 0.0
        self._lightness_shift = 0.0

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
        colors = frame.bgr[y:bottom, x:right]
        seed = (min(w - 2, max(1, round(point[0] - x))), min(h - 2, max(1, round(point[1] - y))))
        foreground = selected_foreground(colors, seed)
        round_reference = RoundReference.from_mask(colors, foreground)
        if round_reference is None:
            # A tight box can put the ball itself on GrabCut's hard background
            # border. Retry with real surrounding pixels, keeping the same seed
            # and probable foreground box. Accept only a separable round object.
            pad = max(4, round(min(w, h) * 0.2))
            ax, ay = max(0, x - pad), max(0, y - pad)
            ar, ab = min(width, right + pad), min(height, bottom + pad)
            context = frame.bgr[ay:ab, ax:ar]
            bounds = (x - ax, y - ay, w, h)
            expanded = selected_foreground(
                context, (seed[0] + x - ax, seed[1] + y - ay), bounds)
            rounded = RoundReference.from_mask(context, expanded)
            if rounded is not None:
                foreground, colors, round_reference = expanded, context, rounded
                x, y, w, h = ax, ay, ar - ax, ab - ay
        if foreground is not None:
            # Follow the object alone, not the fingers or table the box also took in, with
            # a margin so its outline against the background is part of the picture.
            fx, fy, fw, fh = cv2.boundingRect(foreground)
            pad = max(2, round(0.15 * max(fw, fh)))
            ox, oy = max(0, fx - pad), max(0, fy - pad)
            ox1, oy1 = min(w, fx + fw + pad), min(h, fy + fh + pad)
            mask = foreground[oy:oy1, ox:ox1]
            tx, ty, tw, th = x + ox, y + oy, ox1 - ox, oy1 - oy
        else:
            mask = None
            tx, ty, tw, th = x, y, w, h
        color_model, hue_shift = _color_model(frame, tx, ty, tw, th, mask)
        patch = frame.gray[ty:ty + th, tx:tx + tw]
        if float(patch.std()) < 3:
            # Different colours can have the same brightness: match the Lab channel that
            # tells the object from its surroundings instead.
            lab = cv2.cvtColor(frame.bgr[ty:ty + th, tx:tx + tw], cv2.COLOR_BGR2LAB)
            channel = 1 + int(np.argmax(lab[:, :, 1:].std(axis=(0, 1))))
            if float(lab[:, :, channel].std()) >= 3:
                self.match_channel = channel
                patch = lab[:, :, channel]
            elif color_model is None:
                self.debug = {"reason": "insufficient_contrast"}
                return
        self.foreground = foreground
        self.round_reference = round_reference
        self.original = patch.copy()
        self.template = patch.astype(np.float32)
        self.color_model = color_model
        self.hue_shift = hue_shift
        if mask is None:
            self._mask = _ellipse_mask(tw, th)
        else:
            # Keep a little of the object's edge against the background.
            kernel = np.ones((3, 3), np.uint8)
            self._mask = mask + 0.2 * cv2.dilate(mask, np.ones((5, 5), np.uint8)).astype(np.float32)
            inside = mask > 0
            if self.round_reference is not None and not inside.all():
                silhouette = np.full(patch.shape, np.median(patch[~inside]), np.float32)
                silhouette[inside] = np.median(patch[inside])
                self.silhouette = cv2.GaussianBlur(silhouette, (5, 5), 0)
                ring = cv2.dilate(mask, kernel) - cv2.erode(mask, kernel)
                self._outline = (0.1 * mask + ring).astype(np.float32)
        self.bbox = (tx, ty, tw, th)
        self._center = (tx + tw / 2, ty + th / 2)
        self._size = (float(tw), float(th))
        self._time = frame.timestamp
        self._scene_lightness = float(np.median(cv2.cvtColor(frame.bgr, cv2.COLOR_BGR2LAB)[:, :, 0]))
        self.debug = {"reason": "initialized", "bbox": list(self.bbox)}

    @property
    def method(self) -> str:
        if self.round_reference is not None and self.color_model is None:
            return "foreground_verified"
        return "masked_template" if self.foreground is not None else "template"

    # Tracking

    def detect(self, frame: PreprocessedFrame) -> Detection | None:
        if self.original is None or self.bbox is None:
            return None
        if self.round_reference is not None:
            scene = float(np.median(cv2.cvtColor(frame.bgr, cv2.COLOR_BGR2LAB)[:, :, 0]))
            self._lightness_shift = float(np.clip(scene - self._scene_lightness, -40, 40))
        if self.match_channel is None:
            self._image = frame.gray
        else:
            self._image = cv2.cvtColor(frame.bgr, cv2.COLOR_BGR2LAB)[:, :, self.match_channel]
        fw, fh = frame.size
        dt = min(1.0, max(0.0, frame.timestamp - self._time))
        px = self._center[0] + self._velocity[0] * dt
        py = self._center[1] + self._velocity[1] * dt
        speed = math.hypot(*self._velocity) * dt
        w, h = self._size
        # How far the object may be from the prediction grows with the time between frames,
        # which is longer on a slow connection. Until a speed is known (just selected, or
        # found again after a long gap) it may also be moving at any speed a hand or a ramp
        # gives it. Only for frames that follow on from each other: after a longer gap the
        # object could be anywhere, and the whole-frame search with its stricter checks
        # finds it.
        gap = dt if dt <= MAX_GAP_S else 0.0
        per_frame = max(1.0, gap * REFERENCE_FPS)
        unknown = 0.0 if self._velocity_known else UNKNOWN_SPEED * fw / 320 * gap
        reach = max(w, h) / 2 + 24 * per_frame + 0.75 * speed + unknown + 12 * min(self.missed, 6)
        bounds = (max(0, int(px - reach - w / 2)), max(0, int(py - reach - h / 2)),
                  min(fw, int(px + reach + w / 2) + 1), min(fh, int(py + reach + h / 2) + 1))

        best = None
        # While the object is in view it is looked for near where it is heading. Once it
        # was lost, the whole frame is searched, so a lookalike that turned up elsewhere in
        # the meantime makes the match ambiguous instead of going unnoticed.
        if self.missed == 0 and bounds[2] - bounds[0] >= 8 and bounds[3] - bounds[1] >= 8:
            best = self._search(frame, bounds, (px, py), reach, global_search=False)
        recovered = best is None
        if best is None:
            best = self._search(frame, (0, 0, fw, fh), (px, py), reach, global_search=True)
        if best is None:
            self.missed += 1
            self.debug["missed"] = self.missed
            return None

        confidence = best.confidence(self.color_model is not None)
        self._update(frame, best, dt, recovered)
        self.missed = 0
        self.debug.update(reason="detected", bbox=list(self.bbox), score=round(confidence, 3))
        x, y, bw, bh = self.bbox
        # Positions here are continuous (a box from x to x + w has its middle at x + w / 2);
        # detections report pixel indices, like the other detectors' centroids.
        return Detection("selected", (best.cx - 0.5, best.cy - 0.5), self.bbox, float(bw * bh), confidence, "manual")

    def _search(self, frame: PreprocessedFrame, bounds, predicted, reach, global_search: bool):
        left, top, right, bottom = bounds
        has_color = self.color_model is not None
        prob = _back_project(frame, self.color_model, bounds, self.hue_shift) if has_color else None
        candidates = self._template_candidates(bounds, prob, global_search)
        if has_color:
            candidates += self._color_candidates(frame, bounds, prob)

        # A round object without a colour of its own (a grey or white ball) is checked by
        # its outline and shading at every match instead. That check lets a weaker picture
        # match count far from the prediction.
        check_outline = self.round_reference is not None and not has_color
        far_score = ROUND_GLOBAL_SCORE if check_outline else self.global_score
        passing = []
        for c in candidates:
            if has_color and c.color < self.min_color:
                continue  # the right shape in the wrong colour
            score = c.confidence(has_color)
            distance = math.hypot(c.cx - predicted[0], c.cy - predicted[1]) / max(reach, 1.0)
            near = distance <= 1.0
            if global_search and not near:
                # Far from the prediction there is no motion to go on, so both the picture
                # and the colour have to match well on their own.
                if c.appearance < 0.65 or (has_color and c.color < 0.5) or score < far_score:
                    continue
            elif not near or score < self.local_score:
                continue
            if check_outline and not self._verified(frame, c):
                continue
            # Near the prediction, prefer the closer of two good matches.
            rank = score * (1.0 - 0.3 * min(1.0, distance) ** 2)
            passing.append((rank, score, c))
        passing.sort(key=lambda item: item[0], reverse=True)
        self.debug = {"search": [int(left), int(top), int(right), int(bottom)], "global": global_search,
                      "candidates": len(passing), "missed": self.missed, "method": self.method}
        if not passing:
            self.debug["reason"] = "appearance_rejected"
            return None
        rank, score, best = passing[0]
        self.debug["score"] = round(score, 3)
        if global_search:
            # Part of a blurred or half-hidden object can match a shrunken picture better
            # than the whole of it does: of overlapping matches, take the largest that is
            # nearly as good.
            best = max((c for _, s, c in passing
                        if s >= score - 0.1 and math.hypot(c.cx - best.cx, c.cy - best.cy) < 0.5 * max(c.w, best.w)),
                       key=lambda c: c.w * c.h)
            size = max(best.w, best.h)
            for _, other_score, other in passing[1:]:
                if math.hypot(other.cx - best.cx, other.cy - best.cy) > size * 0.6 and score - other_score < 0.08:
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

    def _verified(self, frame: PreprocessedFrame, c: _Candidate) -> bool:
        """A round object's colours fill a round outline at the candidate, and are not all
        around it as they would be on a wrist, a face or a wall."""
        tw, th = max(8, round(c.w)), max(8, round(c.h))
        fw, fh = frame.size
        bx = min(max(0, int(round(c.cx - tw / 2))), fw - tw)
        by = min(max(0, int(round(c.cy - th / 2))), fh - th)
        if bx < 0 or by < 0:
            return False
        # The box keeps a margin around the object, for the ring verify() compares it with.
        outline = cv2.resize((self._mask >= 1).astype(np.uint8), (tw, th), interpolation=cv2.INTER_NEAREST)
        verified = self.round_reference.verify(
            frame.bgr[by:by + th, bx:bx + tw], outline, self._lightness_shift)
        if verified is None:
            return False
        _, inside, outside = verified
        # Weak evidence from the shading needs a stronger picture match.
        return c.appearance >= 0.76 or (inside >= 0.85 and inside - outside >= 0.4)

    def _references(self, tw: int, th: int):
        """(weights, pictures) to match at this size. Usually the object's own pixels,
        against the original and updated pictures. A grey or white ball's surface says
        little (its markings turn out of view, glare comes and goes), so it is matched by
        its outline instead, and against its silhouette as well."""
        pictures = [cv2.resize(self.original.astype(np.float32), (tw, th)), cv2.resize(self.template, (tw, th))]
        if self.silhouette is not None and self.color_model is None:
            weights = cv2.resize(self._outline, (tw, th), interpolation=cv2.INTER_NEAREST)
            pictures.append(cv2.resize(self.silhouette, (tw, th)))
        else:
            weights = cv2.resize(self._mask, (tw, th), interpolation=cv2.INTER_NEAREST)
        return weights * weights, pictures

    def _template_candidates(self, bounds, prob, global_search: bool) -> list[_Candidate]:
        left, top, right, bottom = bounds
        search = self._image[top:bottom, left:right].astype(np.float32)
        w, h = self._size
        out = []
        tried = set()
        oh, ow = self.original.shape
        # Near the prediction the object is about the size it just was. Anywhere else it
        # can be any size it can take (see _update), so the sizes are the selected one's;
        # a much smaller picture matches any patch of texture.
        if global_search:
            sizes = [(ow * scale, oh * scale) for scale in GLOBAL_SCALES]
        else:
            sizes = [(w * scale, h * scale) for scale in LOCAL_SCALES]
        for sw, sh in sizes:
            tw = max(8, round(float(np.clip(sw, 0.5 * ow, 2.0 * ow))))
            th = max(8, round(float(np.clip(sh, 0.5 * oh, 2.0 * oh))))
            if (tw, th) in tried:
                continue
            tried.add((tw, th))
            if search.shape[0] < th or search.shape[1] < tw:
                continue
            weights, references = self._references(tw, th)
            scores = np.nan_to_num(weighted_scores(search, references, weights), nan=-1.0, posinf=-1.0, neginf=-1.0)
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
            cx, cy = centroids[i] + 0.5  # from pixel indices to continuous, like the picture matches
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
        region = self._image[y0:y1, x0:x1].astype(np.float32)
        weights, references = self._references(w, h)
        return float(np.nan_to_num(weighted_scores(region, references, weights), nan=-1.0).max())

    def _update(self, frame: PreprocessedFrame, best: _Candidate, dt: float, recovered: bool) -> None:
        """Move to the match. After a recovery from the whole frame, nothing about how the
        object got there is known, so the motion starts over and its size is taken as found."""
        cx, cy = best.cx, best.cy
        if dt > 0 and not recovered:
            vx, vy = (cx - self._center[0]) / dt, (cy - self._center[1]) / dt
            # Follow changes in speed quickly (a falling ball), but not frame-to-frame jitter.
            self._velocity = (0.4 * self._velocity[0] + 0.6 * vx, 0.4 * self._velocity[1] + 0.6 * vy)
            self._velocity_known = True
        elif 0 < dt <= RECENT_FIX_S:
            # Found again by the whole-frame search soon after the last fix: usually it simply
            # moved further than the search reached. Where it went since then is its speed, so
            # the next frame looks ahead of it instead of starting from rest again.
            self._velocity = ((cx - self._center[0]) / dt, (cy - self._center[1]) / dt)
            self._velocity_known = True
        else:
            self._velocity = (0.0, 0.0)
            self._velocity_known = False
        oh, ow = self.original.shape
        blend = 1.0 if recovered else 0.3
        w = float(np.clip((1 - blend) * self._size[0] + blend * best.w, 0.5 * ow, 2.0 * ow))
        h = float(np.clip((1 - blend) * self._size[1] + blend * best.h, 0.5 * oh, 2.0 * oh))
        self._center, self._size, self._time = (cx, cy), (w, h), frame.timestamp
        fw, fh = frame.size
        x = int(round(min(max(cx - w / 2, 0), fw - w)))
        y = int(round(min(max(cy - h / 2, 0), fh - h)))
        self.bbox = (x, y, int(round(w)), int(round(h)))
        # Learn the current look only from a confident, clearly visible match that follows
        # on from the last one: a recovery may be a lookalike, and learning it would make
        # the mistake stick.
        if not recovered and best.appearance >= 0.55 and (self.color_model is None or best.color >= 0.5):
            patch = self._image[y:y + self.bbox[3], x:x + self.bbox[2]]
            if patch.shape[0] >= 4 and patch.shape[1] >= 4:
                th, tw = self.template.shape
                self.template = 0.8 * self.template + 0.2 * cv2.resize(patch.astype(np.float32), (tw, th))


def _color_model(frame: PreprocessedFrame, x: int, y: int, w: int, h: int,
                 mask: np.ndarray | None = None) -> tuple[np.ndarray | None, int]:
    """How likely each hue-saturation bin is to be the object rather than the rest of the
    picture, and the hue shift it was binned with. The model is None when the object's
    colour does not set it apart (grey objects, or colours that are all over the
    background). `mask` marks the object's pixels in the box; without one, the middle of
    the box is taken to be the object."""
    if mask is None:
        core = np.zeros((h, w), np.uint8)
        cv2.ellipse(core, (w // 2, h // 2), (max(1, w * 2 // 5), max(1, h * 2 // 5)), 0, 0, 360, 255, -1)
    else:
        core = (mask > 0).astype(np.uint8) * 255
    # Hue means little on a grey, white or black object, and JPEG bleeds the colour of a
    # logo into the grey around it; such objects are followed by their picture and outline.
    if float(np.median(frame.hsv[y:y + h, x:x + w, 1][core > 0])) < MIN_SATURATION:
        return None, 0
    hue = frame.hsv[y:y + h, x:x + w, 0][core > 0]
    shift = RED_HUE_SHIFT if float(np.mean((hue < 10) | (hue >= 170))) >= 0.5 else 0
    hsv = _model_hsv(frame, shift)
    # Everything but the object counts against it, including fingers beside it in the box.
    outside = np.full(hsv.shape[:2], 255, np.uint8)
    outside[y:y + h, x:x + w][core > 0] = 0
    obj = cv2.calcHist([hsv[y:y + h, x:x + w]], HIST_CHANNELS, core, HIST_BINS, HIST_RANGES)
    rest = cv2.calcHist([hsv], HIST_CHANNELS, outside, HIST_BINS, HIST_RANGES)
    # Spread along saturation only, by about 50 of 255 each way: light and motion blur
    # change saturation (a ball selected mid-throw is washed out by its surroundings and
    # sharper once it slows down), but hue is what tells a red ball from a skin-coloured hand.
    obj = cv2.GaussianBlur(obj / max(float(obj.sum()), 1.0), (7, 1), 0)
    rest = cv2.GaussianBlur(rest / max(float(rest.sum()), 1.0), (7, 1), 0)
    # The floor stands in for colours not in this picture yet (a hand that reaches in
    # later): a colour the object barely has must not count as the object.
    model = (obj / (obj + rest + COLOR_FLOOR)).astype(np.float32)
    prob = _back_project(frame, model, (0, 0) + frame.size, shift)
    # Most of the object has to be that colour: a grey ball with a coloured logo is grey,
    # and a model of the logo alone loses the ball as soon as it turns.
    inside = float(np.median(prob[y:y + h, x:x + w][core > 0]))
    pad = max(w, h) // 2 + 4
    ring = np.zeros(prob.shape, np.uint8)
    ring[max(0, y - pad):y + h + pad, max(0, x - pad):x + w + pad] = 1
    ring[y:y + h, x:x + w] = 0
    around = float(prob[ring > 0].mean()) if ring.any() else 0.0
    if inside < 0.5 or inside - around < 0.3:
        return None, 0
    return model, shift


def _ellipse_mask(w: int, h: int) -> np.ndarray:
    """The ellipse inside a w x h box. Matching only inside it keeps the background in the
    corners of the selection from pulling the match off the object as it moves."""
    mask = np.zeros((h, w), np.float32)
    cv2.ellipse(mask, (w // 2, h // 2), (max(1, round(w * 0.47)), max(1, round(h * 0.47))), 0, 0, 360, 1.0, -1)
    return mask


def _model_hsv(frame: PreprocessedFrame, shift: int) -> np.ndarray:
    """frame.hsv with hue turned by `shift`, computed once per frame."""
    if not shift:
        return frame.hsv
    if "_red_hsv" not in frame.__dict__:
        hsv = frame.hsv.copy()
        hue = hsv[:, :, 0].astype(np.uint16) + shift
        hsv[:, :, 0] = np.where(hue >= 180, hue - 180, hue).astype(np.uint8)
        frame.__dict__["_red_hsv"] = hsv
    return frame.__dict__["_red_hsv"]


def _back_project(frame: PreprocessedFrame, model: np.ndarray, bounds, shift: int = 0) -> np.ndarray:
    left, top, right, bottom = bounds
    hsv = _model_hsv(frame, shift)[top:bottom, left:right]
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
