"""PR55 release evidence validator tests; all actual hardware gates remain pending."""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "verify-pr55-release-evidence.py"
TEMPLATE = ROOT / "Docs" / "Studio_PR55_Release_Evidence.template.json"


class ReleaseEvidenceTests(unittest.TestCase):
    def run_gate(self, path, *extra):
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(path), *extra],
            capture_output=True, text=True, check=False)

    def test_template_is_well_formed_but_not_release_approved(self):
        self.assertEqual(self.run_gate(TEMPLATE, "--validate-template").returncode, 0)
        self.assertNotEqual(self.run_gate(TEMPLATE).returncode, 0)

    def test_missing_or_failed_gate_prevents_false_release(self):
        data = json.loads(TEMPLATE.read_text())
        data["automated"]["ptools_quality"] = {
            "status": "fail", "evidence": "https://github.com/example/run/1"
        }
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "result.json"
            path.write_text(json.dumps(data))
            result = self.run_gate(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("PR55_RELEASE_EVIDENCE", result.stdout)


if __name__ == "__main__":
    unittest.main()
