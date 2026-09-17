#!/usr/bin/env python3
"""b1_check -- DRAC_PLAN step 2: the guard for code that lives in two banks.

drac.txt moves the code to bank $01 as the MADS segment B1. The assembler lays
it out, but it cannot see what a 16-bit address means at run time: a `jsr`
stays in the PROGRAM bank, an absolute data operand reads the DATA bank (0).
This decodes every listed instruction (tools/code_map.py, byte-exact against
the XEX and build/b1code.bin) and fails on:

  xjump   jsr/jmp/branch whose target is code only in the OTHER bank
  xlong   jsl/jml whose 24-bit target is not code in that bank
          (MENU_RUN, the runtime overlay window, is allowed from bank 0)
  xdata   an absolute data operand in bank-$01 code that names a bank-$01
          label (it would read bank 0 at that address)
  xret    a jsl target whose proc has no rtl, or a jsr target in bank $01
          that only returns with rtl

and lists, without failing:

  xind    jmp (abs) / jmp (abs,x) / jsr (abs,x) in bank-$01 code (the pointer
          bank and the target bank need a human look)

    python tools/b1_check.py            -> build/b1_check.txt, exit 1 on errors
"""
import bisect
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import code_map                                                 # noqa: E402
from code_xref import OPS, group                                # noqa: E402

BRANCH = {0x90, 0xB0, 0xF0, 0xD0, 0x30, 0x10, 0x50, 0x70, 0x80}
IDENT = re.compile(r'[A-Za-z_?@][\w?@.]*')
DATA_MODES = {'abs', 'absx', 'absy'}
MENU_RUN = (0x1000, 0x14FF)                   # memory_map.inc MENU_RUN..END


def lab_banks():
    """NAME -> (bank, addr) out of build/doom_bsp.lab (bank 0 or 1 only)."""
    out = {}
    for line in open(os.path.join(code_map.ROOT, 'build', 'doom_bsp.lab'),
                     encoding='latin-1'):
        p = line.split()
        if len(p) != 3:
            continue
        try:
            bk, adr = int(p[0], 16), int(p[1], 16)
        except ValueError:
            continue
        if bk < 0x100:
            out[p[2].upper()] = (bk, adr)
    return out


def ranges(m):
    """bank -> code ranges. Bank 0 counts the lifted overlays and the runtime-
    copied blocks too: their code is not resident, but a bank-0 jump to it
    (wi stage 2 at $4100, the finale's FIN2_RESUME) is exactly right."""
    out = defaultdict(list)
    for ln in m.lines:
        if ln.kind == 'code' and (group(ln) is None or ln.bank == 0):
            out[ln.bank].append((ln.run, ln.run + ln.size, ln))
    for b in out:
        out[b].sort(key=lambda t: t[0])
    return out


def resolve(labs, ln, idt):
    """A label as the assembler sees it from this line: a ?local belongs to
    the enclosing proc (MADS lists it as PROC.?NAME)."""
    if idt.startswith('?'):
        if ln.proc:
            return labs.get(f'{ln.proc}.{idt}'.upper())
        return None
    return labs.get(idt.upper())


def hit(rs, bank, addr):
    r = rs.get(bank, [])
    i = bisect.bisect_right(r, (addr, 1 << 30)) - 1
    return r[i][2] if i >= 0 and r[i][0] <= addr < r[i][1] else None


def main():
    m = code_map.load()
    rs = ranges(m)
    labs = lab_banks()
    procnames = {n.lower() for (_b, n) in m.proc}
    errs, notes = [], []
    rets = defaultdict(set)                   # (bank, proc) -> {'rts','rtl'}
    for ln in m.lines:
        if ln.kind == 'code' and ln.bytes and ln.proc:
            if ln.bytes[0] == 0x60:
                rets[(ln.bank, ln.proc)].add('rts')
            elif ln.bytes[0] == 0x6B:
                rets[(ln.bank, ln.proc)].add('rtl')

    def where(ln):
        return f'{ln.bank:02X}:{ln.run:04X} {ln.proc or "?"}: {ln.src.strip()[:60]}'

    for ln in m.lines:
        # overlays and runtime-copied blocks RUN in bank 0 (MENU_RUN, the map
        # slot): check their calls too -- a menu `jsr vw_apply` into a proc
        # that moved is as wrong as a resident one. (Bank-$01 two-address code
        # has no such block left; skip it.)
        if ln.kind != 'code' or not ln.bytes or (group(ln) is not None and ln.bank != 0):
            continue
        op = ln.bytes[0]
        b = ln.bytes
        if op in BRANCH and len(b) == 5 and b[1] == 3 and b[2] == 0x4C:
            op, b = 0x4C, b[2:]                 # MADS jeq/jne/..: Bxx +3 / jmp abs
        mn, mode = OPS[op]
        other = 1 - ln.bank if ln.bank in (0, 1) else 0
        if op in (0x20, 0x4C) and len(b) >= 3 or op in BRANCH and len(b) == 2 \
                or op == 0x82 and len(b) == 3:
            if op in (0x20, 0x4C):
                tgt = b[1] | b[2] << 8
            elif op == 0x82:
                o = b[1] | b[2] << 8
                tgt = (ln.run + 3 + (o - 65536 if o > 32767 else o)) & 0xFFFF
            else:
                tgt = (ln.run + 2 + (b[1] - 256 if b[1] > 127 else b[1])) & 0xFFFF
            here = hit(rs, ln.bank, tgt)
            # the runtime overlay window -- but only for a target that is not a
            # bank-$01 label: the B1 segment starts at $1000 too, and an address
            # test alone waved snd_resume's `jmp init_level` through
            tlabels = [resolve(labs, ln, i) for i in IDENT.findall(ln.op.split(';')[0])]
            tbank1 = any(t is not None and t[0] == 1 for t in tlabels)
            overlay = ln.bank == 0 and MENU_RUN[0] <= tgt <= MENU_RUN[1] and not tbank1
            # By LABEL first: the two banks share 16-bit addresses, so a bank-0
            # `jsr X` can land on unrelated bank-0 code at X's bank-$01 address
            # and an address test alone would call that fine.
            lbl_bank = None
            for idt in IDENT.findall(ln.op.split(';')[0]):
                bl = resolve(labs, ln, idt)
                if bl is not None:
                    lbl_bank = bl[0]
                    break
            if lbl_bank is not None and lbl_bank != ln.bank and not overlay:
                errs.append(('xjump', f'{mn} to a bank-${lbl_bank:02X} label from bank '
                                      f'${ln.bank:02X} -- {where(ln)}'))
            elif here is None and not overlay and hit(rs, other, tgt) is not None:
                errs.append(('xjump', f'{mn} ${tgt:04X} lands on bank-${other:02X} '
                                      f'code only -- {where(ln)}'))
            if here is not None and op == 0x20 and ln.bank == 1:
                r = rets.get((1, here.proc), set())
                if r == {'rtl'}:
                    errs.append(('xret', f'jsr into {here.proc}, which only rtl\'s '
                                         f'-- {where(ln)}'))
        elif op in (0x22, 0x5C) and len(b) >= 4:
            tgt, tb = b[1] | b[2] << 8, b[3]
            here = hit(rs, tb, tgt)
            # bank-$01 code long-jumping into BANK-0 code that returns with rts
            # (the runtime overlays at MENU_RUN do): that rts pops the 2-byte
            # frame a bank-$01 jsr left and lands in bank 0 -- enter it through
            # a bank-0 `jsr X / rtl` wrapper instead
            if ln.bank == 1 and tb == 0 and op == 0x5C and \
                    MENU_RUN[0] <= tgt <= MENU_RUN[1]:
                errs.append(('xlong', f'jml into the bank-0 overlay window from bank '
                                      f'$01: its rts returns to the wrong bank -- {where(ln)}'))
            if here is None and not (tb == 0 and MENU_RUN[0] <= tgt <= MENU_RUN[1]):
                errs.append(('xlong', f'{mn} ${tb:02X}:{tgt:04X} is not code in that '
                                      f'bank -- {where(ln)}'))
            elif here is not None and op == 0x22:
                r = rets.get((tb, here.proc), set())
                # a WRAPPER label (no .proc): `jsr X` then `rtl` right behind it
                wrap = (here.bytes and here.bytes[0] == 0x20 and
                        (nxt := hit(rs, tb, here.run + 3)) is not None and
                        nxt.bytes and nxt.bytes[0] == 0x6B)
                if 'rtl' not in r and not wrap:
                    errs.append(('xret', f'jsl into {here.proc}, which has no rtl '
                                         f'-- {where(ln)}'))
        elif mode in DATA_MODES and mn not in ('jmp', 'jsr') and 'DBR1' in ln.src:
            pass                                # phk/plb around it: DBR = bank $01
        elif mode in DATA_MODES and mn not in ('jmp', 'jsr'):
            # a ?local is not in the .lab: catch the self-modifying store by
            # ADDRESS -- bank-$01 code whose absolute operand lands inside its
            # own proc's code patches bank 0 at that address instead
            if ln.bank == 1 and len(b) >= 3 and '?' in ln.op.split(';')[0] \
                    and 'B1CODE_BASE' not in ln.op.upper():
                t = hit(rs, 1, b[1] | b[2] << 8)
                if t is not None and t.proc == ln.proc:
                    errs.append(('xdata', f'{mn} into its own bank-$01 code at '
                                          f'${b[1] | b[2] << 8:04X} with a 16-bit '
                                          f'operand (bank 0) -- {where(ln)}'))
                    continue
            # any bank: an absolute operand is DBR = bank 0, so a bank-$01
            # label there reads/writes the wrong bank (bank-0 code poking a
            # variable that moved inside a B1 proc counts too)
            for idt in IDENT.findall(ln.op.split(';')[0]):
                bl = resolve(labs, ln, idt)
                if bl and bl[0] == 1 and 'B1CODE_BASE' not in ln.op.upper():
                    errs.append(('xdata', f'{mn} names bank-$01 label {idt} with a '
                                          f'16-bit operand (bank 0) -- {where(ln)}'))
                    break
        if ln.bank == 1 and op in (0x6C, 0x7C, 0xFC, 0xDC):
            notes.append(('xind', where(ln)))
        # xptr: a CODE address loaded as an immediate (lda #label, #<label) --
        # it ends up in a patched jsr operand or a pushed return address, and
        # that jump happens in the bank of the code that TAKES it. A label from
        # the other bank is the 2026-09-13 muzzle-flash crash: wp_flight put
        # lt_seg_flash ($3985, bank 0) into process_seg's jsr in bank $01.
        if mode in ('immm', 'immx') or mn == 'pea':
            for idt in IDENT.findall(ln.op.split(';')[0]):
                # only a real CODE label -- a proc or proc.local; an equ whose
                # value happens to fall inside some code (TH_WROW, INFRATICS)
                # is a number, not an address anyone jumps to
                if idt.lower() not in procnames and '.' not in idt:
                    continue
                bl = resolve(labs, ln, idt)
                if bl is None:
                    continue
                t = hit(rs, bl[0], bl[1])
                # snd_init stores snd_irq into the OS's RAM vector VIMIRQ: that
                # IRQ is taken by the OS in bank 0, never jumped to from here
                if idt.lower() == 'snd_irq':
                    continue
                if t is not None and t.proc and bl[0] != ln.bank:
                    errs.append(('xptr', f'{mn} #{idt}: a bank-${bl[0]:02X} code address '
                                         f'taken by bank-${ln.bank:02X} code -- {where(ln)}'))
                    break
    # ...and the same in data: dta a(label) / v(label) naming code in a bank the
    # table's user may not run in -- listed for a look, not failed
    for ln in m.lines:
        if ln.kind == 'data' and ln.mn == 'dta':
            for idt in IDENT.findall(ln.op.split(';')[0]):
                bl = labs.get(idt.upper())
                if bl and bl[0] == 1:
                    notes.append(('xtab', f'dta names bank-$01 code {idt} -- {where(ln)}'))
                    break

    L = [f'b1_check  {len(errs)} error(s), {len(notes)} note(s)']
    for k, t in errs:
        L.append(f'  ERROR {k:5} {t}')
    for k, t in notes:
        L.append(f'  note  {k:5} {t}')
    txt = '\n'.join(L)
    out = os.path.join(code_map.ROOT, 'build', 'b1_check.txt')
    with open(out, 'w', encoding='utf-8') as f:
        f.write(txt + '\n')
    print('\n'.join(L[:25]))
    if len(L) > 25:
        print(f'  ... {len(L) - 25} more in {out}')
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(main())
