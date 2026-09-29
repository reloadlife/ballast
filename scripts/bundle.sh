#!/bin/sh
# Builds Ballast.app in the repo root. Copy it to /Applications, then grant it
# Full Disk Access (System Settings → Privacy & Security) so protected folders
# like Photos and Group Containers can be measured.
set -e
cd "$(dirname "$0")/.."

BUNDLE_ID=${BUNDLE_ID:-dev.mamad.Ballast}
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
# Sparkle reads the appcast from the latest GitHub release (see
# .github/workflows/release.yml). Forks can point it elsewhere.
SPARKLE_FEED_URL=${SPARKLE_FEED_URL:-https://github.com/reloadlife/ballast/releases/latest/download/appcast.xml}
# The key that update archives are checked against: the committed one
# (scripts/sparkle-setup.sh writes it), else the environment. With neither,
# the app is built without one and never checks for updates. Local builds
# (no BUILD_NUMBER given) skip the committed key, so a dev build in the repo
# never offers to replace itself with a release; SPARKLE_DEV=1 opts back in.
if [ -f Resources/sparkle-public-key.txt ] && { [ "$BUILD_NUMBER" != 1 ] || [ -n "${SPARKLE_DEV:-}" ]; }; then
    SPARKLE_PUBLIC_KEY="$(tr -d '[:space:]' < Resources/sparkle-public-key.txt)"
fi
SPARKLE_PUBLIC_KEY=${SPARKLE_PUBLIC_KEY:-}

# Builds both products: the app and its widget extension. The Shortcuts
# actions need SwiftPM's Swift Build backend (the default in Xcode 27's
# Swift 6.4, which has no other): it keeps the compiler's const values and
# the linker's dependency info, which the App Intents step below reads.
# SwiftPMs that still offer a choice are asked for Swift Build.
BUILD_FLAGS="-c release"
if swift build --help-hidden 2>/dev/null | grep -q -- "--build-system"; then
    BUILD_FLAGS="$BUILD_FLAGS --build-system swiftbuild"
fi
swift build $BUILD_FLAGS
BIN="$(swift build $BUILD_FLAGS --show-bin-path)"
APP=Ballast.app
WIDGET="$APP/Contents/PlugIns/BallastWidget.appex"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks" "$WIDGET/Contents/MacOS"
cp "$BIN/Ballast" "$APP/Contents/MacOS/Ballast"
cp "$BIN/BallastWidget" "$WIDGET/Contents/MacOS/BallastWidget"

# Sparkle, for in-app updates. ditto keeps the framework's Versions/Current
# symlinks, which its signature covers. Its XPC services are only for
# sandboxed apps; Ballast isn't one, and Sparkle's docs say they can go.
# Headers and modules are for compiling against it, and Xcode strips them
# when it embeds a framework too.
ditto "$BIN/Sparkle.framework" "$SPARKLE"
for part in XPCServices Headers PrivateHeaders Modules; do
    rm -rf "$SPARKLE/Versions/B/$part" "$SPARKLE/$part"
done
if ! otool -l "$APP/Contents/MacOS/Ballast" | grep -q "path @executable_path/../Frameworks "; then
    echo "error: Ballast's binary has no @executable_path/../Frameworks rpath; it can't load Sparkle." >&2
    exit 1
fi
# The icon is rendered from SwiftUI by scripts/make-icon.swift.
[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Shortcuts, Siri and Spotlight find the app's actions through
# Contents/Resources/Metadata.appintents, which Xcode writes with
# appintentsmetadataprocessor after linking. SwiftPM doesn't run it, so this
# does, with the arguments Xcode 27 passes: the Ballast module's source list
# and .swiftconstvalues, and the linker's dependency info (how it knows the
# binary links AppIntents; without it, extraction is skipped). Nothing
# without the metadata ships: the actions would silently never appear.
ARCH="$(uname -m)"
OBJECTS="$(find .build/out/Intermediates.noindex -type f -name Ballast.SwiftFileList -path "*/Release/*/Objects-normal/$ARCH/*" 2>/dev/null | head -n 1)"
OBJECTS="${OBJECTS%/*}"
INTENTS="$(pwd)/.build/appintents"
rm -rf "$INTENTS" && mkdir -p "$INTENTS"
[ -n "$OBJECTS" ] && find "$(pwd)/$OBJECTS" -maxdepth 1 -name "*.swiftconstvalues" > "$INTENTS/const-values.list"
if [ -z "$OBJECTS" ] || [ ! -s "$INTENTS/const-values.list" ] || [ ! -f "$OBJECTS/Ballast_dependency_info.dat" ]; then
    echo "error: no const values or link dependency info for the Ballast module under .build/out." >&2
    echo "       App Intents metadata needs SwiftPM's Swift Build backend (Xcode 27, Swift 6.4)." >&2
    exit 1
fi
: > "$INTENTS/no-dependencies.list"
TOOLCHAIN="$(xcrun --find swiftc)" && TOOLCHAIN="${TOOLCHAIN%/usr/bin/swiftc}"
# Its log goes to a file: it notes every step, and skipping extraction is
# only a warning, which the check below turns into a failure.
xcrun appintentsmetadataprocessor \
    --toolchain-dir "$TOOLCHAIN" \
    --module-name Ballast \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ { print $3 }')" \
    --platform-family macOS \
    --deployment-target 26.0 \
    --bundle-identifier "$BUNDLE_ID" \
    --output "$(pwd)/$APP/Contents/Resources" \
    --target-triple "$ARCH-apple-macos26.0" \
    --binary-file "$(pwd)/$APP/Contents/MacOS/Ballast" \
    --dependency-file "$OBJECTS/Ballast_dependency_info.dat" \
    --stringsdata-file "$INTENTS/ExtractedAppShortcutsMetadata.stringsdata" \
    --source-file-list "$OBJECTS/Ballast.SwiftFileList" \
    --metadata-file-list "$INTENTS/no-dependencies.list" \
    --static-metadata-file-list "$INTENTS/no-dependencies.list" \
    --swift-const-vals-list "$INTENTS/const-values.list" \
    --compile-time-extraction \
    --deployment-aware-processing \
    --no-app-shortcuts-localization > "$INTENTS/extract.log" 2>&1 || { cat "$INTENTS/extract.log" >&2; exit 1; }
if [ ! -f "$APP/Contents/Resources/Metadata.appintents/extract.actionsdata" ] || grep -q -E "error:|skipped" "$INTENTS/extract.log"; then
    cat "$INTENTS/extract.log" >&2
    echo "error: App Intents metadata wasn't extracted" >&2
    exit 1
fi
grep "warning:" "$INTENTS/extract.log" >&2 || true

# ballast://overview and ballast://cleanup open those screens (the widget
# links to them). SUEnableAutomaticChecks stays unset: Sparkle asks on the
# second launch whether to check, and nothing goes online before that.
if [ -n "$SPARKLE_PUBLIC_KEY" ]; then
    SPARKLE_KEY_ENTRY="<key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_KEY}</string>"
else
    SPARKLE_KEY_ENTRY=""
    echo "note: no Sparkle public key (Resources/sparkle-public-key.txt or SPARKLE_PUBLIC_KEY); this build won't check for updates"
fi
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
    <key>SUFeedURL</key><string>${SPARKLE_FEED_URL}</string>
    ${SPARKLE_KEY_ENTRY}
    <key>SUScheduledCheckInterval</key><integer>86400</integer>
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
# Inside out, never --deep: Sparkle's helpers and then the framework (in the
# order Sparkle's docs give), the widget with its sandbox entitlements, then
# the app (which has none) around them. The release workflow repeats this
# with a Developer ID, --options runtime and --timestamp.
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE/Versions/B/Updater.app"
codesign --force --options runtime --sign "$IDENTITY" "$SPARKLE"
codesign --force --sign "$IDENTITY" --entitlements Resources/BallastWidget.entitlements "$WIDGET"
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP"
