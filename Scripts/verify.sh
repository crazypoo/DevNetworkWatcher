#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
python3 -m unittest discover -v -s Tests/BackendTests
python3 -m py_compile Sources/PTNetworkStudio/Backend/*.py
python3 Scripts/verify-pr50-boundaries.py
python3 Scripts/verify-pr55-release-evidence.py Docs/Studio_PR55_Release_Evidence.template.json --validate-template
swift package dump-package >/dev/null
swiftc -frontend -parse Sources/PTNetworkStudio/*.swift
python3 Scripts/audit-swift-source.py
if [ "$(uname -s)" = "Darwin" ]; then
  swift test
  sh Scripts/build-macos.sh
else
  echo 'macOS SwiftUI/AppKit build not performed (requires a Mac).'
fi
