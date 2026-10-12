"""Original camera JPEGs with blur, partial visibility, and ball absence."""

import hashlib
import json
import math
from pathlib import Path

import cv2
import pytest

from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, preprocess_frame
from physics_engine import PhysicsSession

FIXTURE = Path(__file__).parent / "fixtures" / "blurred_gray_ball"


def captured_frames():
    manifest = json.loads((FIXTURE / "manifest.json").read_text())
    frames = {}
    for item in manifest["frames"]:
        jpeg = (FIXTURE / item["file"]).read_bytes()
        assert hashlib.sha256(jpeg).hexdigest() == item["sha256"]
        frames[item["frame_id"]] = preprocess_frame(
            decode_jpeg(jpeg), item["frame_id"], item["timestamp"])
    return manifest, frames


def test_blurred_falling_ball_keeps_marker_without_physics():
    manifest, frames = captured_frames()
    cv2.setRNGSeed(0)
    pipe, physics = TrackingPipeline(), PhysicsSession()
    pipe.apply_config(manifest["config"])
    states = {}
    try:
        assert pipe.initialize(frames[0])["status"] == "initialized"
        for i, frame in frames.items():
            if i == 0:
                continue
            report = {"frame_id": i, "timestamp": frame.timestamp, **pipe(frame)}
            states[i] = physics.process_frame(report, manifest["config"])
        for number, center in manifest["visual_annotations"]["centers"].items():
            state = states[int(number)]
            assert state["tracked"]
            assert math.hypot(state["pixel"]["x"] - center[0],
                              state["pixel"]["y"] - center[1]) < 8
            assert state["tracking_status"] == "low_confidence"
            assert state["objects"][0]["measurement_valid"] is False
            assert state["position"] is None
            assert state["position_3d"] is None
            assert state["screen_axes"] is None
            assert state["physics_quality"]["reason"] == "localization_uncertain"
            assert "velocity" not in state and "acceleration" not in state
            assert "energy" not in state and not state["forces"]
        for i in manifest["visual_annotations"]["partial_frames"] + manifest["visual_annotations"]["absent_frames"]:
            assert not states[i]["tracked"]
        # Fresh precise observations must establish their own derivative history.
        assert states[9]["physics_quality"]["samples"] == 1
        assert states[13]["physics_quality"]["samples"] == 1
    finally:
        pipe.close()


def test_weak_markers_never_refresh_the_identity_deadline_or_template(monkeypatch):
    manifest, frames = captured_frames()
    cv2.setRNGSeed(0)
    pipe = TrackingPipeline()
    pipe.apply_config(manifest["config"])
    try:
        pipe.initialize(frames[0])
        for i in (1, 2, 3):
            pipe(frames[i])
        tracker = pipe._manual
        anchor = tracker._last_verified_time
        template = tracker.template.copy()
        original = tracker.original.copy()
        size = tracker._size
        # Isolate the continuation path after the last sharp identity match.
        monkeypatch.setattr(tracker, "_search", lambda *args, **kwargs: None)
        for i in range(4, 9):
            assert tracker.detect(frames[i]) is not None
            assert tracker.visual_only
            assert tracker._last_verified_time == anchor
            assert tracker._size == size
            assert (tracker.template == template).all()
            assert (tracker.original == original).all()
        assert tracker.detect(frames[9]) is None  # 249.8 ms since sharp match.
    finally:
        pipe.close()
