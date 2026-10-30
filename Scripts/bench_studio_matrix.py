#!/usr/bin/env python3
"""PR42 reproducible bounded diagnostics baseline for CI and developers.

This measures Python schema-v2 JSON decode, sanitization and re-encoding only.
It does NOT measure SwiftUI/AppKit FPS, TLS, the bridge, or a real iPhone.
Each row has two independent, authenticated-shaped session identifiers;
the sanitization result must preserve its exact session identity.
No latency threshold is enforced across different CI hosts.
"""
import json
from pathlib import Path
import statistics
import sys
import time
import tracemalloc
import uuid

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Sources" / "PTNetworkStudio" / "Backend"))
from studio_diagnostics import MAX_ENTRIES, safe_reply


def make_reply(count, session_id):
    if count < 0 or count > MAX_ENTRIES:
        raise ValueError("outside production diagnostics entry cap")
    return {
        "schemaVersion": 2,
        "id": str(uuid.uuid4()),
        "sessionID": str(session_id),
        "success": True,
        "entries": [
            {
                "id": f"view-{i}",
                "parentID": f"view-{(i - 1) // 3}" if i else None,
                "kind": "UIView",
                "name": "UIView",
                "detail": "alpha=1.0",
                "frame": {"x": 0, "y": i, "width": 400, "height": 44},
                "attributes": {"alpha": "1.0", "hidden": "false"},
            }
            for i in range(count)
        ],
    }


def measure(count, repeats=7):
    if repeats < 1:
        raise ValueError("repeats must be positive")
    sessions = [uuid.uuid4(), uuid.uuid4()]
    payloads = [json.dumps(make_reply(count, sid), separators=(",", ":"))
                for sid in sessions]
    samples = []
    peaks = []
    for sample in range(repeats):
        payload = payloads[sample % len(payloads)]
        expected_session = str(sessions[sample % len(sessions)])
        tracemalloc.start()
        started = time.perf_counter()
        decoded = json.loads(payload)
        clean = safe_reply(decoded)
        encoded = json.dumps(clean, separators=(",", ":"))
        elapsed_ms = (time.perf_counter() - started) * 1000
        _, peak_bytes = tracemalloc.get_traced_memory()
        tracemalloc.stop()
        if clean["sessionID"] != expected_session or len(clean["entries"]) != count:
            raise AssertionError("wrong session or unexpected entry count")
        if json.loads(encoded)["sessionID"] != expected_session:
            raise AssertionError("session identity changed during encoding")
        samples.append(elapsed_ms)
        peaks.append(peak_bytes)
    ordered = sorted(samples)
    return {
        "entries": count,
        "devices": len(sessions),
        "jsonBytesPerDevice": [len(s) for s in payloads],
        "repeats": repeats,
        "medianMS": round(statistics.median(samples), 3),
        "p95MS": round(ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))], 3),
        "peakTracedKiB": round(max(peaks) / 1024, 1),
    }


def main():
    print(json.dumps({
        "workload": "Python v2 diagnostics: JSON decode + redact + encode",
        "notAMacOSUIBenchmark": True,
        "notAPhysicalDeviceTest": True,
        "performanceThreshold": None,
        "results": [measure(n) for n in (100, 500, 1000)],
    }, indent=2))


if __name__ == "__main__":
    main()
