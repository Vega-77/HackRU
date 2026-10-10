# HandsOn Physics

HackRU prototype for tracking physical experiments and displaying physics
telemetry over a live camera view.

The Python backend is in [`backend/`](backend/README.md). It provides the
`/ws/frames` WebSocket used by the mobile client, object tracking,
calibration, physics states, a browser debug view, and sample clips. See the
backend README for setup, the wire protocol, and tests.

## Physics engine

`physics_engine.KinematicsEngine` converts timestamped visual-tracking
coordinates into velocity and acceleration estimates. It accepts either pixel
centroids plus a scale or calibrated metre coordinates. The physics package
has no third-party dependencies.

```python
from physics_engine import KinematicsEngine

engine = KinematicsEngine(window_size=7)
result = engine.add_sample(
    timestamp=0.1,
    x_px=120,
    y_px=300,
    meters_per_pixel=0.002,
    confidence=0.95,
)

print(result.to_dict())
```

With an experiment `mode` configured, the live backend reads Dev 2's
calibrated positions and returns a `state` message per processed frame. The
physics session supports `free_fall`, `ramp`, `pendulum`, and `collision`.
Model-derived forces are distinct from measured acceleration.

Run the tests with:

```shell
python3 -m unittest discover -v
```

For the backend integration tests, install `backend/requirements.txt` and run
`python3 -m pytest backend/tests -q` from the repository root.
