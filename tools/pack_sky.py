#!/usr/bin/env python3
"""DOOM's sky textures -> build/assets/sky.bin, the columns seg_draw.asm sky_clip paints.

r_plane.c R_DrawPlanes (396) draws an F_SKY1 ceiling as a SCREEN-FIXED texture,
not a flat: column (viewangle + xtoviewangle[x]) >> ANGLETOSKYSHIFT (22) -- 1024
steps a turn, four 256-wide tiles -- row skytexturemid (100) + (y - centery) *
pspriteiscale, always full bright (colormaps[0]). G_InitNew picks the texture
per episode, SKY1/SKY2/SKY3; pack_map.py writes that choice into the level
header (MAP_HSKY).

Layout -- it rides into Rapidus SRAM behind the COLORMAP (make_atr_doom.py
SKY_EXT), read by load_weapons' chunk walk, no loader of its own:
  +$0000  SKY1, SKY2, SKY3: 128 stored columns x 64 B each. A column is the wall
          painter's own record (tools/texruns.py): 32 (rows, colour) pairs that
          sum to 128. Every other source column is kept, as a wall's HALF_W, so
          the stored column is (angle >> 1) & 127.
  +$6000  160 B: the full view's column x as a stored-column offset,
          floor((xtoviewangle(x) >> 22) / 2), a signed byte.
A sky the IWAD does not carry is one black run per column.

Skipped when sky.bin is newer than the WAD, this script and texruns.py (the
k-segment fit is the slow part and none of its inputs moved).

  python tools/pack_sky.py
"""
import math
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                            # noqa: E402
from wadtex import WadTextures                                 # noqa: E402
import texruns                                                 # noqa: E402

OUT = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'sky.bin')
SKIES = ('SKY1', 'SKY2', 'SKY3')
COLS, H, K = 128, 128, 32              # stored columns, texels, runs a column
TAB_OFF = len(SKIES) * COLS * 2 * K    # $6000: the column offsets follow
VIEW_COLS = 160                        # memory_map.inc SCREEN_WIDTH


def stored_columns(wt, name):
    """128 columns of 128 palette indices, or None when the IWAD has no such sky."""
    try:
        w, h, cols = wt.get_texture(name)
    except Exception:
        return None
    step = max(1, w // COLS)
    return [[cols[x * step % w][y % h] for y in range(H)] for x in range(COLS)]


def column_offsets():
    """xtoviewangle for the full 320-wide view (FOV 90, focal 160), sampled at
    the centre of each 2-pixel view column, >> 22 and halved for the stored
    columns. Positive to the left: DOOM's angles grow counter-clockwise."""
    out = bytearray()
    for c in range(VIEW_COLS):
        x = 2 * c + 1
        units = math.floor(math.atan((160 - x) / 160.0) * 1024 / (2 * math.pi))
        out.append((units // 2) & 0xFF)
    return bytes(out)


def build(wad_path=DEFAULT_WAD):
    wt = WadTextures(Wad(wad_path))
    blob = bytearray()
    for name in SKIES:
        cols = stored_columns(wt, name)
        if cols is None:
            print(f'  {name}: not in the WAD -- black')
            blob += bytes((H, 0)) + bytes(2 * K - 2) * 1
            blob += (bytes((H, 0)) + bytes(2 * K - 2)) * (COLS - 1)
            continue
        runs, _grid = texruns.texture_runs(cols, wt.playpal, K)
        assert len(runs) == COLS * 2 * K, f'{name}: {len(runs)} B of runs'
        blob += runs
    assert len(blob) == TAB_OFF
    return bytes(blob) + column_offsets()


def main():
    wad = os.environ.get('DOOMWAD') or DEFAULT_WAD
    inputs = (wad, os.path.abspath(__file__), texruns.__file__)
    if os.path.exists(OUT) and all(os.path.getmtime(OUT) > os.path.getmtime(p)
                                   for p in inputs):
        print('sky up to date -- pack_sky skipped')
        return 0
    data = build(wad)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(data)
    print(f'{OUT}: {len(data)} B ({len(SKIES)} skies x {COLS} columns + {VIEW_COLS} offsets)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
