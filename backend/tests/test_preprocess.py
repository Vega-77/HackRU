import cv2
import numpy as np
import pytest

from cv_engine.preprocess import decode_jpeg, downsample, encode_jpeg, preprocess_frame


def red_ball(w=1280, h=720):
    img = np.full((h, w, 3), 90, np.uint8)
    cv2.circle(img, (w // 2, h // 2), 60, (0, 0, 255), -1)
    return img


def test_downsample_keeps_aspect_and_never_upsamples():
    small, scale = downsample(red_ball(), 640)
    assert small.shape[:2] == (360, 640)
    assert scale == 0.5
    same, scale = downsample(red_ball(320, 240), 640)
    assert same.shape[:2] == (240, 320) and scale == 1.0


def test_preprocess_produces_hsv_and_gray_at_working_size():
    pf = preprocess_frame(red_ball(), frame_id=3, timestamp=1.0)
    assert pf.size == (640, 360)
    assert pf.source_size == (1280, 720)
    assert pf.hsv.shape == (360, 640, 3)
    assert pf.gray.shape == (360, 640)
    # Center of the red ball: red hue (near 0 or 179), saturated, bright.
    h, s, v = pf.hsv[180, 320]
    assert (h < 10 or h > 170) and s > 200 and v > 200
    assert pf.to_source_coords(320, 180) == (640, 360)


def test_jpeg_round_trip_and_bad_bytes():
    img = decode_jpeg(encode_jpeg(red_ball(), 80))
    assert img.shape == (720, 1280, 3)
    with pytest.raises(ValueError):
        decode_jpeg(b"not an image")
