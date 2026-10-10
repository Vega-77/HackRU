"""ARKit spatial mapping: per-frame camera pose + a detected plane -> metric 3D positions.

On iOS the app runs an ARKit session. With every frame it sends the camera intrinsics
(in the pixels of the JPEG it sent) and the camera-to-world transform, and at setup it
sends one plane ARKit found (a point and a normal, in ARKit world coordinates: metres,
+Y up against gravity). A tracked centroid is then a ray from the camera; where that ray
meets the plane is the object's 3D position.

Rather than intersecting rays by hand, each frame builds the plane's homography from
the pose, so everything that already works with a PlaneMapping (to_world, object width,
world_to_image for the renderer, the debug overlay) works unchanged.

Plane coordinates (what the physics stage sees) use a fixed 2D basis on the plane,
chosen once from the first pose so it does not drift while the phone moves:
  * a vertical-ish plane (a board behind a ramp or pendulum): +x to the right as seen
    from the camera, +y straight up. Gravity is then exactly (0, -g).
  * a horizontal-ish plane (a table): +x to the right, +y away from the camera, the
    same convention the ArUco/manual calibrations use for a table.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

import numpy as np

from cv_engine.calibration import PlaneMapping

WORLD_UP = np.array([0.0, 1.0, 0.0])
# Planes tilted less than this from horizontal get the table basis (y away from camera).
HORIZONTAL_LIMIT_DEG = 30.0
# ARKit cameras look down -Z with +Y up; image pixels have y down. This flips camera
# axes into the OpenCV convention (x right, y down, z forward) used by K.
_ARKIT_TO_CV = np.diag([1.0, -1.0, -1.0])
# Plane points (metres) used to describe the mapping in status messages.
_REFERENCE_SQUARE = np.array([[0.0, 0.0], [0.2, 0.0], [0.2, 0.2], [0.0, 0.2]])


@dataclass(frozen=True)
class CameraPose:
    """One frame's camera, in the pixels of the image the client sent."""

    K: np.ndarray  # 3x3 intrinsics
    camera_to_world: np.ndarray  # 4x4, ARKit camera axes (x right, y up, z back)

    @property
    def rotation(self) -> np.ndarray:
        return self.camera_to_world[:3, :3]

    @property
    def position(self) -> np.ndarray:
        return self.camera_to_world[:3, 3]

    @property
    def forward(self) -> np.ndarray:
        return -self.rotation[:, 2]

    @classmethod
    def from_meta(cls, meta: dict) -> CameraPose | None:
        """Parse {"intrinsics": {fx, fy, cx, cy}, "camera_to_world": [16 numbers, row-major]}.
        Returns None when the frame has no pose; raises ValueError when it is malformed."""
        intr, c2w = meta.get("intrinsics"), meta.get("camera_to_world")
        if intr is None and c2w is None:
            return None
        if not isinstance(intr, dict) or not isinstance(c2w, list):
            raise ValueError("a pose needs intrinsics {fx, fy, cx, cy} and camera_to_world [16]")
        try:
            fx, fy, cx, cy = (float(intr[k]) for k in ("fx", "fy", "cx", "cy"))
            M = np.asarray(c2w, np.float64).reshape(4, 4)
        except (KeyError, TypeError, ValueError) as e:
            raise ValueError(f"bad pose: {e}") from e
        if not (all(map(math.isfinite, (fx, fy, cx, cy))) and np.isfinite(M).all()) or fx <= 0 or fy <= 0:
            raise ValueError("pose values must be finite with positive focal lengths")
        R = M[:3, :3]
        if not np.allclose(R.T @ R, np.eye(3), atol=1e-3):
            raise ValueError("camera_to_world rotation must be orthonormal")
        K = np.array([[fx, 0.0, cx], [0.0, fy, cy], [0.0, 0.0, 1.0]])
        return cls(K, M)

    def pixel_ray(self, u: float, v: float) -> tuple[np.ndarray, np.ndarray]:
        """World-space origin and unit direction of the ray through pixel (u, v)."""
        d_cv = np.linalg.solve(self.K, [u, v, 1.0])
        d = self.rotation @ (_ARKIT_TO_CV @ d_cv)
        return self.position, d / np.linalg.norm(d)


class ArPlane:
    """The plane the object moves on, from an ARKit raycast at setup."""

    def __init__(self, point, normal, offset_m: float = 0.0) -> None:
        p = np.asarray(point, np.float64).reshape(3)
        n = np.asarray(normal, np.float64).reshape(3)
        if not (np.isfinite(p).all() and np.isfinite(n).all()) or np.linalg.norm(n) < 1e-6:
            raise ValueError("ar_plane needs a finite point and a nonzero normal")
        if not math.isfinite(offset_m) or abs(offset_m) > 1.0:
            raise ValueError("ar_plane offset_m must be within 1 m")
        self.anchor = p
        self.normal = n / np.linalg.norm(n)
        self.offset_m = float(offset_m)
        self.x_axis: np.ndarray | None = None
        self.y_axis: np.ndarray | None = None

    @classmethod
    def from_request(cls, request: dict) -> ArPlane:
        if not isinstance(request, dict):
            raise ValueError("ar_plane must be an object with point and normal")
        try:
            return cls(request["point"], request["normal"], float(request.get("offset_m", 0.0)))
        except (KeyError, TypeError) as e:
            raise ValueError(f"ar_plane needs point [x, y, z] and normal [x, y, z]: {e}") from e

    @property
    def has_basis(self) -> bool:
        return self.x_axis is not None

    @property
    def origin(self) -> np.ndarray:
        """Plane origin, shifted along the normal by offset_m (e.g. a ball's radius, so
        positions are the ball's centre rather than where it touches the surface)."""
        return self.anchor + self.offset_m * self.normal

    def fix_basis(self, pose: CameraPose) -> None:
        """Pick the 2D axes once, from the camera that first sees the plane."""
        if self.has_basis:
            return
        # Face the normal towards the camera so "right" means right as seen by the user.
        if np.dot(self.normal, pose.position - self.anchor) < 0:
            self.normal = -self.normal
        up = WORLD_UP - np.dot(WORLD_UP, self.normal) * self.normal
        if np.linalg.norm(up) < math.sin(math.radians(HORIZONTAL_LIMIT_DEG)):
            # Table: y points away from the camera along the surface.
            up = pose.forward - np.dot(pose.forward, self.normal) * self.normal
            if np.linalg.norm(up) < 1e-6:  # looking straight down: use the phone's top edge
                up = pose.rotation[:, 1] - np.dot(pose.rotation[:, 1], self.normal) * self.normal
        self.y_axis = up / np.linalg.norm(up)
        self.x_axis = np.cross(self.y_axis, self.normal)

    def plane_to_world(self, xy) -> np.ndarray:
        x, y = float(xy[0]), float(xy[1])
        return self.origin + x * self.x_axis + y * self.y_axis

    def vector_to_world(self, xy) -> np.ndarray:
        return float(xy[0]) * self.x_axis + float(xy[1]) * self.y_axis

    def mapping(self, pose: CameraPose) -> PlaneMapping | None:
        """Homography between the client's pixels and plane metres for this camera pose,
        or None when the camera sees the plane edge-on or from behind."""
        self.fix_basis(pose)
        R_t = pose.rotation.T
        cols = np.column_stack([R_t @ self.x_axis, R_t @ self.y_axis, R_t @ (self.origin - pose.position)])
        H_inv = pose.K @ _ARKIT_TO_CV @ cols  # plane (x, y, 1) -> image
        # The plane must lie in front of the camera, and not be seen edge-on.
        depth = (_ARKIT_TO_CV @ cols)[2, 2]
        facing = abs(np.dot(self.normal, pose.forward))
        if depth <= 1e-3 or facing < 0.05 or abs(np.linalg.det(H_inv)) < 1e-12:
            return None
        H_inv = H_inv / H_inv[2, 2]
        H = np.linalg.inv(H_inv)
        world = _REFERENCE_SQUARE.copy()
        img = _project(H_inv, world)
        return PlaneMapping(H, H_inv, img, world, "arkit", 0.0)

    def describe(self) -> dict:
        out = {"point": _r(self.anchor), "normal": _r(self.normal), "offset_m": self.offset_m,
               "facing": "horizontal" if abs(self.normal[1]) > math.cos(math.radians(HORIZONTAL_LIMIT_DEG)) else "vertical"}
        if self.has_basis:
            out.update({"origin": _r(self.origin), "x_axis": _r(self.x_axis), "y_axis": _r(self.y_axis)})
        return out


def image_axes(mapping: PlaneMapping, xy) -> dict:
    """How the plane's +x and +y directions look on screen at plane point xy, in client
    pixels per metre (image y down). The renderer turns a vector (vx, vy) on the plane into
    the screen direction vx * x + vy * y, which is right even when the plane is tilted."""
    p = np.asarray(xy, np.float64).reshape(2)
    step = 0.01
    base, ex, ey = mapping.world_to_image([p, p + [step, 0.0], p + [0.0, step]])
    jx, jy = (ex - base) / step, (ey - base) / step
    return {"x": {"x": round(float(jx[0]), 2), "y": round(float(jx[1]), 2)},
            "y": {"x": round(float(jy[0]), 2), "y": round(float(jy[1]), 2)}}


def _project(H: np.ndarray, pts: np.ndarray) -> np.ndarray:
    h = np.column_stack([pts, np.ones(len(pts))]) @ H.T
    return h[:, :2] / h[:, 2:3]


def _r(v: np.ndarray) -> list[float]:
    return [round(float(x), 5) for x in v]
