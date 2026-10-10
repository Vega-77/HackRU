import cv2
import numpy as np
import pytest

from cv_engine.pipeline import PipelineConfig, TrackingPipeline
from cv_engine.preprocess import preprocess_frame


def frame(x, frame_id):
    img = np.full((720, 1280, 3), 90, np.uint8)
    cv2.circle(img, (x, 400), 40, (0, 0, 255), -1)
    return preprocess_frame(img, frame_id=frame_id, timestamp=frame_id / 30)


def test_reports_tracks_in_source_pixels_and_normalized():
    pipe = TrackingPipeline()
    assert pipe(frame(300, 0))["objects"] == []  # not confirmed yet (min_hits=2)
    objs = pipe(frame(320, 1))["objects"]
    assert len(objs) == 1
    o = objs[0]
    assert o["label"] == "red" and o["id"] == 1
    assert o["pixel"] == pytest.approx({"x": 320, "y": 400}, abs=2)
    assert o["pixel_norm"] == pytest.approx({"x": 0.25, "y": 0.5556}, abs=0.005)
    assert o["bbox"]["w"] == pytest.approx(80, abs=5)
    assert o["position"] is None  # no calibration yet


def test_config_validation_and_update():
    cfg = PipelineConfig()
    assert cfg.updated({"colors": ["blue"]}).colors == ["blue"]
    with pytest.raises(ValueError):
        cfg.updated({"detector": "magic"})
    with pytest.raises(ValueError):
        cfg.updated({"nope": 1})


def test_failed_reconfigure_keeps_old_setup():
    pipe = TrackingPipeline()
    with pytest.raises(ValueError):
        pipe.configure(PipelineConfig(colors=["chartreuse"]))
    assert pipe.config.colors == PipelineConfig().colors


def test_mediapipe_mode_switch():
    pipe = TrackingPipeline(PipelineConfig(detector="both"))
    assert pipe._mediapipe is not None
    pipe.configure(pipe.config.updated({"detector": "color"}))
    assert pipe._mediapipe is None


def scene(frame_id, ball_x=None, ball_bgr=(255, 0, 0), static=()):
    """Gray table with still objects (center, bgr) and an optional moving ball."""
    img = np.full((720, 1280, 3), 90, np.uint8)
    for center, bgr in static:
        cv2.circle(img, center, 40, bgr, -1)
    if ball_x is not None:
        cv2.circle(img, (ball_x, 400), 40, ball_bgr, -1)
    return preprocess_frame(img, frame_id=frame_id, timestamp=frame_id / 30)


def test_auto_target_follows_the_moving_ball_not_a_still_red_object():
    pipe = TrackingPipeline()
    for i in range(20):
        out = pipe(scene(i, ball_x=200 + 30 * i, static=[((1100, 150), (0, 0, 255))]))
    (target,) = [o for o in out["objects"] if o["target"]]
    assert target["label"] == "blue"


def test_auto_target_switches_when_another_object_starts_moving():
    pipe = TrackingPipeline()
    still = [((1100, 150), (0, 200, 0))]
    for i in range(5):  # nothing moves yet: some object is picked
        pipe(scene(i, ball_x=200, static=still))
    for i in range(5, 25):
        out = pipe(scene(i, ball_x=200 + 30 * (i - 5), static=still))
    (target,) = [o for o in out["objects"] if o["target"]]
    assert target["label"] == "blue"


def test_motion_mode_tracks_an_orange_ball_the_color_detector_misses():
    pipe = TrackingPipeline(PipelineConfig(detector="motion"))
    xs = []
    for i in range(25):
        x = 200 + 30 * i if i >= 5 else None  # empty table first, then the ball rolls in
        out = pipe(scene(i, ball_x=x, ball_bgr=(0, 120, 255)))
        xs += [o["pixel"]["x"] for o in out["objects"] if o["target"]]
    assert out["tracked"] and len(xs) >= 15
    assert xs[-1] == pytest.approx(200 + 30 * 24, abs=3)
    assert TrackingPipeline().color.detect(scene(0, ball_x=600, ball_bgr=(0, 120, 255))) == []
