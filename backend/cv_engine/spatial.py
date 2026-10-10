"""Per-connection spatial mapping state: which calibration is active and its latest fit.

Mappings are stored in the client's own pixel space (the image it sent) or in
normalized 0-1 image coordinates, so they do not depend on the server's working
resolution.
"""

from __future__ import annotations

import numpy as np

from cv_engine.ar_plane import ArPlane, CameraPose
from cv_engine.calibration import ArucoCalibrator, PlaneMapping, rectangle_world_points
from cv_engine.preprocess import PreprocessedFrame

# Requestable with a calibrate message. Two more come from the app's config: "arkit"
# (ar_plane, re-fit every frame from the camera pose) and "scale" (px_per_m).
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
        self.ar_plane: ArPlane | None = None
        self.pose: CameraPose | None = None  # the current frame's camera, ARKit clients only
        self.pose_error: str | None = None
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
            self.ar_plane = None
            self._frames_since_seen = 0
        elif method == "manual":
            space = "norm" if request.get("normalized") else "px"
            self.mapping = PlaneMapping.fit(request.get("image_points", []), world, "manual")
            self._aruco, self.space, self.ar_plane = None, space, None
        else:
            self._aruco = self.mapping = self.ar_plane = None
        self.method = method
        self._settings = {k: v for k, v in request.items() if k != "type"}
        return self.status()

    def set_scale(self, px_per_m: float | None, frame_size: dict | None) -> None:
        """Simple calibration from the app's ruler: a fixed pixels-per-meter scale, with the
        origin at the bottom-left of the frame and y up. It assumes the camera faces the
        plane of motion squarely; ArUco or manual calibration, if active, takes priority."""
        if self.method not in ("none", "scale"):
            return
        if px_per_m is None:
            self.method, self.mapping, self._settings = "none", None, {}
            return
        w, h = (float(frame_size["w"]), float(frame_size["h"])) if frame_size else (100.0, 0.0)
        # The frame's corners (TL, TR, BR, BL) and where they land in meters: (x / s, (h - y) / s).
        img = np.array([[0, 0], [w, 0], [w, h or 100.0], [0, h or 100.0]], np.float64)
        world = np.column_stack([img[:, 0] / px_per_m, (h - img[:, 1]) / px_per_m])
        self.mapping = PlaneMapping.fit(img, world, "scale")
        self.method, self.space = "scale", "px"
        self._settings = {"px_per_m": px_per_m, "frame_size": frame_size}

    def set_ar_plane(self, request: dict | None) -> None:
        """Plane from the app's ARKit raycast. It beats the ruler scale (it knows depth and
        tilt), but an explicit ArUco or manual calibration still takes priority. Raises
        ValueError (old setup kept) if the plane is invalid."""
        if self.method in ("aruco", "manual"):
            return
        if request is None:
            if self.method == "arkit":
                self.method, self.mapping, self.ar_plane, self._settings = "none", None, None, {}
            return
        if self.method == "arkit" and self._settings == request:
            return  # same plane re-sent with an unrelated config change: keep its basis
        plane = ArPlane.from_request(request)
        self.method, self.ar_plane, self.space = "arkit", plane, "px"
        self.mapping = None
        self._settings = dict(request)

    def update(self, frame: PreprocessedFrame) -> None:
        """Read this frame's camera pose (ARKit clients) and refresh the mapping: re-fit the
        ARKit plane to the new pose, or re-detect ArUco markers."""
        try:
            self.pose = CameraPose.from_meta(frame.meta)
            self.pose_error = None
        except ValueError as e:
            self.pose, self.pose_error = None, str(e)
        if self.ar_plane is not None:
            self.mapping = self.ar_plane.mapping(self.pose) if self.pose is not None else None
            return
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

    def to_world_3d(self, plane_xy) -> dict | None:
        """ARKit world coordinates (metres, y up) of a point on the calibrated plane."""
        if self.ar_plane is None or not self.ar_plane.has_basis or plane_xy is None:
            return None
        x, y, z = self.ar_plane.plane_to_world(plane_xy)
        return {"x": round(float(x), 4), "y": round(float(y), 4), "z": round(float(z), 4)}

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
            state = {"aruco": "searching", "arkit": "no_pose"}.get(self.method, "none")
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
        if self.ar_plane is not None:
            out["plane"] = self.ar_plane.describe()
            if self.pose_error:
                out["pose_error"] = self.pose_error
        return out


def _world_points(request: dict) -> np.ndarray:
    if "world_points" in request:
        return np.asarray(request["world_points"], np.float64).reshape(-1, 2)
    if "width_m" in request and "height_m" in request:
        return rectangle_world_points(float(request["width_m"]), float(request["height_m"]))
    raise ValueError("give width_m and height_m, or world_points")
