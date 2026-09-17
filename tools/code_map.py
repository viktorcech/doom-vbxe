#!/usr/bin/env python3
"""code_map -- DRAC_PLAN 0.2 / phase 1: what the XEX puts where, from the MADS
listing, byte-exact against the XEX itself.

Every listing line that emits bytes gets a run address (where the CPU sees it),
a load address (where the XEX stores it -- differs inside `org run, load`), a
size (address delta to the next line, so long `dta` runs are counted whole), a
kind (code / data / other), the enclosing .proc and the program bank it runs
in. On top of that: the static control-flow graph (jsr/jsl/jmp/jml/brl/branch
targets decoded from the listed bytes) between procs.

    python tools/code_map.py              # summary -> bench/code_map.txt
    python tools/code_map.py --procs      # + every proc

    import code_map; m = code_map.load()  # for probes (tools/tests/_probe_*)
"""
import bisect
import os
import re
import struct
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LST = os.path.join(ROOT, 'build', 'doom_bsp.lst')
XEX = os.path.join(ROOT, 'build', 'doom_bsp.xex')

# 65816 instruction mnemonics + MADS long-branch/skip/repeat forms + the MADS
# macro commands (they list as one line with all the bytes of the expansion).
INSN = set('''adc and asl bcc bcs beq bit bmi bne bpl bra brk brl bvc bvs clc cld
cli clv cmp cop cpx cpy dea dec dex dey eor ina inc inx iny jml jmp jsl jsr lda
ldx ldy lsr mvn mvp nop ora pea pei per pha phb phd phk php phx phy pla plb pld
plp plx ply rep rol ror rti rtl rts sbc sec sed sei sep sta stp stx sty stz tax
tay tcd tcs tdc trb tsb tsc tsx txa txs txy tya tyx wai wdm xba xce
jeq jne jcc jcs jmi jpl jvc jvs seq sne scc scs smi spl svc svs
req rne rcc rcs rmi rpl rvc rvs add sub adb sbb adw sbw phr plr inw inl ind
dew del ded mva mvx mvy mwa mwx mwy cpb cpw cpl cpd'''.split())
DATA = set('''dta .byte .by .word .wo .long .dword .he .sb .cb ins .ds .fl'''.split())

BRANCH = {0x90, 0xB0, 0xF0, 0xD0, 0x30, 0x10, 0x50, 0x70, 0x80}

LINE = re.compile(r'^\s*(\d+) (.*)$')
# MADS prefixes a line assembled inside a `.segdef ... bank` segment with the
# virtual bank: "01,2000-200C> AD 04 30" / "01,2005 20 11 20".
ADDR = re.compile(r'^(?:([0-9A-F]{2}),)?([0-9A-F]{4})$')
BLK = re.compile(r'^(?:([0-9A-F]{2}),)?([0-9A-F]{4})-([0-9A-F]{4})>$')


def xex_blocks(path=XEX):
    d = open(path, 'rb').read()
    i = 2 if d[:2] == b'\xff\xff' else 0
    out = []
    while i + 4 <= len(d):
        lo, hi = struct.unpack_from('<HH', d, i)
        i += 4
        if lo == 0xFFFF:
            continue
        n = hi - lo + 1
        out.append((lo, hi, d[i:i + n]))
        i += n
    return out


def proc_file_map():
    """.proc NAME -> the .asm file that declares it (listing Source: lines do not
    announce the return from an icl, so the listing alone cannot say)."""
    out = {}
    pat = re.compile(r'^\s*\.proc\s+(\w+)', re.I)
    for fn in sorted(os.listdir(ROOT)):
        if fn.endswith(('.asm', '.inc')):
            for ln in open(os.path.join(ROOT, fn), encoding='latin-1'):
                m = pat.match(ln)
                if m:
                    out.setdefault(m.group(1).lower(), fn)
    return out


def _split(src):
    """source text -> (label, mnemonic, operand). Leading tabs are listing
    padding; a first token that is a mnemonic is never a label."""
    s = src.split(';', 1)[0].rstrip()
    if not s.strip():
        return None, '', ''
    col0 = not s[:1].isspace()
    toks = s.split(None, 2)
    lab = None
    t0 = toks[0]
    base = lambda t: re.sub(r'\.[bwlzq]$', '', t.lower().lstrip(':'))
    if col0 and base(t0) not in INSN and base(t0) not in DATA \
            and not t0.startswith('.') and not t0.startswith(':'):
        lab = t0
        toks = toks[1:]
        if toks and len(toks) == 1 and ' ' in s.split(None, 1)[1].strip():
            toks = s.split(None, 1)[1].strip().split(None, 1)
    if not toks:
        return lab, '', ''
    mn = toks[0]
    op = toks[1] if len(toks) > 1 else ''
    if mn.startswith(':'):                     # :COUNT dta ...  (repeat prefix)
        rest = op.split(None, 1)
        mn = rest[0] if rest else ''
        op = rest[1] if len(rest) > 1 else ''
    return lab, base(mn) if not mn.startswith('.') else mn.lower(), op


class Line:
    __slots__ = ('n', 'run', 'load', 'size', 'bytes', 'plus', 'kind', 'mn',
                 'op', 'label', 'proc', 'bank', 'blk', 'src', 'lst', 'ovl')

    def __init__(self, **kw):
        self.ovl = False
        for k, v in kw.items():
            setattr(self, k, v)


def _listing_blocks(lst):
    out = []
    for raw in open(lst, encoding='latin-1'):
        m = LINE.match(raw.rstrip('\n'))
        if not m:
            continue
        f = m.group(2).split('\t', 1)[0].split()
        if f and f[0] == 'FFFF>':
            f = f[1:]
        if f and BLK.match(f[0]):
            b = BLK.match(f[0])
            out.append((int(b.group(2), 16), int(b.group(3), 16),
                        int(b.group(1), 16) if b.group(1) else 0))
    return out


def load(lst=LST, xex=XEX):
    """Parse the listing into Line records and cross-check against the XEX.
    Listing blocks the shipped XEX does not carry are the overlays
    tools/split_menu_ovl.py lifts out after mads: they are kept, flagged ovl."""
    lines = []
    blocks = xex_blocks(xex)
    # tools/split_b1.py inserts blocks MADS never listed: each bank-$01 chunk
    # staged at B1STAGE plus the INIT block behind it. Drop them before lining
    # the XEX up with the listing.
    m_st = re.search(r'^\s*B1STAGE\s+equ\s+\$([0-9A-Fa-f]+)',
                     open(os.path.join(ROOT, 'memory_map.inc'),
                          encoding='latin-1').read(), re.M)
    if m_st:
        stage = int(m_st.group(1), 16)
        kept, skip_init = [], False
        for b in blocks:
            if b[0] == stage:
                skip_init = True
                continue
            if skip_init and (b[0], b[1]) == (0x02E2, 0x02E3):
                skip_init = False
                continue
            skip_init = False
            kept.append(b)
        blocks = kept
    lbl = _listing_blocks(lst)
    xmap, j = [], 0
    for lo, hi, bk in lbl:
        if bk:                                  # a bank segment: tools/split_b1.py
            xmap.append(None)                   #   takes it out of the XEX
            continue
        if j < len(blocks) and (blocks[j][0], blocks[j][1]) == (lo, hi):
            xmap.append(j)
            j += 1
        else:
            xmap.append(None)
    if j != len(blocks):
        raise SystemExit(f'code_map: only {j} of {len(blocks)} XEX blocks line up '
                         f'with the listing')
    bi = -1                                     # current LISTING block index
    load_off = 0                                # run - load in this block
    pending = None                              # block-start line awaiting run addr
    procs = []                                  # stack of names
    org_hint = None
    two_addr_bank = 0
    org_text = ''
    seg = None
    for lno, raw in enumerate(open(lst, encoding='latin-1')):
        raw = raw.rstrip('\n')
        m = LINE.match(raw)
        if not m:
            continue
        rest = m.group(2)
        if '\t' in rest:
            field, src = rest.split('\t', 1)
        elif ' + ' in rest:                     # long data line: "ADDR> 00 00 + SRC"
            field, src = rest.split(' + ', 1)
            field += ' +'
        else:
            field, src = rest, ''
        src = src.lstrip('\t')
        field = field.strip()
        lab, mn, op = _split(src)
        if mn == '.proc':
            procs.append(op.split()[0] if op else '?')
        elif mn == '.endp':
            if procs:
                procs.pop()
        elif mn == '.segment':
            seg = op.split()[0] if op else '?'
        elif mn == '.endseg':
            seg = None
            org_text = ''                       # MADS drops the load address too
        elif mn == 'org':
            org_text = op
            org_hint = None                     # run address of a 2-addr block
        if not field or field.startswith('='):
            # `label = *` right behind a two-address org names its RUN address
            if field.startswith('=') and ',' in org_text and org_hint is None:
                hv = re.match(r'=\s*(?:[0-9A-F]{2},)?([0-9A-F]{4})', field)
                if hv:
                    org_hint = int(hv.group(1), 16)
            continue
        toks = field.split()
        if toks and toks[0] == 'FFFF>':
            toks = toks[1:]
        if not toks:
            continue
        is_blk = BLK.match(toks[0])
        seg_bank = None
        if is_blk:
            bi += 1
            lo = int(is_blk.group(2), 16)
            addr_field = lo
            hexb = toks[1:]
            if is_blk.group(1):
                seg_bank = int(is_blk.group(1), 16)
        elif ADDR.match(toks[0]):
            am = ADDR.match(toks[0])
            addr_field = int(am.group(2), 16)
            hexb = toks[1:]
            if am.group(1):
                seg_bank = int(am.group(1), 16)
        else:
            continue
        plus = False
        hx = []
        for t in hexb:
            if t == '+':
                plus = True
                break
            if len(t) != 2:
                raise SystemExit(f'code_map: listing line {lno + 1}: cannot read '
                                 f'the byte field {field!r}')
            hx.append(int(t, 16))
        bs = bytes(hx)
        if not bs and not is_blk:
            # a bare label line behind a two-address org: its RUN address
            # (not the org line itself -- that one still shows the OLD address)
            if ',' in org_text and org_hint is None and mn != 'org':
                org_hint = addr_field
            continue                            # an address with no bytes (.ds)
        if is_blk:
            two = ',' in org_text and seg_bank is None
            ln = Line(n=lno + 1, run=None, load=addr_field, size=None, bytes=bs,
                      plus=plus, kind=None, mn=mn, op=op, label=lab,
                      proc=procs[-1] if procs else None, bank=0, blk=bi,
                      src=src, lst=lno + 1)
            ln.run = addr_field if not two else None
            if seg_bank is not None:
                two_addr_bank = seg_bank
            elif two:
                two_addr_bank = 1 if 'B1CODE' in org_text.upper() else 0
            else:
                two_addr_bank = 0
            ln.bank = two_addr_bank
            load_off = 0 if not two else None
            pending = ln if two else None
            if two and org_hint is not None:    # run address already known
                ln.run = org_hint
                load_off = org_hint - addr_field
                pending = None
            org_hint = None if two else org_hint
            lines.append(ln)
            continue
        # plain line inside the current block
        if pending is not None:
            # first plain line of a two-address block: fix the run/load offset
            k = len(pending.bytes) if not pending.plus else None
            if k is None:
                raise SystemExit(f'code_map: listing line {pending.lst}: cannot '
                                 f'place a two-address block (long first line)')
            load_off = addr_field - (pending.load + k)
            pending.run = pending.load + load_off
            pending = None
        run = addr_field
        ld = run - (load_off or 0)
        lines.append(Line(n=lno + 1, run=run, load=ld, size=None, bytes=bs,
                          plus=plus, kind=None, mn=mn, op=op, label=lab,
                          proc=procs[-1] if procs else None,
                          bank=seg_bank if seg_bank is not None else two_addr_bank,
                          blk=bi, src=src, lst=lno + 1))
    # sizes: delta to the next line of the same block, the last one to block end
    for i, ln in enumerate(lines):
        nxt = lines[i + 1] if i + 1 < len(lines) else None
        if nxt is not None and nxt.blk == ln.blk:
            ln.size = nxt.load - ln.load
        else:
            ln.size = lbl[ln.blk][1] - ln.load + 1
        ln.ovl = xmap[ln.blk] is None and not lbl[ln.blk][2]
        if ln.mn in INSN:
            ln.kind = 'code'
        elif ln.mn in DATA:
            ln.kind = 'data'
        else:
            ln.kind = 'other'
    # byte-exact cross-check against the XEX (overlays: not in it)
    bad = 0
    for ln in lines:
        if xmap[ln.blk] is None:                # lifted overlay / bank segment
            continue
        lo, hi, data = blocks[xmap[ln.blk]]
        off = ln.load - lo
        if off < 0 or off + len(ln.bytes) > len(data) or \
                data[off:off + len(ln.bytes)] != ln.bytes:
            bad += 1
            if bad <= 5:
                print(f'code_map: MISMATCH listing line {ln.lst} load '
                      f'${ln.load:04X}: {ln.src[:60]}', file=sys.stderr)
    m = Map(lines, blocks, bad)
    m.lblocks, m.xmap = lbl, xmap
    return m


def region(run, bank, ovl=False):
    if ovl:
        return 'ovl'
    if bank:
        return f'bank${bank:02X}'
    if run < 0x4000:
        return 'fast0'
    if run < 0x8000:
        return 'win1'
    if run < 0xC000:
        return 'win2'
    return 'urom'


class Map:
    def __init__(self, lines, blocks, mismatches):
        self.lines = lines
        self.blocks = blocks
        self.mismatches = mismatches
        pf = proc_file_map()
        self.proc = {}                          # (bank, name) -> info
        for ln in lines:
            if ln.proc is None:
                continue
            key = (ln.bank, ln.proc)
            p = self.proc.get(key)
            if p is None:
                p = self.proc[key] = {'name': ln.proc, 'bank': ln.bank,
                                      'lo': ln.run, 'hi': ln.run + ln.size - 1,
                                      'code': 0, 'data': 0, 'other': 0,
                                      'file': pf.get(ln.proc.lower(), '?'),
                                      'calls': defaultdict(int),
                                      'callers': defaultdict(int)}
            p['lo'] = min(p['lo'], ln.run)
            p['hi'] = max(p['hi'], ln.run + ln.size - 1)
            p[ln.kind] += ln.size
        self._index()
        self._edges()

    def _index(self):
        self.starts = defaultdict(list)          # bank -> sorted [(lo, key)]
        for key, p in self.proc.items():
            self.starts[p['bank']].append((p['lo'], key))
        for b in self.starts:
            self.starts[b].sort()

    def proc_at(self, bank, addr):
        st = self.starts.get(bank, [])
        i = bisect.bisect_right(st, (addr, (999, '~'))) - 1
        if i < 0:
            return None
        key = st[i][1]
        p = self.proc[key]
        return key if p['lo'] <= addr <= p['hi'] else None

    def _edges(self):
        self.edges = []                          # (from_key, to_key|None, kind, line)
        for ln in self.lines:
            if ln.kind != 'code' or not ln.bytes:
                continue
            op = ln.bytes[0]
            b = ln.bytes
            if op in BRANCH and len(b) == 5 and b[1] == 3 and b[2] == 0x4C:
                op, b = 0x4C, b[2:]             # MADS jeq/jne/..: Bxx +3 / jmp abs
            tgt = tb = None
            kind = None
            if op in (0x20, 0x4C) and len(b) >= 3:
                tgt, tb, kind = b[1] | b[2] << 8, ln.bank, 'jsr' if op == 0x20 else 'jmp'
            elif op in (0x22, 0x5C) and len(b) >= 4:
                tgt, tb = b[1] | b[2] << 8, b[3]
                kind = 'jsl' if op == 0x22 else 'jml'
            elif op in BRANCH and len(b) == 2:
                tgt, tb, kind = (ln.run + 2 + (b[1] - 256 if b[1] > 127 else b[1])) & 0xFFFF, ln.bank, 'br'
            elif op == 0x82 and len(b) == 3:
                o = b[1] | b[2] << 8
                tgt, tb, kind = (ln.run + 3 + (o - 65536 if o > 32767 else o)) & 0xFFFF, ln.bank, 'brl'
            elif op in (0x6C, 0x7C, 0xFC, 0xDC):
                kind = {0x6C: 'jmp()', 0x7C: 'jmp(,x)', 0xFC: 'jsr(,x)', 0xDC: 'jml[]'}[op]
            else:
                continue
            fk = (ln.bank, ln.proc) if ln.proc else None
            tk = self.proc_at(tb, tgt) if tgt is not None else None
            self.edges.append((fk, tk, kind, ln, tgt, tb))
            if fk and tk and fk != tk:
                self.proc[fk]['calls'][tk] += 1
                self.proc[tk]['callers'][fk] += 1


def report(m, procs=False):
    L = []
    A = L.append
    tot = defaultdict(int)
    for ln in m.lines:
        tot[(region(ln.run, ln.bank, ln.ovl), ln.kind)] += ln.size
    A(f'code_map  {len(m.lines)} emitting lines, {len(m.blocks)} XEX blocks '
      f'(+{m.xmap.count(None)} lifted overlay blocks), '
      f'{m.mismatches} listing/XEX mismatches')
    A('')
    A(f'  {"region":8} {"code":>7} {"data":>7} {"other":>7}')
    for r in ('fast0', 'win1', 'win2', 'urom', 'bank$01', 'ovl'):
        A(f'  {r:8} {tot[(r, "code")]:7} {tot[(r, "data")]:7} {tot[(r, "other")]:7}')
    A(f'  {"total":8} {sum(v for (r, k), v in tot.items() if k == "code"):7} '
      f'{sum(v for (r, k), v in tot.items() if k == "data"):7} '
      f'{sum(v for (r, k), v in tot.items() if k == "other"):7}')
    outside = defaultdict(int)
    for ln in m.lines:
        if ln.proc is None:
            outside[(region(ln.run, ln.bank, ln.ovl), ln.kind)] += ln.size
    A('')
    A('  bytes outside any .proc: ' + ', '.join(
        f'{r}/{k} {v}' for (r, k), v in sorted(outside.items())))
    ind = defaultdict(int)
    for fk, tk, kind, ln, tgt, tb in m.edges:
        if kind in ('jmp()', 'jmp(,x)', 'jsr(,x)', 'jml[]'):
            ind[kind] += 1
    A('  indirect transfers: ' + ', '.join(f'{k} {v}' for k, v in sorted(ind.items())))
    if procs:
        A('')
        A(f'  {"proc":24} {"file":22} {"bank":>4} {"lo":>5} {"code":>5} {"data":>5} {"oth":>4}  calls')
        for key, p in sorted(m.proc.items(), key=lambda kv: (kv[1]['bank'], kv[1]['lo'])):
            A(f'  {p["name"][:24]:24} {p["file"][:22]:22} {p["bank"]:4} '
              f'${p["lo"]:04X} {p["code"]:5} {p["data"]:5} {p["other"]:4}  '
              + ' '.join(sorted(k[1] for k in p['calls']))[:90])
    return '\n'.join(L)


if __name__ == '__main__':
    mp = load()
    txt = report(mp, '--procs' in sys.argv)
    print(txt)
    out = os.path.join(ROOT, 'bench', 'code_map.txt')
    with open(out, 'w', encoding='utf-8') as f:
        f.write(txt + '\n')
    print(f'\n-> {out}')
