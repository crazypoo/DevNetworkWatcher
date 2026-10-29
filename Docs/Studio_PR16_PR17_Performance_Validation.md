# PTNetworkStudio PR16–PR17 Performance Validation

This is a reproducible test plan for the changes in PR #15. It does not claim hardware benchmark results.

## Source-level improvements
- `CaptureStore` computes its host/statistics snapshot before one `@Published entries` notification; it no longer publishes a second independent stats notification per batch.
- Inspector skips hierarchy rebuilding on unrelated diagnostic revisions, unchanged fingerprints, and edit acknowledgements.
- Screen previews use an NSCache with a 12-entry/12 MiB budget; cache keys include the authenticated session, node and image data fingerprint.
- Changing diagnostic domains or connected sessions resets the selected view, hierarchy, diff state and preview cache.

## Automated tests
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
python3 Scripts/bench-diagnostics.py
swift package dump-package
swift test
sh Scripts/build-macos.sh
```
The backend test covers authenticated v2 long-poll operation without holding the schema-v1 collector lock. The Swift tests verify capture record cap, session import behavior, and one coherent UI-publish notification for a 500-request burst.

## Real Mac acceptance (not automated by this PR)
Perform five repeat runs per scenario using matching devices, OS, build configuration and sample data:
1. Baseline idle: Bridge running, zero capture, no diagnostics enabled. Record CPU, idle wakeups and resident memory.
2. Capture workload: 100/500/1,000 requests, inspect first/middle/last, filter hosts, search, select, scroll and clear. Record median/p95 response time, CPU and peak memory.
3. Inspector workload: 100/500/900 nodes, Refresh, expand/collapse, select, preview on/off, 2D/3D. Record frame stalls and main thread stack traces.
4. 30-minute authorized connection, iPhone background/foreground, network interruption and reconnection.
5. Full preexisting Network Bridge 7/7: Bonjour discover, CA/pin/token authorization, live request ACK, request deletion, session reset, reconnect and invalid peer refusal.

Do not assert a performance percentage or mark the draft PR merge-ready until native CI and real-device evidence are attached. The project does not need to change its existing UIKit screenshots or secure Bridge protocol to evaluate this work.
