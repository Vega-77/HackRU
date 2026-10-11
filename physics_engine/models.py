"""Model-derived forces and energy for the four experiment modes.

Measured velocity and acceleration come from :mod:`kinematics`. These helpers
only add quantities justified by the selected model and available geometry.
"""

from __future__ import annotations

from math import atan2, cos, degrees, hypot, radians, sin, sqrt

from .kinematics import Vector2D

GRAVITY_MPS2 = 9.81


def _force(name: str, x: float, y: float, z: float = 0.0) -> dict:
    """A protocol force; ``z`` (out of the plane) only when there is one."""
    force = {"name": name, "x": x, "y": y}
    if abs(z) > 1e-9:
        force["z"] = z
    return force


def gravity_supports(gravity: tuple[float, float, float]) -> bool:
    """True when most of gravity points into the plane, so objects rest on the plane
    itself (a table, a tilted board) instead of moving across it (a board behind a ramp)."""
    g = sqrt(gravity[0] ** 2 + gravity[1] ** 2 + gravity[2] ** 2)
    return g > 0 and -gravity[2] >= 0.5 * g


def plane_tilt_deg(gravity: tuple[float, float, float]) -> float:
    """How far the plane is tilted from level, from the share of gravity lying in it."""
    return degrees(atan2(hypot(gravity[0], gravity[1]), abs(gravity[2])))


def motion_model(
    mode: str | None,
    position: Vector2D,
    velocity: Vector2D,
    acceleration: Vector2D | None,
    mass_kg: float,
    settings: dict,
    initial_energy_j: float | None = None,
    gravity: tuple[float, float, float] | None = None,
) -> dict:
    """Return protocol ``forces``, ``energy`` and ``extras`` for one body.

    ``acceleration=None`` means the numerical acceleration is not valid yet.
    The model never substitutes a predicted acceleration for a measurement.

    ``gravity`` is g (m/s^2) in the plane's coordinates, z out of the plane, from
    ``contact.gravity_in_plane``. The default is a side-on board: straight down -y.
    """

    if mass_kg <= 0:
        raise ValueError("mass_kg must be positive")
    forces = []
    extras = {}
    kinetic = 0.5 * mass_kg * velocity.magnitude**2
    energy = {"kinetic": kinetic}

    gx, gy, gz = gravity if gravity is not None else (0.0, -GRAVITY_MPS2, 0.0)

    if mode in ("free_fall", "ramp", "pendulum"):
        forces.append(_force("gravity", mass_kg * gx, mass_kg * gy, mass_kg * gz))

    if mode in ("free_fall", "ramp"):
        # Height is distance against gravity, which on a tilted plane is not y.
        energy["potential"] = -mass_kg * (gx * position.x + gy * position.y)

    if mode == "ramp" and gravity_supports((gx, gy, gz)):
        # The ball rolls on the picked plane itself, so the plane's tilt is the ramp
        # angle, known before anything moves. Gravity splits into the part along the
        # ramp (in the plane) and the part into it (out of the plane).
        g_in = hypot(gx, gy)
        down = Vector2D(gx / g_in, gy / g_in) if g_in > 1e-9 else Vector2D(0.0, 0.0)
        parallel_magnitude = mass_kg * g_in
        normal_magnitude = -mass_kg * gz
        if not settings.get("normal_from_contacts"):
            forces.append(_force("normal", 0.0, 0.0, normal_magnitude))
        forces.append(_force("gravity_parallel", mass_kg * gx, mass_kg * gy))
        forces.append(_force("gravity_perpendicular", 0.0, 0.0, mass_kg * gz))
        extras["angle_deg"] = plane_tilt_deg((gx, gy, gz))
        if acceleration is not None and g_in > 1e-9:
            along = mass_kg * (acceleration.x * down.x + acceleration.y * down.y)
            residual = along - parallel_magnitude
            forces.append(_force("friction", residual * down.x, residual * down.y))
            if settings.get("sliding_body") and normal_magnitude > 0:
                extras["mu"] = abs(residual) / normal_magnitude

    elif mode == "ramp" and settings.get("ramp_angle_deg") is not None:
        angle = radians(float(settings["ramp_angle_deg"]))
        # Positive angle is a ramp rising toward +X. A negative angle rises
        # toward -X. The plane's normal points upward.
        tangent = Vector2D(cos(angle), sin(angle))
        normal = Vector2D(-sin(angle), cos(angle))
        normal_magnitude = mass_kg * GRAVITY_MPS2 * cos(angle)
        parallel_magnitude = -mass_kg * GRAVITY_MPS2 * sin(angle)
        # A live session finds the normal force from contact instead (see contact.py),
        # so it is only shown while the ball is actually on the ramp.
        if not settings.get("normal_from_contacts"):
            forces.append(_force("normal", normal.x * normal_magnitude, normal.y * normal_magnitude))
        forces.extend(
            [
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
