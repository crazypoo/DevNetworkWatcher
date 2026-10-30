# DevNetworkWatcher + PTools 6.0 — PR56–PR60 release candidate

**Decision: NOT APPROVED** until every automated and physical gate has
an actual passing result. This document does not authorize a 6.0 tag.

## Implemented changes

| Phase | Patch | Automatic evidence |
| --- | --- | --- |
| PR56 | Companion PTools fixes report comparator operator precedence and reports concrete drift paths; canonical report regeneration stays generator-owned. | Ruby regression tests and mandatory `CURRENT_REPORT_REPRODUCIBLE` job; no bypass of Quality/Governance. |
| PR57 | Studio native CI now captures `sw_vers`, `uname -m`, actual Xcode, macOS SDK and Swift toolchain. PTools adds iOS Simulator build matrix covering core, UI, Studio Bridge and legacy Debug umbrella. | `swift test`, `sh Scripts/build-macos.sh`, Apple SDK target gate, strict-concurrency and Pods separately. |
| PR58 | Keep `/v1/events` and its ACK exactly as-is. Within **private Mac collector stdout only**, group adjacent upserts (max 24 per valid received batch) into `entryBatch` while retaining legacy `entry` for singles. Swift decodes before MainActor and applies each group in one UI task. | Python unit tests for delete/reset barriers, peer ordering, batch bounds. `bench_bridge_local_ipc.py` writes an explicitly synthetic 100/500/1000 event-count comparison. |
| PR59 | Local stdout messages are serialized per HTTP request; each v2 diagnostics reply now requires matching id/session **and** pending-command age less than 50s and recent session heartbeat under 100s. No new device identities or auth bypass. | Python local order tests, existing TLS/nonce/replay tests, Swift `StudioDiagnosticCorrelationTests` for expiry/wrong ID. |
| PR60 | Fail-closed machine-readable evidence template from PR55 remains in use and 7/7 two-phone plus Mac profiling acceptance remains mandatory. | `Scripts/verify-pr55-release-evidence.py` without `--validate-template` rejects any missing, failing or untested gate. |

## What remains deliberately NOT RUN

1. Full native macOS SwiftPM build/test and actual two physical iPhones
   (Bonjour, CA trust, pinning, re-auth, concurrent sessions, revocation,
   pending command, wrong-session reply, replay and ACK).
2. 30-minute Mac Studio idle/traffic/Inspector Instruments memory,
   main-thread, CPU and actual frame-rate recordings, before vs after.
3. Real 100/500/1000 captures, high-frequency updates while switching
   scope/query, deletion/reset and fresh repeated reconnects.
4. iOS Swift 6 strict build for all affected targets, CocoaPods and
   SwiftPM source parity, iOS 26/27 navigation and Duo Scene regression.
5. Reviewer-approved release evidence with original build SHA, dated
   CI run URLs, two device model/OS logs and Instruments trace links.

## Manual steps / commands

On Linux and macOS:
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 Scripts/verify-pr50-boundaries.py
python3 Scripts/bench_bridge_local_ipc.py
python3 Scripts/verify-pr55-release-evidence.py Docs/Studio_PR55_Release_Evidence.template.json --validate-template
```

On macOS (real Apple SDK):
```sh
swift package dump-package
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
swift test
sh Scripts/build-macos.sh
```

In PTools:
```sh
ruby Tests/Governance/test_compare_current_reports.rb
bash Scripts/Governance/generate_all_current_reports.sh --check
# On macOS/Xcode:
bash Scripts/CI/verify_studio_native_targets.sh
```

The schema validator's `--validate-template` flag validates *format only*;
it is not evidence of successful checks. Release approval requires a completed
copy of `Docs/Studio_PR55_Release_Evidence.template.json` and:
```sh
python3 Scripts/verify-pr55-release-evidence.py path/to/actual-verified-evidence.json
```
The verifier checks presence and status, not authenticity: reviewers must
inspect original CI URLs, signed app builds and performance captures.

## Explicit compatibility boundary

- No changes to externally transmitted PTools Network schema v1 and ACK.
- No changes to authorized Diagnostics schema v2 or `PTStudioDiagnosticEntry`.
- Bridge local stdout `entryBatch` is internal-only to Python -> Mac Swift.
- No extra TCP endpoint, credential storage, swizzle, session auto-pairing or
  implicit edit permission.
- Keep both PRs draft until actual build results and device evidence exist.
