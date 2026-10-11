#!/bin/zsh
# Builds build/LocalDictation.app. With --install, also replaces /Applications/LocalDictation.app
# and relaunches it.
#
# Signs with the "LocalDictation Dev" identity (scripts/create-signing-identity.sh) when present,
# so macOS privacy permissions survive rebuilds. Override with SIGN_IDENTITY.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product LocalDictation

APP=build/LocalDictation.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp assets/AppIcon.icns "$APP/Contents/Resources/"
cp .build/release/LocalDictation "$APP/Contents/MacOS/"
FRAMEWORK=$(find .build/artifacts -path "*macos-arm64*/llama.framework" -type d | head -1)
cp -R "$FRAMEWORK" "$APP/Contents/Frameworks/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.idreeskamal.localdictation</string>
    <key>CFBundleName</key><string>Local Dictation</string>
    <key>CFBundleExecutable</key><string>LocalDictation</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Local Dictation listens to the built-in microphone to transcribe what you say. Audio never leaves this Mac.</string>
</dict>
</plist>
PLIST

DEV_ID=$(security find-identity -p codesigning 2>/dev/null | awk '/"LocalDictation Dev"/ {print $2; exit}')
IDENTITY="${SIGN_IDENTITY:-${DEV_ID:--}}"
codesign --force --deep --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with ${IDENTITY})"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e 'tell application id "com.idreeskamal.localdictation" to quit' 2>/dev/null || true
    pkill -x LocalDictation 2>/dev/null || true
    for _ in {1..50}; do pgrep -x LocalDictation >/dev/null || break; sleep 0.1; done
    rm -rf /Applications/LocalDictation.app
    cp -R "$APP" /Applications/
    open /Applications/LocalDictation.app
    echo "Installed and launched /Applications/LocalDictation.app"
fi
