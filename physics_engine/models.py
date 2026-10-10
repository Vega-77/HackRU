"""Model-derived forces and energy for the four experiment modes.

Measured velocity and acceleration come from :mod:`kinematics`. These helpers
only add quantities justified by the selected model and available geometry.
"""

from __future__ import annotations

from math import atan2, cos, degrees, hypot, radians, sin

from .kinematics import Vector2D

GRAVITY_MPS2 = 9.81


def _force(name: str, x: float, y: float) -> dict:
    return {"name": name, "x": x, "y": y}


def motion_model(
    mode: str | None,
    position: Vector2D,
    velocity: Vector2D,
    acceleration: Vector2D | None,
    mass_kg: float,
    settings: dict,
    initial_energy_j: float | None = None,
) -> dict:
    """Return protocol ``forces``, ``energy`` and ``extras`` for one body.

    ``acceleration=None`` means the numerical acceleration is not valid yet.
    The model never substitutes a predicted acceleration for a measurement.
    """

    if mass_kg <= 0:
        raise ValueError("mass_kg must be positive")
    forces = []
    extras = {}
    kinetic = 0.5 * mass_kg * velocity.magnitude**2
    energy = {"kinetic": kinetic}

    if mode in ("free_fall", "ramp", "pendulum"):
        forces.append(_force("gravity", 0.0, -mass_kg * GRAVITY_MPS2))

    if mode in ("free_fall", "ramp"):
        energy["potential"] = mass_kg * GRAVITY_MPS2 * position.y

    if mode == "ramp" and settings.get("ramp_angle_deg") is not None:
        angle = radians(float(settings["ramp_angle_deg"]))
        # Positive angle is a ramp rising toward +X. A negative angle rises
        # toward -X. The plane's normal points upward.
        tangent = Vector2D(cos(angle), sin(angle))
        normal = Vector2D(-sin(angle), cos(angle))
        normal_magnitude = mass_kg * GRAVITY_MPS2 * cos(angle)
        parallel_magnitude = -mass_kg * GRAVITY_MPS2 * sin(angle)
        forces.extend(
            [
                _force("normal", normal.x * normal_magnitude, normal.y * normal_magnitude),
                _force("gravity_parallel", tangent.x * parallel_magnitude, tangent.y * parallel_magnitude),
                _force(
                    "gravity_perpendicular",
                    -normal.x * normal_magnitude,
                    -normal.y * normal_magnitude,
                ),
            ]
        )
        extras["angle_deg"] = degrees(angle)
        if acceleration is not None:
            along = mass_kg * (acceleration.x * tangent.x + acceleration.y * tangent.y)
            residual = along - parallel_magnitude
            forces.append(_force("friction", residual * tangent.x, residual * tangent.y))
            # This coefficient assumes a sliding body and that the residual
            # tangential force is kinetic friction. A rolling ball does not
            # satisfy that assumption, so do not report mu by default.
            if settings.get("sliding_body") and normal_magnitude > 0:
                extras["mu"] = abs(residual) / normal_magnitude

    if mode == "pendulum" and settings.get("pendulum_pivot_m") is not None:
        pivot = settings["pendulum_pivot_m"]
        dx = position.x - float(pivot["x"])
        dy = position.y - float(pivot["y"])
        length = hypot(dx, dy)
        if length > 0:
            theta = atan2(dx, -dy)
            radial_out = Vector2D(dx / length, dy / length)
            tangent = Vector2D(-radial_out.y, radial_out.x)
            tangential_speed = velocity.x * tangent.x + velocity.y * tangent.y
            tension = mass_kg * (tangential_speed**2 / length + GRAVITY_MPS2 * cos(theta))
            forces.append(_force("tension", -radial_out.x * tension, -radial_out.y * tension))
            restoring = -mass_kg * GRAVITY_MPS2 * sin(theta)
            forces.append(_force("gravity_parallel", tangent.x * restoring, tangent.y * restoring))
            energy["potential"] = mass_kg * GRAVITY_MPS2 * length * (1 - cos(theta))
            extras.update({"theta_deg": degrees(theta), "length_m": length})

    if acceleration is not None:
        forces.append(_force("net", mass_kg * acceleration.x, mass_kg * acceleration.y))

    if mode == "ramp" and settings.get("sliding_body") and initial_energy_j is not None:
        current = energy.get("kinetic", 0.0) + energy.get("potential", 0.0)
        # A model estimate, not a direct measurement of heat. The caller
        # should show it only for a run that begins before the body moves.
        energy["thermal"] = max(0.0, initial_energy_j - current)

    if mode == "collision":
        extras["momentum_x"] = mass_kg * velocity.x
        extras["momentum_y"] = mass_kg * velocity.y

    return {"forces": forces, "energy": energy, "extras": extras}


def collision_metrics(
    before_a: Vector2D,
    before_b: Vector2D,
    after_a: Vector2D,
    after_b: Vector2D,
    mass_a_kg: float,
    mass_b_kg: float,
    axis: Vector2D,
) -> dict:
    """Momentum and restitution for a two-body collision along ``axis``.

    The signed axis points from body A toward body B before impact. Results
    require measured pre-impact and post-impact velocities, not just positions.
    """

    if mass_a_kg <= 0 or mass_b_kg <= 0:
        raise ValueError("collision masses must be positive")
    axis_length = axis.magnitude
    if axis_length == 0:
        raise ValueError("collision axis must be nonzero")
    ux, uy = axis.x / axis_length, axis.y / axis_length

    def along(vector: Vector2D) -> float:
        return vector.x * ux + vector.y * uy

    u_a, u_b = along(before_a), along(before_b)
    v_a, v_b = along(after_a), along(after_b)
    approach = u_a - u_b
    if approach <= 0:
        raise ValueError("bodies must be approaching before collision")
    momentum_before = mass_a_kg * u_a + mass_b_kg * u_b
    momentum_after = mass_a_kg * v_a + mass_b_kg * v_b
    kinetic_before = 0.5 * (mass_a_kg * u_a**2 + mass_b_kg * u_b**2)
    kinetic_after = 0.5 * (mass_a_kg * v_a**2 + mass_b_kg * v_b**2)
    return {
        "restitution": (v_b - v_a) / approach,
        "momentum_before": momentum_before,
        "momentum_after": momentum_after,
        "momentum_delta": momentum_after - momentum_before,
        "kinetic_before": kinetic_before,
        "kinetic_after": kinetic_after,
    }
