#!/bin/bash
# Builds, then runs the end-to-end self-test (it opens a window). Usage: scripts/selftest.sh [app-binary]
#
#   scripts/selftest.sh --relaunch   the relaunch harness (debug build): a real quit, install and relaunch of a throwaway
#                                    copy of the app, then its quits, crashes and restores, in private folders of its own
#                                    (SelfTestRestore.swift, SelfTestRestoreLaunches.swift)
#   scripts/selftest.sh --keep-probe the keep probe (debug build): whether herdr and tmux, started in a tab of the
#                                    harness's throwaway copy, outlive its update relaunch and its quit, run against a herdr
#                                    and a tmux of its own (SelfTestKeepProbe.swift). Installs neither.
set -euo pipefail
cd "$(dirname "$0")/.."

HARNESS_ID=me.mishuk.nextterm.relaunch-harness

# A throwaway app bundle of the debug binary, signed ad hoc: <folder>/Next Term.app at <version>.
make_app() { # <folder> <version>
  local app="$1/Next Term.app"
  mkdir -p "$app/Contents/MacOS"
  cp .build/debug/NextTerm "$app/Contents/MacOS/NextTerm"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Next Term</string>
  <key>CFBundleIdentifier</key><string>$HARNESS_ID</string>
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
    return 1
  fi
}

# The stub opener the install script ends with: it records each call (each argument ends in a NUL, each call in a record
# separator, as the install script's tests read them) and opens nothing.
make_opener() { # <folder>
  mkdir -p "$1/bin"
  cat > "$1/bin/open" <<STUB
#!/bin/sh
printf '%s\0' "\$@" >> $(printf %q "$1/opened")
printf '\036' >> $(printf %q "$1/opened")
STUB
  chmod 755 "$1/bin/open"
}

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
  local id=$HARNESS_ID folder agent
  folder="$(cd "$(mktemp -d)" && pwd -P)"
  agent="$(cd "$(mktemp -d "$HOME/Library/Caches/nt-relaunch-agent.XXXXXX")" && pwd -P)"
  keep() {
    echo "The harness's folders are kept: $folder and $agent" >&2
  }
  make_app "$folder/install" 0.0.1 || { keep; exit 1; }
  make_app "$folder/update" 0.0.2 || { keep; exit 1; }
  mkdir -p "$folder/project" "$folder/api"
  make_opener "$folder"
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

# The keep probe (plan 010a U8): does herdr, or tmux, started in a tab outlive the app's update relaunch, then its quit?
# The harness's two bundles as above, each step launched as the Finder launches an app (`open -n -W`, so the app is no
# child of this script), against a herdr and a tmux of the probe's own: a scratch root in /tmp (short, for the sockets)
# with its own XDG folders and TMUX_TMPDIR, and launchers that start each tool with only the variables it needs and none
# of its config. Nothing here installs herdr or tmux; a missing one is reported skipped. The exit trap ends what the
# probe started, on every path: herdr's probe session stopped and deleted, the probe's tmux server killed, then any
# process still holding a scratch socket, then the scratch root, the harness folder and the throwaway app's defaults.
# It never touches a process by name alone, nor the user's own herdr or tmux.
keep_probe() {
  swift build
  local folder root session="nt-probe-$$" herdr="" tmux="" step failed=0
  folder="$(cd "$(mktemp -d)" && pwd -P)"
  root="$(cd "$(mktemp -d /tmp/ntp.XXXXXX)" && pwd -P)"
  mkdir -p "$root/c" "$root/d" "$root/s" "$root/k" "$root/r" "$root/t" "$root/h"
  chmod 700 "$root/r" "$root/t"
  for candidate in "$(command -v herdr 2>/dev/null || true)" "$HOME/.local/bin/herdr" /opt/homebrew/bin/herdr /usr/local/bin/herdr; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then herdr="$candidate"; break; fi
  done
  for candidate in "$(command -v tmux 2>/dev/null || true)" /opt/homebrew/bin/tmux /usr/local/bin/tmux; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then tmux="$candidate"; break; fi
  done
  # The user's own herdr config must never hold the probe's session: looked for while it runs and after cleanup (a
  # session folder by its name), through a symlinked folder too.
  herdr_config_leak() {
    [[ -e "$HOME/.config/herdr" ]] || return 0
    find -L "$HOME/.config/herdr" -name "$session" -print -quit 2>/dev/null || true
  }
  # HOME is scratch too: the panes' login shells would otherwise read the user's ~/.profile.
  local variables=(HOME="$root/h" USER="$USER" LOGNAME="${LOGNAME:-$USER}" SHELL=/bin/sh PATH=/usr/bin:/bin:/usr/sbin:/sbin
    TERM=xterm-256color LANG=en_US.UTF-8 XDG_CONFIG_HOME="$root/c" XDG_DATA_HOME="$root/d" XDG_STATE_HOME="$root/s"
    XDG_CACHE_HOME="$root/k" XDG_RUNTIME_DIR="$root/r" TMUX_TMPDIR="$root/t")

  # The cleanup, on every exit. herdr's session stopped and tmux's server killed, on the probe's own only; then any
  # process still holding one of the two scratch sockets, while they are still there; then herdr's session deleted; then
  # each pid the probe recorded, only while it still holds a file in the scratch root (each checked again just before
  # the signal, so a reused pid is never hit).
  cleanup() {
    local socket pid
    [[ -n "${folder:-}" && -n "${root:-}" ]] || return 0
    if [[ -n "$herdr" ]]; then
      /usr/bin/env -i "${variables[@]}" "$herdr" session stop "$session" >/dev/null 2>&1 || true
    fi
    if [[ -n "$tmux" ]]; then
      /usr/bin/env -i "${variables[@]}" "$tmux" -L "$session" kill-server >/dev/null 2>&1 || true
    fi
    for socket in "$root/c/herdr/sessions/$session/herdr.sock" "$root/t/tmux-$(id -u)/$session"; do
      [[ -S "$socket" ]] || continue
      for pid in $(lsof -t -- "$socket" 2>/dev/null); do kill -TERM "$pid" 2>/dev/null || true; done
      for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -z "$(lsof -t -- "$socket" 2>/dev/null)" ]] && break; sleep 0.5; done
      for pid in $(lsof -t -- "$socket" 2>/dev/null); do kill -KILL "$pid" 2>/dev/null || true; done
    done
    if [[ -n "$herdr" ]]; then
      /usr/bin/env -i "${variables[@]}" "$herdr" session delete "$session" >/dev/null 2>&1 || true
    fi
    held() { lsof -p "$1" -Fn 2>/dev/null | grep -qF "n$root/"; }
    if [[ -s "$folder/probe-pids" ]]; then
      for pid in $(awk '{print $2}' "$folder/probe-pids"); do
        held "$pid" && kill -TERM "$pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do held "$pid" || break; sleep 0.5; done
        held "$pid" && kill -KILL "$pid" 2>/dev/null
      done
    fi
    pkill -f "$folder/install/Next Term.app/Contents/MacOS/NextTerm" 2>/dev/null || true
    rm -rf "$root"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$folder/install/Next Term.app" "$folder/update/Next Term.app" >/dev/null 2>&1 || true
    defaults delete "$HARNESS_ID" >/dev/null 2>&1 || true
    rm -rf "$folder"
  }
  # An early failure (set -e) still shows the report before cleanup removes it.
  trap 'status=$?; [[ $status -ne 0 && -s "$folder/report.txt" ]] && cat "$folder/report.txt" >&2; cleanup' EXIT
  trap 'exit 130' INT TERM

  make_app "$folder/install" 0.0.1
  make_app "$folder/update" 0.0.2
  mkdir -p "$folder/project"
  make_opener "$folder"
  printf 'session=%s\nroot=%s\nherdr=%s\ntmux=%s\n' "$session" "$root" "$herdr" "$tmux" > "$folder/probe-tools"
  local quoted=""
  for variable in "${variables[@]}"; do quoted+=" $(printf %q "$variable")"; done
  printf '#!/bin/sh\n# The keep probe'"'"'s herdr: its own session, with only these variables.\nexec /usr/bin/env -i%s %q --session %q\n' \
    "$quoted" "$herdr" "$session" > "$folder/probe-herdr"
  printf '#!/bin/sh\n# The keep probe'"'"'s tmux: its own server, no config, with only these variables.\nexec /usr/bin/env -i%s %q -L %q -f /dev/null new-session -A -s probe\n' \
    "$quoted" "$tmux" "$session" > "$folder/probe-tmux"
  : > "$folder/report.txt"
  defaults delete "$HARNESS_ID" >/dev/null 2>&1 || true

  # Each step five minutes at most, its app launched only from the harness's own folder and with the harness's bundle id;
  # one that does not end in time is stopped by its full path.
  launch_step() { # <step>
    local app="$folder/install/Next Term.app" resolved bundle
    resolved="$(cd "$app" && pwd -P)"
    bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$resolved" != "$folder/"* || "$bundle" != "$HARNESS_ID" ]]; then
      echo "FAIL [driver] refused to launch $resolved ($bundle): not the harness's own copy" >> "$folder/report.txt"
      return 1
    fi
    if ! perl -e 'alarm 300; exec @ARGV' /usr/bin/open -n -W -a "$resolved" --args --relaunch-harness "$folder" "$1" \
      >/dev/null 2>&1; then
      if pgrep -f "$resolved/Contents/MacOS/NextTerm" >/dev/null; then
        pkill -f "$resolved/Contents/MacOS/NextTerm" || true
        echo "FAIL [driver] step $1 did not end within five minutes" >> "$folder/report.txt"
      fi
    fi
  }
  launch_step keep-probe-start
  if grep -qE '^RESULT nothing (to probe|started)' "$folder/report.txt"; then
    cat "$folder/report.txt"
    grep -qE '^(FAIL|RESULT nothing started)' "$folder/report.txt" && failed=1
    trap - EXIT
    cleanup
    return "$failed"
  fi
  local leaked
  leaked="$(herdr_config_leak)"
  [[ -z "$leaked" ]] || echo "FAIL [driver] the probe's herdr session is in the user's own config: $leaked" >> "$folder/report.txt"
  for _ in $(seq 1 300); do [[ -s "$folder/opened" ]] && break; sleep 0.2; done
  [[ -s "$folder/opened" ]] || echo "FAIL [driver] the install script opened nothing within a minute of the quit" >> "$folder/report.txt"
  launch_step keep-probe-after-update
  launch_step keep-probe-after-quit
  local report="$folder/report.txt"
  grep -v '^PASS' "$report" || true
  echo "$(grep -c '^PASS' "$report") passed"
  [[ -s "$folder/probe-result.json" ]] && cat "$folder/probe-result.json"
  echo
  local expected passed
  expected="$(printf 'STEP %s PASSED\n' keep-probe-start keep-probe-after-update keep-probe-after-quit)"
  passed="$(grep -E '^STEP [a-z-]+ (PASSED|[0-9]+ FAILED)$' "$report" || true)"
  if grep -q '^FAIL' "$report" || [[ "$passed" != "$expected" ]]; then
    [[ "$passed" == "$expected" ]] || echo "Not every step passed, or one did not finish: see the STEP lines above."
    failed=1
  fi
  # What the probe started is gone, and the user's own herdr config was not touched.
  local pids=""
  [[ -s "$folder/probe-pids" ]] && pids="$(awk '{print $2}' "$folder/probe-pids")"
  trap - EXIT
  cleanup
  local alive=""
  for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive+=" $pid"; done
  local left
  left="$(pgrep -f "$session" || true)"
  local leftover
  leftover="$(herdr_config_leak)"
  if [[ -n "$alive" || -n "$left" || -e "$root" || -n "$leftover" ]]; then
    echo "FAIL [driver] the probe left something: pids alive${alive:- none}, processes naming $session: ${left:-none}," \
      "scratch root there: $([[ -e "$root" ]] && echo yes || echo no), its session in ~/.config/herdr: ${leftover:-no}"
    failed=1
  else
    echo "PASS [driver] the probe left nothing: no pid it noted alive, no process naming $session, the scratch root gone, nothing of its session in ~/.config/herdr"
  fi
  return "$failed"
}

if [[ "${1:-}" == "--keep-probe" ]]; then
  keep_probe
  exit
fi

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
