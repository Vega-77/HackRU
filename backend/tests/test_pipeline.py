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
    pipe = TrackingPipeline(PipelineConfig(detector="color"))
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
    pipe.configure(pipe.config.updated({"detector": "motion"}))
    assert pipe._mediapipe is None
