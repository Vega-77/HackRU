"""Compare tap-guided classical methods on labeled synthetic JPEGs, not camera footage."""

import json
import time
from statistics import median

import cv2
import numpy as np

from cv_engine.acquisition import box_iou, propose_region
from cv_engine.preprocess import decode_jpeg, encode_jpeg


def fixtures():
    for name, color in [('gray', (180, 180, 180)), ('white', (240, 240, 240)),
                        ('black', (20, 20, 20)), ('red', (0, 0, 255))]:
        image = np.full((180, 320, 3), 90, np.uint8)
        cv2.circle(image, (80, 90), 16, color, -1)
        cv2.rectangle(image, (170, 30), (200, 60), (220, 220, 220), -1)
        for label, point in [('center', (80, 90)), ('edge', (94, 90))]:
            yield f'{name}-{label}', decode_jpeg(encode_jpeg(image)), point, (64, 74, 33, 33)
    image = np.full((180, 320, 3), 90, np.uint8)
    cv2.circle(image, (80, 90), 16, (180, 180, 180), -1)
    yy, xx = np.indices((180, 320))
    image = np.clip(image.astype(float) + 30 * np.sin(xx[..., None] / 100), 0, 255).astype(np.uint8)
    yield 'illumination-gradient', decode_jpeg(encode_jpeg(image)), (80, 90), (64, 74, 33, 33)
    image = np.full((180, 320, 3), 90, np.uint8)
    cv2.rectangle(image, (68, 65), (92, 120), (0, 0, 255), -1)
    cv2.rectangle(image, (74, 55), (86, 70), (0, 0, 255), -1)
    yield 'bottle-silhouette', decode_jpeg(encode_jpeg(image)), (80, 90), (68, 55, 25, 66)
    yield 'empty', np.full((180, 320, 3), 90, np.uint8), (80, 90), None
    image = np.full((180, 320, 3), 90, np.uint8)
    cv2.circle(image, (80, 90), 16, (95, 95, 95), -1)
    yield 'insufficient-contrast', image, (80, 90), None


def region_box(mask):
    y, x = np.where(mask)
    if len(x) < 40 or len(x) > mask.size * .35 or min(x) == 0 or min(y) == 0 or max(x) == mask.shape[1]-1 or max(y) == mask.shape[0]-1:
        return None
    box = (int(min(x)), int(min(y)), int(max(x)-min(x)+1), int(max(y)-min(y)+1))
    return box if min(box[2:]) >= 8 else None


def flood(image, point):
    lab = cv2.cvtColor(cv2.GaussianBlur(image, (3, 3), 0), cv2.COLOR_BGR2LAB)
    mask = np.zeros((image.shape[0]+2, image.shape[1]+2), np.uint8)
    cv2.floodFill(lab, mask, point, (0, 0, 0), (12, 12, 12), (12, 12, 12),
                  cv2.FLOODFILL_FIXED_RANGE | cv2.FLOODFILL_MASK_ONLY | (255 << 8) | 4)
    return region_box(mask[1:-1, 1:-1] > 0)


def grabcut(image, point):
    mask = np.full(image.shape[:2], cv2.GC_PR_BGD, np.uint8)
    mask[:2, :] = mask[-2:, :] = cv2.GC_BGD
    mask[:, :2] = mask[:, -2:] = cv2.GC_BGD
    cv2.circle(mask, point, 3, cv2.GC_PR_FGD, -1)
    cv2.circle(mask, point, 1, cv2.GC_FGD, -1)
    cv2.setRNGSeed(0)
    cv2.grabCut(image, mask, None, np.zeros((1, 65)), np.zeros((1, 65)), 3, cv2.GC_INIT_WITH_MASK)
    return region_box((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD))


def proposal_box(image, point, *, use_region_growth=True):
    box = propose_region(image, point, use_region_growth=use_region_growth)['bbox']
    return tuple(box[k] for k in ('x', 'y', 'w', 'h')) if box else None


def benchmark():
    cv2.setNumThreads(1)
    report = {}
    methods = [('selected-method', proposal_box),
               ('contour-only', lambda image, point: proposal_box(image, point, use_region_growth=False)),
               ('flood-fill', flood), ('tap-seeded-grabcut', grabcut)]
    for name, method in methods:
        cases, times = [], []
        for label, image, point, truth in fixtures():
            start = time.perf_counter()
            box = method(image, point)
            times.append((time.perf_counter() - start) * 1000)
            iou = box_iou(box, truth) if box and truth else None
            cases.append({'fixture': label, 'bbox': box, 'iou': None if iou is None else round(iou, 3),
                          'correct': box is None if truth is None else iou is not None and iou >= .7})
        report[name] = {'correct': sum(c['correct'] for c in cases), 'total': len(cases),
                        'median_ms': round(median(times), 2), 'cases': cases}
    return report


if __name__ == '__main__':
    print(json.dumps(benchmark(), indent=2))
