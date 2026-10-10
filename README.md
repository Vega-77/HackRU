# HackRU

HandsOn Physics: an AR physics assistant. The Python CV backend lives in
[`backend/`](backend/README.md).

## Physics engine

`physics_engine.KinematicsEngine` converts timestamped visual-tracking
coordinates into velocity and acceleration estimates. It accepts either pixel
centroids plus a scale or Dev 2's calibrated metre coordinates. The physics
package has no third-party dependencies.

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

The live backend reads calibrated positions from Dev 2 and returns a `state`
message for each processed frame after a `mode` is configured. Its physics
session supports `free_fall`, `ramp`, `pendulum`, and `collision`; see
[`backend/README.md`](backend/README.md) for the wire format and required
calibration. Model-derived forces are distinct from measured acceleration.

Run the tests with:

```shell
python3 -m unittest discover -v
```

For the backend integration tests, install `backend/requirements.txt` and run
`python3 -m pytest backend/tests -q` from the repository root.
