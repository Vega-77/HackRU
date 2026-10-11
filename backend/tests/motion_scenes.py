"""Synthetic clips of a selected object moving the way it does in real experiments.

Each clip is what the app streams: 320 x 240 JPEGs at quality 70 and 15 fps, with
ground truth for every frame. The objects roll (their pattern rotates), blur while
they move fast, pass over textured backgrounds and under changing light, and the
"camera" wobbles by a pixel or two like a handheld phone. These are the conditions
that broke the selected-object tracker; they are not a substitute for real footage.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

import cv2
import numpy as np

W, H = 320, 240
FPS = 15.0


@dataclass
class Clip:
    name: str
    frames: list[bytes]  # JPEG bytes
    truth: list[tuple[float, float] | None]  # object centre in frame pixels, None when hidden
    diameter: float
    box: dict  # selection box on frame 0, frame pixels
    timestamps: list[float] = field(default_factory=list)

    @property
    def tap(self) -> dict:
        return {"x": self.box["x"] + self.box["w"] / 2, "y": self.box["y"] + self.box["h"] / 2}


def _background(seed: int, base=(110, 100, 90)) -> np.ndarray:
    """A table or wall: low-frequency blotches, fine grain and a few hard-edged objects."""
    rng = np.random.default_rng(seed)
    low = cv2.resize(rng.normal(0, 18, (6, 8, 3)).astype(np.float32), (W, H), interpolation=cv2.INTER_CUBIC)
    grain = rng.normal(0, 6, (H, W, 3)).astype(np.float32)
    img = np.clip(np.array(base, np.float32) + low + grain, 0, 255).astype(np.uint8)
    for _ in range(5):
        x, y = int(rng.integers(0, W - 40)), int(rng.integers(0, H - 30))
        color = tuple(int(c) for c in rng.integers(40, 200, 3))
        cv2.rectangle(img, (x, y), (x + int(rng.integers(15, 45)), y + int(rng.integers(10, 30))), color, -1)
    return img


def _ball_sprite(radius: int, angle: float, colors) -> tuple[np.ndarray, np.ndarray]:
    """A ball with a two-tone pattern rotated by `angle`, as an image and alpha mask."""
    size = 2 * radius + 3
    c = size / 2
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) + 0.5
    dx, dy = xx - c, yy - c
    r = np.hypot(dx, dy)
    alpha = np.clip(radius + 0.5 - r, 0, 1)
    # A seam that turns with the ball, like a tennis ball's curve or a stripe.
    u = dx * math.cos(angle) + dy * math.sin(angle)
    v = -dx * math.sin(angle) + dy * math.cos(angle)
    seam = np.abs(u - 0.35 * radius * np.sin(v / radius * 2.2)) < radius * 0.18
    img = np.empty((size, size, 3), np.float32)
    img[:] = colors[0]
    img[seam] = colors[1]
    shade = np.clip(1.15 - 0.45 * (np.hypot(dx + radius * 0.35, dy + radius * 0.35) / radius), 0.55, 1.15)
    return np.clip(img * shade[..., None], 0, 255), alpha


def _paste(canvas: np.ndarray, sprite: np.ndarray, alpha: np.ndarray, centre: tuple[float, float]) -> None:
    size = sprite.shape[0]
    M = np.float32([[1, 0, centre[0] - size / 2], [0, 1, centre[1] - size / 2]])
    s = cv2.warpAffine(sprite, M, (W, H), flags=cv2.INTER_LINEAR, borderValue=0)
    a = cv2.warpAffine(alpha, M, (W, H), flags=cv2.INTER_LINEAR, borderValue=0)[..., None]
    canvas[:] = canvas * (1 - a) + s * a


def _render(background: np.ndarray, draw, t: float, blur_steps: int, shake, light: float) -> np.ndarray:
    """Average sub-frames across the exposure for motion blur, then shake and relight."""
    acc = np.zeros((H, W, 3), np.float32)
    for k in range(blur_steps):
        canvas = background.astype(np.float32).copy()
        draw(canvas, t + k / (blur_steps * FPS) * 0.6)  # 0.6 of the frame interval exposed
        acc += canvas
    img = acc / blur_steps * light
    M = np.float32([[1, 0, shake[0]], [0, 1, shake[1]]])
    img = cv2.warpAffine(np.clip(img, 0, 255).astype(np.uint8), M, (W, H), borderMode=cv2.BORDER_REPLICATE)
    return img


def _encode(img: np.ndarray) -> bytes:
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 70])
    assert ok
    return buf.tobytes()


def _clip(name, n, seed, position, sprite, radius, *, base=(110, 100, 90), light=lambda t: 1.0,
          extra=None, hidden=lambda t: False, occluder=None) -> Clip:
    rng = np.random.default_rng(seed + 1)
    background = _background(seed, base)
    frames, truth, stamps = [], [], []
    for i in range(n):
        t = i / FPS
        shake = rng.normal(0, 0.8, 2) if i else (0.0, 0.0)

        def draw(canvas, tt):
            if extra:
                extra(canvas, tt)
            if not hidden(tt):
                spr, alpha = sprite(tt)
                _paste(canvas, spr, alpha, position(tt))
            if occluder:
                occluder(canvas, tt)

        img = _render(background, draw, t, 6, shake, light(t))
        frames.append(_encode(img))
        stamps.append(t)
        cx, cy = position(t + 0.3 / FPS)  # the middle of the exposure
        visible = not hidden(t) and not (occluder and occluder.covers(t, (cx, cy)))
        truth.append((cx + shake[0], cy + shake[1]) if visible else None)
    x, y = position(0.0)
    pad = 2
    box = {"x": x - radius - pad, "y": y - radius - pad, "w": 2 * (radius + pad), "h": 2 * (radius + pad)}
    return Clip(name, frames, truth, 2 * radius, box, stamps)


def ramp_roll() -> Clip:
    """A tennis ball rolling down a ramp from rest, rotating as it goes."""
    r = 11
    start, angle = np.array([40.0, 60.0]), math.radians(25)
    along = np.array([math.cos(angle), math.sin(angle)])
    accel = 260.0  # px/s^2 along the ramp

    def pos(t):
        return tuple(start + along * 0.5 * accel * t * t)

    def sprite(t):
        return _ball_sprite(r, 0.5 * accel * t * t / r, ((60, 220, 200), (235, 240, 240)))

    def ramp(canvas, t):
        p0 = start - along * 30 + np.array([0, r + 1])
        p1 = start + along * 330 + np.array([0, r + 1])
        cv2.line(canvas, tuple(int(v) for v in p0), tuple(int(v) for v in p1), (70, 90, 120), 4)

    return _clip("ramp_roll", 22, 3, pos, sprite, r, extra=ramp)


def pendulum() -> Clip:
    """An orange bob on a string, swinging across a cluttered wall."""
    r = 12
    pivot = np.array([160.0, 20.0])
    length, amp, period = 170.0, 0.6, 1.8

    def pos(t):
        a = amp * math.cos(2 * math.pi * t / period)
        return tuple(pivot + length * np.array([math.sin(a), math.cos(a)]))

    def sprite(t):
        return _ball_sprite(r, amp * math.cos(2 * math.pi * t / period) * 3, ((40, 130, 240), (30, 60, 150)))

    def string(canvas, t):
        x, y = pos(t)
        cv2.line(canvas, (160, 20), (int(x), int(y)), (200, 200, 200), 1)

    return _clip("pendulum", 40, 5, pos, sprite, r, base=(150, 145, 140), extra=string)


def toss() -> Clip:
    """A ball tossed up and across, falling under gravity: fast and blurred near the end."""
    r = 10
    g = 600.0  # px/s^2

    def pos(t):
        return (30 + 170 * t, 200 - 330 * t + 0.5 * g * t * t)

    def sprite(t):
        return _ball_sprite(r, 4 * t, ((50, 50, 210), (230, 230, 230)))

    return _clip("toss", 15, 7, pos, sprite, r)


def grey_box_slide() -> Clip:
    """A grey printed box (no detector colour) sliding across a table while the light dims."""
    w, h = 34, 24
    rng = np.random.default_rng(11)
    label = np.full((h, w, 3), 150, np.float32)
    label[4:8, 4:30] = 60
    label[11:13, 4:22] = 90
    label[16:20, 4:14] = 40
    label += rng.normal(0, 4, label.shape)
    alpha = np.ones((h, w), np.float32)

    def pos(t):
        return (50 + 140 * t - 25 * t * t, 140 + 6 * math.sin(3 * t))

    def sprite(t):
        return label, alpha

    clip = _clip("grey_box_slide", 30, 13, pos, sprite, 0, base=(120, 110, 95),
                 light=lambda t: 1.0 - 0.25 * min(1.0, t / 1.5))
    x, y = pos(0.0)
    clip.box = {"x": x - w / 2 - 2, "y": y - h / 2 - 2, "w": w + 4, "h": h + 4}
    clip.diameter = float(max(w, h))
    return clip


class _Hand:
    """A skin-coloured hand that sweeps across the middle of the clip."""

    def __init__(self, t0: float, t1: float, y: float):
        self.t0, self.t1, self.y = t0, t1, y

    def x(self, t):
        return -60 + (t - self.t0) / (self.t1 - self.t0) * 440

    def __call__(self, canvas, t):
        if self.t0 <= t <= self.t1:
            cv2.ellipse(canvas, (int(self.x(t)), int(self.y)), (45, 30), 0, 0, 360, (120, 150, 205), -1)

    def covers(self, t, p):
        if not self.t0 <= t <= self.t1:
            return False
        return ((p[0] - self.x(t)) / 45) ** 2 + ((p[1] - self.y) / 30) ** 2 < 1.4


def occluded_roll() -> Clip:
    """A ball rolling across while a hand passes over it."""
    r = 11

    def pos(t):
        return (40 + 110 * t, 130.0)

    def sprite(t):
        return _ball_sprite(r, 110 * t / r, ((30, 30, 200), (40, 200, 230)))

    return _clip("occluded_roll", 36, 17, pos, sprite, r, occluder=_Hand(0.9, 1.35, 130))


def distractor_roll() -> Clip:
    """The selected ball rolls past a still ball of the same colour."""
    r = 11
    still, _ = _ball_sprite(r, 0.0, ((40, 40, 200), (230, 230, 230))), None

    def pos(t):
        return (40 + 120 * t, 90 + 40 * t)

    def sprite(t):
        return _ball_sprite(r, 120 * t / r, ((40, 40, 200), (230, 230, 230)))

    def other(canvas, t):
        spr, alpha = still
        _paste(canvas, spr, alpha, (250.0, 60.0))

    return _clip("distractor_roll", 30, 19, pos, sprite, r, extra=other)


def fast_red_roll() -> Clip:
    """A red ball (its hue on both sides of OpenCV's wrap) rolled hard across a busy table,
    with a red block on it: 27 px between frames at 15 fps, and blurred."""
    r = 11

    def pos(t):
        return (30 + 400 * t, 120 + 25 * math.sin(2.5 * t))

    def sprite(t):
        return _ball_sprite(r, 400 * t / r, ((40, 40, 200), (230, 230, 230)))

    return _clip("fast_red_roll", 11, 23, pos, sprite, r)


def all_clips() -> list[Clip]:
    return [ramp_roll(), pendulum(), toss(), grey_box_slide(), occluded_roll(), distractor_roll(),
            fast_red_roll()]
