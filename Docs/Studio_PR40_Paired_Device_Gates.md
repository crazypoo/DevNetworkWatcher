# PTNetworkStudio PR40 paired-device release verification

This change adds a deterministic backend regression exercising two concurrently
authenticated iPhones. A reply from device B bearing device A's command ID
must not acknowledge or consume device A's pending request. The correct reply
must continue to succeed, and replay must fail. No Bridge v1/v2 wire schema,
TLS, Bonjour, token or on-device authorization logic is changed.

## Automated validation

```sh
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
swift test
```

Linux tests cover authorization, reply correlation, replay, redaction, and
nonblocking long polling. Native SwiftPM/Xcode and physical devices remain
independent required gates.

## Manual 7/7 acceptance (same physical Mac and iPhone)

1. Bonjour discovery and consistent identity during reconnection
2. TLS verification, CA trust, and pinned leaf certificate
3. Explicit opt-in pairing, revocation, and invalid token refusal
4. Request event capture, batching, ACK and UI refresh
5. Deletion and session reset without resurrecting stale records
6. Background/foreground and Wi-Fi/BLE/network reconnect
7. Invalid peer, wrong-session v2 reply, replay and stale snapshot rejection

Also test two simultaneously paired devices, Inspector hierarchy/highlight,
edit/Undo, Storage metadata redaction, Console subscriptions and 30-minute
idle memory/CPU. Do not claim acceptance without run logs and device data.
