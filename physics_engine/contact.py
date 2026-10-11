"""Which surfaces and objects a body is resting against, and the normal forces they push with.

Everything here works in the calibrated plane's coordinates, extended to 3D: x and y on
the plane (metres, as the rest of the physics), z out of the plane towards the camera. A
surface is a plane in those coordinates: a point and a unit normal. A line drawn on a
side-on board (a ramp edge, the floor) is a surface with z = 0 in its normal; the plane
of motion itself, when the object sits on it (a table seen from above), is the one
surface whose normal is purely z.

A body touches a surface when two things hold:
  * it is about its own radius away from it, and
  * the surface has to push to explain the measured motion: N = m (a - g) . n > 0.
The second check is what turns the force off while a ball is in the air or bouncing
away, even when it is close to the surface. Each contact then has to hold for a few
frames before it is shown, or fail for a few before it is dropped, so arrows don't
flicker on tracking noise.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from math import cos, hypot, isfinite, radians, sin, sqrt

from .kinematics import Vector2D
from .models import gravity_supports

# A contact appears after this many frames in a row, and goes after this many misses.
ON_FRAMES = 2
OFF_FRAMES = 3
# Distance tolerance between a body's edge and a surface, metres, and as a share of
# the body's size (tracking noise grows with the object).
GAP_TOLERANCE_M = 0.012
GAP_TOLERANCE_SHARE = 0.25
# Smaller pushes than this share of the body's weight are noise, not contact.
MIN_PUSH_SHARE = 0.05
# Moving away from a surface faster than this is a bounce, not contact.
LEAVING_SPEED_MPS = 0.15
# Two surface normals closer than this (cosine) describe the same contact.
SAME_DIRECTION_COS = 0.94
# Where a surface came from, most trusted first: a duplicate of a better one is dropped.
SOURCE_PRIORITY = ("ar_plane", "ar_surface", "tap", "edge", "path", "ramp_angle")
# A straight stretch of path counts as a track when it is at least this long, this
# straight (RMS distance from the fitted line), and not steeper than this.
PATH_MIN_LENGTH_M = 0.04
PATH_MAX_RMS_M = 0.003
PATH_MAX_SLOPE_COS = 0.5  # 60 degrees
PATH_MIN_SAMPLES = 5


@dataclass(frozen=True)
class Surface:
    """A flat surface in plane coordinates (x, y on the plane, z towards the camera)."""

    id: str
    source: str
    point: tuple[float, float, float]
    normal: tuple[float, float, float]
    # The plane of motion itself: the body sits on it, so there is no distance to check.
    on_plane: bool = False

    @classmethod
    def from_dict(cls, data: dict) -> Surface | None:
        try:
            point = tuple(float(v) for v in data["point"])
            normal = tuple(float(v) for v in data["normal"])
        except (KeyError, TypeError, ValueError):
            return None
        if len(point) == 2:
            point = (*point, 0.0)
        if len(normal) == 2:
            normal = (*normal, 0.0)
        if len(point) != 3 or len(normal) != 3 or not all(map(isfinite, point + normal)):
            return None
        length = _norm(normal)
        if length < 1e-9:
            return None
        return cls(
            str(data.get("id", data.get("source", "surface"))),
            str(data.get("source", "surface")),
            point,
            _scale(normal, 1 / length),
            bool(data.get("on_plane", False)),
        )

    def to_dict(self) -> dict:
        out = {"id": self.id, "source": self.source, "point": _round(self.point), "normal": _round(self.normal)}
        if self.on_plane:
            out["on_plane"] = True
        return out


@dataclass
class Body:
    """One tracked object this frame."""

    id: int
    mass_kg: float
    position: Vector2D
    velocity: Vector2D | None
    acceleration: Vector2D | None
    width_m: float | None = None
    height_m: float | None = None

    def half_extent(self, n: tuple[float, float, float]) -> float:
        """Distance from the centre to the body's edge along n, treating it as an ellipse
        (a ball is a circle, a cart's box is close enough)."""
        w = self.width_m or self.height_m or 0.05
        h = self.height_m or w
        depth = min(w, h)  # unseen: assume it is as deep as its smaller visible side
        return 0.5 * sqrt((w * n[0]) ** 2 + (h * n[1]) ** 2 + (depth * n[2]) ** 2)

    @property
    def size(self) -> float:
        return max(self.width_m or 0.0, self.height_m or 0.0, 0.02)

    def vec3(self, v: Vector2D | None) -> tuple[float, float, float]:
        return (0.0, 0.0, 0.0) if v is None else (v.x, v.y, 0.0)


@dataclass
class _Hold:
    """Hysteresis for one (body, surface or other body) pair."""

    hits: int = 0
    misses: int = 0
    on: bool = False
    last: dict | None = None


@dataclass
class ContactTracker:
    """Contact state for one physics session."""

    holds: dict[tuple, _Hold] = field(default_factory=dict)
    paths: dict[int, Surface] = field(default_factory=dict)

    def reset(self) -> None:
        self.holds.clear()
        self.paths.clear()

    def forget(self, body_id: int) -> None:
        self.paths.pop(body_id, None)
        for key in [k for k in self.holds if body_id in k[:2]]:
            del self.holds[key]

    def learn_path(self, body: Body, samples: list[tuple[float, float]], gravity) -> None:
        """Remember the straight track a body rolled along as a surface, offset by its
        radius below the path. Only for side-on views, where gravity lies in the plane."""
        surface = path_surface(body, samples, gravity)
        if surface is not None:
            self.paths[body.id] = surface

    def update(
        self, bodies: list[Body], surfaces: dict[int, list[Surface]], gravity: tuple[float, float, float]
    ) -> dict[int, list[dict]]:
        """Return each body's contact forces this frame:
        {"name", "x", "y", "z", "source", "surface", "point"} in plane coordinates."""
        out: dict[int, list[dict]] = {b.id: [] for b in bodies}
        object_force: dict[int, tuple[float, float, float]] = {b.id: (0.0, 0.0, 0.0) for b in bodies}
        seen: set[tuple] = set()

        # Bodies against each other first: whatever push between them explains both
        # motions, equal and opposite (Newton's third law).
        for i, a in enumerate(bodies):
            for b in bodies[i + 1:]:
                key = (a.id, b.id, "body")
                seen.add(key)
                found = _body_contact(a, b, gravity)
                hold = self._hold(key, found)
                if hold is None:
                    continue
                magnitude, n_ab = hold["magnitude"], hold["normal"]
                for body, sign, other in ((a, 1.0, b), (b, -1.0, a)):
                    n = _scale(n_ab, sign)
                    f = _scale(n, magnitude)
                    object_force[body.id] = _add(object_force[body.id], f)
                    out[body.id].append(_force("normal_contact", f, f"object {other.id}", "object",
                                               _contact_point(body, n)))

        for body in bodies:
            candidates = list(surfaces.get(body.id, []))
            if body.id in self.paths:
                candidates.append(self.paths[body.id])
            candidates.sort(key=_priority)
            residual = _sub(_scale(_sub(body.vec3(body.acceleration), gravity), body.mass_kg), object_force[body.id])
            chosen: list[tuple[float, float, float]] = []
            for surface in candidates:
                key = (body.id, surface.id, "surface")
                if key in seen:
                    continue
                n = _facing(surface, body)
                if any(_dot(n, c) > SAME_DIRECTION_COS for c in chosen):
                    continue  # a better source already covers this direction
                seen.add(key)
                hold = self._hold(key, _surface_contact(body, surface, n, residual))
                if hold is None:
                    continue
                f = _scale(hold["normal"], hold["magnitude"])
                chosen.append(hold["normal"])
                residual = _sub(residual, f)
                out[body.id].append(_force("normal", f, surface.id, surface.source,
                                           None if surface.on_plane else _contact_point(body, hold["normal"])))
                if len(chosen) == 2:
                    break

        # Pairs not looked at this frame (a body left, a surface vanished) count as misses.
        for key in [k for k in self.holds if k not in seen]:
            self._hold(key, None)
        # The strongest push keeps the plain "normal" name; any second one is numbered.
        for forces in out.values():
            normals = sorted((f for f in forces if f["name"] == "normal"), key=lambda f: -_norm((f["x"], f["y"], f["z"])))
            for k, f in enumerate(normals[1:], start=2):
                f["name"] = f"normal_{k}"
        return out

    def _hold(self, key: tuple, found: dict | None) -> dict | None:
        hold = self.holds.setdefault(key, _Hold())
        if found is not None:
            hold.hits, hold.misses, hold.last = hold.hits + 1, 0, found
            if hold.hits >= ON_FRAMES:
                hold.on = True
        else:
            hold.hits, hold.misses = 0, hold.misses + 1
            if hold.misses >= OFF_FRAMES:
                hold.on = False
                hold.last = None
        if not hold.on:
            if hold.misses > OFF_FRAMES:
                del self.holds[key]  # long gone: stop carrying it
            return None
        return found or hold.last


def gravity_in_plane(plane: dict | None, view: str | None) -> tuple[float, float, float]:
    """Gravity (m/s^2) in plane coordinates. An ARKit plane knows its own axes; otherwise
    a side-on board has gravity along -y and a table seen from above along -z."""
    g = 9.81
    if plane and all(k in plane for k in ("x_axis", "y_axis", "normal")):
        down = (0.0, -g, 0.0)
        return tuple(_dot(down, tuple(plane[k])) for k in ("x_axis", "y_axis", "normal"))
    if view == "top":
        return (0.0, 0.0, -g)
    return (0.0, -g, 0.0)


def plane_support(gravity: tuple[float, float, float]) -> Surface | None:
    """The plane of motion itself, as a surface, when objects sit on it: when most of
    gravity points into it (a table, a tilted board), not along it (a board behind a ramp)."""
    if not gravity_supports(gravity):
        return None
    return Surface("plane", "ar_plane", (0.0, 0.0, 0.0), (0.0, 0.0, 1.0), on_plane=True)


def path_surface(body: Body, samples: list[tuple[float, float]], gravity) -> Surface | None:
    """The track under a body, from a straight stretch of its own path."""
    g_in = hypot(gravity[0], gravity[1])
    if len(samples) < PATH_MIN_SAMPLES or g_in < 0.5 * _norm(gravity):
        return None
    n = len(samples)
    mx = sum(p[0] for p in samples) / n
    my = sum(p[1] for p in samples) / n
    sxx = sum((p[0] - mx) ** 2 for p in samples)
    syy = sum((p[1] - my) ** 2 for p in samples)
    sxy = sum((p[0] - mx) * (p[1] - my) for p in samples)
    # Principal direction of the points: the line they lie along.
    angle_dir = _principal(sxx, syy, sxy)
    dx, dy = angle_dir
    length = max(p[0] * dx + p[1] * dy for p in samples) - min(p[0] * dx + p[1] * dy for p in samples)
    if length < PATH_MIN_LENGTH_M:
        return None
    rms = sqrt(sum(((p[0] - mx) * -dy + (p[1] - my) * dx) ** 2 for p in samples) / n)
    if rms > PATH_MAX_RMS_M:
        return None
    # The side of the line gravity points to is the track; its normal points back up.
    up = (-gravity[0] / g_in, -gravity[1] / g_in)
    nx, ny = -dy, dx
    if nx * up[0] + ny * up[1] < 0:
        nx, ny = -nx, -ny
    if nx * up[0] + ny * up[1] < PATH_MAX_SLOPE_COS:
        return None  # too steep to be a track: a fall, or a swing
    normal = (nx, ny, 0.0)
    r = body.half_extent(normal)
    point = (mx - nx * r, my - ny * r, 0.0)
    return Surface("path", "path", point, normal)


def ramp_surface(body: Body, angle_deg: float) -> Surface:
    """A ramp of a known angle (typed in, or from the path's overall slope), right under
    the body. It says nothing about where the ramp ends, so only the push check decides
    contact: a ball flying off the end falls freely and needs no push."""
    angle = radians(angle_deg)
    normal = (-sin(angle), cos(angle), 0.0)
    r = body.half_extent(normal)
    point = (body.position.x - normal[0] * r, body.position.y - normal[1] * r, 0.0)
    return Surface("ramp_angle", "ramp_angle", point, normal)


def _body_contact(a: Body, b: Body, gravity) -> dict | None:
    d = (a.position.x - b.position.x, a.position.y - b.position.y, 0.0)
    distance = _norm(d)
    if distance < 1e-6:
        return None
    n = _scale(d, 1 / distance)  # from b towards a
    gap = distance - a.half_extent(n) - b.half_extent(n)
    tolerance = max(GAP_TOLERANCE_M, GAP_TOLERANCE_SHARE * min(a.size, b.size))
    if gap > tolerance:
        return None
    # No check for moving apart here, unlike surfaces: a collision's push lasts a few
    # milliseconds, so by the frame the acceleration shows it the objects already separate.
    push_a = a.mass_kg * _dot(_sub(a.vec3(a.acceleration), gravity), n)
    push_b = -b.mass_kg * _dot(_sub(b.vec3(b.acceleration), gravity), n)
    # Both motions agree: take the mean. Only one needs a push (one ball on top of
    # another, held up by the table): that one is the contact force.
    if push_a > 0 and push_b > 0:
        magnitude = 0.5 * (push_a + push_b)
    else:
        magnitude = max(push_a, push_b)
    weight = min(a.mass_kg, b.mass_kg) * max(_norm(gravity), 1.0)
    if magnitude < MIN_PUSH_SHARE * weight:
        return None
    return {"magnitude": magnitude, "normal": n}


def _surface_contact(body: Body, surface: Surface, n, residual) -> dict | None:
    if not surface.on_plane:
        offset = _sub((body.position.x, body.position.y, 0.0), surface.point)
        gap = _dot(offset, n) - body.half_extent(n)
        tolerance = max(GAP_TOLERANCE_M, GAP_TOLERANCE_SHARE * body.size)
        # A body seen a little inside the surface (tracking noise, a thick drawn edge) is
        # still on it; one more than its own radius inside is on the other side.
        if gap > tolerance or gap < -max(tolerance, body.half_extent(n)):
            return None
    if body.velocity is not None and _dot(body.vec3(body.velocity), n) > LEAVING_SPEED_MPS:
        return None
    magnitude = _dot(residual, n)
    if magnitude < MIN_PUSH_SHARE * body.mass_kg * 9.81:
        return None
    return {"magnitude": magnitude, "normal": n}


def _facing(surface: Surface, body: Body):
    """The surface normal, turned to point at the body."""
    if surface.on_plane:
        return surface.normal
    offset = _sub((body.position.x, body.position.y, 0.0), surface.point)
    return surface.normal if _dot(offset, surface.normal) >= 0 else _scale(surface.normal, -1.0)


def _contact_point(body: Body, n) -> dict:
    r = body.half_extent(n)
    return {"x": round(body.position.x - n[0] * r, 5), "y": round(body.position.y - n[1] * r, 5)}


def _force(name: str, f, surface_id: str, source: str, point: dict | None) -> dict:
    out = {"name": name, "x": f[0], "y": f[1], "z": f[2], "surface": surface_id, "source": source}
    if point is not None:
        out["point"] = point
    return out


def _priority(surface: Surface) -> int:
    return SOURCE_PRIORITY.index(surface.source) if surface.source in SOURCE_PRIORITY else len(SOURCE_PRIORITY)


def _principal(sxx: float, syy: float, sxy: float) -> tuple[float, float]:
    trace_half = (sxx + syy) / 2
    det = sxx * syy - sxy * sxy
    lam = trace_half + sqrt(max(trace_half**2 - det, 0.0))
    if abs(sxy) > 1e-12:
        v = (lam - syy, sxy)
    else:
        v = (1.0, 0.0) if sxx >= syy else (0.0, 1.0)
    length = hypot(*v)
    return v[0] / length, v[1] / length


def _dot(a, b) -> float:
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _scale(a, k: float):
    return (a[0] * k, a[1] * k, a[2] * k)


def _norm(a) -> float:
    return sqrt(_dot(a, a))


def _round(v) -> list[float]:
    return [round(float(x), 5) for x in v]
