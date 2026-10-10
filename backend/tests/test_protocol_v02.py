"""The Flutter app's side of docs/protocol.md (v0.2, branch Dev1)."""

import json

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import app
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import encode_jpeg, preprocess_frame

@pytest.fixture(autouse=True)
def color_detector(monkeypatch):
    # These tests check the protocol with red/blue test objects, so pin the color detector
    # (the app default is motion, which needs a moving object against a learned background).
    monkeypatch.setenv("CV_DETECTOR", "color")


APP_CONFIG = {
    "type": "config",
    "mode": "ramp",
    "mass_kg": 0.1,
    "px_per_m": 812.5,
    "target_px": None,
    "frame_size": {"w": 320, "h": 240},
}


def phone_frame(balls=(((160, 120), 12, (0, 0, 255)),)):
    """A 320x240 frame like the app sends."""
    img = np.full((240, 320, 3), 90, np.uint8)
    for center, r, color in balls:
        cv2.circle(img, center, r, color, -1)
    return img


def send_frame(ws, frame_id, img):
    ws.send_text(json.dumps({"frame_id": frame_id, "timestamp": 41.2 + frame_id / 15}))
    ws.send_bytes(encode_jpeg(img, 70))
    return ws.receive_json()


def test_app_config_is_accepted_silently():
    # The app counts any reply it doesn't recognise as a failure, so a good config gets none:
    # the first message back must be the frame report.
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps(APP_CONFIG))
        out = send_frame(ws, 0, phone_frame())
        assert out["type"] == "state" and out["frame_id"] == 0
        assert out["calibration"]["method"] == "scale"


def test_pipeline_keeps_session_settings():
    pipe = TrackingPipeline()
    settings = pipe.apply_config(APP_CONFIG)
    assert settings["session"] == {k: v for k, v in APP_CONFIG.items() if k != "type"}


def test_objects_in_phone_pixels_with_px_per_m_position():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps(APP_CONFIG))
        send_frame(ws, 0, phone_frame())
        out = send_frame(ws, 1, phone_frame())
    assert out["tracked"] is True
    (obj,) = out["objects"]
    assert obj["target"] is True and out["target_id"] == obj["id"]
    assert obj["pixel"] == pytest.approx({"x": 160, "y": 120}, abs=1)
    assert obj["bbox"] == pytest.approx({"x": 148, "y": 108, "w": 25, "h": 25}, abs=2)
    # px_per_m scale, origin bottom-left of the frame, y up.
    assert obj["position"] == pytest.approx({"x": 160 / 812.5, "y": (240 - 120) / 812.5}, abs=0.002)
    assert out["calibration"]["method"] == "scale"


def test_every_frame_gets_a_reply_even_with_nothing_tracked():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps(APP_CONFIG))
        for i in range(3):
            out = send_frame(ws, i, phone_frame(balls=()))
            assert out["frame_id"] == i and out["tracked"] is False and out["objects"] == []


def test_invalid_config_is_rejected_and_nothing_changes():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps({**APP_CONFIG, "mode": "teleport", "px_per_m": 1000}))
        assert ws.receive_json()["type"] == "error"
        send_frame(ws, 0, phone_frame())
        out = send_frame(ws, 1, phone_frame())
    assert out["objects"][0]["position"] is None  # px_per_m was not applied


def test_target_px_picks_the_tapped_object():
    balls = (((60, 120), 12, (0, 0, 255)), ((250, 120), 12, (255, 0, 0)))
    pipe = TrackingPipeline()
    pipe.apply_config({**APP_CONFIG, "target_px": {"x": 245, "y": 118}})
    for i in range(2):
        out = pipe(preprocess_frame(phone_frame(balls), i, i / 15))
    (target,) = [o for o in out["objects"] if o["target"]]
    assert target["label"] == "blue"

    # Re-tapping the other object switches the target.
    pipe.apply_config({"type": "config", "target_px": {"x": 62, "y": 121}})
    out = pipe(preprocess_frame(phone_frame(balls), 2, 2 / 15))
    (target,) = [o for o in out["objects"] if o["target"]]
    assert target["label"] == "red"


def test_tap_far_from_any_object_tracks_nothing():
    pipe = TrackingPipeline()
    pipe.apply_config({**APP_CONFIG, "target_px": {"x": 300, "y": 20}})
    for i in range(2):
        out = pipe(preprocess_frame(phone_frame(), i, 0.0))
    assert out["tracked"] is False and len(out["objects"]) == 1


def test_explicit_calibration_beats_px_per_m():
    pipe = TrackingPipeline()
    pipe.calibrate({"method": "manual", "image_points": [[0, 0], [320, 0], [320, 240], [0, 240]],
                    "width_m": 1.0, "height_m": 0.75})
    pipe.apply_config(APP_CONFIG)
    assert pipe.spatial.method == "manual"
    pipe.apply_config({"type": "config", "px_per_m": None})
    assert pipe.spatial.method == "manual"


def test_px_per_m_null_turns_scale_off():
    pipe = TrackingPipeline()
    pipe.apply_config(APP_CONFIG)
    assert pipe.spatial.method == "scale"
    pipe.apply_config({"type": "config", "px_per_m": None})
    assert pipe.spatial.method == "none" and pipe.spatial.mapping is None
