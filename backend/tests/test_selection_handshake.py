from fastapi.testclient import TestClient
import pytest

from app import app
from cv_engine.acquisition import box_iou
from cv_engine.preprocess import encode_jpeg
from test_acquisition import scene


def send_image(ws, kind, frame_id, image, **meta):
    ws.send_json({'type': kind, 'frame_id': frame_id, 'timestamp': frame_id * .2,
                  'selection_id': 'test-selection', **meta})
    ws.send_bytes(encode_jpeg(image))


def test_acquisition_proposes_region_from_exact_image_without_claiming_tracking():
    with TestClient(app).websocket_connect('/ws/frames') as ws:
        send_image(ws, 'acquire', 0, scene(), target_px={'x': 80, 'y': 90})
        ack = ws.receive_json()
        assert ack['type'] == 'acquisition' and ack['selection_id'] == 'test-selection'
        assert not ack['tracked'] and ack['status'] == 'proposed'
        assert box_iou(tuple(ack['bbox'][k] for k in ('x', 'y', 'w', 'h')), (68, 78, 25, 25)) > .7


def test_initialization_image_cannot_be_overwritten_by_immediate_live_frame():
    with TestClient(app).websocket_connect('/ws/frames') as ws:
        ws.send_json({'type': 'config', 'target_px': {'x': 80, 'y': 90},
                      'initialization_required': True})
        send_image(ws, 'initialize', 0, scene())
        send_image(ws, 'frame', 1, scene(center=(250, 90)))
        ack = ws.receive_json()
        assert ack['type'] == 'initialization' and ack['frame_id'] == 0
        assert ack['status'] == 'initialized' and not ack['tracked']
        assert ack['bbox']['x'] < 80 < ack['bbox']['x'] + ack['bbox']['w']
        result = ws.receive_json()
        target = next(o for o in result['objects'] if o['target'])
        assert target['pixel']['x'] == pytest.approx(250, abs=1)


def test_failed_initialization_blocks_live_frames_and_allows_retry():
    with TestClient(app).websocket_connect('/ws/frames') as ws:
        ws.send_json({'type': 'config', 'target_px': {'x': 140, 'y': 90},
                      'initialization_required': True})
        send_image(ws, 'initialize', 0, scene())
        assert ws.receive_json()['status'] == 'failed'
        send_image(ws, 'frame', 1, scene())
        assert ws.receive_json()['type'] == 'error'
        ws.send_json({'type': 'config', 'target_px': {'x': 80, 'y': 90}})
        send_image(ws, 'initialize', 2, scene())
        assert ws.receive_json()['status'] == 'initialized'
        send_image(ws, 'frame', 3, scene())
        result = ws.receive_json()
        assert next(o for o in result['objects'] if o['target'])['pixel']['x'] == pytest.approx(80, abs=1)


def test_invalid_image_initialization_acknowledges_failure():
    with TestClient(app).websocket_connect('/ws/frames') as ws:
        ws.send_json({'type': 'initialize', 'frame_id': 0, 'selection_id': 'bad-image'})
        ws.send_bytes(b'invalid jpeg')
        ack = ws.receive_json()
        assert ack['type'] == 'initialization' and ack['status'] == 'failed'
        assert ack['selection_id'] == 'bad-image' and not ack['tracked']


def test_initialization_requires_a_newer_capture_before_confirmation():
    with TestClient(app).websocket_connect('/ws/frames') as ws:
        ws.send_json({'type': 'config', 'target_px': {'x': 80, 'y': 90},
                      'initialization_required': True})
        send_image(ws, 'initialize', 0, scene(), timestamp=5)
        assert ws.receive_json()['status'] == 'initialized'
        send_image(ws, 'frame', 1, scene(), timestamp=5)
        assert 'strictly increase' in ws.receive_json()['message']
        send_image(ws, 'frame', 2, scene(center=(100, 90)), timestamp=5.1)
        result = ws.receive_json()
        assert result['tracked']
        target = next(o for o in result['objects'] if o['target'])
        assert target['pixel']['x'] == pytest.approx(100, abs=1)
