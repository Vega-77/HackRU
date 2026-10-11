"""Identity regression tests for a ball moving away from its selection background."""

import cv2
import numpy as np
import pytest

from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, encode_jpeg, preprocess_frame
from cv_engine.universal import weighted_scores


def background():
    noise = np.random.default_rng(12).integers(0, 255, (180, 320), dtype=np.uint8)
    noise = cv2.GaussianBlur(noise, (0, 0), 2)
    return cv2.cvtColor(np.clip((noise.astype(float) - 128) * 4 + 100, 20, 170).astype(np.uint8),
                        cv2.COLOR_GRAY2BGR)


def ball(center=(80, 90), marking=True, blur=1, color=(200, 200, 200), fingers=False):
    image = background()
    if fingers:
        cv2.rectangle(image, (center[0] + 11, center[1] - 20),
                      (center[0] + 26, center[1] + 23), (100, 140, 185), -1)
    layer = image.copy()
    cv2.circle(layer, center, 12, color, -1)
    if marking:
        cv2.rectangle(layer, (center[0] - 3, center[1] - 3),
                      (center[0] + 3, center[1] + 3), (160, 70, 30), -1)
    if blur > 1:
        layer = cv2.filter2D(layer, -1, np.ones((blur, 1), np.float32) / blur)
    return layer


def frame(image, index):
    return preprocess_frame(decode_jpeg(encode_jpeg(image)), index, index / 30)


def selected():
    pipe = TrackingPipeline()
    pipe.apply_config({'target_px': {'x': 80, 'y': 90},
                       'target_bbox': {'x': 54, 'y': 69, 'w': 52, 'h': 41},
                       'debug_tracking': True})
    ack = pipe.initialize(frame(ball(fingers=True), 0))
    assert ack['status'] == 'initialized' and not ack['tracked']
    assert pipe._manual.foreground is not None
    assert pipe._manual.round_reference is not None
    # The segmentation must isolate the ball rather than the finger beside it.
    mask = pipe._manual.foreground
    truth = np.zeros_like(mask)
    cv2.circle(truth, (26, 21), 12, 1, -1)
    assert np.count_nonzero(mask & truth) / np.count_nonzero(mask | truth) > .8
    return pipe


@pytest.mark.parametrize('destination', [(110, 90), (160, 90), (250, 90), (80, 145)])
@pytest.mark.parametrize('marking', [True, False])
def test_background_translation_and_surface_rotation_keep_ball_identity(destination, marking):
    pipe = selected()
    reference = pipe._manual.original.copy()
    image = ball(destination, marking=marking)
    cv2.rectangle(image, (95, 30), (125, 150), (100, 140, 185), -1)
    # Keep the distractor separate from the intended ball.
    if destination[0] == 110:
        image = ball(destination, marking=marking)
    result = pipe(frame(image, 1))
    target = next(o for o in result['objects'] if o['target'])
    assert target['pixel'] == pytest.approx(dict(zip(('x', 'y'), destination)), abs=2)
    assert result['tracking_debug']['method'] == 'foreground_verified'
    np.testing.assert_array_equal(pipe._manual.original, reference)


@pytest.mark.parametrize('blur', [1, 7, 11])
def test_fast_vertical_motion_with_moderate_blur(blur):
    pipe = selected()
    for index, y in enumerate((35, 60, 95, 140), 1):
        result = pipe(frame(ball((250, y), marking=False, blur=blur), index))
        target = next(o for o in result['objects'] if o['target'])
        assert target['pixel'] == pytest.approx({'x': 250, 'y': y}, abs=3)


def test_wrist_and_wrong_color_do_not_replace_missing_gray_ball():
    pipe = selected()
    image = background()
    cv2.rectangle(image, (65, 50), (105, 155), (100, 140, 185), -1)
    cv2.circle(image, (250, 90), 12, (0, 0, 255), -1)
    assert not pipe(frame(image, 1))['tracked']
    assert not pipe(frame(background(), 2))['tracked']
    recovered = pipe(frame(ball((250, 130), marking=False), 3))
    assert next(o for o in recovered['objects'] if o['target'])['pixel'] == pytest.approx(
        {'x': 250, 'y': 130}, abs=2)


def test_same_appearance_round_objects_are_ambiguous_even_outside_local_window():
    pipe = selected()
    assert not pipe(frame(background(), 1))['tracked']
    image = ball(marking=False)
    cv2.circle(image, (250, 90), 12, (200, 200, 200), -1)
    result = pipe(frame(image, 2))
    assert not result['tracked']
    assert result['tracking_debug']['reason'] == 'ambiguous_match'


def test_nonround_object_uses_masked_reference_across_changed_background():
    pipe = TrackingPipeline()
    pipe.apply_config({'target_px': {'x': 80, 'y': 90},
                       'target_bbox': {'x': 54, 'y': 64, 'w': 52, 'h': 52},
                       'debug_tracking': True})
    def image(x):
        out = background()
        cv2.rectangle(out, (x - 9, 70), (x + 9, 110), (30, 70, 220), -1)
        cv2.rectangle(out, (x - 5, 82), (x + 5, 93), (210, 210, 210), -1)
        return out
    assert pipe.initialize(frame(image(80), 0))['status'] == 'initialized'
    assert pipe._manual.foreground is not None
    assert pipe._manual.round_reference is None
    result = pipe(frame(image(250), 1))
    assert next(o for o in result['objects'] if o['target'])['pixel'] == pytest.approx(
        {'x': 250, 'y': 90}, abs=2)
    assert result['tracking_debug']['method'] == 'masked_template'


def test_weighted_matching_ignores_excluded_background_and_additive_exposure():
    reference = np.random.default_rng(4).integers(40, 160, (15, 15), dtype=np.uint8)
    weights = np.zeros(reference.shape, np.float32)
    weights[3:12, 3:12] = 1
    candidate = np.full(reference.shape, 240, np.uint8)
    candidate[3:12, 3:12] = reference[3:12, 3:12] + 35
    search = np.full((35, 50), 20, np.uint8)
    search[10:25, 25:40] = candidate
    scores = weighted_scores(search, [reference], weights)
    _, score, _, location = cv2.minMaxLoc(scores)
    assert location == (25, 10)
    assert score == pytest.approx(1, abs=1e-4)


def test_weighted_matching_rejects_zero_contrast_in_foreground():
    reference = np.random.default_rng(4).integers(40, 160, (15, 15), dtype=np.uint8)
    search = np.full((35, 50), 90, np.uint8)
    weights = np.ones(reference.shape, np.float32)
    assert weighted_scores(search, [reference], weights).max() < .68


def test_equal_luminance_red_object_is_not_rejected_as_empty_gray_background():
    pipe = TrackingPipeline()
    pipe.apply_config({'target_px': {'x': 80, 'y': 90}})
    def image(x):
        out = np.full((180, 320, 3), 90, np.uint8)
        cv2.circle(out, (x, 90), 14, (30, 30, 220), -1)
        return out
    ack = pipe.initialize(frame(image(80), 0))
    assert ack['status'] == 'initialized' and not ack['tracked']
    assert pipe._manual.match_channel in (1, 2)
    assert not pipe(frame(np.full((180, 320, 3), 90, np.uint8), 1))['tracked']
    result = pipe(frame(image(250), 2))
    target = next(o for o in result['objects'] if o['target'])
    assert target['pixel'] == pytest.approx({'x': 250, 'y': 90}, abs=2)
