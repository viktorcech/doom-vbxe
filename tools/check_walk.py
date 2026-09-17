#!/usr/bin/env python3
"""Walk-cycle coverage per level: every monster kind a level spawns (and that
has a RUN chain -- not the barrel) must ship at least one walk image.

WHY: ai_setrow (enemy_ai.asm) folds the RUN state onto the images with
`cmp [zp_ptr],y / bcc / sbc [zp_ptr],y / bcs` against WTAB_N[kind]. With
WTAB_N = 0 that loop never exits -- the game freezes the tic the monster
wakes. pack_walk (pack_things.py) leaves wn = 0 / wfirst = $FF for a kind
when the frame-id / row budget runs out.

Reads build/assets/things/<LEVEL>.dtab (header 1 = WTAB_EXT, header 2 =
WTAB_N, 16 B each, index = kind) and the WAD's things at the packer's skill.

  python tools/check_walk.py              # every .dtab in build/assets/things
  python tools/check_walk.py E3M9 E1M6
  python tools/check_walk.py --skill 4
"""
import glob
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import doomstates                     # noqa: E402
from wadlib import Wad                # noqa: E402
from wadthings import map_things      # noqa: E402

PROJ = os.path.dirname(_HERE)
DTAB_DIR = os.path.join(PROJ, 'build', 'assets', 'things')
DTAB_HDR = 16
MK_ORDER = doomstates.MONSTERS        # == pack_things.MK_ORDER


def live_kinds(wad, name, skill):
    """{doomednum: things} of the monster types that reach TH_KIND at runtime.

    The RUNTIME kind is per SPAWN SPRITE, last thing wins (pack() kind_of):
    the demon (3002) and the spectre (58) are both SARGA1, so on a level with
    both every SARG thing carries whichever type came last -- the other kind
    never reaches TH_KIND and its empty WTAB_N cannot be read."""
    md = wad.load_map(name)
    kind_of_spr = {}
    count = {}
    for t, base, frame, *_ in map_things(md, skill=skill):
        if t.type in MK_ORDER and base is not None:
            kind_of_spr[(base, frame)] = t.type
            count[(base, frame)] = count.get((base, frame), 0) + 1
    live = {}
    for spr, num in kind_of_spr.items():
        live[num] = live.get(num, 0) + count[spr]
    return live


def check(wad, name, skill):
    raw = open(os.path.join(DTAB_DIR, f'{name}.dtab'), 'rb').read()
    dfirst = raw[0 * DTAB_HDR:1 * DTAB_HDR]
    wfirst = raw[1 * DTAB_HDR:2 * DTAB_HDR]
    wn = raw[2 * DTAB_HDR:3 * DTAB_HDR]
    afirst = raw[3 * DTAB_HDR:4 * DTAB_HDR]
    pfirst = raw[4 * DTAB_HDR:5 * DTAB_HDR]
    d = doomstates.doom()
    live = live_kinds(wad, name, skill)
    bad = []
    lines = []
    for num, n in sorted(live.items(), key=lambda kv: MK_ORDER.index(kv[0])):
        k = MK_ORDER.index(num) + 1
        chase = bool(d.run_chain(num))
        ok = (not chase) or wn[k] > 0
        lines.append(f'  kind {k:2} ({num:5}) x{n:3}  WTAB_EXT=${wfirst[k]:02X} '
                     f'WTAB_N={wn[k]}  death ${dfirst[k]:02X} atk ${afirst[k]:02X} '
                     f'pain ${pfirst[k]:02X}{"" if chase else "  (no RUN chain)"}'
                     f'{"" if ok else "   <-- FREEZE: ai_setrow divides by 0"}')
        if not ok:
            bad.append(k)
    return bad, lines


def main():
    argv = sys.argv[1:]
    skill = 2
    if '--skill' in argv:
        i = argv.index('--skill')
        skill = int(argv[i + 1])
        del argv[i:i + 2]
    names = argv or sorted(os.path.splitext(os.path.basename(p))[0]
                           for p in glob.glob(os.path.join(DTAB_DIR, '*.dtab')))
    wad = Wad()
    nbad = 0
    for name in names:
        bad, lines = check(wad, name, skill)
        print(f'{name}: {"OK" if not bad else f"{len(bad)} kind(s) WITHOUT walk images"}')
        for ln in lines:
            print(ln)
        nbad += bool(bad)
    print(f'\n{nbad} level(s) with a kind that would hang ai_setrow (skill {skill})')
    return 1 if nbad else 0


if __name__ == '__main__':
    sys.exit(main())
