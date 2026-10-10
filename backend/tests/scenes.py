"""Synthetic camera views of a calibrated board, for calibration tests."""

import cv2
import numpy as np

from cv_engine.calibration import make_marker_sheet

DPI = 150
PX_PER_M = DPI / 0.0254
BOARD_W, BOARD_H = 0.40, 0.25  # meters between marker centers


def board_image(ball_world=None, ball_radius_m=0.02):
    """Front-on board with ArUco markers at the corners and an optional red ball.

    Returns the image and a function mapping world meters -> board pixels.
    """
    sheet = cv2.cvtColor(make_marker_sheet(BOARD_W, BOARD_H, marker_size_m=0.04, dpi=DPI), cv2.COLOR_GRAY2BGR)
    h = sheet.shape[0]
    margin = round(0.04 * PX_PER_M)

    def to_px(X, Y):
        return margin + X * PX_PER_M, h - margin - Y * PX_PER_M

    if ball_world is not None:
        cx, cy = to_px(*ball_world)
        cv2.circle(sheet, (round(cx), round(cy)), round(ball_radius_m * PX_PER_M), (0, 0, 255), -1)
    return sheet, to_px


def camera_view(img, out_size=(1280, 720)):
    """Warp the board as if seen by a tilted phone camera; returns view and the warp."""
    h, w = img.shape[:2]
    src = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    dst = np.float32([[260, 90], [1050, 140], [1150, 640], [140, 600]])  # a skewed quad
    M = cv2.getPerspectiveTransform(src, dst)
    view = cv2.warpPerspective(img, M, out_size, borderValue=(90, 90, 90))
    return view, M
