#!/bin/sh
set -eu
if [ "$(uname -s)" != "Darwin" ]; then
  echo "This installer runs on macOS only" >&2
  exit 2
fi
if command -v mitmdump >/dev/null 2>&1; then
  echo "mitmdump: $(command -v mitmdump)"
else
  if ! command -v brew >/dev/null 2>&1; then
    echo 'Install Homebrew from https://brew.sh/, then run: brew install --cask mitmproxy' >&2
    exit 1
  fi
  brew install --cask mitmproxy
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo 'python3 required for the optional iOS Bridge. Install Command Line Tools (xcode-select --install).' >&2
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo 'openssl required for the optional iOS Bridge.' >&2
fi
printf 'Dependency check completed. Now run sh Scripts/build-macos.sh\n'
