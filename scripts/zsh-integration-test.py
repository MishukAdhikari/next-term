#!/usr/bin/env python3
"""Runs the shipped .zshenv in a real pty and checks the OSC marks it emits.

Two runs: one with the user's own zsh config (whatever this machine has), one with a hostile config
(`setopt nounset ksh_arrays`) to prove the hooks are robust to user options.
"""
import base64, os, pty, re, select, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, "Sources/NextTermCore/ShellIntegration.swift")).read()
script = src.split('zshenvScript = #"""\n', 1)[1].split('"""#', 1)[0]
NONCE = "0123456789abcdef0123456789abcdef"

failures = []
def check(cond, msg):
    print(("PASS " if cond else "FAIL ") + msg)
    if not cond:
        failures.append(msg)

def run_session(label, user_zdotdir, steps):
    zdot = tempfile.mkdtemp()
    open(os.path.join(zdot, ".zshenv"), "w").write(script)
    # The same variables Next Term sets for every shell (TerminalTab.environment).
    env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", TERM_PROGRAM="NextTerm",
               LANG=os.environ.get("LANG") or "en_US.UTF-8", ZDOTDIR=zdot, NEXTTERM_NONCE=NONCE,
               NEXTTERM_USER_ZDOTDIR=user_zdotdir)
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(os.path.expanduser("~"))
        os.execve("/bin/zsh", ["-zsh"], env)
    buf = b""
    def read_for(seconds):
        nonlocal buf
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    buf += os.read(fd, 65536)
                except OSError:
                    return
    read_for(4)  # let the config (oh-my-zsh, p10k...) finish
    for keys, wait in steps:
        os.write(fd, keys.encode())
        read_for(wait)
    os.write(fd, b"exit\r")
    read_for(1)
    text = buf.decode("utf-8", "replace")
    marks = re.findall(r"\x1b\]6973;([^\x07]*)\x07", text)
    events = []
    for m in marks:
        nonce, kind, val = (m.split(";", 2) + ["", ""])[:3]
        if kind == "cwd" and val:
            val = base64.b64decode(val).decode()
        elif kind == "cmd":
            typed, _, expanded = val.partition(";")
            val = base64.b64decode(typed).decode()
            events.append((nonce, "exp", base64.b64decode(expanded).decode() if expanded else ""))
        elif kind == "jobs":
            count, _, listing = val.partition(";")
            val = count + ":" + (base64.b64decode(listing).decode() if listing else "")
        events.append((nonce, kind, val))
    print(f"[{label}] events:", [(k, v) for _, k, v in events])
    assert len(text) > 200, "no session output captured: the checks below would pass vacuously"
    # Error lines that point at our script or our functions (not at /etc/zshrc and friends).
    ours = [l for l in re.sub(r"\x1b\][^\x07]*\x07", "", text).splitlines()
            if (zdot in l or "__nextterm" in l) and ("not set" in l or "error" in l.lower() or "not found" in l)]
    for l in ours:
        print("  hook error:", l.strip()[:200])
    if os.environ.get("NT_DUMP"):  # NT_DUMP=1 saves each session's raw output, for debugging
        path = os.path.join(tempfile.gettempdir(), f"nextterm-zsh-{label.split()[0]}.txt")
        open(path, "w").write(text)
        print("  session saved to", path)
    return events, text, zdot, ours

# 1. The user's own config.
events, text, zdot, errors = run_session("user config", os.environ.get("ZDOTDIR", ""), [
    ("sleep 0.3; false\r", 1.5),
    ("cd /tmp\r", 1),
    ('echo "ZD=${ZDOTDIR:-unset} HOOK=$__nextterm_hooked NONCE_ENV=$(env | grep -c NEXTTERM_NONCE) EARLY=$__early_nonce"\r', 1.5),
    ("sleep 3\r", 0.6),
    ("\x1a", 0.8),  # Ctrl-Z
    ("fg\r", 3.5),
])
ev = [(k, v) for _, k, v in events]
check(all(n == NONCE for n, _, _ in events) and events, "every mark carries the tab's nonce")
check(("cmd", "sleep 0.3; false") in ev, "preexec reports the command line")
i = ev.index(("cmd", "sleep 0.3; false")) if ("cmd", "sleep 0.3; false") in ev else -1
check(i >= 0 and ("end", "1") in ev[i:], "precmd reports exit status 1 after it")
check(("cwd", "/tmp") in ev, "precmd reports the new directory")
check("HOOK=1" in text and "NONCE_ENV=0" in text, "hooks active, nonce not in the environment of child processes")
check(("jobs", "1:sleep 3 (suspended)") in ev, "precmd reports a suspended job")
suspended = ev.index(("jobs", "1:sleep 3 (suspended)")) if ("jobs", "1:sleep 3 (suspended)") in ev else None
check(suspended is not None and ("jobs", "0:") in ev[suspended + 1:], "and its end after `fg`")
check("ZD=" in text and zdot not in text.replace(f"{zdot}/.zshenv:", ""), "user ZDOTDIR restored (ours never leaks into the session)")
check(not errors, "no errors from the hooks with the user's config")
check(ev.count(("cmd", "cd /tmp")) == 1, "each command reported once")
check(ev.count(("cmd", "sleep 3")) == 2 and ("cmd", "fg") not in ev, "`fg` reports the resumed job, not \"fg\"")

# 2. Hostile options in the user's config must not break the hooks or print errors.
hostile = tempfile.mkdtemp()
# The user's .zshenv records whether it can see the nonce: it must not.
open(os.path.join(hostile, ".zshenv"), "w").write('setopt nounset ksh_arrays\ntypeset -g __early_nonce="${NEXTTERM_NONCE-none}"\n')
open(os.path.join(hostile, ".zshrc"), "w").write("setopt nounset ksh_arrays err_return\nPS1='$ '\nalias ll2='ls -la'\n")
events, text, _, errors = run_session("nounset + ksh_arrays", hostile, [
    ("false\r", 1),
    ("ll2 /tmp >/dev/null\r", 1),
    ('echo "EARLY=$__early_nonce"\r', 1),
    ("sleep 2\r", 0.6),
    ("\x1a", 0.8),
    ("%1\r", 2.5),
])
ev = [(k, v) for _, k, v in events]
check(not errors, "no errors from the hooks under nounset + ksh_arrays")
check(("cmd", "false") in ev and ("end", "1") in ev, "marks still work under nounset + ksh_arrays")
check(ev.count(("cmd", "sleep 2")) == 2, "`%1` reports the resumed job under ksh_arrays")
i = ev.index(("cmd", "ll2 /tmp >/dev/null")) if ("cmd", "ll2 /tmp >/dev/null") in ev else -1
# zsh normalises the expanded text ("> /dev/null", ";" becomes a newline), so compare the start.
check(i > 0 and ev[i - 1][0] == "exp" and ev[i - 1][1].startswith("ls -la /tmp"), "aliases are reported expanded (how `claude-auto` is recognised)")
check("EARLY=none" in text, "the user's .zshenv never sees the nonce")

sys.exit(1 if failures else 0)
