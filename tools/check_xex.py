#!/usr/bin/env python3
"""doom -- guard against XEX segments landing in reserved RAM (adapted from
doom2d/wolf3d tools/check_xex.py).

MADS does not error when separate `org` blocks overlap each other or land in
regions that are ROM / get overwritten at runtime -- the result is a silent
"black screen" or a KIL much later. This parses the segmented XEX and fails
the build if any segment overlaps a reserved range, AND if any two segments
overlap each other. Run by build.ps1 / build_atr.ps1.

Reserved ranges (see memory_map.inc, the single source of truth):
  $0700-$08FF  ATR boot loader + its sector buffer (alive WHILE the XEX loads)
  $4000-$4BFF  streamed map slot, LOW region (load_level overwrites it). Was
               $4000-$85FF until 2026-07-31, when the seg table moved to a
               Rapidus bank and $4C00-$85FF became ordinary RAM.
  $9000-$9FFF  MEMAC-A window (writes go to VBXE, not RAM)
  $B000-$BFFF  TEX_STAGE (load_textures streams texture chunks here AFTER the XEX
               loads -- code up there is destroyed on the first level load; the
               symptom is a flat pink screen, so this check is the only guard)
  NOTE $A000-$AFFF is legitimately code (palette/textab, QSqr, textured blit).
  $C000-$FFFF  Atari OS ROM

Usage:  python tools/check_xex.py build/doom_bsp.xex
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ram_map import RESERVED, STAGED  # ONE source of truth for the runtime map


def main():
    data = open(sys.argv[1], 'rb').read()
    i = 2 if data[0:2] == b'\xff\xff' else 0
    bad = []
    segs = []
    while i + 4 <= len(data):
        start, end = struct.unpack_from('<HH', data, i)
        i += 4
        if start == 0xFFFF:
            continue
        if end < start:
            bad.append(f'corrupt segment header @ {i-4}: ${start:04X}-${end:04X}')
            break
        if (start, end) not in ((0x02E0, 0x02E1), (0x02E2, 0x02E3)):
            segs.append((start, end))
        i += end - start + 1
        if any(start >= lo and end <= hi for lo, hi, _w in STAGED):
            continue                 # a deliberate staging segment: it is copied
                                     # out before the thing that reserves the RAM
                                     # ever runs (see STAGED in ram_map.py)
        for lo, hi, what in RESERVED:
            if start <= hi and end >= lo:
                bad.append(f'segment ${start:04X}-${end:04X} overlaps '
                           f'${lo:04X}-${hi:04X} ({what})')
    segs.sort()
    for (s1, e1), (s2, e2) in zip(segs, segs[1:]):
        if s2 <= e1:
            bad.append(f'segments overlap each other: ${s1:04X}-${e1:04X} '
                       f'and ${s2:04X}-${e2:04X}')
    if bad:
        for b in bad:
            print('XEX CHECK FAIL:', b)
        sys.exit(1)
    print(f'xex check OK ({len(segs)} data segments, no reserved overlap)')


if __name__ == '__main__':
    main()
