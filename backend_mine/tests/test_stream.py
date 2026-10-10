import struct

from fastapi.testclient import TestClient

from handson_backend.pipeline import Kinematics, Pipeline, TrackedObject, UnconfiguredPhysics, UnconfiguredTracker
from handson_backend.protocol import ClientConfig, Vec2, decode_frame
from handson_backend.server import Session, create_app


JPEG = b"\xff\xd8fake-jpeg\xff\xd9"


def frame(frame_id, timestamp_ms=1234):
    return struct.pack(">IQ", frame_id, timestamp_ms) + JPEG


class FakeTracker:
    def track(self, jpeg, config):
        assert jpeg == JPEG
        return TrackedObject(12.0, 34.0, 0.9)


class FakePhysics:
    def update(self, capture_timestamp_ms, tracked, config):
        assert capture_timestamp_ms == 1234
        return Kinematics(position_m=Vec2(x=0.12, y=0.34))


def test_default_pipeline_reports_unavailable():
    app = create_app()
    with TestClient(app) as client:
        assert client.get("/health").json() == {"status": "ok", "active_sessions": 0}
        with client.websocket_connect("/ws") as ws:
            hello = ws.receive_json()
            assert hello["type"] == "hello"
            assert client.get("/health").json()["active_sessions"] == 1
            ws.send_bytes(frame(1))
            result = ws.receive_json()
            assert result["frame_id"] == 1
            assert result["status"] == "tracking_unavailable"
            assert result["measurement"] is None
        assert client.get("/health").json()["active_sessions"] == 0


def test_config_and_tracking_adapter():
    app = create_app(FakeTracker, FakePhysics)
    with TestClient(app) as client:
        with client.websocket_connect("/ws") as ws:
            ws.receive_json()
            ws.send_json({"type": "config", "version": 1, "mode": "ramp", "mass_kg": 0.2})
            ack = ws.receive_json()
            assert ack["type"] == "config_ack"
            assert ack["config"]["mode"] == "ramp"
            ws.send_bytes(frame(7))
            result = ws.receive_json()
            assert result["status"] == "tracked"
            assert result["frame_id"] == 7
            assert result["measurement"]["x_px"] == 12.0
            assert result["measurement"]["position_m"] == {"x": 0.12, "y": 0.34}


def test_bad_frame_and_config_do_not_end_session():
    with TestClient(create_app()) as client:
        with client.websocket_connect("/ws") as ws:
            ws.receive_json()
            ws.send_json({"type": "config", "mass_kg": -1})
            assert ws.receive_json()["code"] == "invalid_config"
            ws.send_bytes(b"bad")
            assert ws.receive_json()["code"] == "frame_too_short"
            ws.send_bytes(frame(1))
            assert ws.receive_json()["type"] == "result"
            ws.send_bytes(frame(1))
            assert ws.receive_json()["code"] == "out_of_order_frame"
            ws.send_bytes(frame(2, 1233))
            assert ws.receive_json()["code"] == "non_monotonic_timestamp"
            ws.send_bytes(frame(3, 1235))
            assert ws.receive_json()["frame_id"] == 3


def test_pending_queue_keeps_newest_frame():
    session = Session(None, Pipeline(UnconfiguredTracker(), UnconfiguredPhysics(), False))
    config = ClientConfig()
    session.enqueue(decode_frame(frame(1), config, 100))
    session.enqueue(decode_frame(frame(2, 1235), config, 101))
    assert session.dropped_frames == 1
    assert session.pending.get_nowait().frame_id == 2
