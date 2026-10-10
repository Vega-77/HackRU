import json

import cv2
import numpy as np

from replay_tracking import replay


def test_replay_preserves_irregular_ids_timestamps_and_scores_the_selected_target(tmp_path):
    frames = []
    for index, (frame_id, timestamp, x) in enumerate([(0, .2, 80), (2, .7, 80), (7, 1.9, 250)]):
        image = np.full((180, 320, 3), 90, np.uint8)
        cv2.circle(image, (x, 90), 12, (180, 180, 180), -1)
        name = f"{index}.jpg"
        cv2.imwrite(str(tmp_path / name), image)
        frames.append({"file": name, "frame_id": frame_id, "timestamp": timestamp,
                       "truth": {"x": x, "y": 90, "diameter": 24}})
    manifest = tmp_path / "replay.json"
    manifest.write_text(json.dumps({"config": {"target_px": {"x": 80, "y": 90},
        "target_bbox": {"x": 64, "y": 74, "w": 32, "h": 32}}, "frames": frames}))
    result = replay(manifest)
    assert [r["frame_id"] for r in result["frames"]] == [0, 2, 7]
    assert [r["timestamp"] for r in result["frames"]] == [.2, .7, 1.9]
    assert result["metrics"]["correct_target_frames"] == 2
    assert result["metrics"]["wrong_target_frames"] == 0
    assert result["frames"][2]["tracked"]
