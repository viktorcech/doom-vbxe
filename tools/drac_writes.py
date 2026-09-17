#!/usr/bin/env python3
"""drac_writes -- CPU WRITES per 16 KB window per frame, from the frame bench.

Why: Altirra's Rapidus (alt-src rapidus.cpp UpdateSRAMWindows) routes every
write into a fast window through the write-through SHADOW layer while MCR
bit 5 is set -- and that layer is not FastBus, so each such write waits for
the next chip-bus cycle and takes all of it (cpumachine.inl wait_slow_cycle):
~11-16 core cycles instead of 1. boot.asm clears it for $0000-$3FFF only
(CMCR bit 6). The sim6502 model prices every write at 1 core cycle, so this
cost is invisible to the bench -- but not to Altirra or the real machine.
Reads by region the bench already reports; this counts the WRITES.

    python tools/drac_writes.py [--frames 3]      -> bench/drac_writes.txt
"""
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, 'tests'))
import _bench_frame as B                                         # noqa: E402
import sim6502                                                   # noqa: E402

frames = 3
if '--frames' in sys.argv:
    frames = int(sys.argv[sys.argv.index('--frames') + 1])

fb = B.FrameBench()
S = type(fb.s)                       # the bench's sim class (a Sim subclass)
counts = Counter()                   # (phase, window) -> writes
by_pc = Counter()                    # (window, pc) -> writes, in-game only
state = {'in_game': False, 'pc': 0}
orig_wr = S.wr


def wr(self, a, v):
    a16 = a & 0xFFFF
    w = a16 >> 14
    if fb.in_game:                   # the bench sets it at the first frame mark
        counts[('game', w)] += 1
        by_pc[(w, state['pc'])] += 1
    else:
        counts[('boot', w)] += 1
    return orig_wr(self, a, v)


S.wr = wr
# the bench flips its own in_game flag when the first frame starts; mirror it
# by watching frame marks: simplest is to count everything and split by the
# bench's blit_log length afterwards -- so record the write total at each
# frame mark instead.
marks = []
orig_step = S.step


def step(self, pc):
    state['pc'] = pc
    return orig_step(self, pc)


S.step = step
fb.bench(frames)
nf = max(1, len(fb.blit_log) - 1)
lines = [f'CPU writes per 16 KB window ({frames} frames, {nf} in-game frames)',
         f'  {"window":14} {"boot":>9} {"in-game/frame":>14}   chip cost if write-through (x11 core cyk)']
for w in range(4):
    g = counts[('game', w)] // nf
    note = '' if w == 0 else f'{g * 11:9d} cyk = {g * 11 / 19730.0:5.1f} ms'
    lines.append(f'  ${w * 0x4000:04X}-${w * 0x4000 + 0x3FFF:04X} {counts[("boot", w)]:9d} {g:14d}   {note}')
lines.append('')
lines.append('in-game write sites outside $0000-$3FFF, top 40 (window, pc, writes/frame):')
sym = fb.s.sym
names = sorted((a & 0xFFFF, n) for n, a in sym.items() if isinstance(a, int) and '.' not in n)
import bisect
for (w, pc), n in [kv for kv in by_pc.most_common(400) if kv[0][0] != 0][:40]:
    i = bisect.bisect_right([a for a, _ in names], pc) - 1
    lines.append(f'  W{w} ${pc:04X} {n // nf:8d}   near {names[i][1] if i >= 0 else "?"}')
out = os.path.join(os.path.dirname(HERE), 'bench', 'drac_writes.txt')
open(out, 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print('\n'.join(lines))
