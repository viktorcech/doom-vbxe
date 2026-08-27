#!/usr/bin/env python3
"""Reusable DOOM WAD reader -- the single source of truth for map geometry.

This is the foundation of the flat-shaded BSP DOOM port: it reads the *exact*
map lumps DOOM ships (vertices, linedefs, sidedefs, sectors, and the prebuilt
BSP: segs/ssectors/nodes). No rasterizing to a grid -- geometry is preserved
1:1. Downstream tools (top-down verify render, ATR packer, the 6502 renderer's
reference) all consume this.

Map lump order after a map marker (ExMy / MAPxx):
    THINGS, LINEDEFS, SIDEDEFS, VERTEXES, SEGS, SSECTORS, NODES,
    SECTORS, REJECT, BLOCKMAP
"""
import os
import struct

import doomspecs
from dataclasses import dataclass, field

_HERE = os.path.dirname(os.path.abspath(__file__))
# The IWAD everything is extracted from, and any PWADs layered on top of it.
# Both come from the environment so that ONE setting reaches every packer:
# pack_map, pack_things, pack_textures, wadsound, pack_weap and pack_hud all
# open the WAD through this module, and tools/wadconv.py builds an ATR from
# somebody else's map WAD by setting these two and running the normal pipeline.
#   DOOMWAD   -- path to the IWAD (graphics, sprites, sounds, textures)
#   DOOMPWAD  -- os.pathsep-separated PWADs; later ones win, like DOOM's -file
DEFAULT_WAD = os.environ.get('DOOMWAD') or os.path.join(_HERE, 'DOOM.WAD')
DEFAULT_PWADS = tuple(p for p in os.environ.get('DOOMPWAD', '').split(os.pathsep) if p)

# linedef flags
ML_BLOCKING = 0x0001
ML_TWOSIDED = 0x0004
ML_DONTPEGTOP = 0x0008
ML_DONTPEGBOTTOM = 0x0010
ML_SECRET = 0x0020
ML_DONTDRAW = 0x0080       # am_map.c LINE_NEVERSEE: never on the automap
ML_MAPPED = 0x0100         # ... and "the player has seen it" (r_segs.c:398)

NO_SIDEDEF = 0xFFFF        # -1 as unsigned: "no side" (one-sided line)
NF_SUBSECTOR = 0x8000      # node child bit: child is a subsector (leaf)


@dataclass
class Vertex:
    x: int
    y: int


@dataclass
class Linedef:
    v1: int
    v2: int
    flags: int
    special: int
    tag: int
    right: int            # front sidedef index (0xFFFF = none)
    left: int             # back sidedef index (0xFFFF = none)

    @property
    def two_sided(self):
        return self.left != NO_SIDEDEF and (self.flags & ML_TWOSIDED)


@dataclass
class Sidedef:
    xoff: int
    yoff: int
    upper: str
    lower: str
    middle: str
    sector: int


@dataclass
class Sector:
    floor_h: int
    ceil_h: int
    floor_flat: str
    ceil_flat: str
    light: int
    special: int
    tag: int


@dataclass
class Thing:
    x: int
    y: int
    angle: int
    type: int
    flags: int


@dataclass
class Seg:
    v1: int
    v2: int
    angle: int
    linedef: int
    side: int             # 0 = front/right, 1 = back/left
    offset: int


@dataclass
class Subsector:
    count: int
    first: int


@dataclass
class Node:
    x: int                # partition line start
    y: int
    dx: int               # partition line delta
    dy: int
    # bbox[child] = (top, bottom, left, right)
    bbox: tuple
    child: tuple          # (right_child, left_child), high bit = subsector leaf


def _stair_sectors(lines, sides, sectors):
    """Every sector EV_BuildStairs (p_floor.c:453) can reach from a STAIRS line.

    The walk is DOOM's own, and it has to be run BEFORE the sector merge that
    calls it, on the raw rows: the chain leaves the tagged sector and follows
    two-sided lines whose FRONT side is the sector it is standing on and whose
    back sector's floor flat still matches the FIRST sector's -- picking up
    untagged, identical neighbours that then rise to different heights. Those
    are precisely the rows the merge must not fold together.

    Faithful down to the quirks: `texture` is captured once and never updated,
    and a sector already in the chain still costs a step (DOOM bumps `height`
    before the specialdata test). Heights are not returned -- pack_things'
    _build_stairs computes those; this only answers WHICH sectors are involved.
    """
    lines_of = {}
    for li, ld in enumerate(lines):
        for sd in (ld.right, ld.left):
            if sd != NO_SIDEDEF:
                lines_of.setdefault(sides[sd].sector, []).append(li)
    out = set()
    for tag in {ld.tag for ld in lines if ld.special in doomspecs.STAIRS}:
        moving = set()
        for start, s in enumerate(sectors):
            if s.tag != tag or start in moving:
                continue
            sec = start
            moving.add(sec)
            out.add(sec)
            texture, ok = sectors[sec].floor_flat, True
            while ok:
                ok = False
                for li in lines_of[sec]:
                    ld = lines[li]
                    if not (ld.flags & ML_TWOSIDED):
                        continue
                    if NO_SIDEDEF in (ld.right, ld.left):
                        continue
                    if sides[ld.right].sector != sec:        # frontsector == sec
                        continue
                    nxt = sides[ld.left].sector
                    if sectors[nxt].floor_flat != texture:
                        continue
                    if nxt in moving:
                        continue
                    sec = nxt
                    moving.add(sec)
                    out.add(sec)
                    ok = True
                    break
    return out


def _name(raw: bytes) -> str:
    return raw.split(b'\x00', 1)[0].decode('ascii', 'replace').upper()


class Wad:
    def __init__(self, path=DEFAULT_WAD, pwads=None):
        """path = the IWAD; pwads = PWADs layered over it (last one wins).

        The overlay is DOOM's own -file rule: a PWAD's lumps are appended and
        looked up first, so GALAXIA.WAD's E1M1 replaces the IWAD's while every
        texture, sprite and sound still comes out of the IWAD -- which is what
        a map WAD expects, since it ships none of those."""
        self.path = path
        self.lumps = []                       # [(name, offset, size)]
        self._index = {}                      # name -> lump index (last wins)
        self.sources = []                     # the files, in load order
        self._src = []                        # lump index -> index into sources
        self._load(path, first=True)
        for p in (DEFAULT_PWADS if pwads is None else pwads):
            self._load(p, first=False)

    def _load(self, path, first):
        with open(path, 'rb') as f:
            raw = f.read()
        wad_id = raw[0:4].decode('ascii', 'replace')
        if wad_id not in ('IWAD', 'PWAD'):
            raise ValueError(f'{os.path.basename(path)}: not a WAD ({wad_id!r})')
        if first:
            self.data = raw
            base = 0
        else:
            base = len(self.data)             # rebase the appended directory
            self.data += raw
        self.sources.append(path)
        src = len(self.sources) - 1
        num_lumps, dir_off = struct.unpack_from('<ii', raw, 4)
        for i in range(num_lumps):
            off = dir_off + i * 16
            lo, ls = struct.unpack_from('<ii', raw, off)
            nm = _name(raw[off + 8:off + 16])
            self.lumps.append((nm, lo + base, ls))
            self._src.append(src)
            if first:
                self._index.setdefault(nm, len(self.lumps) - 1)
            else:
                self._index[nm] = len(self.lumps) - 1

    # ---- WHICH FILE a lump came from -------------------------------------
    # Needed because a lump's PALETTE is a property of the file it shipped in,
    # not of the merged view: layer a WAD with its own PLAYPAL (heretic.wad,
    # hexen.wad, a total conversion) over DOOM and its texture indices mean
    # something else than the IWAD's do. wadtex.py remaps them; this is how it
    # knows which ones. (2026-08-16)
    def lump_source(self, name):
        """Index into self.sources for the lump the merged view resolves
        `name` to -- None when there is no such lump."""
        i = self._index.get(name.upper())
        return None if i is None else self._src[i]

    def source_lump(self, src, name):
        """`name` AS SHIPPED BY source `src` (its last copy), not the merged
        view. None when that file does not have it."""
        up = name.upper()
        for i in range(len(self.lumps) - 1, -1, -1):
            if self._src[i] == src and self.lumps[i][0] == up:
                _nm, off, size = self.lumps[i]
                return self.data[off:off + size]
        return None

    def source_palette(self, src):
        """Source `src`'s OWN palette 0 (768 raw RGB bytes), or None."""
        d = self.source_lump(src, 'PLAYPAL')
        return d[:768] if d and len(d) >= 768 else None

    # ---- map discovery ----
    def map_names(self):
        """All map markers present (ExMy or MAPxx), in WAD order."""
        out = []
        for nm, _, _ in self.lumps:
            if (len(nm) == 4 and nm[0] == 'E' and nm[2] == 'M'
                    and nm[1].isdigit() and nm[3].isdigit()):
                out.append(nm)
            elif len(nm) == 5 and nm.startswith('MAP') and nm[3:].isdigit():
                out.append(nm)
        return out

    def map_format(self, mapname):
        """'doom' or 'hexen' -- WHICH STRUCT this map's lumps use.

        Hexen (and anything saved in Hexen format: ZDoom, Vavoom, Strife-style
        PWADs) carries a BEHAVIOR lump after BLOCKMAP, its linedefs are 16
        bytes -- flags, a script SPECIAL and five ACS arguments where DOOM has
        a tag -- and its things are 20. The readers below speak DOOM's 14/10
        only, and they do not fail on the wrong one: they read the fields at
        the wrong offsets and hand back a map made of noise. So ask first.
        BEHAVIOR is the marker id Software's own format never has; the linedef
        size is the cross-check for a map whose BEHAVIOR is empty."""
        idx = self._index.get(mapname.upper())
        if idx is None:
            raise KeyError(f'map {mapname} not in WAD')
        MAPDATA = {'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS',
                   'SSECTORS', 'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP',
                   'BEHAVIOR', 'SCRIPTS'}
        ld = None
        for i in range(idx + 1, len(self.lumps)):
            nm, _lo, ls = self.lumps[i]
            if nm not in MAPDATA:
                break
            if nm == 'BEHAVIOR':
                return 'hexen'
            if nm == 'LINEDEFS':
                ld = ls
        if ld and ld % 16 == 0 and ld % 14 != 0:
            return 'hexen'
        return 'doom'

    def _map_lumps(self, mapname):
        idx = self._index.get(mapname.upper())
        if idx is None:
            raise KeyError(f'map {mapname} not in WAD')
        result = {}
        MAPDATA = {'THINGS', 'LINEDEFS', 'SIDEDEFS', 'VERTEXES', 'SEGS',
                   'SSECTORS', 'NODES', 'SECTORS', 'REJECT', 'BLOCKMAP'}
        for i in range(idx + 1, len(self.lumps)):
            nm, lo, ls = self.lumps[i]
            if nm not in MAPDATA:
                break
            result[nm] = (lo, ls)
        return result

    def _records(self, lumps, name, size, fmt):
        if name not in lumps:
            return []
        off, total = lumps[name]
        return [struct.unpack_from(fmt, self.data, off + i * size)
                for i in range(total // size)]

    # ---- typed map loader ----
    def load_map(self, mapname):
        L = self._map_lumps(mapname)
        hexen = self.map_format(mapname) == 'hexen'
        verts = [Vertex(x, y) for (x, y) in self._records(L, 'VERTEXES', 4, '<hh')]
        if hexen:
            # A Hexen linedef is 16 bytes: the same v1/v2/flags, then a SCRIPT
            # special with five byte arguments where DOOM has a u16 special and
            # a u16 tag. arg0 is the tag for every action that takes one (a 0
            # tag still means "the sector behind this line", as in DOOM), and
            # the trigger class -- W1/WR/S1/SR -- comes out of the flags' SPAC
            # bits. doomspecs.hexen_to_doom does that translation; the rest of
            # this module, and every packer downstream, then sees an ordinary
            # DOOM map. What the args carried (speed, delay, height, lock) is
            # gone: no DOOM special number can hold it.
            lines, dropped = [], {}
            for r in self._records(L, 'LINEDEFS', 16, '<HHHBBBBBBHH'):
                v1, v2, flags, sp, a0 = r[0], r[1], r[2], r[3], r[4]
                doom_sp = doomspecs.hexen_to_doom(sp, flags)
                if sp and not doom_sp:            # ACS_Execute and friends: no
                    dropped[sp] = dropped.get(sp, 0) + 1     # DOOM equivalent
                lines.append(Linedef(v1, v2, flags, doom_sp, a0, r[9], r[10]))
        else:
            lines, dropped = [Linedef(*r) for r in
                              self._records(L, 'LINEDEFS', 14, '<7H')], {}
        # SUBSTITUTE the door triggers this port does not implement (see
        # doomspecs.nearest_supported). It happens HERE because every packer
        # and every report reads its map through load_map, so they cannot
        # disagree about what the map says. Nothing else is touched: a special
        # the port already implements, and anything that is not a door, comes
        # through exactly as the WAD wrote it -- across all nine DOOM 1 maps
        # this changes zero linedefs.
        remapped = {}
        for ld in lines:
            if not ld.special:
                continue
            sub = doomspecs.nearest_supported(ld.special)
            if sub is not None and sub != ld.special:
                remapped[(ld.special, sub)] = remapped.get((ld.special, sub), 0) + 1
                ld.special = sub
        sides = []
        if 'SIDEDEFS' in L:
            off, total = L['SIDEDEFS']
            for i in range(total // 30):
                xo, yo = struct.unpack_from('<hh', self.data, off + i * 30)
                up = _name(self.data[off + i*30 + 4:off + i*30 + 12])
                lo_ = _name(self.data[off + i*30 + 12:off + i*30 + 20])
                mid = _name(self.data[off + i*30 + 20:off + i*30 + 28])
                sec, = struct.unpack_from('<H', self.data, off + i*30 + 28)
                sides.append(Sidedef(xo, yo, up, lo_, mid, sec))
        sectors = []
        if 'SECTORS' in L:
            off, total = L['SECTORS']
            for i in range(total // 26):
                fh, ch = struct.unpack_from('<hh', self.data, off + i*26)
                ff = _name(self.data[off + i*26 + 4:off + i*26 + 12])
                cf = _name(self.data[off + i*26 + 12:off + i*26 + 20])
                light, special, tag = struct.unpack_from('<hhh', self.data, off + i*26 + 20)
                if hexen:
                    # Hexen's SECTOR specials are a different set entirely
                    # (phased lighting, wind, the lava/ice damage types) and
                    # they collide with DOOM's numbers -- read as DOOM's they
                    # would flicker lights and hurt the player at random. The
                    # port models DOOM's, so a Hexen map simply has none.
                    special = 0
                sectors.append(Sector(fh, ch, ff, cf, light, special, tag))
        if hexen:
            # 20 bytes: tid, x, y, STARTING HEIGHT, angle, type, flags, and the
            # thing's own script special + args. The port takes what a DOOM
            # thing has; the height is dropped (it places a thing on its
            # sector's floor, or under the ceiling when the type hangs), and
            # the flags are masked to the four bits that mean the same in both
            # games -- skill 1/2/4 and ambush 8. Bit 4 is MTF_DORMANT in Hexen
            # and MTF_NOTSINGLE in DOOM, so passing it through would delete
            # every dormant monster from the map.
            things = [Thing(r[1], r[2], r[4], r[5], r[6] & 0x0F)
                      for r in self._records(L, 'THINGS', 20, '<HhhhHHHBBBBBB')]
        else:
            things = [Thing(*r) for r in self._records(L, 'THINGS', 10, '<5h')]
        segs = [Seg(*r) for r in self._records(L, 'SEGS', 12, '<6H')]
        ssectors = [Subsector(c, f) for (c, f) in self._records(L, 'SSECTORS', 4, '<HH')]
        nodes = []
        for r in self._records(L, 'NODES', 28, '<12h2H'):
            x, y, dx, dy = r[0:4]
            rbb = r[4:8]    # right: top,bottom,left,right
            lbb = r[8:12]   # left
            nodes.append(Node(x, y, dx, dy, (rbb, lbb), (r[12], r[13])))
        # ---- SECTOR MERGE (2026-08-18, first E2/E3 maps): the packed seg
        # record holds front/back sector in a BYTE ($FF = none), capping a map
        # at 254 sectors -- E2M7 has 323, E3M5 268 -- and the LOW region's
        # $C00 budget caps the shared SECTORS section at 248 rows once the
        # 27-map textab (63) + ybits (2438 segs) + yoff caps are in, so 248
        # is the working limit (E1M6's 250 merges by 2). IDENTICAL in every
        # field the port reads (heights, flats, light, special, tag) are the
        # same sector to every consumer downstream, so they merge and the
        # sidedefs remap. Done HERE, like the special substitution above:
        # every packer reads its map through load_map, so pack_map's sector
        # ids and pack_things' trigger targets cannot drift apart.
        # Special 9 (secret) never merges -- each is one secret in the tally.
        # If identical rows are not enough, LIGHT quantises (16, then 32) on
        # plain sectors (special 0, tag 0) until the map fits.
        if True:                          # identical-merge ALWAYS (2026-08-18:
            # E2M2's mincer is 12 alternating sectors x 3 walk lines = 36
            # trigger records that blew the $C000 things blob -- identical
            # rows fold to 2 sectors and 6 records, and the pass is lossless
            # by construction). The light-quantising passes still gate on the
            # 248-row LOW budget.
            orig = len(sectors)
            # NEVER merge a manual door's sector: it is tag-0 and named by its
            # BACK side alone (EV_VerticalDoor), so folding two identical
            # closed doors into one row would open BOTH when either is used.
            # Tagged movers are safe -- same tag means same action by
            # definition; secret 9 likewise stays unique for the tally.
            no_merge = {sides[ld.left].sector for ld in lines
                        if ld.special in doomspecs.MANUAL_DOOR
                        and ld.left != NO_SIDEDEF}
            # ...and NEVER merge a STAIRCASE (2026-08-18). "Same tag means same
            # action" is true of every floor special but one: EV_BuildStairs
            # tags only the BOTTOM step and then walks on through UNTAGGED
            # neighbours that match its floor flat -- so a flight is N sectors
            # that are identical in every field this key looks at, and each one
            # has to end up at a DIFFERENT height. Folding them collapsed the
            # flight: E1M8's five steps became three rows (two of which it
            # shares with the map's other STEP2 flights), the staircase to the
            # teleporter stopped two steps short, and the gap read as a wall you
            # could not get past. Nine steps across E1-E3 (E1M8 2, E2M4 4,
            # E2M5 1, E2M8 2).
            no_merge |= _stair_sectors(lines, sides, sectors)
            newsec, remap = sectors, {}
            for quant in (1, 16, 32):
                if quant > 1 and len(newsec) <= 248:
                    break
                key_of, remap, newsec = {}, {}, []
                for i, s in enumerate(sectors):
                    lt = s.light if (quant == 1 or s.special or s.tag) \
                        else (s.light // quant) * quant
                    k = (('one', i) if (s.special == 9 or i in no_merge) else
                         (s.floor_h, s.ceil_h, s.floor_flat, s.ceil_flat,
                          lt, s.special, s.tag))
                    j = key_of.get(k)
                    if j is None:
                        j = key_of[k] = len(newsec)
                        newsec.append(s if lt == s.light else
                                      Sector(s.floor_h, s.ceil_h, s.floor_flat,
                                             s.ceil_flat, lt, s.special, s.tag))
                    remap[i] = j
                if len(newsec) <= 248:
                    break
            tail = '' if len(newsec) <= 248 else ' -- STILL over 248'
            if len(newsec) != orig or tail:
                print(f'  {mapname}: sector merge {orig} -> {len(newsec)}{tail}')
            sectors = newsec
            for sd in sides:
                sd.sector = remap[sd.sector]
        # ---- The DOOR WELD is gone (2026-08-18, same day it went in). It capped
        # a map at 32 working doors and shipped the excess permanently open,
        # because the twelve runtime [N] arrays ended exactly at READKEYS
        # ($F180) and DOORS_NMAX could not grow. The arrays live in Rapidus bank
        # $01 at DOOR_EXT now (memory_map.inc) and DOORS_NMAX is 48, which
        # covers every map in episodes 1-3 -- E3M5, the fullest, has 43. A set
        # that still would not fit now FAILS the build (the MAP_NDOORS assert in
        # doors.asm, and wadconv.py's own check) instead of quietly welding.
        md = MapData(mapname.upper(), verts, lines, sides, sectors,
                     things, segs, ssectors, nodes, remapped, hexen, dropped)
        return md


@dataclass
class MapData:
    name: str
    vertices: list
    linedefs: list
    sidedefs: list
    sectors: list
    things: list
    segs: list
    ssectors: list
    nodes: list
    # {(from, to): count} -- the door triggers load_map substituted, so a
    # report can say what it did instead of the reader wondering why the map
    # on the disk is not quite the map in the WAD.
    remapped: dict = field(default_factory=dict)
    # HEXEN-format maps only (map_format): the map was read with the Hexen
    # structs and its specials translated (doomspecs.HEXEN_LINE), and `dropped`
    # is {hexen special: count} for the ones no DOOM special can express --
    # ACS_Execute above all, i.e. the scripted half of the level.
    hexen: bool = False
    dropped: dict = field(default_factory=dict)

    def bounds(self):
        xs = [v.x for v in self.vertices]
        ys = [v.y for v in self.vertices]
        return min(xs), min(ys), max(xs), max(ys)

    def stats(self):
        one = sum(1 for ld in self.linedefs if not ld.two_sided)
        two = len(self.linedefs) - one
        return (f'{self.name}: {len(self.vertices)} verts, '
                f'{len(self.linedefs)} lines ({one} solid / {two} two-sided), '
                f'{len(self.sectors)} sectors, {len(self.things)} things, '
                f'{len(self.segs)} segs, {len(self.ssectors)} ssectors, '
                f'{len(self.nodes)} nodes')


if __name__ == '__main__':
    import sys
    w = Wad(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WAD)
    print(f'WAD: {w.path}  ({len(w.lumps)} lumps)')
    print('Maps:', ', '.join(w.map_names()))
    for mn in w.map_names():
        print('  ' + w.load_map(mn).stats())
