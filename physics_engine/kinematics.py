"""Streaming two-dimensional kinematics from visual tracking samples.

The computer-vision pipeline supplies a timestamped object centroid in pixels.
This module converts the centroid to metres and estimates velocity and
acceleration by fitting a quadratic to a rolling window of recent positions.
The fit smooths small tracking errors and works with irregular frame times.
"""

from __future__ import annotations

from collections import deque
from dataclasses import asdict, dataclass
from math import atan, atan2, cos, degrees, hypot, isfinite, pi, sin, sqrt
from typing import Deque, Optional


@dataclass(frozen=True)
class Vector2D:
    """A two-dimensional vector."""

    x: float
    y: float

    @property
    def magnitude(self) -> float:
        return hypot(self.x, self.y)


@dataclass(frozen=True)
class _PositionSample:
    timestamp: float
    x: float
    y: float


@dataclass(frozen=True)
class KinematicsResult:
    """Latest motion estimate returned to the backend or renderer."""

    timestamp: float
    position_m: Vector2D
    velocity_mps: Vector2D
    acceleration_mps2: Vector2D
    speed_mps: float
    velocity_valid: bool
    acceleration_valid: bool
    tracking_valid: bool
    sample_count: int
    reason: Optional[str] = None
    span_s: float = 0.0
    position_residual_m: float = 0.0
    acceleration_std_mps2: Optional[float] = None

    def to_dict(self) -> dict:
        """Return a JSON-serializable representation."""

        return asdict(self)


class KinematicsEngine:
    """Estimate motion from a rolling stream of visual coordinates.

    Args:
        window_size: Number of recent valid positions used for each estimate.
        confidence_threshold: Samples below this tracking confidence reset the
            engine so motion is not calculated across a tracking loss.
        invert_y: Convert image coordinates (positive Y points down) into a
            physics coordinate system (positive Y points up).
        max_gap_seconds: Reset if consecutive samples are farther apart than
            this. Set to ``None`` to disable gap detection.
    """

    def __init__(
        self,
        window_size: int = 7,
        confidence_threshold: float = 0.5,
        invert_y: bool = True,
        max_gap_seconds: Optional[float] = 0.5,
        max_window_seconds: Optional[float] = None,
        min_acceleration_samples: int = 3,
        min_acceleration_span: float = 0.0,
        position_noise_m: float = 0.0,
        max_acceleration_std: Optional[float] = None,
    ) -> None:
        if window_size < 3:
            raise ValueError("window_size must be at least 3")
        if not 0.0 <= confidence_threshold <= 1.0:
            raise ValueError("confidence_threshold must be between 0 and 1")
        if max_gap_seconds is not None and max_gap_seconds <= 0.0:
            raise ValueError("max_gap_seconds must be positive or None")

        self.window_size = window_size
        self.confidence_threshold = confidence_threshold
        self.invert_y = invert_y
        self.max_gap_seconds = max_gap_seconds
        self.max_window_seconds = max_window_seconds
        self.min_acceleration_samples = min_acceleration_samples
        self.min_acceleration_span = min_acceleration_span
        self.position_noise_m = position_noise_m
        self.max_acceleration_std = max_acceleration_std
        self._samples: Deque[_PositionSample] = deque(maxlen=window_size)

    def reset(self) -> None:
        """Discard motion history, for example after tracking is lost."""

        self._samples.clear()

    def recent_positions(self) -> list[tuple[float, float]]:
        """The positions in the current window, oldest first."""

        return [(sample.x, sample.y) for sample in self._samples]

    def trajectory_angle_deg(self, min_horizontal_m: float = 0.03) -> Optional[float]:
        """Estimate the slope of a straight track, independent of travel direction."""

        if len(self._samples) < 3:
            return None
        first, last = self._samples[0], self._samples[-1]
        dx = last.x - first.x
        if abs(dx) < min_horizontal_m:
            return None
        return degrees(atan((last.y - first.y) / dx))

    def estimate_circle_center(self) -> Optional[Vector2D]:
        """Estimate a pendulum pivot from a curved trajectory segment.

        A circle fit is underdetermined on a nearly straight or stationary
        segment, so callers should wait for enough arc motion.
        """

        if len(self._samples) < 5:
            return None
        xs = [sample.x for sample in self._samples]
        ys = [sample.y for sample in self._samples]
        if max(xs) - min(xs) < 0.025:
            return None
        matrix = [
            [sum(x * x for x in xs), sum(x * y for x, y in zip(xs, ys)), sum(xs),
             sum(x * (x * x + y * y) for x, y in zip(xs, ys))],
            [sum(x * y for x, y in zip(xs, ys)), sum(y * y for y in ys), sum(ys),
             sum(y * (x * x + y * y) for x, y in zip(xs, ys))],
            [sum(xs), sum(ys), float(len(xs)), sum(x * x + y * y for x, y in zip(xs, ys))],
        ]
        try:
            twice_cx, twice_cy, _ = _solve_3x3(matrix)
        except ValueError:
            return None
        pivot = Vector2D(twice_cx / 2.0, twice_cy / 2.0)
        radii = [hypot(x - pivot.x, y - pivot.y) for x, y in zip(xs, ys)]
        mean_radius = sum(radii) / len(radii)
        if mean_radius <= 0 or max(abs(radius - mean_radius) for radius in radii) > 0.02 * mean_radius:
            return None
        if pivot.y <= self._samples[-1].y:
            return None
        return pivot

    def pendulum_estimate(
        self, pivot: Vector2D, gravity_mps2: float = 9.81
    ) -> Optional[tuple[Vector2D, Vector2D]]:
        """Velocity and acceleration of a bob swinging about ``pivot``.

        The generic quadratic fit assumes constant acceleration across the
        window, but a pendulum's acceleration turns through tens of degrees in
        that time, so its arrow can point up to 90 degrees off. Here the string
        angle is fitted with ``C + A cos(wt) + B sin(wt)``, using the small-swing
        frequency ``w = sqrt(g / L)``, and the derivatives are taken at the
        newest sample. The result is still fitted to the measured positions; the
        model only supplies the shape of the curve. Returns ``None`` until the
        window holds enough samples.
        """

        if len(self._samples) < 5:
            return None
        radii = [hypot(sample.x - pivot.x, sample.y - pivot.y) for sample in self._samples]
        length = sum(radii) / len(radii)
        if length <= 0.0:
            return None
        latest_time = self._samples[-1].timestamp
        times = [sample.timestamp - latest_time for sample in self._samples]
        # Angle from straight down, positive toward +X; unwrapped so a swing
        # through the top does not jump by a full turn.
        angles = []
        for sample in self._samples:
            angle = atan2(sample.x - pivot.x, pivot.y - sample.y)
            if angles:
                while angle - angles[-1] > pi:
                    angle -= 2 * pi
                while angle - angles[-1] < -pi:
                    angle += 2 * pi
            angles.append(angle)
        omega = sqrt(gravity_mps2 / length)
        basis = [(1.0, cos(omega * t), sin(omega * t)) for t in times]
        matrix = [
            [sum(row[i] * row[j] for row in basis) for j in range(3)]
            + [sum(row[i] * angle for row, angle in zip(basis, angles))]
            for i in range(3)
        ]
        try:
            _, a, b = _solve_3x3(matrix)
        except ValueError:
            return None
        # At t = 0: theta' = b * w, theta'' = -a * w^2.
        angular_velocity = b * omega
        angular_acceleration = -a * omega**2
        latest = self._samples[-1]
        radius = hypot(latest.x - pivot.x, latest.y - pivot.y)
        if radius <= 0.0:
            return None
        inward = Vector2D((pivot.x - latest.x) / radius, (pivot.y - latest.y) / radius)
        tangent = Vector2D(inward.y, -inward.x)  # direction of increasing angle
        speed = length * angular_velocity
        along = length * angular_acceleration
        centripetal = length * angular_velocity**2
        velocity = Vector2D(tangent.x * speed, tangent.y * speed)
        acceleration = Vector2D(
            tangent.x * along + inward.x * centripetal,
            tangent.y * along + inward.y * centripetal,
        )
        return velocity, acceleration

    def add_sample(
        self,
        timestamp: float,
        x_px: float,
        y_px: float,
        meters_per_pixel: float,
        confidence: float = 1.0,
    ) -> KinematicsResult:
        """Add one tracked centroid and return the current motion estimate.

        Invalid numeric values raise ``ValueError`` because they indicate an
        integration error. Low-confidence, repeated, out-of-order, or
        excessively delayed samples return an invalid result without creating
        a derivative spike.
        """

        values = (timestamp, x_px, y_px, meters_per_pixel, confidence)
        if not all(isfinite(value) for value in values):
            raise ValueError("sample values must be finite numbers")
        if meters_per_pixel <= 0.0:
            raise ValueError("meters_per_pixel must be positive")
        if not 0.0 <= confidence <= 1.0:
            raise ValueError("confidence must be between 0 and 1")

        y_direction = -1.0 if self.invert_y else 1.0
        position = Vector2D(
            x=x_px * meters_per_pixel,
            y=y_direction * y_px * meters_per_pixel,
        )

        return self._add_position(timestamp, position, confidence)

    def add_world_sample(
        self, timestamp: float, x_m: float, y_m: float, confidence: float = 1.0
    ) -> KinematicsResult:
        """Accept Dev 2's calibrated coordinates (metres, positive Y up)."""

        return self._add_position(timestamp, Vector2D(x_m, y_m), confidence)

    def _add_position(
        self, timestamp: float, position: Vector2D, confidence: float
    ) -> KinematicsResult:
        values = (timestamp, position.x, position.y, confidence)
        if not all(isfinite(value) for value in values):
            raise ValueError("sample values must be finite numbers")
        if not 0.0 <= confidence <= 1.0:
            raise ValueError("confidence must be between 0 and 1")

        if confidence < self.confidence_threshold:
            self.reset()
            return self._invalid_result(
                timestamp, position, "tracking_confidence_below_threshold"
            )

        if self._samples:
            time_delta = timestamp - self._samples[-1].timestamp
            if time_delta <= 0.0:
                return self._invalid_result(
                    timestamp, position, "timestamp_not_strictly_increasing"
                )
            if self.max_gap_seconds is not None and time_delta > self.max_gap_seconds:
                self.reset()

        self._samples.append(_PositionSample(timestamp, position.x, position.y))
        if self.max_window_seconds is not None:
            while timestamp - self._samples[0].timestamp > self.max_window_seconds:
                self._samples.popleft()

        velocity = Vector2D(0.0, 0.0)
        acceleration = Vector2D(0.0, 0.0)
        velocity_valid = len(self._samples) >= 2
        span = timestamp - self._samples[0].timestamp
        acceleration_valid = (len(self._samples) >= self.min_acceleration_samples
                              and span >= self.min_acceleration_span)
        residual = 0.0
        acceleration_std = None
        reason = None

        if velocity_valid:
            x_fit, y_fit = self._estimate_axis("x"), self._estimate_axis("y")
            velocity = Vector2D(x_fit[0], y_fit[0])
            acceleration = Vector2D(x_fit[1], y_fit[1])
            residual = hypot(x_fit[2], y_fit[2])
            if len(self._samples) >= 3:
                acceleration_std = hypot(x_fit[3], y_fit[3])
        if not acceleration_valid:
            reason = "insufficient_time_span" if span < self.min_acceleration_span else "insufficient_samples"
        elif self.max_acceleration_std is not None and acceleration_std > self.max_acceleration_std:
            acceleration_valid = False
            reason = "acceleration_uncertain"

        return KinematicsResult(
            timestamp=timestamp,
            position_m=position,
            velocity_mps=velocity,
            acceleration_mps2=acceleration,
            speed_mps=velocity.magnitude,
            velocity_valid=velocity_valid,
            acceleration_valid=acceleration_valid,
            tracking_valid=True,
            sample_count=len(self._samples),
            reason=reason,
            span_s=span,
            position_residual_m=residual,
            acceleration_std_mps2=acceleration_std,
        )

    def mark_tracking_lost(self, timestamp: float = 0.0) -> KinematicsResult:
        """Reset history and report that no tracked position is available."""

        if not isfinite(timestamp):
            raise ValueError("timestamp must be finite")
        self.reset()
        return self._invalid_result(
            timestamp, Vector2D(0.0, 0.0), "tracking_lost"
        )

    def _estimate_axis(self, axis: str) -> tuple[float, float, float, float]:
        """Latest derivatives, residual RMS and acceleration standard error.

        Normalize time before fitting so clustered capture times do not make
        the normal equations singular solely because their units are seconds.
        The noise floor represents pixel localization error, not gravity.
        """

        latest_time = self._samples[-1].timestamp
        times = [sample.timestamp - latest_time for sample in self._samples]
        values = [getattr(sample, axis) for sample in self._samples]

        if len(self._samples) == 2:
            elapsed = times[1] - times[0]
            return (values[1] - values[0]) / elapsed, 0.0, 0.0, 0.0

        span = -times[0]
        normalized = [t / span for t in times]
        constant, linear, quadratic = _quadratic_least_squares(normalized, values)
        squared_error = sum((v - constant - linear * t - quadratic * t * t) ** 2
                            for t, v in zip(normalized, values))
        count = len(values)
        variance = max(self.position_noise_m ** 2, squared_error / max(1, count - 3))
        sums = [sum(t ** power for t in normalized) for power in range(5)]
        covariance_column = _solve_3x3([
            [sums[0], sums[1], sums[2], 0.0],
            [sums[1], sums[2], sums[3], 0.0],
            [sums[2], sums[3], sums[4], 1.0],
        ])
        std = 2 * sqrt(max(0.0, variance * covariance_column[2])) / span ** 2
        return linear / span, 2 * quadratic / span ** 2, sqrt(squared_error / count), std

    def _invalid_result(
        self, timestamp: float, position: Vector2D, reason: str
    ) -> KinematicsResult:
        return KinematicsResult(
            timestamp=timestamp,
            position_m=position,
            velocity_mps=Vector2D(0.0, 0.0),
            acceleration_mps2=Vector2D(0.0, 0.0),
            speed_mps=0.0,
            velocity_valid=False,
            acceleration_valid=False,
            tracking_valid=False,
            sample_count=len(self._samples),
            reason=reason,
        )


def _quadratic_least_squares(
    times: list[float], values: list[float]
) -> tuple[float, float, float]:
    """Fit ``value = a + b*t + c*t^2`` using normal equations."""

    count = float(len(times))
    sum_t = sum(times)
    sum_t2 = sum(time**2 for time in times)
    sum_t3 = sum(time**3 for time in times)
    sum_t4 = sum(time**4 for time in times)
    sum_v = sum(values)
    sum_tv = sum(time * value for time, value in zip(times, values))
    sum_t2v = sum(time**2 * value for time, value in zip(times, values))

    matrix = [
        [count, sum_t, sum_t2, sum_v],
        [sum_t, sum_t2, sum_t3, sum_tv],
        [sum_t2, sum_t3, sum_t4, sum_t2v],
    ]
    return tuple(_solve_3x3(matrix))  # type: ignore[return-value]


def _solve_3x3(matrix: list[list[float]]) -> list[float]:
    """Solve a three-variable augmented matrix with pivoted elimination."""

    for column in range(3):
        pivot = max(range(column, 3), key=lambda row: abs(matrix[row][column]))
        matrix[column], matrix[pivot] = matrix[pivot], matrix[column]

        pivot_value = matrix[column][column]
        if abs(pivot_value) < 1e-15:
            raise ValueError("sample timestamps do not support a motion estimate")

        for item in range(column, 4):
            matrix[column][item] /= pivot_value

        for row in range(3):
            if row == column:
                continue
            factor = matrix[row][column]
            for item in range(column, 4):
                matrix[row][item] -= factor * matrix[column][item]

    return [matrix[row][3] for row in range(3)]
