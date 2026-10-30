"""PR42: deterministic correctness gates for non-gating performance measurements."""
import sys
from pathlib import Path
import unittest
import uuid

SCRIPTS = Path(__file__).resolve().parents[2] / "Scripts"
sys.path.insert(0, str(SCRIPTS))
from bench_studio_matrix import make_reply, measure


class StudioBenchmarkMatrixTests(unittest.TestCase):
    def test_matrix_has_bounded_distinct_entry_ids_and_correct_session(self):
        for size in (100, 500, 1000):
            sid = uuid.uuid4()
            reply = make_reply(size, sid)
            self.assertEqual(reply["sessionID"], str(sid))
            self.assertEqual(len(reply["entries"]), size)
            self.assertEqual(len({e["id"] for e in reply["entries"]}), size)
            self.assertIsNone(reply["entries"][0]["parentID"])

    def test_matrix_rejects_oversized_payload(self):
        with self.assertRaises(ValueError):
            make_reply(1201, uuid.uuid4())

    def test_small_measurement_reports_two_isolated_sessions(self):
        result = measure(4, repeats=2)
        self.assertEqual(result["entries"], 4)
        self.assertEqual(result["devices"], 2)
        self.assertEqual(result["repeats"], 2)
        self.assertGreater(result["peakTracedKiB"], 0)
        self.assertEqual(len(result["jsonBytesPerDevice"]), 2)


if __name__ == "__main__":
    unittest.main()
