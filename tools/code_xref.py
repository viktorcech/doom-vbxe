#!/usr/bin/env python3
"""code_xref -- DRAC_PLAN phase 2: every instruction that treats CODE as data.

Code that runs out of bank $01 fetches its opcodes there, but an absolute
`sta abs` still writes bank 0 (DBR = 0). So a self-modifying store aimed at a
code byte patches the copy the CPU is NOT executing, and a read of a code byte
reads the bank-0 copy. This decodes every listed instruction (tools/code_map.py,
byte-exact against the XEX) and reports each absolute/long operand that lands
inside a code line:

  write   sta/stx/sty/stz/inc/dec/asl/lsr/rol/ror/tsb/trb -> code  (SMC)
  read    lda/ldx/ldy/adc/sbc/cmp/cpx/cpy/and/ora/eor/bit -> code
  pea     a pushed constant that is a code address (rts/rtl dispatch)

    python tools/code_xref.py        -> bench/code_xref.txt
"""
import bisect
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import code_map                                                 # noqa: E402

_T = '''brk imm8|ora dpxi|cop imm8|ora sr|tsb dp|ora dp|asl dp|ora dpil|php imp|ora immm|asl acc|phd imp|tsb abs|ora abs|asl abs|ora long|
bpl rel|ora dpiy|ora dpi|ora sriy|trb dp|ora dpx|asl dpx|ora dpily|clc imp|ora absy|inc acc|tcs imp|trb abs|ora absx|asl absx|ora longx|
jsr abs|and dpxi|jsl long|and sr|bit dp|and dp|rol dp|and dpil|plp imp|and immm|rol acc|pld imp|bit abs|and abs|rol abs|and long|
bmi rel|and dpiy|and dpi|and sriy|bit dpx|and dpx|rol dpx|and dpily|sec imp|and absy|dec acc|tsc imp|bit absx|and absx|rol absx|and longx|
rti imp|eor dpxi|wdm imm8|eor sr|mvp bm|eor dp|lsr dp|eor dpil|pha imp|eor immm|lsr acc|phk imp|jmp abs|eor abs|lsr abs|eor long|
bvc rel|eor dpiy|eor dpi|eor sriy|mvn bm|eor dpx|lsr dpx|eor dpily|cli imp|eor absy|phy imp|tcd imp|jml long|eor absx|lsr absx|eor longx|
rts imp|adc dpxi|per rel16|adc sr|stz dp|adc dp|ror dp|adc dpil|pla imp|adc immm|ror acc|rtl imp|jmp absi|adc abs|ror abs|adc long|
bvs rel|adc dpiy|adc dpi|adc sriy|stz dpx|adc dpx|ror dpx|adc dpily|sei imp|adc absy|ply imp|tdc imp|jmp absxi|adc absx|ror absx|adc longx|
bra rel|sta dpxi|brl rel16|sta sr|sty dp|sta dp|stx dp|sta dpil|dey imp|bit immm|txa imp|phb imp|sty abs|sta abs|stx abs|sta long|
bcc rel|sta dpiy|sta dpi|sta sriy|sty dpx|sta dpx|stx dpy|sta dpily|tya imp|sta absy|txs imp|txy imp|stz abs|sta absx|stz absx|sta longx|
ldy immx|lda dpxi|ldx immx|lda sr|ldy dp|lda dp|ldx dp|lda dpil|tay imp|lda immm|tax imp|plb imp|ldy abs|lda abs|ldx abs|lda long|
bcs rel|lda dpiy|lda dpi|lda sriy|ldy dpx|lda dpx|ldx dpy|lda dpily|clv imp|lda absy|tsx imp|tyx imp|ldy absx|lda absx|ldx absy|lda longx|
cpy immx|cmp dpxi|rep imm8|cmp sr|cpy dp|cmp dp|dec dp|cmp dpil|iny imp|cmp immm|dex imp|wai imp|cpy abs|cmp abs|dec abs|cmp long|
bne rel|cmp dpiy|cmp dpi|cmp sriy|pei dp|cmp dpx|dec dpx|cmp dpily|cld imp|cmp absy|phx imp|stp imp|jml absil|cmp absx|dec absx|cmp longx|
cpx immx|sbc dpxi|sep imm8|sbc sr|cpx dp|sbc dp|inc dp|sbc dpil|inx imp|sbc immm|nop imp|xba imp|cpx abs|sbc abs|inc abs|sbc long|
beq rel|sbc dpiy|sbc dpi|sbc sriy|pea abs|sbc dpx|inc dpx|sbc dpily|sed imp|sbc absy|plx imp|xce imp|jsr absxi|sbc absx|inc absx|sbc longx'''
OPS = [tuple(e.split()) for e in _T.replace('\n', '').split('|')]
assert len(OPS) == 256

WRITES = {'sta', 'stx', 'sty', 'stz', 'inc', 'dec', 'asl', 'lsr', 'rol', 'ror',
          'tsb', 'trb'}
READS = {'lda', 'ldx', 'ldy', 'adc', 'sbc', 'cmp', 'cpx', 'cpy', 'and', 'ora',
         'eor', 'bit'}
ABS = {'abs', 'absx', 'absy'}
LONG = {'long', 'longx'}


def group(ln):
    """None for resident code; the listing block for anything that RUNS
    somewhere other than where the XEX puts it (lifted overlays, the
    two-address blocks copied into place at runtime -- AMOVL, B1CODE)."""
    return ln.blk if (ln.ovl or ln.load != ln.run) else None


def code_ranges(m):
    """(bank, group) -> sorted [(lo, hi_excl, line)] of every code line.
    group is None for resident code and the listing block number for a lifted
    overlay: the overlays all run at $1000-$14FF, on top of the render
    arrays and of each other, so they only ever count against themselves."""
    out = defaultdict(list)
    for ln in m.lines:
        if ln.kind == 'code':
            out[(ln.bank, group(ln))].append((ln.run, ln.run + ln.size, ln))
    for b in out:
        out[b].sort(key=lambda t: t[0])
    return out


def hit(ranges, bank, addr):
    rs = ranges.get(bank)
    if not rs:
        return None
    i = bisect.bisect_right(rs, (addr, 1 << 30)) - 1
    if i >= 0 and rs[i][0] <= addr < rs[i][1]:
        return rs[i][2]
    return None


def staged_blocks(m):
    """Listing blocks the XEX stages into reserved RAM for a boot one-shot
    (ram_map.STAGED: xdl at TEX_STAGE, RECIP_STAGE, ...). Their code is dead
    long before the frame loop, and it overlaps live variables."""
    from ram_map import STAGED
    out = set()
    for i, (lo, hi, _bk) in enumerate(m.lblocks):
        if any(lo >= slo and hi <= shi for slo, shi, _w in STAGED):
            out.add(i)
    return out


def scan(m, resident=False):
    ranges = code_ranges(m)
    staged = staged_blocks(m) if resident else set()
    if resident:                 # drop staged code from the target ranges too
        for key in list(ranges):
            ranges[key] = [r for r in ranges[key] if r[2].blk not in staged]
    sites = []
    for ln in m.lines:
        if ln.kind != 'code' or not ln.bytes:
            continue
        if resident and (group(ln) is not None or ln.blk in staged):
            continue
        mn, mode = OPS[ln.bytes[0]]
        b = ln.bytes
        if mode in ABS and len(b) >= 3:
            addr, bank = b[1] | b[2] << 8, 0              # DBR = 0
        elif mode in LONG and len(b) >= 4:
            addr, bank = b[1] | b[2] << 8, b[3]
        else:
            continue
        if mn in WRITES:
            kind = 'write'
        elif mn in READS:
            kind = 'read'
        elif mn == 'pea':
            kind = 'pea'
        else:
            continue
        t = hit(ranges, (bank, None), addr)
        if t is None and group(ln) is not None:
            t = hit(ranges, (bank, group(ln)), addr)
        if t is None and bank == ln.bank and group(ln) is None:
            pass
        if t is None:
            continue
        sites.append((kind, ln, bank, addr, t))
    return sites


def main():
    m = code_map.load()
    resident = '--resident' in sys.argv
    sites = scan(m, resident)
    L = []
    A = L.append
    cnt = defaultdict(int)
    for kind, *_ in sites:
        cnt[kind] += 1
    A(f'code_xref  {len(sites)} instructions whose absolute/long operand is a CODE byte: '
      + ', '.join(f'{k} {v}' for k, v in sorted(cnt.items())))
    A('  (abs = DBR bank 0; from bank-$01 code a write here patches the bank-0 copy)')
    A('')
    A(f'  {"kind":5} {"at":>7} {"proc":20} {"file":20} {"target":>8} {"target proc":20}  source')
    for kind, ln, bank, addr, t in sorted(sites, key=lambda s: (s[0], s[1].bank, s[1].run)):
        pf = m.proc.get((ln.bank, ln.proc), {}).get('file', '?') if ln.proc else '?'
        A(f'  {kind:5} {ln.bank:02X}:{ln.run:04X} {str(ln.proc)[:20]:20} {pf[:20]:20} '
          f'{bank:02X}:{addr:04X} {str(t.proc)[:20]:20}  {ln.src.strip()[:60]}')
    txt = '\n'.join(L)
    out = os.path.join(code_map.ROOT, 'bench', 'code_xref_resident.txt' if resident
                       else 'code_xref.txt')
    with open(out, 'w', encoding='utf-8') as f:
        f.write(txt + '\n')
    print('\n'.join(L[:3]))
    print(f'-> {out}')


if __name__ == '__main__':
    main()
