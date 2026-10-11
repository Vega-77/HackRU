"""Reconstruct the visible camera pixels from the supplied screen recording."""

import argparse
import hashlib
import json
from pathlib import Path

import cv2
import numpy as np


def extract(recording, destination):
    destination.mkdir(parents=True, exist_ok=True)
    capture = cv2.VideoCapture(str(recording))
    rows = []
    for index, timestamp in enumerate((20, 45, 58, 65, 68.5, 68.6, 68.7, 68.8, 69.1)):
        capture.set(cv2.CAP_PROP_POS_MSEC, timestamp * 1000)
        ok, image = capture.read()
        if not ok or image.shape[:2] != (1912, 2940):
            raise ValueError('Expected the original 2940 × 1912 recording')
        graphics = np.zeros(image.shape[:2], np.uint8)
        if index == 0:
            cv2.circle(graphics, (1735, 1156), 60, 255, -1)
            cv2.rectangle(graphics, (1447, 938), (2023, 1382), 255, 6)
            camera = (80, 354, 2115, 1878)
        else:
            camera = (0, 242, 2218, 1912)
            graphics[242:360, :2218] = 255
            if timestamp == 45:
                cv2.circle(graphics, (1754, 1286), 285, 255, 10)
                graphics[1260:1610, 1690:1810] = 255
            if timestamp >= 58:
                graphics[1460:1565, 875:1370] = 255
        image = cv2.inpaint(image, graphics, 5, cv2.INPAINT_TELEA)
        left, top, right, bottom = camera
        frame = np.zeros((180, 320, 3), np.uint8)
        frame[:, 40:280] = cv2.resize(image[top:bottom, left:right], (240, 180))
        filename = f'{timestamp:g}.png'
        cv2.imwrite(str(destination / filename), frame)
        rows.append({'file': filename, 'frame_id': index, 'timestamp': timestamp})
    capture.release()
    manifest = {
        'source_sha256': hashlib.sha256(recording.read_bytes()).hexdigest(),
        'config': {'target_px': {'x': 235, 'y': 95},
                   'target_bbox': {'x': 201, 'y': 69, 'w': 68, 'h': 52},
                   'frame_size': {'w': 320, 'h': 180}},
        'frames': rows,
    }
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('recording', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    extract(args.recording, args.destination)
