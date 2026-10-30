#!/usr/bin/env python3
"""PR55: do not call PTools 6.0 / Studio release-ready without real evidence.

Use --validate-template in CI to check the schema without pretending manual
hardware tests ran. Without that flag, every automated and manual gate must
carry a PASS result and a nonempty human-reviewable evidence reference.
"""
import argparse
import json
import sys
from pathlib import Path

REQUIRED = {
    "automated": [
        "ptools_quality", "ptools_governance", "studio_bridge_ci",
        "swift6_apple_sdk", "cocoapods_spm_compatibility",
    ],
    "manual": [
        "two_iphone_seven_cases", "mac_idle_30_min_cpu_memory",
        "network_100_500_1000_flows", "inspector_layout_and_undo",
        "session_revoke_reconnect_replay", "multi_scene_duo_compat",
    ],
}


def check(path: Path, template: bool) -> list[str]:
    data = json.loads(path.read_text(encoding="utf-8"))
    errors = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must equal 1")
    for group, names in REQUIRED.items():
        actual = data.get(group)
        if not isinstance(actual, dict):
            errors.append(f"{group} is required")
            continue
        for name in names:
            record = actual.get(name)
            if not isinstance(record, dict):
                errors.append(f"{group}.{name} is required")
                continue
            state, evidence = record.get("status"), record.get("evidence")
            if state not in {"pass", "fail", "not_run"}:
                errors.append(f"{group}.{name}.status must be pass/fail/not_run")
            if not isinstance(evidence, str):
                errors.append(f"{group}.{name}.evidence must be a string")
            if not template and (state != "pass" or not isinstance(evidence, str) or
                                 len(evidence.strip()) < 10):
                errors.append(f"{group}.{name} is not verified with concrete evidence")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("evidence", type=Path)
    parser.add_argument("--validate-template", action="store_true")
    args = parser.parse_args()
    errors = check(args.evidence, args.validate_template)
    for error in errors:
        print("FAIL [PR55_RELEASE_EVIDENCE]:", error)
    if errors:
        return 1
    if args.validate_template:
        print("PASS [PR55_EVIDENCE_SCHEMA]: template well formed; not release approved")
    else:
        print("PASS [PR55_RELEASE_EVIDENCE]: submitted evidence clears required fields; review content manually")
    return 0


if __name__ == "__main__":
    sys.exit(main())
