import cv2
import numpy as np
import pytest

from cv_engine.acquisition import box_iou, propose_region
from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import encode_jpeg, decode_jpeg, preprocess_frame


def scene(color=(180, 180, 180), center=(80, 90), radius=12):
    image = np.full((180, 320, 3), 90, np.uint8)
    cv2.circle(image, center, radius, color, -1)
    return image


@pytest.mark.parametrize('color', [(180, 180, 180), (0, 0, 255), (240, 240, 240), (20, 20, 20)])
@pytest.mark.parametrize('tap', [(80, 90), (90, 90)])
def test_neutral_and_red_taps_select_actual_ball_not_nearby_texture(color, tap):
    image = scene(color)
    cv2.rectangle(image, (150, 30), (190, 65), (240, 240, 240), -1)
    proposal = propose_region(decode_jpeg(encode_jpeg(image)), tap)
    assert proposal['status'] == 'proposed'
    box = proposal['bbox']
    assert box_iou(tuple(box[k] for k in ('x', 'y', 'w', 'h')), (68, 78, 25, 25)) > .7
    assert box['x'] <= tap[0] < box['x'] + box['w']
    assert box['y'] <= tap[1] < box['y'] + box['h']
    assert box['x'] + box['w'] < 150


@pytest.mark.parametrize('image,tap', [
    (np.full((180, 320, 3), 90, np.uint8), (80, 90)),
    (scene(), (140, 90)),
    (scene((95, 95, 95)), (80, 90)),
])
def test_empty_or_unclear_boundary_requests_manual_box(image, tap):
    result = propose_region(image, tap)
    assert result['status'] == 'manual_required'
    assert result['bbox'] is None


def test_nested_boundaries_require_confirmation_by_manual_selection():
    image = scene(radius=25)
    cv2.circle(image, (80, 90), 12, (30, 30, 30), -1)
    result = propose_region(image, (80, 90))
    assert result['status'] == 'manual_required'
    assert result['reason'] == 'ambiguous_boundary'


@pytest.mark.parametrize('destination', [(250, 90), (80, 145)])
def test_tap_initialization_then_motion_preserves_selected_identity(destination):
    pipe = TrackingPipeline()
    pipe.apply_config({'target_px': {'x': 80, 'y': 90}, 'debug_tracking': True})
    ack = pipe.initialize(preprocess_frame(scene(), 0, 0))
    assert ack['status'] == 'initialized' and not ack['tracked']
    original = pipe._manual.original.copy()
    image = scene(center=destination)
    cv2.circle(image, (160, 40), 12, (0, 0, 255), -1)
    result = pipe(preprocess_frame(image, 1, .2))
    target = next(o for o in result['objects'] if o['target'])
    assert target['source'] == 'manual'
    assert target['pixel'] == pytest.approx(dict(zip(('x', 'y'), destination)), abs=2)
    np.testing.assert_array_equal(pipe._manual.original, original)


def test_failed_automatic_initialization_can_retry_with_manual_box():
    pipe = TrackingPipeline()
    pipe.apply_config({'target_px': {'x': 80, 'y': 90}})
    ack = pipe.initialize(preprocess_frame(np.full((180, 320, 3), 90, np.uint8), 0))
    assert ack['status'] == 'failed' and not ack['tracked']
    pipe.apply_config({'target_bbox': {'x': 64, 'y': 74, 'w': 32, 'h': 32}})
    ack = pipe.initialize(preprocess_frame(scene(), 1))
    assert ack['status'] == 'initialized' and not ack['tracked']
    result = pipe(preprocess_frame(scene(), 2))
    assert next(o for o in result['objects'] if o['target'])['pixel'] == pytest.approx({'x': 80, 'y': 90}, abs=1)


def test_initialization_rejects_image_from_a_different_coordinate_system():
    pipe = TrackingPipeline()
    pipe.apply_config({'target_px': {'x': 80, 'y': 90}, 'frame_size': {'w': 640, 'h': 360}})
    result = pipe.initialize(preprocess_frame(scene(), 0))
    assert result['status'] == 'failed' and result['reason'] == 'selection_image_size_mismatch'
    assert pipe._manual.original is None
