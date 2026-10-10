"""Stand-in physics backend that speaks docs/protocol.md.

It ignores the image content and replies to every frame with a synthetic
trajectory, so the app's live mode (camera -> socket -> overlay) can be
tested before the real backend exists.

    pip install websockets
    python mobile/tool/mock_server.py              # ws://0.0.0.0:8000/ws/frames
    python mobile/tool/mock_server.py --delay 0.08 # simulate 80 ms of CV work

Then run the app with demo mode off and the backend URL set to
ws://<this machine's LAN IP>:8000/ws/frames (or ws://localhost:8000/ws/frames
in Chrome). Same port and path as the real backend, so stop one before
starting the other.
"""

import argparse
import asyncio
import json
import math
import sys
import time

import websockets

G = 9.81
PATH = "/ws/frames"


def ramp(t, m):
    theta, mu, length = math.radians(25), 0.15, 0.62
    a = G * (math.sin(theta) - mu * math.cos(theta))
    t_end = math.sqrt(2 * length / a)
    tt = min(t % (t_end + 0.5), t_end)
    moving = tt < t_end
    d = (math.cos(theta), -math.sin(theta))
    n = (math.sin(theta), math.cos(theta))
    s, v = 0.5 * a * tt * tt, (a * tt if moving else 0.0)
    pos = (0.08 + d[0] * s, 0.52 + d[1] * s)
    w, normal = m * G, m * G * math.cos(theta)
    friction = mu * normal if moving else w * math.sin(theta)
    acc = (d[0] * a, d[1] * a) if moving else (0.0, 0.0)
    forces = [
        ("gravity", 0.0, -w),
        ("normal", n[0] * normal, n[1] * normal),
        ("friction", -d[0] * friction, -d[1] * friction),
    ]
    energy = {"kinetic": 0.5 * m * v * v, "potential": w * (pos[1] - (0.52 - length * math.sin(theta))),
              "thermal": mu * normal * s}
    return pos, (d[0] * v, d[1] * v), acc, forces, energy, {"angle_deg": 25.0, "mu": mu}


def free_fall(t, m):
    x0, y0, vx, vy, floor = 0.06, 0.18, 0.55, 2.4, 0.04
    t_end = (vy + math.sqrt(vy * vy + 2 * G * (y0 - floor))) / G
    tt = min(t % (t_end + 0.4), t_end)
    pos = (x0 + vx * tt, y0 + vy * tt - 0.5 * G * tt * tt)
    vel = (vx, vy - G * tt)
    energy = {"kinetic": 0.5 * m * (vel[0] ** 2 + vel[1] ** 2), "potential": m * G * (pos[1] - floor), "thermal": 0.0}
    return pos, vel, (0.0, -G), [("gravity", 0.0, -m * G)], energy, {}


def pendulum(t, m):
    # Small-angle approximation is fine for a test server.
    length, amp = 0.45, math.radians(30)
    w = math.sqrt(G / length)
    th, thd = amp * math.cos(w * t), -amp * w * math.sin(w * t)
    thdd = -w * w * th
    tan, inward = (math.cos(th), math.sin(th)), (-math.sin(th), math.cos(th))
    pos = (0.42 + length * math.sin(th), 0.6 - length * math.cos(th))
    vel = (tan[0] * length * thd, tan[1] * length * thd)
    acc = tuple(tan[i] * length * thdd + inward[i] * length * thd * thd for i in range(2))
    tension = m * (G * math.cos(th) + length * thd * thd)
    forces = [("gravity", 0.0, -m * G), ("tension", inward[0] * tension, inward[1] * tension)]
    energy = {"kinetic": 0.5 * m * (vel[0] ** 2 + vel[1] ** 2),
              "potential": m * G * length * (1 - math.cos(th)), "thermal": 0.0}
    return pos, vel, acc, forces, energy, {"angle_deg": math.degrees(th)}


MODES = {"ramp": ramp, "free_fall": free_fall, "pendulum": pendulum, "collision": ramp}


def state_for(config, frame_id, capture_t, sim_t):
    m = config.get("mass_kg", 0.1)
    fw, fh = config["frame_size"]["w"], config["frame_size"]["h"]
    pos, vel, acc, forces, energy, extras = MODES.get(config.get("mode"), ramp)(sim_t, m)
    px_per_m = fh / 0.65  # same framing as the app's MockPhysics
    px, py = pos[0] * px_per_m, fh - pos[1] * px_per_m
    return {
        "type": "state",
        "frame_id": frame_id,
        "timestamp": capture_t,
        "tracked": True,
        "pixel": {"x": px, "y": py},
        "bbox": {"x": px - 9, "y": py - 9, "w": 18, "h": 18},
        "position": {"x": pos[0], "y": pos[1]},
        "velocity": {"x": vel[0], "y": vel[1]},
        "acceleration": {"x": acc[0], "y": acc[1]},
        "forces": [{"name": n, "x": x, "y": y} for n, x, y in forces]
        + [{"name": "net", "x": acc[0] * m, "y": acc[1] * m}],
        "energy": energy,
        "extras": extras,
    }


async def handle(ws, delay):
    peer = ws.remote_address
    print(f"client connected: {peer}")
    config = {"mode": "ramp", "mass_kg": 0.1, "frame_size": {"w": 320, "h": 240}}
    start = time.monotonic()
    frames, window_start, last_bytes = 0, time.monotonic(), 0
    meta, next_id = {}, 0  # metadata text that precedes the next JPEG
    try:
        async for message in ws:
            if isinstance(message, str):
                data = json.loads(message)
                if data.get("type") == "config":
                    config = data
                    start = time.monotonic()
                    print(f"config: {json.dumps(data)}")
                else:
                    meta = data
                continue

            frame_id = int(meta.get("frame_id", next_id))
            capture_t = meta.get("timestamp", time.monotonic())
            meta, next_id = {}, frame_id + 1
            last_bytes = len(message)
            if delay:
                await asyncio.sleep(delay)
            await ws.send(json.dumps(state_for(config, frame_id, capture_t, time.monotonic() - start)))

            frames += 1
            now = time.monotonic()
            if now - window_start >= 2:
                fs = config["frame_size"]
                print(f"{frames / (now - window_start):5.1f} fps  "
                      f"{fs['w']}x{fs['h']}  jpeg {last_bytes / 1024:.1f} KB  frame {frame_id}")
                frames, window_start = 0, now
    except websockets.ConnectionClosed:
        pass
    print(f"client disconnected: {peer}")


async def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--delay", type=float, default=0.0, help="seconds of fake processing per frame")
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # show logs live when piped

    async def router(ws):
        if ws.request.path != PATH:
            await ws.close(code=1008, reason=f"use {PATH}")
            return
        await handle(ws, args.delay)

    async with websockets.serve(router, args.host, args.port, max_size=2**22):
        print(f"mock physics server on ws://{args.host}:{args.port}{PATH}")
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
