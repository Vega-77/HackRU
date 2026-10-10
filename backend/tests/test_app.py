import json

import cv2
import numpy as np
from fastapi.testclient import TestClient

from app import app
from cv_engine.preprocess import encode_jpeg


def frame_bytes():
    img = np.full((480, 1280, 3), 90, np.uint8)
    cv2.circle(img, (200, 200), 40, (0, 0, 255), -1)
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
