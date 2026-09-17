#!/usr/bin/env python3
"""sep_windows -- DRAC_PLAN 5, static: every 8-bit window inside 16-bit code.

drac.txt: "uproscic kod ... przez ograniczenie przelaczen na 8 bitow tylko po
to, zeby nie nadpisac adresu zmienna+3". A window is a `sep #$20`/`sep #$30`
that follows a `rep #$20`/`#$21`/`#$30` in the same proc and is closed by the
next rep there. For each window the instructions inside are classified:
  var    memory op on a bank-0 variable at offset N of a W-byte cell:
           N == W-1   the LAST byte (an 8-bit variable, or the top byte of a
                      24-bit one): a 16-bit access would spill into the next
                      cell -- the width alone forces the window
           otherwise  inner byte: would not spill
  call   jsr/jsl (the callee's width contract)
  table  indexed/indirect/long operand
  io     operand in $D000-$D7FF
  other  anything else that reads/writes memory
A window whose memory work is ONLY `var` last-byte ops (plus register/flag
instructions) exists only because of the declared widths: widen those cells
(16/32 bits) and the window can go.

    python tools/sep_windows.py      -> build/sep_windows.txt, summary on stdout
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
OUT = os.path.join(ROOT, 'build', 'sep_windows.txt')
MEMOPS = {'lda', 'sta', 'adc', 'sbc', 'cmp', 'and', 'ora', 'eor', 'inc', 'dec', 'asl', 'lsr',
          'rol', 'ror', 'stz', 'bit', 'tsb', 'trb', 'ldx', 'ldy', 'stx', 'sty', 'cpx', 'cpy'}
REGOPS = {'tax', 'tay', 'txa', 'tya', 'txy', 'tyx', 'inx', 'iny', 'dex', 'dey', 'clc', 'sec',
          'pha', 'pla', 'phx', 'plx', 'phy', 'ply', 'xba', 'nop', 'clv', 'php', 'plp'}
BRANCH = {'bcc', 'bcs', 'beq', 'bne', 'bmi', 'bpl', 'bvc', 'bvs', 'bra', 'brl', 'jeq', 'jne', 'jcc',
          'jcs', 'jmi', 'jpl', 'jvc', 'jvs'}


def cells():
    """bank-0 address -> (name, width): width = gap to the next bank-0 label
    (the .ds cells and equates the map declares)."""
    addrs = {}
    for ln in open(LAB, encoding='latin-1'):
        p = ln.split()
        if len(p) != 3 or p[0] != '00':
            continue
        try:
            a = int(p[1], 16)
        except ValueError:
            continue
        if a < 0x10000:
            addrs.setdefault(a, p[2])
    srt = sorted(addrs)
    out = {}
    for i, a in enumerate(srt):
        nx = srt[i + 1] if i + 1 < len(srt) else 0x10000
        out[addrs[a].upper()] = (a, nx - a)
    return out


def main():
    m = code_map.load()
    pf = code_map.proc_file_map()
    C = cells()
    ident = re.compile(r'^\s*[#<>\[(]*([A-Za-z_?@][\w?@.]*)\s*(?:\+\s*(\$[0-9A-Fa-f]+|\d+))?\s*(,\s*[xyXY]|\))?')
    byproc = defaultdict(list)
    for ln in m.lines:
        if ln.kind == 'code' and ln.proc:
            byproc[(ln.bank or 0, ln.proc)].append(ln)
    windows = []
    for key, lns in byproc.items():
        lns.sort(key=lambda l: l.run)
        wide, cur = False, None
        for ln in lns:
            mn = (ln.mn or '').lower()
            op = (ln.op or '').split(';')[0].strip().lower()
            if mn == 'rep' and op in ('#$20', '#$21', '#$30', '#$31'):
                if cur is not None:
                    windows.append((key, cur))
                    cur = None
                wide = True
                continue
            if mn == 'sep' and op in ('#$20', '#$30'):
                if wide and cur is None:
                    cur = []
                wide = False
                continue
            if cur is not None:
                cur.append(ln)
            if mn in ('rts', 'rtl', 'rti', 'jmp', 'jml'):
                cur = None                     # the window ends the proc: not a sep..rep pair
                wide = False
    stats = defaultdict(lambda: [0, 0])
    report = []
    candidates = defaultdict(set)
    for (bank, proc), body in windows:
        kinds = defaultdict(int)
        vars_last = []
        for ln in body:
            mn = (ln.mn or '').lower()
            op = (ln.op or '').split(';')[0].strip()
            if mn in REGOPS or mn in BRANCH or not op and mn in ('asl', 'lsr', 'rol', 'ror', 'inc', 'dec'):
                continue
            if mn in ('jsr', 'jsl'):
                kinds['call'] += 1
                continue
            if mn not in MEMOPS:
                kinds['other'] += 1
                continue
            if op.startswith('#'):
                continue                       # immediate: 16-bit form is one byte longer, no memory
            mt = ident.match(op)
            if not mt or mt.group(3) or op.startswith(('(', '[')) or ln.mn.lower().endswith('.l'):
                kinds['table'] += 1
                continue
            name = mt.group(1).upper()
            off = mt.group(2)
            n = (int(off[1:], 16) if off and off.startswith('$') else int(off)) if off else 0
            if name not in C:
                kinds['other'] += 1
                continue
            a, w = C[name]
            if 0xD000 <= a + n <= 0xD7FF:
                kinds['io'] += 1
            elif n == w - 1 or w == 0:
                kinds['var-last'] += 1
                vars_last.append(f'{name.lower()}+{n}' if n else name.lower())
            else:
                kinds['var-inner'] += 1
        pure = kinds and set(kinds) <= {'var-last', 'var-inner'} and kinds.get('var-last')
        tag = 'WIDTH-ONLY' if pure else '+'.join(sorted(kinds)) or 'empty'
        stats[tag][0] += 1
        if pure:
            for v in vars_last:
                candidates[v.split('+')[0]].add(f'{proc}')
        first = body[0].run if body else 0
        report.append(f'{tag:28} {bank:02X}:{first:04X} {proc:22} {pf.get(proc.lower(), ""):18} '
                      f'{" ".join(vars_last)[:60]}')
    report.sort()
    with open(OUT, 'w') as fh:
        fh.write('\n'.join(report) + '\n\nwidth-only candidates (cell -> procs):\n')
        for v, ps in sorted(candidates.items()):
            fh.write(f'  {v:16} {", ".join(sorted(ps))}\n')
    print(f'{len(windows)} sep..rep windows inside 16-bit code:')
    for tag, (n, _) in sorted(stats.items(), key=lambda kv: -kv[1][0])[:12]:
        print(f'  {n:4}  {tag}')
    print(f'width-only cells: {len(candidates)} -> {os.path.relpath(OUT, ROOT)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
