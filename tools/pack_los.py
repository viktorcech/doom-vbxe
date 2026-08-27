#!/usr/bin/env python3
"""Precomputed line of sight for the exploding barrels (A_Explode).

WHY. p_map.c P_RadiusAttack calls P_CheckSight before it applies damage, so a
barrel behind a wall neither hurts the player nor chains into the barrel in the
next room. This port had no sight test at all -- the blast was pure distance, so
it went straight through walls (enemy.asm said so in its header). A real
P_CheckSight is a BSP trace with an opening test per crossed two-sided line:
a lot of 6502 for something that fires a handful of times per level. Barrels do
not move, so the whole thing is computed HERE, once, per barrel.

THE TABLE. PIT_RadiusAttack's reach is CHEBYSHEV -- dist = max(|dx|,|dy|), minus
the target's radius (BOOM_R 16), out of range at bombdamage (BOOM_DMG 128) -- so
the damaged area is exactly the square |dx|,|dy| <= 143 around the barrel. One
bit per 16x16 cell of that square is 19x19 bits = 76 B. A record is

    +0  u8  thing index (into the .things blob's thing array)
    +1  u8  pad
    +2  19 rows x 4 bytes, MSB first: bit c of row r = 1 -> the CENTRE of cell
        (c,r), world (x + 16*(c-9), y + 16*(r-9)), is VISIBLE from the barrel
    +78 pad to LOS_REC

LOS_NMAX records, the unused ones marked with thing index $FF. The engine finds
a barrel's record by thing index (enemy.asm en_lfind) and reads one bit per
candidate (en_los): an explosion costs a <= 40-entry scan plus a bit test per
thing, and no geometry at runtime.

WHAT BLOCKS. Solid (one-sided) linedefs only. A two-sided line never blocks: it
may be a door that is shut while this table is built and open when the barrel
goes off, and the safe direction is to let the blast through. So this table is
"the blast does not cross a WALL", not full P_CheckSight.

RESOLUTION. The cell CENTRE decides the whole cell, so the sight edge can be off
by up to 8 units against a 143-unit blast radius. A bit per world unit would be
287x287 per barrel.

Usage:  python pack_los.py [E1M1 ...]      # stats + an ASCII dump per barrel
"""
import os
import struct
import sys

from wadlib import Wad, DEFAULT_WAD

BARREL = 2035                 # mobjinfo MT_BARREL (wadthings.py: 'BAR1')
BOOM_R = 16                   # memory_map.inc -- keep in step
BOOM_DMG = 128
REACH = BOOM_R + BOOM_DMG - 1  # 143: the largest |dx| that still does damage

GRID_STEP = 16                # world units per cell (a power of 2: the 6502 side
                              #   turns a delta into a cell with four LSRs)
GRID_MID = (REACH + GRID_STEP - 1) // GRID_STEP        # 9 cells each way
GRID_N = GRID_MID * 2 + 1                              # 19x19
GRID_ROW = (GRID_N + 7) // 8 + 1                       # 4 B/row (3 would do; 4
                                                       #   makes row*4 two ASLs)
LOS_NMAX = 40                 # barrel records per level (E1M4 has the most: 32)
LOS_REC = 80                  # record stride, a round number >= 2 + 19*4
LOS_BYTES = LOS_NMAX * LOS_REC                         # 3200 B = 25 sectors
LOS_EXT = 0x6A00              # Rapidus bank $01, above TH_TICS (memory_map.inc)

_HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'things')

assert 2 + GRID_N * GRID_ROW <= LOS_REC


def walls(md):
    """The blockers: one-sided linedefs, as (x1,y1,x2,y2). A two-sided line is
    an opening (or a door that will open) -- see the module header."""
    out = []
    for ld in md.linedefs:
        if ld.two_sided:
            continue
        v1, v2 = md.vertices[ld.v1], md.vertices[ld.v2]
        if (v1.x, v1.y) != (v2.x, v2.y):
            out.append((v1.x, v1.y, v2.x, v2.y))
    return out


def _near(walls_, bx, by, reach):
    """The walls whose bounding box meets the blast square -- everything else
    can never be crossed by a ray that stays inside it."""
    x0, x1 = bx - reach, bx + reach
    y0, y1 = by - reach, by + reach
    return [w for w in walls_
            if max(w[0], w[2]) >= x0 and min(w[0], w[2]) <= x1
            and max(w[1], w[3]) >= y0 and min(w[1], w[3]) <= y1]


def sees(bx, by, tx, ty, near):
    """Segment (b -> t) against the walls, in exact integer arithmetic.

    The wall's parameter u is half-open [0,1): a ray through a vertex shared by
    two walls is then counted by exactly one of them, instead of by both (which
    would be arbitrary) or by neither (which would leak the blast through every
    corner on a grid-aligned map -- and DOOM maps are grid-aligned)."""
    dx, dy = tx - bx, ty - by
    if dx == 0 and dy == 0:
        return True
    for (x1, y1, x2, y2) in near:
        ex, ey = x2 - x1, y2 - y1
        den = dx * ey - dy * ex
        if den == 0:                       # parallel (or collinear): no crossing
            continue
        wx, wy = x1 - bx, y1 - by
        tn = wx * ey - wy * ex             # t * den
        un = wx * dy - wy * dx             # u * den
        if den < 0:
            tn, un, den = -tn, -un, -den
        if 0 < tn < den and 0 <= un < den:
            return False
    return True


def grid(md_walls, bx, by):
    """The 19x19 visibility bitmap of one barrel -> [GRID_N * GRID_ROW] bytes."""
    near = _near(md_walls, bx, by, GRID_MID * GRID_STEP)
    rows = bytearray(GRID_N * GRID_ROW)
    for r in range(GRID_N):
        ty = by + (r - GRID_MID) * GRID_STEP
        o = r * GRID_ROW
        for c in range(GRID_N):
            tx = bx + (c - GRID_MID) * GRID_STEP
            if sees(bx, by, tx, ty, near):
                rows[o + (c >> 3)] |= 0x80 >> (c & 7)
    return rows


def pack(md, barrels):
    """barrels = [(thing index, x, y)] in .things order -> the LOS_BYTES blob."""
    blob = bytearray(LOS_BYTES)
    for i in range(LOS_NMAX):
        blob[i * LOS_REC] = 0xFF                       # empty record
    w = walls(md)
    kept = barrels[:LOS_NMAX]
    if len(barrels) > LOS_NMAX:
        print(f'  WARNING: {len(barrels)} barrels > LOS_NMAX {LOS_NMAX} -- the '
              f'last {len(barrels) - LOS_NMAX} keep the old through-wall blast')
    for i, (ti, bx, by) in enumerate(kept):
        o = i * LOS_REC
        blob[o] = ti
        blob[o + 2:o + 2 + GRID_N * GRID_ROW] = grid(w, bx, by)
    return blob


def barrels_of(things):
    """[(thing index, x, y)] out of pack_things' FINAL thing list (per record:
    x at 1, y at 2, the WAD thing type at 7).

    Taking the index from that list rather than re-deriving it from the WAD is
    the whole point: the record is found at runtime BY thing index, and
    pack_things drops things for reasons this file cannot see (no sprite lump,
    no patch, a sprite too big for a byte) before it sorts them by subsector."""
    return [(i, r[1], r[2]) for i, r in enumerate(things) if r[7] == BARREL]


def _barrels_approx(md, skill=2):
    """Barrel positions straight from the WAD -- for the stats/dump path below
    only. The indexes are NOT the engine's (see barrels_of)."""
    from wadthings import map_things
    return [(i, t.x, t.y)
            for i, (t, base, *_rest) in enumerate(map_things(md, skill=skill))
            if base is not None and t.type == BARREL]


def dump(md, bx, by):
    """ASCII picture of one barrel's grid: # = blocked, . = visible, B = barrel."""
    g = grid(walls(md), bx, by)
    out = []
    for r in range(GRID_N - 1, -1, -1):                # north up
        line = ''
        for c in range(GRID_N):
            vis = g[r * GRID_ROW + (c >> 3)] & (0x80 >> (c & 7))
            line += 'B' if (r == GRID_MID and c == GRID_MID) else ('.' if vis else '#')
        out.append(line)
    return '\n'.join(out)


def main():
    names = [a for a in sys.argv[1:] if not a.startswith('--')] or ['E1M1']
    verbose = '-v' in sys.argv
    wad = Wad(DEFAULT_WAD)
    for nm in names:
        md = wad.load_map(nm)
        bs = _barrels_approx(md)
        blob = pack(md, bs)
        cells = GRID_N * GRID_N
        tot = 0
        for i, (ti, bx, by) in enumerate(bs[:LOS_NMAX]):
            o = i * LOS_REC + 2
            n = sum(bin(b).count('1')
                    for r in range(GRID_N)
                    for b in blob[o + r * GRID_ROW:o + r * GRID_ROW + GRID_ROW])
            tot += cells - n
            if verbose:
                print(f'\n{nm} barrel thing {ti} at ({bx},{by}): '
                      f'{cells - n}/{cells} cells blocked')
                print(dump(md, bx, by))
        print(f'{nm}: {len(bs)} barrels, {len(blob)} B blob, '
              f'{tot / max(1, len(bs)):.0f}/{cells} cells blocked on average')


if __name__ == '__main__':
    main()
