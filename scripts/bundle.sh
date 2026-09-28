#!/bin/sh
# Builds Ballast.app in the repo root. Copy it to /Applications, then grant it
# Full Disk Access (System Settings → Privacy & Security) so protected folders
# like Photos and Group Containers can be measured.
set -e
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-dev.mamad.Ballast}
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}

# Builds both products: the app and its widget extension.
swift build -c release
BIN="$(swift build -c release --show-bin-path)"
APP=Ballast.app
WIDGET="$APP/Contents/PlugIns/BallastWidget.appex"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$WIDGET/Contents/MacOS"
cp "$BIN/Ballast" "$APP/Contents/MacOS/Ballast"
cp "$BIN/BallastWidget" "$WIDGET/Contents/MacOS/BallastWidget"
# The icon is rendered from SwiftUI by scripts/make-icon.swift.
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ballast://overview and ballast://cleanup open those screens (the widget
# links to them).
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Ballast</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Ballast</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key><array><string>ballast</string></array>
        </dict>
    </array>
</dict>
</plist>
EOF

# An app extension: an XPC!-type bundle that WidgetKit finds through the
# containing app. Its versions have to match the app's.
cat > "$WIDGET/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BallastWidget</string>
    <key>CFBundleDisplayName</key><string>Ballast</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}.widget</string>
    <key>CFBundleExecutable</key><string>BallastWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF

# Sign with a real identity when one is configured: it keeps the Full Disk
# Access grant across rebuilds (ad-hoc signatures change every build, and
# macOS silently drops the grant). Put `SIGN_ID=<identity hash or name>` in
# scripts/signing.local (gitignored) or the environment; otherwise ad-hoc.
[ -f scripts/signing.local ] && . scripts/signing.local
if [ -n "${SIGN_ID:-}" ] && security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    IDENTITY="$SIGN_ID"
else
    [ -n "${SIGN_ID:-}" ] && echo "warning: identity $SIGN_ID not found"
    echo "note: signing ad-hoc; re-grant Full Disk Access after each rebuild"
    IDENTITY=-
fi
# Inside out, never --deep: the widget with its sandbox entitlements, then
# the app (which has none) around it.
codesign --force --sign "$IDENTITY" --entitlements Resources/BallastWidget.entitlements "$WIDGET"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
