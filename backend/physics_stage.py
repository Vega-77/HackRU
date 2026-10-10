"""Load the shared physics package when the backend runs from its directory."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from physics_engine.session import PhysicsSession  # noqa: E402

__all__ = ["PhysicsSession"]
