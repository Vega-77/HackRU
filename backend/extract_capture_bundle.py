"""Extract a browser .hop.json capture into exact JPEGs and a replay manifest."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import math
from pathlib import Path


def extract_capture(path: Path, destination: Path) -> Path:
    bundle = json.loads(path.read_text(encoding="utf-8"))
    if bundle.get("format") != "hands-on-physics-capture" or bundle.get("version") != 1:
        raise ValueError("Expected HandsOnPhysics capture format version 1")
    if not isinstance(bundle.get("config"), dict) or not bundle.get("frames"):
        raise ValueError("Capture needs configuration and frames")
    decoded = []
    previous_id, previous_time = -1, -math.inf
    for index, item in enumerate([bundle["selection"], *bundle["frames"]]):
        frame_id, timestamp = item["frame_id"], item["timestamp"]
        if (type(frame_id) is not int or frame_id <= previous_id
                or not isinstance(timestamp, (int, float))
                or not math.isfinite(timestamp) or timestamp <= previous_time):
            raise ValueError("Frame IDs and capture timestamps must increase")
        try:
            jpeg = base64.b64decode(item["jpeg_base64"], validate=True)
        except (binascii.Error, TypeError) as error:
            raise ValueError("Invalid JPEG base64") from error
        if not jpeg.startswith(b"\xff\xd8") or not jpeg.endswith(b"\xff\xd9"):
            raise ValueError("Frame is not a JPEG")
        filename = "selection.jpg" if index == 0 else f"frame_{index:04d}.jpg"
        metadata = {k: v for k, v in item.items() if k != "jpeg_base64"}
        decoded.append((filename, jpeg, {**metadata, "file": filename}))
        previous_id, previous_time = frame_id, timestamp
    # Validate before creating the output; never overwrite a previous capture.
    destination.mkdir(parents=True, exist_ok=False)
    for filename, jpeg, _ in decoded:
        (destination / filename).write_bytes(jpeg)
    manifest = destination / "manifest.json"
    manifest.write_text(json.dumps({
        "config": bundle["config"], "frames": [row for _, _, row in decoded],
    }, indent=2), encoding="utf-8")
    (destination / "analysis.json").write_text(
        json.dumps(bundle.get("analysis", {}), indent=2), encoding="utf-8")
    (destination / "capture.json").write_text(json.dumps({
        k: v for k, v in bundle.items() if k not in ("selection", "frames", "analysis")
    }, indent=2), encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("destination", type=Path, help="new directory for this capture")
    args = parser.parse_args()
    print(extract_capture(args.capture, args.destination))


if __name__ == "__main__":
    main()
