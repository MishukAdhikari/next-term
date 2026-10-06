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
    env = dict(os.environ, TERM="xterm-256color", ZDOTDIR=zdot, NEXTTERM_NONCE=NONCE,
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
        if kind in ("cmd", "cwd") and val:
            val = base64.b64decode(val).decode()
        events.append((nonce, kind, val))
    print(f"[{label}] events:", [(k, v) for _, k, v in events])
    return events, text, zdot

# 1. The user's own config.
events, text, zdot = run_session("user config", os.environ.get("ZDOTDIR", ""), [
    ("sleep 0.3; false\r", 1.5),
    ("cd /tmp\r", 1),
    ('echo "ZD=${ZDOTDIR:-unset} HOOK=$__nextterm_hooked NONCE_ENV=$(env | grep -c NEXTTERM_NONCE)"\r', 1.5),
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
check("ZD=" in text and zdot not in text, "user ZDOTDIR restored (ours never leaks into the session)")
check(ev.count(("cmd", "cd /tmp")) == 1, "each command reported once")
check(ev.count(("cmd", "sleep 3")) == 2 and ("cmd", "fg") not in ev, "`fg` reports the resumed job, not \"fg\"")

# 2. Hostile options in the user's config must not break the hooks or print errors.
hostile = tempfile.mkdtemp()
open(os.path.join(hostile, ".zshenv"), "w").write("setopt nounset ksh_arrays\n")
open(os.path.join(hostile, ".zshrc"), "w").write("setopt nounset ksh_arrays err_return\nPS1='$ '\n")
events, text, _ = run_session("nounset + ksh_arrays", hostile, [
    ("false\r", 1),
    ("sleep 2\r", 0.6),
    ("\x1a", 0.8),
    ("%1\r", 2.5),
])
ev = [(k, v) for _, k, v in events]
check("parameter not set" not in text and "__nextterm" not in text.replace("\x1b", ""), "no errors from the hooks")
check(("cmd", "false") in ev and ("end", "1") in ev, "marks still work under nounset + ksh_arrays")
check(ev.count(("cmd", "sleep 2")) == 2, "`%1` reports the resumed job under ksh_arrays")

sys.exit(1 if failures else 0)
