"""Foreground identity inside a confirmed selection, independent of its background."""

import cv2
import numpy as np


class ColorModel:
    """Selected foreground/background colors with regularized illumination bands."""

    def __init__(self, pixels):
        pixels = pixels.astype(np.float32)
        brightness = pixels.mean(axis=1)
        edges = np.percentile(brightness, [0, 20, 40, 60, 80, 100])
        self.bands = []
        for index in range(5):
            band = pixels[(brightness >= edges[index]) & (brightness <= edges[index + 1])]
            if not len(band):
                continue
            variance = np.maximum(band.var(axis=0), 16)
            self.bands.append((band.mean(axis=0), variance, float(np.log(variance).sum())))

    def cost(self, image):
        pixels = image.astype(np.float32)
        costs = [np.sum((pixels - mean) ** 2 / variance, axis=2) + normalization
                 for mean, variance, normalization in self.bands]
        return np.minimum.reduce(costs)


def selected_foreground(image, seed, selection_bounds=None):
    height, width = image.shape[:2]
    px, py = seed
    if min(width, height) < 12:
        return None
    labels = np.full((height, width), cv2.GC_PR_FGD, np.uint8)
    selected_width, selected_height = width, height
    if selection_bounds is not None:
        x, y, selected_width, selected_height = selection_bounds
        labels[:] = cv2.GC_PR_BGD
        labels[y:y + selected_height, x:x + selected_width] = cv2.GC_PR_FGD
    labels[:2] = labels[-2:] = cv2.GC_BGD
    labels[:, :2] = labels[:, -2:] = cv2.GC_BGD
    # A single foreground pixel can isolate a logo instead of the object.
    radius = max(1, min(round(min(selected_width, selected_height) * .25), px - 1, py - 1,
                        width - px - 2, height - py - 2))
    cv2.circle(labels, (px, py), radius, cv2.GC_FGD, -1)
    try:
        cv2.grabCut(image, labels, None, np.zeros((1, 65)), np.zeros((1, 65)),
                    5, cv2.GC_INIT_WITH_MASK)
    except cv2.error:
        return None
    binary = np.uint8((labels == cv2.GC_FGD) | (labels == cv2.GC_PR_FGD))
    _, components, _, _ = cv2.connectedComponentsWithStats(binary)
    component = components[py, px]
    if component == 0:
        return None
    mask = np.uint8(components == component)
    contour = max(cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)[0],
                  key=cv2.contourArea)
    x, y, w, h = cv2.boundingRect(contour)
    area = cv2.contourArea(contour)
    # Reject tiny seed islands and selections with no separable background.
    if (area < max(40, selected_width * selected_height * .12, np.pi * radius * radius * 1.15)
            or area > width * height * .9 or min(w, h) < 8):
        return None
    cv2.drawContours(mask, [contour], -1, 1, -1)
    return mask


class RoundReference:
    """Use a verified round silhouette when surface texture turns out of view."""

    @classmethod
    def from_mask(cls, image, mask):
        if mask is None:
            return None
        contour = max(cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)[0],
                      key=cv2.contourArea)
        if len(contour) < 5:
            return None
        area, perimeter = cv2.contourArea(contour), cv2.arcLength(contour, True)
        _, axes, _ = cv2.fitEllipse(contour)
        if (4 * np.pi * area / max(perimeter * perimeter, 1) < .72
                or min(axes) / max(axes) < .8):
            return None
        instance = cls()
        lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB).astype(np.float32)
        interior = cv2.erode(mask, np.ones((3, 3), np.uint8)) > 0
        instance.chroma = np.median(lab[interior, 1:], axis=0)
        instance.chroma_spread = np.maximum(
            np.median(np.abs(lab[interior, 1:] - instance.chroma), axis=0) * 1.4826, 2.0)
        instance.lightness = float(np.median(lab[interior, 0]))
        instance.spread = float(np.diff(np.percentile(lab[interior, 0], [25, 75]))[0])
        instance.median_color = np.median(image[interior], axis=0)
        instance.background_model = ColorModel(image[mask == 0])
        instance.foreground_model = ColorModel(image[mask > 0])
        return instance

    def verify(self, image, expected_mask, lightness_shift=0.0):
        if not self.appearance_matches(image, expected_mask, lightness_shift):
            return None
        median_color = np.median(image[expected_mask > 0], axis=0)
        corrected = np.clip(image.astype(np.float32) + np.clip(self.median_color - median_color, -40, 40),
                            0, 255).astype(np.uint8)
        # Freeze the selected object's color model rather than learning a new nearby region.
        difference = self.foreground_model.cost(corrected) - self.background_model.cost(corrected)
        # This bounded evidence score is not a calibrated object probability.
        evidence = 1 / (1 + np.exp(np.clip(difference * .5, -40, 40)))
        interior = cv2.erode(expected_mask, np.ones((3, 3), np.uint8)) > 0
        exterior = (cv2.dilate(expected_mask, np.ones((5, 5), np.uint8)) - expected_mask) > 0
        if not interior.any() or not exterior.any():
            return None
        # Similar foreground colors must be concentrated inside the matched silhouette.
        inside, outside = float(evidence[interior].mean()), float(evidence[exterior].mean())
        if inside < .6 or inside - outside < .12:
            return None
        moments = cv2.moments(expected_mask)
        yy, xx = np.indices(expected_mask.shape)
        angle = np.arctan2(yy - moments['m01'] / moments['m00'], xx - moments['m10'] / moments['m00'])
        quadrants = np.floor((angle + np.pi) * 2 / np.pi).astype(int) % 4
        support = 0
        for quadrant in range(4):
            inner = interior & (quadrants == quadrant)
            outer = exterior & (quadrants == quadrant)
            if inner.any() and outer.any() and evidence[inner].mean() - evidence[outer].mean() >= .1:
                support += 1
        if support < 3:
            return None
        mask = np.uint8((evidence > .5) & (expected_mask > 0))
        mask = cv2.morphologyEx(mask, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
        return mask, inside, outside

    def appearance_matches(self, image, mask, lightness_shift=0.0):
        interior = cv2.erode(mask, np.ones((3, 3), np.uint8)) > 0
        if not interior.any():
            return False
        lab = cv2.cvtColor(image, cv2.COLOR_BGR2LAB).astype(np.float32)
        chroma_delta = np.median(lab[interior, 1:], axis=0) - self.chroma
        return (np.linalg.norm(chroma_delta) <= 12
                and np.linalg.norm(chroma_delta / self.chroma_spread) <= 3
                # Exposure can shift the whole scene. A dark lookalike in an
                # unchanged scene must not get the same allowance.
                and abs(float(np.median(lab[interior, 0])) - self.lightness)
                <= max(30, min(45, 0.75 * self.spread)) + abs(lightness_shift)
                and float(np.diff(np.percentile(lab[interior, 0], [25, 75]))[0]) <= self.spread + 15)
