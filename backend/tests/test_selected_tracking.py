"""The selected object is followed through clips like real experiments (motion_scenes):
rolling, swinging, tossed, a plain grey box, a hand passing over, a lookalike nearby.

These guard against the tracker drifting onto the background or a lookalike, which is
worse than losing the object: a wrong frame draws arrows on the wrong thing."""

import math
import sys
from pathlib import Path

import cv2
import pytest

from cv_engine.pipeline import TrackingPipeline
from cv_engine.preprocess import decode_jpeg, preprocess_frame
from physics_stage import PhysicsSession

sys.path.insert(0, str(Path(__file__).parent))
import motion_scenes  # noqa: E402

CLIPS = {clip.name: clip for clip in motion_scenes.all_clips()}


def follow(clip, *, box=True):
    pipe = TrackingPipeline()
    config = {"type": "config", "target_px": clip.tap, "px_per_m": 400.0, "mode": "free_fall",
              "frame_size": {"w": motion_scenes.W, "h": motion_scenes.H}}
    if box:
        config["target_bbox"] = clip.box
    pipe.apply_config(config)
    physics = PhysicsSession()
    found = wrong = visible = with_velocity = 0
    ids = set()
    statuses = []
    for i, (jpeg, truth) in enumerate(zip(clip.frames, clip.truth)):
        result = pipe(preprocess_frame(decode_jpeg(jpeg), i, clip.timestamps[i]))
        state = physics.process_frame({**result, "frame_id": i, "timestamp": clip.timestamps[i]}, pipe.session)
        statuses.append(result["tracking_status"])
        with_velocity += "velocity" in state
        target = next((o for o in result["objects"] if o["target"]), None)
        if target is not None:
            ids.add(target["id"])
        if i == 0:
            continue
        if truth is None:
            wrong += target is not None
            continue
        visible += 1
        if target is None:
            continue
        if math.hypot(target["pixel"]["x"] - truth[0], target["pixel"]["y"] - truth[1]) <= 0.35 * clip.diameter:
            found += 1
        else:
            wrong += 1
    return {"recall": found / visible, "wrong": wrong, "ids": ids, "statuses": statuses,
            "velocity_frames": with_velocity}


@pytest.mark.parametrize("name", sorted(CLIPS))
def test_boxed_object_is_followed_through_the_clip(name):
    run = follow(CLIPS[name])
    assert run["wrong"] == 0
    assert run["recall"] >= 0.9
    assert run["statuses"][0] == "initialized"
    assert len(run["ids"]) == 1  # one ID, so the physics history is never restarted


def test_velocity_is_reported_through_a_short_occlusion():
    clip = CLIPS["occluded_roll"]
    run = follow(clip)
    # Velocity needs two samples, so the first two frames have none; every frame where the
    # ball is in sight after that has a velocity, including right after the hand passes.
    seen = sum(t is not None for t in clip.truth)
    assert run["velocity_frames"] >= seen - 3


@pytest.mark.parametrize("name", ["ramp_roll", "pendulum", "occluded_roll", "distractor_roll"])
def test_tapped_ball_is_boxed_and_followed(name):
    run = follow(CLIPS[name], box=False)
    assert run["statuses"][0] == "initialized"
    assert run["wrong"] == 0
    assert run["recall"] >= 0.9


def test_tap_on_a_bare_table_asks_for_a_box():
    image = motion_scenes._background(46)
    jpeg = cv2.imencode(".jpg", image, [cv2.IMWRITE_JPEG_QUALITY, 70])[1].tobytes()
    for tap in ({"x": 150, "y": 150}, {"x": 270, "y": 110}, {"x": 230, "y": 60}):
        pipe = TrackingPipeline()
        pipe.apply_config({"type": "config", "target_px": tap, "frame_size": {"w": 320, "h": 240}})
        result = pipe(preprocess_frame(decode_jpeg(jpeg), 0, 0.0))
        assert result["tracking_status"] == "selection_required", tap


def test_new_selection_gets_a_new_id():
    clip = CLIPS["distractor_roll"]
    pipe = TrackingPipeline()
    pipe.apply_config({"type": "config", "target_px": clip.tap, "target_bbox": clip.box,
                       "frame_size": {"w": 320, "h": 240}})
    frames = [preprocess_frame(decode_jpeg(j), i, clip.timestamps[i]) for i, j in enumerate(clip.frames[:6])]
    first = [pipe(f) for f in frames[:3]][-1]
    old_id = first["target_id"]
    assert old_id is not None
    # The still ball at (250, 60) has the same colours.
    pipe.apply_config({"type": "config", "target_px": {"x": 250, "y": 60},
                       "target_bbox": {"x": 237, "y": 47, "w": 26, "h": 26}})
    results = [pipe(f) for f in frames[3:]]
    target = next(o for o in results[-1]["objects"] if o["target"])
    assert target["id"] != old_id
    assert target["pixel"] == pytest.approx({"x": 250, "y": 60}, abs=3)


def test_physics_keeps_history_over_one_missed_frame():
    session = PhysicsSession()
    settings = {"mode": "free_fall", "mass_kg": 0.1}

    def frame(i, visible=True):
        objects = [{"id": 3, "target": True, "score": 0.9, "pixel": {"x": 0, "y": 0},
                    "position": {"x": 0.1 * i, "y": 0.0}}] if visible else []
        return {"type": "frame", "frame_id": i, "timestamp": i / 15, "tracked": visible, "objects": objects}

    for i in range(4):
        session.process_frame(frame(i), settings)
    assert not session.process_frame(frame(4, visible=False), settings)["tracked"]
    after = session.process_frame(frame(5), settings)
    assert after["velocity"]["x"] == pytest.approx(1.5)  # 0.1 m per 1/15 s
    assert "acceleration" in after  # the earlier samples were kept
    # Gone for longer than the gap rule: starts over.
    for i in range(6, 20):
        session.process_frame(frame(i, visible=False), settings)
    assert 3 not in session.engines
    assert "velocity" not in session.process_frame(frame(20), settings)
