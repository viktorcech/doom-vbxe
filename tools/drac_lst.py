#!/usr/bin/env python3
"""drac_lst -- independent readers of the build artefacts for the drac.txt audit.

Reads ONLY what the assembler and the build wrote:
    build/doom_bsp.lst    MADS listing  (bank, address, bytes, source per line)
    build/doom_bsp.lab    MADS labels   (bank, address, name)
    build/doom_bsp.xex    the engine as the boot loader sees it (after the splits)
    build/b1code.bin/.map the bank-$01 image split_b1.py wrote

Nothing here imports the older tools (code_map, ram_map, sim6502 ...) and nothing
trusts a source comment: instruction sizes and operand addresses are decoded from
the assembled BYTES with the 65816 opcode table below, and the table is checked
against the listing's byte counts on every code line (`selftest`).

Used by tools/drac_check.py and tools/drac_width.py. Reports -> tools/drac_out/.
"""
import json
import os
import re
import struct
from collections import namedtuple

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(ROOT, 'build')
LST = os.path.join(BUILD, 'doom_bsp.lst')
LAB = os.path.join(BUILD, 'doom_bsp.lab')
XEX = os.path.join(BUILD, 'doom_bsp.xex')
B1BIN = os.path.join(BUILD, 'b1code.bin')
B1MAP = os.path.join(BUILD, 'b1code.map')
OUTDIR = os.path.join(HERE, 'drac_out')

# ---------------------------------------------------------------------------
# 65816 opcode table: opcode -> (mnemonic, mode). Sizes follow from the mode;
# 'immM'/'immX' depend on the M/X flags (2 or 3 bytes).
# ---------------------------------------------------------------------------
_ALU = {0x0: 'ora', 0x2: 'and', 0x4: 'eor', 0x6: 'adc', 0x8: 'sta', 0xA: 'lda', 0xC: 'cmp', 0xE: 'sbc'}
OPS = {}
for hi, mn in _ALU.items():
    b = hi << 4
    OPS[b | 0x1] = (mn, '(dp,x)')
    OPS[b | 0x3] = (mn, 'sr')
    OPS[b | 0x5] = (mn, 'dp')
    OPS[b | 0x7] = (mn, '[dp]')
    OPS[b | 0x9] = (mn, 'immM')
    OPS[b | 0xD] = (mn, 'abs')
    OPS[b | 0xF] = (mn, 'long')
    b2 = (hi + 1) << 4
    OPS[b2 | 0x1] = (mn, '(dp),y')
    OPS[b2 | 0x2] = (mn, '(dp)')
    OPS[b2 | 0x3] = (mn, '(sr),y')
    OPS[b2 | 0x5] = (mn, 'dp,x')
    OPS[b2 | 0x7] = (mn, '[dp],y')
    OPS[b2 | 0x9] = (mn, 'abs,y')
    OPS[b2 | 0xD] = (mn, 'abs,x')
    OPS[b2 | 0xF] = (mn, 'long,x')
OPS[0x89] = ('bit', 'immM')                      # not sta #
OPS.update({
    0x02: ('cop', 'imm8'), 0x22: ('jsl', 'long'), 0x42: ('wdm', 'imm8'), 0x62: ('per', 'rel16'),
    0x82: ('brl', 'rel16'), 0xA2: ('ldx', 'immX'), 0xC2: ('rep', 'imm8'), 0xE2: ('sep', 'imm8'),
    0x00: ('brk', 'imm8'), 0x10: ('bpl', 'rel8'), 0x20: ('jsr', 'abs'), 0x30: ('bmi', 'rel8'),
    0x40: ('rti', 'imp'), 0x50: ('bvc', 'rel8'), 0x60: ('rts', 'imp'), 0x70: ('bvs', 'rel8'),
    0x80: ('bra', 'rel8'), 0x90: ('bcc', 'rel8'), 0xA0: ('ldy', 'immX'), 0xB0: ('bcs', 'rel8'),
    0xC0: ('cpy', 'immX'), 0xD0: ('bne', 'rel8'), 0xE0: ('cpx', 'immX'), 0xF0: ('beq', 'rel8'),
    0x04: ('tsb', 'dp'), 0x14: ('trb', 'dp'), 0x24: ('bit', 'dp'), 0x34: ('bit', 'dp,x'),
    0x44: ('mvp', 'move'), 0x54: ('mvn', 'move'), 0x64: ('stz', 'dp'), 0x74: ('stz', 'dp,x'),
    0x84: ('sty', 'dp'), 0x94: ('sty', 'dp,x'), 0xA4: ('ldy', 'dp'), 0xB4: ('ldy', 'dp,x'),
    0xC4: ('cpy', 'dp'), 0xD4: ('pei', '(dp)'), 0xE4: ('cpx', 'dp'), 0xF4: ('pea', 'abs'),
    0x06: ('asl', 'dp'), 0x16: ('asl', 'dp,x'), 0x26: ('rol', 'dp'), 0x36: ('rol', 'dp,x'),
    0x46: ('lsr', 'dp'), 0x56: ('lsr', 'dp,x'), 0x66: ('ror', 'dp'), 0x76: ('ror', 'dp,x'),
    0x86: ('stx', 'dp'), 0x96: ('stx', 'dp,y'), 0xA6: ('ldx', 'dp'), 0xB6: ('ldx', 'dp,y'),
    0xC6: ('dec', 'dp'), 0xD6: ('dec', 'dp,x'), 0xE6: ('inc', 'dp'), 0xF6: ('inc', 'dp,x'),
    0x08: ('php', 'imp'), 0x18: ('clc', 'imp'), 0x28: ('plp', 'imp'), 0x38: ('sec', 'imp'),
    0x48: ('pha', 'imp'), 0x58: ('cli', 'imp'), 0x68: ('pla', 'imp'), 0x78: ('sei', 'imp'),
    0x88: ('dey', 'imp'), 0x98: ('tya', 'imp'), 0xA8: ('tay', 'imp'), 0xB8: ('clv', 'imp'),
    0xC8: ('iny', 'imp'), 0xD8: ('cld', 'imp'), 0xE8: ('inx', 'imp'), 0xF8: ('sed', 'imp'),
    0x0A: ('asl', 'acc'), 0x1A: ('inc', 'acc'), 0x2A: ('rol', 'acc'), 0x3A: ('dec', 'acc'),
    0x4A: ('lsr', 'acc'), 0x5A: ('phy', 'imp'), 0x6A: ('ror', 'acc'), 0x7A: ('ply', 'imp'),
    0x8A: ('txa', 'imp'), 0x9A: ('txs', 'imp'), 0xAA: ('tax', 'imp'), 0xBA: ('tsx', 'imp'),
    0xCA: ('dex', 'imp'), 0xDA: ('phx', 'imp'), 0xEA: ('nop', 'imp'), 0xFA: ('plx', 'imp'),
    0x0B: ('phd', 'imp'), 0x1B: ('tcs', 'imp'), 0x2B: ('pld', 'imp'), 0x3B: ('tsc', 'imp'),
    0x4B: ('phk', 'imp'), 0x5B: ('tcd', 'imp'), 0x6B: ('rtl', 'imp'), 0x7B: ('tdc', 'imp'),
    0x8B: ('phb', 'imp'), 0x9B: ('txy', 'imp'), 0xAB: ('plb', 'imp'), 0xBB: ('tyx', 'imp'),
    0xCB: ('wai', 'imp'), 0xDB: ('stp', 'imp'), 0xEB: ('xba', 'imp'), 0xFB: ('xce', 'imp'),
    0x0C: ('tsb', 'abs'), 0x1C: ('trb', 'abs'), 0x2C: ('bit', 'abs'), 0x3C: ('bit', 'abs,x'),
    0x4C: ('jmp', 'abs'), 0x5C: ('jml', 'long'), 0x6C: ('jmp', '(abs)'), 0x7C: ('jmp', '(abs,x)'),
    0x8C: ('sty', 'abs'), 0x9C: ('stz', 'abs'), 0xAC: ('ldy', 'abs'), 0xBC: ('ldy', 'abs,x'),
    0xCC: ('cpy', 'abs'), 0xDC: ('jml', '[abs]'), 0xEC: ('cpx', 'abs'), 0xFC: ('jsr', '(abs,x)'),
    0x0E: ('asl', 'abs'), 0x1E: ('asl', 'abs,x'), 0x2E: ('rol', 'abs'), 0x3E: ('rol', 'abs,x'),
    0x4E: ('lsr', 'abs'), 0x5E: ('lsr', 'abs,x'), 0x6E: ('ror', 'abs'), 0x7E: ('ror', 'abs,x'),
    0x8E: ('stx', 'abs'), 0x9E: ('stz', 'abs,x'), 0xAE: ('ldx', 'abs'), 0xBE: ('ldx', 'abs,y'),
    0xCE: ('dec', 'abs'), 0xDE: ('dec', 'abs,x'), 0xEE: ('inc', 'abs'), 0xFE: ('inc', 'abs,x'),
})
assert len(OPS) == 256, len(OPS)

MODE_SIZE = {'imp': 1, 'acc': 1, 'imm8': 2, 'dp': 2, 'dp,x': 2, 'dp,y': 2, '(dp)': 2, '(dp,x)': 2,
             '(dp),y': 2, '[dp]': 2, '[dp],y': 2, 'sr': 2, '(sr),y': 2, 'rel8': 2, 'rel16': 3,
             'abs': 3, 'abs,x': 3, 'abs,y': 3, '(abs)': 3, '(abs,x)': 3, '[abs]': 3, 'move': 3,
             'long': 4, 'long,x': 4}
ABS16 = {'abs', 'abs,x', 'abs,y', '(abs)', '(abs,x)', '[abs]'}
DPMODES = {'dp', 'dp,x', 'dp,y', '(dp)', '(dp,x)', '(dp),y', '[dp]', '[dp],y'}
LONGM = {'long', 'long,x'}
# memory ops whose access WIDTH follows the M flag / the X flag
M_OPS = {'ora', 'and', 'eor', 'adc', 'sta', 'lda', 'cmp', 'sbc', 'bit', 'tsb', 'trb', 'stz',
         'asl', 'rol', 'lsr', 'ror', 'inc', 'dec'}
X_OPS = {'ldx', 'ldy', 'stx', 'sty', 'cpx', 'cpy'}
WRITES = {'sta', 'stz', 'stx', 'sty', 'tsb', 'trb', 'asl', 'rol', 'lsr', 'ror', 'inc', 'dec'}
BRANCH = {'bra', 'brl', 'bpl', 'bmi', 'bvc', 'bvs', 'bcc', 'bcs', 'bne', 'beq'}

Line = namedtuple('Line', 'bank addr bytes src file lineno proc blk kind')
# kind: 'code' (an instruction / MADS macro line), 'data' (bytes, no instruction), 'none'
Ins = namedtuple('Ins', 'mn mode size ea eabank imm off')

_LINE = re.compile(r'^\s*(\d+)\s+(?:([0-9A-F]{2}),)?([0-9A-F]{4})(-([0-9A-F]{4})>)?((?:\s[0-9A-F]{2})*)\s*\t?(.*)$')
_PSEUDO = {'dta', 'ins', 'org', 'equ', 'ert', 'ini', 'run', 'opt', 'icl', 'smb', 'blk', 'lmb', 'nmb', 'rmb'}
_MNEMS = {v[0] for v in OPS.values()} | {
    # MADS pseudo instructions that assemble to several real ones
    'jeq', 'jne', 'jcc', 'jcs', 'jmi', 'jpl', 'jvc', 'jvs', 'inw', 'dew', 'adw', 'sbw', 'phr', 'plr',
    'cpw', 'mwa', 'mva', 'mwx', 'mvx', 'mwy', 'mvy', 'adb', 'sbb', 'inl', 'del', 'add', 'sub', 'cpl',
    'cpd', 'ccp', 'spl', 'spb', 'spw', 'stw', 'ldw', 'sta', 'lda'}


def read_lab():
    """({(bank, NAME): addr}, {(bank, addr): [names]})"""
    by_name, by_addr = {}, {}
    for ln in open(LAB, encoding='latin-1'):
        p = ln.split()
        if len(p) != 3:
            continue
        try:
            bank, addr = int(p[0], 16), int(p[1], 16)
        except ValueError:
            continue
        by_name.setdefault((bank, p[2].upper()), addr)
        by_addr.setdefault((bank, addr), []).append(p[2])
    return by_name, by_addr


def read_xex(path=XEX):
    """[(lo, hi, bytes)] in file order; INIT/RUN vectors are ordinary blocks."""
    data = open(path, 'rb').read()
    i = 0
    out = []
    while i + 4 <= len(data):
        lo, hi = struct.unpack_from('<HH', data, i)
        if lo == 0xFFFF:
            i += 2
            continue
        n = hi - lo + 1
        out.append((lo, hi, bytes(data[i + 4:i + 4 + n])))
        i += 4 + n
    return out


def read_b1():
    img = open(B1BIN, 'rb').read()
    runs = [tuple(r) for r in json.load(open(B1MAP))]
    return img, runs


def decode(bank, addr, bts, off, m8, x8):
    """One instruction at bts[off:]. m8/x8: True = 8-bit, False = 16-bit."""
    op = bts[off]
    mn, mode = OPS[op]
    if mode == 'immM':
        size = 2 if m8 else 3
    elif mode == 'immX':
        size = 2 if x8 else 3
    else:
        size = MODE_SIZE[mode]
    b = bts[off:off + size]
    ea = eabank = imm = None
    if len(b) == size:
        if mode in ('immM', 'immX', 'imm8'):
            imm = b[1] | (b[2] << 8 if size == 3 else 0)
        elif mode in ABS16:
            ea = b[1] | (b[2] << 8)
            eabank = bank if mn in ('jsr', 'jmp', 'jml', 'pea') else 0     # DBR assumed 0
        elif mode in LONGM:
            ea = b[1] | (b[2] << 8)
            eabank = b[3]
        elif mode in DPMODES:
            ea = b[1]                                                    # D assumed 0
            eabank = 0
        elif mode == 'rel8':
            d = b[1] - 256 if b[1] > 127 else b[1]
            ea = (addr + off + 2 + d) & 0xFFFF
            eabank = bank
        elif mode == 'rel16':
            d = b[1] | (b[2] << 8)
            d = d - 65536 if d > 32767 else d
            ea = (addr + off + 3 + d) & 0xFFFF
            eabank = bank
    return Ins(mn, mode, size, ea, eabank, imm, off)


def decode_line(ln, m8=None, x8=None):
    """All instructions in one code line. With the flags unknown every M/X
    combination is tried and the one that covers the line's bytes exactly is
    taken. Returns (instructions, (m8, x8) used, exact)."""
    cands = []
    if m8 is None or x8 is None:
        for mm in ((m8,) if m8 is not None else (True, False)):
            for xx in ((x8,) if x8 is not None else (True, False)):
                cands.append((mm, xx))
    else:
        cands.append((m8, x8))
    best = None
    for mm, xx in cands:
        out, i = [], 0
        while i < len(ln.bytes):
            ins = decode(ln.bank, ln.addr, ln.bytes, i, mm, xx)
            out.append(ins)
            i += ins.size
        exact = i == len(ln.bytes)
        if exact:
            return out, (mm, xx), True
        if best is None:
            best = (out, (mm, xx), False)
    return best


def read_lst(path=LST):
    """Every listing line that carries an address. Returns (lines, blocks):
    blocks = [(bank, lo, hi)] in listing order (the `lo-hi>` marks)."""
    lines, blocks = [], []
    cur_file = '?'
    proc_stack = []
    blk = None
    for raw in open(path, encoding='latin-1'):
        raw = raw.rstrip('\n')
        if raw.startswith('Source:'):
            name = raw.split(':', 1)[1].strip()
            if name.lower().endswith(('.asm', '.inc')):
                cur_file = name
            continue
        m = _LINE.match(raw)
        if not m:
            continue
        lineno = int(m.group(1))
        bank = int(m.group(2), 16) if m.group(2) else 0
        addr = int(m.group(3), 16)
        if m.group(5):
            blk = (bank, addr, int(m.group(5), 16))
            blocks.append(blk)
        bts = bytes(int(b, 16) for b in m.group(6).split())
        src = m.group(7)
        code = src.split(';', 1)[0]
        toks = code.split()
        mn = None
        for t in toks[:2]:                     # `label mnem ...` or `mnem ...`
            tl = t.lower()
            base = tl.split('.')[0] if not tl.startswith('.') else tl
            if base in _MNEMS or base in _PSEUDO or tl.startswith('.'):
                mn = base
                break
        low = code.strip().lower()
        if low.startswith('.proc'):
            p = low.split()
            proc_stack.append(p[1] if len(p) > 1 else '?')
        elif low.startswith('.endp'):
            if proc_stack:
                proc_stack.pop()
        proc = proc_stack[-1] if proc_stack else ''
        kind = 'none'
        if bts:
            kind = 'code' if (mn in _MNEMS and mn not in _PSEUDO) else 'data'
        lines.append(Line(bank, addr, bts, src, cur_file, lineno, proc, blk, kind))
    return lines, blocks


def selftest(lines):
    """Code lines whose bytes no M/X combination decodes exactly: the opcode
    table (or the code/data split) disagrees with MADS there."""
    bad = []
    for ln in lines:
        if ln.kind == 'code':
            _, _, exact = decode_line(ln)
            if not exact:
                bad.append(ln)
    return bad


def in_runs(addr, runs):
    return any(lo <= addr <= hi for lo, hi in runs)


def ensure_outdir():
    os.makedirs(OUTDIR, exist_ok=True)
    return OUTDIR


def hx(v, w=4):
    return f'${v:0{w}X}'
