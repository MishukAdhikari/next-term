#!/bin/bash
# Builds, then runs the end-to-end self-test (it opens a window). Usage: scripts/selftest.sh [app-binary]
#
#   scripts/selftest.sh --relaunch   the relaunch harness (debug build): a real quit, install and relaunch of a throwaway
#                                    copy of the app, then its quits, crashes and restores, in private folders of its own
#                                    (SelfTestRestore.swift, SelfTestRestoreLaunches.swift)
set -euo pipefail
cd "$(dirname "$0")/.."

# The relaunch harness. The debug binary goes into two app bundles signed ad hoc, under a new private folder: the
# installed copy and an update at the next version. The installed copy stages the update, quits through the update
# sheet's "Update Now" and the real install script swaps the two (its `open` is a stub that records the call). Then the swapped app is
# launched once for each later step in turn (SelfTestRestore, SelfTestRestoreLaunches): quits with and without the resume
# box, an automatic resume that fails at start, a logout, a launch that names a folder as `nxtrm` does, crashes (each a
# SIGKILL the step sends itself), restores that do not finish, safe mode and a snapshot set aside. Each launch checks what
# the one before left. A stand-in Claude Code, built here, and its own Claude store live in a second private folder,
# outside the temporary folders, which the resume gate keeps an agent's code and store out of. Everything is in those two
# folders, except the throwaway copy's own defaults domain, removed after.
relaunch() {
  swift build
  local bin=.build/debug/NextTerm id=me.mishuk.nextterm.relaunch-harness folder agent
  folder="$(cd "$(mktemp -d)" && pwd -P)"
  agent="$(cd "$(mktemp -d "$HOME/Library/Caches/nt-relaunch-agent.XXXXXX")" && pwd -P)"
  keep() {
    echo "The harness's folders are kept: $folder and $agent" >&2
  }
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
    local signed
    if ! signed="$(codesign --force --sign - "$app" 2>&1)"; then
      echo "error: $app could not be signed ad hoc: $signed" >&2
      keep
      exit 1
    fi
  }
  make_app "$folder/install" 0.0.1
  make_app "$folder/update" 0.0.2
  mkdir -p "$folder/bin" "$folder/project" "$folder/api"
  # Each argument ends in a NUL and each call in a record separator, as the install script's tests read them.
  cat > "$folder/bin/open" <<STUB
#!/bin/sh
printf '%s\0' "\$@" >> $(printf %q "$folder/opened")
printf '\036' >> $(printf %q "$folder/opened")
STUB
  chmod 755 "$folder/bin/open"
  # The stand-in Claude Code: a program named claude, so the kernel and capture see Claude Code, which notes each run's
  # arguments on a line of its own and waits for a signal. Its session and the store it is read from are the harness's.
  # A resume that carries --permission-mode fails at once, as a later Claude Code that no longer takes it would (AE31),
  # and while the harness leaves a file named fail-plain in its folder, so does every other resume.
  mkdir -p "$agent/bin" "$agent/home/.claude"
  chmod 700 "$agent/home" "$agent/home/.claude"
  cat > "$agent/claude.c" <<'C'
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int given(int argc, char **argv, const char *word) {
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], word) == 0) return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  FILE *runs = fopen(RUNS, "a");
  if (runs) {
    for (int i = 1; i < argc; i++) {
      if (i > 1) fputc(' ', runs);
      fputs(argv[i], runs);
    }
    fputc('\n', runs);
    fclose(runs);
  }
  if (given(argc, argv, "--resume")) {
    if (given(argc, argv, "--permission-mode")) {
      fputs("error: unknown option '--permission-mode'\n", stderr);
      return 1;
    }
    if (access(FAIL_PLAIN, F_OK) == 0) {
      fputs("error: No conversation found\n", stderr);
      return 1;
    }
  }
  for (;;) pause();
}
C
  local built
  if ! built="$(${CC:-cc} -O -o "$agent/bin/claude" -DRUNS="\"$agent/runs\"" -DFAIL_PLAIN="\"$agent/fail-plain\"" \
    "$agent/claude.c" 2>&1)"; then
    echo "error: the stand-in Claude Code could not be built: $built" >&2
    keep
    exit 1
  fi
  rm -f "$agent/claude.c"
  printf '%s' "$agent" > "$folder/agent-folder"
  : > "$folder/report.txt"
  defaults delete "$id" >/dev/null 2>&1 || true
  local installed="$folder/install/Next Term.app/Contents/MacOS/NextTerm"
  # Each step, five minutes at most. Neither the stand-in's store nor an automatic resume may come from the environment
  # this script runs in: the variables that move Claude Code's store or continue its turn are left out.
  launch() { # <step> [arguments]
    perl -e 'alarm 300; exec @ARGV' /usr/bin/env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_RESUME_INTERRUPTED_TURN \
      -u CLAUDE_CODE_RESUME_INTERRUPTED_TURN_MAX_AGE_MS -u CLAUDE_CODE_RESUME_PROMPT \
      "$installed" --relaunch-harness "$folder" "$@" >/dev/null 2>&1 || true
  }
  launch update-quit
  # The install script runs once the app has quit, and ends by opening the swapped app through the stub.
  for _ in $(seq 1 300); do [[ -s "$folder/opened" ]] && break; sleep 0.2; done
  [[ -s "$folder/opened" ]] || echo "FAIL [driver] the install script opened nothing within a minute of the quit" >> "$folder/report.txt"
  launch after-update
  launch after-welcome-quit
  launch after-quit-checked
  launch after-quit-unasked
  # As `nxtrm ~/Code/api` launches Next Term when it is not running.
  local request
  request="$(printf '{"items":[{"path":"%s","isDirectory":true,"isNew":false}],"newWindow":false,"app":""}' "$folder/api")"
  launch open-request --open-request "$request"
  local steps=(after-crash fail-again safe-mode-try-again set-aside fail-once fail-again safe-mode-keep)
  for step in "${steps[@]}"; do launch "$step"; done
  defaults delete "$id" >/dev/null 2>&1 || true
  local report="$folder/report.txt"
  grep -v '^PASS' "$report" || true
  echo "$(grep -c '^PASS' "$report") passed"
  # Every step said it passed, in the order the steps ran.
  local expected passed
  expected="$(printf 'STEP %s PASSED\n' update-quit after-update after-welcome-quit after-quit-checked after-quit-unasked \
    open-request "${steps[@]}")"
  passed="$(grep -E '^STEP [a-z-]+ (PASSED|[0-9]+ FAILED)$' "$report" || true)"
  if grep -q '^FAIL' "$report" || [[ "$passed" != "$expected" ]]; then
    [[ "$passed" == "$expected" ]] || echo "Not every step passed, or one did not finish: see the STEP lines above."
    keep
    return 1
  fi
  rm -rf "$folder" "$agent"
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
