#!/bin/zsh
# Builds Snap.app into ./build. Usage: Scripts/bundle.sh [--install | --release]
#   --install  also copies the app to ~/Applications and (re)launches it.
#   --release  signs with Developer ID + hardened runtime, notarizes, publishes GitHub release
#              v$VERSION with Snap.zip and updates the Homebrew cask. Bump VERSION first.
#              Uses the Developer ID certificate of TEAM (default: Sammy's own team).
#              One-time setup: xcrun notarytool store-credentials snap-notary
# SIGN_IDENTITY overrides the codesigning identity. A stable identity keeps the
# Screen Recording permission across rebuilds; ad-hoc ("-") re-prompts each build.
set -euo pipefail
TEAM="${TEAM:-UJN9G4KLA2}"
VERSION=0.1.0
cd "${0:A:h}/.."

swift build -c release

APP=build/Snap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Snap "$APP/Contents/MacOS/Snap"
strip -x "$APP/Contents/MacOS/Snap"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"  # regenerate with: swift Scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.sammy.snap</string>
    <key>CFBundleName</key><string>Snap</string>
    <key>CFBundleExecutable</key><string>Snap</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

if [[ "${1:-}" == "--release" ]]; then
    IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' -v t="($TEAM)" 'index($0, "Developer ID Application") && index($0, t) {print $2; exit}')}"
    [[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate for team $TEAM (Xcode → Settings → Accounts → Manage Certificates)"; exit 1; }
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
    ditto -c -k --keepParent "$APP" build/Snap.zip
    xcrun notarytool submit build/Snap.zip --keychain-profile snap-notary --wait
    xcrun stapler staple "$APP"
    ditto -c -k --keepParent "$APP" build/Snap.zip  # re-zip with the stapled ticket

    # Publish: the in-app updater and the Homebrew cask both download from this release.
    gh release create "v$VERSION" build/Snap.zip --repo SamuelPicasse/snap --title "Snap $VERSION" --generate-notes
    TAP=$(mktemp -d)
    gh repo clone SamuelPicasse/homebrew-tap "$TAP" -- -q
    mkdir -p "$TAP/Casks"
    sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$(shasum -a 256 build/Snap.zip | cut -d' ' -f1)/" Scripts/snap.rb > "$TAP/Casks/snap.rb"
    git -C "$TAP" add Casks/snap.rb
    git -C "$TAP" commit -qm "snap $VERSION"
    git -C "$TAP" push -q
    echo "Released Snap $VERSION (signed with: $IDENTITY)"
    exit 0
fi

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
