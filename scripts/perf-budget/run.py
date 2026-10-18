#!/usr/bin/env python3
"""Next Term's performance budget (scripts/perf-budget.sh runs this).

A test copy of a release build runs with its own settings domain and a temporary home (its MCP socket, rc files
and agent folders stay out of yours), with shim.dylib injected. Each scenario starts a fresh copy, drives it
through its own MCP socket and reads its counters with `ru` (proc_pid_rusage): instructions retired, which stay
comparable across P and E cores and on a busy machine, the CPU time of the git runs it reaped, and its footprint.

  S2   idle: 10 tabs at the prompt                          M instructions/s     at most 25
  S4h  3 agent stand-ins at work, the app hidden (⌘H)       M instructions/s     at most 130
  S5n  a 10 s flood of output with no URL in it, app hidden M instructions/MB    at most 390
  S7w  a 20,000-file repository, `.next/trace` appended    % of a core in git   at most 2
       twice a second (as `next dev` does)
  M30  footprint 30 s after a 10 MB burst of output         MB                   at most 300
       (1 MB a second for 10 s)

The terminal's tabs in a list down its left (Settings › Terminal › Tabs), against the top bar in the same run:
  S2L  S2 with the list                                     M instructions/s     at most 25, and S2 + 5%
  S4hL S4h with the list                                    M instructions/s     at most 130, no row drawn
  S4v  3 agent stand-ins at work, the window in view        M instructions/s     (the comparison's base)
  S4vL S4v with the list                                    M instructions/s     S4v + 5%; rows drawn at most
                                                                                 the top tabs' + 10%
Suggestions while typing, at 100,000 commands recorded (a deterministic seed in the copy's own home), in one zsh tab:
  G1   the shell's report read, to the suggestion set: p50  ms                   at most 1
  G1p  the same, p95                                        ms                   at most 2
  G1e  a key down to the suggestion drawn, p50 (p95 too)    ms                   (INFO)
  G1m  the copy's footprint with the record loaded, over    MB                   (INFO: at most 15 wanted)
       the same copy's before its first suggestion
The keys (50 rounds of `git ch` then ^U, 80 ms apart) are posted by the shim inside the copy, so G1 needs --front
(the terminal must have the keyboard in the key window), as S7w does.

With --base <release folder>, S2 and S4v also run on that build (the release before, tabs on top), and this one's
are held to within 5% of its. --pairs N runs each compared scenario N times, in turn, and compares medians, with the
spread in the report. The shim counts the top bar's tabs and the list's rows drawn, where the build has them.

S7w, M30, S4v, S4vL and G1 need a window in view the whole time (no git refresh runs, and no terminal draws, for a
window nobody can see): with --front the copy takes the front (leave the Mac alone meanwhile). Without it, the copy's
windows open behind yours or on another Space, and each is skipped unless a window stays in view (S4v and S4vL are
skipped outright); a skipped M30 still reports what it measured. The report says how many windows were in view, and
M30 how many draws the burst made.
Usage: run.py <release folder> <shim.dylib> <ru> [--front] [--only S2,S4h,...] [--warn-only] [--relieve-after-burst]
              [--base <release folder>] [--pairs N]
"""
import argparse, json, math, os, pwd, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
DOMAIN = 'me.mishuk.nextterm.perfbudget'
# The S5n budget: 0.10.2's measurement on an M3 Pro (295-314 M/MB; 0.10.1: 359-472) plus 25%.
S5N_BUDGET = 390.0
BUDGETS = {'S2': 25.0, 'S2L': 25.0, 'S4h': 130.0, 'S4hL': 130.0, 'S4v': None, 'S4vL': None, 'S5n': S5N_BUDGET,
           'S7w': 2.0, 'M30': 300.0, 'G1': 1.0, 'G1p': 2.0, 'G1e': None, 'G1m': None}
# One layout against the other, and this build against the base, in the same run: at most 5% more. Rows of the list
# may draw at most 10% more than the top bar's tabs for the same work.
MARGIN = 1.05
DRAW_MARGIN = 1.1
# Where each scenario's tabs show; None leaves the default, the top.
TABS = {'S2': None, 'S2L': 'left', 'S4h': None, 'S4hL': 'left', 'S4v': None, 'S4vL': 'left'}
# The scenarios that run in turn with --pairs, in that order, and the ones that also run on the base.
PAIRED = ('S2', 'S2L', 'S4h', 'S4hL', 'S4v', 'S4vL')
ON_BASE = ('S2', 'S4v')
ORDER = ('S2', 'S2L', 'S4h', 'S4hL', 'S4v', 'S4vL', 'S5n', 'S7w', 'M30', 'G1', 'G1p', 'G1e', 'G1m')
GHOST = ('G1', 'G1p', 'G1e', 'G1m')
# G1's record: this many commands, and its typing: rounds of `git ch` then ^U, this far apart.
GHOST_COMMANDS = 100_000
GHOST_ROUNDS = 50
GHOST_GAP_MS = 80
# The burst: 10 MB at 1 MB a second, a build log scrolling by. The flood: as fast as it goes, for 10 s.
BURST_RATE = float(os.environ.get('NT_BURST_RATE', '1'))
BURST_KIND = os.environ.get('NT_BURST_KIND', 'log')
FLOOD_SECONDS = 10
UNITS = {'S2': 'M/s', 'S2L': 'M/s', 'S4h': 'M/s', 'S4hL': 'M/s', 'S4v': 'M/s', 'S4vL': 'M/s', 'S5n': 'M/MB',
         'S7w': '% of a core', 'M30': 'MB', 'G1': 'ms', 'G1p': 'ms', 'G1e': 'ms', 'G1m': 'MB'}


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


def percentile(values, fraction):
    """The value at `fraction` of the sorted `values` (nearest rank); None for none."""
    if not values: return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, max(0, math.ceil(fraction * len(ordered)) - 1))]


def seed_history(home):
    """A deterministic record of GHOST_COMMANDS commands in the copy's own home, as Next Term keeps it (History.noindex,
    0700, its log 0600): ten kinds of command over distinct arguments, one run each a millisecond apart, and
    `git checkout main` the newest, so `git ch` has one to show among ten thousand that start with it."""
    folder = os.path.join(home, 'Library/Application Support/Next Term/History.noindex')
    os.makedirs(folder, mode=0o700)
    os.chmod(folder, 0o700)
    kinds = ('git checkout', 'git commit -m', 'npm run', 'make', 'kubectl get', 'docker compose up', 'ls -la', 'grep -rn',
             'swift build --product', 'ssh deploy@')
    start = 1_700_000_000_000
    lines = ['nextterm-history 1']
    for i in range(GHOST_COMMANDS - 1):
        lines.append(f'c\t{start + i}\t1\t1\t0\t-\t-\t-\t{kinds[i % len(kinds)]} item-{i:06d}')
    lines.append(f'c\t{start + GHOST_COMMANDS}\t3\t3\t0\t-\t-\t-\tgit checkout main')
    descriptor = os.open(os.path.join(folder, 'commands.log'), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as log:
        log.write('\n'.join(lines) + '\n')


def strips(m):
    """What the terminal's tab strips drew while measured: the top bar's tabs and the list's rows, where counted."""
    parts = [f"{m[key]} {what} draws" for key, what in (('tab_draws', 'top-tab'), ('row_draws', 'list-row'))
             if m.get(key) is not None]
    return ''.join(', ' + part for part in parts)


class Copy:
    """One run of the test copy, with a home of its own."""

    def __init__(self, check, name, app=None):
        self.check, self.name, self.app = check, name, app or check.app
        self.home = os.path.join(check.work, 'home-' + name)
        self.sock = os.path.join(self.home, 'Library/Application Support/Next Term/mcp.sock')
        self.log = os.path.join(check.work, name + '.log')
        self.status_file = os.path.join(check.work, name + '.status')
        self.type_file = os.path.join(check.work, name + '.type')
        os.makedirs(self.home)
        self.process = None

    # MARK: starting and ending

    def launch(self, tabs=None):
        """Starts the copy with fresh settings; `tabs` (left or right) puts its terminal tabs in the list."""
        subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
        subprocess.run(['defaults', 'write', DOMAIN, 'NSAppSleepDisabled', '-bool', 'YES'])
        subprocess.run(['defaults', 'write', DOMAIN, 'commandLineToolOffer', 'never'])
        if tabs:
            subprocess.run(['defaults', 'write', DOMAIN, 'terminalTabs', tabs])
        env = dict(os.environ)
        for key in list(env):
            if key.startswith(('XDG_', 'CLAUDE', 'CODEX', 'GEMINI', 'QWEN', 'COPILOT', 'NEXTTERM', 'NEXT_TERM')) or key in ('ZDOTDIR', 'TERM_PROGRAM'):
                del env[key]
        env.update(HOME=self.home, CFFIXED_USER_HOME=self.home, DYLD_INSERT_LIBRARIES=self.check.shim,
                   NT_SHIM_LOG=self.log, NT_SHIM_STATUS=self.status_file, NT_SHIM_FRONT='1' if self.check.front else '0',
                   NT_SHIM_TYPE=self.type_file, NT_SHIM_TYPE_GAP_MS=str(GHOST_GAP_MS))
        if env['HOME'] != self.home or env['CFFIXED_USER_HOME'] != self.home or not self.home.startswith('/tmp/ntpb.'):
            sys.exit('refusing to launch: the home is not the temporary one')
        out = open(os.path.join(self.check.work, self.name + '.out'), 'a')
        self.process = subprocess.Popen([self.app], env=env, stdin=subprocess.DEVNULL, stdout=out,
                                        stderr=subprocess.STDOUT, start_new_session=True)
        # The shim's first line is the home the process really has: stop at once if it is not the temporary one.
        homes = []
        for _ in range(100):
            homes = [l for l in open(self.log).read().splitlines() if l.startswith('home ')] if os.path.exists(self.log) else []
            if homes: break
            time.sleep(0.05)
        if not homes or homes[-1] != f'home {self.home} {self.home} | {self.home}':
            self.process.kill()
            sys.exit(f'stopped the test copy: it does not run with the temporary home ({homes[-1:] or "no shim log"})')
        for _ in range(200):
            if self.answers(): break
            time.sleep(0.1)
        else:
            self.process.kill()
            sys.exit('the test copy never answered on its MCP socket')
        time.sleep(3)  # the first window, the welcome checks
        return self

    def end(self):
        """Closes every tab, then kills the copy and anything left running in this run's folder."""
        try:
            tabs = self.call('list_tabs')
            for window in tabs.get('windows', []) if isinstance(tabs, dict) else []:
                for tab in window.get('tabs', []):
                    self.call('close_tab', tab_id=tab['id'], force=True)
        except (OSError, ValueError):
            pass
        time.sleep(1.5)
        if self.process and self.process.poll() is None:
            self.process.kill()
            self.process.wait()
        self.check.sweep()

    # MARK: the copy's MCP socket and counters

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

    def new_tab(self, directory, command=None, title=None):
        args = {'directory': directory}
        if command: args['command'] = command
        if title: args['title'] = title
        reply = self.call('new_tab', **args)
        return reply.get('id') if isinstance(reply, dict) else reply

    def counters(self):
        parts = sh(self.check.ru, str(self.process.pid)).split()
        if len(parts) != 8: return None
        keys = ('instructions', 'cycles', 'user', 'system', 'child_user', 'child_system', 'footprint')
        return dict(zip(keys, map(int, parts[1:])))

    def status(self):
        """(draws, visible windows, windows, active, hidden, top-tab draws, list-row draws) as the shim last wrote them;
        the last two are -1 where not counted, and for a shim that writes only the first five. The shim rewrites the
        file every second: a read that catches it empty or half written is tried again, then the last whole one is
        used."""
        for _ in range(5):
            try:
                values = tuple(int(x) for x in open(self.status_file).read().split())
            except (OSError, ValueError):
                values = ()
            if len(values) in (5, 7):
                values = values + (-1, -1) if len(values) == 5 else values
                self.last_status = values
                return values
            time.sleep(0.02)
        return getattr(self, 'last_status', (0, 0, 0, 0, 0, -1, -1))

    def measure(self, seconds):
        a, s0, t0 = self.counters(), self.status(), time.time()
        time.sleep(seconds)
        b, s1, t1 = self.counters(), self.status(), time.time()
        took = t1 - t0
        return {
            'mips': (b['instructions'] - a['instructions']) / took / 1e6,
            'cpu': (b['user'] + b['system'] - a['user'] - a['system']) / took / 1e7,  # % of a core
            'git': (b['child_user'] + b['child_system'] - a['child_user'] - a['child_system']) / took / 1e7,
            'draws': s1[0] - s0[0], 'seconds': took, 'visible': s1[1], 'windows': s1[2], 'hidden': s1[4],
            'counted': b['instructions'] > a['instructions'],
            'tab_draws': s1[5] - s0[5] if min(s0[5], s1[5]) >= 0 else None,
            'row_draws': s1[6] - s0[6] if min(s0[6], s1[6]) >= 0 else None,
        }

    def reliefs(self):
        """What the shim logged of giving memory back (--relieve-after-burst): (passes, MB returned)."""
        lines = [l.split() for l in open(self.log).read().splitlines() if l.startswith('relief ')]
        return len(lines), sum(float(l[1]) for l in lines if len(l) > 2)

    def type(self, keys):
        """Keys for the shim to type into the copy's key window (its next tick reads them): written whole, then moved
        into place, so it never reads half of them."""
        with open(self.type_file + '.part', 'w') as f: f.write(keys)
        os.rename(self.type_file + '.part', self.type_file)

    def ghost_stamps(self):
        """The shim's stamps since its last `typing` line: (kind, values)."""
        try: lines = open(self.status_file + '.ghost').read().splitlines()
        except OSError: return []
        stamps = [(l.split()[0], [float(x) for x in l.split()[1:]]) for l in lines if len(l.split()) >= 2]
        starts = [i for i, (kind, _) in enumerate(stamps) if kind == 'typing']
        return stamps[starts[-1] + 1:] if starts else stamps

    def hide(self, hidden):
        self.process.send_signal(signal.SIGUSR1 if hidden else signal.SIGUSR2)
        for _ in range(40):
            time.sleep(0.25)
            if bool(self.status()[4]) == hidden: return True
        return False


class Check:
    def __init__(self, release, shim, ru, front, warn_only, relieve_after_burst, base=None, pairs=1):
        self.release, self.shim, self.ru = os.path.abspath(release), os.path.abspath(shim), os.path.abspath(ru)
        self.front, self.warn_only, self.relieve_after_burst = front, warn_only, relieve_after_burst
        self.pairs = max(1, pairs)
        # A short path: a Unix socket's path must stay under 104 bytes.
        self.work = tempfile.mkdtemp(prefix='ntpb.', dir='/tmp')
        self.project = os.path.join(self.work, 'project')
        shutil.copytree(os.path.join(HERE, 'project'), self.project)
        self.app = self.make_app(self.release, 'NT-perfbudget.app')
        # The release before, to hold this one to (the same settings domain: the copies never run at once).
        self.base_app = self.make_app(os.path.abspath(base), 'NT-perfbudget-base.app') if base else None
        self.real_home = pwd.getpwuid(os.getuid()).pw_dir
        self.results = {}
        self.notes = []
        # The run each paired scenario's result came from (its draws), the base's results, and the ratio budgets.
        self.chosen = {}
        self.base_results = {}
        self.compared = []
        self.launches = 0

    def make_app(self, release, name):
        """A bundle with its own id (its own settings domain); the binary and bundles hard-linked, not copied."""
        app = os.path.join(self.work, name)
        macos = os.path.join(app, 'Contents/MacOS')
        os.makedirs(macos)
        binary = os.path.join(macos, 'NextTerm')
        try: os.link(os.path.join(release, 'NextTerm'), binary)
        except OSError: shutil.copy2(os.path.join(release, 'NextTerm'), binary)
        for name in os.listdir(release):
            if name.endswith('.bundle'):
                shutil.copytree(os.path.join(release, name), os.path.join(app, name), copy_function=os.link)
        with open(os.path.join(app, 'Contents/Info.plist'), 'w') as f:
            f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>NT-perfbudget</string>
  <key>CFBundleIdentifier</key><string>{DOMAIN}</string>
  <key>CFBundleExecutable</key><string>NextTerm</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
''')
        return binary

    def sweep(self):
        """Kills what still runs with its working directory in this run's folder (and nothing of yours)."""
        pids = [int(l.split()[0]) for l in sh('ps', '-axo', 'pid=').splitlines() if l.strip()]
        out = sh('lsof', '-a', '-d', 'cwd', '-Fpn', '-p', ','.join(map(str, pids)))
        mine, pid = set(), None
        for line in out.splitlines():
            if line.startswith('p'): pid = int(line[1:])
            elif line.startswith('n') and pid and os.path.realpath(line[1:]).startswith(os.path.realpath(self.work)): mine.add(pid)
        mine.discard(os.getpid())
        for sig in (signal.SIGCONT, signal.SIGKILL):
            for p in mine:
                try: os.kill(p, sig)
                except OSError: pass
        time.sleep(0.5)

    def record(self, key, value, detail):
        self.results[key] = (value, detail)

    # MARK: scenarios

    def copy(self, key, app=None):
        """A fresh copy for one run of `key`, its files named apart from every other run's."""
        self.launches += 1
        return Copy(self, f'{key.lower()}-{self.launches}', app)

    def s2(self, key='S2', app=None):
        """S2 and S2L: 10 tabs at the prompt, on top or in the list."""
        copy = self.copy(key, app).launch(TABS[key])
        try:
            for i in range(10):
                copy.new_tab(self.project, title=f'idle {i + 1}')
                time.sleep(0.4)
            time.sleep(15)  # shells started, prompts drawn, first polls done
            m = copy.measure(20)
            detail = f"{m['cpu']:.1f}% CPU, {m['draws']} draws{strips(m)}, {m['visible']}/{m['windows']} windows in view"
            return dict(m, value=m['mips'] if m['counted'] else None, detail=detail)
        finally:
            copy.end()

    def s4h(self, key='S4h', app=None):
        """S4h and S4hL: 3 agent stand-ins at work with the app hidden, on top or in the list."""
        copy = self.copy(key, app).launch(TABS[key])
        try:
            for i in range(3):
                copy.new_tab(self.project, command='bin/claude 75', title=f'agent {i + 1}')
                time.sleep(0.4)
            time.sleep(4)
            shown = copy.measure(15)
            label = 'S4' if key == 'S4h' else 'S4L'
            self.notes.append(f"{label} not hidden ({shown['visible']}/{shown['windows']} windows in view): {shown['mips']:.0f} M/s, "
                              f"{shown['cpu']:.1f}% CPU, {shown['draws']} draws{strips(shown)} in {shown['seconds']:.0f} s")
            if not copy.hide(True):
                return {'value': None, 'detail': 'the app did not hide'}
            time.sleep(5)
            m = copy.measure(20)
            copy.hide(False)
            return dict(m, value=m['mips'] if m['counted'] else None, detail=f"{m['cpu']:.1f}% CPU, {m['draws']} draws{strips(m)} while hidden")
        finally:
            copy.end()

    def s4v(self, key='S4v', app=None):
        """S4v and S4vL: 3 agent stand-ins at work with the window in view, on top or in the list: what the tabs'
        live marks cost while someone watches. Needs --front."""
        if not self.front:
            return {'value': None, 'detail': 'SKIP: needs a window in view (run with --front)'}
        copy = self.copy(key, app).launch(TABS[key])
        try:
            for i in range(3):
                copy.new_tab(self.project, command='bin/claude 75', title=f'agent {i + 1}')
                time.sleep(0.4)
            time.sleep(4)
            if not copy.status()[1]:
                return {'value': None, 'detail': 'SKIP: no window in view (run with --front)'}
            m = copy.measure(15)
            if not m['visible']:
                return {'value': None, 'detail': 'SKIP: the window left view while measured'}
            detail = f"{m['cpu']:.1f}% CPU, {m['draws']} terminal draws{strips(m)}, {m['visible']}/{m['windows']} windows in view"
            return dict(m, value=m['mips'] if m['counted'] else None, detail=detail)
        finally:
            copy.end()

    def paired(self, only):
        """The scenarios each layout is compared in, and the base's, run in turn --pairs times: a drift in the Mac's
        load meanwhile then reaches both sides of each comparison alike."""
        runs = {key: [] for key in PAIRED}
        base_runs = {key: [] for key in ON_BASE}
        scenario = {'S2': self.s2, 'S2L': self.s2, 'S4h': self.s4h, 'S4hL': self.s4h, 'S4v': self.s4v, 'S4vL': self.s4v}
        for _ in range(self.pairs):
            for key in PAIRED:
                if key not in only: continue
                if self.base_app and key in ON_BASE:
                    base_runs[key].append(scenario[key](key, self.base_app))
                runs[key].append(scenario[key](key))
        for key in PAIRED:
            if runs[key]: self.settle(key, runs[key], self.results, self.chosen)
            if base_runs.get(key): self.settle(key, base_runs[key], self.base_results, {})

    def settle(self, key, runs, results, chosen):
        """A scenario's runs as one result: the median run (the lower of the two middle ones, so its draws are its
        own), and the spread when it ran more than once."""
        measured = sorted((run for run in runs if run.get('value') is not None), key=lambda run: run['value'])
        if not measured:
            results[key] = (None, runs[-1]['detail'])
            return
        middle = measured[(len(measured) - 1) // 2]
        detail = middle['detail']
        if len(runs) > 1:
            detail += f"; median of {len(measured)} of {len(runs)} runs, {measured[0]['value']:.1f}-{measured[-1]['value']:.1f}"
        results[key] = (middle['value'], detail)
        chosen[key] = middle

    def memory_and_flood(self, only):
        copy = Copy(self, 'm30').launch()
        try:
            copy.new_tab(self.project, title='output')
            time.sleep(8)
            tab = self.tab_id(copy)
            if 'M30' in only:
                base = copy.counters()['footprint'] / 1e6
                done = os.path.join(self.work, 'burst.done')
                s0 = copy.status()
                in_view = s0[1]  # the fewest windows in view while the burst ran
                copy.call('send_to_tab', tab_id=tab, text=f'python3 flood.py {done} --mb 10 --rate {BURST_RATE} --kind {BURST_KIND}')
                peak, start = base, time.time()
                while not os.path.exists(done) and time.time() - start < 180:
                    peak = max(peak, copy.counters()['footprint'] / 1e6)
                    in_view = min(in_view, copy.status()[1])
                    time.sleep(0.5)
                s1 = copy.status()
                if not os.path.exists(done):
                    self.record('M30', None, 'the 10 MB burst did not finish within 3 minutes')
                else:
                    ended = time.time()
                    if self.relieve_after_burst:
                        time.sleep(3)
                        copy.process.send_signal(signal.SIGINFO)
                    samples = {}
                    for at in (2, 5, 10, 30):
                        time.sleep(max(0, ended + at - time.time()))
                        samples[at] = copy.counters()['footprint'] / 1e6
                        peak = max(peak, samples[at])
                    detail = (f"before {base:.0f} MB, peak {peak:.0f}, after 2 s {samples[2]:.0f}, 5 s {samples[5]:.0f}, "
                              f"10 s {samples[10]:.0f}")
                    detail += f"; {s1[0] - s0[0]} draws in the burst, {s1[1]}/{s1[2]} windows in view"
                    if self.relieve_after_burst:
                        passes, returned = copy.reliefs()
                        detail += f"; asked to give memory back {passes} time(s), it returned {returned:.1f} MB"
                    if in_view:
                        self.record('M30', samples[30], detail)
                    else:
                        # Nobody saw the burst, so nothing drew it: not the case the budget is for.
                        self.record('M30', None, f"SKIP: no window in view during the burst (run with --front); "
                                                 f"measured anyway: after 30 s {samples[30]:.0f} MB, {detail}")
            if 'S5n' in only:
                # Hidden, so the count is the parsing and the scans of what it prints, whether or not the windows
                # happen to be in view (drawing is S4's).
                copy.hide(True)
                done = os.path.join(self.work, 'flood.done')
                a, s0 = copy.counters(), copy.status()
                copy.call('send_to_tab', tab_id=tab, text=f'python3 flood.py {done} --seconds {FLOOD_SECONDS}')
                start = time.time()
                while not os.path.exists(done) and time.time() - start < 300:
                    time.sleep(0.25)
                if not os.path.exists(done):
                    self.record('S5n', None, 'the flood did not finish within 5 minutes')
                else:
                    time.sleep(2)  # what was still in the terminal's buffer
                    b, s1 = copy.counters(), copy.status()
                    t0, t1, written, lines = open(done).read().split()
                    mb = int(written) / 1e6
                    took = float(t1) - float(t0)
                    per_mb = (b['instructions'] - a['instructions']) / 1e6 / mb
                    cpu = (b['user'] + b['system'] - a['user'] - a['system']) / 1e9
                    self.record('S5n', per_mb if b['instructions'] > a['instructions'] else None,
                                f"{mb:.0f} MB, {int(lines):,} lines in {took:.1f} s ({mb / took:.1f} MB/s), {cpu:.1f} s CPU, "
                                f"{s1[0] - s0[0]} draws, app hidden {bool(s1[4])}")
                copy.hide(False)
        finally:
            copy.end()

    def s7w(self):
        repo = os.path.join(self.work, 'shop')
        for d in range(200):
            folder = os.path.join(repo, 'src', f'm{d}')
            os.makedirs(folder)
            for f in range(100):
                with open(os.path.join(folder, f'f{f}.ts'), 'w') as fh:
                    fh.write(f'export const v{d}_{f} = {d * f};\n')
        os.makedirs(os.path.join(repo, '.next'))
        with open(os.path.join(repo, '.gitignore'), 'w') as fh: fh.write('.next/\nnode_modules/\n')
        git = ['git', '-C', repo, '-c', 'user.name=perf', '-c', 'user.email=perf@example.invalid']
        for args in (['init', '-q'], ['add', '-A'], ['commit', '-qm', 'files']):
            subprocess.run(git + args, capture_output=True)
        trace = os.path.join(repo, '.next', 'trace')
        open(trace, 'w').write('{}\n')
        copy = Copy(self, 's7w').launch()
        try:
            copy.new_tab(repo, title='next dev')
            time.sleep(10)  # the project window, its sidebar and its first git read
            if not copy.status()[1]:
                self.record('S7w', None, 'SKIP: no window in view (run with --front)')
                return
            a, t0 = copy.counters(), time.time()
            in_view = copy.status()[1]
            for i in range(60):
                with open(trace, 'a') as fh: fh.write(f'{{"ts":{i}}}\n')
                time.sleep(0.5)
                in_view = min(in_view, copy.status()[1])
            b, took = copy.counters(), time.time() - t0
            if not in_view:
                # A window nobody can see runs no git refresh at all: 0% would say nothing.
                self.record('S7w', None, 'SKIP: the window left view while the writer ran (run with --front)')
                return
            git_cpu = (b['child_user'] + b['child_system'] - a['child_user'] - a['child_system']) / took / 1e7
            self.record('S7w', git_cpu, f"{copy.status()[1]}/{copy.status()[2]} windows in view")
        finally:
            copy.end()

    def g1(self, only):
        """G1, G1p, G1e and G1m: suggestions while typing at GHOST_COMMANDS commands recorded, in one zsh tab with the
        keyboard. A first round loads the record (it loads at the first suggestion asked for); the measured rounds
        follow."""
        keys = [key for key in GHOST if key in only or 'G1' in only]
        if not self.front:
            for key in keys: self.record(key, None, 'SKIP: needs the terminal to have the keyboard (run with --front)')
            return
        copy = self.copy('G1')
        seed_history(copy.home)
        copy.launch()
        try:
            copy.new_tab(self.project, title='suggestions')
            time.sleep(6)  # the shell at its prompt, its hooks loaded
            if not copy.status()[1]:
                for key in keys: self.record(key, None, 'SKIP: no window in view (run with --front)')
                return
            before = copy.counters()['footprint'] / 1e6
            copy.type('git ch\x15')
            time.sleep(6)  # the record read, the first suggestion shown
            loaded = copy.counters()['footprint'] / 1e6
            round_keys = 'git ch\x15'
            copy.type(round_keys * GHOST_ROUNDS)
            time.sleep(len(round_keys) * GHOST_ROUNDS * GHOST_GAP_MS / 1000 + 4)
            stamps = copy.ghost_stamps()
            share = [(v[1] - v[0]) * 1000 for k, v in stamps if k == 'shown' and len(v) == 2]
            presses = [v[0] for k, v in stamps if k == 'key']
            draws = [v[0] for k, v in stamps if k == 'draw']
            drawn = []
            for i, pressed in enumerate(presses):
                following = presses[i + 1] if i + 1 < len(presses) else pressed + 1
                first = next((d for d in draws if pressed <= d < following), None)
                if first is not None: drawn.append((first - pressed) * 1000)
            counted = f'{len(share)} suggestions set, {len(presses)} keys, {len(drawn)} drawn after a key'
            p50, p95 = percentile(share, 0.5), percentile(share, 0.95)
            self.record('G1', p50, counted + (f', max {max(share):.2f} ms' if share else ''))
            self.record('G1p', p95, counted)
            e50, e95 = percentile(drawn, 0.5), percentile(drawn, 0.95)
            self.record('G1e', e50, f'p95 {e95:.1f} ms; ' + counted if e95 is not None else counted)
            self.record('G1m', loaded - before, f'before the first suggestion {before:.0f} MB, with the record {loaded:.0f} MB')
        finally:
            copy.end()

    def tab_id(self, copy):
        tabs = copy.call('list_tabs')
        for window in tabs.get('windows', []):
            for tab in window.get('tabs', []):
                if tab.get('title', '').startswith('output') or tab.get('folder', '').endswith('project'):
                    return tab['id']
        return tabs['windows'][0]['tabs'][-1]['id']

    # MARK: the report

    def ratio(self, name, what, value, against, limit, detail):
        """One budget that is a ratio: `value` at most `against` × `limit`. Nothing against nothing passes."""
        if value is None or against is None:
            self.compared.append(('SKIP', name, what, '-', limit, detail + ': not measured'))
            return
        ok = value <= against * limit
        shown = f'{value / against:.2f} x' if against else ('-' if not value else 'more')
        verdict = 'PASS' if ok else ('WARN' if self.warn_only else 'FAIL')
        self.compared.append((verdict, name, what, shown, limit, detail))

    def judge(self):
        """The ratio budgets: the list against the top bar, and this build against the base, each from this run."""
        value = lambda results, key: results[key][0] if key in results else None
        for key, against, what in (('S2L', 'S2', 'the list against top, idle'), ('S4vL', 'S4v', 'the list against top, 3 agents')):
            if key in self.results and against in self.results:
                a, b = value(self.results, key), value(self.results, against)
                self.ratio(f'{key}/{against}', what, a, b, MARGIN,
                           f"{key} {a if a is None else round(a, 1)} M/s, {against} {b if b is None else round(b, 1)} M/s")
        if 'S4vL' in self.results and 'S4v' in self.results:
            rows = self.chosen.get('S4vL', {}).get('row_draws')
            tabs = self.chosen.get('S4v', {}).get('tab_draws')
            self.ratio('rows/tabs', 'list rows drawn against top tabs', rows, tabs, DRAW_MARGIN,
                       f'{rows} list-row draws, {tabs} top-tab draws')
        if 'S4hL' in self.chosen:
            rows = self.chosen['S4hL'].get('row_draws')
            if rows is None:
                self.compared.append(('SKIP', 'S4hL rows', 'list rows drawn while hidden', '-', 0, 'not counted'))
            else:
                verdict = 'PASS' if rows == 0 else ('WARN' if self.warn_only else 'FAIL')
                self.compared.append((verdict, 'S4hL rows', 'list rows drawn while hidden', str(rows), 0, f'{rows} list-row draws'))
        for key in ON_BASE:
            if key in self.results and key in self.base_results:
                a, b = value(self.results, key), value(self.base_results, key)
                self.ratio(f'{key}/base', 'this build against the base, top', a, b, MARGIN,
                           f"this build {a if a is None else round(a, 1)} M/s, base {b if b is None else round(b, 1)} M/s")
                self.notes.append(f'{key} on the base: {self.base_results[key][1]}')

    def report(self):
        failed = False
        names = {'S2': 'idle, 10 tabs', 'S2L': 'idle, 10 tabs, list', 'S4h': '3 agents, app hidden',
                 'S4hL': '3 agents hidden, list', 'S4v': '3 agents, window in view', 'S4vL': '3 agents in view, list',
                 'S5n': '10 s flood, no URL', 'S7w': 'git, .next/ writer', 'M30': '30 s after a 10 MB burst',
                 'G1': 'suggestion set, p50', 'G1p': 'suggestion set, p95', 'G1e': 'key to suggestion drawn',
                 'G1m': 'the record, 100,000'}
        for key in ORDER:
            if key not in self.results: continue
            value, detail = self.results[key]
            budget = BUDGETS[key]
            if value is None:
                verdict, shown = 'SKIP', '-'
            else:
                shown = f'{value:.1f} {UNITS[key]}'
                verdict = 'INFO' if budget is None else ('PASS' if value <= budget else ('WARN' if self.warn_only else 'FAIL'))
                failed |= verdict == 'FAIL'
            limit = '-' if budget is None else f'{budget:g}'
            print(f'{verdict:<4} {key:<4} {names[key]:<26} {shown:>18}  budget {limit:<5} {detail}')
        for verdict, name, what, shown, limit, detail in self.compared:
            failed |= verdict == 'FAIL'
            print(f'{verdict:<4} {name:<9} {what:<34} {shown:>9}  budget {limit:<5g} {detail}')
        for note in self.notes:
            print('     ' + note)
        return failed

    def finish(self):
        subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
        for folder in (os.path.join(self.real_home, 'Library/Preferences'), os.path.join(self.real_home, 'Library/Saved Application State')):
            for name in (DOMAIN + '.plist', DOMAIN + '.savedState'):
                path = os.path.join(folder, name)
                if os.path.isdir(path): shutil.rmtree(path, ignore_errors=True)
                elif os.path.exists(path): os.remove(path)
        shutil.rmtree(self.work, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(usage=__doc__)
    parser.add_argument('release')
    parser.add_argument('shim')
    parser.add_argument('ru')
    parser.add_argument('--front', action='store_true', help='bring the copy to the front (needed for S7w)')
    parser.add_argument('--only', default=','.join(ORDER))
    parser.add_argument('--warn-only', action='store_true', help='report a budget overrun as WARN and exit 0 (CI)')
    parser.add_argument('--relieve-after-burst', action='store_true',
                        help='3 s after the burst the shim asks the allocator to give freed memory back: what that is worth')
    parser.add_argument('--base', metavar='FOLDER',
                        help='a release build of the release before: S2 and S4v run on it too, and this build is held to it')
    parser.add_argument('--pairs', type=int, default=1, metavar='N',
                        help='run each compared scenario N times, in turn, and compare medians')
    args = parser.parse_args()
    only = set(args.only.split(','))
    unknown = only - set(ORDER)
    if unknown: sys.exit(f"no such scenario: {', '.join(sorted(unknown))} (there are {', '.join(ORDER)})")
    if args.base and not os.access(os.path.join(args.base, 'NextTerm'), os.X_OK):
        sys.exit(f'no NextTerm in {args.base}: build the base release with swift build -c release first')
    check = Check(args.release, args.shim, args.ru, args.front, args.warn_only, args.relieve_after_burst, args.base, args.pairs)
    watched = [os.path.join(check.real_home, d) for d in ('.claude/ide', '.gemini', '.qwen', '.copilot', '.codex')]
    listing = lambda: {d: sorted(os.listdir(d)) if os.path.isdir(d) else None for d in watched}
    untouched = listing()
    try:
        check.paired(only)
        if only & {'M30', 'S5n'}: check.memory_and_flood(only)
        if 'S7w' in only: check.s7w()
        if only & set(GHOST): check.g1(only)
        check.judge()
        failed = check.report()
    finally:
        check.finish()
    if listing() != untouched:
        print('WARNING: a folder in your home changed meanwhile:', [d for d in watched if listing()[d] != untouched[d]])
    print('perf budget: ' + ('FAILED' if failed else 'PASSED'))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
