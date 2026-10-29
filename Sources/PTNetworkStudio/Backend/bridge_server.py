"""Authenticated PToolsDebugStudioBridge schema-v1 HTTPS collector.

Usage: python3 bridge_server.py <private-dir> [port=9453] [LAN-IP-or-host]
The generated development CA must be manually trusted by the developer's
test iPhone; certificate pinning is an additional check, not a trust bypass.
"""
import hashlib
import ipaddress
import json
import os
import re
import secrets
import ssl
import subprocess
import sys
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit
from studio_rules import redact_json, MAX_PREVIEW

PREFIX = "PTSTUDIO:"
MAX_PAYLOAD = 2 * 1024 * 1024
MAX_BATCH = 24
NONCE_TTL = 120
KINDS = {"hello", "capabilities", "recordUpsert", "recordFinalize",
         "recordDelete", "sessionReset", "heartbeat"}


def emit(value):
    print(PREFIX + json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)


def openssl(*args):
    subprocess.run(["openssl", *map(str, args)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def valid_host(host):
    host = host.strip()
    if not host or len(host) > 253 or any(x in host for x in "/\\%"):
        raise ValueError("Invalid pairing host")
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", host) or ".." in host:
            raise ValueError("Invalid pairing hostname")
        return host.lower(), "DNS:" + host.lower()
    if address.version != 4 or not (address.is_private or address.is_loopback):
        raise ValueError("Bridge accepts private IPv4 or local hostnames only")
    return str(address), "IP:" + str(address)


def verify_tls_chain(ca_cert, cert):
    """No listener is advertised before a real leaf-to-CA verification succeeds."""
    return subprocess.run(
        ["openssl", "verify", "-CAfile", str(ca_cert), str(cert)],
        capture_output=True, text=True
    ).returncode == 0


def sign_leaf_with_ca(folder, csr, cert, ca_cert, ca_key, san):
    """Use OpenSSL CA signing rather than the platform-dependent x509 -req path.

    The on-disk CA stays unchanged, so already trusted iPhones remain trusted.
    """
    config = folder / "bridge-signing.cnf"
    index = folder / "bridge-signing.index"
    serial = folder / "bridge-signing.serial"
    index.write_text("")
    serial.write_text(secrets.token_hex(8).upper() + "\n")
    config.write_text(
        "[ca]\ndefault_ca=bridge_ca\n"
        "[bridge_ca]\n"
        "database=bridge-signing.index\n"
        "serial=bridge-signing.serial\n"
        "new_certs_dir=.\n"
        "private_key=bridge-root-key.pem\n"
        "certificate=bridge-root-ca.pem\n"
        "default_md=sha256\n"
        "default_days=90\n"
        "policy=bridge_policy\n"
        "x509_extensions=bridge_leaf\n"
        "unique_subject=no\n"
        "[bridge_policy]\ncommonName=supplied\n"
        "[bridge_leaf]\n"
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\n"
        f"subjectAltName={san},IP:127.0.0.1,DNS:localhost\n"
    )
    try:
        subprocess.run(["openssl", "ca", "-batch", "-notext",
                        "-config", config.name, "-in", csr.name,
                        "-out", cert.name], check=True, cwd=folder,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    finally:
        for path in (config, index, serial, folder / (index.name + ".attr"),
                     folder / (serial.name + ".old"), folder / (index.name + ".old")):
            path.unlink(missing_ok=True)


def prepare_identity(folder, hostname="127.0.0.1"):
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    hostname, san = valid_host(hostname)
    ca_cert, ca_key = folder / "bridge-root-ca.pem", folder / "bridge-root-key.pem"
    ca_der = folder / "bridge-root-ca.cer"
    cert, key = folder / "bridge-cert.pem", folder / "bridge-key.pem"
    host_file = folder / "bridge-host"
    # Deliberately migrate the old token filename: it was once copied into
    # an example app's source and can no longer be considered secret.
    legacy_token_file = folder / "bridge-token"
    token_file = folder / "bridge-token-v2"

    if not ca_cert.is_file() or not ca_key.is_file():
        openssl("req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
                "-days", "3650", "-keyout", ca_key, "-out", ca_cert,
                "-subj", "/CN=DevNetworkWatcher Development CA",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign")
        os.chmod(ca_key, 0o600)
    openssl("x509", "-in", ca_cert, "-outform", "DER", "-out", ca_der)
    renew = not (cert.is_file() and key.is_file() and host_file.is_file()
                 and host_file.read_text() == hostname)
    if not renew:
        renew = (subprocess.run(["openssl", "x509", "-checkend", "86400", "-noout",
                                 "-in", str(cert)], stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode != 0
                 or not verify_tls_chain(ca_cert, cert))
    if renew:
        csr = folder / "bridge.csr"
        try:
            openssl("req", "-new", "-newkey", "rsa:3072", "-sha256", "-nodes",
                    "-keyout", key, "-out", csr,
                    "-subj", "/CN=DevNetworkWatcher Bridge")
            sign_leaf_with_ca(folder, csr, cert, ca_cert, ca_key, san)
            os.chmod(key, 0o600)
            if not verify_tls_chain(ca_cert, cert):
                raise RuntimeError("Studio TLS leaf cannot be verified by its Development CA")
            host_file.write_text(hostname)
        finally:
            csr.unlink(missing_ok=True)
    # Refuse to broadcast a listener that iOS SecureTransport cannot trust.
    if not verify_tls_chain(ca_cert, cert):
        raise RuntimeError("Studio TLS certificate chain invalid; re-check the Development CA")
    if not token_file.is_file():
        token_file.write_text(secrets.token_urlsafe(32))
    os.chmod(token_file, 0o600)
    legacy_token_file.unlink(missing_ok=True)
    token = token_file.read_text().strip()
    pin = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
    return cert, key, token, pin, ca_der


def as_uuid(value):
    if not isinstance(value, str):
        raise ValueError("Expected UUID")
    return str(uuid.UUID(value))


def safe_body(value):
    if not isinstance(value, dict):
        raise ValueError("Invalid body snapshot")
    size = value.get("totalBytes")
    if type(size) is not int or not -1 <= size < 2**63 or value.get("redacted") is not True:
        raise ValueError("Unredacted or invalid body")
    preview = value.get("preview")
    if preview is None:
        return "[body withheld]"
    if not isinstance(preview, str) or len(preview.encode("utf-8")) > MAX_PREVIEW:
        raise ValueError("Oversized preview")
    try:
        return json.dumps(redact_json(json.loads(preview)), ensure_ascii=False)
    except (TypeError, ValueError):
        return "[body withheld]"


def safe_headers(value):
    if not isinstance(value, dict) or len(value) > 128:
        raise ValueError("Invalid headers")
    if any(not isinstance(k, str) or not isinstance(v, str) or
           len(k) > 128 or len(v) > 8192 for k, v in value.items()):
        raise ValueError("Invalid header values")
    return {name: "[REDACTED]" for name in value}


def capture_entry(event):
    record = event["payload"].get("record")
    if not isinstance(record, dict) or not isinstance(record.get("method"), str):
        raise ValueError("Invalid record")
    method = record["method"]
    if len(method) > 32:
        raise ValueError("Invalid HTTP method")
    raw_url = record.get("url")
    if not isinstance(raw_url, str) or len(raw_url) > 8192:
        raise ValueError("Invalid URL")
    parsed = urlsplit(raw_url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("Invalid URL")
    host = parsed.hostname
    if len(host) > 255:
        raise ValueError("Invalid hostname")
    suffix = f":{parsed.port}" if parsed.port is not None else ""
    # The PTools privacy policy has already hidden query values. The Mac still
    # fails closed for path, query, fragments, credentials and all header values.
    url = urlunsplit((parsed.scheme, host + suffix, "/", "", ""))
    started = record.get("startedAt")
    if not isinstance(started, str):
        raise ValueError("Missing ISO8601 startedAt")
    moment = datetime.fromisoformat(started.replace("Z", "+00:00"))
    if moment.tzinfo is None:
        raise ValueError("Missing timezone")
    reference = datetime(2001, 1, 1, tzinfo=timezone.utc)
    status = record.get("status")
    if status is not None and (type(status) is not int or not 100 <= status <= 599):
        raise ValueError("Invalid HTTP status")
    duration = record.get("durationSeconds")
    if duration is not None and (not isinstance(duration, (float, int))
                                 or not 0 <= duration <= 86400):
        raise ValueError("Invalid duration")
    response = record.get("responseBody")
    if response is not None and not isinstance(response, dict):
        raise ValueError("Invalid response body")
    response_size = response.get("totalBytes", 0) if response else 0
    if type(response_size) is not int or response_size > 2**63 - 1:
        raise ValueError("Invalid response size")
    return {
        "id": as_uuid(event["requestID"]),
        "startedAt": (moment - reference).total_seconds(),
        "method": method, "url": url, "host": host,
        "source": "PTools Live", "status": status, "duration": duration,
        "requestHeaders": safe_headers(record.get("requestHeaders", {})),
        "responseHeaders": safe_headers(record.get("responseHeaders", {})),
        "requestBody": safe_body(record.get("requestBody")),
        "responseBody": safe_body(response) if response else "[body withheld]",
        "responseSize": max(0, response_size),
        "error": "[network error — details withheld]" if record.get("errorCode") is not None else None
    }


class CollectorState:
    """Replay, nonce and sequence state are isolated to this listening process."""
    def __init__(self, token):
        self.token = token
        self.lock = threading.Lock()
        self.nonces = {}
        self.sessions = {}

    def receive(self, headers, data):
        if not secrets.compare_digest(headers.get("Authorization", ""),
                                      "Bearer " + self.token):
            return 401, None, []
        try:
            nonce = as_uuid(headers.get("X-PTStudio-Nonce"))
            sent_at = int(headers.get("X-PTStudio-Sent-At", ""))
        except (ValueError, TypeError):
            return 400, None, []
        now = int(time.time())
        if abs(now - sent_at) > NONCE_TTL:
            return 401, None, []
        try:
            document = json.loads(data)
            if not isinstance(document, dict) or document.get("schemaVersion") != 1:
                raise ValueError("Unsupported schemaVersion")
            raw_events = document.get("events")
            if not isinstance(raw_events, list) or not 1 <= len(raw_events) <= MAX_BATCH:
                raise ValueError("Invalid batch count")
            session_id, prepared = None, []
            for event in raw_events:
                if not isinstance(event, dict) or event.get("schemaVersion") != 1:
                    raise ValueError("Unsupported event")
                sid = as_uuid(event.get("sessionID"))
                eid = as_uuid(event.get("eventID"))
                as_uuid(event.get("deviceID"))
                if session_id is None:
                    session_id = sid
                elif session_id != sid:
                    raise ValueError("Mixed sessions")
                seq = event.get("sequence")
                kind = event.get("kind")
                if type(seq) is not int or not 0 < seq < 2**64 or kind not in KINDS:
                    raise ValueError("Invalid sequence or kind")
                if not isinstance(event.get("payload"), dict):
                    raise ValueError("Missing payload")
                request_id = event.get("requestID")
                if request_id is not None:
                    request_id = as_uuid(request_id)
                entry = capture_entry(event) if kind in ("recordUpsert", "recordFinalize") else None
                prepared.append((eid, seq, kind, entry, request_id))
            if len({item[0] for item in prepared}) != len(prepared):
                raise ValueError("Duplicate event IDs within batch")
            if any(a[1] >= b[1] for a, b in zip(prepared, prepared[1:])):
                raise ValueError("Out of order sequences")
        except (ValueError, TypeError, KeyError, OverflowError):
            return 400, None, []
        with self.lock:
            self.nonces = {n: expiry for n, expiry in self.nonces.items() if expiry > now}
            if nonce in self.nonces:
                return 409, None, []
            self.nonces[nonce] = now + NONCE_TTL
            if session_id not in self.sessions and len(self.sessions) >= 512:
                return 429, None, []
            session = self.sessions.setdefault(session_id, {"last": 0, "ids": {}})
            last = session["last"]
            messages = []
            for eid, seq, kind, entry, request_id in prepared:
                if eid in session["ids"]:
                    if session["ids"][eid] != (seq, kind):
                        return 409, None, []
                    continue
                if seq <= last:
                    return 409, None, []
                last = seq
                if kind in ("hello", "heartbeat"):
                    # Successfully authenticated and non-replayed. Session UUID
                    # is ephemeral; never expose a token or hardware identity.
                    messages.append({"type": "bridgePeer", "sessionID": session_id})
                elif kind in ("recordUpsert", "recordFinalize"):
                    messages.append({"type": "entry", "entry": entry})
                elif kind == "recordDelete":
                    messages.append({"type": "bridgeDelete", "requestID": request_id})
                elif kind == "sessionReset":
                    messages.append({"type": "bridgeReset", "sessionID": session_id})
            for eid, seq, kind, _, _ in prepared:
                session["ids"][eid] = (seq, kind)
            session["last"] = last
            return 200, {"schemaVersion": 1, "sessionID": session_id,
                         "acceptedSequence": prepared[-1][1]}, messages


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def reply(self, status, data=None):
            body = json.dumps(data, separators=(",", ":")).encode() if data else b""
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_POST(self):
            if self.path != "/v1/events":
                self.reply(404)
                return
            if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
                self.reply(415)
                return
            try:
                size = int(self.headers.get("Content-Length", "-1"))
            except ValueError:
                self.reply(400)
                return
            if not 0 < size <= MAX_PAYLOAD:
                self.reply(413)
                return
            status, ack, events = state.receive(self.headers, self.rfile.read(size))
            for event in events:
                emit(event)
            self.reply(status, ack)
    return Handler


def main():
    folder = Path(sys.argv[1]).resolve()
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 9453
    host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"
    cert, key, token, fingerprint, ca_certificate = prepare_identity(folder, host)
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(CollectorState(token)))
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=str(cert), keyfile=str(key))
    server.socket = context.wrap_socket(server.socket, server_side=True)
    emit({"type": "bridgeReady", "port": port, "token": token, "fingerprint": fingerprint,
          "host": host, "caCertificate": str(ca_certificate)})
    server.serve_forever(poll_interval=0.2)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        emit({"type": "notice", "text": "Bridge failed: " + type(exc).__name__})
        raise
