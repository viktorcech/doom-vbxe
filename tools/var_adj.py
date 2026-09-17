#!/usr/bin/env python3
"""var_adj -- DRAC_PLAN phase 4 audit: which code leans on a variable's
NEIGHBOUR. drac.txt: "zmiennych ... zadeklarowane jako 8-bitowe albo
24-bitowe, przedeklarować na 16 albo 32 bity". Widening a variable moves its
neighbours, so every operand that reaches past the variable's own bytes (or
walks it with ,x/,y as if the next variable were more of the same) has to be
found and rewritten first.

A variable's width here is what the address map gives it today: the distance
to the next bank-0 symbol in the scanned range (.lab). For every code line in
the listing whose operand names one of the variables:
  over   name+N with N >= width           (reads/writes the next variable)
  edge   name+N with N == width-1         (a 16-bit access there spills)
  index  name,x / name,y / name+N,x|y     (a walk: extent unknown statically)

    python tools/var_adj.py rs_t1 rs_t2 ...     -> only those names
    python tools/var_adj.py --range 1300 13FF   -> every symbol in the range
Report -> bench/var_adj.txt, counts on stdout.
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import code_map                                                  # noqa: E402

LAB = os.path.join(ROOT, 'build', 'doom_bsp.lab')
OUT = os.path.join(ROOT, 'build', 'var_adj.txt')


def lab0():
    out = {}
    for ln in open(LAB, encoding='latin-1'):
        p = ln.split()
        if len(p) == 3 and p[0] == '00':
            try:
                out[p[2].upper()] = int(p[1], 16)
            except ValueError:
                pass
    return out


def declared():
    """names memory_map.inc DECLARES as variables: `name = $hhhh` or
    `name = BASE+n` (not equ constants, not other files' aliases)."""
    out = set()
    rx = re.compile(r'^([A-Za-z_][A-Za-z_0-9]*)\s*=\s*(\$[0-9A-Fa-f]{4}|[A-Z_]+\+\d+)\b')
    for ln in open(os.path.join(ROOT, 'memory_map.inc'), encoding='latin-1'):
        mt = rx.match(ln)
        if mt:
            out.add(mt.group(1).upper())
    return out


def widths(lab, lo, hi):
    """name -> (addr, width) for every symbol in [lo, hi]. The width is the gap
    to the next address DECLARED in memory_map.inc (aliases and constants that
    happen to share an address do not cut a variable short)."""
    dec = declared()
    addrs = sorted({a for n, a in lab.items() if lo <= a <= hi and n in dec})
    out = {}
    for n, a in lab.items():
        if not lo <= a <= hi:
            continue
        nx = next((b for b in addrs if b > a), hi + 1)
        out[n] = (a, nx - a)
    return out


def main():
    args = sys.argv[1:]
    lab = lab0()
    if args[:1] == ['--range']:
        lo, hi = int(args[1], 16), int(args[2], 16)
        W = widths(lab, lo, hi)
        want = set(W)
    else:
        want = {a.upper() for a in args}
        spans = [lab[n] for n in want if n in lab]
        W = widths(lab, min(spans) - 0x20, max(spans) + 0x20) if spans else {}
        missing = sorted(want - set(W))
        if missing:
            print('not in .lab (bank 0):', ', '.join(missing))
    m = code_map.load()
    pf = code_map.proc_file_map()
    rx = re.compile(r'(?<![A-Za-z_0-9?@.])([A-Za-z_?@][A-Za-z_0-9?@]*)'
                    r'(\s*\+\s*(\$[0-9A-Fa-f]+|\d+))?(\s*,\s*([xyXY]))?')
    # the accumulator width the SOURCE declares at each listing line: MADS sizes
    # immediates from .LONGA, and the skills require it to track every rep/sep,
    # so it is the static answer to "is this access 16-bit"
    longa = {}
    cur = False
    for raw in open(code_map.LST, encoding='latin-1'):
        s = raw.split(';', 1)[0].lower()
        if '.longa' in s:
            cur = 'on' in s.split('.longa', 1)[1]
        elif '.proc' in s:
            cur = False
        mt = re.match(r'^\s*(\d+)\s+(?:[0-9a-f]{2},)?([0-9a-f]{4})', raw, re.I)
        if mt:
            longa.setdefault(raw.rstrip('\n'), cur)
    lines_long = {}
    for raw, v in longa.items():
        lines_long[raw.split('\t', 1)[-1].strip()] = lines_long.get(raw.split('\t', 1)[-1].strip(), False) or v
    MEMOPS = {'lda', 'sta', 'adc', 'sbc', 'cmp', 'and', 'ora', 'eor', 'inc', 'dec',
              'asl', 'lsr', 'rol', 'ror', 'stz', 'bit', 'tsb', 'trb'}
    hits = defaultdict(list)
    for ln in m.lines:
        if ln.kind != 'code' or not ln.op:
            continue
        wide = lines_long.get(ln.src.strip(), False) and (ln.mn or '').lower() in MEMOPS
        for mt in rx.finditer(ln.op):
            name = mt.group(1).upper()
            if name not in want or name not in W:
                continue
            if mt.start() and ln.op[mt.start() - 1] in '<>':
                continue                       # #<name: an address, not a load
            _a, w = W[name]
            n = 0
            if mt.group(3):
                g = mt.group(3)
                n = int(g[1:], 16) if g.startswith('$') else int(g)
            idx = mt.group(5)
            kind = None
            if idx:
                kind = 'index'
            elif n >= w:
                kind = 'over'
            elif n == w - 1 and wide:
                kind = 'edge'                  # a 16-bit access spills into the next
            if kind:
                f = pf.get((ln.proc or '').lower(), '?')
                hits[name].append((kind, ln.bank or 0, ln.proc or '?', f,
                                   f'{ln.mn} {ln.op}'.strip()))
    out = []
    tot = defaultdict(int)
    for name in sorted(W, key=lambda k: W[k][0]):
        if name not in want:
            continue
        a, w = W[name]
        hs = hits.get(name, [])
        c = defaultdict(int)
        for h in hs:
            c[h[0]] += 1
            tot[h[0]] += 1
        out.append(f'{name:14} ${a:04X} w={w}  over={c["over"]} edge={c["edge"]} '
                   f'index={c["index"]}')
        seen = set()
        for kind, bank, proc, f, txt in hs:
            key = (kind, proc, txt)
            if key in seen:
                continue
            seen.add(key)
            out.append(f'    {kind:5} {"$01" if bank else "b0 "} {proc:18} {f:16} {txt}')
    with open(OUT, 'w') as fh:
        fh.write('\n'.join(out) + '\n')
    print(f'{len([n for n in want if n in W])} variables: '
          + ', '.join(f'{k}={v}' for k, v in sorted(tot.items())), '->',
          os.path.relpath(OUT, ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
