#!/usr/bin/env python3
"""Runs the shipped .zshenv, and Tab completion's hook beside it, in a real pty and checks the OSC marks
they emit.

Runs:
- the user's own zsh config (whatever this machine has), with Tab completion on;
- a hostile config (`setopt nounset ksh_arrays err_return`), with Tab completion on, which also drives
  Next Term's own engine path (no compinit there);
- zsh's completion system (`compinit -u -D` in a temp ZDOTDIR);
- Tab completion off: no completion mark at all, the other marks as before;
- once on zsh 5.8 (macOS 13's) when one is found (NT_ZSH58 or a few usual places), else skipped;
- the prefix through tmux with `extended-keys` and `user-keys`, when tmux is installed, else skipped;
- with NT_PLUGIN_DIR pointing at plugin checkouts (zsh-autocomplete, fzf-tab, zsh-autosuggestions,
  zsh-syntax-highlighting, zsh-vi-mode), the plugin matrix; local only.

This script plays Next Term's part: it sends the private keys (CompletionProtocol.frame) and reads the
marks, so the hook is tested as Next Term drives it.
"""
import base64, os, pty, re, select, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(ROOT, "Sources/NextTermCore/ShellIntegration.swift")).read()
script = src.split('zshenvScript = #"""\n', 1)[1].split('"""#', 1)[0]
# The completion hook, filled the way ZshCompletionScript.script fills it.
csrc = open(os.path.join(ROOT, "Sources/NextTermCore/ZshCompletionScript.swift")).read()
completion = csrc.split('template = #"""\n', 1)[1].split('"""#', 1)[0]
VALUES = dict(re.findall(r'\("(@NT_\w+@)", #"(.*?)"#\)', csrc))
for placeholder, value in VALUES.items():
    completion = completion.replace(placeholder, value)
NONCE = "0123456789abcdef0123456789abcdef"
PREFIX = b"\x1b[6973~"

failures = []
def check(cond, msg, detail=""):
    print(("PASS " if cond else "FAIL ") + msg + ("" if cond or not detail else " — " + detail))
    if not cond:
        failures.append(msg)

def skip(msg):
    print("SKIP " + msg)

check(VALUES and "@NT_" not in completion, "every placeholder in the completion hook is filled")
check(VALUES.get("@NT_PREFIX@") == "\\e[6973~", "the hook's prefix is CompletionProtocol.prefix")

# --- Next Term's side of the protocol (CompletionProtocol.frame and parse) ---

def escape(text):
    out = b""
    for byte in text.encode():
        out += bytes([byte]) if 0x21 <= byte <= 0x7E and byte not in b"\\;" else b"\\x%02x" % byte
    return out

def frame(kind, ident, fields=()):
    payload = b";".join(escape(f) for f in fields)
    return PREFIX + kind.encode() + b"%06d" % ident + b"%06d" % len(payload) + payload

def pdec(field):
    out, i, raw = b"", 0, field.encode("latin1")
    while i < len(raw):
        if raw[i:i + 1] == b"%" and i + 2 < len(raw) and re.match(rb"[0-9A-Fa-f]{2}", raw[i + 1:i + 3]):
            out += bytes([int(raw[i + 1:i + 3], 16)])
            i += 3
        else:
            out += raw[i:i + 1]
            i += 1
    return out.decode("utf-8", "replace")

def env_for(zdot, user_zdotdir, completion_on=True, extra=None):
    # The same variables Next Term sets for every shell (TerminalTab.environment).
    env = dict(os.environ, TERM="xterm-256color", COLORTERM="truecolor", TERM_PROGRAM="NextTerm",
               LANG=os.environ.get("LANG") or "en_US.UTF-8", ZDOTDIR=zdot, NEXTTERM_NONCE=NONCE,
               NEXTTERM_USER_ZDOTDIR=user_zdotdir)
    if completion_on:
        env["NEXTTERM_COMPLETION"] = "1"
    env.update(extra or {})
    return env

class Shell:
    """A zsh in a pty with the shipped integration, read as Next Term reads it."""
    def __init__(self, label, user_zdotdir, completion_on=True, cwd=None, zsh="/bin/zsh", extra_env=None, settle=4):
        self.label = label
        self.zdot = tempfile.mkdtemp()
        open(os.path.join(self.zdot, ".zshenv"), "w").write(script)
        open(os.path.join(self.zdot, "completion.zsh"), "w").write(completion)
        env = env_for(self.zdot, user_zdotdir, completion_on, extra_env)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd or os.path.expanduser("~"))
            os.execve(zsh, ["-zsh"], env)
        self.buf = b""
        self.read_for(settle)  # let the config (oh-my-zsh, p10k...) finish

    def read_for(self, seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.02)
            if r:
                try:
                    self.buf += os.read(self.fd, 65536)
                except OSError:
                    return

    def send(self, data, wait=0.0):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())
        if wait:
            self.read_for(wait)

    def text(self, since=0):
        return self.buf[since:].decode("utf-8", "replace")

    def marks(self, since=0):
        found = []
        for m in re.findall(r"\x1b\]6973;([^\x07]*)\x07", self.buf[since:].decode("latin1")):
            parts = m.split(";")
            found.append((parts[0], parts[1] if len(parts) > 1 else "", parts[2:]))
        return found

    def wait_mark(self, kind, since, timeout=3, pred=lambda fields: True):
        end = time.time() + timeout
        while True:
            for nonce, k, fields in self.marks(since):
                if k == kind and pred(fields):
                    return fields
            if time.time() > end:
                return None
            self.read_for(0.02)

    def screen(self, since=0):
        """What was drawn since `since`, without escape sequences."""
        t = self.text(since)
        t = re.sub(r"\x1b\][^\x07]*\x07", "", t)
        t = re.sub(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]", "", t)
        return re.sub(r"\x1b[()][0-9A-B]|\x1b[=>]", "", t)

    def line(self, since=0):
        """The last line as drawn, after zsh's redraws: carriage returns, backspaces, cursor moves and
        clears to the end of the line are applied."""
        text = re.sub(r"\x1b\][^\x07]*\x07", "", self.text(since))
        row, col, rows = [], 0, []
        for token in re.findall(r"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b.|.", text, re.S):
            if token == "\r":
                col = 0
            elif token == "\n":
                rows.append("".join(row))
                row, col = [], 0
            elif token == "\b":
                col = max(0, col - 1)
            elif token.startswith("\x1b["):
                n = int(re.sub(r"\D", "", token[2:-1]) or 1) if token[-1] in "CD" else 0
                if token[-1] == "K":
                    del row[col:]
                elif token[-1] == "D":
                    col = max(0, col - n)
                elif token[-1] == "C":
                    col += n
            elif token.startswith("\x1b") or token < " ":
                continue
            else:
                row += [" "] * (col - len(row))
                if col < len(row):
                    row[col] = token
                else:
                    row.append(token)
                col += 1
        return "".join(row).rstrip()

    def wait_line(self, since, pred, timeout=4):
        """Waits until the drawn line satisfies `pred` (a slow machine redraws late); returns the line."""
        end = time.time() + timeout
        while not pred(self.line(since)) and time.time() < end:
            self.read_for(0.05)
        return self.line(since)

    def close(self):
        try:
            os.write(self.fd, b"\x03exit\r")
            self.read_for(1)
        except OSError:
            pass

    def errors(self):
        """Error lines that point at our script or our functions (not at /etc/zshrc and friends)."""
        return [l for l in re.sub(r"\x1b\][^\x07]*\x07", "", self.text()).splitlines()
                if (self.zdot in l or "__nextterm" in l) and ("not set" in l or "error" in l.lower() or "not found" in l
                                                             or "bad " in l or "no such" in l.lower())]

def drawn(shell, since, text):
    """The line as drawn ends with `text`, within a few seconds."""
    return shell.wait_line(since, lambda line: line.endswith(text)).endswith(text)

def arms(shell, since=0):
    return [f for _, k, f in shell.marks(since) if k == "arm"]

def tab_key(shell, ident, wait=0.6):
    """Sends the private Tab key; returns the offset where its marks start."""
    start = len(shell.buf)
    shell.send(frame("t", ident), wait)
    return start

def bindings(shell, keymaps=("main", "viins")):
    start = len(shell.buf)
    shell.send("".join(f"bindkey -M {k} '^I'; " for k in keymaps) + "\r", 1)
    return re.findall(r'"\^I" (\S+)', shell.screen(start))

def legacy_events(shell):
    events = []
    for nonce, kind, fields in shell.marks():
        val = ";".join(fields)
        if kind == "cwd" and val:
            val = base64.b64decode(val).decode()
        elif kind == "cmd":
            typed, _, expanded = val.partition(";")
            val = base64.b64decode(typed).decode()
            events.append((nonce, "exp", base64.b64decode(expanded).decode() if expanded else ""))
        elif kind == "jobs":
            count, _, listing = val.partition(";")
            val = count + ":" + (base64.b64decode(listing).decode() if listing else "")
        elif kind in ("arm", "tab", "comp", "done", "line"):
            continue
        events.append((nonce, kind, val))
    return events

def run_session(label, user_zdotdir, steps, completion_on=True):
    shell = Shell(label, user_zdotdir, completion_on)
    for keys, wait in steps:
        shell.send(keys, wait)
    shell.close()
    text = shell.text()
    events = legacy_events(shell)
    print(f"[{label}] events:", [(k, v) for _, k, v in events])
    assert len(text) > 200, "no session output captured: the checks below would pass vacuously"
    errors = shell.errors()
    for l in errors:
        print("  hook error:", l.strip()[:200])
    if os.environ.get("NT_DUMP"):  # NT_DUMP=1 saves each session's raw output, for debugging
        path = os.path.join(tempfile.gettempdir(), f"nextterm-zsh-{label.split()[0]}.txt")
        open(path, "w").write(text)
        print("  session saved to", path)
    return events, text, shell.zdot, errors, shell

# 1. The user's own config.
events, text, zdot, errors, user = run_session("user config", os.environ.get("ZDOTDIR", ""), [
    ("sleep 0.3; false\r", 1.5),
    ("cd /tmp\r", 1),
    ('echo "ZD=${ZDOTDIR:-unset} HOOK=$__nextterm_hooked NONCE_ENV=$(env | grep -c NEXTTERM_NONCE) EARLY=$__early_nonce COMP_ENV=$(env | grep -c NEXTTERM_COMPLETION)"\r', 1.5),
    ("sleep 3\r", 0.6),
    ("\x1a", 0.8),  # Ctrl-Z
    ("fg\r", 3.5),
])
ev = [(k, v) for _, k, v in events]
check(all(n == NONCE for n, _, _ in user.marks()) and events, "every mark carries the tab's nonce")
check(("cmd", "sleep 0.3; false") in ev, "preexec reports the command line")
i = ev.index(("cmd", "sleep 0.3; false")) if ("cmd", "sleep 0.3; false") in ev else -1
check(i >= 0 and ("end", "1") in ev[i:], "precmd reports exit status 1 after it")
check(("cwd", "/tmp") in ev, "precmd reports the new directory")
check("HOOK=1" in text and "NONCE_ENV=0" in text, "hooks active, nonce not in the environment of child processes")
check("COMP_ENV=0" in text, "nor the completion switch")
check(("jobs", "1:sleep 3 (suspended)") in ev, "precmd reports a suspended job")
suspended = ev.index(("jobs", "1:sleep 3 (suspended)")) if ("jobs", "1:sleep 3 (suspended)") in ev else None
check(suspended is not None and ("jobs", "0:") in ev[suspended + 1:], "and its end after `fg`")
check("ZD=" in text and zdot not in text.replace(f"{zdot}/.zshenv:", "").replace(f"{zdot}/completion.zsh:", ""),
      "user ZDOTDIR restored (ours never leaks into the session)")
check(not errors, "no errors from the hooks with the user's config")
check(ev.count(("cmd", "cd /tmp")) == 1, "each command reported once")
check(ev.count(("cmd", "sleep 3")) == 2 and ("cmd", "fg") not in ev, "`fg` reports the resumed job, not \"fg\"")
user_arms = arms(user)
check(len(user_arms) >= 5, "an `arm` mark at each prompt with the user's config", f"{len(user_arms)} arms")

# 2. Hostile options in the user's config must not break the hooks or print errors.
hostile = tempfile.mkdtemp()
# The user's .zshenv records whether it can see the nonce: it must not.
open(os.path.join(hostile, ".zshenv"), "w").write('setopt nounset ksh_arrays\ntypeset -g __early_nonce="${NEXTTERM_NONCE-none}"\n')
open(os.path.join(hostile, ".zshrc"), "w").write("setopt nounset ksh_arrays err_return\nPS1='$ '\nalias ll2='ls -la'\n")
events, text, _, errors, _ = run_session("nounset + ksh_arrays", hostile, [
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

# 3. Tab completion off: no completion mark, no binding, the other marks as before.
off = Shell("completion off", hostile, completion_on=False)
off.send("false\r", 1)
off.send("cd /tmp\r", 1)
off.send(frame("t", 1), 0.5)
off_kinds = {k for _, k, _ in off.marks()}
check({"end", "cwd", "cmd"} <= off_kinds and not off_kinds & {"arm", "tab", "comp", "done", "line"},
      "with Tab completion off, no completion mark and the others as before", str(sorted(off_kinds)))
off.close()

# 4. Next Term's own engine: the hostile config has no compinit.
tree = tempfile.mkdtemp()
for d in ("Sources", "Resources", "Tests", "My Fo'lder $x", "café"):
    os.mkdir(os.path.join(tree, d))
open(os.path.join(tree, "Sourcery.txt"), "w").close()

def engine_checks(label, user_zdotdir, zsh="/bin/zsh"):
    sh = Shell(label, user_zdotdir, cwd=tree, zsh=zsh)
    a = arms(sh)
    check(len(a) >= 1 and a[-1][1:3] in (["main", "start"], ["emacs", "start"]) and a[-1][3] == "1",
          f"[{label}] `arm` at the prompt: keymap, context, the private key bound", str(a[-1:] if a else "none"))
    check(a and a[-1][4] == "0", f"[{label}] and no completion system loaded", str(a[-1:]))
    check(not sh.marks(0) or all(n == NONCE for n, _, _ in sh.marks()), f"[{label}] completion marks carry the nonce")

    # The private Tab key on `ls /Sys`: one `tab` mark with that LBUFFER and its words.
    start = len(sh.buf)
    sh.send("ls /Sys", 0.3)
    tab_key(sh, 1, 0.05)
    tab = sh.wait_mark("tab", start, 1)
    check(tab is not None and tab[0] == "000001" and pdec(tab[2]) == "ls /Sys", f"[{label}] the private Tab key reports the line",
          str(tab))
    if tab:
        check([pdec(w) for w in tab[5].split(" ")] == ["ls", "/Sys"] and pdec(tab[6]) == "/Sys" and pdec(tab[1]) == os.path.realpath(tree),
              f"[{label}] with zsh's words, the word and the folder", str(tab))
    # No answer: `done` (native) for that id, then zsh's own Tab after about 150 ms.
    done = sh.wait_mark("done", start, 1)
    check(done == ["000001", "native"], f"[{label}] no answer: done native", str(done))
    sh.read_for(0.4)
    check(drawn(sh, start, "ls /System/"), f"[{label}] and zsh's own Tab completes it", repr(sh.line(start)))
    sh.send("\x03", 0.4)

    # A scripted insert changes the word.
    start = len(sh.buf)
    sh.send("cd Te", 0.3)
    tab_key(sh, 2, 0.05)
    if sh.wait_mark("tab", start, 1):
        sh.send(frame("a", 2, ["i", "Tests/"]), 0.4)
    check("cd Tests/" in sh.screen(start), f"[{label}] an `insert` answer replaces the word", repr(sh.screen(start)[-60:]))
    sh.send("\x03", 0.4)

    # A scripted native: zsh's own completion.
    start = len(sh.buf)
    sh.send("ls /Syst", 0.3)
    tab_key(sh, 3, 0.05)
    if sh.wait_mark("tab", start, 1):
        sh.send(frame("a", 3, ["n"]), 0.5)
    check(drawn(sh, start, "ls /System/") and sh.wait_mark("done", start, 0.1) is None,
          f"[{label}] a `native` answer runs zsh's own Tab", repr(sh.line(start)))
    sh.send("\x03", 0.4)

    # A scripted open: one `line` mark at once; typing reports the word; take replaces it; a stale take does nothing.
    start = len(sh.buf)
    sh.send("cd So", 0.3)
    tab_key(sh, 4, 0.05)
    if sh.wait_mark("tab", start, 1):
        sh.send(frame("a", 4, ["o"]), 0.3)
    lines = [f for _, k, f in sh.marks(start) if k == "line"]
    check(lines == [["000004", "0", "So", "So"]], f"[{label}] an `open` answer gives one `line` mark at once", str(lines))
    sh.send("u", 0.3)
    lines = [f for _, k, f in sh.marks(start) if k == "line"]
    check(lines[-1:] == [["000004", "0", "Sou", "Sou"]], f"[{label}] typing reports the word now", str(lines))
    mark = len(sh.buf)
    sh.send(frame("k", 3, ["w", "Sou", "Nope/"]), 0.3)
    check("Nope" not in sh.screen(mark), f"[{label}] a stale-id take changes nothing", repr(sh.screen(mark)))
    sh.send(frame("k", 4, ["w", "Sou", "Sources/"]), 0.4)
    check("cd Sources/" in sh.screen(start), f"[{label}] `take` replaces the word", repr(sh.screen(start)[-60:]))
    before = len(sh.marks(start))
    sh.send("x", 0.3)
    check(not [k for _, k, _ in sh.marks(start)[before:] if k == "line"], f"[{label}] after the take, typing sends no `line` mark")
    sh.send("\x03", 0.4)

    # An open list: the cursor leaving the word reports it once and stops.
    start = len(sh.buf)
    sh.send("ls Re", 0.3)
    tab_key(sh, 5, 0.05)
    if sh.wait_mark("tab", start, 1):
        sh.send(frame("a", 5, ["o"]), 0.3)
    sh.send(" ", 0.3)
    sh.send("x", 0.3)
    lines = [f for _, k, f in sh.marks(start) if k == "line"]
    check(lines[-1:] == [["000005", "1"]] and len(lines) == 2, f"[{label}] a blank leaves the word: reported once, then quiet", str(lines))
    sh.send("\x03", 0.4)

    # A take whose word no longer matches beeps and changes nothing.
    start = len(sh.buf)
    sh.send("ls Re", 0.3)
    tab_key(sh, 6, 0.05)
    if sh.wait_mark("tab", start, 1):
        sh.send(frame("a", 6, ["o"]), 0.3)
    sh.send(frame("k", 6, ["w", "Rx", "Resources/"]), 0.3)
    check("Resources/" not in sh.screen(start), f"[{label}] a take for a word the line no longer has does nothing")
    sh.send("\x03", 0.4)

    # The close key: no more reports.
    start = len(sh.buf)
    sh.send("ls Te", 0.3)
    tab_key(sh, 7, 0.05)
    if sh.wait_mark("tab", start, 1):
        sh.send(frame("a", 7, ["o"]), 0.3)
    sh.send(frame("k", 7, ["c"]), 0.2)
    before = len(sh.marks(start))
    sh.send("s", 0.3)
    check(not [k for _, k, _ in sh.marks(start)[before:] if k == "line"], f"[{label}] after the close key, typing sends no `line` mark")
    sh.send("\x03", 0.4)

    # With no list open, typing sends no completion mark at all.
    start = len(sh.buf)
    sh.send("echo hello there", 0.4)
    check(not [k for _, k, _ in sh.marks(start) if k in ("line", "tab", "comp", "done")],
          f"[{label}] with no list open, typing sends no mark")
    sh.send("\x03", 0.4)

    # Late answers are consumed: no junk on the line, and a late open sends no `line`.
    start = len(sh.buf)
    sh.send("echo late", 0.2)
    tab_key(sh, 8, 0.4)
    sh.send(frame("a", 8, ["o"]), 0.3)
    sh.send(frame("a", 8, ["i", "JUNK"]), 0.3)
    shown = sh.screen(start)
    check("6973" not in shown and "JUNK" not in shown and not [k for _, k, _ in sh.marks(start) if k == "line"],
          f"[{label}] late answers are read and dropped", repr(shown[-80:]))
    sh.send("\x03", 0.4)

    # Stray bytes during the wait go back to the line, after zsh's own Tab.
    start = len(sh.buf)
    sh.send("echo /Syst", 0.2)
    sh.send(frame("t", 9) + b"ab", 0.6)
    done = sh.wait_mark("done", start, 0.5)
    check(done == ["000009", "native"] and drawn(sh, start, "echo /System/ab"),
          f"[{label}] stray bytes during the wait go back to the line, after zsh's own Tab", repr(sh.line(start)))
    sh.send("\x03", 0.4)

    # Step backs before asking: only blanks before the cursor, the cursor inside a word, a word with $(, a here-doc.
    for case, keys, expect in [
        ("only blanks", "   ", None),
        ("cursor inside a word", "ls Sources\x1b[D\x1b[D", None),
        ("a $( word", "ls $(echo So", None),
        ("a backtick word", "ls `echo", None),
    ]:
        start = len(sh.buf)
        sh.send(keys, 0.3)
        tab_key(sh, 10, 0.4)
        kinds = [k for _, k, _ in sh.marks(start)]
        check("tab" not in kinds and ["000010", "native"] in [f for _, k, f in sh.marks(start) if k == "done"],
              f"[{label}] steps back before asking: {case}", str(kinds))
        sh.send("\x03", 0.4)
    start = len(sh.buf)
    sh.send("cat <<EOF\r", 0.3)
    sh.send("ab", 0.2)
    tab_key(sh, 11, 0.4)
    kinds = [k for _, k, _ in sh.marks(start)]
    check("tab" not in kinds, f"[{label}] steps back inside a here-document", str(kinds))
    sh.send("\x03", 0.4)

    # A `\` continuation: PREBUFFER is sent, and the words include the first line's.
    start = len(sh.buf)
    sh.send("ls \\\r", 0.3)
    sh.send("Sou", 0.2)
    tab_key(sh, 12, 0.05)
    tab = sh.wait_mark("tab", start, 1)
    check(tab is not None and pdec(tab[4]).startswith("ls ") and [pdec(w) for w in tab[5].split(" ")][-1] == "Sou",
          f"[{label}] a continuation line sends PREBUFFER and the words", str(tab))
    sh.read_for(0.3)
    sh.send("\x03", 0.4)

    # A combining accent round-trips (NFD bytes as typed).
    start = len(sh.buf)
    word = "cafe\u0301"
    sh.send("echo " + word, 0.3)
    tab_key(sh, 13, 0.05)
    tab = sh.wait_mark("tab", start, 1)
    check(tab is not None and pdec(tab[2]) == "echo " + word, f"[{label}] LBUFFER bytes round-trip (a combining accent)", str(tab))
    sh.read_for(0.3)
    sh.send("\x03", 0.4)

    # `~/` is resolved by parameter lookup only.
    start = len(sh.buf)
    sh.send("ls ~/", 0.3)
    tab_key(sh, 14, 0.05)
    tab = sh.wait_mark("tab", start, 1)
    check(tab is not None and pdec(tab[8]) == "~/" and pdec(tab[9]) == os.path.expanduser("~") + "/",
          f"[{label}] a `~/` head is sent resolved", str(tab))
    sh.read_for(0.3)
    sh.send("\x03", 0.4)

    # A line report costs under 1 ms (zsh's own clock).
    start = len(sh.buf)
    sh.send(" __nt_t=$EPOCHREALTIME; for i in {1..200}; do __nextterm_copen=000099 __nextterm_cbase='cd ' __nextterm_crbuf= "
            "LBUFFER='cd Sou' RBUFFER= __nextterm_cline force; done >/dev/null; __nextterm_cclose; "
            "print \"PER_LINE=$(( (EPOCHREALTIME - __nt_t) * 1000 / 200 ))\"\r", 3)
    per = re.search(r"PER_LINE=([0-9.]+)", sh.screen(start))
    check(per is not None and float(per.group(1)) < 1.0, f"[{label}] a `line` report costs under 1 ms",
          per.group(1) + " ms" if per else "not measured")

    # The vi keymaps: `arm` follows zle-keymap-select; in vicmd the key leaves no junk.
    start = len(sh.buf)
    sh.send("bindkey -v\r", 0.5)
    sh.send("echo vi", 0.2)
    sh.send("\x1b", 0.6)
    a = arms(sh, start)
    check(a and a[-1][1] == "vicmd", f"[{label}] vi: `arm` follows the keymap (vicmd)", str(a[-2:]))
    mark = len(sh.buf)
    sh.send(frame("t", 15), 0.4)
    check("6973" not in sh.screen(mark) and ["000015", "native"] in [f for _, k, f in sh.marks(mark) if k == "done"],
          f"[{label}] vi: the key in vicmd steps back and leaves no junk", repr(sh.screen(mark)))
    sh.send("i", 0.4)
    a = arms(sh, mark)
    check(a and a[-1][1] in ("viins", "main"), f"[{label}] vi: back in insert mode it arms again", str(a[-1:]))
    sh.send("\x03", 0.3)
    sh.send("bindkey -e\r", 0.5)

    # After `exec zsh`, no `arm` mark appears (the new shell has no integration).
    start = len(sh.buf)
    sh.send("exec /bin/zsh -f\r", 1)
    sh.send("echo after\r", 0.5)
    check(not arms(sh, start + 30), f"[{label}] after `exec zsh`, no `arm` mark", str(arms(sh, start)))
    errors = sh.errors()
    for l in errors:
        print("  hook error:", l.strip()[:200])
    check(not errors, f"[{label}] no errors from the completion hook")
    check(NONCE not in sh.screen(), f"[{label}] the nonce never shows")
    sh.close()
    return sh

engine_checks("engine, hostile options", hostile)

# 5. ^I keeps the user's binding (KTD2): the same before and after the hook loads.
plain = Shell("bindings without the hook", hostile, completion_on=False)
before = bindings(plain)
plain.close()
hooked = Shell("bindings with the hook", hostile)
after = bindings(hooked)
check(before and before == after, "`bindkey '^I'` in main and viins is the same with the hook loaded", f"{before} vs {after}")
hooked.close()

# 6. A plugin that replaces zle-line-init in its own precmd (as zsh-vi-mode does): `arm` comes back.
replacer = tempfile.mkdtemp()
open(os.path.join(replacer, ".zshrc"), "w").write(
    "PS1='$ '\n__mine() { zle -N zle-line-init __mine_init }\n__mine_init() { : }\nprecmd_functions+=(__mine)\n")
sh = Shell("a plugin replaces zle-line-init", replacer)
sh.send("true\r", 0.6)
start = len(sh.buf)
sh.send("true\r", 0.6)
check(arms(sh, start), "a plugin that replaces zle-line-init in its precmd: `arm` comes back at the next prompt", str(arms(sh, start)))
sh.close()

# 7. zsh's completion system loaded: its own Tab answers the private key, for now.
compdot = tempfile.mkdtemp()
open(os.path.join(compdot, ".zshrc"), "w").write(
    "PS1='$ '\nautoload -Uz compinit && compinit -u -D\nzstyle ':completion:*' menu select\nzmodload zsh/complist\n")
sh = Shell("zsh's completion system", compdot, cwd=tree)
a = arms(sh)
check(a and a[-1][4] == "1", "[zsh's completion system] `arm` says zsh's completion system is loaded", str(a[-1:]))
start = len(sh.buf)
sh.send("cd Te", 0.3)
tab_key(sh, 21, 0.3)
check(["000021", "native"] in [f for _, k, f in sh.marks(start) if k == "done"] and drawn(sh, start, "cd Tests/"),
      "[zsh's completion system] the private Tab key: done native, then zsh's own Tab", repr(sh.line(start)))
check(not sh.errors(), "[zsh's completion system] no errors from the completion hook")
sh.close()

# 8. The user's own config, driven: whichever path it is on, Tab never leaves junk.
sh = Shell("user config, driven", os.environ.get("ZDOTDIR", ""), cwd=tree)
a = arms(sh)
if a:
    start = len(sh.buf)
    sh.send("cd ", 0.3)
    tab_key(sh, 31, 2)
    kinds = [k for _, k, _ in sh.marks(start)]
    if "tab" in kinds:
        sh.send(frame("a", 31, ["n"]), 0.5)
    elif "comp" in kinds:
        sh.send(frame("k", 31, ["c"]), 0.3)
    check("6973" not in sh.screen(start) and ("tab" in kinds or "comp" in kinds or "done" in kinds),
          "[user config] the private Tab key is answered by the hook and leaves no junk", str(kinds))
    sh.send("\x03", 0.4)
errors = sh.errors()
check(not errors, "[user config] no errors from the completion hook", str(errors[:2]))
sh.close()

# 9. zsh 5.8, macOS 13's version, when one is available.
zsh58 = next((p for p in [os.environ.get("NT_ZSH58", ""), "/opt/homebrew/opt/zsh@5.8/bin/zsh", "/usr/local/opt/zsh@5.8/bin/zsh"]
              if p and os.path.exists(p)), None)
if zsh58:
    engine_checks("engine, zsh 5.8", hostile, zsh=zsh58)
else:
    skip("zsh 5.8 (macOS 13's) not found; set NT_ZSH58 to its path to run the engine checks on it")

# 10. The prefix passes through Next Term's tmux with extended-keys and user-keys, so the constant can stay.
tmux = shutil.which("tmux")
if tmux:
    sock = f"nt-test-{os.getpid()}"
    conf = os.path.join(tempfile.mkdtemp(), "tmux.conf")
    out = os.path.join(tempfile.mkdtemp(), "keys")
    open(conf, "w").write('set -s extended-keys on\nset -s user-keys[0] "\\e[6973~"\n'
                          'bind -n User0 send-keys -H 1b 5b 36 39 37 33 7e\n')
    reader = f"stty raw -echo; head -c {len(frame('t', 1))} > {out}"
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(tmux, ["tmux", "-L", sock, "-f", conf, "new-session", reader], dict(os.environ, TERM="xterm-256color"))
    time.sleep(1.5)
    os.write(fd, frame("t", 1))
    time.sleep(1)
    got = open(out, "rb").read() if os.path.exists(out) else b""
    check(got == frame("t", 1), "the private key passes through tmux with extended-keys and user-keys", repr(got))
    subprocess.run([tmux, "-L", sock, "kill-server"], check=False)
else:
    skip("the prefix through tmux: tmux is not installed")

# 11. The plugin matrix, with real checkouts (opt-in, local only).
plugins = os.environ.get("NT_PLUGIN_DIR")
if plugins:
    def plugin_rc(*names, extra=""):
        d = tempfile.mkdtemp()
        # zsh-autocomplete runs compinit itself, and asks that nothing else does.
        lines = ["PS1='$ '"] + ([] if "zsh-autocomplete" in names else ["autoload -Uz compinit && compinit -u -D"])
        for name in names:
            path = os.path.join(plugins, name)
            files = [f for f in os.listdir(path) if f.endswith(".plugin.zsh")] if os.path.isdir(path) else []
            if files:
                lines.append(f"source {os.path.join(path, files[0])}")
            else:
                skip(f"plugin matrix: {name} is not in NT_PLUGIN_DIR")
        open(os.path.join(d, ".zshrc"), "w").write("\n".join(lines) + "\n" + extra)
        return d
    for name in ("zsh-autocomplete", "fzf-tab", "zsh-autosuggestions", "zsh-syntax-highlighting", "zsh-vi-mode"):
        if not os.path.isdir(os.path.join(plugins, name)):
            continue
        sh = Shell(f"plugin {name}", plugin_rc(name), cwd=tree, settle=5)
        sh.send("true\r", 1)
        a = arms(sh)
        check(a, f"[plugin {name}] `arm` arrives", str(a[-1:]))
        if a:
            print(f"  [{name}] ^I runs {pdec(a[-1][5])} ({pdec(a[-1][6])}), plugins: {pdec(a[-1][7])}")
            start = len(sh.buf)
            sh.send("ls ", 0.4)
            tab_key(sh, 41, 1)
            kinds = [k for _, k, _ in sh.marks(start)]
            check(a[-1][3] == "0" or "done" in kinds, f"[plugin {name}] answers the private key or fails closed", str(kinds))
            check("6973" not in sh.screen(start), f"[plugin {name}] no junk on the line")
        errors = sh.errors()
        check(not errors, f"[plugin {name}] no errors from the completion hook", str(errors[:2]))
        sh.close()
else:
    skip("the plugin matrix: set NT_PLUGIN_DIR to a folder of plugin checkouts to run it")

shutil.rmtree(tree, ignore_errors=True)
sys.exit(1 if failures else 0)
