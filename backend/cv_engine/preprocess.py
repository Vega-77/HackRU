"""Frame preprocessing: decode, downsample to a fixed working size, convert color spaces.

Every frame that reaches the tracker goes through `preprocess_frame`, so later
stages can rely on a consistent resolution and on HSV/grayscale copies being
ready without converting again.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field

import cv2
import numpy as np

DEFAULT_WORKING_WIDTH = 640


@dataclass
class PreprocessedFrame:
    frame_id: int
    timestamp: float  # capture time from the client (seconds), or receive time if absent
    bgr: np.ndarray  # downsampled frame, BGR uint8
    hsv: np.ndarray  # same frame in HSV (OpenCV ranges: H 0-179, S/V 0-255)
    gray: np.ndarray  # same frame in grayscale
    scale: float  # working size / source size; divide working coords by this to get source pixels
    source_size: tuple[int, int]  # (width, height) of the frame as received
    meta: dict = field(default_factory=dict)  # client metadata passed through untouched

    @property
    def size(self) -> tuple[int, int]:
        h, w = self.bgr.shape[:2]
        return w, h

    def to_source_coords(self, x: float, y: float) -> tuple[float, float]:
        """Map a point in working-frame pixels back to the client's original pixels."""
        return x / self.scale, y / self.scale


def decode_jpeg(data: bytes) -> np.ndarray:
    """Decode JPEG/PNG bytes into a BGR image. Raises ValueError on bad input."""
    buf = np.frombuffer(data, dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError("could not decode image bytes")
    return img


def encode_jpeg(img: np.ndarray, quality: int = 70) -> bytes:
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if not ok:
        raise ValueError("could not encode image")
    return buf.tobytes()


def downsample(img: np.ndarray, max_width: int) -> tuple[np.ndarray, float]:
    """Shrink `img` so its width is at most `max_width`, keeping aspect ratio.

    Never upsamples. Returns the resized image and the scale factor applied.
    """
    h, w = img.shape[:2]
    if w <= max_width:
        return img, 1.0
    scale = max_width / w
    new_size = (max_width, max(1, round(h * scale)))
    return cv2.resize(img, new_size, interpolation=cv2.INTER_AREA), scale


def preprocess_frame(
    img: np.ndarray,
    frame_id: int,
    timestamp: float | None = None,
    working_width: int = DEFAULT_WORKING_WIDTH,
    blur_ksize: int = 5,
    meta: dict | None = None,
) -> PreprocessedFrame:
    """Downsample a BGR frame and produce the HSV and grayscale versions the tracker uses.

    A light Gaussian blur is applied before the HSV conversion to cut sensor noise,
    which makes color thresholding in the tracking stage much more stable.
    """
    h, w = img.shape[:2]
    small, scale = downsample(img, working_width)
    smoothed = cv2.GaussianBlur(small, (blur_ksize, blur_ksize), 0) if blur_ksize > 1 else small
    return PreprocessedFrame(
        frame_id=frame_id,
        timestamp=time.time() if timestamp is None else timestamp,
        bgr=small,
        hsv=cv2.cvtColor(smoothed, cv2.COLOR_BGR2HSV),
        gray=cv2.cvtColor(smoothed, cv2.COLOR_BGR2GRAY),
        scale=scale,
        source_size=(w, h),
        meta=meta or {},
    )
