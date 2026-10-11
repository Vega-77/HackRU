"""Surfaces an object can rest against, in the calibrated plane's coordinates.

The physics stage (physics_engine/contact.py) decides when an object touches one and
how hard it pushes. This module only finds candidates, from three places:
  * ARKit plane anchors the phone found (ar_surfaces in the config), turned from world
    space into plane coordinates;
  * lines the user tapped on the surface edge (surface_px in the config), mapped
    through the calibration;
  * straight edges OpenCV finds right next to a tracked object (a ramp, a table edge,
    a wall), for clients with no ARKit.
Each comes out as {"id", "source", "point": [x, y, z], "normal": [x, y, z]}: x and y on
the plane, z out of it towards the camera.
"""

from __future__ import annotations

import math

import cv2
import numpy as np

from cv_engine.ar_plane import ArPlane
from cv_engine.preprocess import PreprocessedFrame

# Edge search around an object, in multiples of its size (the larger bbox side).
EDGE_SEARCH_PAD = 1.5
EDGE_MIN_LENGTH = 1.5
# The object's own outline is erased with an ellipse this much larger than its box.
OUTLINE_MASK_SCALE = 1.15
# Edges further than this from the object's rim (metres) are not where it rests.
EDGE_MAX_GAP_M = 0.03
# An ARKit plane this close in angle (cosine) and distance (metres) to the plane of
# motion is that same plane, already covered by the physics' plane support.
SAME_PLANE_COS = 0.98
SAME_PLANE_M = 0.03


def ar_surfaces(plane: ArPlane | None, requests: list[dict] | None) -> list[dict]:
    """ARKit plane anchors in plane coordinates, skipping the plane of motion itself."""
    if plane is None or not plane.has_basis or not requests:
        return []
    basis = np.vstack([plane.x_axis, plane.y_axis, plane.normal])
    out = []
    for k, request in enumerate(requests):
        try:
            p = np.asarray(request["point"], np.float64).reshape(3)
            n = np.asarray(request["normal"], np.float64).reshape(3)
        except (KeyError, TypeError, ValueError):
            continue
        if not (np.isfinite(p).all() and np.isfinite(n).all()) or np.linalg.norm(n) < 1e-6:
            continue
        n = n / np.linalg.norm(n)
        local_p = basis @ (p - plane.origin)
        local_n = basis @ n
        if abs(local_n[2]) > SAME_PLANE_COS and abs(local_p[2]) < SAME_PLANE_M:
            continue
        out.append({"id": f"ar:{request.get('id', k)}", "source": "ar_surface",
                    "point": _r(local_p), "normal": _r(local_n)})
    return out


def tapped_surfaces(spatial, frame: PreprocessedFrame, lines: list[dict] | None) -> list[dict]:
    """Surface edges the user marked with two taps each (client pixels), on the plane."""
    if not lines or spatial.mapping is None:
        return []
    out = []
    for k, line in enumerate(lines):
        ends = [_to_plane(spatial, frame, line[key]["x"], line[key]["y"]) for key in ("a", "b")]
        surface = _line_surface(*ends, f"tap:{k}", "tap")
        if surface is not None:
            out.append(surface)
    return out


def edge_surface(frame: PreprocessedFrame, obj: dict, spatial) -> list[dict]:
    """The straight edge an object is most likely resting on, from the image, as a
    one-item list (or empty). obj is a tracked object from track_to_json: client pixels
    for its box, plane metres for its position."""
    position, width_m = obj.get("position"), obj.get("width_m")
    height_m = obj.get("height_m") or width_m
    if spatial.mapping is None or position is None or not width_m:
        return []
    s = frame.scale
    b = obj["bbox"]
    x, y, w, h = b["x"] * s, b["y"] * s, b["w"] * s, b["h"] * s
    size = max(w, h)
    if size < 4:
        return []
    fh, fw = frame.gray.shape[:2]
    pad = EDGE_SEARCH_PAD * size
    x0, y0 = max(int(x - pad), 0), max(int(y - pad), 0)
    x1, y1 = min(int(x + w + pad), fw), min(int(y + h + pad), fh)
    if x1 - x0 < 8 or y1 - y0 < 8:
        return []
    edges = cv2.Canny(frame.gray[y0:y1, x0:x1], 40, 120)
    centre = (int(round(x + w / 2 - x0)), int(round(y + h / 2 - y0)))
    axes = (int(math.ceil(w / 2 * OUTLINE_MASK_SCALE)), int(math.ceil(h / 2 * OUTLINE_MASK_SCALE)))
    cv2.ellipse(edges, centre, axes, 0, 0, 360, 0, -1)
    # The gap lets a line that runs behind the erased outline join up again.
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=max(12, int(0.8 * size)),
                            minLineLength=EDGE_MIN_LENGTH * size, maxLineGap=size)
    if lines is None:
        return []
    best, best_gap = None, EDGE_MAX_GAP_M
    for ax, ay, bx, by in lines.reshape(-1, 4):
        a = _to_plane(spatial, frame, (ax + x0) / s, (ay + y0) / s)
        b2 = _to_plane(spatial, frame, (bx + x0) / s, (by + y0) / s)
        surface = _line_surface(a, b2, "edge", "edge")
        if surface is None:
            continue
        offset = np.subtract([position["x"], position["y"]], surface["point"][:2])
        nx, ny = surface["normal"][:2]
        radius = 0.5 * math.hypot(width_m * nx, height_m * ny)  # half the object along the normal
        gap = abs(abs(float(np.dot(offset, (nx, ny)))) - radius)
        if gap < best_gap:
            best, best_gap = surface, gap
    return [] if best is None else [best]


def _to_plane(spatial, frame: PreprocessedFrame, u: float, v: float):
    w, h = frame.source_size
    return spatial.to_world((u, v), (u / w, v / h))


def _line_surface(a, b, surface_id: str, source: str) -> dict | None:
    if a is None or b is None:
        return None
    d = np.subtract(b, a)
    length = float(np.hypot(*d))
    if length < 1e-4:
        return None
    normal = [-d[1] / length, d[0] / length, 0.0]
    return {"id": surface_id, "source": source, "point": [round(float(a[0]), 5), round(float(a[1]), 5), 0.0],
            "normal": [round(float(c), 5) for c in normal]}


def _r(v) -> list[float]:
    return [round(float(x), 5) for x in v]
