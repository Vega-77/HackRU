"""Local WebSocket delay for camera testing, without changing capture timestamps.

Run beside the development backend, then select ws://127.0.0.1:8765 in the app.
Each direction delays messages concurrently while preserving message order.
This simulates latency, not bandwidth limits, jitter, or packet loss.
"""

import argparse
import asyncio

from websockets.legacy.client import connect
from websockets.legacy.server import serve


async def relay(source, destination, delay_seconds):
    pending = asyncio.Queue(maxsize=64)
    loop = asyncio.get_running_loop()

    async def receive():
        async for message in source:
            await pending.put((loop.time() + delay_seconds, message))
        await pending.put(None)

    async def deliver():
        while True:
            item = await pending.get()
            if item is None:
                return
            due, message = item
            await asyncio.sleep(max(0, due - loop.time()))
            await destination.send(message)

    tasks = [asyncio.create_task(receive()), asyncio.create_task(deliver())]
    try:
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)


async def run(upstream, port, rtt_ms):
    async def bridge(client):
        async with connect(upstream, max_size=512 * 1024) as backend:
            tasks = [asyncio.create_task(relay(client, backend, rtt_ms / 2000)),
                     asyncio.create_task(relay(backend, client, rtt_ms / 2000))]
            try:
                done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
            finally:
                for task in tasks:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)

    async with serve(bridge, '127.0.0.1', port, max_size=512 * 1024):
        print(f'ws://127.0.0.1:{port} -> {upstream}; added RTT {rtt_ms:g} ms', flush=True)
        await asyncio.Future()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', default='ws://127.0.0.1:8001/ws/frames')
    parser.add_argument('--port', type=int, default=8765)
    parser.add_argument('--rtt-ms', type=float, default=600)
    args = parser.parse_args()
    if not 0 <= args.rtt_ms <= 10000:
        parser.error('--rtt-ms must be between 0 and 10000')
    asyncio.run(run(args.upstream, args.port, args.rtt_ms))
