import asyncio
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
import uuid

BACKEND = Path(__file__).resolve().parents[2] / 'Sources' / 'PTNetworkStudio' / 'Backend'
sys.path.insert(0, str(BACKEND))

class Headers(dict):
    def items(self, multi=False): return super().items()

class Message:
    def __init__(self, url='http://example.test/old', content=b'{}'):
        self.url = url
        self.pretty_url = url
        self.pretty_host = 'example.test'
        self.scheme = url.split(':', 1)[0]
        self.method = 'GET'
        self.headers = Headers({'Content-Type': 'application/json'})
        self.content = content
        self.timestamp_start = 1000000000
        self.timestamp_end = 1000000001
        self.status_code = 200
    @property
    def raw_content(self): return self.content

class Response(Message):
    @staticmethod
    def make(status, body, headers):
        m = Response(content=body)
        m.status_code = status
        m.headers = Headers(headers)
        return m

class Flow:
    def __init__(self):
        self.id = str(uuid.uuid4())
        self.request = Message()
        self.response = None
        self.error = None

class AddonTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for p in ['gates', 'maps']:
            (self.root / p).mkdir()
        self.rulesfile = self.root / 'rules.json'
        os.environ['PTSTUDIO_RULES'] = str(self.rulesfile)
        os.environ['PTSTUDIO_GATES'] = str(self.root / 'gates')
        os.environ['PTSTUDIO_MAPS'] = str(self.root / 'maps')
        fake = types.ModuleType('mitmproxy')
        fake.http = types.SimpleNamespace(Response=Response, HTTPFlow=Flow)
        sys.modules['mitmproxy'] = fake
        spec = importlib.util.spec_from_file_location('studio_addon_for_testing', BACKEND / 'studio_addon.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.addon = self.module.StudioAddon()

    def test_map_local_responds_without_upstream(self):
        (self.root / 'maps' / 'fixture.json').write_text('{"hello":"world"}')
        self.rulesfile.write_text(json.dumps([{'kind':'mapLocal','pattern':'http://example.test/*',
            'fileName':'fixture.json','mimeType':'application/json','status':201}]))
        flow = Flow()
        out = io.StringIO()
        with contextlib.redirect_stdout(out): asyncio.run(self.addon.request(flow))
        self.assertEqual(flow.response.status_code, 201)
        self.assertEqual(flow.response.content, b'{"hello":"world"}')
        self.assertIn('PTSTUDIO:', out.getvalue())

    def test_live_rewrite_and_breakpoint_decision(self):
        self.rulesfile.write_text(json.dumps([
            {'kind':'rewriteRequest','pattern':'http://example.test/*','field':'header',
             'headerName':'X-Debug','replacement':'enabled'},
            {'kind':'breakRequest','pattern':'http://example.test/*'}]))
        flow = Flow()
        async def scenario():
            task = asyncio.create_task(self.addon.request(flow))
            await asyncio.sleep(0.05)
            self.assertFalse(task.done())
            path = self.root / 'gates' / (flow.id + '.request.json')
            path.write_text(json.dumps({'action':'continue','changes':{'url':'http://example.test/rewritten'}}))
            await asyncio.wait_for(task, timeout=2)
        with contextlib.redirect_stdout(io.StringIO()): asyncio.run(scenario())
        self.assertEqual(flow.request.headers['X-Debug'], 'enabled')
        self.assertEqual(flow.request.url, 'http://example.test/rewritten')

if __name__ == '__main__': unittest.main()
