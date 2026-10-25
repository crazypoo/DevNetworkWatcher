"""Verify real TLS server, authorization and redacted NDJSON transport."""
import http.client
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import tempfile
import unittest

BACKEND = Path(__file__).resolve().parents[2] / 'Sources' / 'PTNetworkStudio' / 'Backend'

class BridgeIntegrationTest(unittest.TestCase):
    def test_pinned_tls_ingest(self):
        with tempfile.TemporaryDirectory() as tmp:
            with socket.socket() as probe:
                probe.bind(('127.0.0.1', 0))
                port = probe.getsockname()[1]
            proc = subprocess.Popen([sys.executable, '-u', str(BACKEND / 'bridge_server.py'), tmp, str(port)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                line = proc.stdout.readline().strip()
                self.assertTrue(line.startswith('PTSTUDIO:'), (line, proc.poll()))
                ready = json.loads(line.removeprefix('PTSTUDIO:'))
                self.assertEqual(ready['type'], 'bridgeReady')
                self.assertEqual(len(ready['fingerprint']), 64)
                ctx = ssl._create_unverified_context()
                connection = http.client.HTTPSConnection('127.0.0.1', port, context=ctx, timeout=3)
                connection.connect()
                actual_pin = hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest()
                self.assertEqual(actual_pin, ready['fingerprint'])
                payload = {'entry': {'id': 'fb394afa-e30c-4460-a14f-e18e7b74335d',
                          'method': 'GET', 'url': 'https://example.com/?token=secret',
                          'host': 'example.com', 'requestHeaders': {'Authorization': 'secret'},
                          'requestBody': '{"password":"secret"}', 'responseBody': '{}',
                          'startedAt': 810000000}}
                body = json.dumps(payload).encode()
                connection.request('POST', '/v1/capture', body=body, headers={
                    'Authorization': 'Bearer wrong', 'Content-Type': 'application/json'})
                self.assertEqual(connection.getresponse().status, 401)
                connection.request('POST', '/v1/capture', body=body, headers={
                    'Authorization': 'Bearer ' + ready['token'], 'Content-Type': 'application/json'})
                self.assertEqual(connection.getresponse().status, 204)
                event = proc.stdout.readline().strip()
                self.assertTrue(event.startswith('PTSTUDIO:'))
                self.assertNotIn('secret', event)
                self.assertEqual(json.loads(event.removeprefix('PTSTUDIO:'))['entry']['source'], 'PTools Live')
                connection.close()
            finally:
                proc.terminate()
                proc.wait(timeout=5)
                proc.stdout.close()
                proc.stderr.close()

if __name__ == '__main__': unittest.main()
