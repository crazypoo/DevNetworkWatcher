#!/usr/bin/env python3
"""Reproducible backend-only diagnostic sanitization baseline.

Does not measure macOS SwiftUI, AppKit, TLS or the iPhone's actual FPS.
Run: python3 Scripts/bench-diagnostics.py
"""
import json
from pathlib import Path
import statistics
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources" / "PTNetworkStudio" / "Backend"))
from studio_diagnostics import safe_reply


def measure(count, repeats=7):
    template = {
        "schemaVersion": 2, "id": str(uuid.uuid4()),
        "sessionID": str(uuid.uuid4()), "success": True,
        "entries": [
            {"id": f"v-{i}", "parentID": f"v-{i//3}" if i else None,
             "kind": "UIView", "name": "UIView",
             "detail": "alpha=1.0",
             "frame": {"x": 0, "y": i, "width": 400, "height": 44},
             "attributes": {"alpha": "1.0", "hidden": "false"}}
            for i in range(count)
        ]
    }
    data = json.dumps(template)
    samples = []
    for _ in range(repeats):
        started = time.perf_counter()
        result = safe_reply(json.loads(data))
        json.dumps(result, separators=(",", ":"))
        samples.append((time.perf_counter() - started) * 1000)
    ordered = sorted(samples)
    return {
        "entries": count,
        "jsonBytes": len(data),
        "medianMS": round(statistics.median(samples), 3),
        "p95MS": round(ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))], 3)
    }


if __name__ == "__main__":
    print(json.dumps({"workload": "python diagnostic decode/redact/encode",
                      "notAUIBenchmark": True,
                      "results": [measure(n) for n in (100, 500, 900, 1200)]},
                     indent=2))
