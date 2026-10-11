#!/bin/bash
# Unit tests. With only the Command Line Tools installed, swift-testing lives outside the default
# search path, so point the compiler and the test runner at it.
#
# Every temporary file the tests make goes in one folder of this run's, removed when the run ends, failed or
# not: a test that leaves its fixture behind (one per call, thousands per run) no longer fills the disk. A short
# path, as unix sockets made there must fit in 104 bytes. What can't be removed (an app bundle macOS protects)
# is left.
set -euo pipefail
cd "$(dirname "$0")/.."
RUN_TMP="$(mktemp -d /tmp/nt-test.XXXXXX)"
trap 'chmod -R u+w "$RUN_TMP" 2>/dev/null; rm -rf "$RUN_TMP" 2>/dev/null || true' EXIT
export TMPDIR="$RUN_TMP/"
FW="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FW/Testing.framework" ]]; then
  LIB="$(xcode-select -p)/Library/Developer/usr/lib"
  swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
else
  swift test "$@"
fi
