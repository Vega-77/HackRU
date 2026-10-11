"""A recorded sequence uses the live protocol, but never queues two images.

These generated camera JPEGs test capture-time physics through the actual
selection/tracker/WebSocket pipeline. They are not a real-camera benchmark.
"""

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

import app as server
from cv_engine.preprocess import encode_jpeg


def gray_ball(y):
    image = np.full((240, 320, 3), 45, np.uint8)
    cv2.circle(image, (140, round(y)), 13, (160, 160, 160), -1)
    cv2.circle(image, (136, round(y) - 4), 4, (190, 190, 190), -1)
    return encode_jpeg(image)


def test_saved_60fps_gray_fall_preserves_every_frame_and_derives_acceleration():
    with TestClient(server.app).websocket_connect('/ws/frames') as ws:
        ws.send_json({'type': 'config', 'mode': 'free_fall', 'mass_kg': .1,
                      'px_per_m': 220, 'target_px': {'x': 140, 'y': 30},
                      'target_bbox': {'x': 124, 'y': 14, 'w': 32, 'h': 32},
                      'frame_size': {'w': 320, 'h': 240}, 'initialization_required': True})
        ws.send_json({'type': 'initialize', 'frame_id': 0, 'timestamp': 1})
        ws.send_bytes(gray_ball(30))
        ack = ws.receive_json()
        assert ack['status'] == 'initialized' and not ack['tracked']
        results = []
        ids = set()
        # Frames were already captured; server arrival need not be 60 FPS.
        for i in range(25):
            t = i / 60
            y = 30 + 4.905 * 220 * t * t
            ws.send_json({'frame_id': i + 1, 'timestamp': 3 + t})
            ws.send_bytes(gray_ball(y))
            state = ws.receive_json()
            assert state['frame_id'] == i + 1
            assert state['timestamp'] == pytest.approx(3 + t)
            assert state['tracked'], (i, state.get('tracking_status'))
            assert state['pixel'] == pytest.approx({'x': 140, 'y': y}, abs=2)
            assert state['position']['y'] == pytest.approx((240 - y) / 220, abs=2 / 220)
            ids.add(state['target_id'])
            results.append(state)
        assert len(ids) == 1
        assert results[-1]['stats']['dropped'] == 0
        assert results[-1]['velocity']['y'] == pytest.approx(-9.81 * .4, abs=.15)
        assert results[-1]['acceleration']['y'] == pytest.approx(-9.81, abs=1)
        assert results[-1]['physics_quality']['span_s'] <= .35
        assert results[-1]['physics_quality']['samples'] > 12


def test_stage_timings_are_nonnegative_and_do_not_replace_capture_time():
    frame = server.IncomingFrame(gray_ball(30), {'frame_id': 42, 'timestamp': 6.25}, 999)
    pipe = server.TrackingPipeline()
    pipe.apply_config({'mode': 'free_fall', 'px_per_m': 220})
    result, _ = server._process_with_physics(frame, pipe, server.PhysicsSession())
    assert result['timestamp'] == 6.25 and result['timestamp_source'] == 'capture'
    assert set(result['timing_ms']) == {'decode', 'preprocess', 'tracking', 'physics'}
    assert all(v >= 0 for v in result['timing_ms'].values())
    pipe.close()
