#!/usr/bin/env python3
"""Symphony's own Mac project; shared host behavior, separate state and authority."""
from pathlib import Path
import runpy


if __name__ == "__main__":
    profile = Path(__file__).resolve()
    adapter = runpy.run_path(str(profile.parent.parent / "events-concierge/profile.py"))
    raise SystemExit(adapter["main"]("iliazlobin/symphony", profile))
