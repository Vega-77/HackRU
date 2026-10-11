"""Render synthetic test clips of the three lab experiments, with ground truth.

Each clip shows a 0.60 x 0.40 m vertical board with ArUco markers 0-3 at its corners
(the calibration rectangle), filmed by a slightly shaky, tilted handheld camera, with
sensor noise. The motion is simulated with real physics, and the true positions in
meters are written next to each clip as <name>_truth.csv, so the whole pipeline
(detection, tracking, mapping) can be scored, and the kinematics stage can be tested
against known velocities and accelerations.

    python samples/generate_samples.py          # writes samples/*.mp4 and *_truth.csv

Clips (30 fps, 1280x720):
  ramp      red ball rolling down a 25 degree incline (a = 5/7 g sin(theta))
  pendulum  blue bob, L = 0.28 m, released from 30 degrees, light damping
  carts     red cart at 0.25 m/s hits a resting green cart of equal mass (elastic)
"""

from __future__ import annotations

import csv
import math
import sys
from pathlib import Path

import cv2
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cv_engine.calibration import make_marker_sheet  # noqa: E402

BOARD_W, BOARD_H = 0.60, 0.40  # meters between marker centers
MARKER_M = 0.05
DPI = 100
PX_PER_M = DPI / 0.0254
MARGIN = round(MARKER_M * PX_PER_M)  # make_marker_sheet puts marker centers this far in
FPS = 30
OUT_SIZE = (1280, 720)
G = 9.81
RED, GREEN, BLUE, DARK = (0, 0, 230), (40, 190, 40), (220, 90, 20), (60, 60, 60)


def board_px(X: float, Y: float, h: int) -> tuple[float, float]:
    return MARGIN + X * PX_PER_M, h - MARGIN - Y * PX_PER_M


def base_board() -> np.ndarray:
    sheet = make_marker_sheet(BOARD_W, BOARD_H, marker_size_m=MARKER_M, dpi=DPI)
    board = cv2.cvtColor(sheet, cv2.COLOR_GRAY2BGR)
    board[sheet == 180] = (235, 235, 235)  # hide the guide line
    return cv2.addWeighted(board, 0.92, np.full_like(board, (200, 215, 225)), 0.08, 0)  # warm paper tint


def camera(board: np.ndarray, t: float, rng: np.random.Generator) -> np.ndarray:
    """A tilted view of the board with a little handheld wobble and sensor noise."""
    h, w = board.shape[:2]
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    base = np.float32([[230, 80], [1070, 120], [1130, 650], [170, 610]])
    wobble = np.float32([[math.sin(1.7 * t + i) * 6, math.cos(1.3 * t + 2 * i) * 5] for i in range(4)])
    M = cv2.getPerspectiveTransform(src, base + wobble)
    view = cv2.warpPerspective(board, M, OUT_SIZE, flags=cv2.INTER_AREA, borderValue=(70, 75, 80))
    noise = rng.normal(0, 4, view.shape)
    return np.clip(view.astype(np.float32) + noise, 0, 255).astype(np.uint8)


def square_camera(board: np.ndarray, t: float, rng: np.random.Generator) -> np.ndarray:
    """The board straight on, as the app's ruler scale assumes: no tilt, no wobble."""
    h, w = board.shape[:2]
    s = min(1180 / w, 680 / h)
    x0, y0 = (OUT_SIZE[0] - w * s) / 2, (OUT_SIZE[1] - h * s) / 2
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    dst = np.float32([[x0, y0], [x0 + w * s, y0], [x0 + w * s, y0 + h * s], [x0, y0 + h * s]])
    M = cv2.getPerspectiveTransform(src, dst)
    view = cv2.warpPerspective(board, M, OUT_SIZE, flags=cv2.INTER_AREA, borderValue=(70, 75, 80))
    noise = rng.normal(0, 4, view.shape)
    return np.clip(view.astype(np.float32) + noise, 0, 255).astype(np.uint8)


def circle(img, X, Y, r_m, color):
    cx, cy = board_px(X, Y, img.shape[0])
    cv2.circle(img, (round(cx), round(cy)), round(r_m * PX_PER_M), color, -1, cv2.LINE_AA)


def rect(img, X, Y, w_m, h_m, color):
    """Axis-aligned rectangle centered at (X, Y) meters."""
    x0, y0 = board_px(X - w_m / 2, Y + h_m / 2, img.shape[0])
    x1, y1 = board_px(X + w_m / 2, Y - h_m / 2, img.shape[0])
    cv2.rectangle(img, (round(x0), round(y0)), (round(x1), round(y1)), color, -1, cv2.LINE_AA)


def line(img, a, b, color, thickness=4):
    h = img.shape[0]
    pa, pb = board_px(*a, h), board_px(*b, h)
    cv2.line(img, tuple(map(round, pa)), tuple(map(round, pb)), color, thickness, cv2.LINE_AA)


def ramp_frames():
    theta = math.radians(25)
    r = 0.02
    top = np.array([0.06, 0.34])
    down = np.array([math.cos(theta), -math.sin(theta)])
    normal = np.array([math.sin(theta), math.cos(theta)])
    length = 0.55
    a = 5 / 7 * G * math.sin(theta)  # solid sphere rolling without slipping
    s0 = 0.02
    for k in range(int(FPS * 1.5)):
        t = k / FPS
        moving = max(0.0, t - 0.3)  # hold still briefly, then release
        s = min(s0 + 0.5 * a * moving**2, length - r)
        c = top + down * s + normal * r
        yield t, [("ball", "red", *c)], lambda img, c=c: (
            line(img, top - down * 0.01, top + down * length, DARK, 5),
            circle(img, *c, r, RED),
        )


def pendulum_frames():
    L, r, gamma = 0.28, 0.02, 0.15  # length, bob radius, damping (1/s)
    pivot = np.array([0.30, 0.37])
    th, om = math.radians(30), 0.0
    dt = 1 / (FPS * 20)
    for k in range(FPS * 4):
        t = k / FPS
        bob = pivot + L * np.array([math.sin(th), -math.cos(th)])
        yield t, [("bob", "blue", *bob)], lambda img, bob=bob: (
            line(img, pivot, bob, DARK, 2),
            circle(img, *pivot, 0.006, DARK),
            circle(img, *bob, r, BLUE),
        )
        for _ in range(20):  # semi-implicit Euler substeps
            om += (-G / L * math.sin(th) - gamma * om) * dt
            th += om * dt


def carts_frames():
    w, h, track_y = 0.07, 0.04, 0.06
    x1, v1 = 0.08, 0.25
    x2, v2 = 0.36, 0.0
    collided = False
    for k in range(FPS * 3):
        t = k / FPS
        y = track_y + h / 2
        yield t, [("cart1", "red", x1, y), ("cart2", "green", x2, y)], lambda img, x1=x1, x2=x2, y=y: (
            line(img, (0.0, track_y - 0.004), (BOARD_W, track_y - 0.004), DARK, 4),
            rect(img, x1, y, w, h, RED),
            rect(img, x2, y, w, h, GREEN),
        )
        x1, x2 = x1 + v1 / FPS, x2 + v2 / FPS
        if not collided and x2 - x1 <= w:  # equal masses, elastic: velocities swap
            v1, v2 = v2, v1
            collided = True
        x2 = min(x2, BOARD_W - w / 2)


def render(name: str, frames, out_dir: Path, view=camera) -> None:
    rng = np.random.default_rng(0)
    board = base_board()
    video = cv2.VideoWriter(str(out_dir / f"{name}.mp4"), cv2.VideoWriter_fourcc(*"mp4v"), FPS, OUT_SIZE)
    with open(out_dir / f"{name}_truth.csv", "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["frame", "t", "object", "color", "x_m", "y_m"])
        for k, (t, objects, draw) in enumerate(frames):
            img = board.copy()
            draw(img)
            video.write(view(img, t, rng))
            for obj, color, X, Y in objects:
                writer.writerow([k, f"{t:.4f}", obj, color, f"{X:.5f}", f"{Y:.5f}"])
    video.release()
    print(f"wrote {name}.mp4 and {name}_truth.csv")


def main() -> None:
    out = Path(__file__).resolve().parent
    render("ramp", ramp_frames(), out)
    render("pendulum", pendulum_frames(), out)
    render("carts", carts_frames(), out)
    # Filmed square on, for trying the pendulum with the app's ruler scale: the tilted
    # clip above needs ArUco calibration to keep its swing circular.
    render("pendulum_square", pendulum_frames(), out, view=square_camera)


if __name__ == "__main__":
    main()
