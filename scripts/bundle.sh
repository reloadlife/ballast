#!/bin/sh
# Builds Ballast.app in the repo root. Copy it to /Applications, then grant it
# Full Disk Access (System Settings → Privacy & Security) so protected folders
# like Photos and Group Containers can be measured.
set -e
cd "$(dirname "$0")/.."

swift build -c release
APP=Ballast.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/Ballast" "$APP/Contents/MacOS/Ballast"
# The icon is rendered from SwiftUI by scripts/make-icon.swift.
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ballast</string>
    <key>CFBundleIdentifier</key><string>dev.mamad.Ballast</string>
    <key>CFBundleExecutable</key><string>Ballast</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION:-0.1.0}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER:-1}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Sign with a real identity when one is configured: it keeps the Full Disk
# Access grant across rebuilds (ad-hoc signatures change every build, and
# macOS silently drops the grant). Put `SIGN_ID=<identity hash or name>` in
# scripts/signing.local (gitignored) or the environment; otherwise ad-hoc.
[ -f scripts/signing.local ] && . scripts/signing.local
if [ -n "${SIGN_ID:-}" ] && security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" "$APP"
else
    [ -n "${SIGN_ID:-}" ] && echo "warning: identity $SIGN_ID not found"
    echo "note: signing ad-hoc; re-grant Full Disk Access after each rebuild"
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
