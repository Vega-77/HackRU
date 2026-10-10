# HackRU

HandsOn Physics: an AR physics assistant. The Python CV backend lives in [`backend/`](backend/README.md).
# HandsOn Physics

HackRU prototype: a Flutter camera client streams experiment frames to a Python
backend, which returns tracked object coordinates and physics telemetry for
live vector overlays.

The Dev 4 server foundation is in [`backend/`](backend/). Its wire contract is
documented in [`docs/websocket-protocol.md`](docs/websocket-protocol.md).

## Run the backend

With Python 3.9 or newer:

```sh
cd backend
python3 -m venv .venv
.venv/bin/python -m pip install '.[test]'
.venv/bin/python -m uvicorn handson_backend.server:app --host 0.0.0.0 --port 8000 --ws-max-size 524288
```

Then request `http://localhost:8000/health`. The default server accepts frames
but reports `tracking_unavailable` until Dev 2's tracker is connected. It does
not claim to measure motion yet.

To run tests from `backend/`:

```sh
.venv/bin/python -m pytest
```

Docker is also supported:

```sh
docker build -t handson-bßackend backend
docker run --rm -p 8000:8000 handson-backend
```
