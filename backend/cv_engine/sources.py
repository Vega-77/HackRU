"""Local frame sources (webcam or video file) for testing without the iOS app."""

from __future__ import annotations

import time
from collections.abc import Iterator

import cv2
import numpy as np


def open_capture(source: str | int) -> cv2.VideoCapture:
    """Open a webcam index ("0", 0) or a video file path."""
    if isinstance(source, str) and source.isdigit():
        source = int(source)
    cap = cv2.VideoCapture(source)
    if not cap.isOpened():
        raise RuntimeError(f"could not open video source {source!r}")
    return cap


def iter_frames(
    source: str | int, max_fps: float | None = None, loop: bool = False
) -> Iterator[tuple[float, np.ndarray]]:
    """Yield (timestamp, BGR frame) pairs, optionally throttled to `max_fps`.

    `loop=True` restarts a video file when it ends, which is handy for soak tests.
    """
    cap = open_capture(source)
    min_interval = 1.0 / max_fps if max_fps else 0.0
    last = 0.0
    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                if loop and cap.set(cv2.CAP_PROP_POS_FRAMES, 0):
                    continue
                return
            now = time.time()
            wait = min_interval - (now - last)
            if wait > 0:
                time.sleep(wait)
                now = time.time()
            last = now
            yield now, frame
    finally:
        cap.release()
