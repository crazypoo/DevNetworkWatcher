"""PR02–PR06 regression gates: v1 remains intact, v2 is opt-in and bounded."""
import json
import sys
from pathlib import Path
import time
import threading
import unittest
import uuid

BACKEND = Path(__file__).resolve().parents[2] / "Sources" / "PTNetworkStudio" / "Backend"
sys.path.insert(0, str(BACKEND))
from studio_diagnostics import DiagnosticsBroker, safe_reply, validate_command
from bridge_server import CollectorState


def make_command(sid, domain="inspector", operation="snapshot"):
    return {"schemaVersion": 2, "id": str(uuid.uuid4()).upper(),
            "sessionID": sid.upper(), "domain": domain, "operation": operation,
            "targetID": None, "arguments": {}}


def make_headers(token):
    return {"Authorization": "Bearer " + token,
            "X-PTStudio-Nonce": str(uuid.uuid4()),
            "X-PTStudio-Sent-At": str(int(time.time()))}


class DiagnosticsTests(unittest.TestCase):
    def test_denies_unknown_commands_and_unpaired_sessions(self):
        broker = DiagnosticsBroker()
        sid = str(uuid.uuid4())
        cmd = make_command(sid)
        self.assertFalse(broker.enqueue(cmd, {}))
        self.assertFalse(validate_command({**cmd, "operation": "executeScript"}))
        self.assertFalse(validate_command({**cmd, "arguments": {"a": "x" * 10000}}))
        self.assertTrue(broker.enqueue(cmd, {sid: {}}))

    def test_uuid_normalization_poll_and_reply_replay_rejection(self):
        broker = DiagnosticsBroker()
        sid = str(uuid.uuid4())
        cmd = make_command(sid)
        self.assertTrue(broker.enqueue(cmd, {sid: {}}))
        polled = broker.poll(sid.upper(), {sid: {}})
        self.assertEqual(len(polled["commands"]), 1)
        self.assertEqual(polled["commands"][0]["sessionID"], sid)
        reply = {"schemaVersion": 2, "id": cmd["id"].upper(),
                 "sessionID": sid.upper(), "success": True, "entries": []}
        self.assertIsNotNone(broker.accept_reply(reply))
        self.assertIsNone(broker.accept_reply(reply))

    def test_two_authenticated_devices_never_consume_each_others_pending_reply(self):
        broker = DiagnosticsBroker()
        alice = str(uuid.uuid4())
        bob = str(uuid.uuid4())
        command_a = make_command(alice)
        command_b = make_command(bob)
        authenticated = {alice: {}, bob: {}}
        self.assertTrue(broker.enqueue(command_a, authenticated))
        self.assertTrue(broker.enqueue(command_b, authenticated))
        self.assertEqual(len(broker.poll(alice, authenticated)["commands"]), 1)
        self.assertEqual(len(broker.poll(bob, authenticated)["commands"]), 1)

        # Device B cannot acknowledge device A's request ID, and the invalid
        # response must not consume A's pending command.
        wrong = {"schemaVersion": 2, "id": command_a["id"],
                 "sessionID": bob, "success": True, "entries": []}
        self.assertIsNone(broker.accept_reply(wrong))
        valid_a = dict(wrong, sessionID=alice)
        self.assertEqual(broker.accept_reply(valid_a)["sessionID"], alice)
        self.assertIsNone(broker.accept_reply(valid_a))
        valid_b = dict(wrong, id=command_b["id"])
        self.assertEqual(broker.accept_reply(valid_b)["sessionID"], bob)

    def test_reply_redacts_sensitive_attributes_and_bounds(self):
        sid = str(uuid.uuid4())
        reply = {"schemaVersion": 2, "id": str(uuid.uuid4()),
                 "sessionID": sid, "success": True,
                 "entries": [{"id": "v", "name": "UIView", "kind": "UIView",
                              "attributes": {"password": "xyz", "alpha": "0.5", "Auth": "private"}}]}
        cleaned = safe_reply(reply)
        self.assertEqual(cleaned["entries"][0]["attributes"], {"alpha": "0.5"})
        with self.assertRaises(ValueError):
            safe_reply({**reply, "entries": reply["entries"] * 1500})
        with self.assertRaises(ValueError):
            safe_reply({**reply, "entries": [{**reply["entries"][0],
                                              "previewBase64": "x" * 400000}]})

    def test_long_poll_wakes_on_command_without_starving_other_sessions(self):
        broker = DiagnosticsBroker()
        sid = str(uuid.uuid4())
        command = make_command(sid)
        def enqueue_later():
            time.sleep(0.03)
            self.assertTrue(broker.enqueue(command, {sid: {}}))
        producer = threading.Thread(target=enqueue_later)
        producer.start()
        start = time.monotonic()
        result = broker.poll(sid, {sid: {}}, wait_seconds=0.4)
        producer.join(timeout=1)
        self.assertEqual(len(result["commands"]), 1)
        self.assertLess(time.monotonic() - start, 0.3)

    def test_freeform_reply_fields_are_redacted(self):
        from studio_diagnostics import safe_reply
        sid = str(uuid.uuid4())
        reply = {"schemaVersion": 2, "id": str(uuid.uuid4()),
                 "sessionID": sid, "success": True,
                 "message": "Authorization: ABCDEF1234",
                 "entries": [{"id": "log1", "kind": "log", "name": "Login",
                              "detail": "Bearer super-secret-token a@company.com",
                              "attributes": {"note": "password=hunter2",
                                             "url": "https://example.org/api?token=EXPOSED_QUERY"}}]}
        clean = safe_reply(reply)
        serialized = json.dumps(clean)
        for value in ("ABCDEF1234", "super-secret-token", "a@company.com",
                      "hunter2", "EXPOSED_QUERY"):
            self.assertNotIn(value, serialized)

    def test_long_poll_never_holds_v1_collector_lock(self):
        token = "t" * 32
        sid = str(uuid.uuid4())
        state = CollectorState(token)
        state.sessions[sid] = {"last": 1, "ids": {}}
        poll_entered = threading.Event()
        original_poll = state.diagnostics.poll

        def observed_poll(*args, **kwargs):
            poll_entered.set()
            return original_poll(*args, **kwargs)

        state.diagnostics.poll = observed_poll
        response = []

        def run_poll():
            response.append(state.diagnostic_request(
                make_headers(token), "/v2/diagnostics/poll",
                json.dumps({"sessionID": sid}).encode()))

        worker = threading.Thread(target=run_poll)
        worker.start()
        try:
            self.assertTrue(poll_entered.wait(timeout=1))
            acquired = state.lock.acquire(timeout=0.2)
            try:
                self.assertTrue(acquired, "long poll must release the network v1 lock")
            finally:
                if acquired:
                    state.lock.release()
            self.assertTrue(state.diagnostics.enqueue(make_command(sid), state.sessions))
        finally:
            worker.join(timeout=1.5)
        self.assertFalse(worker.is_alive())
        self.assertEqual(response[0][0], 200)
        self.assertEqual(len(response[0][1]["commands"]), 1)

    def test_replay_token_and_nonce_required_without_touching_v1(self):
        token = "a" * 32
        sid = str(uuid.uuid4())
        state = CollectorState(token)
        state.sessions[sid] = {"last": 1, "ids": {}}
        cmd = make_command(sid)
        self.assertTrue(state.diagnostics.enqueue(cmd, state.sessions))
        body = json.dumps({"sessionID": sid.upper()}).encode()
        self.assertEqual(state.diagnostic_request(make_headers("bad"), "/v2/diagnostics/poll", body)[0], 401)
        h = make_headers(token)
        code, result, _ = state.diagnostic_request(h, "/v2/diagnostics/poll", body)
        self.assertEqual(code, 200)
        self.assertEqual(result["schemaVersion"], 2)
        self.assertEqual(len(result["commands"]), 1)
        self.assertEqual(state.diagnostic_request(h, "/v2/diagnostics/poll", body)[0], 409)
        self.assertEqual(state.diagnostic_request(make_headers(token), "/v2/diagnostics/poll",
                                                  b'{"sessionID":"other"}')[0], 403)
        self.assertEqual(state.receive(make_headers(token), b'{"schemaVersion":2,"events":[]}')[0], 400)


if __name__ == "__main__":
    unittest.main()
