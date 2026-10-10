"""Streaming two-dimensional kinematics from visual tracking samples.

The computer-vision pipeline supplies a timestamped object centroid in pixels.
This module converts the centroid to metres and estimates velocity and
acceleration by fitting a quadratic to a rolling window of recent positions.
The fit smooths small tracking errors and works with irregular frame times.
"""

from __future__ import annotations

from collections import deque
from dataclasses import asdict, dataclass
from math import hypot, isfinite
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
        self._samples: Deque[_PositionSample] = deque(maxlen=window_size)

    def reset(self) -> None:
        """Discard motion history, for example after tracking is lost."""

        self._samples.clear()

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

        velocity = Vector2D(0.0, 0.0)
        acceleration = Vector2D(0.0, 0.0)
        velocity_valid = len(self._samples) >= 2
        acceleration_valid = len(self._samples) >= 3

        if velocity_valid:
            velocity = Vector2D(
                self._estimate_axis("x")[0],
                self._estimate_axis("y")[0],
            )
        if acceleration_valid:
            acceleration = Vector2D(
                self._estimate_axis("x")[1],
                self._estimate_axis("y")[1],
            )

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
        )

    def mark_tracking_lost(self, timestamp: float = 0.0) -> KinematicsResult:
        """Reset history and report that no tracked position is available."""

        if not isfinite(timestamp):
            raise ValueError("timestamp must be finite")
        self.reset()
        return self._invalid_result(
            timestamp, Vector2D(0.0, 0.0), "tracking_lost"
        )

    def _estimate_axis(self, axis: str) -> tuple[float, float]:
        """Return velocity and acceleration at the latest sample."""

        latest_time = self._samples[-1].timestamp
        times = [sample.timestamp - latest_time for sample in self._samples]
        values = [getattr(sample, axis) for sample in self._samples]

        if len(self._samples) == 2:
            elapsed = times[1] - times[0]
            return (values[1] - values[0]) / elapsed, 0.0

        constant, linear, quadratic = _quadratic_least_squares(times, values)
        del constant
        return linear, 2.0 * quadratic

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
