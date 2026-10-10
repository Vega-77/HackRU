"""End-to-end tests of CV tracking feeding the Dev 3 physics stage."""

import json

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import app


@pytest.fixture(autouse=True)
def color_detector(monkeypatch):
    # The ball is on screen from the first frame, which the color detector sees at once; the
    # app default (motion) only finds it once it moves off a learned background.
    monkeypatch.setenv("CV_DETECTOR", "color")


def send_ball(ws, frame_id: int, x_px: int) -> dict:
    image = np.full((240, 320, 3), 90, np.uint8)
    cv2.circle(image, (x_px, 120), 12, (0, 0, 255), -1)
    ok, encoded = cv2.imencode(".jpg", image)
    assert ok
    ws.send_text(json.dumps({"frame_id": frame_id, "timestamp": frame_id / 10}))
    ws.send_bytes(encoded.tobytes())
    return ws.receive_json()


def test_configured_mode_emits_state_with_metric_vectors() -> None:
    config = {
        "type": "config", "mode": "ramp", "mass_kg": 0.2,
        "px_per_m": 1000.0, "frame_size": {"w": 320, "h": 240},
        "ramp_angle_deg": 0.0,
    }
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps(config))
        replies = [send_ball(ws, index, 80 + 10 * index) for index in range(6)]

    state = replies[-1]
    assert all(reply["type"] == "state" for reply in replies)
    assert state["tracked"] is True
    assert state["frame_id"] == 5
    assert state["position"]["x"] == pytest.approx(0.13, abs=0.003)
    assert state["velocity"]["x"] == pytest.approx(0.1, abs=0.02)
    assert state["acceleration"]["x"] == pytest.approx(0.0, abs=0.2)
    assert {force["name"] for force in state["forces"]} >= {"gravity", "normal", "net"}
    assert state["energy"]["kinetic"] > 0


def test_no_calibration_keeps_pixel_tracking_without_false_physics() -> None:
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps({"type": "config", "mode": "free_fall", "mass_kg": 0.1}))
        send_ball(ws, 0, 80)
        state = send_ball(ws, 1, 90)

    assert state["type"] == "state"
    assert state["tracked"] is True
    assert state["pixel"]["x"] == pytest.approx(90, abs=2)
    assert state["position"] is None
    assert "velocity" not in state


def test_invalid_physics_geometry_rejected_before_processing() -> None:
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps({"type": "config", "mode": "ramp", "ramp_angle_deg": 110}))
        error = ws.receive_json()

    assert error["type"] == "error"
    assert "ramp_angle_deg" in error["message"]


def test_two_clients_keep_separate_physics_history() -> None:
    config = {
        "type": "config", "mode": "ramp", "mass_kg": 0.2,
        "px_per_m": 1000.0, "frame_size": {"w": 320, "h": 240},
        "ramp_angle_deg": 0.0,
    }
    with TestClient(app) as client:
        with client.websocket_connect("/ws/frames") as first:
            with client.websocket_connect("/ws/frames") as second:
                assert client.get("/health").json()["active_sessions"] == 2
                first.send_text(json.dumps(config))
                second.send_text(json.dumps(config))
                send_ball(first, 0, 80)
                send_ball(first, 1, 90)
                moving = send_ball(first, 2, 100)
                send_ball(second, 0, 180)
                fresh = send_ball(second, 1, 180)
                assert moving["type"] == fresh["type"] == "state"
                assert moving["velocity"]["x"] > 0
                assert "velocity" not in fresh
            assert client.get("/health").json()["active_sessions"] == 1
        assert client.get("/health").json()["active_sessions"] == 0


def test_arkit_pose_gives_world_space_vectors() -> None:
    """An iOS client sends its ARKit pose with each frame and a plane once: positions are
    metres on that plane, and every vector also comes back in ARKit world space."""
    camera_to_world = np.eye(4)
    camera_to_world[:3, 3] = [0.0, 0.0, 1.0]  # 1 m in front of the board, looking at it
    pose = {"intrinsics": {"fx": 250.0, "fy": 250.0, "cx": 160.0, "cy": 120.0},
            "camera_to_world": camera_to_world.reshape(-1).tolist()}
    config = {
        "type": "config", "mode": "ramp", "mass_kg": 0.2, "frame_size": {"w": 320, "h": 240},
        "ramp_angle_deg": 0.0, "ar_plane": {"point": [0, 0, 0], "normal": [0, 0, 1]},
    }
    replies = []
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps(config))
        for index in range(6):
            image = np.full((240, 320, 3), 90, np.uint8)
            cv2.circle(image, (80 + 10 * index, 120), 12, (0, 0, 255), -1)
            ok, encoded = cv2.imencode(".jpg", image)
            assert ok
            ws.send_text(json.dumps({"frame_id": index, "timestamp": index / 10, **pose}))
            ws.send_bytes(encoded.tobytes())
            replies.append(ws.receive_json())

    state = replies[-1]
    assert state["calibration"]["method"] == "arkit"
    # 10 px per 0.1 s at 1 m with f = 250 px is 0.4 m/s to the right.
    assert state["position_3d"] == pytest.approx({"x": (130 - 160) / 250, "y": 0.0, "z": 0.0}, abs=0.005)
    assert state["velocity"]["x"] == pytest.approx(0.4, abs=0.05)
    assert state["velocity_3d"]["x"] == pytest.approx(0.4, abs=0.05)
    assert state["velocity_3d"]["z"] == pytest.approx(0.0, abs=1e-6)
    gravity = next(f for f in state["forces_3d"] if f["name"] == "gravity")
    assert gravity == pytest.approx({"name": "gravity", "x": 0.0, "y": -0.2 * 9.81, "z": 0.0}, abs=0.01)
    assert state["screen_axes"]["x"]["x"] == pytest.approx(250, abs=1)
