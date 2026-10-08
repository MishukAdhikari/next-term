#!/usr/bin/env python3
"""Runs the shipped .zshenv, and Tab completion's hook beside it, in a real pty and checks the OSC marks
they emit.

Runs:
- the user's own zsh config (whatever this machine has), with Tab completion on;
- a hostile config (`setopt nounset ksh_arrays err_return`), with Tab completion on, which also drives
  Next Term's own engine path (no compinit there);
- zsh's completion system (`compinit -u -D` in a temp ZDOTDIR), with the user's options and hostile ones;
- Tab completion off: no completion mark at all, the other marks as before;
- once on zsh 5.8 (macOS 13's) when one is found (NT_ZSH58 or a few usual places), else skipped;
- the prefix through tmux with `extended-keys` and `user-keys`, when tmux is installed, else skipped;
- with NT_PLUGIN_DIR pointing at plugin checkouts (zsh-autocomplete, fzf-tab, zsh-autosuggestions,
  zsh-syntax-highlighting, zsh-vi-mode), the plugin matrix; local only;
- the hook as a server runs it (RemoteCompletionHook), started by its launch command under a fake home.

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
    def __init__(self, label, user_zdotdir, completion_on=True, cwd=None, zsh="/bin/zsh", extra_env=None, settle=4, early=None):
        self.label = label
        self.zdot = tempfile.mkdtemp()
        open(os.path.join(self.zdot, ".zshenv"), "w").write(script)
        open(os.path.join(self.zdot, "completion.zsh"), "w").write(completion)
        env = env_for(self.zdot, user_zdotdir, completion_on, extra_env)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd or os.path.expanduser("~"))
            os.execve(zsh, ["-zsh"], env)
        if early:  # typed ahead, before the shell's first prompt
            os.write(self.fd, early)
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

def tab_key(shell, ident, wait=0.6, fields=()):
    """Sends the private Tab key (a server's with its wait as a field); returns the offset where its marks start."""
    start = len(shell.buf)
    shell.send(frame("t", ident, fields), wait)
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

# 7. zsh's completion system loaded: zsh's own matches, read by the hook and listed by Next Term.
def comp_list(shell, since, ident):
    """The `comp` marks for an id, put together: (total, [(text, description, kind)], stem, sizes of the marks)."""
    chunks, total, stem, sizes = {}, None, None, []
    for raw in re.findall(r"\x1b\]6973;([^\x07]*)\x07", shell.buf[since:].decode("latin1")):
        parts = raw.split(";")
        if len(parts) >= 9 and parts[1] == "comp" and parts[2] == "%06d" % ident:
            total, stem = int(parts[3]), (pdec(parts[6]), pdec(parts[7]))
            chunks[int(parts[4])] = parts[8]
            sizes.append(len(raw))
    items = []
    for number in sorted(chunks):
        for item in chunks[number].split(" ") if chunks[number] else []:
            text, dscr, group, kind = item.split(",")
            items.append((pdec(text), pdec(dscr), kind))
    return total, items, stem, sizes

def compsys_checks(label, rc_extra=""):
    compdot = tempfile.mkdtemp()
    open(os.path.join(compdot, ".zshrc"), "w").write(
        rc_extra + "PS1='$ '\nautoload -Uz compinit && compinit -u -D\nzstyle ':completion:*' menu select\nzmodload zsh/complist\n"
        "_ntprint() { print -n 'junk from a completer' >/dev/tty; compadd alpha beta }\ncompdef _ntprint ntprint\n")
    sh = Shell(label, compdot, cwd=tree)
    a = arms(sh)
    check(a and a[-1][4] == "1", f"[{label}] `arm` says zsh's completion system is loaded", str(a[-1:]))

    # One match goes in directly, quoted and finished by zsh.
    start = len(sh.buf)
    sh.send("cd Te", 0.3)
    tab_key(sh, 21, 0.5)
    check(["000021", "inserted"] in [f for _, k, f in sh.marks(start) if k == "done"] and drawn(sh, start, "cd Tests/"),
          f"[{label}] one match: zsh inserts it and reports done", repr(sh.line(start)))
    sh.send("\x03", 0.4)

    # No match: done native, then zsh's own Tab.
    start = len(sh.buf)
    sh.send("ls zzqq", 0.3)
    tab_key(sh, 22, 0.5)
    check(["000022", "native"] in [f for _, k, f in sh.marks(start) if k == "done"] and not comp_list(sh, start, 22)[1],
          f"[{label}] no match: done native, and no list", str([k for _, k, _ in sh.marks(start)]))
    sh.send("\x03", 0.4)

    # `cd ` lists folders only; the list opens with one `line` mark; `take` by index inserts zsh's quoting.
    start = len(sh.buf)
    sh.send("cd ", 0.3)
    tab_key(sh, 23, 0.6)
    total, items, stem, _ = comp_list(sh, start, 23)
    names = sorted(t.rstrip("/") for t, _, _ in items)
    check(names == sorted(["Sources", "Resources", "Tests", "My Fo'lder $x", "café"]),
          f"[{label}] `cd ` lists only the folders, from zsh", str(names))
    check(total == len(items) and all(k == "d" for _, _, k in items), f"[{label}] with the total and each one a folder", str(items))
    lines = [f for _, k, f in sh.marks(start) if k == "line"]
    check(lines == [["000023", "0", "", ""]], f"[{label}] the list opens with one `line` mark", str(lines))
    index = next((i + 1 for i, (t, _, _) in enumerate(items) if t.startswith("My Fo")), 0)
    sh.send(frame("k", 23, ["m", "", str(index)]), 0.5)
    check(drawn(sh, start, "cd My\\ Fo\\'lder\\ \\$x/"), f"[{label}] `take` by index: zsh quotes the name", repr(sh.line(start)))
    sh.send("\x03", 0.4)

    # Letters typed while the list is open, then the take: the word typed so far is replaced.
    start = len(sh.buf)
    sh.send("cd ", 0.3)
    tab_key(sh, 24, 0.6)
    total, items, _, _ = comp_list(sh, start, 24)
    sh.send("Sou", 0.4)
    lines = [f for _, k, f in sh.marks(start) if k == "line"]
    check(lines[-1:] == [["000024", "0", "Sou", "Sou"]], f"[{label}] typing reports the word", str(lines))
    index = next((i + 1 for i, (t, _, _) in enumerate(items) if t.startswith("Sources")), 0)
    mark = len(sh.buf)
    sh.send(frame("k", 23, ["m", "Sou", str(index)]), 0.4)
    check("Sources" not in sh.screen(mark), f"[{label}] a stale id changes nothing", repr(sh.screen(mark)))
    sh.send(frame("k", 24, ["m", "Sou", str(index)]), 0.5)
    check(drawn(sh, start, "cd Sources/"), f"[{label}] the take replaces the word typed since", repr(sh.line(start)))
    sh.send("\x03", 0.4)
    start = len(sh.buf)
    sh.send("cd ", 0.3)
    tab_key(sh, 30, 0.6)
    sh.send(frame("k", 30, ["m", "", "99"]), 0.4)
    check(drawn(sh, start, "cd") and "Sources" not in sh.screen(start + 1), f"[{label}] a stale index changes nothing",
          repr(sh.line(start)))
    sh.send("\x03", 0.4)

    # git checkout lists the branches of a temp repo (AE8), and take inserts one, a space after it.
    repo = tempfile.mkdtemp()
    git = ["git", "-C", repo, "-c", "user.email=t@example.com", "-c", "user.name=t"]
    subprocess.run(["git", "init", "-q", "-b", "main", repo], check=True)
    subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "first"], check=True)
    subprocess.run(git + ["branch", "feature/x"], check=True)
    sh.send(f"cd {repo}\r", 0.6)
    start = len(sh.buf)
    sh.send("git checkout ", 0.3)
    tab_key(sh, 25, 3)
    total, items, _, _ = comp_list(sh, start, 25)
    texts = [t for t, _, _ in items]
    check("main" in texts and "feature/x" in texts, f"[{label}] `git checkout ` lists the branches", str(texts[:12]))
    check(any(d for _, d, _ in items), f"[{label}] with zsh's descriptions", str(items[:6]))
    check(len(texts) == len(set(texts)), f"[{label}] each match once", str(texts))
    sh.send(frame("k", 25, ["m", "", str(texts.index("main") + 1 if "main" in texts else 0)]), 0.5)
    sh.send("X", 0.3)
    check(drawn(sh, start, "git checkout main X"), f"[{label}] take gives `git checkout main `, a space after it", repr(sh.line(start)))
    sh.send("\x03", 0.4)
    sh.send(f"cd {tree}\r", 0.6)
    shutil.rmtree(repo, ignore_errors=True)

    # A completer that prints to the terminal doesn't break the marks.
    start = len(sh.buf)
    sh.send("ntprint ", 0.3)
    tab_key(sh, 26, 0.6)
    total, items, _, _ = comp_list(sh, start, 26)
    check([t for t, _, _ in items] == ["alpha", "beta"], f"[{label}] a completer that prints: the marks still read", str(items))
    sh.send(frame("k", 26, ["c"]), 0.3)
    sh.send("\x03", 0.4)

    # A nested folder: the stem is the folder part, and the names are what follows it.
    start = len(sh.buf)
    sh.send("ls Sources/", 0.3)
    tab_key(sh, 27, 0.6)
    total, items, stem, _ = comp_list(sh, start, 27)
    check(stem == ("Sources/", "Sources/") and sorted(t.rstrip("/") for t, _, _ in items) == ["inner", "insect", "main.swift"],
          f"[{label}] in a nested folder the stem is the folder", f"{stem} {items}")
    sh.send(frame("k", 27, ["c"]), 0.3)
    sh.send("\x03", 0.4)

    # 3,000 matches: the total, then 2,000 in marks under 64 KiB.
    start = len(sh.buf)
    sh.send(f"ls {many}/", 0.3)
    tab_key(sh, 28, 4)
    total, items, _, sizes = comp_list(sh, start, 28)
    check(total == 3000 and len(items) == 2000 and len(sizes) > 1 and max(sizes) < 65536 and items[0][0].startswith("a-file"),
          f"[{label}] 3,000 matches: a total of 3,000, 2,000 sent in marks under 64 KiB", f"{total} {len(items)} {sizes}")
    sh.send(frame("k", 28, ["c"]), 0.3)
    sh.send("\x03", 0.4)

    # The `n` key: Next Term can't show the list, so zsh's own Tab runs, and the line reports stop.
    start = len(sh.buf)
    sh.send("cd ", 0.3)
    tab_key(sh, 29, 0.6)
    sh.send(frame("n", 29), 0.8)
    shown = sh.screen(start)
    before = len(sh.marks(start))
    check("Resources" in shown and "Tests" in shown, f"[{label}] the `n` key: zsh's own Tab lists", repr(shown[-200:]))
    sh.send("\x03\x03", 0.4)
    check(not [k for _, k, _ in sh.marks(start)[before:] if k == "line"], f"[{label}] and the line reports stop")

    errors = sh.errors()
    for l in errors:
        print("  hook error:", l.strip()[:200])
    check(not errors, f"[{label}] no errors from the completion hook")
    check("6973" not in sh.screen(), f"[{label}] no junk on the line")
    sh.close()

os.makedirs(os.path.join(tree, "Sources", "inner"))
os.makedirs(os.path.join(tree, "Sources", "insect"))
open(os.path.join(tree, "Sources", "main.swift"), "w").close()
many = tempfile.mkdtemp()
for i in range(3000):
    open(os.path.join(many, "a-file-with-a-name-long-enough-to-need-two-marks-%04d" % i), "w").close()
compsys_checks("zsh's completion system")
compsys_checks("zsh's completion system, hostile options", "setopt nounset ksh_arrays err_return\n")
shutil.rmtree(many, ignore_errors=True)

# 7b. The `config` key quiets and restores zsh-autocomplete's list as you type, in that shell only: a stand-in
# with its redraw hook (the real plugin runs in the matrix below).
quietdot = tempfile.mkdtemp()
open(os.path.join(quietdot, ".zshrc"), "w").write(
    "PS1='$ '\nautoload -Uz add-zle-hook-widget\n.autocomplete:async:complete() { : }\n"
    "add-zle-hook-widget line-pre-redraw .autocomplete:async:complete\n")
def tree_hash(folder):
    """Every file under `folder` with its bytes, to show nothing was written."""
    found = {}
    for base, _, files in os.walk(folder):
        for name in files:
            path = os.path.join(base, name)
            found[os.path.relpath(path, folder)] = open(path, "rb").read()
    return found
before = tree_hash(quietdot)
sh = Shell("quieting zsh-autocomplete", quietdot)
a = arms(sh)
check(a and "autocomplete" in pdec(a[-1][7]) and a[-1][8] == "0", "[quiet] `arm` names zsh-autocomplete, its list on", str(a[-1:]))
start = len(sh.buf)
sh.send(frame("c", 0, ["q1"]), 0.5)
a = arms(sh, start)
check(a and a[-1][8] == "1", "[quiet] the `config` key q1 takes its list off, and `arm` says so", str(a))
mark = len(sh.buf)
sh.send(frame("c", 0, ["q1"]), 0.5)
check(not arms(sh, mark), "[quiet] a config already in effect does nothing")
sh.send(" zstyle -g h zle-line-pre-redraw widgets; print -r -- HOOKS=${(j:,:)h}\r", 0.6)
check("autocomplete" not in (re.search(r"HOOKS=(\S*)", sh.screen(mark)) or [None, "autocomplete"])[1],
      "[quiet] its redraw hook is gone from this shell", sh.screen(mark)[-120:])
mark = len(sh.buf)
sh.send(frame("c", 0, ["q0"]), 0.5)
a = arms(sh, mark)
check(a and a[-1][8] == "0", "[quiet] q0 puts it back", str(a))
check("6973" not in sh.screen(start) and not sh.errors(), "[quiet] no junk and no errors")
sh.close()

# 7c. A tab started with its list off (NEXTTERM_COMPLETION=q, as Next Term starts it where its list answers Tab) has it
# off from its first prompt with no key, so a command typed ahead of that prompt reads nothing of Next Term's: `cat`
# below gets only what was typed after it.
sh = Shell("quiet from the start", quietdot, extra_env={"NEXTTERM_COMPLETION": "q"}, early=b"cat\r")
a = arms(sh)
check(a and a[0][8] == "1", "[quiet] a tab started with q has its list off at its first prompt, with no key", str(a[:1]))
start = len(sh.buf)
sh.send("typed\r", 0.5)
sh.send("\x04", 0.8)
check("typed" in sh.screen(start) and "6973" not in sh.screen() and not sh.errors(),
      "[quiet] and the command typed ahead of it reads nothing but what was typed", repr(sh.screen()[-120:]))
sh.close()
# A Tab key that says q1 quiets it too (a server's hook starts with it on), before its own report.
sh = Shell("quiet from a Tab", quietdot)
first = len(sh.buf)
sh.send("ls ", 0.3)
start = tab_key(sh, 51, 0.3, fields=["q1"])
sh.send(frame("a", 51, ["n"]), 0.5)
kinds = [(k, f[-1] if k == "arm" else "") for _, k, f in sh.marks(start)]
check(kinds[:1] == [("arm", "1")] and ("tab", "") in kinds, "[quiet] a Tab key with q1 takes its list off, then completes", str(kinds))
sh.send("\x03", 0.5)
sh.send("ls ", 0.3)
mark = tab_key(sh, 52, 0.3, fields=["q1"])
sh.send(frame("a", 52, ["n"]), 0.5)
check(not arms(sh, mark) and "tab" in [k for _, k, _ in sh.marks(mark)], "[quiet] and one already in effect sends no new `arm`")
check("6973" not in sh.screen(first) and not sh.errors(), "[quiet] no junk and no errors from a Tab key's q1")
sh.send("\x03", 0.5)
sh.close()

after = tree_hash(quietdot)
changed = [k for k in set(before) | set(after) if before.get(k) != after.get(k) and not k.startswith(".zsh_history")]
check(not changed, "[quiet] no file in the user's ZDOTDIR changed (AE4)", str(changed))

# 7d. fzf 0.30 and older list processes for `kill ` with no `**`: there the hook steps back, as for `**`, and fzf's
# widget runs. A stand-in with that rule (fzf's own in the plugin matrix, when NT_PLUGIN_DIR has it).
fzfdot = tempfile.mkdtemp()
open(os.path.join(fzfdot, ".zshrc"), "w").write(
    "PS1='$ '\nfzf-completion() {\n  local -a w=(${(z)LBUFFER})\n  local cmd=$w[1]\n"
    "  if [ \"$cmd\" = kill -a ${LBUFFER[-1]} = ' ' ]; then print -n FZF-KILL; fi\n  zle expand-or-complete\n}\n"
    "zle -N fzf-completion\nbindkey '^I' fzf-completion\n")
sh = Shell("fzf's kill", fzfdot, cwd=tree)
def tab_marks(shell, line, ident):
    mark = len(shell.buf)
    shell.send(line, 0.3)
    tab_key(shell, ident, 0.6)
    kinds = [k for _, k, _ in shell.marks(mark)]
    shell.send(frame("a", ident, ["n"]), 0.3)
    screen = shell.screen(mark)
    shell.send("\x03", 0.4)
    return kinds, screen
kinds, screen = tab_marks(sh, "kill ", 61)
check("done" in kinds and "tab" not in kinds and "FZF-KILL" in screen, "[fzf] `kill ` is fzf's where its widget lists processes with no `**`",
      str(kinds))
check("tab" in tab_marks(sh, "sudo kill ", 62)[0] and "tab" in tab_marks(sh, "ls ", 63)[0], "[fzf] `sudo kill ` and `ls ` are not")
# fzf 0.31 and later give `kill ` zsh's own Tab: Next Term's list answers it.
sh.send("fzf-completion() { zle expand-or-complete }\r", 0.5)
check("tab" in tab_marks(sh, "kill ", 64)[0], "[fzf] nor `kill ` where its widget has no such rule")
check(not sh.errors(), "[fzf] no errors from the hook")
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
    # fzf's own completion.zsh: `kill ` is fzf's only where its version lists processes with no `**` (0.30 and older).
    fzf_completion = os.path.join(plugins, "fzf", "shell", "completion.zsh")
    if os.path.exists(fzf_completion):
        d = tempfile.mkdtemp()
        open(os.path.join(d, ".zshrc"), "w").write(f"PS1='$ '\nautoload -Uz compinit && compinit -u -D\nsource {fzf_completion}\n")
        sh = Shell("plugin fzf", d, cwd=tree, settle=5)
        old_rule = "Kill completion" in open(fzf_completion).read()
        kinds, _ = tab_marks(sh, "kill ", 71)
        check(("comp" not in kinds and "done" in kinds) == old_rule, f"[plugin fzf] `kill ` is fzf's only with its old rule ({old_rule})", str(kinds))
        kinds, _ = tab_marks(sh, "vim **", 72)
        check("done" in kinds and "comp" not in kinds, "[plugin fzf] `vim **` is fzf's", str(kinds))
        check(not sh.errors(), "[plugin fzf] no errors from the completion hook")
        sh.close()
    else:
        skip("plugin matrix: fzf (shell/completion.zsh) is not in NT_PLUGIN_DIR")
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
            check(a[-1][3] == "0" or "done" in kinds or "comp" in kinds, f"[plugin {name}] answers the private key or fails closed", str(kinds))
            check("6973" not in sh.screen(start), f"[plugin {name}] no junk on the line")
            sh.send(frame("k", 41, ["c"]), 0.3)
            sh.send("\x03", 0.5)
        if a and name == "zsh-autocomplete":
            # Its list as you type, then quieted by the config key (only in this shell), then back.
            def lists(keys):
                mark = len(sh.buf)
                sh.send(keys, 2)
                shown = sh.screen(mark)
                sh.send("\x03", 0.5)
                return "Resources" in shown and "Tests" in shown
            check(lists("ls "), "[plugin zsh-autocomplete] lists as you type", "")
            mark = len(sh.buf)
            sh.send(frame("c", 0, ["q1"]), 0.8)
            q = arms(sh, mark)
            check(q and q[-1][8] == "1", "[plugin zsh-autocomplete] the config key quiets it", str(q[-1:]))
            check(not lists("ls "), "[plugin zsh-autocomplete] and its list no longer appears")
            mark = len(sh.buf)
            sh.send("cd ", 0.4)
            tab_key(sh, 42, 2)
            total, items, _, _ = comp_list(sh, mark, 42)
            check(items and all(k == "d" for _, _, k in items), "[plugin zsh-autocomplete] chosen against, Next Term's list gets zsh's folders",
                  str(items[:5]))
            sh.send(frame("k", 42, ["c"]), 0.3)
            sh.send("\x03", 0.5)
            mark = len(sh.buf)
            sh.send(frame("c", 0, ["q0"]), 0.8)
            q = arms(sh, mark)
            check(q and q[-1][8] == "0" and lists("ls "), "[plugin zsh-autocomplete] q0 brings its list back")
            # A tab started with it off (NEXTTERM_COMPLETION=q): off from the first prompt, with no key, though
            # zsh-autocomplete puts its hook in at its own first precmd.
            quiet = Shell("plugin zsh-autocomplete, started quiet", plugin_rc(name), cwd=tree, settle=5, extra_env={"NEXTTERM_COMPLETION": "q"})
            q = arms(quiet)
            check(q and q[0][8] == "1", "[plugin zsh-autocomplete] a tab started with q has it off from its first prompt", str(q[:1]))
            mark = len(quiet.buf)
            quiet.send("ls ", 2)
            shown = quiet.screen(mark)
            check(not ("Resources" in shown and "Tests" in shown) and not quiet.errors(), "[plugin zsh-autocomplete] and lists nothing as you type")
            quiet.close()
        if a and name == "fzf-tab":
            # Chosen against: the capture lists zsh's matches through fzf-tab's copy of the completion, and fzf
            # never starts.
            mark = len(sh.buf)
            sh.send("cd ", 0.4)
            tab_key(sh, 43, 2)
            total, items, _, _ = comp_list(sh, mark, 43)
            check(items and all(k == "d" for _, _, k in items), "[plugin fzf-tab] chosen against, the capture lists the folders", str(items[:5]))
            check(subprocess.run(["pgrep", "-x", "fzf"], capture_output=True).returncode != 0, "[plugin fzf-tab] and fzf never starts")
            sh.send(frame("k", 43, ["c"]), 0.3)
            sh.send("\x03", 0.5)
        if a and name in ("zsh-autosuggestions", "zsh-syntax-highlighting"):
            # The take works with widgets they wrap.
            mark = len(sh.buf)
            sh.send("cd ", 0.4)
            tab_key(sh, 44, 2)
            total, items, _, _ = comp_list(sh, mark, 44)
            index = next((i + 1 for i, (t, _, _) in enumerate(items) if t.startswith("Tests")), 0)
            sh.send(frame("k", 44, ["m", "", str(index)]), 0.6)
            check(drawn(sh, mark, "cd Tests/"), f"[plugin {name}] a take works beside it", repr(sh.line(mark)))
            sh.send("\x03", 0.5)
        errors = sh.errors()
        check(not errors, f"[plugin {name}] no errors from the completion hook", str(errors[:2]))
        sh.close()
else:
    skip("the plugin matrix: set NT_PLUGIN_DIR to a folder of plugin checkouts to run it")

# 11b. Suggest a Command's line: `k` with `l` replaces the whole line, one line or several, and runs nothing.
liner = Shell("suggest a command", hostile, cwd=tree)
mark = len(liner.buf)
liner.send("echo old", 0.3)
liner.send(frame("k", 0, ["l", "ls -la; touch PWNED-$(whoami)"]), 0.6)
check(drawn(liner, mark, "ls -la; touch PWNED-$(whoami)") and not os.path.exists(os.path.join(tree, "PWNED-" + os.environ.get("USER", ""))),
      "[suggest a command] the line is replaced, and nothing runs", repr(liner.line(mark)))
liner.send("\x03", 0.5)
mark = len(liner.buf)
liner.send(frame("k", 0, ["l", "cd /tmp\nls"]), 0.6)
liner.send('\r', 1)
check(any(k == "cmd" and base64.b64decode(f[0]).decode() == "cd /tmp\nls" for _, k, f in liner.marks(mark)),
      "[suggest a command] several lines go on as one edit, and run only with Return", str([k for _, k, _ in liner.marks(mark)]))
errors = liner.errors()
check(not errors, "[suggest a command] no errors from the hook", str(errors[:2]))
liner.close()

# 12. Tab completion's hook on a server (RemoteCompletionHook), started the way a tab's launch command starts it,
# under a fake home: completion marks only, with the host's nonce read from its file at each prompt, the wait
# for the round trip on the Tab key, tmux's passthrough inside Next Term's own tmux, and silence inside any other.
hsrc = open(os.path.join(ROOT, "Sources/NextTermCore/RemoteCompletionHook.swift")).read()
server_zshenv = hsrc.split('zshenv = #"""\n', 1)[1].split('"""#', 1)[0]
server_zshenv = server_zshenv.replace("@NT_FIRST_WAIT@", re.search(r'firstWait = "([0-9.]+)"', hsrc).group(1))
server_start = hsrc.split('start = #"""\n', 1)[1].split('"""#', 1)[0]
HOST_NONCE = "fedcba9876543210fedcba9876543210"

class ServerShell(Shell):
    """A server's login shell started by the hook's start command, as Next Term's tab script runs it."""
    def __init__(self, label, rc, tmux=None, settle=3):
        self.label = label
        self.home = tempfile.mkdtemp()
        self.zdot = os.path.join(self.home, ".cache/next-term/completion")
        os.makedirs(os.path.join(self.zdot, "zsh"))
        for name, text in (("completion.zsh", completion), ("zsh/.zshenv", server_zshenv), ("start", server_start)):
            open(os.path.join(self.zdot, name), "w").write(text)
        os.chmod(os.path.join(self.zdot, "start"), 0o700)
        open(os.path.join(self.zdot, "nonce"), "w").write(HOST_NONCE + "\n")
        open(os.path.join(self.home, ".zshrc"), "w").write(rc)
        env = {"HOME": self.home, "SHELL": "/bin/zsh", "TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
               "LANG": os.environ.get("LANG") or "en_US.UTF-8"}
        if tmux:
            env["TMUX"] = tmux
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(tree)
            os.execve("/bin/sh", ["sh", os.path.join(self.zdot, "start")], env)
        self.buf = b""
        self.read_for(settle)

for label, rc in (("server", "PS1='server$ '\n"), ("server, hostile", "setopt nounset ksh_arrays err_return\nPS1='server$ '\n")):
    sh = ServerShell(label, rc)
    a = arms(sh)
    check(a and all(n == HOST_NONCE for n, _, _ in sh.marks()), f"[{label}] the hook arms with the host's nonce, from its file", str(a[-1:]))
    sh.send("false\r", 0.8)
    sh.send("cd /tmp\r", 0.8)
    kinds = {k for _, k, _ in sh.marks()}
    check(kinds and not kinds & {"cmd", "end", "cwd", "jobs"}, f"[{label}] it sends completion marks only, never the commands run", str(sorted(kinds)))
    start = len(sh.buf)
    sh.send('echo "ZD=${ZDOTDIR:-unset} NONCE=${#__nextterm_nonce}"\r', 0.8)
    check("ZD=unset" in sh.screen(start) and "NONCE=32" in sh.screen(start), f"[{label}] the user's ZDOTDIR is back", repr(sh.screen(start)[-80:]))
    sh.send("cd " + tree + "\r", 0.8)
    # No answer: zsh's own Tab after the server's first wait (0.6 s); with `w200` on the Tab key, after 0.2 s.
    def no_answer(ident, fields=()):
        mark = len(sh.buf)
        sh.send("ls /Sys", 0.3)
        sent = time.time()
        tab_key(sh, ident, 0, fields)
        done = sh.wait_mark("done", mark, 2)
        took = time.time() - sent
        sh.send("\x03", 0.5)
        return done, took
    done, took = no_answer(11)
    check(done == ["000011", "native"] and took > 0.45, f"[{label}] with no answer, the server's hook waits 0.6 s", f"{done} {took:.2f} s")
    done, took = no_answer(12, ["w200"])
    check(done == ["000012", "native"] and took < 0.45, f"[{label}] and `w200` on the Tab key makes it 0.2 s", f"{done} {took:.2f} s")
    # A `w` on a config key is no longer read: the wait comes only with a Tab.
    sh.send(frame("c", 0, ["w150"]), 0.3)
    done, took = no_answer(13, ["w600"])
    check(done == ["000013", "native"] and took > 0.45, f"[{label}] a later Tab's own wait holds", f"{done} {took:.2f} s")
    # A new nonce in the file (Remove, then Allow again): the next prompt's marks carry it.
    open(os.path.join(sh.zdot, "nonce"), "w").write("ab" * 16 + "\n")
    mark = len(sh.buf)
    sh.send("\r", 0.8)
    check(any(n == "ab" * 16 for n, k, _ in sh.marks(mark) if k == "arm"), f"[{label}] a new nonce is read at the next prompt")
    errors = sh.errors()
    check(not errors, f"[{label}] no errors from the server's hook", str(errors[:2]))
    sh.close()
    shutil.rmtree(sh.home, ignore_errors=True)

wrapped = ServerShell("server in Next Term's tmux", "PS1='server$ '\n", tmux="/tmp/tmux-501/nextterm,123,0")
check(b"\x1bPtmux;\x1b\x1b]6973;" + HOST_NONCE.encode() + b";arm;" in wrapped.buf,
      "[server] inside Next Term's tmux, marks go through tmux's passthrough")
wrapped.close()
shutil.rmtree(wrapped.home, ignore_errors=True)
other = ServerShell("server in another tmux", "PS1='server$ '\n", tmux="/tmp/tmux-501/default,123,0")
other.send("true\r", 0.6)
check(not other.marks() and b"6973" not in other.buf, "[server] inside the user's own tmux, the hook stays silent")
other.close()
shutil.rmtree(other.home, ignore_errors=True)

shutil.rmtree(tree, ignore_errors=True)
sys.exit(1 if failures else 0)
