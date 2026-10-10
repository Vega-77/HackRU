"""End-to-end tests of CV tracking feeding the Dev 3 physics stage."""

import json

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import app


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
