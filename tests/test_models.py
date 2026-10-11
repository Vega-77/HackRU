from __future__ import annotations

import math
import unittest

from physics_engine import PhysicsSession, Vector2D, collision_metrics, motion_model


class PhysicsModelTests(unittest.TestCase):
    def test_ramp_force_components_balance_perpendicular_gravity(self) -> None:
        result = motion_model(
            "ramp", Vector2D(0.2, 0.3), Vector2D(0.0, 0.0),
            Vector2D(1.0, -0.5), 0.2, {"ramp_angle_deg": -30.0},
        )
        forces = {item["name"]: item for item in result["forces"]}

        self.assertAlmostEqual(forces["gravity"]["y"], -1.962)
        self.assertAlmostEqual(forces["normal"]["x"] + forces["gravity_perpendicular"]["x"], 0.0)
        self.assertAlmostEqual(forces["normal"]["y"] + forces["gravity_perpendicular"]["y"], 0.0)
        self.assertAlmostEqual(forces["net"]["x"], 0.2)
        self.assertAlmostEqual(result["energy"]["potential"], 0.2 * 9.81 * 0.3)
        self.assertNotIn("mu", result["extras"])

    def test_level_plane_puts_gravity_into_the_plane(self) -> None:
        # A floor picked with ARKit: gravity is out of the plane, not along its y axis.
        result = motion_model(
            "ramp", Vector2D(0.1, 0.4), Vector2D(0.0, 0.0), None, 0.2, {},
            gravity=(0.0, 0.0, -9.81),
        )
        forces = {item["name"]: item for item in result["forces"]}

        self.assertAlmostEqual(forces["gravity"]["x"], 0.0)
        self.assertAlmostEqual(forces["gravity"]["y"], 0.0)
        self.assertAlmostEqual(forces["gravity"]["z"], -1.962)
        self.assertAlmostEqual(result["energy"]["potential"], 0.0)
        self.assertAlmostEqual(result["extras"]["angle_deg"], 0.0)

    def test_tilted_plane_is_the_ramp_and_gives_its_angle_at_rest(self) -> None:
        tilt = math.radians(20)
        gravity = (0.0, -9.81 * math.sin(tilt), -9.81 * math.cos(tilt))
        result = motion_model(
            "ramp", Vector2D(0.0, 0.5), Vector2D(0.0, 0.0), None, 0.1, {},
            gravity=gravity,
        )
        forces = {item["name"]: item for item in result["forces"]}

        self.assertAlmostEqual(result["extras"]["angle_deg"], 20.0)
        self.assertAlmostEqual(forces["gravity_parallel"]["y"], -0.981 * math.sin(tilt))
        self.assertAlmostEqual(forces["gravity_perpendicular"]["z"], -0.981 * math.cos(tilt))
        self.assertAlmostEqual(forces["normal"]["z"], 0.981 * math.cos(tilt))
        self.assertNotIn("friction", forces)
        # Half a metre up the slope is 0.5 sin(20) m higher.
        self.assertAlmostEqual(result["energy"]["potential"], 0.981 * 0.5 * math.sin(tilt))

    def test_rolling_down_a_tilted_plane_has_friction_up_the_slope(self) -> None:
        tilt = math.radians(30)
        g_in = 9.81 * math.sin(tilt)
        result = motion_model(
            "ramp", Vector2D(0.0, 0.0), Vector2D(0.0, -0.5), Vector2D(0.0, -5 / 7 * g_in), 0.1,
            {"sliding_body": True, "normal_from_contacts": True},
            gravity=(0.0, -g_in, -9.81 * math.cos(tilt)),
        )
        forces = {item["name"]: item for item in result["forces"]}

        self.assertNotIn("normal", forces)
        self.assertAlmostEqual(forces["friction"]["y"], 0.1 * 2 / 7 * g_in)
        self.assertAlmostEqual(result["extras"]["mu"], 2 / 7 * math.tan(tilt))

    def test_pendulum_at_bottom_has_radial_tension(self) -> None:
        result = motion_model(
            "pendulum", Vector2D(0.0, -0.5), Vector2D(1.0, 0.0),
            Vector2D(0.0, 0.0), 0.1, {"pendulum_pivot_m": {"x": 0.0, "y": 0.0}},
        )
        forces = {item["name"]: item for item in result["forces"]}

        self.assertAlmostEqual(forces["tension"]["y"], 0.1 * (9.81 + 2.0))
        self.assertAlmostEqual(result["energy"]["potential"], 0.0)
        self.assertAlmostEqual(result["extras"]["theta_deg"], 0.0)

    def test_free_fall_gravity_and_measured_net_are_separate(self) -> None:
        result = motion_model(
            "free_fall", Vector2D(0.0, 2.0), Vector2D(0.0, -3.0),
            Vector2D(0.0, -9.5), 0.1, {},
        )
        forces = {item["name"]: item for item in result["forces"]}

        self.assertAlmostEqual(forces["gravity"]["y"], -0.981)
        self.assertAlmostEqual(forces["net"]["y"], -0.95)
        self.assertAlmostEqual(result["energy"]["kinetic"], 0.45)

    def test_equal_mass_elastic_collision(self) -> None:
        result = collision_metrics(
            Vector2D(1.0, 0.0), Vector2D(0.0, 0.0),
            Vector2D(0.0, 0.0), Vector2D(1.0, 0.0),
            0.2, 0.2, Vector2D(1.0, 0.0),
        )

        self.assertAlmostEqual(result["restitution"], 1.0)
        self.assertAlmostEqual(result["momentum_delta"], 0.0)
        self.assertAlmostEqual(result["kinetic_after"], result["kinetic_before"])

    def test_unmeasurable_collision_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            collision_metrics(
                Vector2D(0.0, 0.0), Vector2D(1.0, 0.0),
                Vector2D(0.0, 0.0), Vector2D(1.0, 0.0),
                0.1, 0.1, Vector2D(1.0, 0.0),
            )


class PhysicsSessionTests(unittest.TestCase):
    @staticmethod
    def frame(index: int, x: float | None, mode: str = "ramp") -> dict:
        obj = {
            "id": 7, "target": True, "score": 0.99,
            "pixel": {"x": 100 + index, "y": 200},
            "bbox": {"x": 90 + index, "y": 190, "w": 20, "h": 20},
            "position": None if x is None else {"x": x, "y": 0.3 - 0.5 * x},
            "width_m": 0.04,
        }
        return {
            "type": "frame", "frame_id": index, "timestamp": index * 0.1,
            "tracked": True, "objects": [obj], "target_id": 7,
        }

    def test_cv_frame_becomes_frontend_state(self) -> None:
        session = PhysicsSession()
        settings = {"mode": "ramp", "mass_kg": 0.1, "ramp_angle_deg": -26.565}

        for index in range(5):
            result = session.process_frame(self.frame(index, 0.02 * index), settings)

        self.assertEqual(result["type"], "state")
        self.assertEqual(result["frame_id"], 4)
        self.assertEqual(result["pixel"], {"x": 104, "y": 200})
        self.assertAlmostEqual(result["velocity"]["x"], 0.2)
        self.assertAlmostEqual(result["velocity"]["y"], -0.1)
        self.assertAlmostEqual(result["acceleration"]["x"], 0.0)
        self.assertIn("gravity_parallel", {force["name"] for force in result["forces"]})

    def test_ball_at_rest_on_a_tilted_arkit_plane_shows_the_ramp(self) -> None:
        tilt = math.radians(15)
        plane = {"x_axis": [1.0, 0.0, 0.0], "y_axis": [0.0, math.sin(tilt), -math.cos(tilt)],
                 "normal": [0.0, math.cos(tilt), math.sin(tilt)]}
        session = PhysicsSession()
        for index in range(6):
            frame = self.frame(index, 0.1)
            frame["calibration"] = {"method": "arkit", "plane": plane}
            result = session.process_frame(frame, {"mode": "ramp", "mass_kg": 0.1})

        forces = {item["name"]: item for item in result["forces"]}
        self.assertAlmostEqual(result["extras"]["angle_deg"], 15.0)
        self.assertIn("gravity_parallel", forces)
        # In the world, gravity points straight down whatever the plane.
        gravity_3d = next(f for f in result["forces_3d"] if f["name"] == "gravity")
        self.assertAlmostEqual(gravity_3d["x"], 0.0, places=5)
        self.assertAlmostEqual(gravity_3d["y"], -0.981, places=5)
        self.assertAlmostEqual(gravity_3d["z"], 0.0, places=5)

    def test_path_across_a_level_plane_is_not_a_ramp_angle(self) -> None:
        plane = {"x_axis": [1.0, 0.0, 0.0], "y_axis": [0.0, 0.0, -1.0], "normal": [0.0, 1.0, 0.0]}
        session = PhysicsSession()
        for index in range(6):
            frame = self.frame(index, 0.02 * index)
            frame["calibration"] = {"method": "arkit", "plane": plane}
            result = session.process_frame(frame, {"mode": "ramp", "mass_kg": 0.1})

        self.assertAlmostEqual(result["extras"]["angle_deg"], 0.0)
        self.assertNotIn("ramp_angle", {c["source"] for c in result.get("contacts", [])})

    def test_no_calibration_does_not_fabricate_si_vectors(self) -> None:
        result = PhysicsSession().process_frame(
            self.frame(0, None), {"mode": "ramp", "mass_kg": 0.1}
        )

        self.assertTrue(result["tracked"])
        self.assertIsNone(result["position"])
        self.assertNotIn("velocity", result)
        self.assertNotIn("energy", result)

    def test_missing_target_reports_untracked(self) -> None:
        session = PhysicsSession()
        result = session.process_frame(
            {"type": "frame", "frame_id": 0, "timestamp": 0.0,
             "tracked": False, "objects": []},
            {"mode": "free_fall", "mass_kg": 0.1},
        )

        self.assertFalse(result["tracked"])
        self.assertEqual(result["forces"], [])

    def test_mode_change_resets_derivatives(self) -> None:
        session = PhysicsSession()
        for index in range(4):
            session.process_frame(self.frame(index, 0.02 * index), {"mode": "ramp", "mass_kg": 0.1})

        result = session.process_frame(self.frame(4, 0.08), {"mode": "free_fall", "mass_kg": 0.1})

        self.assertNotIn("velocity", result)

    def test_recalibration_resets_derivatives(self) -> None:
        session = PhysicsSession()
        settings = {"mode": "ramp", "mass_kg": 0.1}
        for index in range(4):
            frame = self.frame(index, 0.02 * index)
            frame["calibration"] = {"method": "scale", "settings": {"px_per_m": 1000}}
            session.process_frame(frame, settings)

        frame = self.frame(4, 0.08)
        frame["calibration"] = {"method": "scale", "settings": {"px_per_m": 500}}
        result = session.process_frame(frame, settings)

        self.assertNotIn("velocity", result)


if __name__ == "__main__":
    unittest.main()
