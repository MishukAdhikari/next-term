#!/bin/bash
# Release check: Next Term's performance budget. Runs a test copy of a release build with its own settings domain
# and a temporary home, never the installed app or your settings, and measures instructions retired (stable across
# P and E cores), git's CPU and the memory footprint in five scenarios: idle with 10 tabs, 3 agents with the app
# hidden, 10 s of output as fast as it comes, a `next dev`-style writer in a 20,000-file repository, and 30 s after a
# 10 MB burst. Run it on Apple Silicon before every release; it takes about five minutes and opens windows. S7w
# needs --front (the copy takes the front: leave the Mac alone meanwhile). In CI, pass --warn-only.
# Usage: scripts/perf-budget.sh [release build folder, default .build/release] [--front] [--only S2,S4h] [--warn-only]
set -euo pipefail
cd "$(dirname "$0")/.."
REL=.build/release
if [[ $# -gt 0 && "$1" != --* ]]; then REL="$1"; shift; fi
[[ -x "$REL/NextTerm" ]] || { echo "no NextTerm in $REL: run swift build -c release first"; exit 1; }
for tool in python3 clang git; do command -v "$tool" >/dev/null || { echo "needs $tool"; exit 1; }; done
TOOLS="$(mktemp -d)"
trap 'rm -rf "$TOOLS"' EXIT
clang -dynamiclib -fobjc-arc -framework AppKit -o "$TOOLS/shim.dylib" scripts/perf-budget/shim.m
clang -O2 -o "$TOOLS/ru" scripts/perf-budget/ru.c
python3 scripts/perf-budget/run.py "$REL" "$TOOLS/shim.dylib" "$TOOLS/ru" "$@"
