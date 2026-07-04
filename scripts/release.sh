#!/bin/bash
# Snapcat release: build → sign → notarize → staple → DMG → appcast → GitHub release.
# Usage: ./scripts/release.sh <version>   e.g. ./scripts/release.sh 0.2.0
set -euo pipefail

cd "$(dirname "$0")/.."

die() { echo "error: $*" >&2; exit 1; }

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "usage: ./scripts/release.sh <version>  (e.g. 0.2.0)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 0.2.0"

# ---------- 1. Preflight ----------
[[ -z "$(git status --porcelain)" ]] || die "git tree is not clean — commit or stash first"

if ! xcrun notarytool history --keychain-profile snapcat-notary >/dev/null 2>&1; then
    cat >&2 <<'EOF'
error: notary credentials not found in the keychain. One-time setup:

  xcrun notarytool store-credentials snapcat-notary \
    --apple-id <APPLE_ID> --team-id YYVT547SZ7 --password <app-specific password>

EOF
    exit 1
fi

# ---------- 2. Bump versions in project.yml ----------
CURRENT_BUILD=$(sed -n 's/^[[:space:]]*CURRENT_PROJECT_VERSION:[[:space:]]*//p' project.yml | head -1)
[[ -n "$CURRENT_BUILD" ]] || die "CURRENT_PROJECT_VERSION not found in project.yml"
NEW_BUILD=$((CURRENT_BUILD + 1))
sed -i '' "s/^\([[:space:]]*\)MARKETING_VERSION:.*/\1MARKETING_VERSION: \"$VERSION\"/" project.yml
sed -i '' "s/^\([[:space:]]*\)CURRENT_PROJECT_VERSION:.*/\1CURRENT_PROJECT_VERSION: $NEW_BUILD/" project.yml
echo "==> Snapcat $VERSION (build $NEW_BUILD)"

# ---------- 3. Generate project + Release build ----------
xcodegen generate
xcodebuild -project Snapcat.xcodeproj -scheme Snapcat -configuration Release \
    -derivedDataPath build/dd build

APP="build/dd/Build/Products/Release/Snapcat.app"
[[ -d "$APP" ]] || die "Release app not found at $APP"

# ---------- 3b. Re-sign Sparkle's nested helpers ----------
# xcodebuild signs the framework shell only; the nested Updater.app/Autoupdate/
# XPC services keep Sparkle's own signature, which notarization rejects.
# Sign inside-out, then rebuild the framework and app seals.
IDENTITY="Developer ID Application"
FW="$APP/Contents/Frameworks/Sparkle.framework"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Versions/B/XPCServices/Installer.xpc"
codesign -f -o runtime --timestamp --preserve-metadata=entitlements -s "$IDENTITY" "$FW/Versions/B/XPCServices/Downloader.xpc"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Versions/B/Autoupdate"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW/Versions/B/Updater.app"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$FW"
codesign -f -o runtime --timestamp -s "$IDENTITY" "$APP"

# ---------- 4. Verify signature ----------
codesign --verify --deep --strict "$APP" || die "codesign verification failed"

# ---------- 5. Zip for notarization ----------
mkdir -p build/dist
ZIP="build/dist/Snapcat-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# ---------- 6. Notarize, staple, re-zip ----------
xcrun notarytool submit "$ZIP" --keychain-profile snapcat-notary --wait \
    || die "app notarization failed (check: xcrun notarytool log --keychain-profile snapcat-notary <id>)"
xcrun stapler staple "$APP" || die "stapling the app failed"
# The distributed zip must contain the stapled ticket — rebuild it from the stapled app.
ditto -c -k --keepParent "$APP" "$ZIP"

# ---------- 7. DMG (stapled app + /Applications symlink), notarize + staple it ----------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="build/dist/Snapcat-$VERSION.dmg"
hdiutil create -volname Snapcat -srcfolder "$STAGE" -ov -format UDZO "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile snapcat-notary --wait \
    || die "DMG notarization failed"
xcrun stapler staple "$DMG" || die "stapling the DMG failed"

# ---------- 8. Appcast (EdDSA-signed; zip name must match the release asset) ----------
mkdir -p build/appcast
cp -f "$ZIP" build/appcast/
DOWNLOAD_PREFIX="https://github.com/beerbeatbox/snapcat/releases/download/v$VERSION/"
if ! ./tools/bin/generate_appcast --account Snapcat --download-url-prefix "$DOWNLOAD_PREFIX" \
        -o appcast.xml build/appcast/; then
    echo "==> Keychain EdDSA key unavailable — retrying with sparkle_priv.pem"
    ./tools/bin/generate_appcast --ed-key-file sparkle_priv.pem \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        -o appcast.xml build/appcast/
fi

# ---------- 9. Commit + push first, so the release tag points at the bumped commit ----------
git add project.yml appcast.xml Snapcat/Info.plist
git commit -m "Release v$VERSION"
git push

# ---------- 10. GitHub release (publishing appcast on main is what ships the update) ----------
gh release create "v$VERSION" "$ZIP" "$DMG" --title "Snapcat $VERSION" --generate-notes

# ---------- 11. Summary ----------
echo
echo "==> Released: https://github.com/beerbeatbox/snapcat/releases/tag/v$VERSION"
echo "==> Running apps will see the update within a day, or immediately via 'Check for Updates…'."
