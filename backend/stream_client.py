"""Stream a webcam or video file to the CV engine, the way the iOS app will.

It mimics the mobile side: downsample each frame, JPEG-encode it, send the
metadata + image over the WebSocket, and print throughput and latency.

    python stream_client.py --source 0                 # default webcam
    python stream_client.py --source clip.mp4 --fps 30
    python stream_client.py --source synthetic         # moving ball, no camera needed
"""

from __future__ import annotations

import argparse
import asyncio
import json
import time
from collections.abc import Iterator

import cv2
import numpy as np
import websockets

from cv_engine.preprocess import downsample, encode_jpeg
from cv_engine.sources import iter_frames


def synthetic_frames(fps: float, width: int = 1280, height: int = 720) -> Iterator[tuple[float, np.ndarray]]:
    """A red ball rolling across a gray table, for testing without a camera."""
    t = 0
    while True:
        frame = np.full((height, width, 3), 90, np.uint8)
        x = int((t * 8) % width)
        y = int(height * 0.6 + 80 * np.sin(t / 15))
        cv2.circle(frame, (x, y), 40, (0, 0, 255), -1)
        time.sleep(1 / fps)
        yield time.time(), frame
        t += 1


async def run(args: argparse.Namespace) -> None:
    if args.source == "synthetic":
        frames = synthetic_frames(args.fps)
    else:
        frames = iter_frames(args.source, max_fps=args.fps, loop=args.loop)

    async with websockets.connect(args.url, max_size=None) as ws:
        if args.aruco:
            w, h = args.aruco
            await ws.send(json.dumps({"type": "calibrate", "method": "aruco", "width_m": w, "height_m": h}))
        sent = 0
        bytes_sent = 0
        results: list[dict] = []
        start = time.time()

        async def reader() -> None:
            async for msg in ws:
                data = json.loads(msg)
                if data.get("type") == "error":
                    print("server error:", data["message"])
                elif data.get("type") == "frame":
                    results.append(data)

        reader_task = asyncio.create_task(reader())
        try:
            for frame_id, (ts, frame) in enumerate(frames):
                if args.max_frames and frame_id >= args.max_frames:
                    break
                small, _ = downsample(frame, args.send_width)
                jpeg = encode_jpeg(small, args.quality)
                await ws.send(json.dumps({"frame_id": frame_id, "timestamp": ts}))
                await ws.send(jpeg)
                sent += 1
                bytes_sent += len(jpeg)
                if sent % 30 == 0:
                    _report(sent, bytes_sent, results, time.time() - start)
                await asyncio.sleep(0)  # let the reader run
            await asyncio.sleep(0.5)  # collect the last results
        finally:
            reader_task.cancel()
        _report(sent, bytes_sent, results, time.time() - start)


def _report(sent: int, bytes_sent: int, results: list[dict], elapsed: float) -> None:
    if not results:
        print(f"sent {sent} frames, no results yet")
        return
    last = results[-1]
    recent = results[-30:]
    lat = sum(r["latency_ms"] for r in recent) / len(recent)
    proc = sum(r["process_ms"] for r in recent) / len(recent)
    print(
        f"sent {sent} ({sent / elapsed:.1f} fps, {bytes_sent / elapsed / 1024:.0f} KB/s, "
        f"{bytes_sent / sent / 1024:.1f} KB/frame) | processed {last['stats']['processed']} "
        f"dropped {last['stats']['dropped']} | latency {lat:.1f} ms, process {proc:.1f} ms"
    )
    cal = last.get("calibration", {})
    if cal.get("method", "none") != "none":
        print(f"    plane: {cal['method']} {cal['status']}")
    for o in last.get("objects", []):
        world = f"  world {o['world']} m" if o.get("world") else ""
        print(f"    #{o['id']} {o['label']:<12} centroid {o['centroid']}  bbox {o['bbox']}{world}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--url", default="ws://localhost:8000/ws/frames")
    p.add_argument("--source", default="0", help="webcam index, video path, or 'synthetic'")
    p.add_argument("--fps", type=float, default=30)
    p.add_argument("--send-width", type=int, default=640, help="width the client downsamples to before sending")
    p.add_argument("--quality", type=int, default=70, help="JPEG quality 1-100")
    p.add_argument("--max-frames", type=int, default=0, help="stop after N frames (0 = run until source ends)")
    p.add_argument("--loop", action="store_true", help="restart a video file when it ends")
    p.add_argument("--aruco", type=float, nargs=2, metavar=("WIDTH_M", "HEIGHT_M"),
                   help="calibrate with ArUco markers 0-3 on a rectangle of this size (center to center)")
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
