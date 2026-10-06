#!/bin/bash
# Builds "Next Term.app" (universal: Apple Silicon + Intel) and a drag-to-install DMG in dist/.
# Needs only the Xcode Command Line Tools.
#
#   scripts/build-dmg.sh                 ad-hoc signed (runs on this Mac; others must right-click > Open)
#   SIGN_ID="Developer ID Application: …" scripts/build-dmg.sh
#                                         signed for distribution; then notarize (see README)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP_NAME="Next Term"
BUNDLE_ID="me.mishuk.nextterm"
SIGN_ID="${SIGN_ID:--}"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/NextTerm-$VERSION.dmg"

echo "==> Building arm64 and x86_64"
swift build -c release --triple arm64-apple-macosx13.0
swift build -c release --triple x86_64-apple-macosx13.0

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create .build/arm64-apple-macosx/release/NextTerm .build/x86_64-apple-macosx/release/NextTerm \
     -output "$APP/Contents/MacOS/NextTerm"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftTerm's optional Metal shaders; it looks for them in Contents/Resources.
cp -R .build/arm64-apple-macosx/release/SwiftTerm_SwiftTerm.bundle "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>NextTerm</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSHumanReadableCopyright</key><string>© $(date +%Y) Mishuk Adhikari</string>
  <!-- Shown when a command in a tab touches these folders. -->
  <key>NSDesktopFolderUsageDescription</key><string>A command you ran in Next Term wants to access your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>A command you ran in Next Term wants to access your Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>A command you ran in Next Term wants to access your Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key><string>A command you ran in Next Term wants to access a removable volume.</string>
  <key>NSNetworkVolumesUsageDescription</key><string>A command you ran in Next Term wants to access a network volume.</string>
  <key>NSAppleEventsUsageDescription</key><string>A command you ran in Next Term wants to control another app.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing ($([[ "$SIGN_ID" == "-" ]] && echo ad-hoc || echo "$SIGN_ID"))"
# One signature seals the whole bundle, the resource bundle included (it has no code of its own).
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - --options runtime "$APP"
else
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp "$APP"
fi
codesign --verify --strict --verbose=1 "$APP"

echo "==> Creating $DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
[[ "$SIGN_ID" != "-" ]] && codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
hdiutil verify "$DMG" >/dev/null
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Done"
ls -lh "$DMG"
cat "$DMG.sha256"
lipo -info "$APP/Contents/MacOS/NextTerm"
