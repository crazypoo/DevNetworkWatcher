# PTNetworkStudio PR21–PR25 — Mac performance and Bridge acceptance

## Delivered code changes
- Diagnostic replies are decoded on the process reader's non-main callback before immutable, Sendable model values enter MainActor.
- `StudioProcessReader` splits an entire NDJSON burst and compacts its buffer once instead of removing the prefix for each line. The existing 4 MiB defensive input cap remains.
- Capture summary HTTPS totals include CONNECT tunnels, matching the HTTPS filter visible in the UI.
- XCTest covers 150 ordered NDJSON events, asynchronous decoding of 900 Inspector nodes, and CONNECT/HTTP/HTTPS summary counts.

## Measured performance evidence
None attached yet. A source-level reduction in copies or MainActor work is **not** a measured CPU, latency or FPS improvement.

## Reproducible checks
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
python3 Scripts/bench-diagnostics.py
swift package dump-package
swift test
sh Scripts/build-macos.sh
```
For paired iPhone + Mac runs, collect Instruments Time Profiler, Allocations, Animation Hitches and Energy Log under matching macOS/iOS versions for 100, 500 and 1,000 captured requests and 100, 500 and 900 Inspector nodes. Repeat each run five times; compare median, p95 and peak resident memory against last merged release.

## Functional 7/7 regression gate
Do not merge until the existing Bridge behavior is confirmed: service discovery, TLS CA+leaf pin, token pairing/consent, live events and ACK, deletion/reset, authorized reconnect, and invalid peer rejection. Also verify Console/Storage/Inspector selection and edit/undo with correct per-device cache isolation.

## Deferred
No physical-device Instruments run, changes to schema-v1 wire behavior, or full 10k+ virtualized capture list is included in this PR.
