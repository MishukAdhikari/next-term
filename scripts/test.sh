#!/bin/bash
# Unit tests. With only the Command Line Tools installed, swift-testing lives outside the default
# search path, so point the compiler and the test runner at it.
#
# The tests' fixtures (nt-fixture-*, nt-db-*, nt-skills*, …: one per call, thousands per run) go in the user's
# temporary folder: Foundation's temporaryDirectory there is getconf DARWIN_USER_TEMP_DIR, whatever TMPDIR says. So
# the run notes when it starts, and when it ends, failed or not, removes the nt-* folders made there since. Test runs
# take turns on this Mac: one lock, /tmp/nt-test.lock, is held for the whole run, so a second run waits for the first
# to finish and clean up instead of sweeping its live fixtures. So nothing else's are that new, except the Next Term
# app's own, which the sweep leaves alone: nt-ssh (its ssh settings and control sockets) and nt-suggest-* (a suggestion being worked out). What
# can't be removed (an app bundle macOS protects) is left. TMPDIR, for git and the shells the tests start, is a folder of
# the run's own, removed too.
set -euo pipefail
cd "$(dirname "$0")/.."
# One run at a time on this Mac: the sweep below must never meet another run's fixtures.
if [[ -z "${NT_TEST_LOCKED:-}" ]] && command -v lockf >/dev/null 2>&1; then
  export NT_TEST_LOCKED=1
  exec lockf -s -t 7200 /tmp/nt-test.lock "$PWD/scripts/test.sh" "$@"
fi
TEMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
RUN_TMP="$(mktemp -d /tmp/nt-test.XXXXXX)"
STARTED="$RUN_TMP/.started"
touch "$STARTED"
cleanup() {
  if [[ -n "$TEMP" && -d "$TEMP" ]]; then
    local mine=(-maxdepth 1 -name 'nt-*' ! -name 'nt-ssh' ! -name 'nt-suggest-*' -newer "$STARTED")
    find "$TEMP" "${mine[@]}" -exec chmod -R u+w {} + 2>/dev/null || true
    find "$TEMP" "${mine[@]}" -exec rm -rf {} + 2>/dev/null || true
  fi
  chmod -R u+w "$RUN_TMP" 2>/dev/null || true
  rm -rf "$RUN_TMP" 2>/dev/null || true
}
trap cleanup EXIT
export TMPDIR="$RUN_TMP/"
FW="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FW/Testing.framework" ]]; then
  LIB="$(xcode-select -p)/Library/Developer/usr/lib"
  swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
else
  swift test "$@"
fi
