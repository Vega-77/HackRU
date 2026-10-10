# HandsOn Physics

HackRU prototype for tracking physical experiments and displaying physics
telemetry over a live camera view.

The single Python backend is in [`backend/`](backend/README.md). It provides
the `/ws/frames` WebSocket used by the mobile client, object tracking,
calibration, a browser debug view, and sample clips. See the backend README for
setup, the wire protocol, and tests.

The CV pipeline currently reports tracked positions. Kinematics and force
calculations still need Dev 3's engine to be connected.
