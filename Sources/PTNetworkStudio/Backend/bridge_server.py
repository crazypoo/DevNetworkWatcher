"""Opt-in TLS + cert-pin + bearer-token ingestion for PTools iOS capture records.
Run: python3 bridge_server.py <app-private-dir> [port] ; no external dependencies.
"""
import hashlib
import json
import os
import secrets
import ssl
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from studio_rules import redact_headers, redact_url, redact_json, MAX_PREVIEW
PREFIX = 'PTSTUDIO:'
MAX_PAYLOAD = 512 * 1024


def emit(o):
    print(PREFIX + json.dumps(o, separators=(',', ':'), ensure_ascii=False), flush=True)


def prepare_identity(folder):
    folder.mkdir(parents=True, exist_ok=True)
    cert, key, tokenfile = folder / 'bridge-cert.pem', folder / 'bridge-key.pem', folder / 'bridge-token'
    if not cert.is_file() or not key.is_file():
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-sha256', '-nodes',
                        '-days', '90', '-keyout', str(key), '-out', str(cert),
                        '-subj', '/CN=PTNetworkStudioBridge'], check=True, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)
        os.chmod(key, 0o600)
    if not tokenfile.is_file():
        tokenfile.write_text(secrets.token_urlsafe(32))
        os.chmod(tokenfile, 0o600)
    token = tokenfile.read_text().strip()
    pem = cert.read_text()
    digest = hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()
    return cert, key, token, digest


def sanitize_entry(raw):
    if not isinstance(raw, dict):
        raise ValueError('Expected object')
    for field in ('id', 'method', 'url', 'host'):
        if not isinstance(raw.get(field), str) or not raw[field] or len(raw[field]) > 8192:
            raise ValueError('Invalid ' + field)
    fields = ('id', 'startedAt', 'method', 'url', 'host', 'source', 'status', 'duration',
              'requestHeaders', 'responseHeaders', 'requestBody', 'responseBody', 'responseSize', 'error')
    o = {k: raw[k] for k in fields if k in raw}
    o['url'] = redact_url(o['url'])
    o['host'] = o['host'][:512]
    o['source'] = 'PTools Live'
    if o.get('error') is not None:
        o['error'] = '[network error — details withheld]'
    for k in ('requestHeaders', 'responseHeaders'):
        o[k] = redact_headers(o.get(k) or {})
    # iOS encoder already redacts content; Mac never trusts arbitrary user-supplied body fields.
    for k in ('requestBody', 'responseBody'):
        value = o.get(k, '')
        if isinstance(value, str) and len(value.encode('utf-8')) <= MAX_PREVIEW:
            try:
                # Recursively redact a second time on the receiving Mac.
                o[k] = json.dumps(redact_json(json.loads(value)), ensure_ascii=False)
            except ValueError:
                o[k] = '[body withheld]'
        else:
            o[k] = '[body withheld]' 
    return o


def make_handler(token):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'
        def log_message(self, fmt, *args):
            pass
        def do_POST(self):
            if self.path != '/v1/capture':
                self.send_error(404); return
            received = self.headers.get('Authorization', '')
            if not secrets.compare_digest(received, 'Bearer ' + token):
                self.send_error(401); return
            try:
                size = int(self.headers.get('Content-Length', '-1'))
                if not 0 < size <= MAX_PAYLOAD:
                    self.send_error(413); return
                payload = json.loads(self.rfile.read(size))
                entry = sanitize_entry(payload['entry'])
                emit({'type': 'entry', 'entry': entry})
            except (ValueError, KeyError, TypeError, OverflowError):
                self.send_error(400); return
            self.send_response(204)
            self.send_header('Content-Length', '0')
            self.end_headers()
    return Handler


def main():
    folder = Path(sys.argv[1]).resolve()
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9443
    cert, key, token, digest = prepare_identity(folder)
    server = ThreadingHTTPServer(('0.0.0.0', port), make_handler(token))
    server.daemon_threads = True
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(certfile=str(cert), keyfile=str(key))
    server.socket = ctx.wrap_socket(server.socket, server_side=True)
    emit({'type': 'bridgeReady', 'port': port, 'token': token, 'fingerprint': digest})
    server.serve_forever(poll_interval=0.2)


if __name__ == '__main__':
    try:
        main()
    except Exception as ex:
        emit({'type': 'notice', 'text': 'Bridge error: ' + str(ex)[:200]})
        raise
