"""Object detection on preprocessed frames.

Three detectors share one output type:
  * MotionDetector - background subtraction (MOG2). Finds whatever moves against a still
                     background, whatever its color. Needs a steady camera.
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
    source: str  # "color", "motion" or "mediapipe"


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


MIN_ALIGN_FEATURES = 20


class MotionDetector:
    """Background subtraction: learns what the still scene looks like and reports blobs
    that differ from it, whatever their color. Stateful, so each connection needs its own.

    Handheld phones wobble, so every frame is first aligned to the frame the background was
    learned from (ORB features + a RANSAC homography) and subtraction runs in that fixed
    view; detections are mapped back to the current frame. If the view moves too far to
    align, the background is relearned from scratch.

    An object that stops moving fades into the background over roughly `history` frames.
    A ball that sat still while the background was learned leaves a "ghost" when it moves
    off; ghosts are dropped because their outline is an edge in the background model but
    not in the live frame.
    """

    def __init__(
        self,
        min_area: float = 80.0,
        max_results: int = 5,
        history: int = 300,
        var_threshold: float = 25.0,
        max_foreground: float = 0.4,
        stabilize: bool = True,
    ) -> None:
        """max_foreground: if more than this fraction of the view changes at once (the
        camera jumped, the lights changed), the background is relearned and nothing reported."""
        self.min_area = min_area
        self.max_results = max_results
        self.history = history
        self.var_threshold = var_threshold
        self.max_foreground = max_foreground
        self.stabilize = stabilize
        self._kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (5, 5))
        self._orb = cv2.ORB_create(nfeatures=800)
        self._matcher = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)
        self.reset()

    def reset(self) -> None:
        self._subtractor = cv2.createBackgroundSubtractorMOG2(
            history=self.history, varThreshold=self.var_threshold, detectShadows=False
        )
        # OpenCV's 0.9 lets a new color join the background once it holds 10% of the pixel's
        # weight, about 1 s at this learning rate: a cart that stops vanishes almost at once.
        # At 0.5 it takes about history * 0.7 frames.
        self._subtractor.setBackgroundRatio(0.5)
        self._frames = 0
        self._ref: tuple | None = None  # ORB keypoints + descriptors of the reference view

    def _align(self, frame: PreprocessedFrame) -> np.ndarray | None:
        """Homography mapping the current frame onto the reference view, or None if the
        two views don't share enough features. A reference view with too little texture to
        align against (a blank table) is assumed to be filmed from a steady camera."""
        kp, des = self._orb.detectAndCompute(frame.gray_sharp(), None)
        if self._ref is None:
            self._ref = (kp, des)
            return np.eye(3)
        ref_kp, ref_des = self._ref
        if ref_des is None or len(ref_kp) < MIN_ALIGN_FEATURES:
            return np.eye(3)
        if des is None or len(kp) < MIN_ALIGN_FEATURES:
            return None
        matches = self._matcher.match(des, ref_des)
        if len(matches) < MIN_ALIGN_FEATURES:
            return None
        src = np.float32([kp[m.queryIdx].pt for m in matches])
        dst = np.float32([ref_kp[m.trainIdx].pt for m in matches])
        H, inliers = cv2.findHomography(src, dst, cv2.RANSAC, 2.0)
        if H is None or int(inliers.sum()) < MIN_ALIGN_FEATURES:
            return None
        return H

    def _trim_to_objects(self, fg: np.ndarray, contours: list, view: np.ndarray) -> np.ndarray:
        """Drop foreground pixels that look like the surface right around their blob. When a
        ball rolls off the spot where it sat while the background was learned, the bare
        table it uncovers differs from the model too, and that "ghost" would otherwise
        merge with the ball and drag its centroid back toward where it started."""
        out = np.zeros_like(fg)
        h, w = fg.shape
        for c in contours:
            x, y, bw, bh = cv2.boundingRect(c)
            pad = 8
            x0, y0, x1, y1 = max(0, x - pad), max(0, y - pad), min(w, x + bw + pad), min(h, y + bh + pad)
            blob = np.zeros((y1 - y0, x1 - x0), np.uint8)
            cv2.drawContours(blob, [c - (x0, y0)], -1, 255, -1)
            ring = cv2.dilate(blob, self._kernel, iterations=2) & ~fg[y0:y1, x0:x1]
            patch = view[y0:y1, x0:x1].astype(np.float32)
            if np.count_nonzero(ring) < 10:
                out[y0:y1, x0:x1] |= blob
                continue
            surface = np.median(patch[ring > 0], axis=0)
            spread = np.median(np.linalg.norm(patch[ring > 0] - surface, axis=1))
            looks_like_surface = np.linalg.norm(patch - surface, axis=2) < max(12.0, 3 * spread)
            blob[looks_like_surface] = 0
            out[y0:y1, x0:x1] |= cv2.morphologyEx(blob, cv2.MORPH_OPEN, self._kernel)
        return out

    def detect(self, frame: PreprocessedFrame) -> list[Detection]:
        w, h = frame.size
        H = self._align(frame) if self.stabilize else np.eye(3)
        if H is None:
            log.debug("camera moved too far to align; relearning the background")
            self.reset()
            H = self._align(frame)
        first = self._frames == 0
        if first or not self.stabilize:
            view, valid = frame.bgr, None
        else:
            view = cv2.warpPerspective(frame.bgr, H, (w, h), borderMode=cv2.BORDER_REPLICATE)
            valid = cv2.warpPerspective(np.full((h, w), 255, np.uint8), H, (w, h))
            valid = cv2.erode(valid, self._kernel, iterations=2)

        # A fixed learning rate (OpenCV's default starts near 1 and decays) so a ball that
        # stops for a moment early in a session is not absorbed into the background at once.
        view = cv2.GaussianBlur(view, (5, 5), 0)
        fg = self._subtractor.apply(view, learningRate=1.0 if first else 1.0 / self.history)
        self._frames += 1
        if first:
            return []  # the first frame only seeds the background model
        # Shadow detection is off: with it on, MOG2 files any darker gray object under "shadow"
        # (no color to tell it apart from a shadowed table), so dark gray balls vanished.
        _, fg = cv2.threshold(fg, 254, 255, cv2.THRESH_BINARY)
        if valid is not None:
            fg &= valid  # parts of the view the reference frame never saw
        fg = cv2.morphologyEx(fg, cv2.MORPH_OPEN, self._kernel)
        fg = cv2.morphologyEx(fg, cv2.MORPH_CLOSE, self._kernel, iterations=2)
        if np.count_nonzero(fg) > self.max_foreground * fg.size:
            log.debug("most of the view changed; relearning the background")
            self.reset()
            return []

        contours, _ = cv2.findContours(fg, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        contours = [c for c in contours if cv2.contourArea(c) >= self.min_area]
        if contours:
            fg = self._trim_to_objects(fg, contours, view)
            contours, _ = cv2.findContours(fg, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
            contours = [c for c in contours if cv2.contourArea(c) >= self.min_area]
        if not contours:
            return []
        view_gray = cv2.cvtColor(view, cv2.COLOR_BGR2GRAY)
        bg_gray = cv2.GaussianBlur(cv2.cvtColor(self._subtractor.getBackgroundImage(), cv2.COLOR_BGR2GRAY), (5, 5), 0)
        to_frame = np.linalg.inv(H)
        found = []
        for c in contours:
            if _is_ghost(c, view_gray, bg_gray):
                continue
            # Back to current-frame pixels; a pure translation for a steady camera.
            c_frame = cv2.perspectiveTransform(c.astype(np.float32), to_frame)
            area = cv2.contourArea(c_frame)
            m = cv2.moments(c_frame)
            if m["m00"] == 0:
                continue
            cx, cy = m["m10"] / m["m00"], m["m01"] / m["m00"]
            x, y, bw, bh = cv2.boundingRect(c_frame)
            hull_area = cv2.contourArea(cv2.convexHull(c_frame)) or area
            found.append(Detection("object", (cx, cy), (x, y, bw, bh), area, min(1.0, area / hull_area), "motion"))
        found.sort(key=lambda d: d.area, reverse=True)
        return found[: self.max_results]


def _is_ghost(contour: np.ndarray, view_gray: np.ndarray, bg_gray: np.ndarray) -> bool:
    """True if the blob's outline is an edge in the background model but not in the live
    view: the hole an object leaves where it sat while the background was learned."""
    x, y, w, h = cv2.boundingRect(contour)
    pad = 4
    x0, y0 = max(0, x - pad), max(0, y - pad)
    x1, y1 = min(view_gray.shape[1], x + w + pad), min(view_gray.shape[0], y + h + pad)
    pts = contour[:, 0, :] - (x0, y0)
    here = _gradient(view_gray[y0:y1, x0:x1])[pts[:, 1], pts[:, 0]].mean()
    there = _gradient(bg_gray[y0:y1, x0:x1])[pts[:, 1], pts[:, 0]].mean()
    return here < 0.5 * there


def _gradient(gray: np.ndarray) -> np.ndarray:
    gx = cv2.Sobel(gray, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(gray, cv2.CV_32F, 0, 1, ksize=3)
    # Widen edges a little: contours sit on the mask boundary, which can be a pixel or
    # two off the true edge after the morphology.
    return cv2.dilate(cv2.magnitude(gx, gy), np.ones((5, 5), np.uint8))


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
