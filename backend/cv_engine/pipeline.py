"""Per-connection tracking pipeline: detectors + tracker + spatial mapping -> JSON.

Each WebSocket connection gets its own TrackingPipeline so tracker state (IDs,
history) and calibration never leak between phones.
"""

from __future__ import annotations

import logging
import math
from dataclasses import dataclass, field, replace

import numpy as np

from cv_engine.ar_plane import ArPlane, image_axes
from cv_engine.acquisition import propose_region
from cv_engine.detect import DEFAULT_COLORS, ColorDetector, Detection, MediaPipeDetector, MotionDetector
from cv_engine.preprocess import PreprocessedFrame
from cv_engine.spatial import SpatialMapper
from cv_engine.tracker import CentroidTracker, Track
from cv_engine.universal import ManualTracker, box_from_tap

log = logging.getLogger(__name__)

DETECTORS = ("color", "motion", "mediapipe", "both")
# Auto-target (no tap): a track must move this far (working px) over its recent history
# to count as moving, and a rival must move twice as much as the current target to take over.
AUTO_TARGET_WINDOW = 15
AUTO_TARGET_MIN_MOTION = 10.0
EXPERIMENT_MODES = ("free_fall", "ramp", "pendulum", "collision")
# Settings the app sends in its config message (docs/protocol.md). The CV engine uses
# px_per_m (calibration fallback) and target_px (which object to follow); the rest is
# kept for the physics stage. iOS ARKit clients may also send ar_plane, the surface the
# object moves on: {"point": [x, y, z], "normal": [x, y, z], "offset_m": 0.0} in world metres.
# In collision mode the app can also select the other object (second_target_px and
# second_target_bbox), which is then followed the same way as the first.
SESSION_DEFAULTS = {"mode": None, "mass_kg": 0.1, "px_per_m": None, "target_px": None, "target_bbox": None,
                    "second_target_px": None, "second_target_bbox": None, "frame_size": None}
# Labels of the selected objects' detections, so the tracker never swaps their IDs.
FIRST_LABEL, SECOND_LABEL = "selected", "selected_2"


@dataclass
class PipelineConfig:
    detector: str = "motion"  # color-independent default; legacy color mode remains available
    colors: list[str] = field(default_factory=lambda: list(DEFAULT_COLORS))
    min_area: float = 80.0
    mediapipe_labels: list[str] | None = None  # e.g. ["sports ball"]; None = all COCO classes
    mediapipe_score: float = 0.35
    max_distance: float = 80.0
    max_missed: int = 10
    min_hits: int = 2

    def updated(self, changes: dict) -> PipelineConfig:
        unknown = set(changes) - set(self.__dataclass_fields__)
        if unknown:
            raise ValueError(f"unknown config keys {sorted(unknown)}")
        merged = PipelineConfig(**{**self.__dict__, **changes})
        if merged.detector not in DETECTORS:
            raise ValueError(f"detector must be one of {DETECTORS}")
        return merged


def validated_session(current: dict, changes: dict) -> dict:
    """Merge the app's session settings, checking the fields the CV engine relies on."""
    s = {**current, **changes}
    for key in ("initialization_required", "debug_tracking"):
        if key in s and not isinstance(s[key], bool):
            raise ValueError(f"{key} must be a boolean")
    if s["mode"] is not None and s["mode"] not in EXPERIMENT_MODES:
        raise ValueError(f"mode must be one of {EXPERIMENT_MODES}")
    if s["px_per_m"] is not None and not (isinstance(s["px_per_m"], (int, float)) and s["px_per_m"] > 0):
        raise ValueError("px_per_m must be a positive number or null")
    if not isinstance(s["mass_kg"], (int, float)) or not math.isfinite(s["mass_kg"]) or s["mass_kg"] <= 0:
        raise ValueError("mass_kg must be a positive number")
    angle = s.get("ramp_angle_deg")
    if angle is not None and (
        not isinstance(angle, (int, float)) or not math.isfinite(angle) or abs(angle) >= 90
    ):
        raise ValueError("ramp_angle_deg must be between -90 and 90 degrees")
    if "sliding_body" in s and not isinstance(s["sliding_body"], bool):
        raise ValueError("sliding_body must be a boolean")
    pivot = s.get("pendulum_pivot_m")
    if pivot is not None and (
        not isinstance(pivot, dict)
        or any(not isinstance(pivot.get(key), (int, float)) or not math.isfinite(pivot[key]) for key in ("x", "y"))
    ):
        raise ValueError("pendulum_pivot_m must have finite numeric x and y")
    masses = s.get("collision_masses_kg")
    if masses is not None and (
        not isinstance(masses, list) or len(masses) != 2
        or any(not isinstance(value, (int, float)) or not math.isfinite(value) or value <= 0 for value in masses)
    ):
        raise ValueError("collision_masses_kg must contain two positive masses")
    if s.get("ar_plane") is not None:
        ArPlane.from_request(s["ar_plane"])  # raises ValueError if malformed
    for key, fields in (("target_px", ("x", "y")), ("target_bbox", ("x", "y", "w", "h")),
                        ("second_target_px", ("x", "y")), ("second_target_bbox", ("x", "y", "w", "h")),
                        ("frame_size", ("w", "h"))):
        v = s[key]
        if v is not None and not (isinstance(v, dict) and all(isinstance(v.get(f), (int, float)) and math.isfinite(v[f]) for f in fields)):
            raise ValueError(f"{key} must be null or an object with numeric {', '.join(fields)}")
    for key in ("target_bbox", "second_target_bbox"):
        if s[key] is not None and (s[key]["w"] <= 0 or s[key]["h"] <= 0):
            raise ValueError(f"{key} must have positive width and height")
    if s["frame_size"] is not None and (s["frame_size"]["w"] <= 0 or s["frame_size"]["h"] <= 0):
        raise ValueError("frame_size must have positive width and height")
    return s


class TrackingPipeline:
    def __init__(self, config: PipelineConfig | None = None) -> None:
        self._mediapipe: MediaPipeDetector | None = None
        self.spatial = SpatialMapper()
        self.session = dict(SESSION_DEFAULTS)
        self._target_id: int | None = None
        self._target_last: tuple[float, float] | None = None  # client px
        self._manual = ManualTracker()
        self._pending_selection = False
        self._second = ManualTracker()  # the other object in a collision, when the user selected it
        self._second_pending = False
        self.configure(config or PipelineConfig())

    def configure(self, config: PipelineConfig) -> None:
        """Apply new settings. Builds everything first, so a failure keeps the old setup."""
        old = getattr(self, "config", None)
        color = ColorDetector(config.colors, min_area=config.min_area)
        mp_settings_changed = old is None or (old.mediapipe_labels, old.mediapipe_score) != (
            config.mediapipe_labels,
            config.mediapipe_score,
        )
        motion = MotionDetector(min_area=config.min_area) if config.detector == "motion" else None
        mediapipe = self._mediapipe
        if config.detector in ("mediapipe", "both") and (mediapipe is None or mp_settings_changed):
            mediapipe = MediaPipeDetector(score_threshold=config.mediapipe_score, allow_labels=config.mediapipe_labels)
        elif config.detector not in ("mediapipe", "both"):
            mediapipe = None
        if self._mediapipe is not None and self._mediapipe is not mediapipe:
            self._mediapipe.close()

        self.config = config
        self.color = color
        self.motion = motion
        self._mediapipe = mediapipe
        self.tracker = CentroidTracker(config.max_distance, config.max_missed, config.min_hits)
        self._target_id = None
        self._manual.reset()
        self._pending_selection = self.session["target_px"] is not None
        self._second.reset()
        self._second_pending = self.session["second_target_px"] is not None

    @property
    def follows_second(self) -> bool:
        """Whether a second selected object is followed: only in collision mode, next to
        the first selection."""
        s = self.session
        return s["mode"] == "collision" and s["target_px"] is not None and s["second_target_px"] is not None

    def apply_config(self, message: dict) -> dict:
        """Handle a {"type": "config"} message. Detector keys (see PipelineConfig) retune
        tracking; everything else is session settings from the app. Raises ValueError and
        changes nothing if any value is invalid."""
        changes = {k: v for k, v in message.items() if k != "type"}
        detector_keys = set(PipelineConfig.__dataclass_fields__)
        detector_changes = {k: v for k, v in changes.items() if k in detector_keys}
        session = validated_session(self.session, {k: v for k, v in changes.items() if k not in detector_keys})
        new_config = self.config.updated(detector_changes) if detector_changes else None

        if new_config is not None:
            self.configure(new_config)
        if session["target_px"] != self.session["target_px"] or session["target_bbox"] != self.session["target_bbox"]:
            self._target_id = None
            t = session["target_px"]
            self._target_last = (t["x"], t["y"]) if t else None
            self._manual.reset()
            self.tracker.forget_manual(FIRST_LABEL)
            self._pending_selection = t is not None
            if t is None and self.motion:
                self.motion.reset()  # its background stopped learning while a tap was followed
        if (session["second_target_px"], session["second_target_bbox"]) != (
            self.session["second_target_px"], self.session["second_target_bbox"]
        ):
            self._second.reset()
            self.tracker.forget_manual(SECOND_LABEL)
            self._second_pending = session["second_target_px"] is not None
        self.session = session
        plane_before = self.spatial.ar_plane
        self.spatial.set_ar_plane(session.get("ar_plane"))
        if self.motion and self.spatial.ar_plane is not plane_before:
            self.motion.reset()  # its reference view was aligned to the old surface
        self.spatial.set_scale(session["px_per_m"], session["frame_size"])
        return self.settings()

    def settings(self) -> dict:
        return {"detector": dict(self.config.__dict__), "session": dict(self.session)}

    def _plane_to_working(self, frame: PreprocessedFrame) -> np.ndarray | None:
        """The AR surface's plane -> working-pixel homography for this frame, so the motion
        detector can align views with the camera pose instead of image features."""
        if self.spatial.method != "arkit" or self.spatial.mapping is None:
            return None
        return np.diag([frame.scale, frame.scale, 1.0]) @ self.spatial.mapping.H_inv

    def detect(self, frame: PreprocessedFrame) -> list[Detection]:
        dets: list[Detection] = []
        if self.config.detector in ("color", "both"):
            dets += self.color.detect(frame)
        if self.config.detector == "motion" and self.motion:
            dets += self.motion.detect(frame, self._plane_to_working(frame))
        if self.config.detector in ("mediapipe", "both") and self._mediapipe:
            dets += self._mediapipe.detect(frame)
        return dets

    def __call__(self, frame: PreprocessedFrame) -> dict:
        """Process one frame; returns the "objects" and "calibration" parts of the result."""
        self.spatial.update(frame)
        tap = self.session["target_px"]
        # Once the user's object is selected, only it is followed (see _pick_target), so the
        # other detectors' work would be thrown away: skipping them roughly halves the time
        # per frame, and a faster stream means smaller jumps between frames. Collisions need
        # the other object too: the detectors keep running for it unless the user selected
        # it as well, and then it is followed the same way as the first.
        following = tap is not None and not self._pending_selection and self._manual.original is not None
        second_tap = self.session["second_target_px"] if self.follows_second else None
        second_following = second_tap is not None and not self._second_pending and self._second.original is not None
        need_detectors = self.session["mode"] == "collision" and not second_following
        detections = [] if following and not need_detectors else self.detect(frame)
        selected = []
        if tap is not None:
            if self._pending_selection:
                self._select(self._manual, frame, tap, self.session["target_bbox"])
                self._pending_selection = False
            elif (manual := self._manual.detect(frame)) is not None:
                selected.append(manual)
        if second_tap is not None:
            if self._second_pending:
                self._select(self._second, frame, second_tap, self.session["second_target_bbox"])
                self._second_pending = False
            elif (second := self._second.detect(frame)) is not None:
                selected.append(replace(second, label=SECOND_LABEL))
        for mx, my, mw, mh in (d.bbox for d in selected):
            detections = [d for d in detections if not (mx < d.bbox[0] + d.bbox[2] and d.bbox[0] < mx + mw
                          and my < d.bbox[1] + d.bbox[3] and d.bbox[1] < my + mh)]
        detections += selected
        tracks = self.tracker.update(detections)
        target = self._pick_target(tracks, frame)
        objects = [track_to_json(t, frame, self.spatial) for t in tracks]
        for o in objects:
            o["target"] = o["id"] == self._target_id
            o["timestamp"] = frame.timestamp
            o["tracking_status"] = "low_confidence" if o["score"] < 0.6 else "detected"
        if target is not None:
            tracking_status = "low_confidence" if target.score < 0.6 else "detected"
        elif self._target_id is not None:
            tracking_status = "lost"
        else:
            tracking_status = self._manual.debug.get("reason", "searching") if tap is not None else "searching"
        result = {
            "tracked": target is not None,
            "tracking_status": tracking_status,
            "target_id": self._target_id,
            "objects": objects,
            "calibration": self.spatial.status(),
        }
        if self.session.get("debug_tracking"):
            result["tracking_debug"] = {"frame_id": frame.frame_id, "timestamp": frame.timestamp,
                                        "detections": len(detections), **self._manual.debug}
            if second_tap is not None:
                result["tracking_debug"]["second"] = dict(self._second.debug)
        return result

    def initialize(self, frame: PreprocessedFrame, which: str = "first") -> dict:
        """Retry acquisition on this exact image; initialization is never a detection.
        `which` is "second" for the other object in a collision, selected on its own image
        after the first object was initialized (initializing the first one clears it)."""
        if which == "second":
            manual = self._second
            manual.reset()
            self.tracker.forget_manual(SECOND_LABEL)
            self._second_pending = False
        else:
            manual = self._manual
            manual.reset()
            self._second.reset()
            self._second_pending = False
            self._target_id = None
            self.tracker = CentroidTracker(self.config.max_distance, self.config.max_missed, self.config.min_hits)
            self._pending_selection = self.session["target_px"] is not None
        expected = self.session["frame_size"]
        if expected is not None and frame.source_size != (expected["w"], expected["h"]):
            return {"status": "failed", "reason": "selection_image_size_mismatch", "tracked": False, "bbox": None}
        if which == "second":
            if not self.follows_second:
                return {"status": "failed", "reason": "no_second_selection", "tracked": False, "bbox": None}
            self._select(manual, frame, self.session["second_target_px"], self.session["second_target_bbox"])
        else:
            self(frame)
        return {"status": "initialized" if manual.original is not None else "failed",
                "reason": manual.debug["reason"], "tracked": False,
                "bbox": None if manual.bbox is None else
                    {key: value / frame.scale for key, value in zip(("x", "y", "w", "h"), manual.bbox)}}

    def _select(self, manual: ManualTracker, frame: PreprocessedFrame, tap: dict, box: dict | None) -> None:
        point = (tap["x"] * frame.scale, tap["y"] * frame.scale)
        if box is None:
            box = self._box_from_tap(frame, point)
        manual.select(frame, point, box)

    def _box_from_tap(self, frame: PreprocessedFrame, point: tuple[float, float]) -> dict | None:
        """A box (client px) around the object under a tap without a drawn box, or None to
        ask the user for one (selection_required). A stable flood-filled region is best on a
        plain background; on a textured one it leaks or finds many outlines, and the object
        is found by how it stands out from its surroundings instead."""
        proposal = propose_region(frame.bgr, point)
        found = None
        if proposal["reason"] != "stable_seeded_region":
            found = box_from_tap(frame, point)
        if found is not None:
            x, y, w, h = found
        elif proposal["bbox"]:
            x, y, w, h = (proposal["bbox"][k] for k in ("x", "y", "w", "h"))
        else:
            return None
        s = frame.scale
        return {"x": x / s, "y": y / s, "w": w / s, "h": h / s}

    def _pick_target(self, tracks: list[Track], frame: PreprocessedFrame) -> Track | None:
        """The object the app cares about: the one the user tapped (target_px), followed by
        ID from then on and re-acquired near its last position if lost; with no tap, the
        object that is moving most (see _auto_target)."""
        if not tracks:
            return None
        by_id = {t.id: t for t in tracks}
        manual_tracks = [t for t in tracks if t.source == "manual" and t.label == FIRST_LABEL] \
            if self.session["target_px"] is not None else []
        if manual_tracks:
            chosen = max(manual_tracks, key=lambda t: t.score)
        elif self.session["target_px"] is not None:
            return None
        else:
            chosen = self._auto_target(tracks, by_id.get(self._target_id))
        self._target_id = chosen.id
        if self.session["target_px"] is not None:
            self._target_last = (chosen.centroid[0] / frame.scale, chosen.centroid[1] / frame.scale)
        return chosen

    @staticmethod
    def _auto_target(tracks: list[Track], current: Track | None) -> Track:
        """Prefer the object that is moving: a still red box (or a background ghost) should
        never beat a rolling ball just because it was seen first. Sticks with the current
        target unless a rival moves clearly more, so the target doesn't flicker."""

        def motion(t: Track) -> float:
            pts = list(t.history)[-AUTO_TARGET_WINDOW:]
            return sum(math.dist(a, b) for a, b in zip(pts, pts[1:]))

        best = max(tracks, key=motion)
        if current is not None and (best is current or motion(best) < max(2 * motion(current), AUTO_TARGET_MIN_MOTION)):
            return current
        if motion(best) < AUTO_TARGET_MIN_MOTION:
            return max(tracks, key=lambda t: (t.hits, t.area))
        return best

    def calibrate(self, request: dict) -> dict:
        return self.spatial.calibrate(request)

    def close(self) -> None:
        if self._mediapipe:
            self._mediapipe.close()
            self._mediapipe = None


def track_to_json(t: Track, frame: PreprocessedFrame, spatial: SpatialMapper | None = None) -> dict:
    """Report positions in the client's own frame pixels (pixel, bbox), normalized 0-1
    coords and, when the plane is calibrated, meters on that plane (position, y up), how
    the plane's axes look on screen there (screen_axes) and, for ARKit clients, the 3D
    point in ARKit world space (position_3d)."""
    s = frame.scale
    w, h = frame.size
    x, y, bw, bh = t.bbox
    cx, cy = t.centroid
    position = width_m = position_3d = axes = None
    if spatial is not None and spatial.mapping is not None:
        wx, wy = spatial.to_world((cx / s, cy / s), (cx / w, cy / h))
        position = {"x": wx, "y": wy}
        position_3d = spatial.to_world_3d((wx, wy))
        if spatial.space == "px":
            axes = image_axes(spatial.mapping, (wx, wy))
        # Object width on the plane, from the left and right edges at centroid height.
        left = spatial.to_world((x / s, cy / s), (x / w, cy / h))
        right = spatial.to_world(((x + bw) / s, cy / s), ((x + bw) / w, cy / h))
        width_m = round(float(np.hypot(right[0] - left[0], right[1] - left[1])), 4)
    return {
        "id": t.id,
        "label": t.label,
        "source": t.source,
        "score": round(t.score, 3),
        "confidence": round(t.score, 3),
        "pixel": {"x": round(cx / s, 2), "y": round(cy / s, 2)},
        "bbox": {"x": round(x / s, 1), "y": round(y / s, 1), "w": round(bw / s, 1), "h": round(bh / s, 1)},
        "pixel_norm": {"x": round(cx / w, 5), "y": round(cy / h, 5)},
        "bbox_norm": {"x": round(x / w, 5), "y": round(y / h, 5), "w": round(bw / w, 5), "h": round(bh / h, 5)},
        "area": round(t.area / (s * s), 1),
        "hits": t.hits,
        "position": position,
        "position_3d": position_3d,
        "screen_axes": axes,
        "width_m": width_m,
    }
