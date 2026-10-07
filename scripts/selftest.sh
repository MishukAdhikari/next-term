#!/bin/bash
# Builds, then runs the end-to-end self-test (it opens a window). Usage: scripts/selftest.sh [app-binary]
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/NextTerm}"
if [[ "$BIN" == .build/debug/NextTerm ]]; then swift build; fi
REPORT="${REPORT:-$(mktemp -d)/selftest.txt}"
perl -e 'alarm 1200; exec @ARGV' "$BIN" --self-test "$REPORT" >/dev/null 2>&1 || true
touch "$REPORT"
grep -v '^PASS' "$REPORT" || true
tail -n 1 "$REPORT" | grep -qE '^(ALL PASSED|[0-9]+ FAILED)$' || echo "DID NOT FINISH: stopped after the last line above (20-minute limit, or a crash)"
echo "$(grep -c '^PASS' "$REPORT") passed"
grep -q '^ALL PASSED' "$REPORT"
