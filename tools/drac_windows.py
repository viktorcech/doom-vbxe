#!/usr/bin/env python3
"""drac_windows -- which 8-bit sep..rep windows in the bank-$01 engine exist
ONLY because a variable is too narrow (drac.txt point 5).

A window = `sep #$20` inside 16-bit code, up to the next `rep #$20` in the same
proc. Every memory operand inside is classified from the assembled bytes:
    last    the LAST byte of a bank-0 variable cell (a 16-bit op there would
            spill into the next cell) -> the declared width forces the window
    inner   another byte of a cell (16-bit would not spill)
    table   indexed / indirect / long operand (a walk, unknown extent)
    io      $D000-$D7FF
    call    jsr / jsl (the callee's width contract)
    other   any other memory operand (arrays, VRAM window, ...)
A window is WIDTH-ONLY when its memory work is nothing but `last`/`inner` cell
bytes: widen those cells and it can go. Register-only instructions inside
(pha, xba, asl A, cmp #imm ...) are listed so a byte-semantics window is not
mistaken for a width one.

    python tools/drac_windows.py [--all]   -> tools/drac_out/drac_windows.txt
"""
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drac_lst as L                                             # noqa: E402

REGONLY = {'pha', 'pla', 'phx', 'plx', 'phy', 'ply', 'xba', 'tax', 'tay', 'txa', 'tya', 'txy',
           'tyx', 'inx', 'iny', 'dex', 'dey', 'clc', 'sec', 'nop', 'php', 'plp', 'clv', 'cld', 'sed',
           'sei', 'cli'}


def cells_map(lines, by_addr):
    """bank-0 address -> (name, width) for every label the code names as a
    memory operand (constants that merely share the range are skipped)."""
    memnames = set()
    for ln in lines:
        if ln.kind != 'code':
            continue
        ins, _, _ = L.decode_line(ln)
        if not any(i.mode in L.DPMODES | L.ABS16 | L.LONGM for i in ins):
            continue
        for w in re.findall(r'[A-Za-z_?@][\w?@]*', ln.src.split(';', 1)[0]):
            memnames.add(w.upper())
    addrs = sorted(a for (b, a) in by_addr if b == 0 and a < 0x10000
                   and any(n.upper() in memnames for n in by_addr[(b, a)]))
    cells = {}
    for k, a in enumerate(addrs):
        nx = addrs[k + 1] if k + 1 < len(addrs) else 0x10000
        cells[a] = (by_addr[(0, a)][0], nx - a)
    return cells


def main():
    L.ensure_outdir()
    by_name, by_addr = L.read_lab()
    lines, _ = L.read_lst()
    cells = cells_map(lines, by_addr)
    addrs = sorted(cells)
    byproc = defaultdict(list)
    for ln in lines:
        if ln.kind == 'code' and ln.bank == 1:
            byproc[(ln.file, ln.proc)].append(ln)
    windows = []
    for (f, p), lns in byproc.items():
        st = [None, None]
        wide, cur = False, None
        for ln in lns:
            ins, (m8, x8), exact = L.decode_line(ln, st[0], st[1])
            if not exact:
                ins, (m8, x8), exact = L.decode_line(ln)
            if exact and any(i.mode == 'immM' for i in ins):
                st[0] = m8
            if exact and any(i.mode == 'immX' for i in ins):
                st[1] = x8
            for i in ins:
                if i.mn == 'rep' and i.imm & 0x20:
                    if cur is not None:
                        windows.append((f, p, cur))
                        cur = None
                    wide, st[0] = True, False
                    if i.imm & 0x10: st[1] = False
                elif i.mn == 'sep' and i.imm & 0x20:
                    if wide and cur is None:
                        cur = [ln.addr + i.off, []]
                    wide, st[0] = False, True
                    if i.imm & 0x10: st[1] = True
                else:
                    if i.mn in ('rts', 'rtl', 'rti', 'jmp', 'jml', 'bra', 'brl'):
                        cur = None                 # the window ends the proc / a tail
                        wide = False
                    elif cur is not None:
                        cur[1].append((ln, i))
    rows, stats = [], Counter()
    widen = defaultdict(set)
    for f, p, (at, body) in windows:
        kinds, lastv, regs = Counter(), [], []
        for ln, i in body:
            if i.mn in REGONLY or i.mode == 'acc':
                regs.append(i.mn)
                continue
            if i.mode in ('immM', 'immX', 'imm8'):
                if i.mn in ('cmp', 'and', 'ora', 'eor', 'adc', 'sbc', 'bit', 'lda'):
                    regs.append(i.mn + '#')
                continue
            if i.mn in ('jsr', 'jsl'):
                kinds['call'] += 1
                continue
            if i.mn in L.BRANCH:
                continue
            if i.ea is None:
                continue
            if i.mode in L.LONGM or i.mode not in ('dp', 'abs'):
                kinds['table'] += 1
                continue
            if 0xD000 <= i.ea <= 0xD7FF:
                kinds['io'] += 1
                continue
            base = max((a for a in addrs if a <= i.ea), default=None)
            if base is None or i.ea >= base + cells[base][1]:
                kinds['other'] += 1
                continue
            name, w = cells[base]
            if i.ea == base + w - 1:
                kinds['last'] += 1
                lastv.append(f'{name.lower()}+{i.ea - base}' if i.ea > base else name.lower())
            else:
                kinds['inner'] += 1
        pure = set(kinds) <= {'last', 'inner'} and kinds['last'] > 0
        tag = 'WIDTH-ONLY' if pure else ('empty' if not kinds and not regs else '+'.join(sorted(kinds)) or 'regs-only')
        stats[tag] += 1
        if pure:
            for v in lastv:
                widen[v.split('+')[0]].add(p)
        rows.append((tag, f, p, at, ' '.join(sorted(set(lastv))), ' '.join(sorted(set(regs)))))
    rows.sort(key=lambda r: (r[0] != 'WIDTH-ONLY', r[1], r[3]))
    outp = os.path.join(L.OUTDIR, 'drac_windows.txt')
    with open(outp, 'w', encoding='utf-8') as fh:
        for tag, f, p, at, lv, rg in rows:
            fh.write(f'{tag:22} {f:22} {p:20} $01:{at:04X}  {lv:40} [{rg}]\n')
        fh.write('\nWIDTH-ONLY cells -> procs:\n')
        for v, ps in sorted(widen.items()):
            fh.write(f'  {v:16} {", ".join(sorted(ps))}\n')
    print(f'{len(windows)} windows in bank-$01 code:')
    for tag, n in stats.most_common():
        print(f'  {n:4}  {tag}')
    print(f'WIDTH-ONLY cells: {len(widen)}  -> {os.path.relpath(outp, L.ROOT)}')
    if '--all' in sys.argv:
        for tag, f, p, at, lv, rg in rows:
            if tag == 'WIDTH-ONLY':
                print(f'  {f:20} {p:18} {at:04X} {lv} [{rg}]')
    return 0


if __name__ == '__main__':
    sys.exit(main())
