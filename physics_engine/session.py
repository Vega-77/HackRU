"""Turn Dev 2 frame reports into the frontend's physics state protocol."""

from __future__ import annotations

from dataclasses import replace
from math import hypot, isfinite

from .contact import Body, ContactTracker, Surface, gravity_in_plane, plane_support, ramp_surface
from .kinematics import KinematicsEngine, KinematicsResult, Vector2D
from .models import GRAVITY_MPS2, collision_metrics, motion_model


# An object missing for longer than this starts a fresh history when it is seen again,
# matching KinematicsEngine's own gap rule. Shorter gaps (a blurred frame, a hand
# passing over) keep it, so velocity doesn't drop out for a single missed frame.
FORGET_AFTER_S = 0.5

# Free fall bounds its history by time (0.35 s), not by count. Seven samples
# at 30 fps span only 0.2 s, too short for the acceleration uncertainty gate
# once the tracker jitters by a pixel or two, so most of a drop would show no
# acceleration. Twenty-four also covers that same time window at 60 fps;
# the 0.35 s cutoff still excludes older positions.
FREE_FALL_MAX_SAMPLES = 24


class PhysicsSession:
    """One physics history per WebSocket connection and tracked object ID."""

    def __init__(self, window_size: int = 7) -> None:
        self.window_size = window_size
        self.engines: dict[int, KinematicsEngine] = {}
        self.initial_energy: dict[int, float] = {}
        # Pendulum pivot for each object, averaged over every circle fit so far. A pivot
        # doesn't move, so averaging steadies it, and a swing point where the fit fails
        # (too little arc in view) keeps the last one.
        self._pivots: dict[int, dict] = {}
        self._last_seen: dict[int, float] = {}
        self._configuration: tuple | None = None
        self._calibration: tuple | None = None
        self._pre_collision: tuple | None = None
        self._last_collision: dict | None = None
        self.contacts = ContactTracker()

    def reset(self) -> None:
        self.engines.clear()
        self.initial_energy.clear()
        self._pivots.clear()
        self._last_seen.clear()
        self._pre_collision = None
        self._last_collision = None
        self.contacts.reset()

    def process_frame(self, frame: dict, settings: dict | None = None) -> dict:
        """Return a ``type: state`` reply with CV fields preserved.

        Position must come from Dev 2's metric ``objects[].position``. When
        calibration is unavailable the target remains visible in pixels, but
        SI vectors and energies are withheld.
        """

        settings = settings or {}
        mode = settings.get("mode")
        mass = float(settings.get("mass_kg", 0.1))
        if not isfinite(mass) or mass <= 0:
            raise ValueError("mass_kg must be positive and finite")
        configuration = (
            mode, mass, repr(settings.get("pendulum_pivot_m")),
            settings.get("ramp_angle_deg"), settings.get("sliding_body"),
            repr(settings.get("collision_masses_kg")), settings.get("view"),
        )
        if self._configuration is not None and configuration != self._configuration:
            self.reset()
        self._configuration = configuration

        calibration = frame.get("calibration", {})
        calibration_signature = (
            calibration.get("method"), repr(calibration.get("settings")),
            repr(calibration.get("world_points")),
        )
        if self._calibration is not None and calibration_signature != self._calibration:
            self.reset()
        self._calibration = calibration_signature

        timestamp = float(frame["timestamp"])
        if not isfinite(timestamp):
            raise ValueError("frame timestamp must be finite")
        state = dict(frame)
        state["type"] = "state"
        state["mode"] = mode
        state["forces"] = []
        state["extras"] = {}
        for obj in frame.get("objects", []):
            self._last_seen[int(obj["id"])] = timestamp
        for gone_id in [i for i, seen in self._last_seen.items() if timestamp - seen > FORGET_AFTER_S]:
            self.engines.pop(gone_id, None)
            self.initial_energy.pop(gone_id, None)
            self._pivots.pop(gone_id, None)
            self.contacts.forget(gone_id)
            del self._last_seen[gone_id]
        target = next((o for o in frame.get("objects", []) if o.get("target")), None)
        if target is None:
            state["tracked"] = False
            return state

        state["pixel"] = target.get("pixel")
        state["bbox"] = target.get("bbox")
        state["position"] = target.get("position")
        state["position_3d"] = target.get("position_3d")
        state["screen_axes"] = target.get("screen_axes")
        if frame.get("timestamp_source") == "server_receive":
            self.reset()
            state["physics_quality"] = {"reason": "capture_timestamp_missing"}
            return state

        results: dict[int, KinematicsResult] = {}
        for obj in frame.get("objects", []):
            position = obj.get("position")
            if position is None:
                object_id = int(obj["id"])
                if object_id in self.engines:
                    self.engines[object_id].reset()
                    self.initial_energy.pop(object_id, None)
                continue
            object_id = int(obj["id"])
            if object_id not in self.engines:
                # A seven-frame history can cover seconds on a slow connection,
                # blending a held ball with its entire fall. Bound physical time.
                axes = obj.get("screen_axes") or {}
                scales = [hypot(v["x"], v["y"]) for v in axes.values() if isinstance(v, dict)]
                scale = min(scales) if scales else calibration.get("settings", {}).get("px_per_m")
                self.engines[object_id] = KinematicsEngine(
                    # Free fall keeps more samples so dropped frames still show gravity;
                    # a pendulum fit needs a little more of the swing to lock on.
                    window_size=(max(self.window_size, FREE_FALL_MAX_SAMPLES) if mode == "free_fall"
                                 else max(self.window_size, 9) if mode == "pendulum"
                                 else self.window_size),
                    confidence_threshold=0.6,
                    max_window_seconds=0.35 if mode == "free_fall" else None,
                    min_acceleration_samples=4 if mode == "free_fall" else 3,
                    min_acceleration_span=0.12 if mode == "free_fall" else 0.0,
                    position_noise_m=1.0 / scale if scale and scale > 0 else 0.0,
                    max_acceleration_std=2.0 if mode == "free_fall" else None,
                    reset_on_motion=mode == "free_fall",
                    # Spatial coordinates are rounded to four decimal places.
                    position_quantization_m=0.0001,
                )
            engine = self.engines[object_id]
            result = engine.add_world_sample(
                timestamp, float(position["x"]), float(position["y"]),
                confidence=float(obj.get("score", 1.0)),
            )
            if result.tracking_valid:
                results[object_id] = result

        target_result = results.get(int(target["id"]))
        if target_result is None:
            state["physics_quality"] = {"reason": "tracking_unreliable"}
            return state

        state["physics_quality"] = {
            "reason": target_result.reason,
            "samples": target_result.sample_count,
            "span_s": target_result.span_s,
            "position_residual_m": target_result.position_residual_m,
            "acceleration_std_mps2": target_result.acceleration_std_mps2,
            "velocity_valid": target_result.velocity_valid,
            "acceleration_valid": target_result.acceleration_valid,
        }

        pivot = None
        if mode == "pendulum" and target_result.velocity_valid:
            pivot = settings.get("pendulum_pivot_m")
            if pivot is None:
                estimated_pivot = self.engines[int(target["id"])].estimate_circle_center()
                if estimated_pivot is not None:
                    self._pivots[int(target["id"])] = _blend_pivot(
                        self._pivots.get(int(target["id"])), estimated_pivot,
                    )
                pivot = self._pivots.get(int(target["id"]))
            if pivot is not None:
                swing = self.engines[int(target["id"])].pendulum_estimate(
                    Vector2D(float(pivot["x"]), float(pivot["y"])), GRAVITY_MPS2
                )
                if swing is not None:
                    target_result = replace(
                        target_result, velocity_mps=swing[0], speed_mps=swing[0].magnitude,
                        acceleration_mps2=swing[1] if target_result.acceleration_valid else target_result.acceleration_mps2,
                    )
                    results[int(target["id"])] = target_result

        if target_result.velocity_valid:
            state["velocity"] = _vec(target_result.velocity_mps)
            state["speed_mps"] = target_result.speed_mps
        if target_result.acceleration_valid:
            state["acceleration"] = _vec(target_result.acceleration_mps2)

        contact_forces = self._contact_forces(frame, results, mode, mass, settings, calibration.get("plane"))
        if contact_forces is not None:
            state["contacts"] = [_contact_summary(f) for f in contact_forces.get(int(target["id"]), [])]

        if target_result.velocity_valid:
            target_id = int(target["id"])
            model_settings = dict(settings)
            model_settings["normal_from_contacts"] = contact_forces is not None
            if mode == "ramp" and model_settings.get("ramp_angle_deg") is None:
                model_settings["ramp_angle_deg"] = self.engines[target_id].trajectory_angle_deg()
            if mode == "pendulum" and pivot is not None:
                model_settings["pendulum_pivot_m"] = pivot
                pivot_pixel = _pivot_pixel(target, pivot)
                if pivot_pixel is not None:
                    state["pivot_pixel"] = pivot_pixel
            energy_at_start = self.initial_energy.get(target_id)
            model = motion_model(
                mode,
                target_result.position_m,
                target_result.velocity_mps,
                target_result.acceleration_mps2 if target_result.acceleration_valid else None,
                mass,
                model_settings,
                energy_at_start,
            )
            state.update(model)
            if (
                mode == "ramp" and settings.get("sliding_body")
                and target_id not in self.initial_energy
                and target_result.speed_mps < 0.05
            ):
                self.initial_energy[target_id] = (
                    model["energy"].get("kinetic", 0.0)
                    + model["energy"].get("potential", 0.0)
                )

        if contact_forces is not None:
            state["forces"] = state["forces"] + [_plain_force(f) for f in contact_forces.get(int(target["id"]), [])]
        _add_world_vectors(state, calibration.get("plane"))

        if mode == "collision":
            state["collision_objects"] = [
                {
                    "id": obj["id"],
                    "position": obj["position"],
                    "velocity": _vec(results[int(obj["id"])].velocity_mps),
                    "forces": [_plain_force(f) for f in (contact_forces or {}).get(int(obj["id"]), [])],
                }
                for obj in frame.get("objects", [])
                if obj.get("position") is not None
                and int(obj["id"]) in results
                and results[int(obj["id"])].velocity_valid
            ]
            collision = self._update_collision(frame.get("objects", []), results, mass, settings)
            if collision is not None:
                state["extras"].update(collision)

        return state

    def _contact_forces(
        self, frame: dict, results: dict[int, KinematicsResult], mode: str | None, mass: float,
        settings: dict, plane: dict | None,
    ) -> dict[int, list[dict]] | None:
        """Normal forces on every tracked object from the surfaces and objects it rests
        against (see contact.py), or None where contact doesn't apply (a pendulum hangs)."""
        if mode == "pendulum":
            return None
        gravity = gravity_in_plane(plane, settings.get("view"))
        masses = settings.get("collision_masses_kg") if mode == "collision" else None
        ids = sorted(results)
        shared = [s for s in (Surface.from_dict(d) for d in frame.get("surfaces", [])) if s is not None]
        support = plane_support(gravity)
        if support is not None:
            shared.append(support)
        bodies, surfaces = [], {}
        for obj in frame.get("objects", []):
            object_id = int(obj["id"])
            result = results.get(object_id)
            if result is None:
                continue
            # Collision masses go to the objects in ID order, as in _update_collision.
            rank = ids.index(object_id)
            body_mass = float(masses[rank]) if masses and len(masses) == 2 and rank < 2 else mass
            body = Body(
                object_id, body_mass, result.position_m,
                result.velocity_mps if result.velocity_valid else None,
                result.acceleration_mps2 if result.acceleration_valid else None,
                obj.get("width_m"), obj.get("height_m"),
            )
            bodies.append(body)
            own = [s for s in (Surface.from_dict(d) for d in obj.get("surfaces", [])) if s is not None]
            if mode == "ramp" and obj.get("target"):
                angle = settings.get("ramp_angle_deg")
                if angle is None:
                    angle = self.engines[object_id].trajectory_angle_deg()
                if angle is not None:
                    own.append(ramp_surface(body, float(angle)))
            surfaces[object_id] = shared + own
            self.contacts.learn_path(body, self.engines[object_id].recent_positions(), gravity)
        # Only objects the user cares about push on each other: the target, and in a
        # collision the other selected object. Background blobs would add phantom contacts.
        if mode != "collision":
            bodies = [b for b in bodies if any(o.get("target") and int(o["id"]) == b.id for o in frame.get("objects", []))]
        return self.contacts.update(bodies, surfaces, gravity)

    def _update_collision(
        self, objects: list[dict], results: dict[int, KinematicsResult], mass: float, settings: dict
    ) -> dict | None:
        available = sorted(
            (obj for obj in objects if int(obj["id"]) in results and results[int(obj["id"])].velocity_valid),
            key=lambda obj: obj["id"],
        )
        if len(available) < 2:
            return self._last_collision
        a, b = available[:2]
        ra, rb = results[int(a["id"])], results[int(b["id"])]
        separation = Vector2D(rb.position_m.x - ra.position_m.x, rb.position_m.y - ra.position_m.y)
        distance = separation.magnitude
        if distance == 0:
            return self._last_collision
        axis = Vector2D(separation.x / distance, separation.y / distance)
        closing_speed = (
            (ra.velocity_mps.x - rb.velocity_mps.x) * axis.x
            + (ra.velocity_mps.y - rb.velocity_mps.y) * axis.y
        )
        contact_distance = (float(a.get("width_m") or 0.05) + float(b.get("width_m") or 0.05)) / 2
        near = distance <= max(0.15, 2.0 * contact_distance)
        masses = settings.get("collision_masses_kg") or [mass, mass]
        if len(masses) != 2:
            return self._last_collision
        if near and closing_speed > 0.05:
            self._pre_collision = (ra.velocity_mps, rb.velocity_mps, axis, float(masses[0]), float(masses[1]))
        elif near and closing_speed < -0.05 and self._pre_collision is not None:
            ua, ub, before_axis, ma, mb = self._pre_collision
            try:
                metrics = collision_metrics(ua, ub, ra.velocity_mps, rb.velocity_mps, ma, mb, before_axis)
            except ValueError:
                metrics = None
            self._pre_collision = None
            if metrics is not None:
                self._last_collision = metrics
        return self._last_collision


def _plain_force(force: dict) -> dict:
    """A contact force as the protocol's force entry: the out-of-plane part (z) only
    when there is one, and where on the object it acts (point, plane metres)."""
    out = {"name": force["name"], "x": force["x"], "y": force["y"]}
    if abs(force["z"]) > 1e-9:
        out["z"] = force["z"]
    if "point" in force:
        out["point"] = force["point"]
    return out


def _contact_summary(force: dict) -> dict:
    return {k: force[k] for k in ("name", "surface", "source", "point") if k in force}


def _blend_pivot(held: dict | None, fitted: Vector2D) -> dict:
    """Running average of pivot fits, so one noisy fit barely moves it."""

    if held is None:
        return {"x": fitted.x, "y": fitted.y, "fits": 1}
    fits = held["fits"] + 1
    weight = max(1.0 / fits, 0.05)
    return {
        "x": held["x"] + (fitted.x - held["x"]) * weight,
        "y": held["y"] + (fitted.y - held["y"]) * weight,
        "fits": fits,
    }


def _pivot_pixel(target: dict, pivot: dict) -> dict | None:
    """Where the pendulum's pivot is in the client's frame pixels, so the app can draw
    the string and lay the tension arrow along it. Steps from the bob using the plane's
    screen axes at the bob, which is close enough over a string's length."""

    axes, pixel, position = target.get("screen_axes"), target.get("pixel"), target.get("position")
    if not axes or not pixel or not position:
        return None
    dx = float(pivot["x"]) - float(position["x"])
    dy = float(pivot["y"]) - float(position["y"])
    return {
        "x": round(float(pixel["x"]) + axes["x"]["x"] * dx + axes["y"]["x"] * dy, 2),
        "y": round(float(pixel["y"]) + axes["x"]["y"] * dx + axes["y"]["y"] * dy, 2),
    }


def _vec(vector: Vector2D) -> dict:
    return {"x": vector.x, "y": vector.y}


def _add_world_vectors(state: dict, plane: dict | None) -> None:
    """For ARKit clients, also give every vector in ARKit world space (metres, +y up), so
    a 3D renderer can anchor arrows in the scene. Physics itself runs in the plane's 2D
    coordinates; a vector (x, y) there is x * x_axis + y * y_axis in the world."""

    if not plane or "x_axis" not in plane or "y_axis" not in plane:
        return
    ex, ey = plane["x_axis"], plane["y_axis"]
    ez = plane.get("normal", [0.0, 0.0, 0.0])

    def lift(v: dict) -> dict:
        # z is out of the plane: only a support force (a table pushing up) has one.
        z = v.get("z", 0.0)
        return {axis: round(v["x"] * ex[i] + v["y"] * ey[i] + z * ez[i], 6) for i, axis in enumerate("xyz")}

    for key in ("velocity", "acceleration"):
        if state.get(key) is not None:
            state[f"{key}_3d"] = lift(state[key])
    state["forces_3d"] = [{"name": f["name"], **lift(f)} for f in state.get("forces", [])]
