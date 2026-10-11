import math

import cv2
import numpy as np
import pytest

from cv_engine.ar_plane import ArPlane, CameraPose
from cv_engine.pipeline import PipelineConfig, TrackingPipeline, validated_session, SESSION_DEFAULTS
from cv_engine.preprocess import preprocess_frame
from cv_engine.surfaces import ar_surfaces

PX_PER_M = 1000.0
W, H = 640, 480


def ramp_image(angle_deg: float, s: float = 0.25, r_px: int = 20) -> tuple[np.ndarray, tuple[float, float]]:
    """A red ball resting on a dark ramp line, on a light background. Returns the image
    and the ball centre in pixels."""
    img = np.full((H, W, 3), 225, np.uint8)
    theta = math.radians(angle_deg)
    foot = np.array([60.0, 420.0])
    up = np.array([math.cos(theta), -math.sin(theta)])  # along the ramp, image y down
    normal = np.array([-math.sin(theta), -math.cos(theta)])  # away from the ramp, upwards
    top = foot + up * 560
    cv2.line(img, tuple(map(int, foot)), tuple(map(int, top)), (60, 60, 60), 4, cv2.LINE_AA)
    centre = foot + up * (s * PX_PER_M) + normal * (r_px + 2)
    cv2.circle(img, tuple(map(int, np.round(centre))), r_px, (0, 0, 230), -1, cv2.LINE_AA)
    return img, (float(centre[0]), float(centre[1]))


def pipeline(**session) -> TrackingPipeline:
    pipe = TrackingPipeline(PipelineConfig(detector="color", min_hits=1))
    pipe.apply_config({"type": "config", "px_per_m": PX_PER_M, "frame_size": {"w": W, "h": H}, **session})
    return pipe


@pytest.mark.parametrize("angle", [0.0, 20.0, 35.0])
def test_edge_under_a_ball_is_found_with_its_slope(angle):
    img, _ = ramp_image(angle)
    pipe = pipeline(mode="ramp")
    for k in range(3):
        result = pipe(preprocess_frame(img, k, k / 30))
    (target,) = [o for o in result["objects"] if o["target"]]
    (edge,) = target["surfaces"]
    nx, ny, nz = edge["normal"]
    # The normal is perpendicular to the ramp (either way round: physics turns it to face the ball).
    assert abs(nx * math.cos(math.radians(angle)) + ny * math.sin(math.radians(angle))) < 0.06
    assert nz == 0.0
    offset = np.subtract([target["position"]["x"], target["position"]["y"]], edge["point"][:2])
    assert abs(abs(offset @ [nx, ny]) - target["width_m"] / 2) < 0.006


def test_no_edges_for_a_pendulum_or_a_table_seen_from_above():
    img, _ = ramp_image(20.0)
    for session in ({"mode": "pendulum"}, {"mode": "ramp", "view": "top"}):
        pipe = pipeline(**session)
        for k in range(3):
            result = pipe(preprocess_frame(img, k, k / 30))
        assert all("surfaces" not in o for o in result["objects"])


def test_tapped_surface_edge_maps_onto_the_plane():
    pipe = pipeline(mode="free_fall", surface_px=[{"a": {"x": 0, "y": 400}, "b": {"x": 600, "y": 400}}])
    img = np.full((H, W, 3), 225, np.uint8)
    result = pipe(preprocess_frame(img, 0, 0.0))
    (tap,) = result["surfaces"]
    assert tap["source"] == "tap"
    assert tap["point"][1] == pytest.approx((H - 400) / PX_PER_M, abs=1e-3)
    assert abs(tap["normal"][1]) == pytest.approx(1.0, abs=1e-6)


def test_bad_surface_settings_are_rejected():
    with pytest.raises(ValueError, match="surface_px"):
        validated_session(SESSION_DEFAULTS, {"surface_px": [{"a": {"x": 0}}]})
    with pytest.raises(ValueError, match="ar_surfaces"):
        validated_session(SESSION_DEFAULTS, {"ar_surfaces": [{"point": [0, 0], "normal": [0, 1, 0]}]})
    with pytest.raises(ValueError, match="view"):
        validated_session(SESSION_DEFAULTS, {"view": "diagonal"})


def test_arkit_floor_under_a_vertical_board_becomes_a_line_on_the_board():
    # A board standing at z = -1 facing the camera, the floor at y = -0.5.
    plane = ArPlane([0.0, 0.0, -1.0], [0.0, 0.0, 1.0])
    meta = {"intrinsics": {"fx": 500, "fy": 500, "cx": 320, "cy": 240},
            "camera_to_world": np.eye(4).reshape(-1).tolist()}
    plane.fix_basis(CameraPose.from_meta(meta))
    floors = ar_surfaces(plane, [
        {"id": "floor", "point": [0.3, -0.5, -0.4], "normal": [0.0, 1.0, 0.0]},
        {"id": "board", "point": [0.2, 0.1, -1.0], "normal": [0.0, 0.0, 1.0]},  # the board itself
    ])
    (floor,) = floors
    assert floor["id"] == "ar:floor"
    assert floor["normal"] == pytest.approx([0.0, 1.0, 0.0])
    assert floor["point"][1] == pytest.approx(-0.5)
