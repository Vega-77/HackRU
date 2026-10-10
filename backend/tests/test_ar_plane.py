import math

import cv2
import numpy as np
import pytest

from cv_engine.ar_plane import ArPlane, CameraPose, image_axes
from cv_engine.pipeline import PipelineConfig, TrackingPipeline
from cv_engine.preprocess import preprocess_frame

FX, CX, CY = 500.0, 320.0, 240.0
INTRINSICS = {"fx": FX, "fy": FX, "cx": CX, "cy": CY}


def yaw_pitch(yaw_deg=0.0, pitch_deg=0.0):
    """ARKit camera rotation: yaw about world +Y, then pitch about the camera's +X."""
    y, p = math.radians(yaw_deg), math.radians(pitch_deg)
    Ry = np.array([[math.cos(y), 0, math.sin(y)], [0, 1, 0], [-math.sin(y), 0, math.cos(y)]])
    Rx = np.array([[1, 0, 0], [0, math.cos(p), -math.sin(p)], [0, math.sin(p), math.cos(p)]])
    return Ry @ Rx


def pose_meta(position, rotation=None):
    M = np.eye(4)
    M[:3, :3] = np.eye(3) if rotation is None else rotation
    M[:3, 3] = position
    return {"intrinsics": dict(INTRINSICS), "camera_to_world": M.reshape(-1).tolist()}


def project(meta, world_point):
    """Where an ARKit camera sees a world point, in image pixels (y down)."""
    M = np.asarray(meta["camera_to_world"]).reshape(4, 4)
    X, Y, Z = M[:3, :3].T @ (np.asarray(world_point, float) - M[:3, 3])
    assert Z < 0, "point is behind the camera"
    return CX + FX * X / -Z, CY - FX * Y / -Z


def test_pose_parsing():
    assert CameraPose.from_meta({}) is None
    pose = CameraPose.from_meta(pose_meta([0, 0, 1]))
    assert pose.position == pytest.approx([0, 0, 1])
    with pytest.raises(ValueError):
        CameraPose.from_meta({"intrinsics": INTRINSICS})
    with pytest.raises(ValueError):
        CameraPose.from_meta({**pose_meta([0, 0, 1]), "camera_to_world": [2.0] * 16})
    with pytest.raises(ValueError):
        CameraPose.from_meta({**pose_meta([0, 0, 1]), "intrinsics": {**INTRINSICS, "fx": -1}})


def test_pixel_ray_points_through_the_pixel():
    meta = pose_meta([0.1, 0.2, 0.9], yaw_pitch(20, -10))
    pose = CameraPose.from_meta(meta)
    target = np.array([0.3, 0.1, 0.0])
    origin, direction = pose.pixel_ray(*project(meta, target))
    to_target = (target - origin) / np.linalg.norm(target - origin)
    assert direction == pytest.approx(to_target, abs=1e-9)


def test_vertical_board_basis_is_right_and_up():
    plane = ArPlane([0, 0, 0], [0, 0, -1])  # normal faces away; it gets flipped
    mapping = plane.mapping(CameraPose.from_meta(pose_meta([0.2, 0.3, 0.8], yaw_pitch(10))))
    assert plane.normal == pytest.approx([0, 0, 1])
    assert plane.x_axis == pytest.approx([1, 0, 0])
    assert plane.y_axis == pytest.approx([0, 1, 0])
    assert plane.describe()["facing"] == "vertical"
    assert mapping is not None


def test_table_basis_points_away_from_camera():
    plane = ArPlane([0, 0, 0], [0, 1, 0])
    plane.mapping(CameraPose.from_meta(pose_meta([0, 0.5, 0.6], yaw_pitch(0, -45))))
    assert plane.y_axis == pytest.approx([0, 0, -1])  # camera looks along -Z
    assert plane.x_axis == pytest.approx([1, 0, 0])
    assert plane.describe()["facing"] == "horizontal"


@pytest.mark.parametrize(
    "normal, camera, rotation, point",
    [
        ([0, 0, 1], [0.2, 0.3, 0.8], yaw_pitch(15, -5), [0.35, 0.12, 0.0]),  # board, phone at an angle
        ([0, 1, 0], [0.0, 0.5, 0.6], yaw_pitch(-20, -40), [0.1, 0.0, -0.15]),  # table seen from above
    ],
)
def test_pixel_maps_back_to_the_3d_point(normal, camera, rotation, point):
    meta = pose_meta(camera, rotation)
    plane = ArPlane([0, 0, 0], normal)
    mapping = plane.mapping(CameraPose.from_meta(meta))
    xy = mapping.image_to_world([project(meta, point)])[0]
    assert plane.plane_to_world(xy) == pytest.approx(point, abs=1e-6)


def test_moving_phone_keeps_the_same_coordinates():
    point = [0.25, 0.15, 0.0]
    plane = ArPlane([0, 0, 0], [0, 0, 1])
    results = []
    for camera, rotation in (([0, 0.2, 0.7], yaw_pitch()), ([0.4, 0.35, 0.5], yaw_pitch(30, -10))):
        meta = pose_meta(camera, rotation)
        mapping = plane.mapping(CameraPose.from_meta(meta))
        results.append(mapping.image_to_world([project(meta, point)])[0])
    assert results[0] == pytest.approx([0.25, 0.15], abs=1e-6)
    assert results[1] == pytest.approx(results[0], abs=1e-6)


def test_offset_moves_the_plane_towards_the_camera():
    meta = pose_meta([0, 0, 1.0])
    plane = ArPlane([0, 0, 0], [0, 0, 1], offset_m=0.03)  # a 3 cm ball in front of the board
    mapping = plane.mapping(CameraPose.from_meta(meta))
    centre = [0.1, 0.05, 0.03]
    xy = mapping.image_to_world([project(meta, centre)])[0]
    assert plane.plane_to_world(xy) == pytest.approx(centre, abs=1e-6)


def test_plane_behind_the_camera_has_no_mapping():
    plane = ArPlane([0, 0, 0], [0, 0, 1])
    looking_away = pose_meta([0, 0, 1.0], yaw_pitch(180))
    assert plane.mapping(CameraPose.from_meta(looking_away)) is None


def test_image_axes_on_a_square_on_board():
    meta = pose_meta([0, 0, 1.0])
    plane = ArPlane([0, 0, 0], [0, 0, 1])
    axes = image_axes(plane.mapping(CameraPose.from_meta(meta)), (0.0, 0.0))
    # 1 m at 1 m away with f = 500: +x is 500 px right, +y is 500 px up (image y down).
    assert axes["x"] == pytest.approx({"x": 500, "y": 0}, abs=1)
    assert axes["y"] == pytest.approx({"x": 0, "y": -500}, abs=1)


def test_bad_plane_requests():
    for bad in (None, {}, {"point": [0, 0, 0]}, {"point": [0, 0], "normal": [0, 1, 0]},
                {"point": [0, 0, 0], "normal": [0, 0, 0]}, {"point": [0, 0, 0], "normal": [0, 1, 0], "offset_m": 5}):
        with pytest.raises(ValueError):
            ArPlane.from_request(bad)


def ball_frame(frame_id, meta, world_point):
    img = np.full((480, 640, 3), 90, np.uint8)
    u, v = project(meta, world_point)
    cv2.circle(img, (round(u), round(v)), 14, (0, 0, 255), -1)
    return preprocess_frame(img, frame_id=frame_id, timestamp=frame_id / 30, working_width=640, meta=meta)


def test_pipeline_reports_plane_and_3d_positions():
    # The ball sits still on the board while the phone moves, so a pose-aligned motion
    # detector rightly ignores it; this test is about mapping, so use the color detector.
    pipe = TrackingPipeline(PipelineConfig(detector="color"))
    pipe.apply_config({"type": "config", "mode": "free_fall", "frame_size": {"w": 640, "h": 480},
                       "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]}})
    point = [0.1, 0.2, 0.0]
    for i, camera in enumerate(([0.05, 0.2, 0.8], [0.1, 0.25, 0.75], [0.15, 0.3, 0.7])):
        meta = pose_meta(camera, yaw_pitch(5 * i))
        out = pipe(ball_frame(i, meta, point))
    assert out["calibration"]["method"] == "arkit"
    assert out["calibration"]["status"] == "ok"
    assert out["calibration"]["plane"]["x_axis"] == pytest.approx([1, 0, 0])
    (obj,) = out["objects"]
    assert obj["position"] == pytest.approx({"x": 0.1, "y": 0.2}, abs=0.005)
    assert obj["position_3d"] == pytest.approx({"x": 0.1, "y": 0.2, "z": 0.0}, abs=0.005)
    assert obj["screen_axes"]["y"]["y"] < 0  # plane up is screen up


def test_pipeline_without_pose_waits_and_ruler_does_not_override():
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "px_per_m": 500, "frame_size": {"w": 640, "h": 480},
                       "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]}})
    out = pipe(preprocess_frame(np.full((480, 640, 3), 90, np.uint8), frame_id=0, timestamp=0.0))
    assert out["calibration"]["method"] == "arkit"
    assert out["calibration"]["status"] == "no_pose"
    # Dropping the plane falls back to the ruler scale.
    pipe.apply_config({"type": "config", "ar_plane": None})
    assert pipe.spatial.method == "scale"


def test_pipeline_rejects_bad_plane_and_keeps_old_one():
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]}})
    with pytest.raises(ValueError):
        pipe.apply_config({"type": "config", "ar_plane": {"point": [0, 0, 0]}})
    assert pipe.spatial.ar_plane is not None and pipe.session["ar_plane"]["normal"] == [0, 0, 1]


def test_malformed_pose_is_reported_not_fatal():
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]}})
    meta = {"intrinsics": INTRINSICS, "camera_to_world": [1, 2, 3]}
    out = pipe(preprocess_frame(np.full((480, 640, 3), 90, np.uint8), frame_id=0, timestamp=0.0, meta=meta))
    assert out["calibration"]["status"] == "no_pose"
    assert "pose" in out["calibration"]["pose_error"]


# A blank board with a few broad shapes: too little texture for ORB to align, so a moving
# phone looks like a moving scene unless the ARKit pose aligns the views.
TEXTURE_PX_PER_M = 1000
TEXTURE_TO_PLANE = np.array([[1 / TEXTURE_PX_PER_M, 0, -0.4], [0, -1 / TEXTURE_PX_PER_M, 0.5], [0, 0, 1]])


def plain_board(ball_xy=None):
    tex = np.full((800, 800, 3), 175, np.uint8)
    cv2.rectangle(tex, (80, 120), (330, 700), (95, 95, 95), -1)
    cv2.rectangle(tex, (520, 60), (760, 300), (130, 150, 170), -1)
    if ball_xy is not None:
        u, v = (ball_xy[0] + 0.4) * TEXTURE_PX_PER_M, (0.5 - ball_xy[1]) * TEXTURE_PX_PER_M
        cv2.circle(tex, (round(u), round(v)), 22, (40, 40, 220), -1)
    return tex


def board_view(meta, plane, tex):
    """The board as an ARKit camera with this pose sees it (640x480)."""
    mapping = plane.mapping(CameraPose.from_meta(meta))
    return cv2.warpPerspective(tex, mapping.H_inv @ TEXTURE_TO_PLANE, (640, 480), borderValue=(60, 60, 60))


def moving_phone(i):
    return pose_meta([0.02 * i, 0.1 + 0.005 * i, 0.9], yaw_pitch(1.5 * i))


def test_motion_detector_aligns_a_plain_board_with_the_pose():
    pipe = TrackingPipeline(PipelineConfig(detector="motion"))
    pipe.apply_config({"type": "config", "frame_size": {"w": 640, "h": 480},
                       "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]}})
    renderer = ArPlane([0, 0, 0], [0, 0, 1])
    ball = (0.05, 0.12)
    for i in range(14):
        meta = moving_phone(i)
        tex = plain_board(ball if i >= 11 else None)
        img = board_view(meta, renderer, tex)
        out = pipe(preprocess_frame(img, frame_id=i, timestamp=i / 30, working_width=640, meta=meta))
        if i < 11:
            assert out["objects"] == [], f"frame {i}: the phone's motion was reported as an object"
    (obj,) = out["objects"]
    assert obj["position"] == pytest.approx({"x": ball[0], "y": ball[1]}, abs=0.005)
    assert obj["position_3d"] == pytest.approx({"x": ball[0], "y": ball[1], "z": 0.0}, abs=0.005)


def test_new_surface_restarts_the_motion_background():
    pipe = TrackingPipeline(PipelineConfig(detector="motion"))
    pipe.apply_config({"type": "config", "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]}})
    meta = moving_phone(0)
    pipe(preprocess_frame(board_view(meta, ArPlane([0, 0, 0], [0, 0, 1]), plain_board()),
                          frame_id=0, timestamp=0.0, working_width=640, meta=meta))
    assert pipe.motion._ref_plane is not None
    pipe.apply_config({"type": "config", "mass_kg": 0.2})  # same surface: keep the background
    assert pipe.motion._ref_plane is not None
    pipe.apply_config({"type": "config", "ar_plane": {"point": [0, 0, 0.1], "normal": [0, 0, 1]}})
    assert pipe.motion._ref_plane is None
