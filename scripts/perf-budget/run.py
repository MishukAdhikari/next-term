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

S7w and M30 need a window in view the whole time (no git refresh runs, and no terminal draws, for a window nobody
can see): with --front the copy takes the front (leave the Mac alone meanwhile). Without it, the copy's windows open
behind yours or on another Space, and each is skipped unless a window stays in view; a skipped M30 still reports
what it measured. The report says how many windows were in view, and M30 how many draws the burst made.
Usage: run.py <release folder> <shim.dylib> <ru> [--front] [--only S2,S4h,...] [--warn-only] [--relieve-after-burst]
"""
import argparse, json, os, pwd, shutil, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
DOMAIN = 'me.mishuk.nextterm.perfbudget'
# The S5n budget: 0.10.2's measurement on an M3 Pro (295-314 M/MB; 0.10.1: 359-472) plus 25%.
S5N_BUDGET = 390.0
BUDGETS = {'S2': 25.0, 'S4h': 130.0, 'S5n': S5N_BUDGET, 'S7w': 2.0, 'M30': 300.0}
# The burst: 10 MB at 1 MB a second, a build log scrolling by. The flood: as fast as it goes, for 10 s.
BURST_RATE = float(os.environ.get('NT_BURST_RATE', '1'))
BURST_KIND = os.environ.get('NT_BURST_KIND', 'log')
FLOOD_SECONDS = 10
UNITS = {'S2': 'M/s', 'S4h': 'M/s', 'S5n': 'M/MB', 'S7w': '% of a core', 'M30': 'MB'}


def sh(*args):
    return subprocess.run(args, capture_output=True, text=True).stdout


class Copy:
    """One run of the test copy, with a home of its own."""

    def __init__(self, check, name):
        self.check, self.name = check, name
        self.home = os.path.join(check.work, 'home-' + name)
        self.sock = os.path.join(self.home, 'Library/Application Support/Next Term/mcp.sock')
        self.log = os.path.join(check.work, name + '.log')
        self.status_file = os.path.join(check.work, name + '.status')
        os.makedirs(self.home)
        self.process = None

    # MARK: starting and ending

    def launch(self):
        subprocess.run(['defaults', 'delete', DOMAIN], capture_output=True)
        subprocess.run(['defaults', 'write', DOMAIN, 'NSAppSleepDisabled', '-bool', 'YES'])
        subprocess.run(['defaults', 'write', DOMAIN, 'commandLineToolOffer', 'never'])
        env = dict(os.environ)
        for key in list(env):
            if key.startswith(('XDG_', 'CLAUDE', 'CODEX', 'GEMINI', 'QWEN', 'COPILOT', 'NEXTTERM', 'NEXT_TERM')) or key in ('ZDOTDIR', 'TERM_PROGRAM'):
                del env[key]
        env.update(HOME=self.home, CFFIXED_USER_HOME=self.home, DYLD_INSERT_LIBRARIES=self.check.shim,
                   NT_SHIM_LOG=self.log, NT_SHIM_STATUS=self.status_file, NT_SHIM_FRONT='1' if self.check.front else '0')
        if env['HOME'] != self.home or env['CFFIXED_USER_HOME'] != self.home or not self.home.startswith('/tmp/ntpb.'):
            sys.exit('refusing to launch: the home is not the temporary one')
        out = open(os.path.join(self.check.work, self.name + '.out'), 'a')
        self.process = subprocess.Popen([self.check.app], env=env, stdin=subprocess.DEVNULL, stdout=out,
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
        """(draws, visible windows, windows, active, hidden) as the shim last wrote them. The shim rewrites the file
        every second: a read that catches it empty or half written is tried again, then the last whole one is used."""
        for _ in range(5):
            try:
                values = tuple(int(x) for x in open(self.status_file).read().split())
            except (OSError, ValueError):
                values = ()
            if len(values) == 5:
                self.last_status = values
                return values
            time.sleep(0.02)
        return getattr(self, 'last_status', (0, 0, 0, 0, 0))

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
        }

    def reliefs(self):
        """What the shim logged of giving memory back (--relieve-after-burst): (passes, MB returned)."""
        lines = [l.split() for l in open(self.log).read().splitlines() if l.startswith('relief ')]
        return len(lines), sum(float(l[1]) for l in lines if len(l) > 2)

    def hide(self, hidden):
        self.process.send_signal(signal.SIGUSR1 if hidden else signal.SIGUSR2)
        for _ in range(40):
            time.sleep(0.25)
            if bool(self.status()[4]) == hidden: return True
        return False


class Check:
    def __init__(self, release, shim, ru, front, warn_only, relieve_after_burst):
        self.release, self.shim, self.ru = os.path.abspath(release), os.path.abspath(shim), os.path.abspath(ru)
        self.front, self.warn_only, self.relieve_after_burst = front, warn_only, relieve_after_burst
        # A short path: a Unix socket's path must stay under 104 bytes.
        self.work = tempfile.mkdtemp(prefix='ntpb.', dir='/tmp')
        self.project = os.path.join(self.work, 'project')
        shutil.copytree(os.path.join(HERE, 'project'), self.project)
        self.app = self.make_app()
        self.real_home = pwd.getpwuid(os.getuid()).pw_dir
        self.results = {}
        self.notes = []

    def make_app(self):
        """A bundle with its own id (its own settings domain); the binary and bundles hard-linked, not copied."""
        app = os.path.join(self.work, 'NT-perfbudget.app')
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

    def s2(self):
        copy = Copy(self, 's2').launch()
        try:
            for i in range(10):
                copy.new_tab(self.project, title=f'idle {i + 1}')
                time.sleep(0.4)
            time.sleep(15)  # shells started, prompts drawn, first polls done
            m = copy.measure(20)
            self.record('S2', m['mips'] if m['counted'] else None,
                        f"{m['cpu']:.1f}% CPU, {m['draws']} draws, {m['visible']}/{m['windows']} windows in view")
        finally:
            copy.end()

    def s4h(self):
        copy = Copy(self, 's4h').launch()
        try:
            for i in range(3):
                copy.new_tab(self.project, command='bin/claude 75', title=f'agent {i + 1}')
                time.sleep(0.4)
            time.sleep(4)
            shown = copy.measure(15)
            self.notes.append(f"S4 not hidden ({shown['visible']}/{shown['windows']} windows in view): {shown['mips']:.0f} M/s, "
                              f"{shown['cpu']:.1f}% CPU, {shown['draws']} draws in {shown['seconds']:.0f} s")
            if not copy.hide(True):
                self.record('S4h', None, 'the app did not hide')
                return
            time.sleep(5)
            m = copy.measure(20)
            self.record('S4h', m['mips'] if m['counted'] else None, f"{m['cpu']:.1f}% CPU, {m['draws']} draws while hidden")
            copy.hide(False)
        finally:
            copy.end()

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

    def tab_id(self, copy):
        tabs = copy.call('list_tabs')
        for window in tabs.get('windows', []):
            for tab in window.get('tabs', []):
                if tab.get('title', '').startswith('output') or tab.get('folder', '').endswith('project'):
                    return tab['id']
        return tabs['windows'][0]['tabs'][-1]['id']

    # MARK: the report

    def report(self):
        failed = False
        names = {'S2': 'idle, 10 tabs', 'S4h': '3 agents, app hidden', 'S5n': '10 s flood, no URL',
                 'S7w': 'git, .next/ writer', 'M30': '30 s after a 10 MB burst'}
        for key in ('S2', 'S4h', 'S5n', 'S7w', 'M30'):
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
    parser.add_argument('--only', default='S2,S4h,S5n,S7w,M30')
    parser.add_argument('--warn-only', action='store_true', help='report a budget overrun as WARN and exit 0 (CI)')
    parser.add_argument('--relieve-after-burst', action='store_true',
                        help='3 s after the burst the shim asks the allocator to give freed memory back: what that is worth')
    args = parser.parse_args()
    only = set(args.only.split(','))
    check = Check(args.release, args.shim, args.ru, args.front, args.warn_only, args.relieve_after_burst)
    watched = [os.path.join(check.real_home, d) for d in ('.claude/ide', '.gemini', '.qwen', '.copilot', '.codex')]
    listing = lambda: {d: sorted(os.listdir(d)) if os.path.isdir(d) else None for d in watched}
    untouched = listing()
    try:
        if 'S2' in only: check.s2()
        if 'S4h' in only: check.s4h()
        if only & {'M30', 'S5n'}: check.memory_and_flood(only)
        if 'S7w' in only: check.s7w()
        failed = check.report()
    finally:
        check.finish()
    if listing() != untouched:
        print('WARNING: a folder in your home changed meanwhile:', [d for d in watched if listing()[d] != untouched[d]])
    print('perf budget: ' + ('FAILED' if failed else 'PASSED'))
    sys.exit(1 if failed else 0)


if __name__ == '__main__':
    main()
