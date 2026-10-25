#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ]; then
  echo "Run this script on macOS with Xcode Command Line Tools." >&2
  exit 2
fi
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/build/PTNetworkStudio.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PTNetworkStudio" "$app/Contents/MacOS/PTNetworkStudio"
cp -R Sources/PTNetworkStudio/Backend "$app/Contents/Resources/Backend"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PTNetworkStudio</string>
<key>CFBundleIdentifier</key><string>com.crazypoo.PTNetworkStudio</string>
<key>CFBundleName</key><string>PTNetwork Studio</string>
<key>CFBundleDisplayName</key><string>PTNetwork Studio</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1.0.2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || echo "Warning: ad-hoc signing failed; consider signing in Xcode"
echo "Created $app"
