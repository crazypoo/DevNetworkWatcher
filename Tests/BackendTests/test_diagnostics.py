"""Authenticated diagnostics are additive; v1 ACK and privacy are still enforced."""
import json
from pathlib import Path
import sys
import time
import unittest
import uuid

BACKEND = Path(__file__).resolve().parents[2] / "Sources" / "PTNetworkStudio" / "Backend"
sys.path.insert(0, str(BACKEND))
from bridge_server import CollectorState


def headers(token="x" * 32, nonce=None, timestamp=None):
    return {
        "Authorization": "Bearer " + token,
        "X-PTStudio-Nonce": nonce or str(uuid.uuid4()),
        "X-PTStudio-Sent-At": str(int(time.time()) if timestamp is None else timestamp),
    }


class StudioDiagnosticsTests(unittest.TestCase):
    def setUp(self):
        self.state = CollectorState("x" * 32)
        self.session = str(uuid.uuid4())
        self.request = json.dumps({"sessionID": self.session}).encode()

    def test_pairing_nonce_and_command_reply_cycle(self):
        self.assertEqual(self.state.poll_diagnostic(headers("wrong"), self.request)[0], 401)
        status, body, peer = self.state.poll_diagnostic(headers(), self.request)
        self.assertEqual(status, 200)
        self.assertEqual(body, {"commands": []})
        self.assertEqual(peer[0]["type"], "diagnosticPeer")
        command = {
            "schemaVersion": 2, "id": str(uuid.uuid4()), "sessionID": self.session,
            "domain": "inspector", "operation": "snapshot",
            "targetID": None, "arguments": {}
        }
        self.assertTrue(self.state.enqueue_diagnostic(command))
        self.assertFalse(self.state.enqueue_diagnostic(command))
        nonce = str(uuid.uuid4())
        status, body, _ = self.state.poll_diagnostic(headers(nonce=nonce), self.request)
        self.assertEqual(status, 200)
        self.assertEqual(body["commands"], [command])
        self.assertEqual(self.state.poll_diagnostic(headers(nonce=nonce), self.request)[0], 401)
        # A retry does not trigger commands until their bounded redelivery interval.
        self.assertEqual(self.state.poll_diagnostic(headers(), self.request)[1]["commands"], [])
        reply = {"schemaVersion": 2, "id": command["id"], "sessionID": self.session,
                 "success": True, "message": None, "entries": []}
        status, received, event = self.state.diagnostic_reply(headers(), json.dumps(reply).encode())
        self.assertEqual((status, received), (200, {"accepted": True}))
        self.assertEqual(event[0]["reply"], reply)
        self.assertEqual(self.state.diagnostic_reply(headers(), json.dumps(reply).encode())[0], 409)

    def test_unknown_sessions_bad_operations_and_expired_tokens(self):
        command = {"schemaVersion": 2, "id": str(uuid.uuid4()), "sessionID": self.session,
                   "domain": "inspector", "operation": "snapshot", "targetID": None, "arguments": {}}
        self.assertFalse(self.state.enqueue_diagnostic(command))
        self.assertEqual(self.state.poll_diagnostic(headers(timestamp=0), self.request)[0], 401)
        self.state.poll_diagnostic(headers(), self.request)
        self.assertFalse(self.state.enqueue_diagnostic(dict(command, domain="internal")))
        self.assertFalse(self.state.enqueue_diagnostic(dict(command, arguments={"x": ["unsupported"]})))
        self.assertTrue(self.state.enqueue_diagnostic(command))

    def test_v1_still_requires_original_schema(self):
        status, _, _ = self.state.receive(headers(), b'{"schemaVersion":2,"events":[]}')
        self.assertEqual(status, 400)


if __name__ == "__main__":
    unittest.main()
