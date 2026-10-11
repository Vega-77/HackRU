"""Color independent CV and protocol coverage on synthetic camera frames."""

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

from app import app
from cv_engine.pipeline import PipelineConfig, TrackingPipeline
from cv_engine.preprocess import encode_jpeg, preprocess_frame


def image(objects=(), background=90, size=(320, 240)):
    out = np.full((size[1], size[0], 3), background, np.uint8)
    for x, y, radius, color in objects:
        cv2.circle(out, (x, y), radius, color, -1)
    return out


def run(pipe, img, index):
    return pipe(preprocess_frame(img, index, index / 15))


@pytest.mark.parametrize("color", [(180, 180, 180), (0, 0, 255), (40, 120, 30)])
def test_motion_detects_different_colors_with_stable_centers(color):
    pipe = TrackingPipeline()
    assert pipe.config.detector == "motion"
    for index in range(5):
        run(pipe, image(), index)
    for index in range(6):
        result = run(pipe, image([(80 + 10 * index, 120, 14, color)]), index + 5)
    assert result["tracked"] is True
    obj = result["objects"][0]
    assert obj["source"] == "motion" and obj["label"] == "object"
    assert obj["pixel"] == pytest.approx({"x": 130, "y": 120}, abs=2)
    assert obj["bbox"]["w"] == pytest.approx(29, abs=3)
    assert obj["timestamp"] == pytest.approx(10 / 15)


def test_manual_selection_tracks_stationary_near_gray_object_and_reports_loss():
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "target_px": {"x": 80, "y": 120},
                       "target_bbox": {"x": 64, "y": 104, "w": 32, "h": 32}})
    selected = image([(80, 120, 12, (104, 104, 104))], background=90)
    assert run(pipe, selected, 0)["tracked"] is False
    first = run(pipe, selected, 1)
    obj = first["objects"][0]
    object_id = obj["id"]
    assert obj["source"] == "manual" and obj["target"] is True
    for i in range(1, 4):
        out = run(pipe, image([(80 + 3 * i, 120, 12, (104, 104, 104))], background=90), i)
        assert out["target_id"] == object_id and out["tracked"] is True
    lost = run(pipe, image(background=90), 4)
    assert lost["tracked"] is False and lost["tracking_status"] == "lost"
    assert all(o["source"] != "manual" for o in lost["objects"])
    resumed = run(pipe, image([(92, 120, 12, (104, 104, 104))], background=90), 5)
    assert resumed["tracked"] is True and resumed["target_id"] == object_id


def test_manual_box_maps_back_to_client_pixels_after_resize():
    pipe = TrackingPipeline(PipelineConfig(detector="motion"))
    pipe.apply_config({"type": "config", "target_px": {"x": 400, "y": 240},
                       "target_bbox": {"x": 370, "y": 210, "w": 60, "h": 60},
                       "px_per_m": 1000, "frame_size": {"w": 640, "h": 480}})
    img = image([(400, 240, 22, (170, 170, 170))], size=(640, 480))
    assert pipe(preprocess_frame(img, 0, 0.0, working_width=320))["tracked"] is False
    out = pipe(preprocess_frame(img, 1, 0.1, working_width=320))
    obj = out["objects"][0]
    assert obj["pixel"] == pytest.approx({"x": 400, "y": 240}, abs=1)
    # The box hugs the ball (radius 22) inside the user's looser box, in client pixels.
    box = obj["bbox"]
    assert box["x"] + box["w"] / 2 == pytest.approx(400, abs=1)
    assert box["y"] + box["h"] / 2 == pytest.approx(240, abs=1)
    assert 44 <= box["w"] <= 60 and 44 <= box["h"] <= 60
    assert obj["position"] == pytest.approx({"x": 0.4, "y": 0.24}, abs=0.001)


def test_selected_object_remains_target_during_modest_scale_change():
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "target_px": {"x": 100, "y": 120},
                       "target_bbox": {"x": 84, "y": 104, "w": 32, "h": 32}})
    ids = set()
    for i, radius in enumerate((11, 12, 13, 14, 15)):
        out = run(pipe, image([(100 + 2 * i, 120, radius, (180, 180, 180))]), i)
        if i == 0:
            assert out["tracked"] is False
            continue
        assert out["tracked"] is True
        ids.add(out["target_id"])
        assert out["objects"][0]["pixel"]["x"] == pytest.approx(100 + 2 * i, abs=5)
    assert len(ids) == 1


def test_websocket_default_motion_and_bad_frame_recovery():
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_text('{"frame_id": "oops", "timestamp": 0}')
        ws.send_bytes(encode_jpeg(image()))
        assert ws.receive_json()["type"] == "error"
        ws.send_bytes(b"bad frame")
        assert ws.receive_json()["type"] == "error"
        ws.send_text('{"frame_id": 0, "timestamp": 0}')
        ws.send_bytes(b"x" * (512 * 1024 + 1))
        assert ws.receive_json()["frame_id"] == 0
        for _ in range(5):
            ws.send_bytes(encode_jpeg(image()))
            ws.receive_json()
        for i in range(5):
            ws.send_bytes(encode_jpeg(image([(80 + 10 * i, 120, 14, (180, 180, 180))])))
            out = ws.receive_json()
        assert out["type"] == "frame" and out["tracked"] is True
        assert out["objects"][0]["source"] == "motion"
        ws.send_text('{"frame_id": 2, "timestamp": 1}')
        ws.send_bytes(encode_jpeg(image()))
        assert "increasing" in ws.receive_json()["message"]


def test_two_moving_objects_keep_distinct_ids():
    pipe = TrackingPipeline()
    for index in range(5):
        run(pipe, image(), index)
    ids = None
    for i in range(7):
        out = run(pipe, image([(60 + 6 * i, 80, 12, (0, 0, 220)),
                               (250 - 6 * i, 160, 15, (175, 175, 175))]), i + 5)
        if i >= 2:
            assert len(out["objects"]) == 2
            ordered = sorted(out["objects"], key=lambda o: o["pixel"]["y"])
            current = [o["id"] for o in ordered]
            if ids is None:
                ids = current
            assert current == ids


def test_selected_object_on_calibrated_sample_clip():
    from pathlib import Path
    import csv
    import math

    sample = Path(__file__).parents[1] / "samples" / "ramp.mp4"
    truth = {int(row["frame"]): (float(row["x_m"]), float(row["y_m"]))
             for row in csv.DictReader(sample.with_name("ramp_truth.csv").open())}
    capture = cv2.VideoCapture(str(sample))
    pipe = TrackingPipeline()
    pipe.calibrate({"method": "aruco", "width_m": 0.6, "height_m": 0.4})
    pipe.apply_config({"type": "config", "target_px": {"x": 389.33, "y": 186.61},
                       "target_bbox": {"x": 366, "y": 168, "w": 50, "h": 40}})
    errors = []
    ids = set()
    for i in range(45):
        ok, frame = capture.read()
        assert ok
        out = run(pipe, frame, i)
        target = next((obj for obj in out["objects"] if obj["target"]), None)
        if target and target["position"]:
            ids.add(target["id"])
            tx, ty = truth[i]
            errors.append(math.hypot(target["position"]["x"] - tx, target["position"]["y"] - ty))
    capture.release()
    assert len(errors) >= 40 and len(ids) == 1
    assert np.median(errors) < 0.01
