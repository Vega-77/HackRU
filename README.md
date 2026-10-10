# HackRU

HandsOn Physics: an AR physics assistant. The Python CV backend lives in
[`backend/`](backend/README.md).

## Physics engine

`physics_engine.KinematicsEngine` converts timestamped visual-tracking
centroids into position, velocity, and acceleration estimates. It has no
third-party dependencies.

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

Run the tests with:

```shell
python3 -m unittest discover -v
```
