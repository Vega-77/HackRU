from __future__ import annotations

import math
import unittest

from physics_engine import PhysicsSession, Vector2D
from physics_engine.contact import (
    Body, ContactTracker, Surface, gravity_in_plane, path_surface, plane_support,
)

G = 9.81
SIDE = (0.0, -G, 0.0)
FLOOR = Surface("floor", "tap", (0.0, 0.0, 0.0), (0.0, 1.0, 0.0))


def ball(x=0.1, y=0.02, v=(0.0, 0.0), a=(0.0, 0.0), mass=0.1, body_id=1, size=0.04) -> Body:
    return Body(body_id, mass, Vector2D(x, y), Vector2D(*v), None if a is None else Vector2D(*a), size, size)


def normals(forces: list[dict], name: str = "normal") -> list[dict]:
    return [f for f in forces if f["name"] == name]


def run(tracker: ContactTracker, frames: int, bodies, surfaces) -> dict:
    out = {}
    for _ in range(frames):
        out = tracker.update(bodies, surfaces, SIDE)
    return out


class SurfaceContactTests(unittest.TestCase):
    def test_ball_resting_on_floor_gets_its_weight_back(self) -> None:
        out = run(ContactTracker(), 2, [ball()], {1: [FLOOR]})
        (normal,) = normals(out[1])

        self.assertAlmostEqual(normal["y"], 0.1 * G)
        self.assertAlmostEqual(normal["x"], 0.0)
        self.assertEqual(normal["point"], {"x": 0.1, "y": 0.0})

    def test_contact_needs_two_frames_to_appear(self) -> None:
        tracker = ContactTracker()
        self.assertEqual(tracker.update([ball()], {1: [FLOOR]}, SIDE)[1], [])
        self.assertEqual(len(tracker.update([ball()], {1: [FLOOR]}, SIDE)[1]), 1)

    def test_rolling_down_a_ramp_gives_mg_cos_theta(self) -> None:
        theta = math.radians(25)
        n = (-math.sin(theta), math.cos(theta), 0.0)  # ramp rising towards +x
        ramp = Surface("ramp", "edge", (0.0, 0.0, 0.0), n)
        along = 5 / 7 * G * math.sin(theta)
        down_slope = (-math.cos(theta), -math.sin(theta))
        body = ball(x=0.3 * math.cos(theta) + n[0] * 0.02, y=0.3 * math.sin(theta) + n[1] * 0.02,
                    v=(0.4 * down_slope[0], 0.4 * down_slope[1]),
                    a=(along * down_slope[0], along * down_slope[1]))
        (normal,) = normals(run(ContactTracker(), 2, [body], {1: [ramp]})[1])

        self.assertAlmostEqual(math.hypot(normal["x"], normal["y"]), 0.1 * G * math.cos(theta), places=6)
        self.assertAlmostEqual(normal["x"] / normal["y"], n[0] / n[1])

    def test_falling_ball_close_to_the_floor_has_no_normal_force(self) -> None:
        falling = ball(y=0.025, v=(0.0, -1.0), a=(0.0, -G))
        self.assertEqual(run(ContactTracker(), 3, [falling], {1: [FLOOR]})[1], [])

    def test_ball_high_above_the_floor_has_no_normal_force(self) -> None:
        self.assertEqual(run(ContactTracker(), 3, [ball(y=0.2)], {1: [FLOOR]})[1], [])

    def test_bouncing_away_is_not_contact(self) -> None:
        leaving = ball(v=(0.0, 1.2), a=(0.0, 30.0))
        self.assertEqual(run(ContactTracker(), 3, [leaving], {1: [FLOOR]})[1], [])

    def test_one_missed_frame_does_not_drop_the_arrow(self) -> None:
        tracker = ContactTracker()
        run(tracker, 2, [ball()], {1: [FLOOR]})
        held = tracker.update([ball(y=0.2)], {1: [FLOOR]}, SIDE)[1]
        self.assertEqual(len(normals(held)), 1)
        dropped = run(tracker, 3, [ball(y=0.2)], {1: [FLOOR]})[1]
        self.assertEqual(dropped, [])

    def test_a_better_source_wins_over_a_duplicate(self) -> None:
        edge = Surface("edge", "edge", (0.0, 0.001, 0.0), (0.0, 1.0, 0.0))
        out = run(ContactTracker(), 2, [ball()], {1: [edge, FLOOR]})[1]
        self.assertEqual(len(normals(out)), 1)
        self.assertEqual(len(out), 1)

    def test_resting_in_a_corner_does_not_push_on_the_wall(self) -> None:
        wall = Surface("wall", "tap", (0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        out = run(ContactTracker(), 2, [ball(x=0.02)], {1: [FLOOR, wall]})[1]
        self.assertEqual([f["name"] for f in out], ["normal"])
        self.assertAlmostEqual(out[0]["y"], 0.1 * G)

    def test_ball_pushed_into_a_wall_gets_two_normal_forces(self) -> None:
        wall = Surface("wall", "tap", (0.0, 0.0, 0.0), (1.0, 0.0, 0.0))
        pushed = ball(x=0.02, v=(-0.05, 0.0), a=(2.0, 0.0))  # rolled into the wall, being stopped
        out = run(ContactTracker(), 2, [pushed], {1: [FLOOR, wall]})[1]
        names = sorted(f["name"] for f in out)
        self.assertEqual(names, ["normal", "normal_2"])
        forces = {f["name"]: f for f in out}
        self.assertAlmostEqual(forces["normal"]["y"], 0.1 * G)
        self.assertAlmostEqual(forces["normal_2"]["x"], 0.2)


class PlaneAndPathTests(unittest.TestCase):
    def test_table_seen_from_above_supports_out_of_the_plane(self) -> None:
        gravity = gravity_in_plane(None, "top")
        support = plane_support(gravity)
        out = ContactTracker()
        for _ in range(2):
            forces = out.update([ball(y=0.3)], {1: [support]}, gravity)[1]
        (normal,) = normals(forces)
        self.assertAlmostEqual(normal["z"], 0.1 * G)
        self.assertNotIn("point", normal)

    def test_side_on_board_is_not_a_support(self) -> None:
        self.assertIsNone(plane_support(gravity_in_plane(None, "side")))

    def test_arkit_plane_axes_give_gravity_in_plane_coordinates(self) -> None:
        tilt = math.radians(30)
        plane = {"x_axis": [1.0, 0.0, 0.0], "y_axis": [0.0, math.sin(tilt), -math.cos(tilt)],
                 "normal": [0.0, math.cos(tilt), math.sin(tilt)]}
        gx, gy, gz = gravity_in_plane(plane, None)
        self.assertAlmostEqual(gx, 0.0)
        self.assertAlmostEqual(gy, -G * math.sin(tilt))
        self.assertAlmostEqual(gz, -G * math.cos(tilt))
        self.assertIsNotNone(plane_support((gx, gy, gz)))

    def test_straight_path_becomes_a_track_one_radius_below(self) -> None:
        samples = [(0.1 + 0.01 * k, 0.05) for k in range(7)]
        surface = path_surface(ball(x=0.16, y=0.05), samples, SIDE)
        self.assertEqual(surface.normal, (0.0, 1.0, 0.0))
        self.assertAlmostEqual(surface.point[1], 0.03)

    def test_steep_or_curved_path_is_not_a_track(self) -> None:
        falling = [(0.1, 0.5 - 0.02 * k) for k in range(7)]
        arc = [(0.1 + 0.01 * k, 0.05 + 0.004 * (k - 3) ** 2) for k in range(7)]
        self.assertIsNone(path_surface(ball(), falling, SIDE))
        self.assertIsNone(path_surface(ball(), arc, SIDE))


class BodyContactTests(unittest.TestCase):
    def test_stacked_balls_push_equal_and_opposite(self) -> None:
        bottom = ball(body_id=1, y=0.02)
        top = ball(body_id=2, y=0.06)
        out = run(ContactTracker(), 2, [bottom, top], {1: [FLOOR], 2: []})
        (on_top,) = normals(out[2], "normal_contact")
        (on_bottom,) = normals(out[1], "normal_contact")
        self.assertAlmostEqual(on_top["y"], 0.1 * G)
        self.assertAlmostEqual(on_bottom["y"], -0.1 * G)
        # The floor holds both up.
        (floor,) = normals(out[1])
        self.assertAlmostEqual(floor["y"], 0.2 * G)

    def test_side_by_side_balls_at_rest_do_not_push(self) -> None:
        out = run(ContactTracker(), 2, [ball(body_id=1, x=0.1), ball(body_id=2, x=0.14)], {1: [FLOOR], 2: [FLOOR]})
        self.assertEqual(normals(out[1], "normal_contact"), [])

    def test_collision_push_shows_on_both_carts(self) -> None:
        a = ball(body_id=1, x=0.1, v=(0.1, 0.0), a=(-3.0, 0.0))
        b = ball(body_id=2, x=0.14, v=(0.2, 0.0), a=(3.0, 0.0))
        out = run(ContactTracker(), 2, [a, b], {1: [], 2: []})
        (on_a,) = normals(out[1], "normal_contact")
        (on_b,) = normals(out[2], "normal_contact")
        self.assertAlmostEqual(on_a["x"], -0.3)
        self.assertAlmostEqual(on_b["x"], 0.3)


class SessionContactTests(unittest.TestCase):
    def frame(self, k: int, y: float, surfaces: list[dict]) -> dict:
        return {
            "timestamp": k / 30, "calibration": {"method": "aruco"},
            "objects": [{"id": 1, "target": True, "position": {"x": 0.2, "y": y}, "score": 1.0,
                         "width_m": 0.04, "height_m": 0.04, "surfaces": surfaces}],
        }

    def test_dropped_ball_gets_a_normal_force_only_once_it_lands(self) -> None:
        session = PhysicsSession()
        floor = [{"id": "edge", "source": "edge", "point": [0.0, 0.0], "normal": [0.0, 1.0]}]
        states = []
        y, v = 0.3, 0.0
        for k in range(40):
            states.append(session.process_frame(self.frame(k, y, floor), {"mode": "free_fall", "mass_kg": 0.1}))
            v -= G / 30
            y = max(0.02, y + v / 30)
            if y == 0.02:
                v = 0.0
        falling = [s for s in states[3:8]]
        resting = states[-1]
        self.assertTrue(all(not normals(s["forces"]) for s in falling))
        (normal,) = normals(resting["forces"])
        self.assertAlmostEqual(normal["y"], 0.1 * G, places=1)
        self.assertEqual(resting["contacts"][0]["source"], "edge")

    def test_pendulum_has_no_contact_forces(self) -> None:
        session = PhysicsSession()
        floor = [{"id": "edge", "source": "edge", "point": [0.0, 0.0], "normal": [0.0, 1.0]}]
        for k in range(5):
            state = session.process_frame(self.frame(k, 0.02, floor), {"mode": "pendulum", "mass_kg": 0.1})
        self.assertEqual(normals(state["forces"]), [])
        self.assertNotIn("contacts", state)


if __name__ == "__main__":
    unittest.main()
