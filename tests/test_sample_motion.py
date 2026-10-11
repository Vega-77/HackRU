"""Check the physics stage against Dev 2's synthetic experiment truth data."""

from __future__ import annotations

import csv
import unittest
from math import atan2, degrees, hypot
from pathlib import Path

from physics_engine import PhysicsSession


SAMPLES = Path(__file__).resolve().parents[1] / "backend" / "samples"


def _angle_between(a: tuple[float, float], b: tuple[float, float]) -> float:
    difference = degrees(atan2(a[1], a[0]) - atan2(b[1], b[0]))
    return abs((difference + 180) % 360 - 180)


def read_truth(name: str) -> list[dict]:
    with (SAMPLES / f"{name}_truth.csv").open(newline="") as handle:
        return list(csv.DictReader(handle))


class SampleMotionTests(unittest.TestCase):
    def test_ramp_truth_recovers_slope_and_acceleration(self) -> None:
        session = PhysicsSession()
        states = {}
        for row in read_truth("ramp"):
            frame_id = int(row["frame"])
            obj = {
                "id": 1, "target": True, "score": 1.0,
                "pixel": {"x": 100, "y": 100},
                "bbox": {"x": 90, "y": 90, "w": 20, "h": 20},
                "position": {"x": float(row["x_m"]), "y": float(row["y_m"])},
            }
            states[frame_id] = session.process_frame(
                {"type": "frame", "frame_id": frame_id, "timestamp": float(row["t"]),
                 "tracked": True, "objects": [obj]},
                {"mode": "ramp", "mass_kg": 0.1},
            )

        moving = states[20]
        self.assertAlmostEqual(moving["acceleration"]["x"], 2.68, delta=0.15)
        self.assertAlmostEqual(moving["extras"]["angle_deg"], -25.0, delta=1.0)
        self.assertIn("normal", {force["name"] for force in moving["forces"]})
        self.assertNotIn("thermal", moving["energy"])

    def test_pendulum_truth_yields_angle_and_tension(self) -> None:
        session = PhysicsSession()
        states = {}
        for row in read_truth("pendulum"):
            frame_id = int(row["frame"])
            obj = {
                "id": 1, "target": True, "score": 1.0,
                "pixel": {"x": 100, "y": 100},
                "bbox": {"x": 90, "y": 90, "w": 20, "h": 20},
                "position": {"x": float(row["x_m"]), "y": float(row["y_m"])},
            }
            states[frame_id] = session.process_frame(
                {"type": "frame", "frame_id": frame_id, "timestamp": float(row["t"]),
                 "tracked": True, "objects": [obj]},
                {"mode": "pendulum", "mass_kg": 0.1},
            )

        near_bottom = states[8]
        self.assertAlmostEqual(near_bottom["extras"]["theta_deg"], 0.0, delta=2.0)
        self.assertAlmostEqual(near_bottom["extras"]["length_m"], 0.28, delta=0.01)
        self.assertIn("tension", {force["name"] for force in near_bottom["forces"]})

    def test_pendulum_vectors_point_the_right_way(self) -> None:
        """Tension toward the pivot, velocity and acceleration along the true motion."""
        rows = read_truth("pendulum")
        points = [(float(row["x_m"]), float(row["y_m"])) for row in rows]
        dt = float(rows[1]["t"]) - float(rows[0]["t"])
        pivot = (0.30, 0.37)  # generate_samples.pendulum_frames
        session = PhysicsSession()
        checked = 0
        for k, row in enumerate(rows):
            x, y = points[k]
            # A square-on camera at 1000 px per metre, image y down from y = 0.5 m.
            obj = {
                "id": 1, "target": True, "score": 1.0,
                "pixel": {"x": 1000 * x, "y": 1000 * (0.5 - y)},
                "bbox": {"x": 90, "y": 90, "w": 20, "h": 20},
                "position": {"x": x, "y": y},
                "screen_axes": {"x": {"x": 1000, "y": 0}, "y": {"x": 0, "y": -1000}},
            }
            state = session.process_frame(
                {"type": "frame", "frame_id": k, "timestamp": float(row["t"]),
                 "tracked": True, "objects": [obj]},
                {"mode": "pendulum", "mass_kg": 0.1},
            )
            forces = {force["name"]: force for force in state["forces"]}
            if "tension" not in forces or k + 1 >= len(rows):
                continue
            checked += 1
            before, after = points[k - 1], points[k + 1]
            true_velocity = ((after[0] - before[0]) / (2 * dt), (after[1] - before[1]) / (2 * dt))
            true_acceleration = (
                (after[0] - 2 * x + before[0]) / dt**2, (after[1] - 2 * y + before[1]) / dt**2,
            )
            self.assertAlmostEqual(state["pivot_pixel"]["x"], 1000 * pivot[0], delta=5)
            self.assertAlmostEqual(state["pivot_pixel"]["y"], 1000 * (0.5 - pivot[1]), delta=5)
            tension = forces["tension"]
            self.assertLess(_angle_between((tension["x"], tension["y"]), (pivot[0] - x, pivot[1] - y)), 3.0)
            self.assertGreater(hypot(tension["x"], tension["y"]), 0.0)
            acceleration = state["acceleration"]
            self.assertLess(_angle_between((acceleration["x"], acceleration["y"]), true_acceleration), 5.0, k)
            if hypot(*true_velocity) > 0.2:
                velocity = state["velocity"]
                self.assertLess(_angle_between((velocity["x"], velocity["y"]), true_velocity), 3.0, k)
        self.assertGreater(checked, 90)

    def test_collision_truth_keeps_two_tracks_and_reports_metrics(self) -> None:
        session = PhysicsSession()
        rows = read_truth("carts")
        states = {}
        for offset in range(0, len(rows), 2):
            pair = rows[offset:offset + 2]
            frame_id = int(pair[0]["frame"])
            objects = [
                {
                    "id": index + 1, "target": index == 0, "score": 1.0,
                    "pixel": {"x": 100 + index, "y": 100},
                    "bbox": {"x": 90 + index, "y": 90, "w": 20, "h": 20},
                    "position": {"x": float(row["x_m"]), "y": float(row["y_m"])},
                    "width_m": 0.06,
                }
                for index, row in enumerate(pair)
            ]
            states[frame_id] = session.process_frame(
                {"type": "frame", "frame_id": frame_id, "timestamp": float(pair[0]["t"]),
                 "tracked": True, "objects": objects},
                {"mode": "collision", "mass_kg": 0.2},
            )

        self.assertEqual(len(states[35]["collision_objects"]), 2)
        self.assertIn("restitution", states[35]["extras"])
        self.assertAlmostEqual(states[35]["extras"]["restitution"], 1.0, delta=0.25)
        self.assertAlmostEqual(states[35]["extras"]["momentum_delta"], 0.0, delta=0.08)


if __name__ == "__main__":
    unittest.main()
