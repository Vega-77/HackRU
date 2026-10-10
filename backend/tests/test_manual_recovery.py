import cv2
import numpy as np
import pytest

from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import preprocess_frame


def scene(points=(), brightness=90):
    image = np.full((180, 320, 3), brightness, np.uint8)
    for x, y, color in points:
        cv2.circle(image, (x, y), 12, color, -1)
    return image


def selected(color=(180, 180, 180)):
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "target_px": {"x": 80, "y": 90},
                       "target_bbox": {"x": 64, "y": 74, "w": 32, "h": 32},
                       "frame_size": {"w": 320, "h": 180}, "debug_tracking": True})
    first = pipe(preprocess_frame(scene([(80, 90, color)]), 0, 0.0))
    assert not first["tracked"]
    assert first["tracking_status"] == "initialized"
    assert pipe(preprocess_frame(scene([(80, 90, color)]), 1, .2))["tracked"]
    return pipe


@pytest.mark.parametrize("position", [(250, 90), (80, 145)])
def test_recovery_after_occlusion_and_motion_uses_original_identity(position):
    pipe = selected()
    original = pipe._manual.original.copy()
    for i in range(2, 15):
        assert not pipe(preprocess_frame(scene(), i, i * .2))["tracked"]
    x, y = position
    recovered = pipe(preprocess_frame(scene([(x, y, (180, 180, 180))]), 15, 3.0))
    assert recovered["tracked"]
    target = next(o for o in recovered["objects"] if o["target"])
    assert target["pixel"] == pytest.approx({"x": x, "y": y}, abs=2)
    assert recovered["tracking_debug"]["global"]
    np.testing.assert_array_equal(original, pipe._manual.original)


def test_jump_beyond_search_window_recovers_without_retapping():
    pipe = selected()
    result = pipe(preprocess_frame(scene([(250, 90, (180, 180, 180))]), 2, .9))
    assert result["tracked"]
    assert result["tracking_debug"]["global"]


def test_exposure_change_preserves_stationary_object():
    pipe = selected()
    for i in range(2, 8):
        result = pipe(preprocess_frame(scene([(80, 90, (220, 220, 220))], 130), i, i / 5))
        assert result["tracked"]
        assert next(o for o in result["objects"] if o["target"])["pixel"]["x"] == pytest.approx(80, abs=2)


def test_different_color_distractor_does_not_replace_red_target():
    pipe = selected((0, 0, 255))
    result = pipe(preprocess_frame(scene([(80, 90, (255, 0, 0))]), 2, .4))
    assert not result["tracked"]


def test_ambiguous_global_recovery_stays_lost():
    pipe = selected()
    assert not pipe(preprocess_frame(scene(), 2, .4))["tracked"]
    result = pipe(preprocess_frame(scene([(80, 90, (180, 180, 180)),
                                          (250, 90, (180, 180, 180))]), 3, .6))
    assert not result["tracked"]
    assert result["tracking_debug"]["reason"] == "ambiguous_match"


def test_tap_on_textured_background_does_not_initialize_a_target():
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "target_px": {"x": 182, "y": 97}})
    image = np.random.default_rng(123).integers(30, 220, (180, 320), dtype=np.uint8)
    image = cv2.cvtColor(image, cv2.COLOR_GRAY2BGR)
    for i in range(3):
        result = pipe(preprocess_frame(image, i, i * .2))
        assert not result["tracked"]
        assert result["tracking_status"] == "selection_required"


def test_diagnostics_are_opt_in_and_contain_no_image_data():
    pipe = TrackingPipeline()
    result = pipe(preprocess_frame(scene(), 0))
    assert "tracking_debug" not in result
    pipe = selected()
    result = pipe(preprocess_frame(scene(), 2, .4))
    assert set(result["tracking_debug"]) <= {
        "frame_id", "timestamp", "detections", "reason", "search", "global",
        "score", "candidates", "missed", "bbox",
    }
