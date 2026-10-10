"""Replay transmitted JPEGs and capture timestamps without a live camera."""

from __future__ import annotations

import argparse
import json
import math
import time
from pathlib import Path

import cv2

from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, preprocess_frame


def replay(path: Path) -> dict:
    manifest = json.loads(path.read_text())
    cv2.setNumThreads(1)
    cv2.setRNGSeed(0)
    pipe = TrackingPipeline()
    pipe.apply_config({**manifest["config"], "type": "config", "debug_tracking": True})
    rows = []
    previous_id, previous_time = -1, -math.inf
    visible = correct = wrong = missing = 0
    errors = []
    start = time.perf_counter()
    try:
        for item in manifest["frames"]:
            frame_id, timestamp = item["frame_id"], item["timestamp"]
            if frame_id <= previous_id or not math.isfinite(timestamp) or timestamp <= previous_time:
                raise ValueError("frame IDs and capture timestamps must increase")
            previous_id, previous_time = frame_id, timestamp
            frame = preprocess_frame(decode_jpeg((path.parent / item["file"]).read_bytes()),
                                     frame_id, timestamp)
            result = pipe(frame)
            target = next((o for o in result["objects"] if o["target"]), None)
            truth = item.get("truth")
            if truth is not None:
                if truth.get("visible", True):
                    visible += 1
                    if target is not None:
                        error = math.hypot(target["pixel"]["x"] - truth["x"],
                                           target["pixel"]["y"] - truth["y"])
                        errors.append(error)
                        if error <= truth["diameter"] * .25:
                            correct += 1
                        else:
                            wrong += 1
                    else:
                        missing += 1
                elif target is not None:
                    wrong += 1
            rows.append({"frame_id": frame_id, "timestamp": timestamp, **result})
    finally:
        pipe.close()
    elapsed = time.perf_counter() - start
    return {"frames": rows, "metrics": {
        "visible_labeled_frames": visible, "correct_target_frames": correct,
        "wrong_target_frames": wrong, "missed_visible_frames": missing,
        "recall": correct / visible if visible else None,
        "precision": correct / (correct + wrong) if correct + wrong else None,
        "center_error_rms_px": math.sqrt(sum(e * e for e in errors) / len(errors)) if errors else None,
        "processing_fps": len(rows) / elapsed if elapsed else None,
    }}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--out", type=Path, help="optional report path; images are never copied")
    args = parser.parse_args()
    report = replay(args.manifest)
    if args.out:
        args.out.write_text(json.dumps(report, indent=2))
    print(json.dumps(report["metrics"], indent=2))


if __name__ == "__main__":
    main()
