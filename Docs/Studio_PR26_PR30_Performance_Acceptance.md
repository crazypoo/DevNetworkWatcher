# Studio PR26–PR30 — CI, responsiveness and acceptance

## Applied
- Adds a Linux Python backend job independent of queued macOS runners for the existing schema v1/v2 and TLS regression tests; diagnostic baseline output is retained as an artifact.
- The Storage/Console non-hierarchy row projection is computed when the diagnostic snapshot changes, not each SwiftUI body redraw.
- iPhone integration still transports the same authenticated schema-v1/v2 data; no changes to Bonjour, pinning, tokens, consent or edit authorization.

## Gates
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
python3 Scripts/bench-diagnostics.py
swift test
sh Scripts/build-macos.sh
```
Use Instruments on the same Mac/iPhone and build before/after: 100/500/1000 flows, 100/500/900 Inspector nodes, 30-minute idle connected run, and repeated sessions. Capture median/p95 main thread duration, memory/allocations and CPU. No percentage improvement is inferred from a source diff.

The release gate requires the 7/7 physical Bridge acceptance matrix, plus Console, Storage, Inspector edit/undo and per-session isolation. Pending runner jobs are not passes.
