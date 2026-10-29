# Studio PR07–PR15 performance & cross-device integration

Implementation baseline: main after PR02–PR06 merge. This is a working branch, not an acceptance certificate.

## Applied changes
- PR07: `OSSignposter` capture snapshot publication interval.
- PR08: `CaptureStore` UUID-indexed authoritative state, 75ms UI coalescing, bounded 1,000 requests, precomputed summary/domain counts, off-main decoding of proxy/Bridge records, 180ms search debounce.
- PR09: Inspector snapshot keyed index, expandable cached hierarchy, cached decoded preview instead of per-body decoding.
- PR10/11: Authenticated, nonce-protected long polling up to eight seconds outside the schema-v1 collector lock. Condvar wakes immediately when the Mac queues a command. Fingerprint-based unchanged Inspector response retains the existing tree.
- PR11: Defense-in-depth log/title/attribute redaction in collector replies, with original TLS pin and pairing behavior unchanged.
- PR15: macOS capture regression XCTest and Python authentication/long-poll/redaction regression tests.

## Verification on macOS
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
swift test
sh Scripts/build-macos.sh
```

### Repeatable performance comparison
Use Instruments Time Profiler + Points of Interest. Run in the same Mac, same build and source of identical events:
1. Empty capture, Bridge connected, Diagnostic off. Record CPU/idle wakeups.
2. Inject 100, 500, then 1,000 network records; measure requests/s, 95th-percentile UI selection latency, memory after a clear, and FPS during scrolling.
3. Inspector: 100, 500, and 900 UIView nodes; measure Refresh, hierarchy expand/collapse, selection, 2D/3D toggle, and preview decode.
4. Leave connected for 30 minutes; verify there is no unbounded memory or steady idle CPU growth.
5. Confirm Network v1 7/7 workflow, manual Capture proxy, Bonjour, CA trust, TLS fingerprint and Token, multi-device refusal, edit/undo, JSON export, background/foreground reconnect.

No asserted speedup percentage is valid until these runs are captured.

## Compatibility boundaries
- `CaptureStore.entries` and existing network public UI remain available. All mutations now update keyed source of truth and publish bounded snapshots.
- `/v1/events` ACK and schema remain unchanged; diagnostics long poll only affects `/v2/diagnostics/poll`.
- View editing requires independent iPhone consent; preview is independently disabled by default.
- The Studio does not execute user-supplied SQL, shell commands or arbitrary code.
- AppKit/SwiftUI and the Python child must be tested on real macOS. No local macOS build result is claimed by these source changes.

## Remaining P1/P2 enhancements
- More advanced request virtualization and incremental query indexing beyond the bounded 1,000-record viewport.
- Cross-device consistent fine-grained view deltas, persistent session export/import and full 3D layer navigation.
- CPU/GPU trace correlation and per-subscriber stream lifetimes.
- Add a measured median/p95 performance dashboard after initial Instruments evidence.
