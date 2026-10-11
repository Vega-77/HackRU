import asyncio

from latency_proxy import relay


def test_delay_preserves_metadata_bytes_and_does_not_serialize_latency():
    async def check():
        messages = ['{"frame_id":1,"timestamp":0.03}', b'jpeg1',
                    '{"frame_id":2,"timestamp":0.06}', b'jpeg2',
                    '{"frame_id":3,"timestamp":0.09}', b'jpeg3']
        received, times = [], []
        loop = asyncio.get_running_loop()
        class Source:
            async def __aiter__(self):
                for message in messages:
                    yield message
        class Destination:
            async def send(self, message):
                received.append(message)
                times.append(loop.time())
        start = loop.time()
        await relay(Source(), Destination(), .06)
        assert received == messages
        assert times[0] - start >= .055
        assert times[-1] - times[0] < .12
    asyncio.run(check())
