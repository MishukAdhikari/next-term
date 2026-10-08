#!/bin/bash
# Builds, then runs the end-to-end self-test (it opens a window). Usage: scripts/selftest.sh [app-binary]
#
#   scripts/selftest.sh --relaunch   the relaunch harness (debug build): a real quit, install and relaunch of a throwaway
#                                    copy of the app, in a private folder of its own (SelfTestRestore.swift)
set -euo pipefail
cd "$(dirname "$0")/.."

# The relaunch harness. The debug binary goes into two app bundles signed ad hoc, under a new private folder: the
# installed copy and an update at the next version. The installed copy stages the update, quits through "Relaunch Now"
# and the real install script swaps the two (its `open` is a stub that records the call). Then the swapped app is
# launched, and checks what the quit and the install left. Everything is in that folder, except the throwaway copy's own
# defaults domain, removed after.
relaunch() {
  swift build
  local bin=.build/debug/NextTerm id=me.mishuk.nextterm.relaunch-harness folder
  folder="$(cd "$(mktemp -d)" && pwd -P)"
  make_app() { # <folder> <version>
    local app="$1/Next Term.app"
    mkdir -p "$app/Contents/MacOS"
    cp "$bin" "$app/Contents/MacOS/NextTerm"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Next Term</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>NextTerm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$2</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app" >/dev/null 2>&1
  }
  make_app "$folder/install" 0.0.1
  make_app "$folder/update" 0.0.2
  mkdir -p "$folder/bin" "$folder/project"
  # Each argument ends in a NUL and each call in a record separator, as the install script's tests read them.
  cat > "$folder/bin/open" <<STUB
#!/bin/sh
printf '%s\0' "\$@" >> $(printf %q "$folder/opened")
printf '\036' >> $(printf %q "$folder/opened")
STUB
  chmod 755 "$folder/bin/open"
  : > "$folder/report.txt"
  defaults delete "$id" >/dev/null 2>&1 || true
  local installed="$folder/install/Next Term.app/Contents/MacOS/NextTerm"
  perl -e 'alarm 300; exec @ARGV' "$installed" --relaunch-harness "$folder" update-quit >/dev/null 2>&1 || true
  # The install script runs once the app has quit, and ends by opening the swapped app through the stub.
  for _ in $(seq 1 300); do [[ -s "$folder/opened" ]] && break; sleep 0.2; done
  [[ -s "$folder/opened" ]] || echo "FAIL [driver] the install script opened nothing within a minute of the quit" >> "$folder/report.txt"
  perl -e 'alarm 300; exec @ARGV' "$installed" --relaunch-harness "$folder" after-update >/dev/null 2>&1 || true
  defaults delete "$id" >/dev/null 2>&1 || true
  local report="$folder/report.txt"
  grep -v '^PASS' "$report" || true
  echo "$(grep -c '^PASS' "$report") passed"
  if grep -q '^FAIL' "$report" || ! grep -q '^STEP after-update PASSED$' "$report"; then
    echo "The harness's folder is kept: $folder"
    return 1
  fi
  rm -rf "$folder"
}

if [[ "${1:-}" == "--relaunch" ]]; then
  relaunch
  exit
fi

BIN="${1:-.build/debug/NextTerm}"
if [[ "$BIN" == .build/debug/NextTerm ]]; then swift build; fi
REPORT="${REPORT:-$(mktemp -d)/selftest.txt}"
perl -e 'alarm 1800; exec @ARGV' "$BIN" --self-test "$REPORT" >/dev/null 2>&1 || true
touch "$REPORT"
grep -v '^PASS' "$REPORT" || true
tail -n 1 "$REPORT" | grep -qE '^(ALL PASSED|[0-9]+ FAILED)$' || echo "DID NOT FINISH: stopped after the last line above (30-minute limit, or a crash)"
echo "$(grep -c '^PASS' "$REPORT") passed"
grep -q '^ALL PASSED' "$REPORT"
