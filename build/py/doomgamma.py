#!/usr/bin/env python3
"""DOOM's gamma correction (the F11 key; '8' in this port) -> the GAMMA BLOCK.

v_video.c's gammatable[5][256] is read out of the DOOM source, as it stands:
I_SetPalette sends every colour component through gammatable[usegamma], level
0 ("OFF") included -- its table is not the identity.

The block rides the weapon master's stream into SDRAM (make_atr_doom.py
GAMMA_EXT) and lights.asm gm_apply installs the palettes from it:

    +$000   gammatable[0..4], 256 B each
    +$500   per installed PLAYPAL slot (playpal.bin, pack_textures.py
            PAL_SLOTS): its R plane, G plane, B plane, 256 B each

Planes, so that the colour is the index of every read (no pointer walks three
bytes a colour).
"""
import os
import re

from doomstates import SRC_DIR

LEVELS = 5
PAL_OFF = LEVELS * 256               # PALRAW_EXT - GAMMA_EXT


def gammatable():
    path = os.path.join(SRC_DIR, 'v_video.c')
    if not os.path.isfile(path):
        raise SystemExit(f'  ERROR: {path} is missing -- gammatable comes from it')
    text = open(path, encoding='latin-1').read()
    m = re.search(r'gammatable\s*\[5\]\s*\[256\]\s*=\s*\{(.*?)\}\s*;', text, re.S)
    nums = [int(n) for n in re.findall(r'\d+', m.group(1))] if m else []
    if len(nums) != LEVELS * 256 or max(nums) > 255:
        raise SystemExit(f'  ERROR: gammatable in {path}: {len(nums)} values, want 1280')
    return bytes(nums)


def block(playpal):
    """The gamma block for the palettes in playpal (768 B each, r,g,b)."""
    if len(playpal) % 768:
        raise SystemExit('  ERROR: playpal.bin is not whole palettes')
    out = bytearray(gammatable())
    for p in range(len(playpal) // 768):
        pal = playpal[p * 768:(p + 1) * 768]
        out += pal[0::3] + pal[1::3] + pal[2::3]
    return bytes(out)


if __name__ == '__main__':
    g = gammatable()
    for lv in range(LEVELS):
        row = g[lv * 256:(lv + 1) * 256]
        print(f'level {lv}: 0 -> {row[0]}, 64 -> {row[64]}, 128 -> {row[128]}, 255 -> {row[255]}')
