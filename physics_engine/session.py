"""Turn Dev 2 frame reports into the frontend's physics state protocol."""

from __future__ import annotations

from math import hypot, isfinite

from .kinematics import KinematicsEngine, KinematicsResult, Vector2D
from .models import GRAVITY_MPS2, collision_metrics, motion_model


# An object missing for longer than this starts a fresh history when it is seen again,
# matching KinematicsEngine's own gap rule. Shorter gaps (a blurred frame, a hand
# passing over) keep it, so velocity doesn't drop out for a single missed frame.
FORGET_AFTER_S = 0.5


class PhysicsSession:
    """One physics history per WebSocket connection and tracked object ID."""

    def __init__(self, window_size: int = 7) -> None:
        self.window_size = window_size
        self.engines: dict[int, KinematicsEngine] = {}
        self.initial_energy: dict[int, float] = {}
        self._last_seen: dict[int, float] = {}
        self._configuration: tuple | None = None
        self._calibration: tuple | None = None
        self._pre_collision: tuple | None = None
        self._last_collision: dict | None = None

    def reset(self) -> None:
        self.engines.clear()
        self.initial_energy.clear()
        self._last_seen.clear()
        self._pre_collision = None
        self._last_collision = None

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
            repr(settings.get("collision_masses_kg")),
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
            engine = self.engines.setdefault(
                object_id, KinematicsEngine(window_size=self.window_size, confidence_threshold=0.6)
            )
            result = engine.add_world_sample(
                timestamp, float(position["x"]), float(position["y"]),
                confidence=float(obj.get("score", 1.0)),
            )
            if result.tracking_valid:
                results[object_id] = result

        target_result = results.get(int(target["id"]))
        if target_result is None:
            return state

        if target_result.velocity_valid:
            state["velocity"] = _vec(target_result.velocity_mps)
            state["speed_mps"] = target_result.speed_mps
        if target_result.acceleration_valid:
            state["acceleration"] = _vec(target_result.acceleration_mps2)

        if target_result.velocity_valid:
            target_id = int(target["id"])
            model_settings = dict(settings)
            if mode == "ramp" and model_settings.get("ramp_angle_deg") is None:
                model_settings["ramp_angle_deg"] = self.engines[target_id].trajectory_angle_deg()
            if mode == "pendulum" and model_settings.get("pendulum_pivot_m") is None:
                estimated_pivot = self.engines[target_id].estimate_circle_center()
                if estimated_pivot is not None:
                    model_settings["pendulum_pivot_m"] = _vec(estimated_pivot)
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

        _add_world_vectors(state, calibration.get("plane"))

        if mode == "collision":
            state["collision_objects"] = [
                {
                    "id": obj["id"],
                    "position": obj["position"],
                    "velocity": _vec(results[int(obj["id"])].velocity_mps),
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


def _vec(vector: Vector2D) -> dict:
    return {"x": vector.x, "y": vector.y}


def _add_world_vectors(state: dict, plane: dict | None) -> None:
    """For ARKit clients, also give every vector in ARKit world space (metres, +y up), so
    a 3D renderer can anchor arrows in the scene. Physics itself runs in the plane's 2D
    coordinates; a vector (x, y) there is x * x_axis + y * y_axis in the world."""

    if not plane or "x_axis" not in plane or "y_axis" not in plane:
        return
    ex, ey = plane["x_axis"], plane["y_axis"]

    def lift(v: dict) -> dict:
        return {axis: round(v["x"] * ex[i] + v["y"] * ey[i], 6) for i, axis in enumerate("xyz")}

    for key in ("velocity", "acceleration"):
        if state.get(key) is not None:
            state[f"{key}_3d"] = lift(state[key])
    state["forces_3d"] = [{"name": f["name"], **lift(f)} for f in state.get("forces", [])]
