"""Reconstruct the visible camera regions in the October 11 screen recording.

These are screen pixels, not the JPEGs sent to the backend. Keep the actual
decoded video PTS: seeking this variable-rate MOV can overshoot the request.
"""

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np


TIMES = (13.28, 17.7, 22.13, 26.55, 30, 30.1, 30.2, 30.3, 30.4, 30.5, 30.6,
         30.7, 30.8, 30.9, 31.1, 31.2, 31.3, 31.4, 35.4, 39.83, 44.26, 45,
         46, 47, 48, 49, 50)
# Approximate manual centers in the reconstructed 320 x 180 coordinate system.
CENTERS = {17.7: (212, 54), 22.13: (207, 63), 26.55: (218, 69),
           30: (215, 60), 30.1: (214, 56), 30.2: (213, 54),
           30.3: (213, 50), 30.4: (212, 47), 30.5: (217, 50),
           30.6: (220, 112), 35.4: (247, 55), 39.83: (216, 46),
           44.26: (267, 76), 45: (199, 68)}
ABSENT = {31.1, 31.2, 31.3, 31.4, 46, 47, 48, 49, 50}


def extract(recording: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    capture = cv2.VideoCapture(str(recording))
    rows = []
    for index, requested in enumerate(TIMES):
        capture.set(cv2.CAP_PROP_POS_MSEC, requested * 1000)
        ok, image = capture.read()
        if not ok or image.shape[:2] != (1912, 2940):
            raise ValueError("Expected the original 2940 x 1912 recording")
        timestamp = capture.get(cv2.CAP_PROP_POS_MSEC) / 1000
        if rows and timestamp <= rows[-1]["timestamp"]:
            raise ValueError("Decoded PTS did not increase; inspect this decoder's seeking")
        left, top, right, bottom = ((339, 695, 1896, 1792) if index == 0
                                    else (0, 310, 2218, 1912))
        if index == 0:
            graphics = np.zeros(image.shape[:2], np.uint8)
            cv2.rectangle(graphics, (1348, 846), (1635, 1104), 255, 8)
            cv2.rectangle(graphics, (1340, 777), (1572, 838), 255, -1)
            cv2.line(graphics, (728, 1079), (1508, 1079), 255, 8)
            for endpoint in ((1508, 1079), (728, 1079)):
                cv2.circle(graphics, endpoint, 24, 255, -1)
            image = cv2.inpaint(image, graphics, 5, cv2.INPAINT_TELEA)
        # Invert BoxFit.cover. Preserve the unknown side strips as black.
        scale = (bottom - top) / 180
        offset = (320 * scale - (right - left)) / 2
        transform = np.float32([[1 / scale, 0, (offset - left) / scale],
                               [0, 1 / scale, -top / scale]])
        frame = cv2.warpAffine(image, transform, (320, 180), flags=cv2.INTER_AREA)
        frame[:, :int(np.ceil(offset / scale))] = 0
        frame[:, int(np.floor(320 - offset / scale)):] = 0
        if index:
            frame[:12] = 0  # top controls; live tracking graphics remain
        name = f"{requested:g}.png"
        cv2.imwrite(str(destination / name), frame)
        row = {"file": name, "frame_id": index, "timestamp": timestamp,
               "requested_time": requested}
        if requested in CENTERS:
            x, y = CENTERS[requested]
            row["truth"] = {"x": x, "y": y, "diameter": 40 if requested == 30.6 else 36}
        elif requested in ABSENT:
            row["truth"] = {"visible": False}
        elif index:
            row["annotation"] = "Partial ball at frame edge; center not labeled"
        rows.append(row)
    capture.release()
    digest = hashlib.sha256()
    with recording.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    manifest = {"source_sha256": digest.hexdigest(),
                "config": {"target_px": {"x": 221.5, "y": 46},
                           "target_bbox": {"x": 198, "y": 25, "w": 47, "h": 42},
                           "frame_size": {"w": 320, "h": 180}},
                "frames": rows}
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recording", type=Path)
    parser.add_argument("destination", type=Path)
    arguments = parser.parse_args()
    extract(arguments.recording, arguments.destination)
