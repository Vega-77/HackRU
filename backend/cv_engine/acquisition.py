"""Tap-guided boundary proposals. Ambiguous scenes require a user-defined box."""

import cv2
import numpy as np


def propose_region(image: np.ndarray, point: tuple[float, float], *, use_region_growth: bool = True) -> dict:
    height, width = image.shape[:2]
    px, py = point
    failure = {"status": "manual_required", "reason": "no_clear_boundary", "bbox": None}
    if not (0 <= px < width and 0 <= py < height):
        return {**failure, "reason": "tap_outside_image"}
    lab = cv2.cvtColor(cv2.GaussianBlur(image, (3, 3), 0), cv2.COLOR_BGR2LAB)
    candidates = []
    for threshold in (20, 40):
        edges = np.zeros((height, width), np.uint8)
        for channel in cv2.split(lab):
            edges |= cv2.Canny(channel, threshold, threshold * 2)
        contours, _ = cv2.findContours(edges, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        for contour in contours:
            area = cv2.contourArea(contour)
            x, y, w, h = cv2.boundingRect(contour)
            if (area < 40 or area > width * height * .35 or w < 8 or h < 8
                    or x <= 0 or y <= 0 or x + w >= width or y + h >= height
                    or area / (w * h) < .25
                    or cv2.pointPolygonTest(contour, (float(px), float(py)), False) < 0):
                continue
            mask = np.zeros((height, width), np.uint8)
            cv2.drawContours(mask, [contour], -1, 255, -1)
            kernel = np.ones((5, 5), np.uint8)
            inside = cv2.erode(mask, kernel) > 0
            ring = (cv2.dilate(mask, kernel) > 0) & (mask == 0)
            if not inside.any() or not ring.any():
                continue
            contrast = float(np.linalg.norm(np.median(lab[inside], axis=0)
                                            - np.median(lab[ring], axis=0)))
            if contrast < 10:
                continue
            box = (x, y, w, h)
            duplicate = next((i for i, old in enumerate(candidates) if same_boundary(box, old)), None)
            if duplicate is None:
                candidates.append(box)
            elif w * h > candidates[duplicate][2] * candidates[duplicate][3]:
                candidates[duplicate] = box
    if len(candidates) > 1 and max(w * h for _, _, w, h in candidates) > 2 * min(w * h for _, _, w, h in candidates):
        return {**failure, "reason": "ambiguous_boundary", "candidates": len(candidates)}
    grown = seeded_region(lab, (round(px), round(py))) if use_region_growth else None
    if grown is not None:
        x, y, w, h = grown
        return {"status": "proposed", "reason": "stable_seeded_region", "candidates": 1,
                "bbox": {"x": x - 2, "y": y - 2, "w": w + 4, "h": h + 4}}
    if len(candidates) != 1:
        return {**failure, "reason": "ambiguous_boundary" if candidates else "no_clear_boundary",
                "candidates": len(candidates)}
    x, y, w, h = candidates[0]
    # Include the silhouette/background transition needed by the retained template.
    left, top = max(0, x - 1), max(0, y - 1)
    right, bottom = min(width, x + w + 1), min(height, y + h + 1)
    return {"status": "proposed", "reason": "enclosing_contour", "candidates": 1,
            "bbox": {"x": left, "y": top, "w": right - left, "h": bottom - top}}


def box_iou(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    intersection = max(0, min(ax + aw, bx + bw) - max(ax, bx)) * max(0, min(ay + ah, by + bh) - max(ay, by))
    return intersection / (aw * ah + bw * bh - intersection)


def same_boundary(a, b):
    # JPEG chroma and Canny can produce two rims a few pixels apart.
    def sides(box):
        x, y, w, h = box
        return x, y, x + w, y + h
    return box_iou(a, b) > .65 and max(abs(x - y) for x, y in zip(sides(a), sides(b))) <= 3


def seeded_region(lab, point):
    height, width = lab.shape[:2]
    point = (min(width - 1, point[0]), min(height - 1, point[1]))
    boxes = []
    for tolerance in (8, 12, 18):
        mask = np.zeros((height + 2, width + 2), np.uint8)
        cv2.floodFill(lab.copy(), mask, point, (0, 0, 0), (tolerance,) * 3, (tolerance,) * 3,
                      cv2.FLOODFILL_FIXED_RANGE | cv2.FLOODFILL_MASK_ONLY | (255 << 8) | 4)
        region = mask[1:-1, 1:-1] > 0
        y, x = np.where(region)
        if len(x) < 40 or len(x) > width * height * .35:
            return None
        box = (int(x.min()), int(y.min()), int(x.max() - x.min() + 1), int(y.max() - y.min() + 1))
        bx, by, bw, bh = box
        if min(bw, bh) < 8 or bx < 3 or by < 3 or bx + bw > width - 3 or by + bh > height - 3:
            return None
        boxes.append(box)
    if min(box_iou(boxes[1], box) for box in boxes) < .8:
        return None
    return boxes[1]
