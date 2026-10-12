"""Regressions from the original JPEG export, without screen reconstruction."""

import json
import base64
import hashlib
from pathlib import Path

import cv2
import numpy as np
import pytest

from cv_engine.foreground import RoundReference
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, preprocess_frame
from physics_engine import PhysicsSession
from analyze_capture_bundle import analyze_capture

FIXTURE = Path(__file__).parent / "fixtures" / "exported_gray_ball"


def test_bundle_analysis_replays_original_ids_times_and_calibration(tmp_path):
    manifest = json.loads((FIXTURE / "manifest.json").read_text())
    def image(row):
        return {**row, "jpeg_base64": base64.b64encode((FIXTURE / row["file"]).read_bytes()).decode()}
    bundle = {"format": "hands-on-physics-capture", "version": 1,
              "config": manifest["config"], "ruler": {"length_m": .3},
              "capture": {"frame_count": len(manifest["frames"]) - 1},
              "selection": image(manifest["frames"][0]),
              "frames": [image(row) for row in manifest["frames"][1:]]}
    path = tmp_path / "capture.hop.json"
    path.write_text(json.dumps(bundle))
    result = analyze_capture(path)
    assert result["source_sha256"] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert result["config"] == bundle["config"]
    assert [(r["frame_id"], r["timestamp"]) for r in result["observations"]] == [
        (r["frame_id"], r["timestamp"]) for r in bundle["frames"]]
    assert sum(r.get("position") is not None for r in result["observations"]) == 18
    assert all("physics" in r["timing_ms"] for r in result["observations"])


def test_exported_long_hold_does_not_contaminate_short_flight_acceleration():
    data = json.loads((FIXTURE / "long_hold_positions.json").read_text())
    physics = PhysicsSession()
    for row in data["observations"]:
        report = {**row, "calibration": {"method": "scale", "settings": {
            "px_per_m": data["config"]["px_per_m"]}}, "objects": [{
                "id": 1, "target": True, "score": 1.0, "position": row["position"],
                "pixel": row["pixel"]}]}
        state = physics.process_frame(report, data["config"])
        if row["frame_id"] in (61, 62, 63):
            assert "acceleration" not in state
            assert state["physics_quality"]["samples"] == row["frame_id"] - 60


def test_exported_ball_does_not_reacquire_hair_after_release():
    manifest = json.loads((FIXTURE / "manifest.json").read_text())
    cv2.setRNGSeed(0)
    pipe = TrackingPipeline()
    pipe.apply_config(manifest["config"])
    physics = PhysicsSession()
    states = {}
    try:
        for item in manifest["frames"]:
            frame = preprocess_frame(decode_jpeg((FIXTURE / item["file"]).read_bytes()),
                                     item["frame_id"], item["timestamp"])
            if item["frame_id"] == 0:
                assert pipe.initialize(frame)["status"] == "initialized"
            else:
                report = {"frame_id": item["frame_id"], "timestamp": item["timestamp"], **pipe(frame)}
                states[item["frame_id"]] = physics.process_frame(report, manifest["config"])
    finally:
        pipe.close()
    for i in range(1, 17):
        assert states[i]["tracked"]  # Held-ball detections are preserved.
    for i in (19, 20):
        assert states[i]["tracked"]
        assert states[i]["pixel"]["x"] == pytest.approx(204, abs=3)
        assert "acceleration" not in states[i]  # No held/falling mixture.
    for i in (65, 66, 67):
        assert not states[i]["tracked"]  # Ball absent; hair must not become the target.


@pytest.mark.parametrize("shift", [-24, 24])
def test_exposure_correction_keeps_its_direction(shift):
    reference = RoundReference()
    reference.chroma = np.array([128, 128])
    reference.chroma_spread = np.array([2, 2])
    reference.lightness, reference.spread = 110.0, 10.0
    mask = np.ones((20, 20), np.uint8)
    def patch(lightness):
        lab = np.full((20, 20, 3), (lightness, 128, 128), np.uint8)
        return cv2.cvtColor(lab, cv2.COLOR_LAB2BGR)
    assert reference.appearance_matches(patch(110 + shift), mask, shift)
    assert not reference.appearance_matches(patch(110 - 2 * shift), mask, shift)
