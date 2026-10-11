"""Camera-scene regressions reconstructed from the reported screen recording."""

import json
from pathlib import Path

import cv2
import numpy as np
import pytest

from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import preprocess_frame


FIXTURE = Path(__file__).parent / 'fixtures' / 'gray_ball_recording'


def selected():
    cv2.setRNGSeed(0)
    pipe = TrackingPipeline()
    pipe.apply_config({**json.loads((FIXTURE / 'manifest.json').read_text())['config'],
                       'debug_tracking': True})
    result = pipe.initialize(preprocess_frame(cv2.imread(str(FIXTURE / '20.png')), 0, 20))
    assert result['status'] == 'initialized' and not result['tracked']
    assert pipe._manual.round_reference is not None
    mask = pipe._manual.foreground
    truth = np.zeros_like(mask)
    cv2.ellipse(truth, (32, 24), (24, 23), 0, 0, 360, 1, -1)
    assert np.count_nonzero(mask & truth) / np.count_nonzero(mask | truth) > .8
    return pipe


@pytest.mark.parametrize('timestamp,center,diameter', [(45, (136, 72), 52), (58, (131, 44), 46),
                                                      (65, (156, 60), 32)])
def test_reacquires_actual_ball_after_background_and_pose_change(timestamp, center, diameter):
    pipe = selected()
    original = pipe._manual.original.copy()
    # Force recovery rather than relying on the last accepted position.
    assert not pipe(preprocess_frame(np.zeros((180, 320, 3), np.uint8), 1, 21))['tracked']
    result = pipe(preprocess_frame(cv2.imread(str(FIXTURE / f'{timestamp}.png')), 2, timestamp))
    target = next(o for o in result['objects'] if o['target'])
    assert target['pixel'] == pytest.approx(dict(zip(('x', 'y'), center)), abs=diameter / 4)
    assert target['source'] == 'manual'
    box = target['bbox']
    assert box['x'] <= center[0] <= box['x'] + box['w']
    assert box['y'] <= center[1] <= box['y'] + box['h']
    assert result['tracking_debug']['global']
    np.testing.assert_array_equal(pipe._manual.original, original)


def test_local_wrist_match_is_rejected_before_full_frame_ball_recovery():
    pipe = selected()
    result = pipe(preprocess_frame(cv2.imread(str(FIXTURE / '45.png')), 1, 45))
    target = next(o for o in result['objects'] if o['target'])
    assert target['pixel'] == pytest.approx({'x': 136, 'y': 72}, abs=13)
    assert target['pixel']['x'] < 170
    assert result['tracking_debug']['global']


def test_blurred_release_never_switches_to_face_wrist_or_ceiling():
    pipe = selected()
    frames = [(45, (136, 72)), (65, (156, 60)), (68.5, (240, 75)),
              (68.6, (240, 75)), (68.7, (240, 80)), (68.8, (240, 130)), (69.1, None)]
    detections = []
    for index, (timestamp, center) in enumerate(frames, 1):
        result = pipe(preprocess_frame(cv2.imread(str(FIXTURE / f'{timestamp:g}.png')), index, timestamp))
        target = next((o for o in result['objects'] if o['target']), None)
        if center is None:
            assert target is None
        elif target is not None:
            assert target['pixel'] == pytest.approx(dict(zip(('x', 'y'), center)), abs=13)
            detections.append(timestamp)
    assert 45 in detections and 65 in detections
    assert 68.7 in detections
