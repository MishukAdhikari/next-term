#!/bin/bash
# Builds, then runs the end-to-end self-test (it opens a window). Usage: scripts/selftest.sh [app-binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/NextTerm}"
if [[ "$BIN" == .build/debug/NextTerm ]]; then swift build; fi
REPORT="${REPORT:-$(mktemp -d)/selftest.txt}"
perl -e 'alarm 600; exec @ARGV' "$BIN" --self-test "$REPORT" >/dev/null 2>&1 || true
grep -v '^PASS' "$REPORT" || true
echo "$(grep -c '^PASS' "$REPORT") passed"
grep -q '^ALL PASSED' "$REPORT"
