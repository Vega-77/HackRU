"""Multi-object tracker that gives each detection a stable ID across frames.

Matching is greedy nearest-neighbour on centroids, restricted to the same label,
against each track's *predicted* position (last position + last per-frame motion).
The prediction keeps IDs stable for fast objects such as a ball rolling off a ramp.
A track survives `max_missed` frames without a match (brief occlusion, motion blur)
before it is dropped.
"""

from __future__ import annotations

import math
from collections import deque
from dataclasses import dataclass, field

from cv_engine.detect import Detection


@dataclass
class Track:
    id: int
    label: str
    centroid: tuple[float, float]
    bbox: tuple[int, int, int, int]
    area: float
    score: float
    source: str
    velocity: tuple[float, float] = (0.0, 0.0)  # pixels per frame, used only for prediction
    hits: int = 1  # frames this track was matched
    missed: int = 0  # consecutive frames without a match
    history: deque = field(default_factory=lambda: deque(maxlen=64))  # recent centroids, for trails

    def predicted(self) -> tuple[float, float]:
        k = self.missed + 1
        return self.centroid[0] + self.velocity[0] * k, self.centroid[1] + self.velocity[1] * k


class CentroidTracker:
    def __init__(self, max_distance: float = 80.0, max_missed: int = 10, min_hits: int = 2) -> None:
        """
        max_distance: largest jump (working-frame px) from a track's predicted position
                      that still counts as the same object.
        max_missed:   frames a track may go unmatched before it is removed.
        min_hits:     frames a new track must be seen before it is reported, which
                      filters out one-frame noise blobs.
        """
        self.max_distance = max_distance
        self.max_missed = max_missed
        self.min_hits = min_hits
        self.tracks: dict[int, Track] = {}
        self._next_id = 1

    def forget_manual(self) -> None:
        """Drop the selected object's track, when the user selects something else."""
        self.tracks = {i: t for i, t in self.tracks.items() if t.source != "manual"}

    def update(self, detections: list[Detection]) -> list[Track]:
        """Feed one frame's detections; returns the confirmed tracks seen this frame."""
        pairs = []
        for ti, t in self.tracks.items():
            px, py = t.predicted()
            for di, d in enumerate(detections):
                if d.label != t.label:
                    continue
                dist = math.hypot(d.centroid[0] - px, d.centroid[1] - py)
                # The selected object keeps its ID wherever ManualTracker finds it: that
                # tracker already checked it is the same object, and a new ID would
                # restart its velocity history.
                if dist <= self.max_distance or (d.source == "manual" and t.source == "manual"):
                    pairs.append((dist, ti, di))
        pairs.sort()

        matched_tracks: set[int] = set()
        matched_dets: set[int] = set()
        for _, ti, di in pairs:
            if ti in matched_tracks or di in matched_dets:
                continue
            matched_tracks.add(ti)
            matched_dets.add(di)
            self._apply(self.tracks[ti], detections[di])

        for ti in list(self.tracks):
            if ti not in matched_tracks:
                t = self.tracks[ti]
                t.missed += 1
                if t.missed > self.max_missed:
                    del self.tracks[ti]

        for di, d in enumerate(detections):
            if di not in matched_dets:
                t = Track(self._next_id, d.label, d.centroid, d.bbox, d.area, d.score, d.source)
                t.history.append(d.centroid)
                self.tracks[t.id] = t
                self._next_id += 1

        return [t for t in self.tracks.values() if t.missed == 0 and (t.hits >= self.min_hits or t.source == "manual")]

    @staticmethod
    def _apply(t: Track, d: Detection) -> None:
        steps = t.missed + 1
        t.velocity = ((d.centroid[0] - t.centroid[0]) / steps, (d.centroid[1] - t.centroid[1]) / steps)
        t.centroid, t.bbox, t.area, t.score, t.source = d.centroid, d.bbox, d.area, d.score, d.source
        t.hits += 1
        t.missed = 0
        t.history.append(d.centroid)
