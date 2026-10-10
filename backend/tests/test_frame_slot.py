import asyncio

from cv_engine.frame_slot import LatestFrameSlot


def test_slot_keeps_newest_and_counts_drops():
    async def go():
        slot = LatestFrameSlot()
        for i in range(5):
            slot.put(i)
        assert await slot.get() == 4
        assert slot.received == 5 and slot.dropped == 4
        slot.close()
        assert await slot.get() is None

    asyncio.run(go())


def test_get_waits_for_put():
    async def go():
        slot = LatestFrameSlot()
        waiter = asyncio.create_task(slot.get())
        await asyncio.sleep(0.01)
        assert not waiter.done()
        slot.put("frame")
        assert await waiter == "frame"

    asyncio.run(go())
