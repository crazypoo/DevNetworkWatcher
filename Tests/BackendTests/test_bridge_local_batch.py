"""PR58: local stdout batching preserves the authenticated v1 event ordering."""
import sys
import unittest
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[2] / "Sources" / "PTNetworkStudio" / "Backend"
sys.path.insert(0, str(BACKEND))
from bridge_server import local_ui_messages


class LocalBridgeBatchTests(unittest.TestCase):
    def test_contiguous_upserts_are_combined_and_single_events_remain_legacy(self):
        entries = [{"type": "entry", "entry": {"id": str(i)}} for i in range(24)]
        grouped = list(local_ui_messages(entries))
        self.assertEqual(len(grouped), 1)
        self.assertEqual(grouped[0]["type"], "entryBatch")
        self.assertEqual([entry["id"] for entry in grouped[0]["entries"]],
                         list(map(str, range(24))))
        single = list(local_ui_messages(entries[:1]))
        self.assertEqual(single, entries[:1])

    def test_peer_delete_and_reset_are_strict_order_barriers(self):
        events = [
            {"type": "entry", "entry": {"id": "a"}},
            {"type": "entry", "entry": {"id": "b"}},
            {"type": "bridgeDelete", "requestID": "a"},
            {"type": "entry", "entry": {"id": "c"}},
            {"type": "bridgeReset", "sessionID": "s1"},
            {"type": "entry", "entry": {"id": "d"}},
            {"type": "entry", "entry": {"id": "e"}},
        ]
        grouped = list(local_ui_messages(events))
        self.assertEqual([event["type"] for event in grouped],
                         ["entryBatch", "bridgeDelete", "entry", "bridgeReset", "entryBatch"])
        self.assertEqual(grouped[0]["entries"][0]["id"], "a")
        self.assertEqual(grouped[-1]["entries"][-1]["id"], "e")

    def test_empty_and_peer_only_batches_do_not_change_messages(self):
        self.assertEqual(list(local_ui_messages([])), [])
        peer = [{"type": "bridgePeer", "sessionID": "s"}]
        self.assertEqual(list(local_ui_messages(peer)), peer)
        self.assertEqual(list(local_ui_messages(peer + [{"type": "entry", "entry": {"id": "a"}}])),
                         peer + [{"type": "entry", "entry": {"id": "a"}}])


if __name__ == "__main__":
    unittest.main()
