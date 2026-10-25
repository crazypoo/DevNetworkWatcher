#!/usr/bin/env python3
"""Source audit for regressions that syntax-only Swift frontend parsing misses."""
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent / "Sources/PTNetworkStudio"
sources = {p.name: p.read_text() for p in root.glob("*.swift")}
assert sources, "No Swift files found"

# Every SwiftUI View must declare exactly one computed View body, but it must
# not also have a stored property named body (regression reported by Xcode).
for name, text in sources.items():
    if "var body: some View" in text:
        assert not re.search(r"(?m)^\s*@(?:State|Binding|Published)\s+(?:private\s+|fileprivate\s+)?var\s+body\s*=", text), (
            f"{name}: stored property named body conflicts with SwiftUI View.body"
        )

assert "TextEditor(text: $requestBody)" in sources["ComposerSheet.swift"]
assert "request.httpBody = Data(requestBody.utf8)" in sources["ComposerSheet.swift"]
assert "struct StudioRuntimeError: LocalizedError" in sources["StudioRuntime.swift"]
# In a `catch` clause, `error` denotes the immutable caught Error, not a
# UI property named `error`. Regressed in 1.0.1 (Xcode arm64 build).
assert 'self.error = error.localizedDescription' in sources['StudioRuntime.swift']
for filename, content in sources.items():
    assert not re.search(r'\bcatch\s*\{\s*error\s*=', content), (
        f"{filename}: catch error shadows the stored UI error property; use self.error"
    )
assert not any("ProxyError(" in t for t in sources.values()), "Old private ProxyError reference found"
print("Swift source-level build regressions: PASS")
