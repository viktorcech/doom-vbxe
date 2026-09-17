#!/usr/bin/env python3
"""drac_check -- is the build what drac.txt asked for? Read from the ARTEFACTS
(build/doom_bsp.xex, .lst, .lab, b1code.bin), never from comments.

  1. RAM: bytes the XEX loads into each Rapidus 16 KB window of bank 0, and
     what sits in bank $01. $8000-$BFFF must carry nothing but the boot-time
     staging chunks that b1_stage_copy moves to bank $01 before MEMAC is on.
  2. WINDOW: every write to VBXE MEMAC_CTL ($D65E) decoded -> base + size.
  3. VARIABLES: width of every cell in the D0 segment and the zero page (gap
     to the next label), and every 16-bit access that reaches PAST its cell
     (the "zmienna+3" overwrite drac.txt talks about). Plus a count of the
     8-bit sep..rep windows left in the bank-$01 code.

    python tools/drac_check.py          -> tools/drac_out/drac_check.txt
"""
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drac_lst as L                                             # noqa: E402

out = []


def say(s=''):
    out.append(s)
    print(s)


def equ(name):
    src = open(os.path.join(L.ROOT, 'memory_map.inc'), encoding='latin-1').read()
    m = re.search(r'^\s*%s\s+equ\s+(\$[0-9A-Fa-f]+)' % name, src, re.M)
    return int(m.group(1)[1:], 16) if m else None


def main():
    L.ensure_outdir()
    by_name, by_addr = L.read_lab()
    lines, blocks = L.read_lst()
    bad = L.selftest(lines)
    say(f'listing: {len(lines)} lines with bytes, opcode-table selftest: '
        f'{len(bad)} undecodable code lines' + ('' if not bad else ' (see end)'))

    # ---- 1. RAM ---------------------------------------------------------------
    say('\n== 1. RAM: what the XEX really loads (bank 0) and what is in bank $01 ==')
    xex = L.read_xex()
    stage = equ('B1STAGE')
    copier = by_name.get((0, 'B1_STAGE_COPY'))
    b1img, b1runs = L.read_b1()
    resident, staged, vectors = [], [], []
    for k, (lo, hi, data) in enumerate(xex):
        if lo in (0x02E0, 0x02E2) and hi == lo + 1:
            vectors.append((lo, data[0] | (data[1] << 8)))
            continue
        nxt = xex[k + 1] if k + 1 < len(xex) else None
        if lo == stage and nxt and nxt[0] == 0x02E2 and (nxt[2][0] | (nxt[2][1] << 8)) == copier:
            staged.append((lo, hi, data))
            continue
        resident.append((lo, hi, data))
    # staged chunks -> rebuild the bank-$01 image and compare with b1code.bin
    rebuilt = bytearray(0x10000)
    cov = []
    for lo, hi, data in staged:
        dst = data[0] | (data[1] << 8)
        n = data[2] | (data[3] << 8)
        rebuilt[dst:dst + n] = data[4:4 + n]
        cov.append((dst, dst + n - 1))
    same = all(rebuilt[a:b + 1] == b1img[a:b + 1] for a, b in b1runs)
    b1_bytes = sum(b - a + 1 for a, b in b1runs)
    say(f'  bank $01 code image: {b1_bytes} B in runs '
        + ', '.join(f'{L.hx(a)}-{L.hx(b)}' for a, b in b1runs)
        + f'  ({len(staged)} staging chunks at {L.hx(stage)}, INIT -> b1_stage_copy {L.hx(copier)})')
    say(f'  staged chunks rebuild b1code.bin byte for byte: {"YES" if same else "NO"}')
    other_b1 = defaultdict(int)
    for bank, lo, hi in blocks:
        if bank == 1 and not L.in_runs(lo, b1runs):
            other_b1[(lo, hi)] += 1
    if other_b1:
        say(f'  bank-$01 listing blocks OUTSIDE b1code.map: {len(other_b1)}')
    win = Counter()
    for lo, hi, data in resident:
        for a in range(lo, hi + 1):
            win[a >> 14] += 1
    total0 = sum(win.values())
    say(f'  bank 0 resident bytes: {total0} in {len(resident)} XEX blocks (each block = one fixed org)')
    for w in range(4):
        say(f'    ${w * 0x4000:04X}-${w * 0x4000 + 0x3FFF:04X}: {win[w]:6} B')
    in_w2 = [(lo, hi) for lo, hi, _ in resident if hi >= 0x8000 and lo <= 0xBFFF]
    say(f'  resident blocks touching $8000-$BFFF: {len(in_w2)} '
        + ('-> EMPTY, only the VBXE window lives there' if not in_w2 else
           ', '.join(f'{L.hx(a)}-{L.hx(b)}' for a, b in in_w2)))
    say(f'  staging chunks touching $8000-$BFFF: {len(staged)} (boot-only; plain RAM until setup_memac)')
    run = [v for k, v in vectors if k == 0x02E0]
    say(f'  RUN vector: {L.hx(run[-1]) if run else "none"}  '
        f'(main = {L.hx(by_name.get((0, "MAIN"), 0))})')
    # code vs data inside the resident bank-0 bytes, from the listing
    kind_at = {}
    for ln in lines:
        if ln.bank == 0 and ln.bytes:
            for i in range(len(ln.bytes)):
                kind_at[ln.addr + i] = ln.kind
    cd = Counter()
    for lo, hi, _ in resident:
        for a in range(lo, hi + 1):
            cd[kind_at.get(a, 'unlisted')] += 1
    say(f'  ... of which code {cd["code"]} B, data {cd["data"]} B, not in listing {cd["unlisted"]} B')
    # overlays: bank-0 listing blocks that the XEX no longer carries (lifted by split_menu_ovl)
    have = {(lo, hi) for lo, hi, _ in xex}
    lifted = [(lo, hi) for bank, lo, hi in blocks if bank == 0 and (lo, hi) not in have and hi > lo + 8]
    lb = sum(hi - lo + 1 for lo, hi in lifted)
    say(f'  bank-0 code copied in at RUNTIME (overlays lifted out of the XEX): {len(lifted)} blocks, {lb} B: '
        + ', '.join(f'{L.hx(a)}-{L.hx(b)}' for a, b in lifted))
    # any instruction whose operand address is in $8000-$BFFF -> must be window traffic
    hits = Counter()
    names = defaultdict(set)
    for ln in lines:
        if ln.kind != 'code':
            continue
        ins, _, _ = L.decode_line(ln)
        for i in ins:
            if i.ea is not None and i.eabank == 0 and 0x8000 <= i.ea <= 0xBFFF \
                    and i.mode in L.ABS16 | L.LONGM and i.mn not in ('jsr', 'jmp', 'jml'):
                s = ln.src.split(';')[0]
                tag = 'MEMW' if 'MEMW' in s or 'FIN2_WIN' in s or 'B1STAGE' in s else 'OTHER'
                hits[tag] += 1
                if tag == 'OTHER':
                    names[ln.proc or ln.file].add(s.strip()[:50])
    say(f'  instructions addressing $8000-$BFFF: {hits["MEMW"]} via MEMW/MEMW16/B1STAGE symbols, '
        f'{hits["OTHER"]} other')
    for p, ss in sorted(names.items()):
        say(f'    OTHER in {p}: ' + ' | '.join(sorted(ss))[:150])

    # ---- 2. WINDOW ------------------------------------------------------------
    say('\n== 2. VBXE MEMAC-A window: every write to MEMAC_CTL ($D65E) ==')
    prev_imm = {}
    for ln in lines:
        if ln.kind != 'code':
            continue
        ins, _, _ = L.decode_line(ln)
        for i in ins:
            if i.imm is not None and i.mn in ('lda', 'ldx', 'ldy'):
                prev_imm[(ln.bank, ln.proc)] = i.imm
            if i.ea == 0xD65E and i.eabank == 0 and i.mn in L.WRITES:
                v = prev_imm.get((ln.bank, ln.proc))
                if v is None:
                    say(f'  {ln.file}:{ln.proc}: {i.mn} MEMAC_CTL <- computed value')
                else:
                    say(f'  {ln.file}:{ln.proc}: MEMAC_CTL <- ${v:02X} = base ${(v >> 4) << 12:04X}, '
                        f'size {4 << (v & 3)} KB, CPU {"on" if v & 8 else "off"}, ANTIC {"on" if v & 4 else "off"}')
    sel = Counter()
    for ln in lines:
        if ln.kind != 'code':
            continue
        ins, _, _ = L.decode_line(ln)
        for i in ins:
            if i.ea == 0xD65F and i.eabank == 0 and i.mn in L.WRITES:
                sel[(ln.bank, ln.file, ln.proc)] += 1
    say(f'  BANK_SEL ($D65F) writes: {sum(sel.values())} in {len(sel)} procs '
        f'(bank $01 code: {sum(v for k, v in sel.items() if k[0] == 1)}, bank 0: '
        f'{sum(v for k, v in sel.items() if k[0] == 0)})')
    for (bank, f, p), n in sorted(sel.items()):
        say(f'    {"$01" if bank else "b0 "} {f:22} {p:20} {n}')

    # ---- 3. VARIABLES ---------------------------------------------------------
    say('\n== 3. Variables: cell widths (D0 segment + zero page) and 16-bit spills ==')
    d0lo, d0len = equ('D0SEG_BASE'), None
    src = open(os.path.join(L.ROOT, 'memory_map.inc'), encoding='latin-1').read()
    m = re.search(r'^D0SEG_LEN\s+equ\s+\$([0-9A-F]+)-D0SEG_BASE', src, re.M)
    d0hi = int(m.group(1), 16) - 1 if m else d0lo + 0xEDB
    ranges = [('zero page', 0x80, 0xFF), ('D0 segment', d0lo, d0hi)]
    # a label is a VARIABLE only if some instruction names it as a memory
    # operand (constants such as TITLE_Y also fall into these address ranges)
    memnames = set()
    for ln in lines:
        if ln.kind != 'code':
            continue
        code = ln.src.split(';', 1)[0]
        ins, _, _ = L.decode_line(ln)
        if not any(i.mode in L.DPMODES | L.ABS16 | L.LONGM for i in ins):
            continue
        for w in re.findall(r'[A-Za-z_?@][\w?@]*', code):
            memnames.add(w.upper())
    cells = {}
    for tag, lo, hi in ranges:
        addrs = sorted(a for (b, a) in by_addr if b == 0 and lo <= a <= hi
                       and any(n.upper() in memnames for n in by_addr[(b, a)]))
        # a cell ends where the next label starts; the last one at the range end
        for k, a in enumerate(addrs):
            nx = addrs[k + 1] if k + 1 < len(addrs) else hi + 1
            cells[a] = (by_addr[(0, a)][0], nx - a, tag)
    # only cells the CODE touches count as variables (equates that alias code do not)
    touched = Counter()
    spills = []
    unknown_m = 0
    state = {}                              # (bank, file, proc) -> [m8, x8], tracked rep/sep
    for ln in lines:
        if ln.kind != 'code':
            continue
        st = state.setdefault((ln.bank, ln.file, ln.proc), [None, None])
        ins, (m8, x8), exact = L.decode_line(ln, st[0], st[1])
        if not exact and (st[0] is not None or st[1] is not None):
            ins, (m8, x8), exact = L.decode_line(ln)        # tracked state contradicts the bytes
        if exact and any(i.mode == 'immM' for i in ins):
            st[0] = m8
        if exact and any(i.mode == 'immX' for i in ins):
            st[1] = x8
        for i in ins:
            if i.mn == 'rep':
                if i.imm & 0x20: st[0] = False
                if i.imm & 0x10: st[1] = False
            elif i.mn == 'sep':
                if i.imm & 0x20: st[0] = True
                if i.imm & 0x10: st[1] = True
            elif i.mn in ('plp', 'rti', 'xce'):
                st[0] = st[1] = None
        for i in ins:
            if i.ea is None or i.eabank != 0 or i.mn in L.BRANCH | {'jsr', 'jmp', 'jml', 'jsl', 'pea'}:
                continue
            if i.mode not in L.DPMODES | {'abs', 'long'}:
                continue
            # which cell holds the address?
            base = max((a for a in cells if a <= i.ea), default=None)
            if base is None or i.ea >= base + cells[base][1]:
                continue
            name, w, tag = cells[base]
            touched[base] += 1
            width = 1
            if i.mn in L.M_OPS and i.mode != 'immM':
                if st[0] is None:
                    unknown_m += 1
                width = 2 if st[0] is False else 1
            elif i.mn in L.X_OPS:
                width = 2 if st[1] is False else 1
            if width == 2 and i.ea + 1 >= base + w:
                nb = cells.get(base + w, ('?',))[0]
                spills.append((ln.bank, ln.file, ln.proc, name, i.ea - base, w, nb, ln.src.split(';')[0].strip()))
    hist = Counter()
    for a, n in touched.items():
        hist[(cells[a][2], min(cells[a][1], 5))] += 1
    for tag, _, _ in ranges:
        parts = [f'{w}B: {hist[(tag, w)]}' for w in (1, 2, 3, 4, 5) if hist[(tag, w)]]
        say(f'  {tag}: {sum(v for (t, w), v in hist.items() if t == tag)} cells the code touches -> '
            + ', '.join(parts).replace('5B', '>=5B'))
    say(f'  16-bit accesses that reach past their own cell: {len(spills)} '
        f'(M-flag unknown at {unknown_m} cell accesses -- counted as 8-bit)')
    seen = set()
    for bank, f, p, name, off, w, nb, s in spills:
        key = (p, name, s)
        if key in seen:
            continue
        seen.add(key)
        say(f'    {"$01" if bank else "b0 "} {f:20} {p:18} {name}+{off} (w={w}) -> next cell {nb}: {s[:40]}')
    # sep..rep windows in the bank-$01 (engine) code, per file
    windows = Counter()
    for f, pl in defaultdict(list, {}).items():
        pass
    byproc = defaultdict(list)
    for ln in lines:
        if ln.kind == 'code' and ln.bank == 1:
            byproc[(ln.file, ln.proc)].append(ln)
    for (f, p), lns in byproc.items():
        wide = False
        for ln in lns:
            ins, _, _ = L.decode_line(ln)
            for i in ins:
                if i.mn == 'rep' and i.imm & 0x20:
                    wide = True
                elif i.mn == 'sep' and i.imm & 0x20:
                    if wide:
                        windows[f] += 1
                    wide = False
                elif i.mn in ('rts', 'rtl', 'rti'):
                    wide = False
    say(f'  8-bit sep..rep windows inside 16-bit code, bank $01: {sum(windows.values())}')
    for f, n in sorted(windows.items(), key=lambda kv: -kv[1])[:12]:
        say(f'    {f:22} {n}')
    if bad:
        say('\nundecodable code lines (opcode table vs MADS):')
        for ln in bad[:10]:
            say(f'  {ln.file}:{ln.lineno} {ln.bytes.hex()} {ln.src.strip()[:60]}')
    open(os.path.join(L.OUTDIR, 'drac_check.txt'), 'w', encoding='utf-8').write('\n'.join(out) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
