import base64
import json

import cv2
import numpy as np
import pytest

from extract_capture_bundle import extract_capture
from replay_tracking import replay


def capture(tmp_path):
    image = np.full((180, 320, 3), 90, np.uint8)
    cv2.circle(image, (80, 90), 12, (180, 180, 180), -1)
    ok, encoded = cv2.imencode(".jpg", image)
    assert ok
    jpeg = encoded.tobytes()
    frame = lambda i, t: {"frame_id": i, "timestamp": t,
                         "jpeg_base64": base64.b64encode(jpeg).decode(),
                         "frame_size": {"w": 320, "h": 180}}
    bundle = {"format": "hands-on-physics-capture", "version": 1,
              "config": {"target_px": {"x": 80, "y": 90},
                         "target_bbox": {"x": 64, "y": 74, "w": 32, "h": 32},
                         "px_per_m": 305, "mode": "free_fall"},
              "ruler": {"length_m": .3}, "selection": frame(0, 1829.396),
              "frames": [frame(1, 1867.6539), frame(2, 1867.6899)],
              "analysis": {"complete": False, "error": "connection lost",
                           "observations": [{"frame_id": 1, "tracked": False}]}}
    path = tmp_path / "capture.hop.json"
    path.write_text(json.dumps(bundle))
    return path, bundle, jpeg


def test_exact_bytes_times_calibration_partial_results_and_replay(tmp_path):
    path, bundle, jpeg = capture(tmp_path)
    destination = tmp_path / "extracted"
    manifest_path = extract_capture(path, destination)
    manifest = json.loads(manifest_path.read_text())
    assert manifest["config"] == bundle["config"]
    assert [r["timestamp"] for r in manifest["frames"]] == [1829.396, 1867.6539, 1867.6899]
    assert [r["frame_id"] for r in manifest["frames"]] == [0, 1, 2]
    for row in manifest["frames"]:
        assert (destination / row["file"]).read_bytes() == jpeg
    assert json.loads((destination / "analysis.json").read_text()) == bundle["analysis"]
    assert json.loads((destination / "capture.json").read_text())["ruler"] == bundle["ruler"]
    assert len(replay(manifest_path)["frames"]) == 3
    with pytest.raises(FileExistsError):
        extract_capture(path, destination)


@pytest.mark.parametrize("corruption", ["base64", "timestamps", "format"])
def test_reject_invalid_bundle_before_writing(tmp_path, corruption):
    path, bundle, _ = capture(tmp_path)
    if corruption == "base64":
        bundle["frames"][1]["jpeg_base64"] = "invalid!"
    elif corruption == "timestamps":
        bundle["frames"][1]["timestamp"] = bundle["frames"][0]["timestamp"]
    else:
        bundle["version"] = 2
    path.write_text(json.dumps(bundle))
    with pytest.raises(ValueError):
        extract_capture(path, tmp_path / "invalid")
    assert not (tmp_path / "invalid").exists()
