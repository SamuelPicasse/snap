#!/bin/zsh
# Builds Snap.app into ./build. Usage: Scripts/bundle.sh [--install]
#   --install  also copies the app to ~/Applications and (re)launches it.
# SIGN_IDENTITY overrides the codesigning identity. A stable identity keeps the
# Screen Recording permission across rebuilds; ad-hoc ("-") re-prompts each build.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release

APP=build/Snap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snap "$APP/Contents/MacOS/Snap"
strip -x "$APP/Contents/MacOS/Snap"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.sammy.snap</string>
    <key>CFBundleName</key><string>Snap</string>
    <key>CFBundleExecutable</key><string>Snap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')}"
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1)), signed with: ${IDENTITY:--}"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Snap 2>/dev/null || true
    while pgrep -x Snap >/dev/null; do sleep 0.1; done
    mkdir -p ~/Applications
    rm -rf ~/Applications/Snap.app
    cp -R "$APP" ~/Applications/
    open ~/Applications/Snap.app
    echo "Installed to ~/Applications/Snap.app"
fi
