#!/usr/bin/env python3
"""Lift the menu CODE overlay out of the XEX and into the menu asset blob.

menu.asm's third part is assembled for $1000 (MENU_RUN -- the per-frame render
arrays, which are dead RAM while the game is paused) but PARKED at $C000
(MNOVL_STAGE) with MADS's two-address ORG, so the block that comes out of the
assembler carries the right code with the wrong load address. It must never
reach base RAM: $C000 is the THINGS slot, and the boot loader writing 1 KB of
menu there would be overwritten by the first load_things anyway.

So this runs between mads and check_xex.py and does two things:

  * writes the block's payload into build/assets/menu/menu.bin at MENU_OVL_OFF,
    the 4 KB chunk tools/pack_menu.py reserved for it. load_menu streams that
    chunk into VBXE VRAM at $00E000 and mn_open copies it down on demand.
  * rewrites the XEX WITHOUT the block, so the ATR carries one copy of it, in
    the asset blob, and check_xex.py never sees a segment in reserved RAM.

The addresses are read out of the sources, not repeated here: MNOVL_STAGE from
memory_map.inc, MENU_OVL_OFF and MENU_OCHUNKS from the generated menu_syms.inc.

  python tools/split_menu_ovl.py [build/doom_bsp.xex]
"""
import os
import re
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(_HERE)
CHUNK = 4096


def equ(path, name):
    """`NAME equ $1234` / `NAME equ 45056` out of a MADS include."""
    src = open(os.path.join(ROOT, path), encoding='latin-1').read()
    m = re.search(r'^\s*%s\s+equ\s+(\$?[0-9A-Fa-f]+)' % name, src, re.M)
    if not m:
        sys.exit('split_menu_ovl: %s is not in %s' % (name, path))
    v = m.group(1)
    return int(v[1:], 16) if v.startswith('$') else int(v)


def segments(blob):
    """[(start, end, payload_slice)] over a segmented Atari XEX."""
    out, i = [], 2
    while i + 4 <= len(blob):
        s, e = struct.unpack('<HH', blob[i:i + 4])
        if s == 0xFFFF:                          # a repeated $FFFF header
            i += 2
            continue
        n = e - s + 1
        out.append((s, e, i, i + 4 + n))         # header offset, end offset
        i += 4 + n
    return out


def main():
    xex = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build',
                                                             'doom_bsp.xex')
    off = equ('menu_syms.inc', 'MENU_OVL_OFF')
    # ALL the overlay chunks pack_menu.py reserved, not just the two that stream
    # into consecutive banks: the automap's is a stream of its own (menu.asm's
    # mn_ld_tab), but it is reserved in the same run and lifted the same way.
    nch = equ('menu_syms.inc', 'MENU_OVL_N')
    # One entry per overlay: (staging address, which source, byte offset in
    # menu.bin). The first three share the contiguous OVL reserve at
    # MENU_OVL_OFF, one chunk each. wi.asm's does NOT: pack_menu.py parks it
    # directly behind the intermission PIXELS so the two are one consecutive
    # bank run and menu.asm needs only one mn_ld_tab row for both -- so it
    # carries its own offset (WI_OVL_OFF).
    ovls = [(equ('memory_map.inc', 'MNOVL_STAGE'), 'menu.asm', off + 0 * CHUNK),
            (equ('memory_map.inc', 'SGOVL_STAGE'), 'savegame.asm', off + 1 * CHUNK),
            # the AUTOMAP overlay is NOT lifted any more (2026-08-31): it rides
            # the XEX at AMOVL_STAGE and b1_to_ext copies it into Rapidus bank
            # $01 (AMOVL_EXT) -- its old menu.bin chunk (off + 2*CHUNK) stays
            # reserved and zeroed so every other stream's sector stays put.
            (equ('memory_map.inc', 'WIOVL_STAGE'), 'wi.asm stage 1',
             equ('menu_syms.inc', 'WI_OVL_OFF')),
            # ...and its stage 2, which runs in the MAP SLOT and is therefore
            # assembled AT $4000 with no two-address org at all. The engine has
            # carried no $4000 segment since the map started streaming, so this
            # is still "exactly one segment at that address".
            (equ('memory_map.inc', 'WI2_RUN'), 'wi.asm stage 2',
             equ('menu_syms.inc', 'WI_OVL2_OFF')),
            # ...and the FINALE's pair (f_finale.asm), the two chunks pack_menu
            # reserved behind those in the same run. Stage 2 runs at WI2_RUN as
            # well -- the intermission and the finale are the two halves of one
            # `if` and can never both be live -- so unlike wi.asm's it carries a
            # two-address `org` and is PARKED at FIN2_STAGE: this loop finds an
            # overlay by its segment START address, and two segments at $4100 is
            # exactly the ambiguity the WI2_RUN note above warns about.
            (equ('memory_map.inc', 'FINOVL_STAGE'), 'f_finale.asm stage 1',
             equ('menu_syms.inc', 'FIN_OVL_OFF')),
            (equ('memory_map.inc', 'FIN2_STAGE'), 'f_finale.asm stage 2',
             equ('menu_syms.inc', 'FIN_OVL2_OFF')),
            # ...and the EPISODE picker (m_episode.asm), the first chunk of the
            # HU-strip run: pack_menu.py puts it in front of the strips so the
            # two share one mn_ld_tab row.
            (equ('memory_map.inc', 'EPIOVL_STAGE'), 'm_episode.asm',
             equ('menu_syms.inc', 'MENU_LVCH') * CHUNK)]
    shared = sum(1 for _s, _w, o in ovls if off <= o < off + nch * CHUNK)
    if shared > nch:
        sys.exit('split_menu_ovl: %d overlays in the shared reserve, only %d '
                 'chunks -- raise OVL_CHUNKS in tools/pack_menu.py' % (shared, nch))

    binp = os.path.join(ROOT, 'build', 'assets', 'menu', 'menu.bin')
    menu = bytearray(open(binp, 'rb').read())
    if len(menu) < off + nch * CHUNK:
        sys.exit('split_menu_ovl: menu.bin is %d B, no room reserved at %d -- '
                 'run tools/pack_menu.py first' % (len(menu), off))
    blob = bytearray(open(xex, 'rb').read())
    for i, (stage, who, o) in enumerate(ovls):
        hits = [s for s in segments(blob) if s[0] == stage]
        if len(hits) != 1:
            sys.exit('split_menu_ovl: expected exactly ONE segment at $%04X, '
                     'found %d -- did %s lose its two-address `org`?'
                     % (stage, len(hits), who))
        start, end, hdr, tail = hits[0]
        code = bytes(blob[hdr + 4:tail])
        if len(code) > CHUNK:
            sys.exit('split_menu_ovl: %s is %d B, a chunk holds %d'
                     % (who, len(code), CHUNK))
        if len(menu) < o + CHUNK:
            sys.exit('split_menu_ovl: %s wants menu.bin +%d, the file is %d B'
                     % (who, o, len(menu)))
        menu[o:o + CHUNK] = code + bytes(CHUNK - len(code))
        del blob[hdr:tail]                       # ...and out of the XEX
        print('  %-12s overlay %4d B: $%04X block -> menu.bin +%d (chunk %d)'
              % (who, len(code), stage, o, o // CHUNK))
    open(binp, 'wb').write(menu)
    open(xex, 'wb').write(blob)


if __name__ == '__main__':
    main()
