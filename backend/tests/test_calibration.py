import cv2
import numpy as np
import pytest

from cv_engine.calibration import ArucoCalibrator, PlaneMapping, rectangle_world_points
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import encode_jpeg, preprocess_frame
from cv_engine.spatial import SpatialMapper
from scenes import BOARD_H, BOARD_W, board_image, camera_view


def test_four_point_mapping_round_trip():
    img = [[100, 50], [500, 80], [520, 400], [80, 380]]
    m = PlaneMapping.fit(img, rectangle_world_points(0.6, 0.4))
    assert m.image_to_world(img) == pytest.approx(rectangle_world_points(0.6, 0.4), abs=1e-6)
    pt = m.world_to_image([[0.3, 0.2]])
    assert m.image_to_world(pt) == pytest.approx(np.array([[0.3, 0.2]]), abs=1e-9)
    assert m.reprojection_error_px < 1e-3


def test_more_than_four_points_uses_least_squares():
    world = np.array([[0, 0], [1, 0], [1, 1], [0, 1], [0.5, 0.5]])
    img = world * 200 + 50
    m = PlaneMapping.fit(img, world)
    assert m.image_to_world([[150, 150]]) == pytest.approx(np.array([[0.5, 0.5]]), abs=1e-6)


def test_degenerate_points_rejected():
    with pytest.raises(ValueError):
        PlaneMapping.fit([[0, 0], [1, 1], [2, 2], [3, 3]], rectangle_world_points(1, 1))
    with pytest.raises(ValueError):
        PlaneMapping.fit([[0, 0], [1, 1], [2, 2]], [[0, 0], [1, 1], [2, 2]])


def test_aruco_markers_found_in_tilted_view():
    board, _ = board_image()
    view, _ = camera_view(board)
    pf = preprocess_frame(view, 0, 0.0)
    m = ArucoCalibrator(rectangle_world_points(BOARD_W, BOARD_H)).detect(pf.gray_sharp())
    assert m is not None and m.method == "aruco"
    assert m.reprojection_error_px < 1e-3  # exactly 4 points fit exactly


@pytest.mark.parametrize("ball", [(0.10, 0.08), (0.30, 0.15), (0.20, 0.20)])
def test_ball_world_position_from_aruco(ball):
    board, _ = board_image(ball_world=ball)
    view, _ = camera_view(board)
    pipe = TrackingPipeline()
    pipe.calibrate({"method": "aruco", "width_m": BOARD_W, "height_m": BOARD_H})
    for i in range(2):
        out = pipe(preprocess_frame(view, i, i / 30))
    assert out["calibration"]["status"] == "ok"
    (obj,) = [o for o in out["objects"] if o["label"] == "red"]
    # Within 5 mm of the truth despite the perspective tilt and 640 px processing.
    assert obj["position"] == pytest.approx({"x": ball[0], "y": ball[1]}, abs=0.005)
    assert obj["width_m"] == pytest.approx(0.04, abs=0.006)


def test_manual_calibration_in_client_and_normalized_pixels():
    board, to_px = board_image(ball_world=(0.25, 0.10))
    view, M = camera_view(board)
    corners_board = np.float32([to_px(*p) for p in rectangle_world_points(BOARD_W, BOARD_H)])
    corners_view = cv2.perspectiveTransform(corners_board.reshape(-1, 1, 2), M).reshape(-1, 2)

    for normalized in (False, True):
        pts = corners_view / [1280, 720] if normalized else corners_view
        pipe = TrackingPipeline()
        status = pipe.calibrate(
            {"method": "manual", "image_points": pts.tolist(), "normalized": normalized,
             "width_m": BOARD_W, "height_m": BOARD_H}
        )
        assert status["status"] == "ok"
        for i in range(2):
            out = pipe(preprocess_frame(view, i, 0.0))
        (obj,) = [o for o in out["objects"] if o["label"] == "red"]
        assert obj["position"] == pytest.approx({"x": 0.25, "y": 0.10}, abs=0.005)


def test_aruco_holds_briefly_then_reports_lost():
    board, _ = board_image()
    view, _ = camera_view(board)
    blank = np.full_like(view, 90)
    sm = SpatialMapper(aruco_hold_frames=2)
    sm.calibrate({"method": "aruco", "width_m": BOARD_W, "height_m": BOARD_H})
    assert sm.status()["status"] == "searching"
    sm.update(preprocess_frame(view, 0, 0.0))
    assert sm.status()["status"] == "ok"
    for expected in ("held", "held", "searching"):
        sm.update(preprocess_frame(blank, 1, 0.0))
        assert sm.status()["status"] == expected


def test_status_gives_world_to_image_for_overlays():
    board, _ = board_image()
    view, _ = camera_view(board)
    sm = SpatialMapper()
    sm.calibrate({"method": "aruco", "width_m": BOARD_W, "height_m": BOARD_H})
    sm.update(preprocess_frame(view, 0, 0.0))
    st = sm.status()
    H = np.array(st["world_to_image"])
    # The world origin is the bottom-left marker, the last image point (TL, TR, BR, BL order).
    p = H @ [0, 0, 1]
    assert p[:2] / p[2] == pytest.approx(st["image_points"][3], abs=0.01)


def test_bad_calibration_requests():
    sm = SpatialMapper()
    for req in ({"method": "magic"}, {"method": "aruco"}, {"method": "manual", "width_m": 1, "height_m": 1},
                {"method": "aruco", "width_m": -1, "height_m": 1}):
        with pytest.raises(ValueError):
            sm.calibrate(req)
    assert sm.method == "none"
