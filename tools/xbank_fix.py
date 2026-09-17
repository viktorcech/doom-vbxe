#!/usr/bin/env python3
"""xbank_fix -- DRAC_PLAN 4b: rewrite the bank crossings b1_check reports after
b1_mark moved procs into bank $01 (drac.txt: all code -> $010000-$01FFFF).

Reads build/b1_check.txt, maps every ERROR's bank:address back to file:line
through build/doom_bsp.lst, and rewrites the call the way the 2b boundary
already works (bsp_main.asm, the wrapper block):
  bank 0 -> bank $01   `jsr X` / `jmp X`   ->  `jsr X_t` / `jmp X_t`
                       (X_t: jsl B1CODE_BASE+X_w1 / rts; X_w1: jsr X / rtl)
  bank $01 -> bank 0   `jsr X`             ->  `jsl X_w0`
                       `jmp X` (tail)      ->  `jsl X_w0` + `rts`
                       (X_w0: jsr X / rtl -- bank 0)
  a bank-0 wrapper `X_w0 jsr X` whose X moved: removed, and every
  `jsl X_w0` becomes `jsr X` again
  bank $01 `jmp X_t` of a thunk whose target is bank $01 now -> `jmp X`
Missing thunks/wrappers are appended to the wrapper block. The instruction
bytes the callers run are the same calls, only routed through the bank line.

    python tools/xbank_fix.py          dry run
    python tools/xbank_fix.py --apply
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
LST = os.path.join(ROOT, 'build', 'doom_bsp.lst')
CHK = os.path.join(ROOT, 'build', 'b1_check.txt')
MAIN = os.path.join(ROOT, 'bsp_main.asm')
ANCHOR = 'init_level_w1   jsr init_level'
TAG = '; DRAC_PLAN 4b (xbank_fix.py)'


def load(path):
    t = open(path, encoding='latin-1', newline='').read()
    eol = '\r\n' if '\r\n' in t else '\n'
    return t.split(eol), eol


def save(path, L, eol):
    open(path, 'w', encoding='latin-1', newline='').write(eol.join(L))


def listing_index():
    idx = {}
    cur = None
    rx = re.compile(r'^\s*(\d+)\s+(?:([0-9A-F]{2}),)?([0-9A-F]{4})\s+[0-9A-F]{2}\s')
    for raw in open(LST, encoding='latin-1'):
        if raw.startswith('Source:'):
            cur = raw.split(':', 1)[1].strip()
            continue
        m = rx.match(raw)
        if m and cur:
            bank = int(m.group(2), 16) if m.group(2) else 0
            idx.setdefault((bank, int(m.group(3), 16)), (cur, int(m.group(1))))
    return idx


CALL = re.compile(r'^(?P<lab>[^\s;]*)(?P<sp>\s+)(?P<mn>jsr|jmp)(?P<sp2>\s+)'
                  r'(?P<op>[A-Za-z_?@][\w?@.]*)(?P<rest>.*)$', re.I)


def main():
    apply = '--apply' in sys.argv
    idx = listing_index()
    ML, meol = load(MAIN)
    mtext = '\n'.join(ML)
    w0_of = {t.lower(): w for w, t in re.findall(r'^(\w+_w0)\s+jsr\s+(\S+)', mtext, re.M)}
    t_target = {}
    for t, w1 in re.findall(r'^(\w+_t)\s+jsl\s+B1CODE_BASE\+(\w+_w1)', mtext, re.M):
        mt = re.search(r'^%s\s+jsr\s+(\S+)' % w1, mtext, re.M)
        if mt:
            t_target[t.lower()] = mt.group(1)
    have = {n.lower() for n in re.findall(r'^(\w+)\s', mtext, re.M)}

    edits = defaultdict(dict)                 # file -> {line: [new lines]}
    drop_w0 = {}                              # wrapper -> target
    new_t, new_w0 = set(), set()
    manual = []
    rxe = re.compile(r'\s*ERROR (\w+)\s+(.*?) -- ([0-9A-F]{2}):([0-9A-F]{4}) (\S+): (.*)$')
    errs = []
    for raw in open(CHK, encoding='utf-8'):
        e = rxe.match(raw)
        if not e:
            continue
        kind, msg, bank, addr = e.group(1), e.group(2), int(e.group(3), 16), int(e.group(4), 16)
        if kind != 'xjump' or ' label from bank ' not in msg:
            manual.append(raw.strip())
            continue
        errs.append((bank, addr, e.group(5), e.group(6), raw.strip()))
    # the listing does not re-announce a file when an icl returns, so find the
    # line by its text inside its proc (b1_check prints the first 60 chars)
    import glob
    sys.path.insert(0, HERE)
    import code_map
    pf = code_map.proc_file_map()
    norm = lambda s: ' '.join(s.split())

    def active(L):
        """False for lines MADS skips: the .else of `.if 1`, the body of
        `.if 0` (the .if 1/.else/.endif style keeps the original text there)"""
        act, st = [], []
        for s in L:
            t = s.split(';', 1)[0].strip().lower()
            if re.match(r'^\.if\s', t):
                v = t.split(None, 1)[1].strip()
                st.append(True if v == '1' else False if v == '0' else None)
            elif re.match(r'^\.if(n?def)\b', t):
                st.append(None)
            elif re.match(r'^\.else\b', t) and st:
                st[-1] = None if st[-1] is None else not st[-1]
            elif re.match(r'^\.endif\b', t) and st:
                st.pop()
            act.append(False not in st)
        return act
    groups = defaultdict(list)
    for er in sorted(errs, key=lambda er: (er[0], er[1])):
        groups[(er[2], norm(er[3]))].append(er)
    located = []
    for (proc, snip), ers in groups.items():
        files = [pf[proc.lower()]] if proc.lower() in pf else \
            [os.path.basename(p) for p in glob.glob(os.path.join(ROOT, '*.asm'))]
        hits = []
        # b1_check prints the source line (comment included) cut at 60 chars:
        # a shorter text is the WHOLE line, so it must match whole
        exact = len(ers[0][3].rstrip()) < 60
        for fn in files:
            L, _ = load(os.path.join(ROOT, fn))
            lo, hi = 0, len(L)
            if proc != '?':
                st = [k for k, s in enumerate(L) if re.match(r'^\.proc\s+%s\b' % re.escape(proc), s, re.I)]
                if st:
                    lo = st[0]
                    hi = next((k for k in range(lo, len(L)) if re.match(r'^\.endp\b', L[k])), len(L) - 1) + 1
            on = active(L)
            for k in range(lo, hi):
                nk = norm(L[k])
                after = nk[len(snip):len(snip) + 1]
                if on[k] and (nk == snip if exact else nk.startswith(snip)):
                    hits.append((fn, k + 1))
        if len(hits) != len(ers):
            for er in ers:
                manual.append(f'{len(hits)} source match(es) for {len(ers)} error(s): {er[4]}')
            continue
        for er, h in zip(ers, hits):
            located.append((er[0], h[0], h[1]))
    for bank, fn, lno in located:
        path = os.path.join(ROOT, fn)
        L, _ = load(path)
        src = L[lno - 1]
        code, sep, comment = src.partition(';')
        m = CALL.match(code.rstrip())
        if not m:
            manual.append(f'{fn}:{lno} not a plain jsr/jmp: {src.strip()[:60]}')
            continue
        lab, mn, x = m.group('lab'), m.group('mn').lower(), m.group('op')
        tail = (sep + comment) if sep else ''
        pad = m.group('sp')
        if bank == 0:                          # bank 0 -> bank $01
            if lab.lower().endswith('_w0'):
                drop_w0[lab] = x
                continue
            tn = x.replace('.', '_') + '_t'
            new = f'{lab}{pad}{mn} {tn}'
            if tail:
                new = new.ljust(len(code.rstrip())) + ' ' + tail
            edits[path][lno] = [new]
            if tn.lower() not in have:
                new_t.add(x)
        else:                                  # bank $01 -> bank 0
            if x.lower() in t_target:
                new = f'{lab}{pad}{mn} {t_target[x.lower()]}'
                edits[path][lno] = [new + ((' ' + tail) if tail else '')]
                continue
            w = w0_of.get(x.lower()) or (x.replace('.', '_') + '_w0')
            if w.lower() not in have:
                new_w0.add(x)
            if mn == 'jsr':
                new = [f'{lab}{pad}jsl {w}' + ((' ' + tail) if tail else '')]
            else:
                new = [f'{lab}{pad}jsl {w}' + ((' ' + tail) if tail else ''),
                       f'{" " * max(len(lab) + len(pad), 8)}rts                          ' + TAG]
            edits[path][lno] = new

    print(f'call rewrites: {sum(len(v) for v in edits.values())} in {len(edits)} files')
    print(f'wrappers dropped (target moved): {sorted(drop_w0)}')
    print(f'new thunks X_t: {sorted(new_t)}')
    print(f'new wrappers X_w0: {sorted(new_w0)}')
    for s in manual:
        print('  MANUAL', s[:150])
    if not apply:
        print('dry run (--apply to write)')
        return 0

    for path, ed in edits.items():
        L, eol = load(path)
        for lno in sorted(ed, reverse=True):
            L[lno - 1:lno] = ed[lno]
        save(path, L, eol)

    # every `jsl X_w0` of a dropped wrapper -> `jsr X`
    import glob
    for path in glob.glob(os.path.join(ROOT, '*.asm')):
        L, eol = load(path)
        ch = False
        for k, s in enumerate(L):
            for w, x in drop_w0.items():
                s2 = re.sub(r'\bjsl(\s+)%s\b' % re.escape(w), lambda mm: 'jsr' + mm.group(1) + x, s)
                if s2 != s:
                    L[k] = s = s2
                    ch = True
        if ch:
            save(path, L, eol)

    ML, meol = load(MAIN)
    out = []
    k = 0
    while k < len(ML):
        s = ML[k]
        mw = re.match(r'^(\w+_w0)\s+jsr\s', s)
        if mw and mw.group(1) in drop_w0 and k + 1 < len(ML) and ML[k + 1].strip() == 'rtl':
            k += 2
            continue
        out.append(s)
        k += 1
    ML = out
    at = next(i for i, s in enumerate(ML) if s.startswith(ANCHOR))
    at = next(i for i in range(at, len(ML)) if ML[i].strip() == '.endseg') + 1
    add = []
    if new_t:
        add.append('; ' + TAG[2:] + ': bank-0 callers of code that moved to bank $01')
        for x in sorted(new_t):
            n = x.replace('.', '_')
            add += [f'{n}_t'.ljust(15) + f' jsl B1CODE_BASE+{n}_w1', '                rts']
        add.append('        .segment B1')
        for x in sorted(new_t):
            n = x.replace('.', '_')
            add += [f'{n}_w1'.ljust(15) + f' jsr {x}', '                rtl']
        add.append('        .endseg')
    if new_w0:
        add.append('; ' + TAG[2:] + ': bank-$01 callers of code that stays in bank 0')
        for x in sorted(new_w0):
            n = x.replace('.', '_')
            add += [f'{n}_w0'.ljust(15) + f' jsr {x}', '                rtl']
    ML[at:at] = add
    save(MAIN, ML, meol)
    print('APPLIED')
    return 0


if __name__ == '__main__':
    sys.exit(main())
