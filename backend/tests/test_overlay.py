import numpy as np

from cv_engine.overlay import TrailHistory, draw_overlay
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import preprocess_frame
from scenes import BOARD_H, BOARD_W, board_image, camera_view


def test_overlay_draws_on_a_copy():
    view, _ = camera_view(board_image(ball_world=(0.2, 0.1))[0])
    pipe = TrackingPipeline()
    pipe.calibrate({"method": "aruco", "width_m": BOARD_W, "height_m": BOARD_H})
    trails = TrailHistory()
    for i in range(3):
        result = pipe(preprocess_frame(view, i, 0.0))
        out = draw_overlay(view, result, trails.update(result["objects"]))
    assert out.shape == view.shape
    assert not np.array_equal(out, view)
    assert np.array_equal(view, camera_view(board_image(ball_world=(0.2, 0.1))[0])[0])  # input untouched


def test_overlay_handles_empty_result():
    img = np.zeros((100, 200, 3), np.uint8)
    assert draw_overlay(img, {}).shape == img.shape


def test_trails_grow_and_are_forgotten():
    th = TrailHistory(length=3, forget_after=2)
    for x in range(5):
        trails = th.update([{"id": 1, "centroid": [x, 0]}])
    assert list(trails[1]) == [(2, 0), (3, 0), (4, 0)]
    for _ in range(3):
        trails = th.update([])
    assert 1 not in trails
