# DevNetworkWatcher PR46–PR50 — performance, layout diagnostics and RC

The branch extends the prior PR41–45 integration without changing the
network v1 schema, diagnostic v2 commands, authorization, TLS/pinning, proxy
behavior, capture retention cap, or the current selected request semantics.

## Delivered

| Stage | Change | Test/acceptance |
| --- | --- | --- |
| PR46 | Keep Linux/backend and native macOS `release-gates` blocking; no bypass of queued Apple CI. Companion PTools generator workflow repairs report drift. | Native `swift test` and `Scripts/build-macos.sh` required |
| PR47 | Pure Sendable `StudioFlowProjection`: same HTTP/HTTPS/failed/host/text filters and reverse ordering; run 300+ row filtering off MainActor with cancellation and revision guards | `StudioFlowProjectionTests`, 1000-flow UI capture baseline |
| PR48 | `StudioLayoutAudit` reports advisory zero/invalid-size and potential clipping only when parent explicitly clips; PTools sends optional read-only UIView flags | `StudioLayoutAuditTests`, physical Inspector screenshot comparison |
| PR49 | Shared `StudioDiagnosticSearch` covers Inspector, Console, Storage and Metrics. Filtered rows are cached until query/snapshot changes; local snapshot receive timestamp supports manual timeline comparison. | `StudioDiagnosticSearchTests`, cross-workspace authorization/selection checks |
| PR50 | Backend tests verify revoke/other-session isolation; release acceptance checklist updated. | 7/7 hardware cases and 30-minute profile are **NOT RUN** |

**Limitations:** Geometry warnings are hints, not proof of unsatisfiable
Auto Layout constraints. Views may intentionally extend beyond parents;
the audit never modifies UIKit properties or enumerates private
constraint structures. The time label is the **Mac's local receipt time**,
not a synchronized iPhone event time.

## Automated commands (macOS)

```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py Scripts/bench_studio_matrix.py
python3 Scripts/bench_studio_matrix.py
swift package dump-package
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
python3 Scripts/audit-swift-source.py
swift test
sh Scripts/build-macos.sh
```

The Python 100/500/1000 matrix measures only schema-v2
decode/redact/encode and cannot be used as a claim about Mac SwiftUI FPS
or an actual physical network path. For PR47, capture a same-Mac
before/after Instruments CPU/MainActor/FPS profile, with 100/500/1000
flows and active search/host scope changes. For PR48, manually inspect
folded/unfolded, hidden and clipped views, including Inspector select/
highlight/edit/undo with explicit authorization.

## Physical acceptance record

| # | Case | Expected | Actual / evidence |
| --- | --- | --- | --- |
| 1 | Bonjour first-pair and identity reconnect | Correct stable peer and no unexpected auto-pairing | NOT RUN |
| 2 | TLS CA/leaf pin invalid peer | Mismatch rejected; trusted peer accepted | NOT RUN |
| 3 | Explicit consent, revoke while command pending | No stale reply accepted; other phone unaffected | NOT RUN |
| 4 | 100/500/1000 network flows, ACK/batching, filter churn | No stale projections or wrong selected detail | NOT RUN |
| 5 | Delete/reset during outstanding filtered list tasks | Cleared rows never reappear | NOT RUN |
| 6 | App background/foreground, network loss, two scenes | Bounded reconnect; no ghost window | NOT RUN |
| 7 | Two phones, wrong-session and replayed diagnostics reply | Session-scoped and one-time ACK | NOT RUN |

Also record 30-minute Mac Studio idle CPU/memory and memory under
heavy Inspector views, and PTools Simulator/Swift 6/CocoaPods gates.
This is a **release candidate checklist**, not an approval.
