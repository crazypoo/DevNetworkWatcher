"""Real TLS + PToolsDebugStudioBridge schema-v1 protocol tests."""
import hashlib
import http.client
import json
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

BACKEND = Path(__file__).resolve().parents[2] / "Sources" / "PTNetworkStudio" / "Backend"
sys.path.insert(0, str(BACKEND))
from bridge_server import CollectorState, prepare_identity


def sample_event(kind, sequence, session, request_id=None):
    event = {
        "schemaVersion": 1, "sessionID": session, "deviceID": str(uuid.uuid4()),
        "eventID": str(uuid.uuid4()), "requestID": request_id,
        "sequence": sequence, "monotonicTime": 17.5,
        "wallTime": "2026-10-25T04:00:00Z", "source": "urlProtocol",
        "kind": kind, "payload": {}
    }
    if kind in ("recordUpsert", "recordFinalize"):
        event["requestID"] = event["requestID"] or str(uuid.uuid4())
        event["payload"]["record"] = {
            "method": "GET", "url": "https://example.com/private/path?token=raw-secret",
            "requestHeaders": {"Authorization": "raw-secret", "X-Debug": "not-to-send"},
            "responseHeaders": {"Set-Cookie": "raw-secret"},
            "requestBody": {"totalBytes": 26, "preview": '{"password":"raw-secret"}',
                            "truncated": False, "redacted": True},
            "responseBody": None, "status": 200, "durationSeconds": 0.15,
            "startedAt": "2026-10-25T04:00:00Z"
        }
    return event


def headers(token, nonce=None, timestamp=None):
    return {
        "Authorization": "Bearer " + token,
        "X-PTStudio-Nonce": nonce or str(uuid.uuid4()),
        "X-PTStudio-Sent-At": str(timestamp if timestamp is not None else int(time.time())),
        "Content-Type": "application/json",
    }


class BridgeProtocolTests(unittest.TestCase):
    def test_exposed_legacy_token_is_rotated_once(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            legacy = root / "bridge-token"
            legacy.write_text("previously-published-token")
            _, _, token, fingerprint, _ = prepare_identity(root)
            self.assertNotEqual(token, "previously-published-token")
            self.assertFalse(legacy.exists())
            self.assertEqual((root / "bridge-token-v2").read_text().strip(), token)
            _, _, subsequent, subsequent_pin, _ = prepare_identity(root)
            self.assertEqual(subsequent, token)
            self.assertEqual(subsequent_pin, fingerprint)

    def test_batch_ack_idempotent_retry_nonce_and_privacy(self):
        state = CollectorState("a" * 32)
        session = str(uuid.uuid4())
        events = [sample_event("hello", 1, session),
                  sample_event("capabilities", 2, session),
                  sample_event("recordFinalize", 3, session)]
        data = json.dumps({"schemaVersion": 1, "events": events}).encode()
        status, ack, delivered = state.receive(headers("a" * 32), data)
        self.assertEqual(status, 200)
        self.assertEqual(ack["acceptedSequence"], 3)
        self.assertEqual(ack["sessionID"], session)
        self.assertEqual(len(delivered), 2)
        self.assertEqual(delivered[0], {"type": "bridgePeer", "sessionID": session})
        self.assertNotIn("raw-secret", json.dumps(delivered))
        self.assertNotIn("/private/path", json.dumps(delivered))
        self.assertEqual(delivered[1]["entry"]["source"], "PTools Live")

        # Retry uses a new nonce but exactly the SAME event IDs; no second emission.
        status, ack, delivered = state.receive(headers("a" * 32), data)
        self.assertEqual((status, ack["acceptedSequence"], delivered), (200, 3, []))
        nonce = str(uuid.uuid4())
        ping = json.dumps({"schemaVersion": 1,
                           "events": [sample_event("heartbeat", 4, session)]}).encode()
        heartbeat_status, _, heartbeat_messages = state.receive(headers("a" * 32, nonce), ping)
        self.assertEqual(heartbeat_status, 200)
        self.assertEqual(heartbeat_messages, [{"type": "bridgePeer", "sessionID": session}])
        self.assertEqual(state.receive(headers("a" * 32, nonce), ping)[0], 409)
        self.assertEqual(state.receive(headers("incorrect"), data)[0], 401)
        self.assertEqual(state.receive(headers("a" * 32, timestamp=int(time.time()) - 500), data)[0], 401)
        self.assertEqual(state.receive(headers("a" * 32), b'{"schemaVersion":2,"events":[]}')[0], 400)

    def test_deletion_reset_and_invalid_unredacted_payload(self):
        state = CollectorState("b" * 32)
        session, rid = str(uuid.uuid4()), str(uuid.uuid4())
        items = [sample_event("recordDelete", 1, session, rid),
                 sample_event("sessionReset", 2, session)]
        status, _, messages = state.receive(
            headers("b" * 32), json.dumps({"schemaVersion": 1, "events": items}).encode())
        self.assertEqual(status, 200)
        self.assertEqual(messages[0]["requestID"], rid)
        self.assertEqual(messages[1]["type"], "bridgeReset")
        dangerous = sample_event("recordUpsert", 3, session)
        dangerous["payload"]["record"]["requestBody"]["redacted"] = False
        status, _, _ = state.receive(headers("b" * 32),
                                      json.dumps({"schemaVersion": 1, "events": [dangerous]}).encode())
        self.assertEqual(status, 400)

    def test_trusted_ca_leaf_fingerprint_and_real_https_ack(self):
        with tempfile.TemporaryDirectory() as folder:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]
            proc = subprocess.Popen(
                [sys.executable, "-u", str(BACKEND / "bridge_server.py"), folder, str(port), "127.0.0.1"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                line = proc.stdout.readline()
                self.assertTrue(line.startswith("PTSTUDIO:"), (line, proc.poll()))
                ready = json.loads(line[len("PTSTUDIO:"):])
                self.assertEqual(ready["port"], port)
                root_pem = str(Path(ready["caCertificate"]).with_suffix(".pem"))
                # Diagnose certificate-chain incompatibilities on macOS Python,
                # rather than treating a TLS handshake failure as an ACK bug.
                verification = subprocess.run(
                    ["openssl", "verify", "-CAfile", root_pem,
                     str(Path(folder) / "bridge-cert.pem")],
                    capture_output=True, text=True)
                self.assertEqual(verification.returncode, 0,
                                 verification.stdout + verification.stderr)
                trusted = ssl.create_default_context(cafile=root_pem)
                connection = http.client.HTTPSConnection("127.0.0.1", port, context=trusted, timeout=5)
                connection.connect()
                pin = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
                self.assertEqual(pin, ready["fingerprint"])
                session = str(uuid.uuid4())
                batch = json.dumps({"schemaVersion": 1,
                                    "events": [sample_event("hello", 1, session),
                                               sample_event("recordFinalize", 2, session)]}).encode()
                connection.request("POST", "/v1/events", body=batch, headers=headers("incorrect"))
                self.assertEqual(connection.getresponse().status, 401)
                connection.request("POST", "/v1/events", body=batch, headers=headers(ready["token"]))
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(json.loads(response.read())["acceptedSequence"], 2)
                peer_notice = proc.stdout.readline()
                self.assertEqual(json.loads(peer_notice[len("PTSTUDIO:"):]),
                                 {"type": "bridgePeer", "sessionID": session})
                emitted = proc.stdout.readline()
                self.assertTrue(emitted.startswith("PTSTUDIO:"), emitted)
                self.assertNotIn("raw-secret", emitted)
                self.assertEqual(json.loads(emitted[len("PTSTUDIO:"):])["type"], "entry")
                connection.close()
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                proc.stdout.close()
                proc.stderr.close()


if __name__ == "__main__":
    unittest.main()
