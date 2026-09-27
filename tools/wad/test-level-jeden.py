#!/usr/bin/env python3
"""test-level -- the port's TEST MAP: one room with every weapon and item the
engine knows, and a wall of switches, each opening a closet with one monster type.

Writes tools/wad/test/test-level.wad, a PWAD with a single map, and converts it
with wadconv's normal pipeline into build/doom-test-level.atr. The map's name, E1M1,
lives only inside that WAD: wadconv snapshots and restores every project file
around its build, so the project's own maps and build/doom.atr are not touched.

    python tools/wad/test-level.py              # WAD + build/doom-test-level.atr
    python tools/wad/test-level.py --wad        # the WAD only
    python tools/wad/test-level.py --nolaunch   # do not start Altirra after

THE ROOM (map units, y up). The hall is W x 1024 with a 128 ceiling. On its NORTH
wall a 64-wide SW1STRTN switch (special 103, S1 Door Open Stay) stands straight
across from each closet door in its SOUTH wall, so the switch's column says which
monster it lets out. West to east:
    zombieman, shotgun guy, imp, demon, spectre, lost soul, cacodemon, baron,
    cyberdemon, spider mastermind
The player starts facing the switches, the items lie in a grid between, and a
released monster walks at you across the hall. Each door is a 24-deep sector with
ceiling = floor (BIGDOOR2, DOORTRAK jambs); it opens to the lowest neighbour
ceiling - 4 = 124, over the cyberdemon's 110. The spider's closet is 320 x 320
for its 128 radius, the cyberdemon's 192.

THE NODES are built here (the tree has no nodebuilder): the classic recursive
split on seg lines -- fewest splits, then best balance -- until every seg set is
convex. All geometry is axis-aligned, so every split vertex is an integer.
pack_map reads SEGS/SSECTORS/NODES only; REJECT (all zero) and a conservative
BLOCKMAP are written as well, so the WAD also runs in real DOOM for comparison.
"""
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, 'test', 'test-level.wad')
ATR_NAME = 'doom-test-level'            # -> build/doom-test-level.atr.
                                        # NOT 'doom': build_atr.ps1 has one
                                        # output name and wadconv renames it
                                        # afterwards, so a build that FAILS
                                        # leaves its half-made image sitting
                                        # in build/doom.atr

H, CEIL, DOOR_D, LIGHT = 1024, 128, 24, 192
MARGIN, GAP = 128, 96
MONSTERS = [                    # doomednum, closet width, closet depth
    (3004, 128, 128), (9, 128, 128), (3001, 128, 128), (3002, 128, 128),
    (58, 128, 128), (3006, 128, 128), (3005, 128, 128), (3003, 128, 128),
    (16, 192, 192), (7, 320, 320)]
ITEMS = [2005, 2001, 2002, 2003, 2004, 2006,              # the six weapons
         2007, 2048, 2008, 2049, 2010, 2046, 2047, 17, 8,   # ammo + backpack
         2011, 2012, 2014, 2013, 2015, 2018, 2019,          # health, armour
         2022, 2023, 2024, 2025, 2026, 2045,                # the six powers
         5, 40, 6, 39, 13, 38, 2035]                        # keys, a barrel
ALL_SKILLS = 7

verts, vidx, lines, sides, sectors, things = [], {}, [], [], [], []


def V(x, y):
    if (x, y) not in vidx:
        vidx[(x, y)] = len(verts)
        verts.append((x, y))
    return vidx[(x, y)]


def S(sec, mid='-', up='-'):
    sides.append((sec, mid, up))
    return len(sides) - 1


def L(a, b, right, left=0xFFFF, flags=1, special=0, tag=0):
    lines.append((V(*a), V(*b), flags, special, tag, right, left))


def SEC(floor, ceil, tag=0):
    sectors.append((floor, ceil, tag))
    return len(sectors) - 1


def geometry():
    """Every outline clockwise, so the sector a line bounds is on its RIGHT."""
    closets, x = [], MARGIN
    for num, w, depth in MONSTERS:
        closets.append((x, x + w, depth, num))
        x += w + GAP
    width = x - GAP + MARGIN
    hall = SEC(0, CEIL)
    L((0, 0), (0, H), S(hall, 'STARTAN3'))
    cuts = [0]
    for a, b, _, _ in closets:
        cuts += [(a + b) // 2 - 32, (a + b) // 2 + 32]
    cuts.append(width)
    for j in range(len(cuts) - 1):                  # north wall, eastward
        if j % 2:
            L((cuts[j], H), (cuts[j + 1], H), S(hall, 'SW1STRTN'),
              special=103, tag=j // 2 + 1)
        else:
            L((cuts[j], H), (cuts[j + 1], H), S(hall, 'STARTAN3'))
    L((width, H), (width, 0), S(hall, 'STARTAN3'))
    prev = width
    for i in reversed(range(len(closets))):         # south wall, westward
        a, b, depth, num = closets[i]
        L((prev, 0), (b, 0), S(hall, 'STARTAN3'))
        door, room = SEC(0, 0, tag=i + 1), SEC(0, CEIL)
        bot = -DOOR_D - depth
        L((b, 0), (a, 0), S(hall, up='BIGDOOR2'), S(door), flags=4)
        L((a, -DOOR_D), (a, 0), S(door, 'DOORTRAK'), flags=1 | 16)
        L((b, 0), (b, -DOOR_D), S(door, 'DOORTRAK'), flags=1 | 16)
        L((b, -DOOR_D), (a, -DOOR_D), S(door), S(room, up='BIGDOOR2'), flags=4)
        L((a, bot), (a, -DOOR_D), S(room, 'STARTAN3'))
        L((b, -DOOR_D), (b, bot), S(room, 'STARTAN3'))
        L((b, bot), (a, bot), S(room, 'STARTAN3'))
        things.append(((a + b) // 2, (bot - DOOR_D) // 2, 90, num, room))
        prev = a
    L((prev, 0), (0, 0), S(hall, 'STARTAN3'))
    things.append((width // 2, H - 256, 90, 1, hall))        # player 1 start
    for k, num in enumerate(ITEMS):                           # 9 x 4 grid
        things.append((width // 2 + (k % 9 - 4) * 96, 560 - (k // 9) * 96,
                       90, num, hall))
    return width


# ---------------------------------------------------------------- nodes --
def cross(p, x, y):
    """> 0 = FRONT of partition p: pack_map's and R_PointOnSide's child 0."""
    return (p[3] - p[1]) * (x - p[0]) - (p[2] - p[0]) * (y - p[1])


def classify(p, s):
    a, b = cross(p, s[0], s[1]), cross(p, s[2], s[3])
    if a == 0 and b == 0:           # collinear: its direction decides
        same = (p[2] - p[0]) * (s[2] - s[0]) + (p[3] - p[1]) * (s[3] - s[1]) > 0
        return 0 if same else 1
    if a >= 0 and b >= 0:
        return 0
    if a <= 0 and b <= 0:
        return 1
    return 2


def split(p, s):
    a, b = cross(p, s[0], s[1]), cross(p, s[2], s[3])
    t = a / (a - b)
    ix, iy = s[0] + (s[2] - s[0]) * t, s[1] + (s[3] - s[1]) * t
    assert ix == int(ix) and iy == int(iy), 'a split off the integer grid'
    ix, iy = int(ix), int(iy)
    head, tail = (s[0], s[1], ix, iy) + s[4:], (ix, iy, s[2], s[3]) + s[4:]
    return (head, tail) if a > 0 else (tail, head)       # (front, back)


def bbox(segs):
    xs = [c for s in segs for c in (s[0], s[2])]
    ys = [c for s in segs for c in (s[1], s[3])]
    return max(ys), min(ys), min(xs), max(xs)            # top bottom left right


def seg_sector(s):
    ln = lines[s[4]]
    return sides[ln[5] if s[5] == 0 else ln[6]][0]


def build_nodes():
    segs = []
    for li, (v1, v2, _, _, _, _, left) in enumerate(lines):
        (x1, y1), (x2, y2) = verts[v1], verts[v2]
        segs.append((x1, y1, x2, y2, li, 0))
        if left != 0xFFFF:
            segs.append((x2, y2, x1, y1, li, 1))
    nodes, ssecs, order = [], [], []

    def rec(ss):
        best = None
        for p in ss:
            n = [0, 0, 0]
            for s in ss:
                n[classify(p, s)] += 1
            if n[1] + n[2] and (best is None or n[2] * 8 + abs(n[0] - n[1]) < best[0]):
                best = (n[2] * 8 + abs(n[0] - n[1]), p)
        if best is None:                                  # convex: a subsector
            assert len({seg_sector(s) for s in ss}) == 1, 'subsector spans sectors'
            ssecs.append((len(ss), len(order)))
            order.extend(ss)
            return 0x8000 | (len(ssecs) - 1)
        p, front, back = best[1], [], []
        for s in ss:
            k = classify(p, s)
            if k == 2:
                f, b = split(p, s)
                front.append(f)
                back.append(b)
            else:
                (front if k == 0 else back).append(s)
        cf, cb = rec(front), rec(back)
        nodes.append((p[0], p[1], p[2] - p[0], p[3] - p[1],
                      bbox(front), bbox(back), cf, cb))
        return len(nodes) - 1

    rec(segs)
    recs = []
    for x1, y1, x2, y2, li, sd in order:
        ox, oy = verts[lines[li][0] if sd == 0 else lines[li][1]]
        ang = round(math.atan2(y2 - y1, x2 - x1) * 32768 / math.pi) & 0xFFFF
        recs.append((V(x1, y1), V(x2, y2), ang, li, sd,
                     round(math.hypot(x1 - ox, y1 - oy))))
    return nodes, ssecs, recs


def locate(nodes, ssecs, recs, x, y):
    """pack_map's own BSP descent (mapview.locate), on the lumps as written."""
    nid = len(nodes) - 1
    while not nid & 0x8000:
        n = nodes[nid]
        nid = n[6] if (y - n[1]) * n[2] < n[3] * (x - n[0]) else n[7]
    _, first = ssecs[nid & 0x7FFF]
    _, _, _, li, sd, _ = recs[first]
    return sides[lines[li][5] if sd == 0 else lines[li][6]][0]


def blockmap():
    xs, ys = [v[0] for v in verts], [v[1] for v in verts]
    ox, oy = min(xs) - 8, min(ys) - 8
    cols, rows = (max(xs) - ox) // 128 + 1, (max(ys) - oy) // 128 + 1
    offs, body = [], []
    for r in range(rows):
        for c in range(cols):
            x0, y0 = ox + c * 128, oy + r * 128
            hit = [i for i, (v1, v2, *_rest) in enumerate(lines)
                   if min(verts[v1][0], verts[v2][0]) <= x0 + 128
                   and max(verts[v1][0], verts[v2][0]) >= x0
                   and min(verts[v1][1], verts[v2][1]) <= y0 + 128
                   and max(verts[v1][1], verts[v2][1]) >= y0]
            offs.append(4 + cols * rows + len(body))
            body += [0] + hit + [0xFFFF]
    return (struct.pack('<hhHH', ox, oy, cols, rows)
            + struct.pack(f'<{len(offs)}H', *offs) + struct.pack(f'<{len(body)}H', *body))


def name8(s):
    return s.encode('ascii').ljust(8, b'\0')


def write_wad():
    width = geometry()
    nodes, ssecs, recs = build_nodes()
    for x, y, _, num, sec in things:
        got = locate(nodes, ssecs, recs, x, y)
        assert got == sec, f'thing {num} at ({x},{y}) lands in sector {got}, not {sec}'
    lumps = [
        ('E1M1', b''),
        ('THINGS', b''.join(struct.pack('<hhhhh', x, y, a, n, ALL_SKILLS)
                            for x, y, a, n, _ in things)),
        ('LINEDEFS', b''.join(struct.pack('<7H', *ln) for ln in lines)),
        ('SIDEDEFS', b''.join(struct.pack('<hh8s8s8sH', 0, 0, name8(up), b'-'.ljust(8, b'\0'),
                                          name8(mid), sec) for sec, mid, up in sides)),
        ('VERTEXES', b''.join(struct.pack('<hh', *v) for v in verts)),
        ('SEGS', b''.join(struct.pack('<5Hh', *r) for r in recs)),
        ('SSECTORS', b''.join(struct.pack('<HH', *s) for s in ssecs)),
        ('NODES', b''.join(struct.pack('<4h4h4hHH', *n[:4], *n[4], *n[5], n[6], n[7])
                           for n in nodes)),
        ('SECTORS', b''.join(struct.pack('<hh8s8sHHH', f, c, name8('FLOOR4_8'),
                                         name8('CEIL3_5'), LIGHT, 0, t)
                             for f, c, t in sectors)),
        ('REJECT', bytes((len(sectors) ** 2 + 7) // 8)),
        ('BLOCKMAP', blockmap()),
    ]
    data, dirs, pos = b'', b'', 12
    for nm, blob in lumps:
        dirs += struct.pack('<ii8s', pos, len(blob), name8(nm))
        data += blob
        pos += len(blob)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'wb') as f:
        f.write(struct.pack('<4sii', b'PWAD', len(lumps), 12 + len(data)) + data + dirs)
    print(f'{OUT}: hall {width}x{H}, {len(sectors)} sectors, {len(lines)} lines, '
          f'{len(things)} things, {len(nodes)} nodes, {len(ssecs)} subsectors, '
          f'{len(recs)} segs')


def main():
    write_wad()
    if '--wad' in sys.argv:
        return 0
    import wadconv                      # beside this script: the normal pipeline
    if '--nolaunch' in sys.argv:
        wadconv.find_altirra = lambda: ''
    return wadconv.build(wadconv.default_iwad(), OUT, ['E1M1'], print,
                         wadconv.Progress(wadconv._cli_progress), name=ATR_NAME)


if __name__ == '__main__':
    sys.exit(main())
