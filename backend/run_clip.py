"""Run the full CV pipeline on a video file offline, with the debug overlay.

    python run_clip.py samples/ramp.mp4 --aruco 0.60 0.40
    python run_clip.py samples/pendulum.mp4 --aruco 0.60 0.40 --out pendulum_debug.mp4
    python run_clip.py my_clip.mp4 --aruco 0.30 0.20 --show      # live window (needs a desktop)

Writes an annotated video (default <clip>_debug.mp4) and a per-frame CSV of every tracked
object (default <clip>_tracks.csv). If <clip>_truth.csv exists (as for the generated
samples), it also scores the run: detection rate, ID switches and position error in mm.
"""

from __future__ import annotations

import argparse
import csv
import math
import time
from collections import defaultdict
from pathlib import Path

import cv2

from cv_engine.overlay import TrailHistory, draw_overlay
from cv_engine.pipeline import PipelineConfig, TrackingPipeline
from cv_engine.preprocess import preprocess_frame


def run(args: argparse.Namespace) -> list[dict]:
    clip = Path(args.clip)
    cap = cv2.VideoCapture(str(clip))
    if not cap.isOpened():
        raise SystemExit(f"could not open {clip}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    config = PipelineConfig(detector=args.detector)
    if args.colors:
        config.colors = args.colors
    pipe = TrackingPipeline(config)
    if args.aruco:
        pipe.calibrate({"method": "aruco", "width_m": args.aruco[0], "height_m": args.aruco[1]})

    out_path = Path(args.out) if args.out else clip.with_name(clip.stem + "_debug.mp4")
    writer = None
    trails = TrailHistory()
    rows: list[dict] = []
    times = []
    k = 0
    while True:
        ok, img = cap.read()
        if not ok:
            break
        t0 = time.perf_counter()
        pf = preprocess_frame(img, frame_id=k, timestamp=k / fps)
        result = {"frame_id": k, "timestamp": k / fps, **pipe(pf)}
        result["process_ms"] = (time.perf_counter() - t0) * 1000
        times.append(result["process_ms"])
        for o in result["objects"]:
            rows.append({"frame": k, "t": k / fps, **o})

        annotated = draw_overlay(img, result, trails.update(result["objects"]))
        if writer is None:
            h, w = annotated.shape[:2]
            writer = cv2.VideoWriter(str(out_path), cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
        writer.write(annotated)
        if args.show:
            cv2.imshow("CV engine debug", annotated)
            if cv2.waitKey(max(1, int(1000 / fps))) & 0xFF in (27, ord("q")):
                break
        k += 1
    cap.release()
    if writer:
        writer.release()
    pipe.close()

    tracks_path = clip.with_name(clip.stem + "_tracks.csv")
    with open(tracks_path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["frame", "t", "id", "label", "cx_px", "cy_px", "x_m", "y_m"])
        for r in rows:
            pos = r["position"] or {"x": "", "y": ""}
            w.writerow([r["frame"], f"{r['t']:.4f}", r["id"], r["label"], r["pixel"]["x"], r["pixel"]["y"], pos["x"], pos["y"]])
    ms = sorted(times)
    print(f"{k} frames, processing median {ms[len(ms) // 2]:.1f} ms, p95 {ms[int(len(ms) * 0.95)]:.1f} ms")
    print(f"wrote {out_path} and {tracks_path}")

    truth_path = clip.with_name(clip.stem + "_truth.csv")
    if truth_path.exists():
        score(rows, truth_path)
    return rows


def score(rows: list[dict], truth_path: Path) -> None:
    """Match each true object to the tracked object of the same color nearest to it."""
    tracked = defaultdict(list)
    for r in rows:
        if r["position"]:
            tracked[r["frame"]].append(r)
    by_object = defaultdict(lambda: {"frames": 0, "found": 0, "errors": [], "ids": []})
    with open(truth_path) as f:
        for t in csv.DictReader(f):
            s = by_object[t["object"]]
            s["frames"] += 1
            tx, ty = float(t["x_m"]), float(t["y_m"])
            same = [r for r in tracked[int(t["frame"])] if r["label"] == t["color"]]
            if not same:
                continue
            best = min(same, key=lambda r: math.hypot(r["position"]["x"] - tx, r["position"]["y"] - ty))
            err = math.hypot(best["position"]["x"] - tx, best["position"]["y"] - ty)
            if err < 0.05:
                s["found"] += 1
                s["errors"].append(err * 1000)
                s["ids"].append(best["id"])

    print("\nscore against ground truth:")
    for name, s in by_object.items():
        errs = sorted(s["errors"])
        switches = sum(1 for a, b in zip(s["ids"], s["ids"][1:]) if a != b)
        if not errs:
            print(f"  {name:<8} never found")
            continue
        rms = math.sqrt(sum(e * e for e in errs) / len(errs))
        print(
            f"  {name:<8} found {s['found']}/{s['frames']} frames, ID switches {switches}, "
            f"error rms {rms:.1f} mm, median {errs[len(errs) // 2]:.1f} mm, max {errs[-1]:.1f} mm"
        )


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("clip")
    p.add_argument("--aruco", type=float, nargs=2, metavar=("WIDTH_M", "HEIGHT_M"),
                   help="calibrate with ArUco markers 0-3 on a rectangle of this size (center to center)")
    p.add_argument("--detector", default="color", choices=["color", "mediapipe", "both"])
    p.add_argument("--colors", nargs="+", help="colors to track (default: red green blue yellow)")
    p.add_argument("--out", help="annotated video path")
    p.add_argument("--show", action="store_true", help="also show a live window")
    run(p.parse_args())


if __name__ == "__main__":
    main()
