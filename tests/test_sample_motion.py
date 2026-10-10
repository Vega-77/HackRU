"""Check the physics stage against Dev 2's synthetic experiment truth data."""

from __future__ import annotations

import csv
import unittest
from pathlib import Path

from physics_engine import PhysicsSession


SAMPLES = Path(__file__).resolve().parents[1] / "backend" / "samples"


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
