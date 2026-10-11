"""A one-frame mailbox that always holds the newest frame.

The phone can send frames faster than the CV engine processes them. Queuing
them would make latency grow without bound, so the receiver overwrites the slot
and the processor always picks up the most recent frame. Overwritten frames are
counted as dropped.
"""

from __future__ import annotations

import asyncio
from typing import Generic, TypeVar

T = TypeVar("T")


class LatestFrameSlot(Generic[T]):
    def __init__(self) -> None:
        self._item: T | None = None
        self._event = asyncio.Event()
        self._closed = False
        self.received = 0
        self.dropped = 0

    def put(self, item: T) -> None:
        if self._item is not None:
            self.dropped += 1
        self._item = item
        self.received += 1
        self._event.set()

    async def get(self) -> T | None:
        """Wait for the next frame. Returns None once the slot is closed and empty."""
        while self._item is None:
            if self._closed:
                return None
            self._event.clear()
            await self._event.wait()
        item, self._item = self._item, None
        return item

    def close(self) -> None:
        self._closed = True
        self._event.set()

    def discard(self) -> None:
        if self._item is not None:
            self.dropped += 1
            self._item = None
