#!/usr/bin/env python3
"""drac_peep -- per-instruction cycles inside bank-$01 procs, from the frame bench.

tools/tests/_peep_pc.py predates the move of the engine into Rapidus bank $01
(its symbol filter drops every 24-bit label, so a bank-$01 proc reports 0).
This one takes the bench's per_b1 (cycles per 16-bit PC fetched with PBR=1),
slices it by the proc's bank-$01 label range and annotates every PC with the
listing line (tools/drac_lst.py).

    python tools/drac_peep.py paint_col pt_dy [--frames 3] [--top 40]
"""
import bisect
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, 'tests'))
import drac_lst as L                                             # noqa: E402
import _bench_frame as B                                         # noqa: E402

args = sys.argv[1:]
frames, top = 3, 40
for flag in ('--frames', '--top'):
    if flag in args:
        i = args.index(flag)
        if flag == '--frames':
            frames = int(args[i + 1])
        else:
            top = int(args[i + 1])
        del args[i:i + 2]
WANT = args or ['paint_col']

lines, _ = L.read_lst()
src1 = {}                                   # bank-1 addr -> (proc, source)
for ln in lines:
    if ln.bank == 1 and ln.kind == 'code':
        ins, _, _ = L.decode_line(ln)
        for i in ins:
            src1.setdefault(ln.addr + i.off, (ln.proc, ln.src.split(';')[0].strip(), i.mn))

fb = B.FrameBench()
fb.bench(frames)
per = fb.per_b1
nf = max(1, len(fb.blit_log) - 1)
syms1 = sorted((a & 0xFFFF, n) for n, a in fb.s.sym.items()
               if isinstance(a, int) and (a >> 16) == 1 and '.' not in n)
sa = [a for a, _ in syms1]
tot_frame = sum(per.values()) // nf
print(f'bank-$01 cycles/frame: {tot_frame}   ({frames} frames)')
for want in WANT:
    base = fb.s.sym.get(want)
    if base is None or (base >> 16) != 1:
        print(f'  {want}: not a bank-$01 label')
        continue
    base &= 0xFFFF
    i = bisect.bisect_right(sa, base)
    end = sa[i] if i < len(sa) else 0x10000
    rows = [(a, c) for a, c in per.items() if base <= a < end and c]
    tot = sum(c for _, c in rows)
    print(f'\n== {want}  $01:{base:04X}..{end - 1:04X}   {tot // nf} cyk/f  ({len(rows)} PC) ==')
    print(f'  {"addr":6} {"cyk/f":>8} {"%":>5}  code')
    for a, c in sorted(rows, key=lambda r: -r[1])[:top]:
        p, s, mn = src1.get(a, ('?', '?', '?'))
        print(f'  ${a:04X} {c // nf:8d} {100.0 * c / max(1, tot):5.1f}  {s[:70]}')
