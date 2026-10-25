#!/bin/sh
set -eu
if [ "$#" -ne 1 ]; then
  echo "Usage: sh Scripts/install-ptools-bridge.sh /path/to/PTools" >&2
  exit 2
fi
cd "$(dirname "$0")/.."
target="$1/PooToolsSource/DebugNetwork"
if [ ! -f "$target/PTNetworkCaptureStore.swift" ]; then
  echo "Not a compatible PTools 5.69.0 DebugNetwork source folder: $target" >&2
  exit 2
fi
if [ -e "$target/PTNetworkStudioBridge.swift" ]; then
  echo "Bridge file already exists; refusing to overwrite without review" >&2
  exit 3
fi
cp PToolsIntegration/PTNetworkStudioBridge.swift "$target/PTNetworkStudioBridge.swift"
echo "Bridge adapter copied. Add an opt-in #if DEBUG start call and build the iOS PTools target."
