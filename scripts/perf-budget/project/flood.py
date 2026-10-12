#!/usr/bin/env python3
"""Prints build-log-like lines with no "://" in them, then writes the start and end times, the bytes and the lines
to `done` (scripts/perf-budget.sh: the output flood and the 10 MB burst). By size (`--mb`) or for a time
(`--seconds`), as fast as the terminal takes them or at `--rate` MB a second."""
import argparse, os, time

parser = argparse.ArgumentParser()
parser.add_argument('done')
parser.add_argument('--mb', type=float, default=0)
parser.add_argument('--seconds', type=float, default=0)
parser.add_argument('--rate', type=float, default=0, help='MB a second; 0: as fast as it goes')
parser.add_argument('--kind', default='log', choices=['log', 'color', 'unicode', 'longline', 'seq'],
                    help='build-log lines; with colors; with emoji and CJK; one line with no line break (minified JS); '
                         'or numbers, one a line (`seq`)')
args = parser.parse_args()
target = int(args.mb * 1_000_000)
start = time.time()
written, n = 0, 0
while (target and written < target) or (args.seconds and time.time() - start < args.seconds):
    lines = []
    for _ in range(1000 if args.kind == 'seq' else 100):
        n += 1
        if args.kind == 'color':
            lines.append(f'\x1b[2m[{n:>7}]\x1b[0m \x1b[32mCompiling\x1b[0m \x1b[1mSources/Module{n % 97}/File{n}.swift\x1b[0m '
                         f'(0.{n % 1000:03d} s) \x1b[33mwarning:\x1b[0m var \x1b[36mx{n}\x1b[0m was never mutated\n')
        elif args.kind == 'unicode':
            lines.append(f'[{n:>7}] ✅ 测试 Module{n % 97} — Größe {n} ✨🚀 データ {chr(0x4e00 + n % 20000)}{chr(0x1f300 + n % 700)} done\n')
        elif args.kind == 'seq':
            lines.append(f'{n}\n')
        elif args.kind == 'longline':
            lines.append(f'var a{n}=function(b){{return b.map(function(c){{return c*{n % 97}}})}};')
        else:
            lines.append(f'[{n:>7}] Compiling Sources/Module{n % 97}/File{n}.swift (0.{n % 1000:03d} s) warning: var x{n} was never mutated\n')
    view = memoryview(''.join(lines).encode())
    written += len(view)
    while view:
        view = view[os.write(1, view):]
    if args.rate:
        ahead = start + written / (args.rate * 1_000_000) - time.time()
        if ahead > 0: time.sleep(ahead)
if args.kind == 'longline':
    os.write(1, b'\n')
end = time.time()
with open(args.done, 'w') as f:
    f.write(f'{start} {end} {written} {n}\n')
