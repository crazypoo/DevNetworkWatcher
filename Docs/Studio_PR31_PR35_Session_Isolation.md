# PTNetworkStudio PR31–PR35: multi-device isolation and iOS Inspector acceptance

## Implemented

- PR32/35: pending diagnostic command IDs now track the exact authenticated `sessionID` at send time; v2 replies from a different iPhone cannot satisfy an outstanding command.
- An invalid reply leaves the legitimate pending command intact (until its original timeout), preventing unsolicited replies from consuming it.
- Empty edit/highlight/unchanged responses can carry a previous snapshot **only from the same iPhone session**. When a different authenticated peer is observed, cached Inspector/Storage/Console result and pending work are invalidated before use.
- The correlation rules live in a pure `StudioDiagnosticCorrelation` helper, with XCTest for cross-device rejection and safe same-session cache preservation.
- This PR intentionally does not alter schema-v1 Network capture, Bonjour, pairing token, TLS or the on-device permission prompt.

## Verification

Run the existing macOS SwiftPM suite and Python TLS/schema tests:
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
swift test
sh Scripts/build-macos.sh
```

Also simulate two authorized iPhones: peer A sends a pending Inspector command; peer B authenticates and replies (or reuses the same domain). B's reply must never be shown as A's result, the cached preview must be invalidated, and edits must continue to require the correct explicit authorization. Verify one connected iPhone still supports highlight/Undo/Storage metadata and all legacy Network Bridge 7/7 scenarios.

This does not claim that Apple macOS CI or paired physical iPhone tests have passed. Do not merge on a Linux-only result.
