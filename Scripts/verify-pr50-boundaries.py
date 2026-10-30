#!/usr/bin/env python3
"""PR50: fail when refactoring duplicates the live owners or bypasses v1/v2 boundaries."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources" / "PTNetworkStudio"
swift = {p.name: p.read_text() for p in SOURCES.glob("*.swift")}
assert swift, "Missing Studio Swift sources"

def owners(pattern):
    return sorted(name for name, body in swift.items() if re.search(pattern, body))

expected = {
    r"\bfinal\s+class\s+CaptureStore\b": ["Models.swift"],
    r"\bfinal\s+class\s+StudioBridgeController\b": ["StudioRuntime.swift"],
    r"\bstruct\s+StudioDiagnosticReply\b": ["StudioDiagnostics.swift"],
    r"\benum\s+StudioFlowProjection\b": ["StudioFlowProjection.swift"],
    r"\benum\s+StudioLayoutAudit\b": ["StudioLayoutAudit.swift"],
    r"\benum\s+StudioDiagnosticSearch\b": ["StudioDiagnosticSearch.swift"],
    r"\benum\s+StudioDiagnosticSessionCorrelation\b": ["StudioDiagnosticSessionCorrelation.swift"],
    r"\benum\s+StudioBridgeLocalDecoder\b": ["StudioBridgeLocalDecoder.swift"],
}
for pattern, correct in expected.items():
    actual = owners(pattern)
    assert actual == correct, f"Expected owner {correct}, got {actual}: {pattern}"

assert "StudioFlowProjection.filter(" in swift["StudioContentView.swift"]
assert "filterWorker?.cancel()" in swift["StudioContentView.swift"]
assert "StudioLayoutAudit.analyze(entries)" in swift["StudioDiagnostics.swift"]
assert "StudioDiagnosticSearch.filter(" in swift["StudioDiagnostics.swift"]
assert "StudioDiagnosticSessionCorrelation.relatedSnapshots(" in swift["StudioDiagnostics.swift"]
assert "StudioBridgeLocalDecoder.entries(from: message)" in swift["StudioRuntime.swift"]
assert "maximumBatchSize = 24" in swift["StudioBridgeLocalDecoder.swift"]
assert "acceptsLive(" in swift["StudioRuntime.swift"]
assert "reply.sessionID == sessionID" in swift["StudioDiagnosticSessionCorrelation.swift"]
assert "diagnosticSearch" in swift["StudioWorkspaceView.swift"]

backend = (SOURCES / "Backend" / "bridge_server.py").read_text()
assert '"/v1/events"' in backend and '"/v2/diagnostics/reply"' in backend
assert 'if not is_valid_session(payload.get("sessionID"), self.sessions):' in backend

print("PASS: unique CaptureStore/Bridge/diagnostic projection owners and v1/v2 session gate")
