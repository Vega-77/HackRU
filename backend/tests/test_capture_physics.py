"""Capture-time physics and transport regressions for the October 11 failures."""

import threading

import cv2
import numpy as np
import pytest
from fastapi.testclient import TestClient

import app as server
from cv_engine.preprocess import encode_jpeg
from physics_engine import PhysicsSession


def observation(t, y, *, score=1.0, visible=True, timestamp_source='capture'):
    return {
        'frame_id': round(t * 1000), 'timestamp': t, 'timestamp_source': timestamp_source,
        'tracked': visible,
        'calibration': {'method': 'manual', 'settings': {'px_per_m': 426.7}},
        'objects': [{'id': 1, 'target': True, 'score': score,
                     'pixel': {'x': 100, 'y': (2 - y) * 426.7},
                     'position': {'x': .5, 'y': y}}] if visible else [],
    }


@pytest.mark.parametrize('acceleration', [-9.81, -3.4, 0.0])
def test_irregular_dropped_capture_samples_recover_measured_acceleration(acceleration):
    session = PhysicsSession()
    times = [0, .033, .071, .104, .171, .208, .251, .29, .337, .379]
    for t in times:
        y = 2 + .3 * t + .5 * acceleration * t * t
        state = session.process_frame(observation(t, y), {'mode': 'free_fall'})
    assert state['position']['y'] == pytest.approx(y)
    assert state['velocity']['y'] == pytest.approx(.3 + acceleration * t, abs=1e-7)
    assert state['acceleration']['y'] == pytest.approx(acceleration, abs=1e-7)
    assert state['physics_quality']['acceleration_std_mps2'] < 2
    gravity = next(f for f in state['forces'] if f['name'] == 'gravity')
    assert gravity['y'] == pytest.approx(-.981)


def test_window_excludes_held_ball_once_sufficient_fall_is_observed():
    session = PhysicsSession()
    for index in range(44):
        t = index / 30
        falling_time = max(0, t - 1)
        state = session.process_frame(observation(t, 2 - 4.905 * falling_time**2),
                                      {'mode': 'free_fall'})
    assert state['physics_quality']['span_s'] <= .35
    assert state['acceleration']['y'] == pytest.approx(-9.81, abs=1e-6)


@pytest.mark.parametrize('fps', [30, 60])
def test_high_rate_drop_with_pixel_jitter_still_measures_gravity(fps):
    # A 1 m drop at 220 px/m, tracked at 30 fps with 2 px of jitter. A
    # seven-sample window spans 0.2 s, and the uncertainty gate then withheld
    # acceleration on most of the fall.
    rng = np.random.default_rng(3)
    session = PhysicsSession()
    noise = 2 / 220
    measured = []
    for index in range(fps):
        t = index / fps
        fall = max(0.0, t - .3)
        y = 1 - 4.905 * fall**2 + rng.normal(0, noise)
        state = session.process_frame(
            {**observation(t, y), 'calibration': {'method': 'manual', 'settings': {'px_per_m': 220}},
             'objects': [{'id': 1, 'target': True, 'score': 1.0, 'pixel': {'x': 100, 'y': (2 - y) * 220},
                          'position': {'x': .5 + rng.normal(0, noise), 'y': y}}]},
            {'mode': 'free_fall'})
        if fall >= .35 and y > 0:
            measured.append(state.get('acceleration', {}).get('y'))
            assert state['physics_quality']['span_s'] <= .35
    assert measured and all(a is not None for a in measured)
    assert np.median(measured) == pytest.approx(-9.81, abs=2)


def test_sparse_noisy_and_missing_observations_withhold_acceleration():
    session = PhysicsSession()
    for t in [0, .194, .39, .59]:  # Log's 5 FPS sequence, too few samples per time window.
        state = session.process_frame(observation(t, 2 - 4.905 * t*t), {'mode': 'free_fall'})
        assert 'acceleration' not in state
    assert state['physics_quality']['reason'] == 'insufficient_samples'

    session.reset()
    for index in range(7):
        t = index / 30
        state = session.process_frame(observation(t, 2 + (-1)**index * .08), {'mode': 'free_fall'})
    assert 'acceleration' not in state
    assert state['physics_quality']['reason'] == 'acceleration_uncertain'
    lost = session.process_frame(observation(.24, 0, visible=False), {'mode': 'free_fall'})
    assert not lost['tracked'] and 'velocity' not in lost and 'acceleration' not in lost
    recovered = session.process_frame(observation(1, 1), {'mode': 'free_fall'})
    assert 'velocity' not in recovered and recovered['physics_quality']['samples'] == 1


def test_receive_clock_cannot_supply_physics_time():
    session = PhysicsSession()
    for t in [100, 100.1, 100.3, 100.4]:
        state = session.process_frame(observation(t, 1, timestamp_source='server_receive'),
                                      {'mode': 'free_fall'})
        assert state['tracked']
        assert 'velocity' not in state and 'acceleration' not in state
        assert state['physics_quality']['reason'] == 'capture_timestamp_missing'


def test_slow_processor_drops_pending_frames_and_preserves_capture_time(monkeypatch):
    entered, release, received = threading.Event(), threading.Event(), threading.Event()
    original = server._process_with_physics
    class ObservedSlot(server.LatestFrameSlot):
        def put(self, item):
            super().put(item)
            if self.received == 6:
                received.set()
    monkeypatch.setattr(server, 'LatestFrameSlot', ObservedSlot)
    def slow(frame, pipeline, physics):
        if frame.meta['frame_id'] == 0:
            entered.set()
            assert release.wait(3)
        return original(frame, pipeline, physics)
    monkeypatch.setattr(server, '_process_with_physics', slow)
    image = np.full((180, 320, 3), 90, np.uint8)
    cv2.circle(image, (80, 90), 12, (0, 0, 255), -1)
    jpeg = encode_jpeg(image)
    with TestClient(server.app).websocket_connect('/ws/frames') as ws:
        ws.send_json({'type': 'config', 'mode': 'free_fall', 'detector': 'color', 'px_per_m': 100})
        ws.send_json({'frame_id': 0, 'timestamp': 10})
        ws.send_bytes(jpeg)
        try:
            assert entered.wait(3)
            for index in range(1, 6):
                ws.send_json({'frame_id': index, 'timestamp': 10 + index / 30})
                ws.send_bytes(jpeg)
            assert received.wait(3)
        finally:
            release.set()
        first, latest = ws.receive_json(), ws.receive_json()
        assert [first['frame_id'], latest['frame_id']] == [0, 5]
        assert latest['timestamp'] == pytest.approx(10 + 5 / 30)
        assert latest['timestamp_source'] == 'capture'
        assert latest['stats']['dropped'] == 4
        assert latest['queue_ms'] >= 0 and latest['process_ms'] >= 0
        assert set(latest['timing_ms']) == {'decode', 'preprocess', 'tracking', 'physics'}
        assert all(v >= 0 for v in latest['timing_ms'].values())
        assert sum(latest['timing_ms'].values()) <= latest['process_ms'] + .1
        ws.send_json({'frame_id': 6, 'timestamp': 10.1})
        ws.send_bytes(jpeg)
        assert 'strictly increase' in ws.receive_json()['message']
        ws.send_json({'frame_id': 7, 'timestamp': 10.3})
        ws.send_bytes(jpeg)
        assert ws.receive_json()['frame_id'] == 7
