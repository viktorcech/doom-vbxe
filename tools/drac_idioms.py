#!/usr/bin/env python3
"""drac_idioms -- drac030's second note: 65816 idioms the code does not use.

Scans the ASSEMBLED code (build/doom_bsp.lst) for three patterns and can
rewrite the first two in the sources where that is provably safe:

  stz    `lda #0` followed by one or more `sta X` (X in a mode stz has: dp,
         dp,x, abs, abs,x). Rewritten to `stz X` only when the instruction
         after the run overwrites A and N/Z (lda / pla / txa / tya / tdc /
         tsc), so neither the value 0 in A nor the flags can be relied on,
         and no label sits on the sta lines (no other path enters with A != 0).
  nozy   `ldy #0` followed by `op (zp),y` / `op [zp],y`. Rewritten to `op (zp)`
         / `op [zp]` and the ldy dropped only when Y is not touched again
         before it is reloaded (ldy/tay/ply) or the proc ends, with no label
         and no branch inside that stretch.
  shift  `asl X / rol X+1` and `lsr X+1 / ror X` multi-byte shifts in memory
         (report only: whether they belong in the accumulator is a judgement).

    python tools/drac_idioms.py            counts + tools/drac_out/drac_idioms.txt
    python tools/drac_idioms.py --apply    rewrite the safe stz / nozy sites
"""
import os
import re
import sys
from collections import Counter, defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drac_lst as L                                             # noqa: E402

STZ_MODES = {'dp', 'dp,x', 'abs', 'abs,x'}
A_KILL = {'lda', 'pla', 'txa', 'tya', 'tdc', 'tsc'}
Y_USE = re.compile(r',\s*y\b', re.I)
LABELED = re.compile(r'^[A-Za-z_?@]')          # a label starts in column 0


def one(ln):
    """the single instruction of a plain (non-macro) code line, or None"""
    if ln.kind != 'code':
        return None
    ins, _, exact = L.decode_line(ln)
    return ins[0] if exact and len(ins) == 1 else None


def scan(lines):
    # per (bank, file, proc) in listing order, code lines only
    groups = defaultdict(list)
    for ln in lines:
        if ln.kind == 'code':
            groups[(ln.bank, ln.file, ln.proc)].append(ln)
    stz_all, stz_safe, nozy_all, nozy_safe, shifts = [], [], [], [], []
    for key, lns in groups.items():
        ins = [one(ln) for ln in lns]
        n = len(lns)
        for k in range(n):
            i = ins[k]
            if i is None:
                continue
            # ---- stz -------------------------------------------------------
            if i.mn == 'lda' and i.mode == 'immM' and i.imm == 0:
                j = k + 1
                while j < n and ins[j] is not None and ins[j].mn == 'sta' and ins[j].mode in STZ_MODES:
                    j += 1
                if j > k + 1:
                    run = lns[k:j]
                    stz_all.append(run)
                    nxt = ins[j] if j < n else None
                    ok = nxt is not None and nxt.mn in A_KILL \
                        and not any(LABELED.match(r.src) for r in run[1:]) \
                        and all(r.file == lns[k].file for r in run)
                    if ok:
                        stz_safe.append(run)
            # ---- nozy ------------------------------------------------------
            if i.mn == 'ldy' and i.mode == 'immX' and i.imm == 0 and k + 1 < n:
                j = ins[k + 1]
                if j is not None and j.mode in ('(dp),y', '[dp],y'):
                    nozy_all.append(lns[k:k + 2])
                    ok, m = True, k + 2
                    while m < n:
                        x, src = ins[m], lns[m].src
                        if x is None:
                            ok = False
                            break
                        if x.mn in ('ldy', 'tay', 'ply') or x.mn in ('rts', 'rtl', 'jmp', 'jml'):
                            break
                        if LABELED.match(src) or x.mn in L.BRANCH or x.mn in ('jsr', 'jsl') \
                                or x.mn in ('iny', 'dey', 'tya', 'phy', 'cpy', 'sty', 'tyx', 'mvn', 'mvp') \
                                or Y_USE.search(src.split(';')[0]):
                            ok = False
                            break
                        m += 1
                    if m >= n:
                        ok = False                       # ran off the proc without an end
                    if LABELED.match(lns[k + 1].src):
                        ok = False
                    if ok:
                        nozy_safe.append(lns[k:k + 2])
            # ---- shift -----------------------------------------------------
            if k + 1 < n and ins[k + 1] is not None and i.ea is not None and ins[k + 1].ea is not None \
                    and i.mode in ('dp', 'abs') and ins[k + 1].mode == i.mode:
                a, b = i, ins[k + 1]
                if (a.mn == 'asl' and b.mn == 'rol' and b.ea == a.ea + 1) or \
                   (a.mn == 'lsr' and b.mn == 'ror' and b.ea == a.ea - 1):
                    shifts.append(lns[k:k + 2])
    return stz_all, stz_safe, nozy_all, nozy_safe, shifts


def apply(stz_safe, nozy_safe):
    """Edit the sources: lines are addressed by (file, listing line number)."""
    edits = defaultdict(dict)                 # file -> lineno -> new text or None (drop)
    for run in stz_safe:
        first, rest = run[0], run[1:]
        src0, src1 = first.src, rest[0].src
        code1 = src1.split(';', 1)[0]
        m = re.match(r'^(\s*)(?:[A-Za-z_?@][\w?@]*\s+)?sta\s+(\S+)', code1, re.I)
        if not m:
            continue
        operand = m.group(2)
        cm0 = (' ' + src0[src0.index(';'):]) if ';' in src0 else ''
        cm1 = (' ' + src1[src1.index(';'):].strip()) if ';' in src1 else ''
        new0 = re.sub(r'\blda\s+#\$?0+\b', 'stz ' + operand, src0.split(';', 1)[0].rstrip(), flags=re.I)
        edits[first.file][first.lineno] = new0 + cm0 + (cm1 if cm1 and cm1.strip() != cm0.strip() else '')
        edits[rest[0].file][rest[0].lineno] = None
        for r in rest[1:]:
            edits[r.file][r.lineno] = re.sub(r'\bsta\b', 'stz', r.src, count=1, flags=re.I)
    for ldy, op in nozy_safe:
        cm = (' ' + ldy.src[ldy.src.index(';'):]) if ';' in ldy.src else ''
        edits[ldy.file][ldy.lineno] = None if not cm.strip() else '        ' + cm.strip()
        edits[op.file][op.lineno] = re.sub(r'([\])])\s*,\s*[yY]\b', r'\1', op.src, count=1)
    total = 0
    for fn, ed in edits.items():
        path = os.path.join(L.ROOT, fn)
        raw = open(path, encoding='latin-1', newline='').read()
        eol = '\r\n' if '\r\n' in raw else '\n'
        src = raw.split(eol)
        for lineno in sorted(ed, reverse=True):
            idx = lineno - 1
            if idx >= len(src):
                sys.exit(f'{fn}: listing line {lineno} past the end of the file')
            if ed[lineno] is None:
                del src[idx]
            else:
                src[idx] = ed[lineno]
            total += 1
        open(path, 'w', encoding='latin-1', newline='').write(eol.join(src))
        print(f'  {fn}: {len(ed)} lines')
    print(f'{total} lines rewritten in {len(edits)} files -- rebuild and re-run the gates')


def main():
    L.ensure_outdir()
    lines, _ = L.read_lst()
    stz_all, stz_safe, nozy_all, nozy_safe, shifts = scan(lines)
    byfile = Counter(r[0].file for r in stz_all)
    outp = os.path.join(L.OUTDIR, 'drac_idioms.txt')
    with open(outp, 'w', encoding='utf-8') as fh:
        fh.write(f'stz candidates {len(stz_all)} (safe {len(stz_safe)}), '
                 f'nozy candidates {len(nozy_all)} (safe {len(nozy_safe)}), memory shifts {len(shifts)}\n\n')
        for tag, runs in (('STZ-SAFE', stz_safe), ('STZ-UNSAFE', [r for r in stz_all if r not in stz_safe]),
                          ('NOZY-SAFE', nozy_safe), ('NOZY-UNSAFE', [r for r in nozy_all if r not in nozy_safe]),
                          ('SHIFT', shifts)):
            fh.write(f'== {tag} ==\n')
            for run in runs:
                r = run[0]
                fh.write(f'{"$01" if r.bank else "b0 "} {r.file:22} {r.proc:18} {r.lineno:5}  '
                         + ' | '.join(x.src.split(";")[0].strip() for x in run)[:90] + '\n')
            fh.write('\n')
    print(f'lda #0 / sta runs: {len(stz_all)}, provably safe for stz: {len(stz_safe)}')
    print(f'ldy #0 / op (zp),y: {len(nozy_all)}, provably safe without Y: {len(nozy_safe)}')
    print(f'multi-byte shifts in memory (asl/rol, lsr/ror pairs): {len(shifts)}')
    print('files with most lda #0/sta: ' + ', '.join(f'{f} {n}' for f, n in byfile.most_common(8)))
    print(f'-> {os.path.relpath(outp, L.ROOT)}')
    if '--apply' in sys.argv:
        apply(stz_safe, nozy_safe)
    return 0


if __name__ == '__main__':
    sys.exit(main())
