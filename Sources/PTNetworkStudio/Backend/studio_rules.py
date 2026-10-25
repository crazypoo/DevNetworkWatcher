"""Pure-Python rule matching, constrained local maps, and default redaction.
No mitmproxy dependency, so this file is unit-testable on all platforms.
"""
import fnmatch
import json
import os
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit, parse_qsl, urlencode

SECRET = ('authorization', 'proxy-authorization', 'cookie', 'set-cookie', 'x-api-key',
          'x-auth-token', 'api_key', 'token', 'access_token', 'refresh_token',
          'password', 'secret', 'session', 'code', 'client_secret', 'credential')
MAX_PREVIEW = 65536
MAX_MAP_BYTES = 10 * 1024 * 1024


def is_secret(name):
    name = str(name).lower().replace('-', '_')
    return name in SECRET or name.endswith(('_token', '_password', '_secret', '_api_key'))


def redact_headers(headers):
    return {str(k): ('[REDACTED]' if is_secret(k) else str(v)[:MAX_PREVIEW])
            for k, v in dict(headers).items()}


def redact_url(url):
    try:
        u = urlsplit(url)
        query = urlencode([(k, '[REDACTED]' if is_secret(k) else v)
                           for k, v in parse_qsl(u.query, keep_blank_values=True)])
        netloc = u.netloc.split('@')[-1]
        return urlunsplit((u.scheme, netloc, u.path, query, ''))
    except (ValueError, UnicodeError):
        return '[invalid URL]'


def redact_json(obj):
    if isinstance(obj, dict):
        return {k: ('[REDACTED]' if is_secret(k) else redact_json(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redact_json(v) for v in obj]
    return obj


def safe_body(data, content_type):
    if not data:
        return ''
    if len(data) > MAX_PREVIEW:
        return f'[body exceeds {MAX_PREVIEW} byte preview limit]'
    ctype = (content_type or '').lower()
    if 'json' in ctype:
        try:
            return json.dumps(redact_json(json.loads(data.decode('utf-8'))), ensure_ascii=False, indent=2)
        except (UnicodeError, ValueError):
            return '[invalid JSON or non-UTF8 body]'
    if 'x-www-form-urlencoded' in ctype:
        try:
            return urlencode([(k, '[REDACTED]' if is_secret(k) else v)
                              for k, v in parse_qsl(data.decode('utf-8'), keep_blank_values=True)])
        except UnicodeError:
            return '[invalid form body]'
    # Never display arbitrary HTML, XML, binary, or text: may contain secrets.
    return '[body hidden by default — JSON/form only]'


def matching(rule, url, phase):
    if not rule.get('enabled', True):
        return False
    kind = rule.get('kind', '')
    if kind == 'breakRequest' and phase != 'request':
        return False
    if kind == 'breakResponse' and phase != 'response':
        return False
    if kind in ('mapLocal', 'rewriteRequest') and phase != 'request':
        return False
    if kind == 'rewriteResponse' and phase != 'response':
        return False
    pattern = rule.get('pattern', '')
    return bool(pattern) and fnmatch.fnmatchcase(url.lower(), pattern.lower())


def load_rules(path):
    try:
        rules = json.loads(Path(path).read_text(encoding='utf-8'))
        return rules if isinstance(rules, list) else []
    except (OSError, ValueError):
        return []


def map_file(root, leaf):
    # App copies selected file to this private directory; no absolute paths or traversal.
    if not leaf or Path(leaf).name != leaf or leaf.startswith('.'):
        raise ValueError('Invalid local map name')
    folder = Path(root).resolve(strict=True)
    candidate = (folder / leaf).resolve(strict=True)
    if not candidate.is_file() or folder not in candidate.parents:
        raise ValueError('Map path escapes the approved directory')
    if candidate.stat().st_size > MAX_MAP_BYTES:
        raise ValueError('Map Local file exceeds 10 MB')
    return candidate.read_bytes()


def apply_rewrite(message, rule):
    field = rule.get('field', 'header')
    if field == 'url' and hasattr(message, 'url'):
        # Exact substring substitution, not regex or script evaluation.
        old = rule.get('search', '')
        if old:
            message.url = message.url.replace(old, rule.get('replacement', ''))
    elif field == 'header':
        name = rule.get('headerName', '').strip()
        if name and '\n' not in name and '\r' not in name:
            value = rule.get('replacement', '')
            if '\r' not in value and '\n' not in value:
                message.headers[name] = value
    elif field == 'body':
        old = rule.get('search', '')
        if old and len(message.content or b'') <= MAX_MAP_BYTES:
            message.content = (message.content or b'').replace(old.encode(), rule.get('replacement', '').encode())
