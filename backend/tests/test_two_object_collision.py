"""Collision mode with both objects selected: each is followed the same way as a single
selected object, keeps its own ID through the impact, and both reach the physics stage."""

import math
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app import app
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, preprocess_frame
from physics_stage import PhysicsSession

sys.path.insert(0, str(Path(__file__).parent))
import motion_scenes  # noqa: E402

FRAME_SIZE = {"w": motion_scenes.W, "h": motion_scenes.H}


def config(first, second, **extra):
    return {"type": "config", "mode": "collision", "px_per_m": 400.0, "frame_size": FRAME_SIZE,
            "target_px": first.tap, "target_bbox": first.box,
            "second_target_px": second.tap, "second_target_bbox": second.box, **extra}


def near(obj, truth, clip):
    return truth is not None and math.hypot(obj["pixel"]["x"] - truth[0], obj["pixel"]["y"] - truth[1]) <= 0.35 * clip.diameter


def test_both_selected_objects_are_followed_through_the_collision():
    first, second = motion_scenes.collision()
    pipe = TrackingPipeline()
    pipe.apply_config(config(first, second))
    physics = PhysicsSession()
    calls = []
    detect = pipe.detect
    pipe.detect = lambda frame: calls.append(frame.frame_id) or detect(frame)
    ids = {"selected": set(), "selected_2": set()}
    found = {"selected": 0, "selected_2": 0}
    extras = {}
    for i, jpeg in enumerate(first.frames):
        result = pipe(preprocess_frame(decode_jpeg(jpeg), i, first.timestamps[i]))
        state = physics.process_frame({**result, "frame_id": i, "timestamp": first.timestamps[i]}, pipe.session)
        extras.update(state["extras"])
        if i == 0:
            continue
        for label, clip in (("selected", first), ("selected_2", second)):
            obj = next((o for o in result["objects"] if o["label"] == label), None)
            if obj is None:
                continue
            ids[label].add(obj["id"])
            found[label] += near(obj, clip.truth[i], clip)
            assert near(obj, clip.truth[i], clip), (label, i, obj["pixel"], clip.truth[i])
    frames = len(first.frames) - 1
    assert found["selected"] >= 0.9 * frames and found["selected_2"] >= 0.9 * frames
    assert len(ids["selected"]) == 1 and len(ids["selected_2"]) == 1
    assert ids["selected"] != ids["selected_2"]
    assert calls == [0]  # with both selected, the other detectors have nothing left to find
    assert "momentum_before" in extras and "restitution" in extras


def test_without_a_second_selection_collision_mode_still_runs_the_detectors():
    first, _ = motion_scenes.collision()
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "mode": "collision", "frame_size": FRAME_SIZE,
                       "target_px": first.tap, "target_bbox": first.box})
    calls = []
    detect = pipe.detect
    pipe.detect = lambda frame: calls.append(frame.frame_id) or detect(frame)
    for i in range(3):
        pipe(preprocess_frame(decode_jpeg(first.frames[i]), i, first.timestamps[i]))
    assert calls == [0, 1, 2]


def test_second_selection_is_ignored_outside_collision_mode():
    first, second = motion_scenes.collision()
    pipe = TrackingPipeline()
    pipe.apply_config(config(first, second, mode="ramp"))
    for i in range(3):
        result = pipe(preprocess_frame(decode_jpeg(first.frames[i]), i, first.timestamps[i]))
    assert not any(o["label"] == "selected_2" for o in result["objects"])


def send_image(ws, kind, frame_id, jpeg, **meta):
    ws.send_json({"type": kind, "frame_id": frame_id, "timestamp": frame_id / motion_scenes.FPS,
                  "selection_id": "test", **meta})
    ws.send_bytes(jpeg)


def test_live_frames_wait_for_both_selections_to_be_initialized():
    first, second = motion_scenes.collision()
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_json(config(first, second, initialization_required=True))
        send_image(ws, "initialize", 0, first.frames[0])
        ack = ws.receive_json()
        assert ack["status"] == "initialized" and ack["target"] == "first"
        send_image(ws, "frame", 1, first.frames[1])
        assert ws.receive_json()["type"] == "error"  # the second object is not initialized yet
        send_image(ws, "initialize", 2, first.frames[0], target="second")
        ack = ws.receive_json()
        assert ack["status"] == "initialized" and ack["target"] == "second"
        assert ack["bbox"]["x"] < second.tap["x"] < ack["bbox"]["x"] + ack["bbox"]["w"]
        for i in range(3, 6):
            send_image(ws, "frame", i, first.frames[i - 2])
            result = ws.receive_json()
        labels = {o["label"] for o in result["objects"]}
        assert {"selected", "selected_2"} <= labels


def test_second_initialization_needs_a_second_selection():
    first, _ = motion_scenes.collision()
    with TestClient(app).websocket_connect("/ws/frames") as ws:
        ws.send_json({"type": "config", "mode": "collision", "target_px": first.tap, "target_bbox": first.box,
                      "initialization_required": True})
        send_image(ws, "initialize", 0, first.frames[0], target="second")
        ack = ws.receive_json()
        assert ack["status"] == "failed" and ack["reason"] == "no_second_selection"


@pytest.mark.parametrize("bad", [{"x": 1}, {"x": 0, "y": 0, "w": 0, "h": 4}])
def test_bad_second_selection_is_rejected(bad):
    pipe = TrackingPipeline()
    key = "second_target_px" if "w" not in bad else "second_target_bbox"
    with pytest.raises(ValueError):
        pipe.apply_config({"type": "config", key: bad})
