import cv2
import numpy as np
import pytest

from cv_engine.detect import ColorDetector, MediaPipeDetector, MotionDetector
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


def table(balls=(), w=1280, h=720, frame_id=0):
    """Like scene(), on a textured table so the background model has some noise to learn."""
    rng = np.random.default_rng(frame_id)
    img = np.clip(np.full((h, w, 3), 110, np.int16) + rng.integers(-6, 7, (h, w, 3)), 0, 255).astype(np.uint8)
    for center, r, color in balls:
        cv2.circle(img, center, r, color, -1)
    return preprocess_frame(img, frame_id=frame_id, timestamp=frame_id / 30)


@pytest.mark.parametrize("bgr", [(0, 0, 255), (0, 120, 255), (240, 240, 240), (25, 25, 25), (180, 105, 255)])
def test_motion_detector_finds_a_ball_of_any_color(bgr):
    det = MotionDetector()
    for i in range(10):
        det.detect(table(frame_id=i))  # learn the empty table
    (d,) = det.detect(table([((700, 400), 40, bgr)], frame_id=10))
    assert d.label == "object" and d.source == "motion"
    assert d.centroid == pytest.approx((350, 200), abs=2)
    x, y, w, h = d.bbox
    assert w == pytest.approx(40, abs=4) and h == pytest.approx(40, abs=4)


def test_motion_detector_ignores_the_still_background():
    det = MotionDetector()
    for i in range(10):
        dets = det.detect(table([((300, 300), 40, (0, 0, 255))], frame_id=i))
    assert dets == []


def test_motion_detector_relearns_when_the_camera_moves():
    det = MotionDetector()
    for i in range(10):
        det.detect(table(frame_id=i))
    shifted = np.full((720, 1280, 3), 200, np.uint8)  # whole view changed at once
    assert det.detect(preprocess_frame(shifted, frame_id=10, timestamp=1)) == []
    assert det.detect(preprocess_frame(shifted, frame_id=11, timestamp=1.1)) == []


def test_motion_detector_ignores_handheld_wobble():
    rng = np.random.default_rng(1)
    board = np.full((800, 1400, 3), 200, np.uint8)
    for _ in range(150):  # printed clutter for the aligner to lock onto
        x, y = int(rng.integers(0, 1350)), int(rng.integers(0, 750))
        cv2.rectangle(board, (x, y), (x + 30, y + 30), tuple(int(v) for v in rng.integers(0, 120, 3)), -1)
    det = MotionDetector()
    for i in range(12):
        dx, dy = int(rng.integers(0, 12)), int(rng.integers(0, 12))  # the phone wobbles a few px
        img = board[dy : dy + 720, dx : dx + 1280].copy()
        if i == 11:
            cv2.circle(img, (640, 360), 40, (0, 200, 0), -1)
        dets = det.detect(preprocess_frame(img, frame_id=i, timestamp=i / 30))
        if i < 11:
            assert dets == [], f"frame {i}: wobble reported as motion"
    (d,) = dets
    assert d.centroid == pytest.approx((320, 180), abs=2)


def test_motion_detector_keeps_a_released_ball_apart_from_where_it_sat():
    det = MotionDetector()
    for i in range(10):  # the ball rests at x=300 while the background is learned
        det.detect(table([((300, 400), 40, (0, 0, 255))], frame_id=i))
    for step in range(1, 5):
        x = 300 + 30 * step  # rolls off, still overlapping the spot it left at first
        (d,) = det.detect(table([((x, 400), 40, (0, 0, 255))], frame_id=10 + step))
        assert d.centroid == pytest.approx((x / 2, 200), abs=1.5)


@pytest.mark.parametrize("gray", [30, 60, 128, 190, 235])
def test_motion_detector_finds_gray_balls_on_a_gray_table(gray):
    det = MotionDetector()
    for i in range(10):
        det.detect(table(frame_id=i))  # table is mid gray (110)
    (d,) = det.detect(table([((700, 400), 40, (gray, gray, gray))], frame_id=10))
    assert d.centroid == pytest.approx((350, 200), abs=2)
