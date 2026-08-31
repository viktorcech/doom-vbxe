#!/usr/bin/env python3
"""Pack a WAD map's geometry + prebuilt BSP into a compact, 6502-friendly blob.

Format v2 (TEXTURED walls, 2026-07-22) -- MEMORY-FITTING variant. The full v2
(256-colour palette + wide seg records IN the .bin) overflowed the Atari map
window ($4000..$8600); this keeps the .bin the SAME size/layout as v1 so it still
fits, and moves the texture metadata OUT of the .bin:

  * .bin (this file): geometry only, NO palette section (n_base=0). Sectors carry
    a PLAYPAL index for floor/ceiling (representative flat colour). Segs REUSE the
    v1 col_a/col_b bytes as wall_tex / low_tex texture ids (bit7 of col_a still =
    ML_BLOCKING impassable). Record sizes are UNCHANGED from v1 (sectors 8B, segs
    10B), so map_syms.inc offsets + the renderer's seg indexing (*10) are unchanged.
  * {map}.tex : column-major texture pixels -> VBXE VRAM $020000 (streamed).
  * {map}_textab.inc : MADS arrays (texid -> VRAM addr / width mask / height /
    dominant colour) the engine `icl`s. Small; lives in engine RAM, not the .bin.
  * playpal.bin : the real 256-colour DOOM palette (engine installs it into VBXE).

Trade-off vs the wide format: no per-seg texture u-offset (seg.offset) is stored,
so a wall split into several BSP segs restarts its texture at each seg boundary
(minor seams). Proper u alignment needs the wide seg record + more map RAM (a
Rapidus-RAM rework), deferred.

Format v3 (2026-07-25) -- MULTI-LEVEL. Three changes, all needed before a second
level can exist at all:

  1. RECORDS COMPACTED, nothing dropped. seg 10 -> 8 B (front/back sector were
     u16 for a table that never exceeds 254 entries) and node 28 -> 12 B (the two
     child BBOXes are read by R_CheckBBox alone, and that cull is off). Same
     vertices, same segs, same BSP -- E1M2 just goes 34.3 KB -> 24.6 KB, which is
     what makes it loadable at all.
  2. FOUR REGIONS. Even compacted, a level does not fit the $4000..$85FF slot, so
     the blob is split: the LOW part loads at $4000 as before, the HIGH part into
     the 10 KB of RAM under the OS ROM at $D800 (underrom.asm already installs
     RAM interrupt vectors, so the engine can simply keep the ROM banked out for
     the whole frame), and the two biggest arrays go to Rapidus SRAM banks --
     verts/nodes/segoff to bank $01, the seg records to bank $03. What is left in
     base RAM is only what is read with plain absolute addressing.
  3. FIXED CAPACITIES + a runtime HEADER. Every section is padded to the largest
     level in the build, so MAP_VERTS/MAP_SEGS/... are the same addresses for
     every level (wolf3d does the same). What DOES vary per level -- counts, root
     node, spawn point, door/yoff/texture counts -- now comes from the header at
     runtime instead of being an assembly-time equ baked from E1M1.
  The texture TABLE moved into the blob too (it used to be an icl'd .inc, i.e.
  one level's table hard-wired into the XEX).

Binary layout (little-endian). c* = the build's capacity for that section.
  --- LOW region, loaded at $4000 ---
  HEADER (32B)  u16 n_verts,n_sectors,n_segs,n_ssectors,n_nodes, u16 root,
                i16 start_x,start_y, u8 start_ang(BAM), u8 n_doors,
                i16 start_eye, u16 n_yoff, u8 n_tex, u8 next_level,
                u16 fmt_ver(=3), u8 scroll_tex($FF=none), 5B reserved
  --- SEG region, streamed to Rapidus bank $03 offset 0 (2026-07-31) ---
  SEGS      cg  x (u16 v1,v2, u8 front_sec, u8 back_sec($FF=one-sided),
                   u8 wall_tex, u8 low_tex)                              [8B]
                         wall_tex: bit7=impassable, bit6=ML_DONTPEGTOP,
                                   bits0-5=texid (0x3F=none)
                         low_tex : bit7=EXIT line, bit6=ML_DONTPEGBOTTOM,
                                   bits0-5=portal-lower texid (0x3F=none)
                         The two peg bits are DOOM's per-linedef texture
                         anchoring (r_segs.c R_StoreWallRange): without
                         ML_DONTPEGTOP an upper texture hangs from the BACK
                         ceiling, which is what makes a door face slide up with
                         the door; ML_DONTPEGBOTTOM anchors a one-sided wall
                         (door tracks!) and a portal lower to the floor.
  --- back in the LOW region ---
  SECTORS   cs  x (i16 floor_h, ceil_h, u8 light, u8 floor_pal, u8 ceil_pal,
                   u8 flags)   flags bit0=sky; floor_pal/ceil_pal = PLAYPAL idx
  TEXTAB    ctex x 7 PARALLEL arrays (addr_lo, addr_mid, addr_hi, wmask, h, dom,
                                      swmate)
  YOFF      u8 bitmap[(cg+7)/8], u8 idx_lo[cy], idx_hi[cy], u8 yoff[cy]
                       sidedef->rowoffset per seg (r_segs.c adds it to every
                       texturemid). A byte per seg does not fit the map slot, so
                       only the segs that need one are listed: the bitmap answers
                       "does this seg have a yoff" in ~15 cycles, the sorted side
                       table (ascending seg index) carries the value.
  --- HIGH region, loaded at $D800 (RAM under the OS ROM) ---
  SSECTORS  css x (u16 first_seg, u16 count)
  DOORS     cd x (u8 sector, u8 deny_sector, i16 open_ceil, i16 org_x, i16 org_y);
            the count lives in the header (+ a parallel cd x u8 LOCK array:
            bits0-2 = key bit (PS_KEYS: blue=1 yellow=2 red=4), bit7 = D1
            opens-once-stays-open).
                         deny_sector: the sector a USE press is REFUSED from
                         ($FF = none) -- p_switch.c opens a manual door from the
                         FRONT sector of the line carrying the special only, and
                         the engine has no linedef specials to tell the door's
                         two faces apart (DOOR_DENY, memory_map.inc). It rides in
                         the byte the sector id's high half used to waste: every
                         episode-1 map is under 250 sectors.
  --- EXT region, streamed to Rapidus bank $01 offset 0 ---
  VERTS     cv  x (i16 x, i16 y)
  NODES     cn  x (i16 x,y,dx,dy, u16 child_r,child_l, then the two child
                   bboxes: 4 x i16 each)                                 [28B]
  SEGOFF    cg  x u16   DOOM's seg->offset (how far along the linedef it starts)
  LIGHTS    cli x (u8 sector, u8 kind, u8 minlight, u8 maxlight, u8 darkvbl,
                   u8 count) the sectors P_SpawnSpecials gives a light thinker
                       (p_lights.c); see _lights() and lights.asm. `count` (and
                       bit6 of `kind`) are the thinker's RUNTIME state -- the
                       EXT bank is RAM and a level load re-streams it, so the
                       state resets itself and costs no base RAM.

All four regions are padded to whole 128-byte sectors and the .bin is
LOW + HIGH + EXT + SEG, which is the order load_level reads them in: LOW straight
to $4000, HIGH staged under the ROM, EXT and SEG staged into their Rapidus banks.
map_syms.inc is emitted from HERE (the capacities live here), not derived from a
.bin by bin_syms.py.

Usage: python pack_map.py [E1M1 ...] | --all
"""
import collections
import math
import os
import re
import struct
import sys

import doomspecs
from wadlib import (Wad, DEFAULT_WAD, NO_SIDEDEF, ML_TWOSIDED, ML_BLOCKING,
                    ML_DONTPEGTOP, ML_DONTPEGBOTTOM, ML_SECRET, ML_DONTDRAW)
from wadtex import WadTextures
from pack_textures import (pack_map_textures, write_playpal, NONE_ID, HALF_W,
                           TexPool, _moving_sectors)

_HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'wadmaps')
TEX_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures')
SYMS_OUT = os.path.join(os.path.dirname(_HERE), 'map_syms.inc')
EYE = 41                             # DOOM view height above the floor
# Exit lines: S1/W1 Exit Level and Exit Secret. The .bin has no linedef table, so
# the flag rides on the seg record; try_use looks for it along the USE ray.
EXIT_SPECIALS = doomspecs.EXIT
SECRET_EXITS = {51, 124}              # S1/W1 SECRET exit (g_game.c
                                     # G_SecretExitLevel). The seg has no spare
                                     # bit, so _secret_sector keys them on
                                     # SEG_FRONT instead.

NO_TEX = 0x3F                        # seg texid sentinel; bit6 = peg flag, bit7 = the
                                     # per-slot flag (impassable / EXIT line)
NO_SECTOR = 0xFF                     # seg back_sec: one-sided wall

# ---- the automap's side tables (bank $03; see _automap) ---------------------
AM_SLOT      = 2                     # bytes per linedef in AMSEEN and in AMFLG.
                                     # TWO, not one, and that is what buys the
                                     # ML_MAPPED hook its size: am_mark stores a
                                     # 16-bit A with no sep/rep dance around it,
                                     # and AMFLG at the SAME stride means the
                                     # automap reads a line's flags with the very
                                     # same X (one lda.l at a constant delta).
                                     # Costs 2.6 KB a level in a bank with 40 KB
                                     # free, against 3 bytes of engine code that
                                     # has nowhere to live. That is the trade.
AMF_SECRET   = 0x01                  # amflg: ML_SECRET   -> draw as a solid wall
AMF_DONTDRAW = 0x02                  #        ML_DONTDRAW -> never draw
AMF_TELEPORT = 0x04                  #        special 39  -> WALLCOLORS+RANGE/2
                                     #        (0 lines in episode 1; the bit is
                                     #         emitted so the rule is not a lie)

HDR_SIZE = 32
SEG_SIZE = 8
SECT_SIZE = 8
LIGHT_SIZE = 6                       # sector, kind, min, max, dark, count --
                                     # the last two are VBLANKs and the count is
                                     # RUNTIME state: bank $01 is RAM and every
                                     # level load re-streams it, so the thinkers
                                     # need no base RAM of their own (lights.asm)
TICRATE = 35                         # DOOM tics/s; the port counts PAL VBLANKs
VBLANKS = 50                         #   (see DOOR_SPEED_Q8 -- same conversion)
SSECT_SIZE = 4
NODE_SIZE = 28      # 12 B of partition+children, then the two child bboxes
TEXTAB_ROWS = 9                      # addr lo/mid/hi, wmask, h, dom, swmate,
                                     #   + column-index offset lo/hi (2026-08-14:
                                     #   the pool made the blob shared, so the
                                     #   per-level index offsets moved here)
SECTOR = 128

MAP_LOAD = 0x4000                    # LOW region: the engine's map slot
MAP_LOAD_HI = 0xD800                 # HIGH region: RAM under the OS ROM
MAP_EXT_BANK = 0x01                  # EXT region: Rapidus SRAM bank (VERTS+NODES)
MAP_SEG_BANK = 0x03                  # SEG region: its OWN Rapidus SRAM bank
LOW_LIMIT = 0x4C00                   # first byte the LOW region may NOT touch.
                                     # 2026-07-31: was $8600. The seg table left
                                     # for bank $03 and LOW is header + sectors +
                                     # textab + yoffs = ~2.7 KB, so the map slot
                                     # shrank to $4000-$4BFF and $4C00-$85FF is
                                     # ordinary free RAM. tools/ram_map.py
                                     # RESERVED must match this constant.
HI_LIMIT = 0xDA00                    # 2026-08-29: was $E300 (USERAY_BASE). The
                                     # THINGS blob's second piece lives at
                                     # $DA00-$E2FF now (memory_map.inc
                                     # THINGS2_BASE) -- the crusher trigger
                                     # records did not fit the 31 sectors at
                                     # $C000 on E2M2/E2M4/E3M5, and the 2.3 KB
                                     # this region has never used since SSECTORS
                                     # left for the EXT bank was the only base
                                     # RAM in the machine that was free AND
                                     # needs no long addressing. HIGH itself is
                                     # 396 B (44 doors) of the 512 that leaves.
                                     # tools/ram_map.py RESERVED must match.
EXT_LIMIT = 0x6000                   # DOOR_EXT (memory_map.inc): the streamed map
                                     # shares bank $01 with the AI tables, and
                                     # THAT is the real ceiling, not the bank end.
                                     # 2026-08-18: was $6400 = TH_HPL. The door
                                     # runtime arrays took the kilobyte below it
                                     # (the only free space left in the machine)
                                     # so 32-door maps stopped needing the weld;
                                     # this ceiling drops with them. The whole
                                     # 27-map set ends at $393C, so there is
                                     # still ~10 KB of map growth under it.
                                     # 2026-08-15: it said LOS_EXT ($6A00), but
                                     # the six pages BELOW that -- TH_HPL/TH_HPH/
                                     # TH_CELL/TH_BNEXT/TH_STATE/TH_TICS -- are
                                     # AI tables too, and the FIRST of them is
                                     # where the map has to stop. LIGHTS crossed
                                     # it on E1M2 (26 thinkers, $6394+156=$6430)
                                     # and en_init wiped the last eight records,
                                     # so the secret-door strobe by the E1M2
                                     # staircase never blinked. LIGHTS lives in
                                     # the SEG bank now; this constant is what
                                     # keeps the rest of the map out of the AI.
SEG_LIMIT = 0x10000                  # ... and the seg bank holds ONLY the segs

def _seg_xoff(md, sg):
    """sidedef->textureoffset of the side this seg shows (r_segs.c rw_offset)."""
    ld = md.linedefs[sg.linedef]
    si = ld.right if sg.side == 0 else ld.left
    if si in (-1, 0xFFFF):
        return 0
    return md.sidedefs[si].xoff


MTX_ROWS = 5                         # texid, top lo/hi, bot lo/hi


def _next_level(names, i, md):
    """The header's next_level, g_game.c G_DoCompleted's graph instead of the
    old (i+1) mod n chain (2026-08-18, the first E2 map):
      * M8 ends the episode -> the NEXT episode's M1 if it is in the build,
        else level 0. (Vanilla goes ga_victory -> F_StartFinale here; the
        port's finale SCREEN is still an open feature -- pack_fin assets and
        fin_syms.inc exist, no engine hook yet -- so the exit goes straight
        to the next episode.)
      * M9 returns where the secret exit left off: E1->E1M4, E2->E2M6,
        E3->E3M7 (wminfo.next 3/5/6).
      * Everything else -> M+1. A SECRET EXIT (51/124) is NOT this byte's
        business any more: it has its own header target (_secret_level), and
        the seg carries which exit it is (bit6 of low_tex). Until 2026-08-27
        a map with a secret exit sent BOTH exits to M9 -- one next_level per
        map -- so finishing E1M3 the normal way landed in E1M9, not E1M4.
    Falls back to (i+1) mod n for names outside the ExMy scheme (wadconv)."""
    nm = names[i]
    linear = (i + 1) % len(names)
    m = re.fullmatch(r'E(\d)M(\d)', nm)
    if not m:
        return linear
    e, mp = int(m.group(1)), int(m.group(2))

    def ix(want):
        return names.index(want) if want in names else None

    if mp == 8:
        nxt = ix(f'E{e + 1}M1')
        return nxt if nxt is not None else 0
    if mp == 9:
        nxt = ix({1: 'E1M4', 2: 'E2M6', 3: 'E3M7'}.get(e, ''))
        return nxt if nxt is not None else linear
    nxt = ix(f'E{e}M{mp + 1}')
    return nxt if nxt is not None else linear


def _secret_sector(md):
    """The sector key use_leaf tells the two exits apart by: the LOW front
    sector of this map's secret-exit segs ($FF = the map has none).

    The seg record has no bit left for it -- low_tex bit7 is already EXIT and
    bit6 is real DONTPEGBOTTOM (E3M4's ld1039 is a two-sided exit with a lower
    step that needs it), so the "which exit" answer has to come from a field
    the seg already carries. SEG_FRONT is a byte and it is exact here: no
    secret exit shares a front sector with a normal one in DOOM1 E1-E3.

    A two-sided secret exit has segs on BOTH sides, so the key covers
    {lo, lo+1} -- E3M6's ld662 is sectors 64/65. Both halves are asserted, so a
    WAD that does not fit fails the build instead of picking the wrong exit."""
    lo_hi, normal = set(), set()
    for sg in md.segs:
        ld = md.linedefs[sg.linedef]
        if ld.special not in EXIT_SPECIALS:
            continue
        fsd = ld.right if sg.side == 0 else ld.left
        if fsd == NO_SIDEDEF:
            continue
        (lo_hi if ld.special in SECRET_EXITS else normal).add(
            md.sidedefs[fsd].sector)
    if not lo_hi:
        return 0xFF
    lo = min(lo_hi)
    assert lo_hi <= {lo, lo + 1}, (
        f'{md.name}: secret-exit front sectors {sorted(lo_hi)} do not fit the '
        f'2-sector key at {lo} -- widen MAP_HSECS')
    assert not (normal & {lo, lo + 1}), (
        f'{md.name}: a NORMAL exit shares the secret key sectors '
        f'{sorted(normal & {lo, lo + 1})} -- SEG_FRONT cannot tell them apart')
    assert lo + 1 < NO_SECTOR, f'{md.name}: secret key {lo} collides with $FF'
    return lo


def _secret_level(names, i, md):
    """The header's SECOND exit target: where the SECRET exit goes
    (g_game.c G_SecretExitLevel -> ExM9). Falls back to the normal next level
    for a map that has no secret exit, so the engine may take this byte
    unconditionally when it sees a secret-exit seg."""
    nm = names[i]
    m = re.fullmatch(r'E(\d)M(\d)', nm)
    if m and any(ld.special in SECRET_EXITS for ld in md.linedefs):
        e = int(m.group(1))
        if f'E{e}M9' in names:
            return names.index(f'E{e}M9')
    return _next_level(names, i, md)


def _seg_layout(caps):
    """The SEG bank's ($03) section offsets -- ONE definition, so pack() and
    emit_map_syms() cannot drift apart. MAP_SEGS is $0100 and not 0 on purpose:
    see the note by `segs =` in emit_map_syms.
    -> (segs, amseg, amskip, amseen, amflg, segmid, mtx, lights, end)"""
    segs = 0x0100
    amseg = segs + caps.segs * SEG_SIZE
    amskip = amseg + caps.segs * 2
    amseen = amskip + (caps.segs + 7) // 8
    amflg = amseen + caps.lines * AM_SLOT
    segmid = amflg + caps.lines * AM_SLOT
    mtx = segmid + caps.segs
    lights = mtx + MTX_ROWS * caps.mtx
    # NODES joined the SEG bank on 2026-08-18: 28 B x E2M7's 817 nodes is
    # 22.9 KB, which blew the EXT bank's $6400 ceiling (E2M2/E2M5/E2M7). The
    # walk reads them through [zp_nodeptr],y and init_level seeds that
    # pointer's bank byte, so the move costs one immediate; bank $03 sits at
    # ~35 KB of 64 even on E2M7 with them in.
    nodes = lights + caps.lights * LIGHT_SIZE
    return (segs, amseg, amskip, amseen, amflg, segmid, mtx, lights, nodes,
            nodes + caps.nodes * NODE_SIZE)


def _midtex(md, segmid_tex, table):
    """The MIDTEX rows: everything about a two-sided MIDDLE texture that does
    not depend on where the player is standing.

    r_segs.c R_StoreWallRange anchors a masked mid texture to the OPENING --
    ML_DONTPEGBOTTOM puts its bottom on the higher of the two floors, otherwise
    its top goes on the lower of the two ceilings -- and then the column drawer
    clips it to that same opening. Both ends of that are two sector heights and
    a texture height, i.e. constants, PROVIDED neither sector moves. Episode 1
    has no strut on a door or lift sector (asserted below), so the whole
    calculation is done here and the engine reads the answer: see midtex.asm,
    where doing it at run time cost ~180 bytes of a 628-byte budget.

    The PEG is not stored. Clipping the texture to the opening moves its top by
    exactly texH - (top - bot) when it stands on the floor, and by nothing when
    it hangs from the ceiling -- which is what process_seg's ONE-SIDED
    ML_DONTPEGBOTTOM rule already computes, and the masked pass takes that
    branch. See mid_planes.

    -> (segmid bytes: MIDTEX row per seg, $FF = none;  rows: [(tex, top, bot)])"""
    doors, plats = _moving_sectors(md)
    out = bytearray()
    rows, index = [], {}
    for i, sg in enumerate(md.segs):
        tex = segmid_tex[i]
        if tex == NONE_ID:
            out.append(0xFF)
            continue
        ld = md.linedefs[sg.linedef]
        fsd, bsd = (ld.right, ld.left) if sg.side == 0 else (ld.left, ld.right)
        fsec = md.sectors[md.sidedefs[fsd].sector]
        bsec = md.sectors[md.sidedefs[bsd].sector]
        if any(s in doors or s in plats for s in
               (md.sidedefs[fsd].sector, md.sidedefs[bsd].sector)):
            # E2/E3 (2026-08-18): a grating strut ON a door or lift sector.
            # Its span is precomputed here and would go stale the moment the
            # sector moves, so the TEXTURE IS DROPPED -- the opening stays,
            # the see-through strut just is not drawn. E1 has no such seg
            # (the old assert proved it); across E2/E3 it is a handful of
            # gratings on moving sectors, a cosmetic reduction.
            print(f'  {md.name}: midtex on MOVING sector dropped (seg {i})')
            out.append(0xFF)
            continue
        texh = table[tex][3]
        top = min(fsec.ceil_h, bsec.ceil_h)          # p_maputl.c's opening
        bot = max(fsec.floor_h, bsec.floor_h)
        if ld.flags & ML_DONTPEGBOTTOM:              # stands on the floor
            top = min(top, bot + texh)               # ... and is cut at the top
        else:                                        # hangs from the ceiling
            bot = max(bot, top - texh)               # ... and is cut at the foot
        if top <= bot:
            # an empty opening (E2/E3: closed or degenerate two-sided struts)
            # -- nothing is drawable, so no row at all (E1 never packed one:
            # the old assert held)
            out.append(0xFF)
            continue
        key = (tex, top, bot)
        r = index.get(key)
        if r is None:
            r = index[key] = len(rows)
            rows.append(key)
        assert r < 0xFF, 'MIDTEX rows overflow the u8 MAP_SEGMID index'
        out.append(r)
    return out, rows


def _automap(md, caps, amseen_base):
    """The automap's side tables (am_map.c AM_drawWalls).

    -> (amseg, amskip, amseen, amflg), in the order they sit in bank $03.

    AM_drawWalls is LINEDEF based and this port has no linedef table -- the
    automap draws SEGS, which tile the same geometry. Two things still have to
    come from the LINE, because per-seg answers would be wrong on screen:

      * ML_MAPPED. r_segs.c:398 sets it on the LINEDEF the moment any part of
        it is rendered, and AM_drawWalls then draws the WHOLE line. Marked per
        seg instead, peeking round a corner would light up one fifth of a long
        wall. So the "seen" bit is per line and every seg carries its line id.
      * ML_SECRET and ML_DONTDRAW. A secret door is two-sided but must draw as
        a solid WALL (that is the whole point -- it must not read as a door on
        the map), and a DONTDRAW line is never drawn at all. Episode 1 has 170
        and 152 of them, so neither branch is decorative.

    AMSEG does not hold a linedef INDEX -- it holds the bank-$03 ADDRESS of that
    line's AMSEEN slot. That is the whole reason the engine-side mark fits: with
    the 65816 already in native mode for the frame loop (underrom.asm), am_mark
    is `rep #$30 / lda rs_segi / asl / tax / lda.l AMSEG,x / tax / sta.l 0,x /
    sep #$30` -- 21 bytes, no address arithmetic at all, and the value it stores
    is the address it just read (any non-zero means seen). An index would have
    cost a shift, an add and a mask, i.e. a routine with nowhere to live.

    AMSKIP is a per-seg BIT: 1 = this seg is the BACK side of a two-sided line.
    Both sides get segs and both tile the line, so drawing both is the same
    pixels twice -- and the automap walks segs in order, so one bitmap byte
    serves eight segs. The back ones still MARK (a wall seen from behind IS
    seen -- and for half the two-sided lines you meet, the back side is the only
    one you ever face), they just do not draw. Verified over episode 1: every
    linedef has side-0 segs and they cover it to within 2 units on 6 lines of
    7475 -- far under one automap pixel.

    AMSEEN ships as ZEROS and rides in the streamed region on purpose: a level
    load re-streams the bank, so "nothing seen yet" resets itself and costs no
    base RAM -- the same trick the light thinkers' runtime state uses.
    """
    draw_side = {}
    for sg in md.segs:
        # side 0 if the line has any front seg, else whatever side it does have
        if draw_side.get(sg.linedef, 1) != 0:
            draw_side[sg.linedef] = sg.side
    missing = [i for i in range(len(md.linedefs)) if i not in draw_side]
    assert not missing, f'{len(missing)} linedefs have no seg -- {missing[:8]}'

    amseg = bytearray()
    amskip = bytearray((len(md.segs) + 7) // 8)
    for i, sg in enumerate(md.segs):
        slot = amseen_base + sg.linedef * AM_SLOT
        assert 0 < slot < 0x10000, f'AMSEEN slot ${slot:X} is not a bank offset'
        amseg += struct.pack('<H', slot)
        if sg.side != draw_side[sg.linedef]:
            amskip[i >> 3] |= 1 << (i & 7)

    amflg = bytearray()
    for ld in md.linedefs:
        f = 0
        if ld.flags & ML_SECRET:
            f |= AMF_SECRET
        if ld.flags & ML_DONTDRAW:
            f |= AMF_DONTDRAW
        if ld.special == 39:                      # W1 Teleport (am_map.c:1140)
            f |= AMF_TELEPORT
        amflg += bytes([f]) + bytes(AM_SLOT - 1)

    return (amseg, amskip, bytearray(caps.lines * AM_SLOT), amflg)



# ---- node bboxes must cover the subtree's THINGS, not just its segs ---------
# A node's WAD bbox bounds the SEGS below it. The port hangs things off the
# SUBSECTOR they stand in (pack_things.py, the per-subsector prefix table) and
# render_subsector is the only thing that ever offers them to spr_add -- so when
# R_CheckBBox throws a subtree away, its things go with it. Those two facts do
# not fit together: a thing standing in the open middle of a subsector is not
# inside that subsector's SEG box, so a subtree can be culled while a thing it
# owns sits dead centre of the screen.
#
# E1M7's barrel at (112,272) is the reported case: it belongs to subsector 145,
# whose box is x[-224,0] y[160,288] -- the west strip, 112 units away from the
# barrel. checkbbox.asm:135 ("all four corners outside the SAME plane") then
# culls it correctly for that box and the barrel vanishes; step back through the
# doorway and it returns. tools/tests/_dbg_e1m7_sprites.py drives the real XEX
# and shows both: subsector 145 offered to spr_add at eye y >= 364, culled at
# y <= 352. tools/tests/_dbg_e1m7_cullscan.py counts 21 things in E1M7 alone
# that disappear this way, and _dbg_e1m7_barrelview.py finds views where the
# barrel is in screen column 80 of 160 when it goes.
#
# DOOM cannot hit this at all: r_bsp.c hands R_AddSprites a SECTOR and
# r_things.c gates it on sec->validcount, so ANY surviving subsector of the
# sector brings every thing in it. Moving the port to that rule would break the
# clip-window snapshot spr_add takes (it is only exact when a thing is collected
# from ITS OWN subsector, in front-to-back order), so the fix goes the other
# way: make the cull honest about what the subtree contains. The bboxes are read
# by check_bbox and nothing else, so growing them can only weaken the cull --
# never change what is drawn, only what is skipped.
THING_MARGIN = 96       # world units around a thing's centre. Its sprite is
                        # drawn from that centre and can overhang it by half a
                        # sprite width; 96 clears every episode-1 sprite (the
                        # baron, the widest, is 60 texels) plus the 32-unit
                        # radius of the fattest obstacle.


def _thing_bbox_of_child(md):
    """child id (bit15 = subsector) -> (top, bottom, left, right) covering
    every thing in that subtree, or absent when the subtree holds none.
    Same skill filter as pack_things' map_things: skill 3, single player."""
    from pack_things import wad_subsector
    per_ss = {}
    for t in md.things:
        if not (t.flags & 2) or (t.flags & 16):
            continue
        ss = wad_subsector(md, t.x, t.y)
        b = per_ss.get(ss)
        if b is None:
            per_ss[ss] = [t.y, t.y, t.x, t.x]
        else:
            b[0] = max(b[0], t.y)
            b[1] = min(b[1], t.y)
            b[2] = min(b[2], t.x)
            b[3] = max(b[3], t.x)
    out = {}

    def walk(cid):
        if cid in out:
            return out[cid]
        if cid & 0x8000:
            b = per_ss.get(cid & 0x7FFF)
            r = None if b is None else (b[0] + THING_MARGIN,
                                        b[1] - THING_MARGIN,
                                        b[2] - THING_MARGIN,
                                        b[3] + THING_MARGIN)
        else:
            n = md.nodes[cid]
            a, c = walk(n.child[0]), walk(n.child[1])
            r = (a if c is None else c if a is None else
                 (max(a[0], c[0]), min(a[1], c[1]),
                  min(a[2], c[2]), max(a[3], c[3])))
        out[cid] = r
        return r

    for i in range(len(md.nodes)):
        walk(md.nodes[i].child[0])
        walk(md.nodes[i].child[1])
    return out


def _bbox_with_things(bb, tb):
    """(top, bottom, left, right), the WAD's box grown over the things' one."""
    if tb is None:
        return bb
    return (min(32767, max(bb[0], tb[0])), max(-32768, min(bb[1], tb[1])),
            max(-32768, min(bb[2], tb[2])), min(32767, max(bb[3], tb[3])))


def pack(md, wt, caps, next_level=0, xpool=None, next_secret=0):
    """-> (low_blob, high_blob, tex_blob, table). caps is a Caps (see below) and is
    REQUIRED: the whole point of v3 is that section addresses never move."""
    pool, _tab, segtex, table, scroll_ids, texix, segmid = \
        pack_map_textures(md, wt, xpool)
    # The .tex blob carries the column INDEX table at its front (texcol.asm:
    # tex_getix lifts it out of the MEMAC window into base RAM after the load),
    # so the pixels start at TEX_POOL_BASE, not TEX_VRAM_BASE.
    if xpool is not None:
        # POOLED (2026-08-14): the level ships no texture bytes at all -- both
        # the runs and the column-index arrays live in the episode blob, and
        # `texix` is the per-texid offset list that rides in the textab below.
        table = [t + (texix[i],) for i, t in enumerate(table)]
        tex_blob = b''
    else:
        from pack_textures import TEXIX_RESERVE
        assert len(texix) <= TEXIX_RESERVE, \
            f'column index blob {len(texix)} B > TEXIX_RESERVE {TEXIX_RESERVE}'
        table = [t + (0,) for t in table]
        tex_blob = bytes(texix) + bytes(TEXIX_RESERVE - len(texix)) + bytes(pool)
    # Ids 0..NO_TEX-1 are real and NO_TEX means "none", so NO_TEX rows fit -- the
    # assert used to say `< NO_TEX` and threw the last one away. E1M3 is exactly
    # 63 once its two-sided middle textures are in.
    assert len(table) <= NO_TEX, f'{len(table)} textures > {NO_TEX} -- texid collides'
    # front/back sector ids are ONE byte now, with $FF reserved for "no sector".
    assert len(md.sectors) < NO_SECTOR, \
        f'{len(md.sectors)} sectors >= {NO_SECTOR} -- the u8 seg sector id overflows'
    texid = lambda raw: NO_TEX if raw == NONE_ID else raw

    # Sector flags: b0 = sky ceiling, b1-b3 = the damage class update_damage
    # (bsp_main.asm) charges the player for standing here, b4 = SECRET SECTOR
    # (special 9). b4 is a class of its own and not a fifth damage value on
    # purpose: p_spec.c's switch gives 9 its own case, a secret does no damage,
    # and update_damage clears the bit in place the way DOOM writes
    # `sector->special = 0` -- so the found flag rides the same $4000 region
    # savegame.asm already snapshots and a found secret stays found across a
    # save. b5-b7 are still free. From p_spec.c
    # P_PlayerInSpecialSector -- the light-animating specials (1/2/3/8/12/13/17)
    # are deliberately absent: the renderer has no per-sector light, so they
    # would cost RAM and change nothing on screen.
    #   1 = 5% (7 nukage)   2 = 10% (5 hellslime)   3 = 20% (4 strobe hurt,
    #   16 super hellslime)   4 = 20% AND end the level at <=10 health --
    #   special 11, which is the ONLY exit E1M8 has (it carries no exit linedef).
    DMG = {7: 1, 5: 2, 4: 3, 16: 3, 11: 4}
    SECRET_BIT = 0x10
    sec_bytes = bytearray()
    for s in md.sectors:
        sky = 1 if s.ceil_flat == 'F_SKY1' else 0
        fb = wt.flat_dominant(s.floor_flat)
        cb = wt.flat_dominant(s.ceil_flat)
        sec_bytes += struct.pack('<hhBBBB', s.floor_h, s.ceil_h,
                                 max(0, min(255, s.light)),
                                 0 if fb is None else fb, 0 if cb is None else cb,
                                 sky | (DMG.get(s.special, 0) << 1)
                                 | (SECRET_BIT if s.special == 9 else 0))

    seg_bytes = bytearray()
    for i, sg in enumerate(md.segs):
        ld = md.linedefs[sg.linedef]
        fsd, bsd = (ld.right, ld.left) if sg.side == 0 else (ld.left, ld.right)
        front_sec = md.sidedefs[fsd].sector
        two = (bsd != NO_SIDEDEF) and (ld.flags & ML_TWOSIDED)
        back_sec = md.sidedefs[bsd].sector if two else NO_SECTOR
        wall = texid(segtex[2 * i])
        if ld.flags & ML_DONTPEGTOP:         # DOOM: top texture anchored at the TOP
            wall |= 0x40                     # (else it hangs from the back ceiling)
        if ld.flags & ML_BLOCKING:
            wall |= 0x80
        low = texid(segtex[2 * i + 1])
        if ld.flags & ML_DONTPEGBOTTOM:      # DOOM: middle/lower anchored at the
            low |= 0x40                      # BOTTOM (door tracks, step fronts)
        if ld.special in EXIT_SPECIALS:      # bit7 of low_tex marks an EXIT line.
            low |= 0x80                      # Free bit: the lower step is only ever
                                             # drawn on two-sided segs and the
                                             # renderer masks it off (and #$3F).
        seg_bytes += struct.pack('<HHBBBB', sg.v1, sg.v2, front_sec, back_sec,
                                 wall, low)

    vert_bytes = bytearray()
    for v in md.vertices:
        vert_bytes += struct.pack('<hh', v.x, v.y)
    ss_bytes = bytearray()
    for ss in md.ssectors:
        ss_bytes += struct.pack('<HH', ss.first, ss.count)
    node_bytes = bytearray()
    tbb = _thing_bbox_of_child(md)
    for n in md.nodes:
        # 2026-07-29: the two child bboxes are BACK. R_CheckBBox (checkbbox.asm)
        # throws a whole subtree away when every column its box covers is
        # already solid, before a single seg of it is transformed -- and in
        # FLAT mode 91 % of the frame is exactly that per-seg work. Measured
        # x1.3-x2.5 (tools/_verify_bboxcull.py), with the painted image proven
        # identical. They cost 16 B per node, but nodes live in the Rapidus EXT
        # bank, which uses 12 KB of its 64 KB -- the map window is untouched.
        # Layout must stay: x,y,dx,dy, child_r, child_l, bbox_r@12, bbox_l@20
        # (render_node writes those offsets into cb_nbb/cb_fbb).
        node_bytes += struct.pack('<hhhhHH', n.x, n.y, n.dx, n.dy,
                                  n.child[0], n.child[1])
        for side in (0, 1):                       # top, bottom, left, right
            b = _bbox_with_things(n.bbox[side], tbb.get(n.child[side]))
            node_bytes += struct.pack('<hhhh', b[0], b[1], b[2], b[3])

    doors, dsnd, doorlock = _doors(md)
    ndoors = struct.unpack_from('<H', doors, 0)[0]
    ybits, yidx_lo, yidx_hi, yval = _yoffs(md, segtex, table)
    lights = _lights(md)
    sx, sy, ang = _start(md)
    eye = _eye(md, sx, sy)
    # scroll_tex: the texid of this level's special-48 wall ($FF = none).
    # Only one per map in episode 1 (E1M1 TEKWALL1, E1M7 BROWN96), and the
    # engine's update_scroll walks exactly one.
    # n_secret: p_spec.c:1305 counts sector special 9 at P_SpawnSpecials and
    # keeps it in totalsecret, because P_PlayerInSpecialSector CLEARS the
    # special when the player walks in (p_spec.c:1052) -- so the total cannot
    # be recovered by counting them later. It is a level constant, so it is
    # baked here instead of costing the engine a load-time loop it has no RAM
    # for (the $1B00 init_level block is full to the byte).
    n_secret = sum(1 for s in md.sectors if s.special == 9)
    assert n_secret < 256, f'{n_secret} secret sectors -- the header byte is u8'
    # fin_ep: 0 = an ordinary exit, 1-3 = "this level ENDS that episode, run the
    # finale first". g_game.c G_DoCompleted tests `gamemap == 8`; the engine has
    # no episode/map numbers at runtime, only a level index, so the fact is baked
    # here. It rides one of the header's three pad bytes -- no level grew, and
    # next_level is left exactly as it was, so a build whose engine ignores this
    # byte behaves the way it always did.
    m8 = re.fullmatch(r'E(\d)M8', md.name.upper())
    fin_ep = int(m8.group(1)) if m8 else 0
    if fin_ep > 3:                       # only E1-E3 have finale assets packed
        fin_ep = 0
    header = struct.pack('<HHHHHHhhBBhHBBHBBBBBB',
                         len(md.vertices), len(md.sectors), len(md.segs),
                         len(md.ssectors), len(md.nodes), len(md.nodes) - 1,
                         sx, sy, ang, ndoors, eye, len(yval),
                         len(table), next_level, 3,
                         scroll_ids[0] if scroll_ids else 0xFF,
                         len(lights) // LIGHT_SIZE,          # hdr+27 -> MAP_HNLIGHT
                         n_secret,                           # hdr+28 -> MAP_HNSECR
                         fin_ep,                             # hdr+29 -> MAP_HFINEP
                         next_secret,                        # hdr+30 -> MAP_HNEXTS
                         _secret_sector(md))                 # hdr+31 -> MAP_HSECS
    assert len(header) == HDR_SIZE
    assert header[31] == _secret_sector(md), (
        'the secret-exit sector is not at header offset 31 -- MAP_HSECS')
    assert header[30] == next_secret, (
        'next_secret is not at header offset 30 -- MAP_HNEXTS must follow it')
    assert header[29] == fin_ep, \
        'fin_ep is not at header offset 29 -- MAP_HFINEP must follow it'
    assert header[28] == n_secret, \
        'n_secret is not at header offset 28 -- MAP_HNSECR must follow it'
    # Guard the emitted symbol against the struct layout drifting: MAP_HSCRTEX
    # was declared at hdr+30 while scroll_tex packs at 26, so every level read a
    # padding 0 and update_scroll walked texture 0 out of its VRAM block --
    # "the doors slide sideways when the level loads" (1..5.png).
    assert header[26] == (scroll_ids[0] if scroll_ids else 0xFF),         'scroll_tex is not at header offset 26 -- MAP_HSCRTEX must follow it'

    def pad(b, unit, cap):
        assert len(b) <= unit * cap, f'section {len(b)} B > cap {unit * cap} B'
        return bytes(b) + bytes(unit * cap - len(b))

    low = (header
           + pad(sec_bytes, SECT_SIZE, caps.sectors)
           + b''.join(pad(_textab_row(table, k), 1, caps.tex)
                      for k in range(TEXTAB_ROWS))
           + pad(ybits, 1, (caps.segs + 7) // 8)
           + pad(yidx_lo, 1, caps.yoff)
           + pad(yidx_hi, 1, caps.yoff)
           + pad(yval, 1, caps.yoff))
    # doors moved to the HIGH region (2026-07-27): the 8 B records (soundorg for
    # snd_q_door_at) + the 7th textab row pushed LOW past its $8600 limit, and
    # every doors reader runs after rom_out anyway.
    # SSECT left for the EXT bank on 2026-08-18: E2M7's 818 subsectors x 4 B
    # alone exceed the whole $D800-$E2FF window. Every reader already built
    # the row address in zp_ptr -- the read went (zp_ptr),y -> [zp_ptr],y
    # (same size, and zp_ptr+2 is the EXT bank byte init_level seeds anyway).
    high = (pad(doors[2:], 4, caps.doors)                  # count lives in the header
            + pad(dsnd, 4, caps.doors)                     # the soundorg pair
            + pad(doorlock, 1, caps.doors))                # 1 B lock per door record
    # EXT region (2026-07-28, the all-of-episode-1 rework): VERTS + NODES moved
    # into Rapidus SRAM bank $01 ($01:0000-$07:FFFF, 448 KB fast SRAM -- see
    # Altirra rapidus.cpp). E1M6 alone overflows the $4000 map slot by ~5 KB and
    # the under-ROM HIGH region by ~2 KB; these two arrays are exactly the bulk.
    # Readers switched to 65816 long addressing ([zp],y -- legal in emulation
    # mode); the port is Rapidus-only, so a plain 6502 is not a target.
    # SEGOFF (2026-07-29): DOOM's seg->offset -- how far along the LINEDEF this
    # seg starts. Without it calc_u restarts the texture at 0 on every BSP
    # split, so 9 % of segs (990 of 10741 in E1) show a seam mid-wall. It is a
    # parallel u16 array rather than a wider seg record because the seg table
    # lives in the packed LOW region, which has ~160 spare bytes, while the EXT
    # bank has 43 KB free.
    # 2026-08-07: this IS r_segs.c's rw_offset now -- seg->offset +
    # sidedef->textureoffset (R_StoreWallRange). Feeding the raw xoff in used to
    # move E1M4's switch plate FURTHER off, which is why a centre-the-plate
    # heuristic (_switch_u0 + SWITCH_NUDGE) sat here instead; the real cause was
    # a UNIT mismatch, not the offset. tw_setup.asm halves rs_seglen when
    # TEX_HALFW is on (the stored texture is half as wide, so one texel spans two
    # world units), but renderer.asm adds rs_segoff to that track unhalved -- so
    # the seed was in world units while the step was in stored texels, i.e.
    # double. Halving it HERE costs nothing at runtime and makes DOOM's own
    # formula land: ld395 in E1M4 has xoff 16 on a 32-unit wall, which is exactly
    # what puts SW1DIRT's plate on the wall instead of 16 texels left of it.
    segoff_bytes = b''.join(
        struct.pack('<H', ((sg.offset + _seg_xoff(md, sg)) >> (1 if HALF_W else 0))
                    & 0xFFFF)
        for sg in md.segs)
    ext = (pad(vert_bytes, 4, caps.verts)
           + pad(segoff_bytes, 2, caps.segs)
           + pad(ss_bytes, SSECT_SIZE, caps.ssect))        # from HIGH, 2026-08-18
    # SEG region (2026-07-31): the seg records left the LOW slot for a Rapidus
    # bank of their own. They were 14,896 of the LOW region's 17,644 B and they
    # sat across $47F0-$821F -- the last big block of ordinary RAM the port had
    # and, per Altirra rapidus.cpp kSRAMWindows, most of it inside the
    # $4000-$7FFF fast SRAM window. Readers went from `(zp_sptr),y` to
    # `[zp_sptr],y` (+1 cycle each, ~5 K cycles a frame); bank $01 was already
    # 40 KB full with VERTS+NODES+SEGOFF, so the segs get bank $03 and 64 KB of
    # room to grow instead of pushing TH_*/LOS/RECIP around inside bank $01.
    # The automap's three side tables ride at the END of the SEG region, which
    # is why the automap needed no loader of its own: load_level's SEG pass
    # already streams this bank in one read_ext, and bank $03 uses 15 KB of its
    # 64. See _automap() for what each one is.
    amseg, amskip, amseen, amflg = _automap(md, caps, _seg_layout(caps)[3])
    # SEGMID + MIDTEX (2026-08-15): the seg's TWO-SIDED MIDDLE texture -- one
    # row index per seg, $FF = none, and the rows themselves. A side array and
    # not a field of the seg record because that record is a fixed 8 B and its
    # address is three shifts; widening it would cost 15 KB of streaming per
    # level for one byte. Bank $03 has 40 KB free, so both ride here and
    # midtex.asm reads them with `lda.l` (16-bit X, the automap's own trick).
    segmid_ix, mtx_rows = _midtex(md, segmid, table)
    mtx = bytearray()
    for k in range(MTX_ROWS):
        for (tex, top, bot) in mtx_rows:
            mtx.append((tex, top & 0xFF, (top >> 8) & 0xFF,
                        bot & 0xFF, (bot >> 8) & 0xFF)[k])
        mtx += bytes(caps.mtx - len(mtx_rows))
    seg = (pad(seg_bytes, SEG_SIZE, caps.segs)
           + pad(amseg, 2, caps.segs)
           + pad(amskip, 1, (caps.segs + 7) // 8)
           + bytes(amseen)
           + pad(amflg, AM_SLOT, caps.lines)
           + pad(segmid_ix + b'\xFF' * (caps.segs - len(segmid_ix)), 1, caps.segs)
           + pad(mtx, MTX_ROWS, caps.mtx)
           # LIGHTS (2026-08-06, moved out of bank $01 on 2026-08-15): per-level
           # data nothing reads in an inner loop -- update_lights walks it once
           # a frame with `lda.l MAP_LIGHTS,x`, so a bank read costs one cycle
           # per field. It sat at the end of the EXT region until E1M2's 26
           # thinkers pushed it past TH_HPL and en_init ate the last eight; the
           # SEG bank uses 15 KB of 64, so here it cannot collide with anything.
           + pad(lights, LIGHT_SIZE, caps.lights)
           + pad(node_bytes, NODE_SIZE, caps.nodes))       # from EXT, 2026-08-18
    assert len(seg) == _seg_layout(caps)[9] - _seg_layout(caps)[0], \
        'the SEG blob and _seg_layout disagree'
    return low, high, ext, seg, tex_blob, table


Caps = collections.namedtuple(
    'Caps', 'verts sectors segs ssect nodes tex doors yoff lights lines mtx')

# ---- the capacity FLOOR, for a build that is not the whole game -------------
# Capacities are the max over the levels BEING BUILT, and every section address
# in map_syms.inc is derived from them -- so a one-level build lays the map blob
# out differently from the 27-level one. The shipping game only ever builds all
# 27, so that layout is the only one that has ever been played; a smaller set
# produces a layout nothing has ever run, and its ATR comes up with broken wall
# textures. Measured 2026-08-30: build_atr.ps1 -Full E1M5 (no wadconv anywhere)
# is broken, while the same single level built at the 27-level capacities is
# correct.
#
# A wadconv conversion is ALWAYS a small set -- that is the whole point of it --
# so it asks for this floor and gets the layout the engine is known to run. The
# numbers are the shipping build's own capacities; max() keeps anything a
# foreign WAD needs MORE of, and pack_map's region asserts still catch a map
# that will not fit. Off unless DOOM_CAPS_FLOOR is set, so the project's own
# build is bit-for-bit what it always was.
CAPS_FLOOR = Caps(verts=1626, sectors=226, segs=2438, ssect=818, nodes=817,
                  tex=NO_TEX, doors=44, yoff=59, lights=21, lines=1764, mtx=8)


def _floor_caps(caps):
    if not os.environ.get('DOOM_CAPS_FLOOR'):
        return caps
    out = Caps(*(max(a, b) for a, b in zip(caps, CAPS_FLOOR)))
    if out != caps:
        moved = [f'{f} {a}->{b}' for f, a, b in zip(Caps._fields, caps, out)
                 if a != b]
        print(f'  capacity floor (DOOM_CAPS_FLOOR): {", ".join(moved)}')
    return out


def emit_map_syms(caps):
    """Write map_syms.inc -- the section bases the engine is assembled against.

    v2 derived these from ONE packed .bin (tools/bin_syms.py). That only works
    while there is one level: with several, the addresses must come from the
    shared CAPACITIES, which only this module knows. Everything that varies per
    level moved into the runtime header (MAP_H*) instead.
    -> (low_sectors, high_sectors)
    """
    from pack_textures import HALF_W, RUN_TEXTURES, RUN_K
    hdr = MAP_LOAD
    sectors = hdr + HDR_SIZE
    texrow = sectors + caps.sectors * SECT_SIZE
    ybits = texrow + caps.tex * TEXTAB_ROWS
    yidxlo = ybits + (caps.segs + 7) // 8
    yidxhi = yidxlo + caps.yoff
    yval = yidxhi + caps.yoff
    low_end = yval + caps.yoff

    doors = MAP_LOAD_HI                         # HIGH: doors ONLY (2026-08-18 --
    dsnd = doors + caps.doors * 4               #   SSECT joined the EXT bank,
    doorlock = dsnd + caps.doors * 4            #   E2M7's 818 x 4 B blew $E300).
    high_end = doorlock + caps.doors            #   Two 4 B door records, not one
                                                #   of 8: see _doors.

    verts = 0x0000                              # EXT: offsets INSIDE bank MAP_EXT_BANK
    segoff = verts + caps.verts * 4             # (NODES joined the SEG bank
    ssect = segoff + caps.segs * 2              #  2026-08-18 -- see _seg_layout)
    ext_end = ssect + caps.ssect * SSECT_SIZE
    # update_lights indexes the records with a BYTE (lda.l MAP_LIGHTS,x), so the
    # whole section has to stay inside one 256-byte reach.
    if caps.lights * LIGHT_SIZE > 255:
        sys.exit(f'{caps.lights} light thinkers x {LIGHT_SIZE} B > 255 -- '
                 f'update_lights indexes them with X (lights.asm)')

    # SEG: offset INSIDE bank MAP_SEG_BANK. NOT 0, and that is load-bearing: the
    # USE trigger records (pack_things) store four seg RECORD ADDRESSES per
    # record and pad the unused slots with ZERO, which switch_match (doors.asm)
    # compares against zp_sptr with no empty-slot test. At base 0 the address of
    # seg 0 is 0, so every padded slot would match seg 0 and USE-ing that one
    # wall would fire unrelated switches. One page of slack costs nothing in a
    # 64 KB bank and keeps every real seg address non-zero.
    (segs, amseg, amskip, amseen, amflg, segmid, mtx, lights, nodes,
     seg_end) = _seg_layout(caps)

    if low_end > LOW_LIMIT:
        sys.exit(f'LOW map region ends at ${low_end:04X}, limit ${LOW_LIMIT:04X} '
                 f'({low_end - LOW_LIMIT} B over) -- the level set is too big.')
    if high_end > HI_LIMIT:
        sys.exit(f'HIGH map region ends at ${high_end:04X}, limit ${HI_LIMIT:04X} '
                 f'({high_end - HI_LIMIT} B over) -- the level set is too big.')
    if ext_end > EXT_LIMIT:
        sys.exit(f'EXT region ends at ${ext_end:04X}, limit ${EXT_LIMIT:04X} '
                 f'(TH_HPL, memory_map.inc) -- the AI tables share bank $01, '
                 f'and en_init clears them at every level load.')
    if seg_end > SEG_LIMIT:
        sys.exit(f'SEG region {seg_end} B > one Rapidus bank -- split it.')
    lo_sec = (low_end - MAP_LOAD + SECTOR - 1) // SECTOR
    hi_sec = (high_end - MAP_LOAD_HI + SECTOR - 1) // SECTOR
    ext_sec = (ext_end + SECTOR - 1) // SECTOR
    seg_sec = (seg_end - segs + SECTOR - 1) // SECTOR         # DATA only: the
                                                              # stream starts at
                                                              # MAP_SEGS, not at 0

    L = ['; AUTO-GENERATED by tools/pack_map.py -- do not edit.',
         '; Section bases of the packed map, from the SHARED CAPACITIES of the level',
         '; set in this build (pack_map.py Caps). Every level pads to them, so these',
         '; addresses hold whichever level is loaded. Per-level values -- counts, root',
         '; node, spawn point -- are read from the header (MAP_H*) at runtime.',
         '; RAM BUDGET: see the RAM-BUDGET block at the top of memory_map.inc.',
         f'; LOW  ${MAP_LOAD:04X}-${low_end:04X} ({low_end - MAP_LOAD} B, {lo_sec} sectors)',
         f'; HIGH ${MAP_LOAD_HI:04X}-${high_end:04X} ({high_end - MAP_LOAD_HI} B, '
         f'{hi_sec} sectors) -- RAM under the OS ROM',
         f'; EXT  ${MAP_EXT_BANK:02X}:0000-${MAP_EXT_BANK:02X}:{ext_end:04X} '
         f'({ext_end} B, {ext_sec} sectors) -- Rapidus SRAM bank (VERTS+SEGOFF+SSECT);',
         ';      MAP_VERTS/MAP_SSECT below are OFFSETS inside that bank, read via',
         ';      65816 [zp],y long indirect with zp+2 = MAP_EXT_BANK. (NODES',
         ';      moved to the SEG bank 2026-08-18, SSECT in from HIGH -- E2/E3.)',
         f'; SEG  ${MAP_SEG_BANK:02X}:{segs:04X}-${MAP_SEG_BANK:02X}:{seg_end:04X} '
         f'({seg_end - segs} B, {seg_sec} sectors) -- the seg records, in a bank',
         ';      of their own (bank $01 is 40 KB full). MAP_SEGS is an OFFSET inside',
         ';      bank MAP_SEG_BANK; readers use [zp_sptr],y, zp_sptr+2 set once',
         ';      by init_level. This is what freed $4C00-$85FF of ordinary RAM.',
         f';      MAP_AMSEG/AMFLG/AMSEEN ride at the end of the same region, so the',
         ';      automap costs no loader and no base RAM (pack_map._automap).',
         '',
         f'MAP_LOAD     equ ${MAP_LOAD:04X}',
         f'MAP_LOAD_HI  equ ${MAP_LOAD_HI:04X}',
         f'MAP_SEGOFF   equ ${segoff:04X}',
         f'MAP_EXT_BANK equ ${MAP_EXT_BANK:02X}',
         f'MAP_SEG_BANK equ ${MAP_SEG_BANK:02X}',
         f'MAP_LOW_SECT equ {lo_sec}',
         f'MAP_HI_SECT  equ {hi_sec}',
         f'MAP_EXT_SECT equ {ext_sec}',
         f'MAP_SEG_SECT equ {seg_sec}',
         '',
         '; ---- runtime header fields (per level) ----',
         f'MAP_HNVERT   equ ${hdr + 0:04X}',
         f'MAP_HNSEC    equ ${hdr + 2:04X}',
         f'MAP_HNSEG    equ ${hdr + 4:04X}',
         f'MAP_HNSS     equ ${hdr + 6:04X}',
         f'MAP_HNNODE   equ ${hdr + 8:04X}',
         f'MAP_HROOT    equ ${hdr + 10:04X}',
         f'MAP_HSX      equ ${hdr + 12:04X}',
         f'MAP_HSY      equ ${hdr + 14:04X}',
         f'MAP_HSANG    equ ${hdr + 16:04X}',
         f'MAP_HNDOOR   equ ${hdr + 17:04X}',
         f'MAP_HEYE     equ ${hdr + 18:04X}',
         f'MAP_HNYOFF   equ ${hdr + 20:04X}',
         f'MAP_HNTEX    equ ${hdr + 22:04X}',
         f'MAP_HNEXT    equ ${hdr + 23:04X}',
         f'MAP_HNLIGHT  equ ${hdr + 27:04X}',
         f'MAP_HNSECR   equ ${hdr + 28:04X}',
         f'MAP_HFINEP   equ ${hdr + 29:04X}      ; 0 = ordinary exit, 1-3 = this'
         f' level ends that episode',
         f'MAP_HNEXTS   equ ${hdr + 30:04X}      ; the SECRET exit target (ExM9);'
         f' use_leaf copies it',
         f'                              ;   over MAP_HNEXT when the exit seg it'
         f' hit matches MAP_HSECS.',
         f'                              ;   Equals MAP_HNEXT on a map with no'
         f' secret exit, so a false',
         f'                              ;   match there cannot change anything',
         f'MAP_HSECS    equ ${hdr + 31:04X}      ; SEG_FRONT of the secret exit'
         f' ($FF = none); the',
         f'                              ;   key covers it and the next sector'
         f' (two-sided lines)',
         '',
         '; ---- section bases ----',
         f'MAP_VERTS    equ ${verts:04X}',
         f'MAP_SEGS     equ ${segs:04X}',
         f'MAP_TEXADDRLO  equ ${texrow + 0 * caps.tex:04X}',
         f'MAP_TEXADDRMID equ ${texrow + 1 * caps.tex:04X}',
         f'MAP_TEXADDRHI  equ ${texrow + 2 * caps.tex:04X}',
         f'MAP_TEXWMASK   equ ${texrow + 3 * caps.tex:04X}',
         f'MAP_TEXH       equ ${texrow + 4 * caps.tex:04X}',
         f'MAP_TEXDOM     equ ${texrow + 5 * caps.tex:04X}',
         f'MAP_TEXSWMATE  equ ${texrow + 6 * caps.tex:04X}',
         f'MAP_TEXIXLO    equ ${texrow + 7 * caps.tex:04X}',
         f'MAP_TEXIXHI    equ ${texrow + 8 * caps.tex:04X}',
         f'MAP_HSCRTEX    equ ${hdr + 26:04X}',
         f'MAP_DOORS    equ ${doors:04X}',
         f'MAP_DSND     equ ${dsnd:04X}      ; soundorg pairs, 4 B a door',
         f'MAP_DOORLOCK equ ${doorlock:04X}',
         f'MAP_YBITS    equ ${ybits:04X}',
         f'MAP_YIDXLO   equ ${yidxlo:04X}',
         f'MAP_YIDXHI   equ ${yidxhi:04X}',
         f'MAP_YVAL     equ ${yval:04X}',
         f'MAP_SECTORS  equ ${sectors:04X}',
         f'MAP_SSECT    equ ${ssect:04X}      ; EXT-bank offset (2026-08-18: was HIGH)',
         f'MAP_NODES    equ ${nodes:04X}      ; SEG-bank offset (2026-08-18: was EXT;'
         f' zp_nodeptr+2 = MAP_SEG_BANK)',
         f'MAP_LIGHTS   equ ${lights:04X}      ; SEG-bank offset (lights.asm)',
         '',
         '; ---- automap side tables (SEG-bank offsets, automap.asm) ----',
         ';   AMSEG  u16 per seg = the bank-$03 ADDRESS of its linedef\'s AMSEEN',
         ';          slot, NOT an index -- that is what makes am_mark 21 bytes',
         ';          (lda.l AMSEG,x / tax / sta.l 0,x: no arithmetic, and the',
         ';          address it just read IS the non-zero "seen" value).',
         ';   AMSKIP 1 bit per seg: 1 = the BACK side of a two-sided line. It',
         ';          still MARKS, it just is not drawn (the front side\'s segs',
         ';          already tile the whole line). The automap walks segs in',
         ';          order, so one byte of this serves eight of them.',
         ';   AMSEEN u16 per linedef, 0 = never seen. r_segs.c:398 ML_MAPPED.',
         ';          Ships as ZEROS, so a level load resets it for free.',
         f';   AMFLG  u16 per linedef at the SAME stride, so the automap reads a',
         f';          line\'s flags with the seen slot\'s own X and a constant',
         f';          delta of ${amflg - amseen:04X}. bit0 ML_SECRET (draw as a solid',
         ';          WALL), bit1 ML_DONTDRAW, bit2 teleporter.',
         f'MAP_AMSEG    equ ${amseg:04X}',
         f'MAP_AMSKIP   equ ${amskip:04X}',
         f'MAP_AMSEEN   equ ${amseen:04X}',
         f'MAP_AMFLG    equ ${amflg:04X}',
         f'MAP_AMFDELTA equ ${amflg - amseen:04X}    ; AMFLG - AMSEEN',
         f'AMF_SECRET   equ ${AMF_SECRET:02X}',
         f'AMF_DONTDRAW equ ${AMF_DONTDRAW:02X}',
         f'AMF_TELEPORT equ ${AMF_TELEPORT:02X}',
         '',
         '; ---- the two-sided MIDDLE texture (SEG-bank, midtex.asm) ----',
         ';   r_segs.c\'s maskedtexture: the see-through support struts and',
         ';   fences (BRNBIG*/BRNSMAL*), which are neither the seg\'s upper nor',
         ';   its lower and so have nowhere to live in the 8 B seg record.',
         ';   SEGMID is one byte per SEG -- which MIDTEX row it uses, $FF for',
         ';   none. A MIDTEX row is the whole answer the renderer needs: the',
         ';   texid plus the world heights of the drawn span\'s top and bottom',
         ';   and the peg shift, all of which pack_map computes because the two',
         ';   sector heights they come from never move (see _midtex).',
         f'MAP_SEGMID   equ ${segmid:04X}',
         f'MAP_MTXTEX   equ ${mtx + 0 * caps.mtx:04X}',
         f'MAP_MTXTLO   equ ${mtx + 1 * caps.mtx:04X}',
         f'MAP_MTXTHI   equ ${mtx + 2 * caps.mtx:04X}',
         f'MAP_MTXBLO   equ ${mtx + 3 * caps.mtx:04X}',
         f'MAP_MTXBHI   equ ${mtx + 4 * caps.mtx:04X}',
         f'MAP_NMTX     equ {caps.mtx}',
         '',
         '; ---- capacities (assembly-time array sizes / asserts) ----',
         f'MAP_NVERTS   equ {caps.verts}',
         f'MAP_NSECTORS equ {caps.sectors}',
         f'MAP_NSEGS    equ {caps.segs}',
         f'MAP_NSSECT   equ {caps.ssect}',
         f'MAP_NNODES   equ {caps.nodes}',
         f'MAP_NDOORS   equ {caps.doors}',
         f'MAP_NYOFF    equ {caps.yoff}',
         f'MAP_NLIGHTS  equ {caps.lights}',
         f'MAP_NLINES   equ {caps.lines}',
         f'LIGHT_SIZE   equ {LIGHT_SIZE}',
         f'TEX_COUNT    equ {caps.tex}',
         '; 1 = textures are stored at HALF horizontal resolution (pack_textures.py',
         ';     HALF_W). seg_len then halves the per-seg u track -- see tw_setup.asm.',
         f'TEX_HALFW    equ {1 if HALF_W else 0}',
         '; 1 = a stored column is TEX_RUNK runs of (rows, colour) that the engine',
         ';     PAINTS (paint.asm), not texH pixels the blitter copies. The engine',
         ';     side MUST agree with pack_textures.RUN_TEXTURES -- which is why it',
         ';     is emitted here and not written by hand. TEX_RUNSH = log2 of the',
         ';     record size, i.e. the column-address shift wall_src uses.',
         f'TEX_RUNS     equ {1 if RUN_TEXTURES else 0}',
         f'TEX_RUNK     equ {RUN_K}',
         f'TEX_RUNSH    equ {(2 * RUN_K).bit_length() - 1}']
    with open(SYMS_OUT, 'w', encoding='ascii') as f:
        f.write('\n'.join(L) + '\n')
    print(f'  wrote {os.path.relpath(SYMS_OUT, os.path.dirname(_HERE))}  '
          f'(LOW ${MAP_LOAD:04X}-${low_end:04X} / {lo_sec} sec, '
          f'HIGH ${MAP_LOAD_HI:04X}-${high_end:04X} / {hi_sec} sec, '
          f'EXT bank ${MAP_EXT_BANK:02X} / {ext_sec} sec, '
          f'SEG bank ${MAP_SEG_BANK:02X} / {seg_sec} sec)')
    return lo_sec, hi_sec, ext_sec, seg_sec


def _textab_row(table, k):
    """One of the seven PARALLEL texture-table arrays, as bytes. Same fields the
    icl'd {map}_textab.inc used to carry; they live in the blob now so a level
    brings its own table instead of one level's being baked into the XEX."""
    sel = (lambda t: t[1],                       # VRAM addr, lo
           lambda t: t[1] >> 8,                  # ... mid
           lambda t: t[1] >> 16,                 # ... hi
           lambda t: t[2] - 1,                   # width-1 (pow2 AND wrap)
           lambda t: t[3],                       # height (column stride)
           lambda t: t[4],                       # dominant PLAYPAL index
           lambda t: t[5],                       # SW1->SW2 mate texid ($FF none)
           lambda t: t[6],                       # column-index offset in the
           lambda t: t[6] >> 8)[k]               #   shared pool (u16), texcol.asm
    return bytes(sel(t) & 0xFF for t in table)


def _eye(md, sx, sy):
    """Spawn eye Z = floor of the subsector the player start stands in + EYE.
    (bin_syms.py used to get this out of the packed .bin; it is per level, so it
    is a header field now.)"""
    from pack_things import wad_subsector, wad_sector_of_ss
    return md.sectors[wad_sector_of_ss(md, wad_subsector(md, sx, sy))].floor_h + EYE


def _yoffs(md, segtex, table):
    """The YOFF section: sidedef->rowoffset for the segs where it is VISIBLE.

    DOOM: `rw_midtexturemid/rw_toptexturemid/rw_bottomtexturemid +=
    sidedef->rowoffset` (r_segs.c:474, 603, 604) -- the mapper's "draw this
    texture N pixels lower" shift. The port expresses the anchor as a whole-texel
    shift (rs_vshw/rs_vshl), so rowoffset just adds into it, modulo the texture
    height; a seg whose rowoffset is a whole number of tiles for every slot it
    draws is therefore invisible and is left out.

    Cost on E1M1: 43 of 732 segs -> 92 B bitmap + 2 + 43*3 = 223 B, against the
    ~460 B still free in the $4000..$85FF map slot. A byte per seg (732 B) does
    not fit -- and the seg record has no spare bit left (texid needs 6 with the
    0x3F sentinel, plus impassable/EXIT and the two peg bits).
    """
    ents = []
    for i, sg in enumerate(md.segs):
        ld = md.linedefs[sg.linedef]
        fsd = ld.right if sg.side == 0 else ld.left
        if fsd == NO_SIDEDEF:
            continue
        yoff = md.sidedefs[fsd].yoff
        if yoff == 0:
            continue
        hs = [table[t][3] for t in (segtex[2 * i], segtex[2 * i + 1])
              if t != NONE_ID]
        # Every sidedef in DOOM.WAD is in 0..152, but DOOM itself allows any
        # rowoffset and other people's WADs use negative ones (GALAXIA.WAD's
        # E1M9 has -8). The 6502 adds an UNSIGNED byte and reduces it mod the
        # texture height at draw time, so shift the offset by whole tiles into
        # 1..255 -- congruent for every slot this seg actually draws, which
        # means working modulo the lcm of their heights. If that does not fit a
        # byte the seg simply loses its offset (a few pixels of vertical shift
        # on a wall that is a flat colour anyway) instead of failing the build.
        if not 0 < yoff < 256:
            step = 1
            for h in hs:
                if h:
                    step = step * h // math.gcd(step, h)
            if step <= 1 or step > 255:
                print(f'  note: seg {i} rowoffset {yoff} does not normalise into '
                      f'a byte (tile step {step}) -- dropped')
                continue
            yoff %= step
            if yoff == 0:
                continue                   # a whole number of tiles: invisible
        if not any(h and yoff % h for h in hs):
            continue                       # nothing drawn, or a whole-tile shift
        ents.append((i, yoff))
    bits = bytearray((len(md.segs) + 7) // 8)
    for i, _ in ents:
        bits[i >> 3] |= 1 << (i & 7)
    return (bytes(bits),
            bytes(i & 0xFF for i, _ in ents),
            bytes(i >> 8 for i, _ in ents),
            bytes(y for _, y in ents))


def _tics(t):
    """DOOM tics -> PAL VBLANKs. The port has no 35 Hz tic: every timed thing
    counts VBLANKs and subtracts fps_n per frame (see DOOR_DWELL_VB)."""
    return max(1, min(255, round(t * VBLANKS / TICRATE)))


def _lights(md):
    """The LIGHTS section: one record per sector P_SpawnSpecials would give a
    light thinker (p_spec.c:1053 ff).

    Everything that is CONSTANT for the level is resolved here, so the 6502 only
    runs the state machine:
      * minlight = P_FindMinSurroundingLight(sector, sector->lightlevel), i.e.
        the darkest of the sector itself and every sector across a two-sided
        line from it (p_lights.c:210). Strobes then apply DOOM's
        `if (minlight == maxlight) minlight = 0`, and a fire flicker its +16.
      * the dark-phase length in VBLANKs (FASTDARK/SLOWDARK); the bright phase
        is STROBEBRIGHT for every strobe, so it is a constant in lights.asm.
    -> bytes, records of LIGHT_SIZE
    """
    nb = {i: set() for i in range(len(md.sectors))}
    for ld in md.linedefs:                     # getNextSector(), both ways
        if ld.right == NO_SIDEDEF or ld.left == NO_SIDEDEF:
            continue
        a = md.sidedefs[ld.right].sector
        b = md.sidedefs[ld.left].sector
        if a != b:
            nb[a].add(b)
            nb[b].add(a)
    out = bytearray()
    for i, s in enumerate(md.sectors):
        ent = doomspecs.LIGHT_SECTOR.get(s.special)
        if ent is None:
            continue
        kind, dark = ent
        mx = max(0, min(255, s.light))
        mn = min([mx] + [max(0, min(255, md.sectors[j].light)) for j in nb[i]])
        base = kind & 0x7F
        if base == doomspecs.LT_STROBE:
            if mn == mx:                       # p_lights.c P_SpawnStrobeFlash
                mn = 0
        elif s.special == 17:                  # P_SpawnFireFlicker's own minlight
            mn = min(255, mn + 16)             #   (it packs as a flash -- see
                                               #    LT_FIRE in lights.asm)
        # The seed count is P_Random()'s job in DOOM (`(P_Random()&7)+1`); here
        # it is baked so a build is reproducible -- and a SYNC strobe seeds at 1
        # exactly like p_lights.c's `inSync` branch, which is the whole point of
        # specials 12/13: every strobe in the map blinks together.
        seed = 1 if (kind & doomspecs.LT_SYNC) else 2 + (len(out) // LIGHT_SIZE * 3) % 7
        if i > 255:                            # LT_SEC is one byte (lights.asm)
            sys.exit(f'{md.name}: sector {i} has light special {s.special}, and '
                     f'the light record stores the sector in ONE byte -- it '
                     f'would animate sector {i & 0xFF} instead. Widening LT_SEC '
                     f'means a 7 B record and a second index register in '
                     f'update_lights.')
        out += struct.pack('<BBBBBB', i, kind, mn, mx,
                           _tics(dark) if dark else 0, seed)
    return bytes(out)


def _doors(md):
    MANUAL_DOOR = doomspecs.MANUAL_DOOR
    # Tagged door actions (p_switch.c / p_spec.c): the tagged sectors behave as
    # doors too -- their records land in MAP_DOORS so trig_fire (doors.asm) can
    # drive them through the same state machine the DR doors use.
    #   2 W1 open stay | 29 S1 raise | 63 SR raise | 90 WR raise | 103 S1 open stay
    # 16/76 (close 30 s, then open) are door actions too, and theirs are the
    # sectors DOOM ships OPEN -- init_doors takes each door's starting ceiling
    # from the map, so they come up open on their own.
    TAG_DOOR = doomspecs.TAG_DOOR
    # Special 46 (GR open door, IMPACT): the tagged sector is a door too -- the
    # door STATE machine drives it either way. What may not happen is USE
    # opening it (P_UseSpecialLine has no case 46), and that is refused one
    # level up, on the LINE: pack_things.py hands the engine the gun line's seg
    # address and try_use/gun_seg_p stops the ray there (doors.asm).
    GUN_DOOR = doomspecs.GUN_DOOR
    # Per-door LOCK byte (EV_VerticalDoor's key check, p_doors.c:186-244):
    # bits0-2 = the key that opens it, matching the PS_KEYS bits give_bonus sets
    # (BN_AMT ids 22-24: blue=1 yellow=2 red=4; card and skull share a bit, like
    # P_CheckKeys' "card || skull"). Bit7 = D1 type: opens ONCE and parks open
    # (p_doors.c `case open`: the thinker is removed at the top = DOORSTAY).
    # Note DOOM's own asymmetry: DR 26/27/28 = B/Y/R but D1 32/33/34 = B/R/Y.
    LOCK = {26: 1, 27: 2, 28: 4,
            32: 0x81, 33: 0x84, 34: 0x82,
            31: 0x80, 118: 0x80}
    # Bit3 = THIS "DOOR" IS A CRUSHER (2026-08-29, p_ceilng.c). The port's only
    # ceiling machinery is the door mover, so a crusher sector gets a door
    # record like any other tagged ceiling -- and this bit is what tells
    # update_doors the three things a crusher does differently: it aims at
    # floor+8 instead of the floor, it reverses at both ends instead of parking,
    # and it HURTS on the way down. Bit3 is outside use_door_go's `and #$27`,
    # so it is invisible to the spacebar; bit5 below (no PUSH line reaches
    # these sectors) is what actually refuses USE, exactly as it does for every
    # other remote-only door.
    CRUSH_LOCK = 0x08
    CRUSHER, CRUSH_STOP = doomspecs.CRUSHER, doomspecs.CRUSH_STOP
    # Bit6 = ML_SECRET (doomdata.h:126). P_UseSpecialLine's monster gate is
    #   if (!thing->player) { if (line->flags & ML_SECRET) return false; ... }
    # (p_switch.c:300-306) -- a monster may never open a secret door, and E1M5's
    # shotgun closet (ld310, special 1, flags $24) is exactly one. ai_door
    # already refuses every door whose LOCK byte is non-zero, so the rule costs
    # no engine code at all; use_door_go masks the key with `and #7` and tests
    # D1 with `bpl`, so bit6 is invisible to the PLAYER's use, which is what
    # DOOM wants -- the flag stops monsters, not you.
    # Bit5 = "no PUSH line at all", the other half of the same gate. After the
    # secret test P_UseSpecialLine lets a monster through for four specials
    # only -- 1, 32, 33, 34, i.e. the doors you open by walking up and using
    # them -- and returns false for everything else. A door whose only opener is
    # a switch or a walkover line therefore cannot be nudged open by a monster,
    # and 49 of episode 1's doors are exactly that (E1M3's W1 rooms, E1M6's
    # timed sector 187, the S1 lifts...). ai_door works off the door SECTOR, not
    # the line it bumped, so the fact is stored per sector: set only when NO
    # manual line reaches this sector, which leaves a door that has both a DR
    # line and a tag openable, the way DOOM has it.
    ML_SECRET = 32
    door_sectors = {}
    locks = {}
    want = []
    pushable = set()
    spec_of = {}                        # sector -> the specials that open it
    for ld in md.linedefs:
        if ld.special in MANUAL_DOOR and ld.left != NO_SIDEDEF:
            lk = LOCK.get(ld.special, 0)
            if ld.flags & ML_SECRET:
                lk |= 0x40
            si = md.sidedefs[ld.left].sector
            pushable.add(si)
            want.append((si, lk))
            spec_of.setdefault(si, set()).add(ld.special)
        elif ld.special in (TAG_DOOR | GUN_DOOR) and ld.tag:
            for i, s in enumerate(md.sectors):
                if s.tag == ld.tag:
                    want.append((i, 0))
                    spec_of.setdefault(i, set()).add(ld.special)
        elif (ld.special in CRUSHER or ld.special in CRUSH_STOP) and ld.tag:
            # A crusher's tagged sectors need a door record for the SAME reason
            # a tagged door's do: the record is where the mover keeps the
            # sector pointer and the ceiling it travels to. A STOP line (74)
            # tags the same sectors, and listing it here means a map whose
            # crusher is only ever stopped still gets its records.
            for i, s in enumerate(md.sectors):
                if s.tag == ld.tag:
                    want.append((i, CRUSH_LOCK))
                    spec_of.setdefault(i, set()).add(ld.special)
    crush_sec = {ds for ds, lk in want if lk & CRUSH_LOCK}
    assert not (crush_sec & {ds for ds, lk in want if not lk & CRUSH_LOCK}), \
        f'{md.name}: a sector is both a crusher and an ordinary door -- one ' \
        f'record cannot carry two open_ceil values'
    for ds, lk in want:
        locks[ds] = locks.get(ds, 0) | lk
        if ds in door_sectors:
            continue
        neigh = set()
        for l2 in md.linedefs:
            if l2.right == NO_SIDEDEF or l2.left == NO_SIDEDEF:
                continue
            fs = md.sidedefs[l2.right].sector
            bs = md.sidedefs[l2.left].sector
            if fs == ds and bs != ds:
                neigh.add(bs)
            elif bs == ds and fs != ds:
                neigh.add(fs)
        ceils = [md.sectors[n].ceil_h for n in neigh]
        if ds in crush_sec:
            # p_ceilng.c EV_DoCeiling: a crusher's topheight is the sector's
            # OWN ceiling -- where the map ships it -- and its bottomheight is
            # floor+8 (the mover computes that end; only the top is a record).
            # Neighbours have no say, unlike every other door here.
            open_ceil = md.sectors[ds].ceil_h
        elif not ceils:
            open_ceil = md.sectors[ds].ceil_h
        elif spec_of.get(ds) == {40}:
            # p_ceilng.c raiseToHighest: 40 raises the ceiling to the HIGHEST
            # neighbour, and it is only a "door" here because the door mover is
            # the port's only ceiling machinery. Borrowing the door target
            # (lowest - 4) sent E3M5's sector 129 to 60 with its floor at 88.
            open_ceil = max(ceils)
        else:
            open_ceil = min(ceils) - 4       # P_FindLowestCeilingSurrounding - 4
        # Never below the sector's own floor. A ceiling under the floor inverts
        # the sector -- the renderer and collision both read ceil-floor as the
        # opening -- and DOOM's own snap can produce it on a degenerate sector
        # (E2M5's 65: a W1-open room at floor 128 whose one neighbour ceils at
        # 128). Clamping costs nothing anywhere else: a real door's neighbours
        # are all above its floor. These two only became reachable when the
        # weld went, which is how they surfaced at all.
        door_sectors[ds] = max(open_ceil, md.sectors[ds].floor_h)
    for ds in locks:                    # remote-only door: no monster may push it
        if ds not in pushable:
            locks[ds] |= 0x20
    # THE SIDE RULE (p_switch.c P_UseSpecialLine: `if (side) ... return false`).
    # A manual door opens from the FRONT sector of the line carrying the special
    # -- and 16 doors in episode 1 have a SECOND face with special 0, which DOOM
    # answers with nothing but sfx_noway. The engine cannot tell the two faces
    # apart on its own: both are two-sided segs with the door as their BACK
    # sector, and the .bin carries no linedef specials. So name the refused
    # face's sector here; use_leaf compares the crossed seg's FRONT sector with
    # it (doors.asm, DOOR_DENY). $FF = refuse nothing, which is every ordinary
    # door -- both its faces carry special 1.
    #   Remote-only doors need no entry: LOCK bit5 above already refuses the
    # spacebar on every face of those.
    push = {}
    for ld in md.linedefs:
        if ld.special in MANUAL_DOOR and ld.left != NO_SIDEDEF:
            push.setdefault(md.sidedefs[ld.left].sector,
                            set()).add(md.sidedefs[ld.right].sector)
    deny = {}
    for ds in door_sectors:
        other = set()
        for ld in md.linedefs:
            if NO_SIDEDEF in (ld.right, ld.left):
                continue
            fs = md.sidedefs[ld.right].sector
            bs = md.sidedefs[ld.left].sector
            if fs == bs or ds not in (fs, bs):
                continue
            other.add(bs if fs == ds else fs)
        other -= push.get(ds, set())
        if not push.get(ds):
            other = set()               # LOCK bit5 refuses the lot already
        if len(other) > 1:
            # E2/E3 (2026-08-18): a door post reachable from 3+ sectors (E1
            # never had one). DOOR_DENY is one byte, so ONE face keeps the
            # refusal and the rest open the door from the "wrong" side too --
            # milder than vanilla, never blocking.
            keep = sorted(other)[0]
            print(f'  {md.name}: door sector {ds} refuses USE from '
                  f'{sorted(other)}; one DENY byte -> keeping {keep}')
            other = {keep}
        deny[ds] = other.pop() if other else 0xFF
    def _soundorg(si):
        # P_GroupLines: a sector's sound origin is its bounding-box centre
        xs, ys = [], []
        for l in md.linedefs:
            for sd in (l.right, l.left):
                if sd != NO_SIDEDEF and md.sidedefs[sd].sector == si:
                    for vi in (l.v1, l.v2):
                        xs.append(md.vertices[vi].x)
                        ys.append(md.vertices[vi].y)
                    break
        if not xs:
            return 0, 0
        return (min(xs) + max(xs)) // 2, (min(ys) + max(ys)) // 2
    # TWO 4 B records per door, not one of 8 (2026-08-18). init_doors and
    # snd_q_door_at both index with `txa / asl.. / tay`, so an 8 B stride puts
    # door 32 and up past Y's 255 and the read wraps to the wrong door -- which
    # is what stopped DOORS_NMAX growing past 32 on the engine side. At 4 B the
    # index reaches door 63.
    out = bytearray(struct.pack('<H', len(door_sectors)))
    snd = bytearray()
    for ds, oc in door_sectors.items():
        sox, soy = _soundorg(ds)
        if ds > 0xFE:
            sys.exit(f'pack_map: door sector {ds} does not fit a byte')
        out += struct.pack('<BBh', ds, deny[ds], oc)      # MAP_DOORS
        snd += struct.pack('<hh', sox, soy)               # MAP_DSND
    return out, bytes(snd), bytes(locks[ds] for ds in door_sectors)


def _start(md):
    for t in md.things:
        if t.type == 1:
            return t.x, t.y, int(t.angle * 256 / 360) & 0xFF
    mnx, mny, mxx, mxy = md.bounds()
    return (mnx + mxx) // 2, (mny + mxy) // 2, 0


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    wad_path = next((a for a in args if a.lower().endswith('.wad')), DEFAULT_WAD)
    names = [a for a in args if not a.lower().endswith('.wad')]
    w = Wad(wad_path)
    wt = WadTextures(w)
    if '--all' in sys.argv:
        names = w.map_names()
    elif not names:
        names = [f'E1M{i}' for i in range(1, 10)]

    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(TEX_DIR, exist_ok=True)
    write_playpal(wt, TEX_DIR)         # the FOUR palettes, not one -- see
                                      # pack_textures.write_playpal

    mds = {nm: w.load_map(nm) for nm in names}
    # Pass 1: the shared capacities. Every level is padded to these, so every
    # section base is a constant the engine can be assembled against.
    xpool = TexPool()                  # the EPISODE texture blob (2026-08-14)
    pre = {}
    for nm, md in mds.items():
        tex_blob, _t, segtex, table, _scr, _ix, segmid = \
            pack_map_textures(md, wt, xpool)
        nd = struct.unpack_from('<H', _doors(md)[0], 0)[0]
        ny = len(_yoffs(md, segtex, table)[3])
        nm_ = len(_midtex(md, segmid, table)[1])
        pre[nm] = (len(table), nd, ny, len(_lights(md)) // LIGHT_SIZE, nm_)
    caps = Caps(verts=max(len(m.vertices) for m in mds.values()),
                sectors=max(len(m.sectors) for m in mds.values()),
                segs=max(len(m.segs) for m in mds.values()),
                ssect=max(len(m.ssectors) for m in mds.values()),
                nodes=max(len(m.nodes) for m in mds.values()),
                tex=max(v[0] for v in pre.values()),
                doors=max(v[1] for v in pre.values()),
                yoff=max(v[2] for v in pre.values()),
                lights=max(v[3] for v in pre.values()),
                lines=max(len(m.linedefs) for m in mds.values()),
                mtx=max(1, max(v[4] for v in pre.values())))
    caps = _floor_caps(caps)
    # Pass 1 interned every payload; freeze the layout so pass 2 gets real
    # offsets. ONE blob for the whole episode instead of one per level.
    pool_blob = xpool.finish()
    with open(os.path.join(TEX_DIR, 'pool.tex'), 'wb') as f:
        f.write(pool_blob)
    lo_sec, hi_sec, ext_sec, seg_sec = emit_map_syms(caps)
    print(f'  shared capacities: {caps.verts} verts, {caps.sectors} sectors, '
          f'{caps.segs} segs, {caps.ssect} ssectors, {caps.nodes} nodes, '
          f'{caps.tex} textures, {caps.doors} doors, {caps.yoff} yoffs, '
          f'{caps.lights} light thinkers, {caps.lines} linedefs')
    print(f'{"map":6} {"low":>6} {"high":>6} {"ext":>6} {"seg":>6} {"segs":>5} '
          f'{"tex":>4} {"tex KB":>7}')
    for i, nm in enumerate(names):
        md = mds[nm]
        low, high, ext, seg, tex_blob, table = pack(md, wt, caps,
                                                    _next_level(names, i, md),
                                                    xpool,
                                                    _secret_level(names, i, md))
        low += bytes(-len(low) % SECTOR)          # each region starts on a sector
        high += bytes(-len(high) % SECTOR)
        ext += bytes(-len(ext) % SECTOR)
        seg += bytes(-len(seg) % SECTOR)
        assert (len(low) == lo_sec * SECTOR and len(high) == hi_sec * SECTOR
                and len(ext) == ext_sec * SECTOR and len(seg) == seg_sec * SECTOR)
        with open(os.path.join(OUT_DIR, f'{nm}.bin'), 'wb') as f:
            f.write(low + high + ext + seg)       # load_level reads them in THIS order
        with open(os.path.join(TEX_DIR, f'{nm}.tex'), 'wb') as f:
            f.write(tex_blob)                     # empty when pooled
        print(f'{nm:6} {len(low):6} {len(high):6} {len(ext):6} {len(seg):6} '
              f'{len(md.segs):5} {len(table):4} {len(tex_blob)/1024:7.1f}')


if __name__ == '__main__':
    main()
