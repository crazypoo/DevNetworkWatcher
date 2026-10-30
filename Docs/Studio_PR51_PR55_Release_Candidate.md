# DevNetworkWatcher PR51–PR55 — native performance and release candidate

Corresponding PTools branch has its own Debug Studio ownership, privacy and
constraint count changes. This branch never changes the Network v1 capture
contract, the Diagnostics v2 command/reply shape, TLS pinning, or pairing.

## Implemented

- **PR51:** Show elapsed *projection only* time at the bottom of Network.
  The existing 75 ms publish coalescing, 1,000-record bound and worker
  cancellation remain. A native Swift XCTest prints median/p95 for
  100/500/1,000 flow projections with exact semantic count checks, and
  checks a 1,000-row Inspector index. It is not an end-to-end FPS benchmark.
- **PR52:** In authorized snapshots only, show possible mixed layout modes
  when own active constraints coexist with autoresizing masks. Hidden,
  intentionally zero-sized views are excluded from size warnings.
  PTools sends only numeric constraint counts in existing v2 attributes.
  This is **advisory**: constraints on ancestor views are not included.
- **PR53:** The Diagnostic search query stays in memory across workspace
  switches, never UserDefaults. Shortcuts show only sanitized snapshots
  whose ephemeral session UUID equals the current snapshot session. This
  does not correlate by token, device name, IP or persistent device ID.
  The Network shortcut exposes the aggregate capture table **across all sources**:
  schema v1 flows do not carry v2 session IDs, so they are deliberately not
  labeled as belonging to the selected diagnostic session.
- **PR54:** Existing `Scripts/verify-pr50-boundaries.py` checks that there is
  one session-correlation owner and that the same-session condition
  remains. No new recorder or TCP listener was added.
- **PR55:** `Docs/Studio_PR55_Release_Evidence.template.json` names all
  required CI and physical gates. CI checks schema; running the verifier
  without `--validate-template` **fails until every gate has a PASS and
  evidence**.

## Reproducible local checks

```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 Scripts/verify-pr50-boundaries.py
python3 Scripts/verify-pr55-release-evidence.py \
  Docs/Studio_PR55_Release_Evidence.template.json --validate-template
swift package dump-package >/dev/null
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
swift test
sh Scripts/build-macos.sh
```

`swift test` includes `StudioProjectionBaselineTests`,
`StudioDiagnosticSessionCorrelationTests`, and updated layout audit
regression tests. Backend tests reject an unverified/failed release evidence
record. GitHub Actions must finish the Linux and macOS jobs successfully;
queued/cancelled/approval-required is not a pass.

## Hardware acceptance — NOT RUN

Collect the following *on the actual Mac and two iPhones* before release:

1. 7/7 earlier two-iPhone Bonjour, TLS, consent, revoke, reconnect, pending
   ACK, reset and wrong-session/replay matrix
2. Xcode Swift 6 strict concurrency and CocoaPods/SwiftPM iOS target builds
3. Network 100/500/1,000 real flows: filtering, selection, collapse, pause,
   import/export, host changes and clear during a detached filter
4. Inspector 100/500/900 actual UIKit hierarchy nodes, screenshots,
   hidden placeholder filtering, same-session correlation and edit/undo
5. 30-minute idle plus load profile: Mac Studio CPU/main actor allocations,
   memory footprint, scrolling responsiveness, OS version and hardware
6. iOS 26/27 and Duo + Scene boundaries, no ghost windows, correct preview
7. Privacy/export regression and positive/negative pairing certificate tests

The `PR55_RELEASE_EVIDENCE` verifier checks the record's status and
presence of evidence, not authenticity. Review the linked CI logs and
Instruments traces manually. Do not declare 6.0 ready before signed-off
native hardware evidence.
