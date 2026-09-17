#!/usr/bin/env python3
"""b1_mark -- DRAC_PLAN step 2b: pick the native code for bank $01 and mark it.

drac.txt moves the code out of the first 64 KB. Moving it proc by proc would
thunk every call across the bank line (the AI alone calls ai_get/ai_put/
en_thing tens of times a frame), so the native engine goes in one step and
only the real boundaries keep a bank line: the interrupt handlers and what
they call, the loaders and overlays (emulation mode / runtime-copied code),
and whatever runs in both modes.

A proc MOVES when all of these hold:
  * tools/tests/_probe_codemode.py classed it native (run, or inherited from
    native callers through the call graph -- bench/probe_codemode.txt);
  * it is resident bank-0 code: not an overlay, not a two-address block, not
    a boot one-shot staged in reserved RAM (ram_map.STAGED);
  * no interrupt vector reaches it (rom_nmi, snd_irq and their callees);
  * it does not share a FALLTHROUGH with a proc that stays: a proc whose last
    instruction is not rts/rtl/rti/jmp/jml/bra/brl runs into the next one,
    and the two go together or not at all.
Data tables that hold the address of a moving proc (dta a(...)/v(...)) are
listed: nothing checks an indirect call across banks.

    python tools/b1_mark.py            report  -> build/b1_mark.txt
    python tools/b1_mark.py --apply    + insert .segment B1 / .endseg in the sources
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import code_map                                                 # noqa: E402
from code_xref import group, staged_blocks                      # noqa: E402

VECTORS = ('rom_nmi', 'snd_irq')
# Native, but staying on purpose: hud_blit is entered 14 times from bank-0
# overlays (menu, intermission, finale) and patched by fps_blit (hb_dbnk);
# in bank 0 it needs one wrapper for the frame's HUD calls instead of 14 thunks.
KEEP = {'hud_blit': 'kept: overlay entry point',
        # every overlay is entered through mn_open's `jmp MENU_RUN` and comes
        # back with rts, tail-jumping resident code on the way out: in bank 0
        # those frames stay plain jsr/rts (DRAC_PLAN 4b)
        'mn_open': 'kept: overlay entry point',
        # `jmp FIN2_RESUME` back INTO the finale overlay after the menu
        'fin_esc': 'kept: jumps back into the finale overlay'}
# Native frame code the tape never ran and whose only callers are cross-bank
# TAIL JUMPS from code that already moved (code_map cannot resolve a jump
# into the other bank by address, so the call graph shows no caller at all):
# ball_frame `jpl bl_wall`, trig_fire `jne trig_crush` / `jne mv_stop`,
# mv_crossed `jne mv_cross2` (-> mv_side_pt), the sound queue's snd_setpan.
FORCE = {'bl_wall', 'trig_crush', 'mv_cross2', 'mv_side_pt', 'mv_stop', 'snd_setpan'}
ENDS = {0x60, 0x6B, 0x40, 0x4C, 0x6C, 0x7C, 0x5C, 0xDC, 0x80, 0x82}


# DRAC_PLAN 4a made the modes a property of the code, not of a tape: from
# urom_init on the machine is native with the ROM out for good; only these run
# in emulation (boot before urom_init, the XEX INIT, the SIOV trampoline), and
# with them everything they call.
EMU_ROOTS = ('ram_check', 'snd_init2', 'detect_vbxe', 'setup_memac',
             'setup_xdl', 'setup_bcbs', 'urom_init', 'b1_stage_copy', 'siov_r',
             'early_init')           # `ini early_init`: a XEX INIT, run by the loader
# main itself is the entry (emulation until urom_init) and stays; what it calls
# AFTER urom_init runs native, so it does not seed the closure.


def static_classes(m):
    # Overlays all RUN at the same few bank-0 addresses (MENU_RUN, WI2_RUN...),
    # so code_map resolves a call into that range to whichever overlay proc
    # sits there -- a bogus edge (xb_copy -> mn_items -> every loader). No
    # resident code lives at those addresses, and overlays stay in bank 0
    # anyway, so the closure never walks into one.
    stay = {(0, ln.proc) for ln in m.lines
            if ln.proc and ln.bank == 0 and (ln.ovl or group(ln) is not None)}
    emu = {(0, 'main')}
    todo = [k for k in m.proc if k[0] == 0 and k[1] in EMU_ROOTS]
    while todo:
        k = todo.pop()
        if k in emu:
            continue
        emu.add(k)
        todo.extend(t for t in m.proc[k]['calls'] if t[0] == 0 and t not in stay)
    return {k[1]: ('emu' if k in emu else 'native') for k in m.proc if k[0] == 0}


def probe_classes():
    cls = {}
    path = os.path.join(ROOT, 'bench', 'probe_codemode.txt')
    for line in open(path, encoding='utf-8'):
        p = line.split()
        if len(p) > 6 and p[0] in ('native', 'emu', 'both', 'unknown') \
                and p[1] in ('run', 'static', '-'):
            cls[p[4]] = p[0]
    return cls


def main():
    m = code_map.load()
    cls = static_classes(m) if '--static' in sys.argv else probe_classes()
    staged = staged_blocks(m)

    # per proc: its lines, in address order
    plines = defaultdict(list)
    for ln in m.lines:
        if ln.proc and ln.bank == 0:
            plines[ln.proc].append(ln)
    reason = {}
    for name, lns in plines.items():
        if any(l.ovl for l in lns):
            reason[name] = 'overlay'
        elif any(group(l) is not None for l in lns):
            reason[name] = 'two-address block'
        elif any(l.blk in staged for l in lns):
            reason[name] = 'boot one-shot (staged)'
        elif cls.get(name) != 'native':
            reason[name] = f'mode: {cls.get(name, "not in probe")}'

    # interrupt reach: everything a vector calls, transitively
    irq = set()
    todo = [k for k in m.proc if k[0] == 0 and k[1] in VECTORS]
    while todo:
        k = todo.pop()
        if k in irq:
            continue
        irq.add(k)
        todo.extend(t for t in m.proc[k]['calls'] if t[0] == 0)
    for k in irq:
        reason.setdefault(k[1], 'interrupt handler reach')
    for n, why in KEEP.items():
        reason.setdefault(n, why)
    for n in FORCE:
        reason.pop(n, None)

    # a proc the tape never ran (no probe class) moves when every caller it
    # has is already bank-$01 code or moving: it cannot run in bank 0 then
    changed = True
    while changed:
        changed = False
        for name, r in list(reason.items()):
            if not (r.startswith('mode: unknown') or r.startswith('mode: not in probe')):
                continue
            k = (0, name)
            if k not in m.proc:
                continue
            callers = m.proc[k]['callers']
            if callers and all(c[0] == 1 or (c[0] == 0 and c[1] not in reason)
                               for c in callers):
                del reason[name]
                changed = True

    # fallthrough groups inside a block
    code_by_blk = defaultdict(list)
    for ln in m.lines:
        if ln.kind == 'code' and ln.bank == 0:
            code_by_blk[ln.blk].append(ln)
    falls = []
    for blk, lns in code_by_blk.items():
        lns.sort(key=lambda l: l.run)
        for a, b in zip(lns, lns[1:]):
            if a.proc != b.proc and a.run + a.size == b.run and a.bytes \
                    and a.bytes[0] not in ENDS:
                if a.proc and b.proc:
                    falls.append((a.proc, b.proc))
                else:
                    # into or out of code that is in no .proc: that code
                    # never moves, so neither does the proc next to it
                    p = a.proc or b.proc
                    if p:
                        reason.setdefault(p, 'falls through non-proc code')
    changed = True
    while changed:
        changed = False
        for a, b in falls:
            if (a in reason) != (b in reason):
                keep = a if a not in reason else b
                other = b if keep == a else a
                reason[keep] = f'falls through with {other} ({reason[other]})'
                changed = True

    moving = sorted((n for n in plines if n not in reason),
                    key=lambda n: (m.proc[(0, n)]['file'], m.proc[(0, n)]['lo']))
    mv_code = sum(m.proc[(0, n)]['code'] for n in moving)
    stay_by = defaultdict(lambda: [0, 0])
    for n, r in reason.items():
        if (0, n) in m.proc:
            key = r.split(' (')[0] if r.startswith('falls') else r
            stay_by[key][0] += 1
            stay_by[key][1] += m.proc[(0, n)]['code']

    # data tables naming a moving proc
    moving_up = {n.upper() for n in moving}
    tabs = []
    ident = re.compile(r'[A-Za-z_?@][\w?@]*')
    for ln in m.lines:
        if ln.kind == 'data' and ln.mn == 'dta':
            names = {i.upper() for i in ident.findall(ln.op.split(';')[0])}
            hitn = names & moving_up
            if hitn:
                tabs.append((ln, sorted(hitn)))

    L = [f'b1_mark  {len(moving)} procs, {mv_code} B of code move to bank $01']
    L.append('  staying in bank 0:')
    for k, (n, b) in sorted(stay_by.items(), key=lambda kv: -kv[1][1]):
        L.append(f'    {k:32} {n:4} procs {b:6} B')
    L.append(f'  data tables holding a moving proc address: {len(tabs)}')
    for ln, names in tabs[:20]:
        L.append(f'    {ln.run:04X} {ln.src.strip()[:70]}  <- {" ".join(names)[:40]}')
    per_file = defaultdict(int)
    for n in moving:
        per_file[m.proc[(0, n)]['file']] += m.proc[(0, n)]['code']
    L.append('  moving code per file:')
    for fn, b in sorted(per_file.items(), key=lambda kv: -kv[1]):
        L.append(f'    {fn:24} {b:6} B')
    txt = '\n'.join(L)
    with open(os.path.join(ROOT, 'build', 'b1_mark.txt'), 'w', encoding='utf-8') as f:
        f.write(txt + '\n' + '\n'.join('    ' + n for n in moving) + '\n')
    print(txt)

    if '--apply' in sys.argv:
        apply(m, moving)


def apply(m, moving):
    """Wrap each moving proc's source text in .segment B1 / .endseg."""
    by_file = defaultdict(set)
    for n in moving:
        by_file[m.proc[(0, n)]['file']].add(n.lower())
    pat_proc = re.compile(r'^\s*\.proc\s+(\w+)', re.I)
    pat_endp = re.compile(r'^\s*\.endp\b', re.I)
    for fn, names in sorted(by_file.items()):
        path = os.path.join(ROOT, fn)
        src = open(path, encoding='latin-1').read().split('\n')
        out, depth, cur = [], 0, None
        for line in src:
            mp = pat_proc.match(line)
            if mp:
                depth += 1
                prev = next((o for o in reversed(out) if o.strip()), '')
                already = prev.strip().lower().startswith('.segment b1')
                if depth == 1 and mp.group(1).lower() in names and not already:
                    out.append('        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)')
                    cur = mp.group(1)
                out.append(line)
                continue
            out.append(line)
            if pat_endp.match(line):
                depth -= 1
                if depth == 0 and cur:
                    out.append('        .endseg')
                    cur = None
        open(path, 'w', encoding='latin-1', newline='').write('\n'.join(out))
        print(f'  marked {len(names):3} procs in {fn}')


if __name__ == '__main__':
    main()
