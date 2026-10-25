"""mitmdump -s addon: HTTPS MITM, rewrite, Map Local, real breakpoints, safe events.
The only transport to the UI is prefixed NDJSON on stdout. Runtime path from env.
"""
import asyncio
import json
import os
import sys
import time
from pathlib import Path

from mitmproxy import http
from studio_rules import load_rules, matching, map_file, apply_rewrite, safe_body, redact_headers, redact_url

PREFIX = 'PTSTUDIO:'
RULES = os.environ['PTSTUDIO_RULES']
GATES = Path(os.environ['PTSTUDIO_GATES'])
MAPS = os.environ['PTSTUDIO_MAPS']
GATES.mkdir(parents=True, exist_ok=True)
APPLE_EPOCH = 978307200


def emit(event):
    # No raw HTTP bodies or credentials cross this boundary.
    print(PREFIX + json.dumps(event, ensure_ascii=False, separators=(',', ':')), file=sys.stdout, flush=True)


def entry_for(flow):
    req = flow.request
    resp = flow.response
    duration = ((resp.timestamp_end or time.time()) - (req.timestamp_start or time.time())) if resp else None
    return dict(
        id=flow.id, startedAt=(req.timestamp_start or time.time()) - APPLE_EPOCH,
        method=req.method, url=redact_url(req.pretty_url), host=req.pretty_host,
        source='HTTPS MITM' if req.scheme == 'https' else 'HTTP Proxy',
        status=resp.status_code if resp else None, duration=duration,
        requestHeaders=redact_headers(req.headers.items(multi=False)),
        responseHeaders=redact_headers(resp.headers.items(multi=False)) if resp else {},
        requestBody=safe_body(req.raw_content or b'', req.headers.get('content-type', '')),
        responseBody=safe_body(resp.raw_content or b'', resp.headers.get('content-type', '')) if resp else '',
        responseSize=len(resp.raw_content or b'') if resp else 0,
        error='[upstream error — details withheld]' if flow.error else None,
    )


async def pause(flow, phase):
    emit({'type': 'paused', 'id': flow.id, 'phase': phase, 'entry': entry_for(flow)})
    decision_path = GATES / (flow.id + '.' + phase + '.json')
    # Timeout fails OPEN, so an unattended breakpoint cannot stall the network forever.
    for _ in range(120):
        if decision_path.is_file():
            try:
                decision = json.loads(decision_path.read_text(encoding='utf-8'))
                decision_path.unlink(missing_ok=True)
            except (OSError, ValueError):
                decision = {}
            action = decision.get('action', 'continue')
            if action == 'abort':
                flow.response = http.Response.make(418, b'Blocked by PTNetwork Studio breakpoint', {'Content-Type': 'text/plain'})
            else:
                changes = decision.get('changes', {})
                target = flow.request if phase == 'request' else flow.response
                if target is not None:
                    if phase == 'request' and isinstance(changes.get('url'), str) and changes['url'].startswith(('https://', 'http://')):
                        target.url = changes['url']
                    if isinstance(changes.get('body'), str) and len(changes['body'].encode()) <= 1024 * 1024:
                        target.content = changes['body'].encode('utf-8')
                    if phase == 'response' and isinstance(changes.get('status'), int) and 100 <= changes['status'] <= 599:
                        target.status_code = changes['status']
            emit({'type': 'resumed', 'id': flow.id})
            return
        await asyncio.sleep(0.5)
    emit({'type': 'resumed', 'id': flow.id, 'notice': 'Breakpoint timed out; request continued unchanged'})


class StudioAddon:
    async def request(self, flow: http.HTTPFlow):
        emit({'type': 'entry', 'entry': entry_for(flow)})
        for rule in load_rules(RULES):
            if not matching(rule, flow.request.pretty_url, 'request'):
                continue
            kind = rule.get('kind')
            if kind == 'rewriteRequest':
                apply_rewrite(flow.request, rule)
            elif kind == 'mapLocal':
                try:
                    data = map_file(MAPS, rule.get('fileName', ''))
                    code = int(rule.get('status', 200))
                    if not (100 <= code <= 599):
                        raise ValueError('Invalid HTTP status code')
                    flow.response = http.Response.make(code, data, {'Content-Type': rule.get('mimeType', 'application/octet-stream')})
                except (OSError, ValueError) as ex:
                    emit({'type': 'notice', 'text': 'Map Local: ' + str(ex)[:180]})
            elif kind == 'breakRequest':
                await pause(flow, 'request')
            if flow.response is not None:
                break
        emit({'type': 'entry', 'entry': entry_for(flow)})

    async def response(self, flow: http.HTTPFlow):
        for rule in load_rules(RULES):
            if not matching(rule, flow.request.pretty_url, 'response'):
                continue
            if rule.get('kind') == 'rewriteResponse':
                apply_rewrite(flow.response, rule)
            elif rule.get('kind') == 'breakResponse':
                await pause(flow, 'response')
        emit({'type': 'entry', 'entry': entry_for(flow)})

    def error(self, flow: http.HTTPFlow):
        emit({'type': 'entry', 'entry': entry_for(flow)})

    def websocket_message(self, flow: http.HTTPFlow):
        # Frame metadata only: raw frames may carry secrets.
        if flow.websocket and flow.websocket.messages:
            msg = flow.websocket.messages[-1]
            emit({'type': 'notice', 'text': f'WebSocket frame {flow.request.pretty_host}: {len(msg.content)} bytes'})


addons = [StudioAddon()]
