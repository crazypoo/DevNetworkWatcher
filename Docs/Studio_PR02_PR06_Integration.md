# PR02–PR06 Studio workspaces: integration and acceptance

## Setup
The existing **Network → iPhone → Start Bridge** on 9453 and original HTTPS proxy/Capture remain unchanged.

In the **PTools Debug Demo** open pairing, enable **Allow Inspector, Storage, Console and Performance**. This is separate from ordinary auto-reconnect consent. Do not enable view edits or screen previews unless required.

Use the left workspace menu and **Refresh**. The Mac sends an allowlisted command through the local Python child's stdin. The authenticated iOS Debug Agent polls `POST /v2/diagnostics/poll` over the same trusted, pinned TLS listener; the agent returns `POST /v2/diagnostics/reply`. The Python broker emits only sanitized replies to the Mac UI. It does not change schema-v1 network request capture or require iPhone Wi-Fi proxy configuration.

## Workspace scope
| PR | Workspace | Included |
|---|---|---|
| PR02 | Inspector | hierarchy snapshot, frames, device-side highlight |
| PR03 | Inspector | explicitly authorized hide/show, alpha, undo; limited perspective presentation |
| PR04 | Storage | top-level file and database inventory, UserDefaults keys/types (not values) |
| PR05 | Console / Performance | explicit diagnostic logs; process snapshots (not full os_log or Instruments) |
| PR06 | Inspector / all | sanitized JSON export, added/removed ID diff, optional on-device preview, replay/bounds tests |

## Non-goals and known limitations
- This is not a full Lookin/Woodpecker equivalent yet. A drawn perspective does not implement Metal layer manipulation.
- SQLite row querying and editing are intentionally absent; no SQL is executed from remotely supplied strings.
- No arbitrary methods, JavaScript, shell, UserDefaults mutation or file content reads.
- The first Performance snapshot is not a live tracing/profiler session; Console requires explicit SDK log events.
- Commands apply only to a single recently authenticated session. If multiple devices are active, disconnect all but the intended test iPhone.
- The command broker has a bounded queue and short reply deadline, without durable offline replay.
- Reopen and reapprove if the CA, leaf fingerprint or pairing Token was rotated.

## Required build/validation
```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
swift test
sh Scripts/build-macos.sh
```
These commands must run on macOS 14+ with Xcode for actual SwiftUI/AppKit validation. Next validate iOS Debug, both opt-in switches, read-only snapshot, edits + undo, screenshot consent, sanitized export, bridge stop/reopen, and original 7/7 Network regression. No claim is made of full physical-device acceptance until those checks are repeated.
