import cv2
import numpy as np
import pytest

from cv_engine.detect import ColorDetector, MediaPipeDetector
from cv_engine.preprocess import preprocess_frame


def scene(balls, w=1280, h=720):
    """balls: list of ((x, y), radius, bgr) drawn on a gray table."""
    img = np.full((h, w, 3), 90, np.uint8)
    for center, r, color in balls:
        cv2.circle(img, center, r, color, -1)
    return preprocess_frame(img, frame_id=0, timestamp=0.0)


def test_finds_each_color_with_centroid_and_box():
    pf = scene([((300, 300), 40, (0, 0, 255)), ((900, 500), 50, (255, 0, 0)), ((600, 150), 30, (0, 200, 0))])
    dets = {d.label: d for d in ColorDetector(["red", "blue", "green"]).detect(pf)}
    assert set(dets) == {"red", "blue", "green"}
    # Working frame is half size, so (300, 300) in the source is (150, 150) here.
    assert dets["red"].centroid == pytest.approx((150, 150), abs=1)
    assert dets["blue"].centroid == pytest.approx((450, 250), abs=1)
    x, y, w, h = dets["blue"].bbox
    assert w == pytest.approx(50, abs=3) and h == pytest.approx(50, abs=3)
    assert all(d.source == "color" and d.score > 0.9 for d in dets.values())


def test_red_on_both_sides_of_hue_wrap():
    # Pure red (H~0) and crimson/magenta-red (H~175) should both count as red.
    pf = scene([((300, 300), 40, (0, 0, 255)), ((900, 300), 40, (60, 0, 230))])
    assert len([d for d in ColorDetector(["red"]).detect(pf) if d.label == "red"]) == 2


def test_ignores_small_noise_and_gray():
    pf = scene([((300, 300), 4, (0, 0, 255))])
    assert ColorDetector().detect(pf) == []


def test_unknown_color_rejected():
    with pytest.raises(ValueError):
        ColorDetector(["chartreuse"])


def test_mediapipe_detector_runs():
    det = MediaPipeDetector()
    try:
        assert det.detect(scene([])) == []
    finally:
        det.close()
