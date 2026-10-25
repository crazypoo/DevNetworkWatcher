import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Sources' / 'PTNetworkStudio' / 'Backend'))
import studio_rules as r
import bridge_server

class RuleTests(unittest.TestCase):
    def test_sensitive_data(self):
        self.assertNotIn('secret', r.redact_url('https://x.test/v?token=secret'))
        self.assertEqual(r.redact_headers({'Authorization': 'secret'})['Authorization'], '[REDACTED]')
        self.assertNotIn('secret', r.safe_body(b'{"nested":{"password":"secret"}}', 'application/json'))
        self.assertEqual(r.safe_body(b'secret raw text', 'text/plain'), '[body hidden by default — JSON/form only]')

    def test_rules(self):
        rule = {'kind': 'breakRequest', 'pattern': '*://*.example.com/*'}
        self.assertTrue(r.matching(rule, 'https://api.example.com/v1', 'request'))
        self.assertFalse(r.matching(rule, 'https://api.example.com/v1', 'response'))

    def test_map_local_sandbox(self):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root)
            (p / 'ok.json').write_text('{"ok":true}')
            self.assertEqual(r.map_file(root, 'ok.json'), b'{"ok":true}')
            with self.assertRaises(ValueError): r.map_file(root, '../passwd')
            with self.assertRaises(ValueError): r.map_file(root, '/etc/passwd')
            try:
                (p / 'evil').symlink_to('/etc/hosts')
                with self.assertRaises(ValueError): r.map_file(root, 'evil')
            except OSError:
                pass

    def test_bridge_redaction(self):
        safe = bridge_server.sanitize_entry({'id': 'x', 'method': 'POST', 'url': 'https://x/?token=secret',
            'host': 'x', 'requestHeaders': {'Authorization':'secret'}, 'requestBody': 'not safe'})
        self.assertNotIn('secret', json.dumps(safe))
        self.assertEqual(safe['source'], 'PTools Live')

    def test_rewrite(self):
        class Message:
            url = 'https://example.com/old'
            headers = {}
            content = b'old value'
        m = Message()
        r.apply_rewrite(m, {'field': 'url', 'search': 'old', 'replacement': 'new'})
        r.apply_rewrite(m, {'field': 'header', 'headerName': 'X-Test', 'replacement': 'good'})
        r.apply_rewrite(m, {'field': 'body', 'search': 'old', 'replacement': 'new'})
        self.assertEqual(m.url, 'https://example.com/new')
        self.assertEqual(m.headers['X-Test'], 'good')
        self.assertEqual(m.content, b'new value')

if __name__ == '__main__':
    unittest.main()
