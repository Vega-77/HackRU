import json

import cv2
import numpy as np
from fastapi.testclient import TestClient

from app import app
from cv_engine.preprocess import encode_jpeg


def frame_bytes(x=200):
    img = np.full((480, 1280, 3), 90, np.uint8)
    cv2.circle(img, (x, 200), 40, (0, 0, 255), -1)
    return encode_jpeg(img)


def test_health():
    assert TestClient(app).get("/health").json()["status"] == "ok"


def test_frame_round_trip():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps({"frame_id": 7, "timestamp": 123.5}))
        ws.send_bytes(frame_bytes())
        out = ws.receive_json()
    assert out["type"] == "frame"
    assert out["frame_id"] == 7 and out["timestamp"] == 123.5
    assert out["size"] == [640, 240] and out["source_size"] == [1280, 480]
    assert out["objects"] == []
    assert out["stats"]["processed"] == 1


def test_frame_without_metadata_gets_an_id():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_bytes(frame_bytes())
        assert ws.receive_json()["frame_id"] == 0


def test_bad_image_reports_error_and_keeps_connection():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_bytes(b"garbage")
        assert ws.receive_json()["type"] == "error"
        ws.send_bytes(frame_bytes())
        assert ws.receive_json()["type"] == "frame"


def test_tracked_object_reported_after_two_frames():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_bytes(frame_bytes(200))
        assert ws.receive_json()["objects"] == []
        ws.send_bytes(frame_bytes(220))
        objs = ws.receive_json()["objects"]
    assert len(objs) == 1 and objs[0]["label"] == "red"
    assert abs(objs[0]["centroid"][0] - 220) < 3 and abs(objs[0]["centroid"][1] - 200) < 3


def test_config_message_changes_colors():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps({"type": "config", "colors": ["blue"]}))
        assert ws.receive_json()["config"]["colors"] == ["blue"]
        ws.send_bytes(frame_bytes(200))
        ws.receive_json()
        ws.send_bytes(frame_bytes(220))
        assert ws.receive_json()["objects"] == []  # red ball is no longer tracked
        ws.send_text(json.dumps({"type": "config", "colors": ["chartreuse"]}))
        assert ws.receive_json()["type"] == "error"


def test_calibrate_message_adds_world_coordinates():
    import sys
    from pathlib import Path
    sys.path.insert(0, str(Path(__file__).parent))
    from scenes import BOARD_H, BOARD_W, board_image, camera_view

    view, _ = camera_view(board_image(ball_world=(0.2, 0.1))[0])
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text(json.dumps({"type": "calibrate", "method": "aruco", "width_m": BOARD_W, "height_m": BOARD_H}))
        assert ws.receive_json()["calibration"]["status"] == "searching"
        for _ in range(2):
            ws.send_bytes(encode_jpeg(view, 90))
            out = ws.receive_json()
        assert out["calibration"]["status"] == "ok"
        (obj,) = out["objects"]
        assert abs(obj["world"][0] - 0.2) < 0.006 and abs(obj["world"][1] - 0.1) < 0.006
        ws.send_text(json.dumps({"type": "calibrate", "method": "aruco"}))
        assert ws.receive_json()["type"] == "error"
