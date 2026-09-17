#!/usr/bin/env python3
"""d0_mark -- DRAC_PLAN / drac.txt: empty $8000-$BFFF of everything the CPU
reads there, so a permanent 16 KB MEMAC-A window can own it.

For every fixed block `org NAME_BASE` whose NAME_BASE (memory_map.inc) lies in
$8000-$BFFF and that holds NO bank-0 code (bank-0 code goes to bank $01 in its
own step -- drac.txt: "cały kod ... przenieść do $010000-$01FFFF"):
  * the `org NAME_BASE` line and every `.if * > NAME_END+1 / ert / .endif`
    guard of a converted block are disabled (`.if 1` empty / `.else`
    original / `.endif`),
  * every stretch of the block that is not already a `.segment B1` goes into
    `.segment D0` (memory_map.inc: bank-0 data below $8000), so MADS packs the
    data back to back and checks the one segment length instead of the erts.
A block CONTINUED later through `org x_resume`, where `x_resume = *` was taken
inside the block (so now inside D0), is the same block: that org is disabled
and its stretch converted too (pass 2, repeated until nothing changes).
`org x_resume` back to an outer flow stays: with the block in a segment it is
a no-op. Blocks whose body `icl`s whole files are left alone.
Source lines move nowhere and change nowhere -- only their placement.

    python tools/d0_mark.py            dry run: what would change
    python tools/d0_mark.py --apply    edit the .asm files
"""
import glob
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import code_map                                                  # noqa: E402

TAG = '; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)'
ORGNAME = re.compile(r'^\s*org\s+([A-Za-z_][A-Za-z0-9_]*)\s*(;.*)?$', re.I)
ANYORG = re.compile(r'^\s*org\s', re.I)
SEGB1 = re.compile(r'^\s*\.segment\s+B1\b', re.I)
SEGD0 = re.compile(r'^\s*\.segment\s+D0\b', re.I)
ENDSEG = re.compile(r'^\s*\.endseg\b', re.I)
IFOPEN = re.compile(r'^\s*\.(if|ifdef|ifndef)\b', re.I)
IFEND = re.compile(r'^\s*\.endif\b', re.I)
STARDEF = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\*')


def blocks_in_win2():
    src = open(os.path.join(ROOT, 'memory_map.inc'), encoding='latin-1').read()
    base = {n.upper(): int(a, 16) for n, a in re.findall(
        r'^([A-Z0-9_]+)_BASE\s+equ\s+\$([0-9A-F]{4})\b', src, re.M)}
    end = {n.upper(): int(a, 16) for n, a in re.findall(
        r'^([A-Z0-9_]+)_END\s+equ\s+\$([0-9A-F]{4})\b', src, re.M)}
    return {n: (a, end.get(n, a)) for n, a in base.items() if 0x8000 <= a <= 0xBFFF}


def has_code(m, lo, hi):
    return any(ln.kind == 'code' and not ln.bank and not ln.ovl
               and lo <= ln.run <= hi for ln in m.lines)


def meaningful(ln):
    s = ln.strip()
    return bool(s) and not s.startswith(';')


def balanced(lines):
    d = 0
    for ln in lines:
        if IFOPEN.match(ln):
            d += 1
        elif IFEND.match(ln):
            d -= 1
            if d < 0:
                return False
    return d == 0


def disabled(L, i):
    return i >= 2 and TAG in L[i - 2] and L[i - 1].strip() == '.else'


INSTR = re.compile(r'^(?:[A-Za-z_?@][\w?@.]*)?\s+([A-Za-z]{3})(?:\.[bwlBWL])?(?:\s|$)')
DATAL = re.compile(r'^(?:[A-Za-z_?@][\w?@.]*)?\s+(dta|\.ds|ins|\.byte|\.word|\.he)\b', re.I)
TERM = {'rts', 'rtl', 'rti', 'jmp', 'jml', 'bra', 'brl'}


def falls_through(body):
    """True when the block's last instruction outside B1 segments can run on
    into whatever follows the block (nothing but labels/comments after it)."""
    last, data_after, inb1 = None, False, False
    for ln in body:
        if SEGB1.match(ln):
            inb1 = True
            continue
        if inb1:
            if ENDSEG.match(ln):
                inb1 = False
            continue
        code = ln.split(';', 1)[0]
        mt = INSTR.match(code)
        if mt and mt.group(1).lower() in code_map.INSN:
            last, data_after = mt.group(1).lower(), False
        elif DATAL.match(code):
            data_after = True
    return last is not None and not data_after and last not in TERM


def convert(L, i, guard_names, code=False):
    """-> (new lines replacing L[i:j], j); raises ValueError to skip."""
    j = i + 1
    while j < len(L) and not ANYORG.match(L[j]):
        j += 1
    body = L[i + 1:j]
    if any(re.match(r'^\s*icl\b', ln, re.I) for ln in body):
        raise ValueError('icl flow: whole files, their own blocks inside')
    if code and falls_through(body):
        raise ValueError('its code falls through to the next block')
    guards = []                                   # (start, end) in body
    k = 0
    while k < len(body):
        ln = body[k]
        mt = IFOPEN.match(ln) and re.search(r'\b([A-Za-z0-9_]+)_END\b', ln)
        if mt and mt.group(1).upper() in guard_names and '*' in ln:
            d, e = 0, k
            while e < len(body):
                if IFOPEN.match(body[e]):
                    d += 1
                elif IFEND.match(body[e]):
                    d -= 1
                    if d == 0:
                        break
                e += 1
            guards.append((k, e))
            k = e + 1
            continue
        k += 1
    gstart = {g[0]: g[1] for g in guards}
    out = [' .if 1                                ' + TAG,
           ' .else',
           L[i],
           ' .endif']
    run = []

    def flush():
        if any(meaningful(x) for x in run):
            if not balanced(run):
                raise ValueError('unbalanced .if inside a D0 stretch')
            out.append('        .segment D0                  ' + TAG)
            out.extend(run)
            out.append('        .endseg')
        else:
            out.extend(run)
        run.clear()

    k = 0
    while k < len(body):
        ln = body[k]
        if k in gstart:
            flush()
            out.append(' .if 1                                ' + TAG)
            out.append(' .else')
            out.extend(body[k:gstart[k] + 1])
            out.append(' .endif')
            k = gstart[k] + 1
            continue
        if SEGB1.match(ln):
            flush()
            e = k
            while e < len(body) and not ENDSEG.match(body[e]):
                e += 1
            out.extend(body[k:e + 1])
            k = e + 1
            continue
        run.append(ln)
        k += 1
    flush()
    return out, j


def load(f):
    text = open(f, encoding='latin-1', newline='').read()
    eol = '\r\n' if '\r\n' in text else '\n'
    return text.split(eol), eol


def d0_defs(files):
    """names `x = *` taken inside a d0_mark D0 stretch"""
    defs = set()
    for f in files:
        L, _ = load(f)
        ind = False
        for ln in L:
            if SEGD0.match(ln) and TAG in ln:
                ind = True
            elif ind and ENDSEG.match(ln):
                ind = False
            elif ind:
                mt = STARDEF.match(ln)
                if mt:
                    defs.add(mt.group(1).upper())
    return defs


def converted_names(files):
    names = set()
    for f in files:
        L, _ = load(f)
        for i, ln in enumerate(L):
            mt = ORGNAME.match(ln)
            if mt and disabled(L, i) and mt.group(1).upper().endswith('_BASE'):
                names.add(mt.group(1).upper()[:-5])
    return names


def main():
    apply = '--apply' in sys.argv
    code_ok = '--code' in sys.argv          # DRAC_PLAN step 3: bank-0 code out of
                                            #   $8000-$BFFF too (bank $01 is step 4)
    win2 = blocks_in_win2()
    m = code_map.load()
    files = sorted(glob.glob(os.path.join(ROOT, '*.asm')))
    done, skipped = [], []
    staged = {}                                   # dry run: file -> lines
    for pas in range(1, 8):
        defs = d0_defs(files) if apply else set()
        if not apply and pas > 1:
            break
        will = {n for n, (lo, hi) in win2.items()
                if code_ok or not has_code(m, lo, hi)}
        guard_names = converted_names(files) | will
        changed_any = False
        for f in files:
            L, eol = staged.get(f) or load(f)
            new, i, changed = [], 0, False
            while i < len(L):
                mt = ORGNAME.match(L[i])
                tgt = mt.group(1).upper() if mt else None
                kind = None
                if tgt and not disabled(L, i):
                    if tgt.endswith('_BASE') and tgt[:-5] in win2:
                        kind = 'block'
                    elif tgt in defs:
                        kind = 'cont'
                if kind:
                    name = tgt[:-5] if kind == 'block' else tgt
                    if kind == 'block' and not code_ok and has_code(m, *win2[name]):
                        if pas == 1:
                            skipped.append(f'{name} (bank-0 code)')
                    else:
                        try:
                            rep, j = convert(L, i, guard_names,
                                             code_ok and has_code(m, *win2.get(name, (0, -1))))
                        except ValueError as e:
                            if pas == 1 or kind == 'cont':
                                skipped.append(f'{name} ({e})')
                        else:
                            new.extend(rep)
                            i = j
                            changed = changed_any = True
                            done.append(f'{name}@{os.path.basename(f)}')
                            continue
                new.append(L[i])
                i += 1
            if changed:
                if apply:
                    with open(f, 'w', encoding='latin-1', newline='') as fh:
                        fh.write(eol.join(new))
                else:
                    staged[f] = (new, eol)
        if not changed_any:
            break
    print(f'converted {len(done)}: ' + ' '.join(done))
    print(f'skipped {len(skipped)}: ' + ', '.join(sorted(set(skipped))))
    print('APPLIED' if apply else 'dry run (--apply to write)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
