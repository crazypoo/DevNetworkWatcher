"""Bounded, authenticated, opt-in diagnostic command queue for the Studio Bridge.

Transport v2 is separate from existing schema-v1 network events.  No commands are
broadcast over Bonjour; commands are delivered only to an authenticated iOS agent.
"""
import json
import secrets
import time
import uuid
import threading
import re
from collections import deque

SENSITIVE = ("token", "secret", "password", "cookie", "auth", "credential", "private", "keychain")
ALLOWED = {
    "inspector": {"snapshot", "highlight", "setHidden", "setAlpha", "undo"},
    "storage": {"list"},
    "defaults": {"list"},
    "database": {"list"},
    "logging": {"snapshot"},
    "performance": {"snapshot"},
}
MAX_COMMANDS = 32
MAX_ENTRIES = 1200

# Defense-in-depth redaction, including free-form log text and file names.
# UI view hierarchy names are preserved, but credentials are never exported.
BEARER = re.compile(r"(?i)\\b(bearer\\s+)[a-z0-9._~+/-]+")
KEY_VALUE = re.compile(r"(?i)\\b(token|password|secret|api[_-]?key|authorization)\\s*[:=]\\s*[^\\s&,;]+")
EMAIL = re.compile(r"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\\.[a-z]{2,}")
QUERY = re.compile(r"(?i)(https?://[^\\s?#]+)\\?[^\\s#]+")


def redact_text(value):
    if value is None:
        return None
    value = QUERY.sub(r"\\1?[REDACTED]", value)
    value = BEARER.sub(r"\\1[REDACTED]", value)
    value = KEY_VALUE.sub(lambda m: m.group(1) + "=[REDACTED]", value)
    return EMAIL.sub("[REDACTED_EMAIL]", value)



def is_uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value.lower()
    except (ValueError, AttributeError):
        return False


def validate_command(value):
    if not isinstance(value, dict) or value.get("schemaVersion") != 2:
        return False
    if not is_uuid(value.get("id")) or not is_uuid(value.get("sessionID")):
        return False
    domain, operation = value.get("domain"), value.get("operation")
    if operation not in ALLOWED.get(domain, set()):
        return False
    target = value.get("targetID")
    if target is not None and (not isinstance(target, str) or len(target) > 128):
        return False
    args = value.get("arguments", {})
    return isinstance(args, dict) and len(args) <= 16 and all(
        isinstance(k, str) and isinstance(v, str) and len(k) <= 64 and len(v) <= 256
        for k, v in args.items()
    )


def safe_reply(value):
    """Fail closed: no private fields, unbounded UI data, or arbitrary payloads."""
    if not isinstance(value, dict) or value.get("schemaVersion") != 2:
        raise ValueError("invalid diagnostics reply version")
    if not is_uuid(value.get("id")) or not is_uuid(value.get("sessionID")):
        raise ValueError("invalid diagnostic identifiers")
    if type(value.get("success")) is not bool:
        raise ValueError("invalid success flag")
    items = value.get("entries", [])
    if not isinstance(items, list) or len(items) > MAX_ENTRIES:
        raise ValueError("too many diagnostic items")
    clean = []
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("invalid diagnostic entry")
        fields = {}
        for name in ("id", "parentID", "kind", "name", "detail"):
            raw = item.get(name)
            if raw is not None:
                if not isinstance(raw, str) or len(raw) > 256:
                    raise ValueError("invalid item field")
                fields[name] = redact_text(raw) if name in ("name", "detail") else raw
        if not fields.get("id") or not fields.get("kind") or not fields.get("name"):
            raise ValueError("missing entry identity")
        frame = item.get("frame")
        if frame is not None:
            if not isinstance(frame, dict) or set(frame) != {"x", "y", "width", "height"}:
                raise ValueError("invalid rectangle")
            if any(type(x) not in (int, float) or abs(x) > 100000 for x in frame.values()):
                raise ValueError("invalid coordinates")
            fields["frame"] = frame
        attrs = item.get("attributes", {})
        if not isinstance(attrs, dict) or len(attrs) > 24:
            raise ValueError("invalid attributes")
        fields["attributes"] = {
            str(k)[:64]: redact_text(str(v)[:256])
            for k, v in attrs.items()
            if isinstance(k, str) and isinstance(v, str)
            and not any(s in k.lower() for s in SENSITIVE)
        }
        preview = item.get("previewBase64")
        if preview is not None:
            if not isinstance(preview, str) or len(preview) > 320000:
                raise ValueError("preview too large")
            fields["previewBase64"] = preview
        clean.append(fields)
    message = value.get("message")
    if message is not None and (not isinstance(message, str) or len(message) > 256):
        raise ValueError("invalid reply message")
    return {"schemaVersion": 2, "id": str(uuid.UUID(value["id"])),
            "sessionID": str(uuid.UUID(value["sessionID"])),
            "success": value["success"], "message": redact_text(message), "entries": clean}


class DiagnosticsBroker:
    def __init__(self):
        self.queues = {}
        self.pending = {}
        self.condition = threading.Condition()

    def enqueue(self, command, authenticated_sessions):
        if not validate_command(command):
            return False
        sid = str(uuid.UUID(command["sessionID"]))
        if sid not in authenticated_sessions:
            return False
        command = dict(command)
        command["id"] = str(uuid.UUID(command["id"]))
        command["sessionID"] = sid
        with self.condition:
            queue = self.queues.setdefault(sid, deque(maxlen=MAX_COMMANDS))
            if command["id"] in self.pending or len(queue) == MAX_COMMANDS:
                return False
            queue.append(command)
            self.pending[command["id"]] = (sid, time.monotonic() + 45)
            self.condition.notify_all()
            return True

    def poll(self, sid, authenticated_sessions, wait_seconds=0):
        if not is_uuid(sid) or str(uuid.UUID(sid)) not in authenticated_sessions:
            return None
        sid = str(uuid.UUID(sid))
        end = time.monotonic() + min(max(float(wait_seconds), 0), 10)
        with self.condition:
            q = self.queues.setdefault(sid, deque(maxlen=MAX_COMMANDS))
            while not q and time.monotonic() < end:
                self.condition.wait(timeout=max(0, end - time.monotonic()))
            items = [q.popleft() for _ in range(min(4, len(q)))]
        return {"schemaVersion": 2, "commands": items}

    def accept_reply(self, reply):
        clean = safe_reply(reply)
        with self.condition:
            pending = self.pending.get(clean["id"])
            if pending is None or pending[0] != clean["sessionID"] or time.monotonic() > pending[1]:
                return None
            del self.pending[clean["id"]]
            return clean

    def expire(self):
        now = time.monotonic()
        with self.condition:
            self.pending = {k: v for k, v in self.pending.items() if v[1] > now}
