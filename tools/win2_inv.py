#!/usr/bin/env python3
"""win2_inv -- DRAC_PLAN phase 3 prerequisite: everything the CPU still sees
in $8000-$BFFF of bank 0, i.e. everything a permanent 16 KB MEMAC-A window
there would hide (drac.txt: "pod $8000-$BFFF włączyć okno 16k VRAM-u ...
na stałe").

From the MADS listing (code_map.load) and build/doom_bsp.lab:
  A  XEX bytes that RUN in the range in bank 0 (code / data), per owner, with
     the number of absolute references to them from bank-0 and bank-$01 code
  B  bytes the XEX only PARKS in the range (load address there, run elsewhere)
  C  runtime RAM: addresses in the range that code references (abs / long
     bank-0 operands, or '#<'/'#>' immediates naming a .lab symbol) but no XEX
     byte fills -- equ variables and work areas
  D  the current 4 KB window $9000-$9FFF: references per file (VRAM access)

    python tools/win2_inv.py          -> bench/win2_inv.txt (+ totals on stdout)
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import code_map                                                  # noqa: E402
from code_xref import OPS                                        # noqa: E402

LO, HI = 0x8000, 0xBFFF
WLO, WHI = 0x9000, 0x9FFF
LAB = os.path.join(ROOT, 'build', 'doom_bsp.lab')
OUT = os.path.join(ROOT, 'bench', 'win2_inv.txt')
WRITES = {'sta', 'stx', 'sty', 'stz', 'inc', 'dec', 'asl', 'lsr', 'rol', 'ror',
          'tsb', 'trb'}


def lab_bank0():
    by_addr = defaultdict(list)
    by_name = {}
    for ln in open(LAB, encoding='latin-1'):
        p = ln.split()
        if len(p) != 3:
            continue
        try:
            bank, addr = int(p[0], 16), int(p[1], 16)
        except ValueError:
            continue
        if bank == 0:
            by_addr[addr].append(p[2])
            by_name[p[2].upper()] = addr
    return by_addr, by_name


def main():
    m = code_map.load()
    by_addr, by_name = lab_bank0()
    pf = code_map.proc_file_map()

    # ---- A/B: XEX bytes -------------------------------------------------
    ten = []                    # [lo, hi, kind, owner, ovl]
    park = []
    covered = bytearray(0x10000)
    last_label = None
    for ln in m.lines:
        if ln.label:
            last_label = ln.label
        if ln.bank or not ln.size or ln.size <= 0:
            continue
        owner = ln.proc or last_label or '?'
        run_in = LO <= ln.run <= HI
        load_in = ln.load is not None and LO <= ln.load <= HI
        if run_in:
            hi = min(ln.run + ln.size - 1, 0xFFFF)
            for a in range(ln.run, hi + 1):
                covered[a] = 1
            t = ten[-1] if ten else None
            if t and t[3] == owner and t[2] == ln.kind and t[4] == ln.ovl \
                    and t[1] + 1 >= ln.run:
                t[1] = max(t[1], hi)
            else:
                ten.append([ln.run, hi, ln.kind, owner, ln.ovl])
        elif load_in:
            t = park[-1] if park else None
            if t and t[3] == owner and t[1] + 1 >= ln.load:
                t[1] = max(t[1], ln.load + ln.size - 1)
            else:
                park.append([ln.load, ln.load + ln.size - 1, ln.kind, owner, ln.run])

    # ---- references from all code --------------------------------------
    refs = defaultdict(list)    # addr -> [(bank, proc, mn, write, how)]
    ident = re.compile(r'[A-Za-z_?@][A-Za-z_0-9?@.]*')
    for ln in m.lines:
        if ln.kind != 'code' or not ln.bytes:
            continue
        b = ln.bytes
        mn, mode = OPS[b[0]]
        who = (ln.bank or 0, ln.proc or '?', mn)
        if mode.startswith('abs') and len(b) >= 3 and mn not in ('jsr', 'jmp'):
            refs[b[1] | b[2] << 8].append(who + (mn in WRITES, 'abs'))
        elif mode in ('long', 'longx') and len(b) >= 4 and b[3] == 0 \
                and mn not in ('jsl', 'jml'):
            refs[b[1] | b[2] << 8].append(who + (mn in WRITES, 'long'))
        elif mn in ('jsr', 'jmp') and mode == 'abs' and len(b) >= 3 and not ln.bank:
            refs[b[1] | b[2] << 8].append(who + (False, mn))
        if ln.op and '#' in ln.op and ('<' in ln.op or '>' in ln.op):
            for nm in ident.findall(ln.op):
                a = by_name.get(nm.upper())
                if a is not None and LO <= a <= HI:
                    refs[a].append(who + (False, 'imm'))

    def rsum(lo, hi):
        n0 = n1 = w = 0
        users = defaultdict(int)
        for a in range(lo, hi + 1):
            for bank, proc, mn, wr, how in refs.get(a, ()):
                if bank:
                    n1 += 1
                else:
                    n0 += 1
                w += wr
                users[(bank, proc)] += 1
        top = sorted(users.items(), key=lambda kv: -kv[1])[:4]
        return n0, n1, w, ', '.join(f'{"$01:" if k[0] else ""}{k[1]}' for k, _ in top)

    out = []
    tot = defaultdict(int)
    out.append('A  XEX bytes RUNNING in $8000-$BFFF, bank 0'
               '   (refs: bank-0 code / bank-$01 code / of them writes)')
    for lo, hi, kind, owner, ovl in ten:
        n0, n1, w, users = rsum(lo, hi)
        sz = hi - lo + 1
        tot[('A', kind, ovl)] += sz
        out.append(f'  ${lo:04X}-${hi:04X} {sz:5} {kind:5} {"ovl " if ovl else ""}'
                   f'{owner:22} {pf.get(owner.lower(), ""):18} '
                   f'r0={n0:<3} r1={n1:<3} w={w:<3} {users}')
    out.append('')
    out.append('B  XEX bytes only PARKED in $8000-$BFFF (load there, run elsewhere)')
    for lo, hi, kind, owner, run in park:
        tot[('B',)] += hi - lo + 1
        out.append(f'  ${lo:04X}-${hi:04X} {hi - lo + 1:5} {kind:5} {owner:22} run ${run:04X}')
    out.append('')
    out.append('C  runtime RAM in $8000-$BFFF outside the XEX and the window'
               ' (referenced, never loaded)')
    addrs = sorted(a for a in refs if LO <= a <= HI and not covered[a]
                   and not WLO <= a <= WHI)
    groups = []
    for a in addrs:
        if groups and a - groups[-1][1] <= 8:
            groups[-1][1] = a
        else:
            groups.append([a, a])
    for lo, hi in groups:
        names = []
        for a in range(lo, hi + 1):
            names += by_addr.get(a, [])
        n0, n1, w, users = rsum(lo, hi)
        tot[('C',)] += hi - lo + 1
        out.append(f'  ${lo:04X}-${hi:04X} {hi - lo + 1:5} '
                   f'{",".join(names[:5]) + ("..." if len(names) > 5 else ""):40} '
                   f'r0={n0:<3} r1={n1:<3} w={w:<3} {users}')
    out.append('')
    out.append('D  window $9000-$9FFF references per file (VRAM through MEMAC-A)')
    perfile = defaultdict(lambda: [0, 0])
    for a in range(WLO, WHI + 1):
        if covered[a]:
            continue
        for bank, proc, mn, wr, how in refs.get(a, ()):
            perfile[pf.get(proc.lower(), '?')][1 if bank else 0] += 1
    for f, (n0, n1) in sorted(perfile.items(), key=lambda kv: -sum(kv[1])):
        out.append(f'  {f:22} bank0 {n0:4}  bank$01 {n1:4}')
        tot[('D',)] += n0 + n1
    out.append('')
    out.append('totals:')
    for k in sorted(tot, key=str):
        out.append(f'  {k}: {tot[k]}')
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w') as f:
        f.write('\n'.join(out) + '\n')
    print('\n'.join(out[out.index('totals:'):]))
    print('->', os.path.relpath(OUT, ROOT))
    return 0


if __name__ == '__main__':
    sys.exit(main())
