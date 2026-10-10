"""Per-connection spatial mapping state: which calibration is active and its latest fit.

Mappings are stored in the client's own pixel space (the image it sent) or in
normalized 0-1 image coordinates, so they do not depend on the server's working
resolution.
"""

from __future__ import annotations

import numpy as np

from cv_engine.calibration import ArucoCalibrator, PlaneMapping, rectangle_world_points
from cv_engine.preprocess import PreprocessedFrame

METHODS = ("none", "aruco", "manual")


class SpatialMapper:
    def __init__(self, aruco_hold_frames: int = 15) -> None:
        """aruco_hold_frames: keep using the last marker fit for this many frames when a
        marker is briefly covered (e.g. by a hand) before reporting the plane as lost."""
        self.aruco_hold_frames = aruco_hold_frames
        self.method = "none"
        self.mapping: PlaneMapping | None = None
        self.space = "px"  # "px" = client pixels, "norm" = 0-1 image fractions
        self._aruco: ArucoCalibrator | None = None
        self._frames_since_seen = 0
        self._settings: dict = {}

    def calibrate(self, request: dict) -> dict:
        """Apply a calibrate request. Raises ValueError (old setup kept) if it is invalid."""
        method = request.get("method", "aruco")
        if method not in METHODS:
            raise ValueError(f"method must be one of {METHODS}")
        world = _world_points(request) if method != "none" else None

        if method == "aruco":
            ids = tuple(request.get("marker_ids", (0, 1, 2, 3)))
            if len(ids) != 4:
                raise ValueError("marker_ids needs exactly 4 ids (TL, TR, BR, BL)")
            if len(world) != 4:
                raise ValueError("aruco calibration needs width_m and height_m")
            aruco = ArucoCalibrator(world, ids)
            self._aruco, self.mapping, self.space = aruco, None, "px"
            self._frames_since_seen = 0
        elif method == "manual":
            space = "norm" if request.get("normalized") else "px"
            self.mapping = PlaneMapping.fit(request.get("image_points", []), world, "manual")
            self._aruco, self.space = None, space
        else:
            self._aruco = self.mapping = None
        self.method = method
        self._settings = {k: v for k, v in request.items() if k != "type"}
        return self.status()

    def update(self, frame: PreprocessedFrame) -> None:
        """Re-detect markers on this frame (ArUco mode only)."""
        if self._aruco is None:
            return
        found = self._aruco.detect(frame.gray_sharp())
        if found is not None:
            # Fit was in working pixels; store it in client pixels.
            self.mapping = found.scaled(1 / frame.scale)
            self._frames_since_seen = 0
        else:
            self._frames_since_seen += 1
            if self._frames_since_seen > self.aruco_hold_frames:
                self.mapping = None

    def to_world(self, point_px: tuple[float, float], point_norm: tuple[float, float]) -> list[float] | None:
        if self.mapping is None:
            return None
        p = point_norm if self.space == "norm" else point_px
        x, y = self.mapping.image_to_world([p])[0]
        return [round(float(x), 4), round(float(y), 4)]

    def status(self, frame: PreprocessedFrame | None = None) -> dict:
        if self.method == "none":
            return {"method": "none", "status": "none"}
        if self.mapping is None:
            state = "searching" if self.method == "aruco" else "none"
        elif self.method == "aruco" and self._frames_since_seen > 0:
            state = "held"
        else:
            state = "ok"
        out = {"method": self.method, "status": state, "space": self.space, "settings": self._settings}
        if self.mapping is not None:
            # world -> image lets the renderer draw metric vectors onto the camera image.
            H = self.mapping.H_inv / self.mapping.H_inv[2, 2]
            out.update(
                {
                    "image_points": np.round(self.mapping.image_points, 2).tolist(),
                    "world_points": self.mapping.world_points.tolist(),
                    "world_to_image": np.round(H, 8).tolist(),
                    "reprojection_error_px": round(self.mapping.reprojection_error_px, 3),
                }
            )
        if self.method == "aruco":
            out["frames_since_seen"] = self._frames_since_seen
        return out


def _world_points(request: dict) -> np.ndarray:
    if "world_points" in request:
        return np.asarray(request["world_points"], np.float64).reshape(-1, 2)
    if "width_m" in request and "height_m" in request:
        return rectangle_world_points(float(request["width_m"]), float(request["height_m"]))
    raise ValueError("give width_m and height_m, or world_points")
