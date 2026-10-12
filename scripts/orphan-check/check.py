#!/usr/bin/env python3
"""What keeps running after Next Term quits, closes its tabs, or is force quit (scripts/orphan-check.sh runs this).

A test copy of a release build runs with its own settings domain and a temporary home (its MCP socket, rc files
and agent folders stay out of yours), with shim.dylib injected. Fourteen tabs run the programs in project/ through
the copy's own MCP socket, then the app is ended three ways: Quit (as ⌘Q), closing every tab, and SIGKILL. Each
time, the test processes still alive 4 s later are listed.

Pass: Quit and closing every tab leave exactly the deliberate survivors (a python ignoring SIGHUP, a nohup'd sleep,
a disowned sleep, the two processes of a double fork, a GNU screen session with its window, and a sleep disowned
in `script`'s own shell), the app exits within 2 s of the quit request, and SIGKILL leaves no orphaned login shell.
Without /usr/bin/screen the screen tab is left out.
Usage: check.py <folder with the release NextTerm binary> <shim.dylib>
"""
import json, os, pwd, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
DOMAIN = 'me.mishuk.nextterm.orphancheck'

TABS = [
    ('A npm-run-dev', 'npm run dev'),
    ('B hup-ignored', 'python3 ntmark-hupign.py'),
    ('C bg-jobs', 'node ntmark-nextserver.js bgjob > bg.out 2>&1 & sleep 7771 &'),
    ('D nohup', 'nohup node ntmark-nextserver.js nohup > nohup.out 2>&1 & nohup sleep 7772 > /dev/null 2>&1 &'),
    ('E disown', 'sleep 7773 & disown'),
    ('F double-fork', '( sleep 7774 & ) ; ( node ntmark-nextserver.js dfork > dfork.out 2>&1 & )'),
    ('G own-pgrp', "sh -c 'python3 ntmark-setpgid.py & wait'"),
    ('H agent', 'node ntmark-agent.js'),
    ('I agent-cleanup', 'node ntmark-agent.js cleanup'),
    ('J stopped', 'sleep 7775'),
    ('K hup-node', 'node ntmark-hupnode.js'),
    ('L dispositions', "perl -e 'print join(\" \", map { \"$_=\" . ($SIG{$_} // \"DEFAULT\") } qw(HUP INT TERM PIPE CHLD)), \"\\\\n\"' > sigs.txt"),
]
# M: GNU screen attached in front: closing the tab detaches it, as in every terminal, and its session keeps running.
# N: `script`'s own shell, on a terminal of its own, disowned a sleep: it keeps running, as one disowned at the prompt.
SCREEN_TAB = ('M screen', 'mkdir -m 700 -p scr && SCREENDIR="$PWD/scr" screen -c /dev/null -S ntoc sleep 7776')
SCRIPT_TAB = ('N script', "script -q /dev/null zsh -fic 'sleep 7777 &!; exec sleep 7778'")
HAS_SCREEN = os.access('/usr/bin/screen', os.X_OK)
TABS += ([SCREEN_TAB] if HAS_SCREEN else []) + [SCRIPT_TAB]

# What each test process is, by its command line (first match wins; order matters).
KINDS = [
    ('SCREEN -c /dev/null -S ntoc', 'M screen session'),
    ('screen -c /dev/null -S ntoc', 'M screen client'),
    # screen's window runs `login -pflq <user> /bin/sleep 7776`: login is setuid root, so its working folder can't be
    # read and it is never counted (nor killed); it ends with the sleep it runs.
    ('/bin/sleep 7776', 'M screen window'),
    ('sleep 7776', 'M sleep in screen'),
    ('script -q /dev/null', 'N script'),
    ('sleep 7777', 'N sleep disowned in script'),
    ('sleep 7778', 'N sleep in front in script'),
    ('ntmark-hupign.py', 'B python ignoring SIGHUP'),
    ('next-server (v16.4.0) bgjob', 'C next-server job'),
    ('sleep 7771', 'C sleep job'),
    ('next-server (v16.4.0) nohup', 'D nohup next-server'),
    ('sleep 7772', 'D nohup sleep'),
    ('sleep 7773', 'E disowned sleep'),
    ('sleep 7774', 'F double-forked sleep'),
    ('next-server (v16.4.0) dfork', 'F double-forked next-server'),
    ('sh -c python3 ntmark-setpgid.py', 'G sh'),
    ('ntmark-setpgid.py', 'G python in its own group'),
    ('ntmark-agent.js cleanup', 'I careful agent'),
    ('ntmark-agent.js', 'H agent'),
    ('npm run dev agentclean', 'I npm'),
    ('ntmark-nextdev.js agentclean', 'I next dev'),
    ('next-server (v16.4.0) agentclean', 'I next-server'),
    ('npm run dev agent', 'H npm'),
    ('ntmark-nextdev.js agent', 'H next dev'),
    ('next-server (v16.4.0) agent', 'H next-server'),
    ('sleep 7775', 'J stopped sleep'),
    ('ntmark-hupnode', 'K node catching SIGHUP'),
    ('npm run dev', 'A npm'),
    ('ntmark-nextdev.js', 'A next dev'),
    ('next-server (v16.4.0) fg', 'A next-server'),
]
DELIBERATE = {'B python ignoring SIGHUP', 'D nohup sleep', 'E disowned sleep', 'F double-forked sleep', 'F double-forked next-server',
              'N sleep disowned in script'} | ({'M screen session', 'M sleep in screen'} if HAS_SCREEN else set())
EXPECTED_BEFORE = 23 + 3 + (3 if HAS_SCREEN else 0)


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


class Check:
    def __init__(self, release, shim):
        self.release, self.shim = os.path.abspath(release), os.path.abspath(shim)
        # A short path: a Unix socket's path must stay under 104 bytes.
        self.work = tempfile.mkdtemp(prefix='ntoc.', dir='/tmp')
        self.home = os.path.join(self.work, 'home')
        self.project = os.path.join(self.work, 'project')
        self.sock = os.path.join(self.home, 'Library/Application Support/Next Term/mcp.sock')
        self.log = os.path.join(self.work, 'shim.log')
        os.makedirs(self.home)
        shutil.copytree(os.path.join(HERE, 'project'), self.project)
        self.app = self.make_app()
        self.real_home = pwd.getpwuid(os.getuid()).pw_dir

    def make_app(self):
        """A bundle with its own id (its own settings domain); the binary and bundles hard-linked, not copied."""
        app = os.path.join(self.work, 'NT-orphancheck.app')
        macos = os.path.join(app, 'Contents/MacOS')
        os.makedirs(macos)
        binary = os.path.join(macos, 'NextTerm')
        try: os.link(os.path.join(self.release, 'NextTerm'), binary)
        except OSError: shutil.copy2(os.path.join(self.release, 'NextTerm'), binary)
        for name in os.listdir(self.release):
            if name.endswith('.bundle'):
                shutil.copytree(os.path.join(self.release, name), os.path.join(app, name), copy_function=os.link)
        with open(os.path.join(app, 'Contents/Info.plist'), 'w') as f:
            f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NT-orphancheck</string>
  <key>CFBundleIdentifier</key><string>{DOMAIN}</string>
  <key>CFBundleExecutable</key><string>NextTerm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict></plist>
''')
        return binary

    # MARK: the test copy

    def call(self, tool, **arguments):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(60)
        s.connect(self.sock)
        s.sendall((json.dumps({'tool': tool, 'arguments': arguments}) + '\n').encode())
        data = b''
        while b'\n' not in data:
            chunk = s.recv(65536)
            if not chunk: break
            data += chunk
        s.close()
        text = json.loads(data).get('text', '')
        try: return json.loads(text)
        except ValueError: return text

    def answers(self):
        try:
            self.call('list_projects')
            return True
        except OSError:
            return False

    def launch(self):
        subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
        subprocess.run(['defaults', 'write', DOMAIN, 'NSAppSleepDisabled', '-bool', 'YES'])
        subprocess.run(['defaults', 'write', DOMAIN, 'commandLineToolOffer', 'never'])
        env = dict(os.environ)
        for key in list(env):
            if key.startswith(('XDG_', 'CLAUDE', 'CODEX', 'GEMINI', 'QWEN', 'COPILOT', 'NEXTTERM', 'NEXT_TERM')) or key in ('ZDOTDIR', 'TERM_PROGRAM'):
                del env[key]
        env.update(HOME=self.home, CFFIXED_USER_HOME=self.home, DYLD_INSERT_LIBRARIES=self.shim, NT_SHIM_LOG=self.log)
        if env['HOME'] != self.home or not self.home.startswith('/tmp/ntoc.') or env['CFFIXED_USER_HOME'] != self.home:
            sys.exit('refusing to launch: the home is not the temporary one')
        out = open(os.path.join(self.work, 'app.out'), 'a')
        process = subprocess.Popen([self.app], env=env, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        # The shim's first line is the home the process really has: stop at once if it is not the temporary one.
        for _ in range(100):
            homes = [l for l in open(self.log).read().splitlines() if ' home ' in l] if os.path.exists(self.log) else []
            if homes: break
            time.sleep(0.05)
        expected = f'home {self.home} {self.home} | {self.home}'
        if not homes or not homes[-1].endswith(expected):
            process.kill()
            sys.exit(f'stopped the test copy: it does not run with the temporary home ({homes[-1:] or "no shim log"})')
        for _ in range(200):
            if self.answers(): return process
            time.sleep(0.1)
        process.kill()
        sys.exit('the test copy never answered on its MCP socket')

    # MARK: the test processes

    def test_processes(self):
        """(pid, ppid, pgid, tty, stat, command, kind) of this run's test processes: matched by command, and with
        their working directory in this run's project (so nothing of yours is ever counted or killed)."""
        rows = []
        for line in sh('ps', '-axo', 'pid=,ppid=,pgid=,tty=,stat=,command=').splitlines():
            parts = line.split(None, 5)
            if len(parts) < 6: continue
            command = parts[5]
            kind = next((k for pattern, k in KINDS if pattern in command), None)
            if kind and 'grep' not in command:
                rows.append((int(parts[0]), int(parts[1]), int(parts[2]), parts[3], parts[4], command, kind))
        mine = self.in_project([r[0] for r in rows])
        return [r for r in rows if r[0] in mine]

    def orphaned_shells(self):
        pids = [int(l.split()[0]) for l in sh('ps', '-axo', 'pid=,ppid=,command=').splitlines()
                if len(l.split()) >= 3 and l.split()[1] == '1' and l.split()[2] == '-zsh']
        return sorted(self.in_project(pids))

    def in_project(self, pids):
        if not pids: return set()
        out = sh('lsof', '-a', '-d', 'cwd', '-Fpn', '-p', ','.join(map(str, pids)))
        mine, pid = set(), None
        for line in out.splitlines():
            if line.startswith('p'): pid = int(line[1:])
            elif line.startswith('n') and pid and os.path.realpath(line[1:]).startswith(os.path.realpath(self.work)): mine.add(pid)
        return mine

    def shell_fds(self, app_pid):
        """Descriptors the newest tab's shell inherited from the app: pty masters and Unix sockets."""
        shells = [int(l.split()[0]) for l in sh('ps', '-axo', 'pid=,ppid=,command=').splitlines() if l.split()[1:] == [str(app_pid), '-zsh']]
        if not shells: return 'no shells found'
        newest = max(shells)
        out = sh('lsof', '-p', str(newest))
        ptmx = sum(1 for l in out.splitlines() if '/dev/ptmx' in l)
        unix = sum(1 for l in out.splitlines() if ' unix ' in l)
        temp = sum(1 for l in out.splitlines() if 'next-term-out-' in l)
        return f'the newest tab shell (pid {newest}) holds {ptmx} pty masters, {unix} Unix sockets, {temp} git output files'

    def kill_all(self, pids):
        for sig in (signal.SIGCONT, signal.SIGKILL):
            for pid in pids:
                try: os.kill(pid, sig)
                except OSError: pass

    def clean_project(self):
        for name in os.listdir(self.project):
            if name.endswith('.out') or name in ('signals.log', 'sigs.txt'):
                os.remove(os.path.join(self.project, name))
        shutil.rmtree(os.path.join(self.project, 'scr'), ignore_errors=True)  # screen's sockets

    # MARK: one run

    def run(self, how):
        if os.path.exists(self.sock) and self.answers():
            sys.exit('another test copy answers on the socket; stop it first')
        self.clean_project()
        process = self.launch()
        pid = process.pid
        ids = {}
        for name, command in TABS:
            reply = self.call('new_tab', directory=self.project, command=command, title=name)
            ids[name] = reply.get('id') if isinstance(reply, dict) else reply
            time.sleep(0.4)
        time.sleep(6)
        # J: ^Z, as the terminal sends it to the foreground group (press_keys has no ctrl+z), so the shell has a
        # suspended job when the app ends.
        for r in self.test_processes():
            if r[6] == 'J stopped sleep':
                os.killpg(r[2], signal.SIGTSTP)
        time.sleep(2)
        before = self.test_processes()
        stopped = [r for r in before if r[6] == 'J stopped sleep' and 'T' in r[4]]
        report = [f'=== end by {how} (app {pid}); before: {len(before)} test processes (expected {EXPECTED_BEFORE})',
                  self.shell_fds(pid), f"J's sleep is {'stopped' if stopped else 'NOT stopped'} (^Z)"]
        if len(before) != EXPECTED_BEFORE:
            counts = {}
            for r in before: counts[r[6]] = counts.get(r[6], 0) + 1
            report.append('running before: ' + ', '.join(f'{k} x{n}' if n > 1 else k for k, n in sorted(counts.items())))
        mark = len(open(self.log).read().splitlines())
        if how == 'quit':
            report.append(self.quit(process))
        elif how == 'close':
            for name, tab in ids.items():
                self.call('close_tab', tab_id=tab, force=True)
                time.sleep(0.3)
            time.sleep(3)
            ptmx = sum(1 for l in sh('lsof', '-p', str(pid)).splitlines() if '/dev/ptmx' in l)
            report.append(f'after closing every tab: the app holds {ptmx} pty masters')
            report.append(self.quit(process))
        else:
            process.kill()
            process.wait()
        alerts = [l.split(' ', 1)[1] for l in open(self.log).read().splitlines()[mark:] if ' alert: ' in l]
        report += alerts
        time.sleep(4)
        after = self.test_processes()
        shells = self.orphaned_shells()
        report.append('--- survivors 4 s later (pid ppid pgid tty stat: what)')
        report += [f'{p:>6} {pp:>6} {g:>6} {t:<8} {s:<5} {kind}' for p, pp, g, t, s, _, kind in sorted(after, key=lambda r: r[6])]
        report.append(f'{len(after)} of {len(before)} survive; orphaned login shells: {len(shells)}')
        # A shell whose terminal a survivor still writes to cannot finish exiting (the kernel drains the output
        # first): "(zsh)", state E, until that survivor ends. Not an orphan, but worth seeing.
        ttys = {r[3] for r in after if r[3] != '??'}
        stuck = [l.split()[0] for l in sh('ps', '-axo', 'pid=,ppid=,tty=,stat=,command=').splitlines()
                 if len(l.split()) >= 5 and l.split()[2] in ttys and l.split()[4] == '(zsh)']
        if stuck: report.append(f'shells stuck exiting on a survivor\'s terminal: {len(stuck)} (they finish once it ends)')
        kinds = {r[6] for r in after}
        if how in ('quit', 'close'):
            ok = kinds == DELIBERATE and len(after) == len(DELIBERATE)
            extra, missing = sorted(kinds - DELIBERATE), sorted(DELIBERATE - kinds)
            report.append(('PASS' if ok else 'FAIL') + f' {how}: exactly the {len(DELIBERATE)} deliberate survivors' +
                          ('' if ok else f' (also alive: {extra}; ended: {missing})'))
        else:
            report.append(('PASS' if not shells else 'FAIL') + f' kill: no orphaned login shell ({len(shells)})')
        self.kill_all([r[0] for r in after] + shells)
        if process.poll() is None:
            process.kill()
            process.wait()
        time.sleep(1)
        return report

    QUIT_BUDGET = 2.0  # one second of grace for what outlives the hangup, and the rest of quitting

    def quit(self, process):
        """Quits as ⌘Q does; FAIL if the app takes longer than QUIT_BUDGET to exit."""
        start = time.time()
        process.send_signal(signal.SIGUSR1)
        try:
            process.wait(30)
            took = time.time() - start
            verdict = 'PASS' if took <= self.QUIT_BUDGET else 'FAIL'
            return f'{verdict} quit time: the app exited {took:.2f} s after the quit request (at most {self.QUIT_BUDGET:.0f} s)'
        except subprocess.TimeoutExpired:
            return 'FAIL quit time: the app is still running 30 s after the quit request'

    def finish(self):
        subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
        for folder in (os.path.join(self.real_home, 'Library/Preferences'), os.path.join(self.real_home, 'Library/Saved Application State')):
            for name in (DOMAIN + '.plist', DOMAIN + '.savedState'):
                path = os.path.join(folder, name)
                if os.path.isdir(path): shutil.rmtree(path, ignore_errors=True)
                elif os.path.exists(path): os.remove(path)
        shutil.rmtree(self.work, ignore_errors=True)


def main():
    if len(sys.argv) != 3: sys.exit(__doc__)
    check = Check(sys.argv[1], sys.argv[2])
    watched = [os.path.join(check.real_home, d) for d in ('.claude/ide', '.gemini', '.qwen', '.copilot', '.codex')]
    listing = lambda: {d: sorted(os.listdir(d)) if os.path.isdir(d) else None for d in watched}
    untouched = listing()
    failed = False
    try:
        for how in ('quit', 'close', 'kill'):
            lines = check.run(how)
            print('\n'.join(lines), flush=True)
            failed |= any(l.startswith('FAIL') for l in lines)
    finally:
        check.finish()
    if listing() != untouched:
        print('WARNING: a folder in your home changed meanwhile:', [d for d in watched if listing()[d] != untouched[d]])
    print('orphan check: ' + ('FAILED' if failed else 'PASSED'))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
