"""Debug overlay: draws a frame result (the same JSON the app receives) onto the image.

Because it only reads the result JSON, what you see here is exactly what the mobile
app is told: boxes, IDs, centroids, trails, metric positions and the calibrated plane.
"""

from __future__ import annotations

from collections import deque

import cv2
import numpy as np

# BGR colors for labels; anything else gets a stable color from its track ID.
LABEL_COLORS = {
    "red": (60, 60, 255),
    "orange": (0, 150, 255),
    "yellow": (0, 230, 255),
    "green": (80, 220, 80),
    "blue": (255, 140, 40),
    "purple": (220, 80, 200),
}
PLANE_COLOR = (255, 255, 0)
FONT = cv2.FONT_HERSHEY_SIMPLEX


def _id_color(i: int) -> tuple[int, int, int]:
    hue = (i * 47) % 180
    bgr = cv2.cvtColor(np.uint8([[[hue, 200, 255]]]), cv2.COLOR_HSV2BGR)[0, 0]
    return int(bgr[0]), int(bgr[1]), int(bgr[2])


class TrailHistory:
    """Remembers recent centroids per track ID across frames, for drawing trails."""

    def __init__(self, length: int = 40, forget_after: int = 30) -> None:
        self.length = length
        self.forget_after = forget_after
        self._trails: dict[int, deque] = {}
        self._last_seen: dict[int, int] = {}
        self._frame = 0

    def update(self, objects: list[dict]) -> dict[int, deque]:
        self._frame += 1
        for o in objects:
            self._trails.setdefault(o["id"], deque(maxlen=self.length)).append((o["pixel"]["x"], o["pixel"]["y"]))
            self._last_seen[o["id"]] = self._frame
        for i in [i for i, f in self._last_seen.items() if self._frame - f > self.forget_after]:
            del self._trails[i], self._last_seen[i]
        return self._trails


def _to_px(pt, space: str, size: tuple[int, int]) -> tuple[int, int]:
    x, y = pt
    if space == "norm":
        x, y = x * size[0], y * size[1]
    return int(round(x)), int(round(y))


def draw_plane(img: np.ndarray, calibration: dict, grid_m: float = 0.05) -> None:
    """Outline the calibrated rectangle with a metric grid and the +X / +Y axes."""
    if "world_to_image" not in calibration:
        return
    H = np.array(calibration["world_to_image"], np.float64)
    space = calibration.get("space", "px")
    size = (img.shape[1], img.shape[0])
    world = np.array(calibration["world_points"], np.float64)
    (x0, y0), (x1, y1) = world.min(axis=0), world.max(axis=0)

    def project(pts):
        p = cv2.perspectiveTransform(np.asarray(pts, np.float64).reshape(-1, 1, 2), H).reshape(-1, 2)
        return [_to_px(q, space, size) for q in p]

    layer = img.copy()
    for gx in np.arange(x0, x1 + 1e-9, grid_m):
        a, b = project([[gx, y0], [gx, y1]])
        cv2.line(layer, a, b, PLANE_COLOR, 1, cv2.LINE_AA)
    for gy in np.arange(y0, y1 + 1e-9, grid_m):
        a, b = project([[x0, gy], [x1, gy]])
        cv2.line(layer, a, b, PLANE_COLOR, 1, cv2.LINE_AA)
    cv2.addWeighted(layer, 0.35, img, 0.65, 0, dst=img)

    corners = project(world)
    cv2.polylines(img, [np.array(corners, np.int32)], True, PLANE_COLOR, 2, cv2.LINE_AA)
    origin, ax, ay = project([[x0, y0], [x0 + 0.1, y0], [x0, y0 + 0.1]])
    cv2.arrowedLine(img, origin, ax, (0, 0, 255), 2, cv2.LINE_AA, tipLength=0.2)
    cv2.arrowedLine(img, origin, ay, (0, 255, 0), 2, cv2.LINE_AA, tipLength=0.2)
    cv2.putText(img, "+X", ax, FONT, 0.5, (0, 0, 255), 1, cv2.LINE_AA)
    cv2.putText(img, "+Y", ay, FONT, 0.5, (0, 255, 0), 1, cv2.LINE_AA)


def draw_overlay(img: np.ndarray, result: dict, trail_map: dict[int, deque] | None = None) -> np.ndarray:
    """Draw `result` onto a copy of `img` (the image the client sent) and return it.

    trail_map comes from TrailHistory.update(), called once per frame result.
    """
    out = img.copy()
    calibration = result.get("calibration", {})
    draw_plane(out, calibration)
    objects = result.get("objects", [])
    trail_map = trail_map or {}

    for o in objects:
        color = LABEL_COLORS.get(o["label"], _id_color(o["id"]))
        trail = trail_map.get(o["id"])
        if trail and len(trail) > 1:
            pts = np.array(trail, np.int32)
            for k in range(1, len(pts)):
                thickness = 1 + 3 * k // len(pts)  # thicker toward the newest point
                cv2.line(out, tuple(pts[k - 1]), tuple(pts[k]), color, thickness, cv2.LINE_AA)
        b = o["bbox"]
        x, y, w, h = (int(round(b[k])) for k in "xywh")
        cx, cy = int(round(o["pixel"]["x"])), int(round(o["pixel"]["y"]))
        cv2.rectangle(out, (x, y), (x + w, y + h), color, 4 if o.get("target") else 2, cv2.LINE_AA)
        cv2.drawMarker(out, (cx, cy), (255, 255, 255), cv2.MARKER_CROSS, 12, 2, cv2.LINE_AA)
        label = f"#{o['id']} {o['label']}" + (" [target]" if o.get("target") else "")
        if o.get("position"):
            label += f"  ({o['position']['x']:.3f}, {o['position']['y']:.3f}) m"
        _text_box(out, label, (x, max(14, y - 6)), color)

    _hud(out, result)
    return out


def _text_box(img, text, org, color, scale=0.5) -> None:
    (tw, th), base = cv2.getTextSize(text, FONT, scale, 1)
    x, y = org
    cv2.rectangle(img, (x, y - th - 4), (x + tw + 6, y + base), (0, 0, 0), -1)
    cv2.putText(img, text, (x + 3, y - 2), FONT, scale, color, 1, cv2.LINE_AA)


def _hud(img, result: dict) -> None:
    stats = result.get("stats", {})
    cal = result.get("calibration", {})
    timing = f"process {result.get('process_ms', 0):.1f} ms"
    if "latency_ms" in result:
        timing += f"  latency {result['latency_ms']:.1f} ms"
    lines = [f"frame {result.get('frame_id', '?')}  objects {len(result.get('objects', []))}", timing]
    if stats:  # only for live streams
        lines.append(f"received {stats.get('received', 0)}  dropped {stats.get('dropped', 0)}")
    lines.append(f"plane: {cal.get('method', 'none')} {cal.get('status', '')}")
    for i, line in enumerate(lines):
        _text_box(img, line, (8, 22 + 20 * i), (255, 255, 255))
