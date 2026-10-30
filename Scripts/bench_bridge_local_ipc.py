#!/usr/bin/env python3
"""PR58 synthetic IPC event-count baseline; NOT an AppKit FPS benchmark."""
import json
import statistics
import sys
import time
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[1] / "Sources/PTNetworkStudio/Backend"
sys.path.insert(0, str(BACKEND))
from bridge_server import local_ui_messages


def benchmark(count: int):
    # The HTTP v1 collector accepts at most 24 events per request. Model
    # separate requests; grouping never crosses a request boundary.
    events = [{"type": "entry", "entry": {"id": str(i)}} for i in range(count)]
    def project():
        return [
            item
            for start in range(0, len(events), 24)
            for item in local_ui_messages(events[start:start + 24])
        ]
    samples = []
    grouped = []
    for _ in range(5):
        start = time.perf_counter_ns()
        grouped = project()
        samples.append((time.perf_counter_ns() - start) / 1_000_000)
    median = statistics.median(samples)
    sorted_samples = sorted(samples)
    assert sum(len(item.get("entries", [item.get("entry")])) for item in grouped) == count
    assert len(grouped) == (count + 23) // 24
    return {
        "entryCount": count, "legacyStdoutLines": count,
        "batchedStdoutLines": len(grouped),
        "medianProjectionMs": round(median, 4),
        "p95ProjectionMs": round(sorted_samples[-1], 4),
    }


if __name__ == "__main__":
    print(json.dumps({
        "kind": "local-ipc-synthetic-only",
        "notMeasurements": ["AppKit frame rate", "actual CPU", "network RTT"],
        "measurements": [benchmark(n) for n in [100, 500, 1000]]
    }, indent=2))
