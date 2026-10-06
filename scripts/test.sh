#!/bin/bash
# Unit tests. With only the Command Line Tools installed, swift-testing lives outside the default
# search path, so point the compiler and the test runner at it.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="$(xcode-select -p)/Library/Developer/Frameworks"
if [[ -d "$FW/Testing.framework" ]]; then
  LIB="$(xcode-select -p)/Library/Developer/usr/lib"
  exec swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
fi
exec swift test "$@"
