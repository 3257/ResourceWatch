#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# The release workflow passes VERSION from the tag. The commit count keeps build numbers rising.
version="${VERSION:-0.4.0}"
build="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
swift build -c release
swift scripts/generate_icon.swift "$PWD/.build/app-icon"
app="$PWD/dist/ResourceWatch.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/ResourceWatch "$app/Contents/MacOS/ResourceWatch"
cp .build/app-icon/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Remove first: cp -R into an existing folder nests the copy one level down.
rm -rf "$app/Contents/Resources/Scripts"
cp -R CleanupScripts "$app/Contents/Resources/Scripts"
xcrun actool .build/app-icon/Assets.xcassets \
  --compile "$app/Contents/Resources" \
  --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist .build/app-icon/AssetInfo.plist
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ResourceWatch</string>
<key>CFBundleIdentifier</key><string>io.github.3257.ResourceWatch</string>
<key>CFBundleName</key><string>ResourceWatch</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIconName</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
echo "$app"
