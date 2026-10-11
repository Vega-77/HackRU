"""Profile the reconstructed camera fixture without inventing physics truth.

Run from the repo root: backend/.venv/bin/python backend/benchmark_tracking.py
The manifest times belong to a screen recording, not sensor capture times.
"""

import json
from pathlib import Path
import time

import cv2
import numpy as np

import app as server
from cv_engine.preprocess import preprocess_frame, encode_jpeg


def replay():
    fixture = Path(__file__).parent / 'tests/fixtures/gray_ball_oct11'
    manifest = json.loads((fixture / 'manifest.json').read_text())
    timings = {k: [] for k in ['decode', 'preprocess', 'tracking', 'physics', 'total']}
    initialization = []
    runs = []
    for _ in range(3):
        cv2.setRNGSeed(0)
        pipe = server.TrackingPipeline()
        pipe.apply_config({**manifest['config'], 'mode': 'free_fall', 'px_per_m': 426.7})
        physics = server.PhysicsSession()
        found = visible = wrong = absent_false = 0
        flagged = []
        errors = []
        for item in manifest['frames']:
            image = cv2.imread(str(fixture / item['file']))
            if item['frame_id'] == 0:
                started = time.perf_counter()
                ack = pipe.initialize(preprocess_frame(image, 0, item['timestamp']))
                initialization.append((time.perf_counter() - started) * 1000)
                assert ack['status'] == 'initialized'
                continue
            frame = server.IncomingFrame(encode_jpeg(image),
                {'frame_id': item['frame_id'], 'timestamp': item['timestamp']}, 0)
            started = time.perf_counter()
            result, _ = server._process_with_physics(frame, pipe, physics)
            timings['total'].append((time.perf_counter() - started) * 1000)
            for key, value in result['timing_ms'].items(): timings[key].append(value)
            truth = item.get('truth')
            if truth is None: continue
            target = next((o for o in result['objects'] if o['target']), None)
            if not truth.get('visible', True):
                wrong += target is not None
                absent_false += target is not None
                if target is not None: flagged.append({'file': item['file'], 'reason': 'absent_detection'})
            else:
                visible += 1
                if target is not None:
                    error = np.hypot(target['pixel']['x'] - truth['x'], target['pixel']['y'] - truth['y'])
                    wrong += error > truth['diameter'] / 4
                    if error > truth['diameter'] / 4:
                        flagged.append({'file': item['file'], 'reason': 'center_outside_tolerance', 'error_px': round(float(error), 3)})
                    found += error <= truth['diameter'] / 4
                    errors.append(error)
        runs.append({'correct': int(found), 'visible': visible, 'flagged': int(wrong),
                     'absent_false': int(absent_false), 'flagged_frames': flagged,
                     'center_rms_px': round(float(np.sqrt(np.mean(np.square(errors)))), 3)})
        pipe.close()
    return {'fixture': 'reconstructed gray_ball_oct11, JPEG quality 70, local CPU',
            'runs': runs, 'initialization_ms': [round(v, 3) for v in initialization],
            'timing_ms': {k: {'median': round(float(np.median(v)), 3),
                             'p95': round(float(np.percentile(v, 95)), 3)} for k, v in timings.items()}}


if __name__ == '__main__':
    print(json.dumps(replay(), indent=2))
