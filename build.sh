#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
swift scripts/generate_icon.swift "$PWD/.build/app-icon"
app="$PWD/dist/ResourceWatch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/ResourceWatch "$app/Contents/MacOS/ResourceWatch"
cp .build/app-icon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ResourceWatch</string>
<key>CFBundleIdentifier</key><string>local.resourcewatch.app</string>
<key>CFBundleName</key><string>ResourceWatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
