"""Spatial mapping: pixel coordinates -> metric coordinates on the plane of motion.

A homography (perspective transform) maps points in the camera image onto a flat
plane measured in meters. It is exact for anything moving *in* that plane: a cart
on the table seen from above, or a ball rolling down a ramp / a pendulum swinging
in front of a vertical board. Calibrate the plane the object actually moves in.

World convention used by the rectangle helpers: origin at the bottom-left corner,
+X to the right, +Y up (on a vertical board +Y is against gravity; on a table seen
from the front it points away from the camera). Units are meters.

Two ways to calibrate:
  * ArUco markers (recommended, automatic): print markers 0-3 and place them at the
    corners of a rectangle of known size; the mapping is re-detected every frame,
    so a handheld phone can move freely.
  * Manual: the client sends four image points (e.g. table corners tapped on the
    screen) and the matching world points.
"""

from __future__ import annotations

from dataclasses import dataclass

import cv2
import numpy as np

# Corner order used everywhere: top-left, top-right, bottom-right, bottom-left (as seen in the image).
CORNER_NAMES = ("top_left", "top_right", "bottom_right", "bottom_left")


def rectangle_world_points(width_m: float, height_m: float) -> np.ndarray:
    """World coordinates of a width x height rectangle's corners, TL, TR, BR, BL."""
    if width_m <= 0 or height_m <= 0:
        raise ValueError("rectangle size must be positive")
    return np.array([[0, height_m], [width_m, height_m], [width_m, 0], [0, 0]], np.float64)


@dataclass
class PlaneMapping:
    """A homography between working-frame pixels and plane coordinates in meters."""

    H: np.ndarray  # 3x3, image (working px) -> world (m)
    H_inv: np.ndarray  # 3x3, world -> image
    image_points: np.ndarray  # Nx2 working px used to fit it
    world_points: np.ndarray  # Nx2 meters
    method: str  # "aruco" or "manual"
    reprojection_error_px: float  # mean distance between image points and reprojected world points

    @classmethod
    def fit(cls, image_points, world_points, method: str = "manual") -> PlaneMapping:
        img = np.asarray(image_points, np.float64).reshape(-1, 2)
        world = np.asarray(world_points, np.float64).reshape(-1, 2)
        if len(img) < 4 or len(img) != len(world):
            raise ValueError("need at least 4 matching image/world point pairs")
        if len(img) == 4:
            H = cv2.getPerspectiveTransform(img.astype(np.float32), world.astype(np.float32)).astype(np.float64)
        else:
            H, _ = cv2.findHomography(img, world, method=0)
        if H is None or not np.isfinite(H).all() or abs(np.linalg.det(H)) < 1e-12:
            raise ValueError("points are degenerate (three in a line, or repeated)")
        H_inv = np.linalg.inv(H)
        back = _apply(H_inv, world)
        err = float(np.mean(np.linalg.norm(back - img, axis=1)))
        return cls(H, H_inv, img, world, method, err)

    def image_to_world(self, points) -> np.ndarray:
        return _apply(self.H, np.asarray(points, np.float64).reshape(-1, 2))

    def world_to_image(self, points) -> np.ndarray:
        return _apply(self.H_inv, np.asarray(points, np.float64).reshape(-1, 2))

    def scaled(self, factor: float) -> PlaneMapping:
        """Same plane, for an image resized by `factor` (e.g. client px -> working px)."""
        return PlaneMapping.fit(self.image_points * factor, self.world_points, self.method)


def _apply(H: np.ndarray, pts: np.ndarray) -> np.ndarray:
    return cv2.perspectiveTransform(pts.reshape(-1, 1, 2), H).reshape(-1, 2)


class ArucoCalibrator:
    """Finds four ArUco markers at the corners of a known rectangle and fits the plane.

    Marker IDs map to corners in CORNER_NAMES order (default 0=TL, 1=TR, 2=BR, 3=BL).
    The marker *centers* are the rectangle corners, so measure width/height between
    marker centers. Extra point pairs from each marker's own corners would need the
    printed marker size; the four centers are enough for a good fit.
    """

    def __init__(
        self,
        world_points,
        marker_ids: tuple[int, int, int, int] = (0, 1, 2, 3),
        dictionary: int = cv2.aruco.DICT_4X4_50,
    ) -> None:
        """world_points: the 4 marker centers in meters, in marker_ids order
        (rectangle_world_points(w, h) for the usual rectangle layout)."""
        self.world = np.asarray(world_points, np.float64).reshape(4, 2)
        self.marker_ids = tuple(marker_ids)
        params = cv2.aruco.DetectorParameters()
        params.cornerRefinementMethod = cv2.aruco.CORNER_REFINE_SUBPIX
        self._detector = cv2.aruco.ArucoDetector(cv2.aruco.getPredefinedDictionary(dictionary), params)

    def detect(self, gray: np.ndarray) -> PlaneMapping | None:
        """Returns a mapping if all four markers are visible, else None."""
        corners, ids, _ = self._detector.detectMarkers(gray)
        if ids is None:
            return None
        centers = {int(i): c.reshape(4, 2).mean(axis=0) for i, c in zip(ids.flatten(), corners)}
        if not all(m in centers for m in self.marker_ids):
            return None
        img = np.array([centers[m] for m in self.marker_ids])
        try:
            return PlaneMapping.fit(img, self.world, "aruco")
        except ValueError:
            return None


def make_marker_sheet(
    width_m: float,
    height_m: float,
    marker_size_m: float = 0.05,
    dpi: int = 150,
    marker_ids: tuple[int, int, int, int] = (0, 1, 2, 3),
    dictionary: int = cv2.aruco.DICT_4X4_50,
) -> np.ndarray:
    """An image with the four markers centred on the corners of a width x height rectangle.

    Printed at `dpi` with no scaling, the distance between marker centers is exactly
    width_m x height_m. For rectangles bigger than a page, print markers individually
    with make_marker(), tape them down and measure the center-to-center distances.
    """
    px_per_m = dpi / 0.0254
    m = round(marker_size_m * px_per_m)
    margin = m  # quiet zone around markers
    w = round(width_m * px_per_m) + 2 * margin
    h = round(height_m * px_per_m) + 2 * margin
    sheet = np.full((h, w), 255, np.uint8)
    d = cv2.aruco.getPredefinedDictionary(dictionary)
    centers = [(margin, margin), (w - margin, margin), (w - margin, h - margin), (margin, h - margin)]
    cv2.rectangle(sheet, centers[0], centers[2], 180, 1)  # faint guide between centers, under the markers
    for mid, (cx, cy) in zip(marker_ids, centers):
        sheet[cy - m // 2 : cy - m // 2 + m, cx - m // 2 : cx - m // 2 + m] = cv2.aruco.generateImageMarker(d, mid, m)
        cv2.putText(sheet, f"id {mid}", (cx - m // 2, cy + m // 2 + 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, 0, 2)
    return sheet


def make_marker(marker_id: int, size_px: int = 600, dictionary: int = cv2.aruco.DICT_4X4_50) -> np.ndarray:
    d = cv2.aruco.getPredefinedDictionary(dictionary)
    img = np.full((size_px + size_px // 3, size_px + size_px // 3), 255, np.uint8)
    o = size_px // 6
    img[o : o + size_px, o : o + size_px] = cv2.aruco.generateImageMarker(d, marker_id, size_px)
    return img
