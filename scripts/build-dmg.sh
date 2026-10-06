#!/bin/bash
# Builds "Next Term.app" (universal: Apple Silicon + Intel) and a drag-to-install DMG in dist/.
# Needs only the Xcode Command Line Tools.
#
#   scripts/build-dmg.sh                 ad-hoc signed (runs here; elsewhere needs Open Anyway, see README)
#   SIGN_ID="Developer ID Application: …" NOTARY_PROFILE=<notarytool keychain profile> scripts/build-dmg.sh
#                                         signed, notarized and stapled for distribution
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP_NAME="Next Term"
BUNDLE_ID="${BUNDLE_ID:-me.mishuk.nextterm}"
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
# The editor's grammars (licence-checked; see scripts/update-highlighting.py). shiki-swift's own bundle,
# which includes GPL grammars, is deliberately not copied.
cp -R Resources/Highlighting "$APP/Contents/Resources/Highlighting"
# File icons: Material Icon Theme (MIT), packed by scripts/update-icons.py.
cp -R Resources/Icons "$APP/Contents/Resources/Icons"
# nxtrm, the command line tool (on PATH in Next Term's tabs; Shell > Install Command Line Tool for others).
mkdir -p "$APP/Contents/Resources/bin"
cp scripts/nxtrm "$APP/Contents/Resources/bin/nxtrm"
chmod 755 "$APP/Contents/Resources/bin/nxtrm"
# License notices travel with the app; Credits.html is what About Next Term shows.
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
{
  echo '<html><body style="font: 11px -apple-system; color: #888">'
  echo "<p>Next Term is free software under the MIT License. It includes SwiftTerm (MIT), code from libsixel (MIT), Unicode data (Unicode License v3), shiki-swift (MIT) with Oniguruma (BSD-2-Clause), TextMate grammars under their own permissive licences, Material Icon Theme (MIT; icons from Pictogrammers MDI and Google Material Symbols, Apache-2.0) and SwiftDraw (Zlib). Product and technology logos are trademarks of their owners and are used only to identify file types.</p>"
  echo "<pre style=\"font: 10px ui-monospace, Menlo; white-space: pre-wrap\">"
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' LICENSE THIRD_PARTY_NOTICES.md
  echo "</pre></body></html>"
} > "$APP/Contents/Resources/Credits.html"

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
  <key>NSMicrophoneUsageDescription</key><string>A command you ran in Next Term wants to use the microphone.</string>
  <key>NSCameraUsageDescription</key><string>A command you ran in Next Term wants to use the camera.</string>
  <key>NSContactsUsageDescription</key><string>A command you ran in Next Term wants to access your contacts.</string>
  <key>NSCalendarsUsageDescription</key><string>A command you ran in Next Term wants to access your calendars.</string>
  <key>NSLocationUsageDescription</key><string>A command you ran in Next Term wants to use your location.</string>
  <key>NSPhotoLibraryUsageDescription</key><string>A command you ran in Next Term wants to access your photos.</string>
  <!-- Folders can be dropped on the Dock icon (or opened with "Open With") to open them as projects. -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Folder</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Text and source code</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.text</string><string>public.source-code</string><string>public.script</string><string>public.json</string><string>public.yaml</string></array>
    </dict>
  </array>
  <key>NSAppleEventsUsageDescription</key><string>A command you ran in Next Term wants to control another app.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing ($([[ "$SIGN_ID" == "-" ]] && echo ad-hoc || echo "$SIGN_ID"))"
# One signature seals the whole bundle, the resource bundle included (it has no code of its own).
ENTITLEMENTS=scripts/NextTerm.entitlements
if [[ "$SIGN_ID" == "-" ]]; then
  codesign --force --sign - --options runtime --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign "$SIGN_ID" --options runtime --timestamp --entitlements "$ENTITLEMENTS" "$APP"
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
# Notarize and staple before the checksum: stapling changes the DMG's bytes.
if [[ -n "${NOTARY_PROFILE:-}" && "$SIGN_ID" != "-" ]]; then
  echo "==> Notarizing"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo "==> Done"
ls -lh "$DMG"
cat "$DMG.sha256"
lipo -info "$APP/Contents/MacOS/NextTerm"
