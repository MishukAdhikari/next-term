#!/bin/bash
# Unit tests. With only the Command Line Tools installed, swift-testing lives outside the default
# search path, so point the compiler and the test runner at it.
#
# The tests' fixtures (nt-fixture-*, nt-db-*, nt-skills*, …: one per call, thousands per run) go in the user's
# temporary folder: Foundation's temporaryDirectory there is getconf DARWIN_USER_TEMP_DIR, whatever TMPDIR says. So
# the run notes when it starts, and when it ends, failed or not, removes the nt-* folders made there since. Builds and
# test runs take turns on this Mac, so nothing else's are that new. What can't be removed (an app bundle macOS
# protects) is left. TMPDIR, for git and the shells the tests start, is a folder of the run's own, removed too.
set -euo pipefail
cd "$(dirname "$0")/.."
TEMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
RUN_TMP="$(mktemp -d /tmp/nt-test.XXXXXX)"
STARTED="$RUN_TMP/.started"
touch "$STARTED"
cleanup() {
  if [[ -n "$TEMP" && -d "$TEMP" ]]; then
    find "$TEMP" -maxdepth 1 -name 'nt-*' -newer "$STARTED" -exec chmod -R u+w {} + 2>/dev/null || true
    find "$TEMP" -maxdepth 1 -name 'nt-*' -newer "$STARTED" -exec rm -rf {} + 2>/dev/null || true
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
