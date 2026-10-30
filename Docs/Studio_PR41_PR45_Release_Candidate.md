# DevNetworkWatcher PR41–PR45 — performance and release-candidate gates

This is a **candidate checklist**, not a claim of completed native/macOS/iPhone acceptance.

## Landed in this branch

| Stage | Scope | Verification |
| --- | --- | --- |
| PR41 | A dedicated `release-gates` workflow requires Linux backend regression and native macOS SwiftPM/Xcode build to both succeed | Review both job results; never bypass a queued/failed Apple runner |
| PR42 | Repeatable 100/500/1000-entry v2 diagnostics matrix; two session IDs; JSON parse/redact/encode median/p95 and traced peak allocations | `python3 Scripts/bench_studio_matrix.py`; artifact on Linux and macOS; no time threshold |
| PR43 | One-pass Inspector projections; retained index/children on collapse; capped 70 perspective frames and 1200 visible rows | `StudioHierarchyProjectionTests` and a physical 1000-node Inspector |
| PR44 | Pure hierarchy projection moved out of SwiftUI workspace without new bridge, recorder, global store or protocol | Exact SwiftPM source compile; compare old selection/highlight and collapsed tree behavior |
| PR45 | Existing queued diagnostic reply is rejected if its authenticated session was revoked before reply | Backend regression + two physical simultaneously paired iPhones |

## Automated verification

```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py Scripts/bench_studio_matrix.py
python3 Scripts/bench_studio_matrix.py > studio-pr42-matrix.json
swift package dump-package
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
swift test
sh Scripts/build-macos.sh
```

Only run the SwiftPM and AppKit/SwiftUI build tests with a macOS Apple SDK. The Python
matrix measures the **Python sanitization path**, not network/proxy throughput, TLS,
SwiftUI rows, iPhone energy usage or actual Mac application FPS. Do not claim
a percentage improvement without before/after measurements on the same Mac.

## Real-device 7/7 acceptance (record each outcome)

| # | Scenario | Expected | Actual | Evidence |
| --- | --- | --- | --- | --- |
| 1 | Bonjour discover; same iPhone reconnects | Correct identity, no duplicate session | NOT RUN | — |
| 2 | CA chain trust and leaf pin mismatch | Valid peer accepted; invalid rejected | NOT RUN | — |
| 3 | Pair, revoke, reset, unauthorized/invalid token | Revoked peer cannot issue or satisfy diagnostics | NOT RUN | — |
| 4 | Capture and batch >1000 network events, ACK | No duplicates or dropped committed events | NOT RUN | — |
| 5 | Delete and session reset during refresh | Cleared records do not reappear | NOT RUN | — |
| 6 | Background/foreground + network transitions | Bounded reconnect, no stale device UI | NOT RUN | — |
| 7 | Two concurrent iPhones and wrong-session/replay | B's reply never resolves A's command | NOT RUN | — |

Also record Inspector highlight/edit/Undo, Storage redaction, Console filter/selection,
100/500/1000-row UI frame timing, 30-minute CPU/memory idle baseline and the original
macOS build. Keep the legacy v1/v2 wire schemas, TLS trust, opt-in authorization
and user-facing proxy behavior unchanged.

## Release decision

- Automated backend and native macOS statuses: **PENDING CI**.
- Physical paired iPhone–Mac validation and 30-minute profile: **NOT RUN**.
- **No release approval** until the above rows are filled with device/OS builds,
  logs and measurements and all required CI jobs succeed.
