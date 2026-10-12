"""Replay a .hop.json through the current CV/physics code using capture times."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import time
from pathlib import Path

import cv2
import numpy as np

from app import IncomingFrame, WORKING_WIDTH, _process_with_physics
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, preprocess_frame
from physics_engine import PhysicsSession


def analyze_capture(path: Path) -> dict:
    raw = path.read_bytes()
    bundle = json.loads(raw)
    if bundle.get("format") != "hands-on-physics-capture" or bundle.get("version") != 1:
        raise ValueError("Expected HandsOnPhysics capture format version 1")
    if not bundle.get("frames"):
        raise ValueError("Capture needs frames")
    cv2.setNumThreads(1)
    cv2.setRNGSeed(0)
    pipe, physics = TrackingPipeline(), PhysicsSession()
    pipe.apply_config(bundle["config"])
    rows, durations = [], []
    try:
        selected = bundle["selection"]
        ack = pipe.initialize(preprocess_frame(
            decode_jpeg(base64.b64decode(selected["jpeg_base64"], validate=True)),
            selected["frame_id"], selected["timestamp"], WORKING_WIDTH, meta=selected))
        if ack["status"] != "initialized":
            raise ValueError(f"Selection initialization failed: {ack}")
        last_id, last_time = selected["frame_id"], selected["timestamp"]
        for item in bundle["frames"]:
            if (item["frame_id"] <= last_id or not np.isfinite(item["timestamp"])
                    or item["timestamp"] <= last_time):
                raise ValueError("Frame IDs and capture timestamps must increase")
            metadata = {k: v for k, v in item.items() if k != "jpeg_base64"}
            incoming = IncomingFrame(base64.b64decode(item["jpeg_base64"], validate=True),
                                     metadata, time.time())
            start = time.perf_counter()
            state, _ = _process_with_physics(incoming, pipe, physics)
            elapsed = (time.perf_counter() - start) * 1000
            durations.append(elapsed)
            rows.append({**state, "replay_worker_ms": elapsed})
            last_id, last_time = item["frame_id"], item["timestamp"]
    finally:
        pipe.close()
    return {
        "source": path.name, "source_sha256": hashlib.sha256(raw).hexdigest(),
        "config": bundle["config"], "ruler": bundle["ruler"], "capture": bundle["capture"],
        "metrics": {
            "frames": len(rows), "tracked": sum(row["tracked"] for row in rows),
            "worker_median_ms": float(np.median(durations)),
            "worker_p95_ms": float(np.percentile(durations, 95)),
        },
        "observations": rows,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    result = analyze_capture(args.capture)
    args.out.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result["metrics"], indent=2))


if __name__ == "__main__":
    main()
