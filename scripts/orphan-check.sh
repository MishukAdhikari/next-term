#!/bin/bash
# Release check: what keeps running after Next Term quits, closes every tab, or is force quit (SIGKILL).
# Runs a test copy of a release build with its own settings domain and a temporary home, never the installed app
# or your settings. Pass: Quit and closing every tab leave exactly the deliberate survivors (nohup'd and
# SIGHUP-ignoring, disowned and double-forked programs, a GNU screen session, a job disowned in `script`'s shell), the
# app exits within 2 s of the quit request, and SIGKILL leaves no orphaned login shell. Takes about two minutes and
# opens windows. Needs node, npm, python3 and clang.
# Usage: scripts/orphan-check.sh [release build folder, default .build/release]
set -euo pipefail
cd "$(dirname "$0")/.."
REL="${1:-.build/release}"
[[ -x "$REL/NextTerm" ]] || { echo "no NextTerm in $REL: run swift build -c release first"; exit 1; }
for tool in node npm python3 clang; do command -v "$tool" >/dev/null || { echo "needs $tool"; exit 1; }; done
SHIM="$(mktemp -d)/shim.dylib"
trap 'rm -rf "$(dirname "$SHIM")"' EXIT
clang -dynamiclib -fobjc-arc -framework AppKit -o "$SHIM" scripts/orphan-check/shim.m
python3 scripts/orphan-check/check.py "$REL" "$SHIM"
