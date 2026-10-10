import random
import unittest

from physics_engine import KinematicsEngine


class KinematicsEngineTests(unittest.TestCase):
    def test_stationary_object_has_zero_motion(self) -> None:
        engine = KinematicsEngine()

        for frame in range(10):
            result = engine.add_sample(frame * 0.1, 100.0, 200.0, 0.01)

        self.assertTrue(result.acceleration_valid)
        self.assertAlmostEqual(result.speed_mps, 0.0, places=9)
        self.assertAlmostEqual(result.acceleration_mps2.magnitude, 0.0, places=9)

    def test_constant_velocity_with_irregular_frame_times(self) -> None:
        engine = KinematicsEngine(invert_y=False)
        times = [0.0, 0.08, 0.19, 0.31, 0.46, 0.58, 0.73]

        for timestamp in times:
            # Position is measured in pixels; scale is 0.01 metres per pixel.
            result = engine.add_sample(
                timestamp,
                x_px=(2.0 * timestamp) / 0.01,
                y_px=(-0.5 * timestamp) / 0.01,
                meters_per_pixel=0.01,
            )

        self.assertAlmostEqual(result.velocity_mps.x, 2.0, places=9)
        self.assertAlmostEqual(result.velocity_mps.y, -0.5, places=9)
        self.assertAlmostEqual(result.acceleration_mps2.x, 0.0, places=9)
        self.assertAlmostEqual(result.acceleration_mps2.y, 0.0, places=9)

    def test_constant_acceleration(self) -> None:
        engine = KinematicsEngine(invert_y=False)
        acceleration = 3.0
        times = [frame * 0.1 for frame in range(7)]

        for timestamp in times:
            x_metres = 0.5 * acceleration * timestamp**2
            result = engine.add_sample(timestamp, x_metres * 100.0, 0.0, 0.01)

        expected_velocity = acceleration * times[-1]
        self.assertAlmostEqual(result.velocity_mps.x, expected_velocity, places=9)
        self.assertAlmostEqual(result.acceleration_mps2.x, acceleration, places=9)

    def test_quadratic_fit_reduces_position_noise(self) -> None:
        random_source = random.Random(42)
        engine = KinematicsEngine(window_size=11, invert_y=False)

        for frame in range(11):
            timestamp = frame * 0.05
            true_x_metres = timestamp
            noisy_x_metres = true_x_metres + random_source.uniform(-0.002, 0.002)
            result = engine.add_sample(timestamp, noisy_x_metres * 1000.0, 0.0, 0.001)

        self.assertAlmostEqual(result.velocity_mps.x, 1.0, delta=0.04)
        self.assertAlmostEqual(result.acceleration_mps2.x, 0.0, delta=0.2)

    def test_low_confidence_resets_history(self) -> None:
        engine = KinematicsEngine(confidence_threshold=0.7)
        engine.add_sample(0.0, 0.0, 0.0, 0.01)
        engine.add_sample(0.1, 1.0, 0.0, 0.01)

        lost = engine.add_sample(0.2, 2.0, 0.0, 0.01, confidence=0.4)
        recovered = engine.add_sample(0.3, 3.0, 0.0, 0.01)

        self.assertFalse(lost.tracking_valid)
        self.assertEqual(lost.reason, "tracking_confidence_below_threshold")
        self.assertEqual(recovered.sample_count, 1)
        self.assertFalse(recovered.velocity_valid)

    def test_duplicate_timestamp_is_rejected_without_division_by_zero(self) -> None:
        engine = KinematicsEngine()
        engine.add_sample(1.0, 10.0, 10.0, 0.01)

        duplicate = engine.add_sample(1.0, 11.0, 10.0, 0.01)
        recovered = engine.add_sample(1.1, 12.0, 10.0, 0.01)

        self.assertFalse(duplicate.tracking_valid)
        self.assertEqual(duplicate.reason, "timestamp_not_strictly_increasing")
        self.assertTrue(recovered.velocity_valid)

    def test_long_frame_gap_starts_a_new_track(self) -> None:
        engine = KinematicsEngine(max_gap_seconds=0.25)
        engine.add_sample(0.0, 0.0, 0.0, 0.01)
        engine.add_sample(0.1, 1.0, 0.0, 0.01)

        result = engine.add_sample(1.0, 100.0, 0.0, 0.01)

        self.assertEqual(result.sample_count, 1)
        self.assertFalse(result.velocity_valid)

    def test_image_y_axis_is_inverted_by_default(self) -> None:
        engine = KinematicsEngine()
        engine.add_sample(0.0, 0.0, 10.0, 0.01)
        result = engine.add_sample(0.1, 0.0, 20.0, 0.01)

        self.assertAlmostEqual(result.velocity_mps.y, -1.0)

    def test_result_is_json_serializable(self) -> None:
        engine = KinematicsEngine()
        result = engine.add_sample(0.0, 10.0, 20.0, 0.01)

        payload = result.to_dict()

        self.assertEqual(payload["position_m"], {"x": 0.1, "y": -0.2})
        self.assertTrue(payload["tracking_valid"])


if __name__ == "__main__":
    unittest.main()
