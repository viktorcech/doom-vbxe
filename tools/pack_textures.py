#!/usr/bin/env python3
"""Pack a map's wall textures into the VBXE-VRAM form the engine blits from.

Phase 1 of textured walls on Atari (mechanism = wolf3d textures.asm: column-major
textures in VRAM, one BCB per column, SRC_STEPY=1, ZOOMY magnify ladder). Emits,
per map, into build/assets/textures/:

  {map}.tex      column-major texture pixels (the VRAM blob, loaded at $020000+).
                 A texture w x h -> for x in 0..w-1: h bytes (palette indices).
                 Column stride = h, so texel(x,y) is at tex_base + x*h + y and a
                 wall column is SRC_ADDR = tex_base + tex_x*h, SRC_STEPY = 1.
  {map}.textab   texture table: u16 count, then per id: u24 vram_addr, u16 w,
                 u16 h, u8 wlog2 (width is always pow2 -> cheap u wrap), 8s name.
  {map}.segtex   per seg (index-aligned with pack_map): u8 wall_texid, u8 low_texid
                 (0xFF = none / '-'; wall = solid-middle or portal-upper, low =
                 portal-lower). Mirrors pack_map's col_a/col_b.
  playpal.bin    the real 256-colour DOOM palette (768 B, r,g,b) for VBXE install.

VRAM: textures are laid out contiguously from TEX_VRAM_BASE ($020000), which the
flat-shaded port left unused. Heights are NATIVE (no padding) -> 4 E1M1 textures
have non-pow2 height (56/72/24) needing a general tex_x*h; the rest are shifts.

Usage: python pack_textures.py [E1M1 ...]   (default E1M1)
"""
import os
import re
import struct
import sys

import doomspecs
from wadlib import Wad, DEFAULT_WAD, NO_SIDEDEF, ML_TWOSIDED
from wadtex import WadTextures

_HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures')

# The PLAYPAL slots that go resident in VBXE's palettes, in the order
# load_palette installs them (see pld_psel in diskio.asm and FL_PAL_* in
# memory_map.inc):
#   0   normal
#   5   damage red -- one level, not two (see below)
#   10  item pickup gold, the level a single BONUSADD always lands on
#       ((6+7)>>3 = 1 -> STARTBONUSPALS+1)
# The green radiation-suit slot (13) is not shipped: the port has no pw_ironfeet.
#
# THREE, NOT FOUR (2026-08-01). VBXE has four palettes and palette 0 is also the
# one it maps ordinary GTIA colours through -- and a WARM reset does not put it
# back (Altirra's core only refills it in ColdReset, _pomocne/alt-src
# .../vbxe.cpp:226-227). So filling all four left the machine with a black
# screen after RESET until a power cycle. wolfenstein3d-vbxe hit the same thing
# and answered it the simple way (src/vbxe_init_cold.asm:70, "Palette 1 picked
# so we don't clobber the ANTIC PF/BAK colors that share palette 0"), so this
# port does too: palette 0 is never written, and the fourth slot -- the milder
# of DOOM's two damage reds -- is what pays for it. FL_REDSPLIT still picks
# between "low" and "high", both now land on the same palette.
PAL_SLOTS = (0, 5, 10)

TEX_VRAM_BASE = 0x018000          # VBXE VRAM: right above FRAME_B ($010000+$7D00).
                                  # 2026-07-27: was $020000; E1M2 + the SW2 switch
                                  # faces (329 KB) overran the 320 KB budget to
                                  # $070000 (TEX8/sprites/HUD) -- this buys 32 KB.
                                  # make_atr_doom.py asserts the slot still fits.
NONE_ID = 0xFF
NONE_SEG_ID = 0x3F                # seg texid is 6 bits; $3F means "no texture",
                                  # so a level may hold at most 63 texids
# ---- WALLS AS RUNS (2026-08-06) --------------------------------------------
# A blitted texture cannot be shaded -- the VBXE blitter has no lookup in its
# path (lights.asm) -- so textured walls ignore the sector light; it has to BE
# in VRAM, which is what the 192 KB arena was for; and it is what the frame's
# blitter budget goes on (measured A/B in tools/_bench_spans.py: 203 % of a
# 50 Hz frame blitted, 41 % painted). With RUN_TEXTURES the per-column payload becomes RUN_K runs of
# (rows, colour) instead of h pixels: the engine PAINTS the column, so it goes
# through the colormap (it blinks) and costs a fraction of the blit.
# Everything else in this file is unchanged -- the dedup, the aliasing, the
# column index, the textab -- because a column is still a fixed-size record;
# only its stride is 2*RUN_K instead of h. Flip this back to False and the build
# ships pixels again.
# 2026-08-06: ON. The engine side landed with it -- paint.asm's paint_col (the
# painter), wall_src/low_src addressing the run record, pt_seg/pt_step for the
# rows-per-texel rate, and seg_draw resolving a texture to its SDRAM address
# instead of fetching it into the VRAM arena. pack_map.py emits TEX_RUNS/
# TEX_RUNK into map_syms.inc from HERE, so the two halves cannot disagree:
# flip this back to False and the whole engine switches back to the blit.
RUN_TEXTURES = True
RUN_K = 32                        # runs per column. 16 shipped first (53.9 % of
                                  # E1's texels byte-exact, tools/tests/
                                  # _verify_texfid.py); 32 doubles the stride to
                                  # 64 B (TEX_RUNSH 5 -> 6 -- it MUST stay a
                                  # power of two, wall_src shifts by it) and the
                                  # SDRAM/ATR slots grow with the blob, which
                                  # make_atr_doom.py re-derives. paint.asm's
                                  # PT_MAXRUN scales off TEX_RUNK the same way.

TEXIX_MAX = 1664                  # the column index blob (dedup_columns). It has
                                  # to be read by the 6502, so it ends up in BASE
                                  # RAM at TEXIX_BASE -- but it gets there by
                                  # riding at the FRONT of the .tex blob and
                                  # being copied back out of the MEMAC window
                                  # once per level (diskio.asm tex_getix). That
                                  # costs 1.6 KB of the 38 KB the dedup just
                                  # freed and saves a whole per-level ATR region.
                                  # 2026-08-06: 2048 -> 1664. The worst level
                                  # (E1M2) needs 1488, and the 384 B of slack
                                  # became LIGHTS_BASE -- base RAM had 179 B
                                  # free in the whole machine. pack_map.py
                                  # asserts every level's real blob against it.
                                  # Keep in step with memory_map.inc TEXIX_MAX.
# How much of the .tex blob the index actually RESERVES. With RUN_TEXTURES the
# engine reads the index straight out of SDRAM with the CPU (texcol.asm), the
# same way it reads the runs -- so it is not copied into base RAM, TEXIX_MAX
# stops being a ceiling, and the reserve costs file bytes instead of the
# scarcest resource in the machine. It has to grow, too: the run encoding
# dedups MORE columns, which changes the index values and cost E1M2's arrays
# their substring aliasing (1488 -> 1904 B, i.e. past TEXIX_MAX).
TEXIX_RESERVE = 4096 if RUN_TEXTURES else TEXIX_MAX
TEX_POOL_BASE = TEX_VRAM_BASE + TEXIX_RESERVE  # ...so the pixels start after it

# 2:1 HORIZONTAL DOWNSAMPLE. The view is 160 LR bytes wide for a 90 deg FOV --
# exactly half of DOOM's 320 -- so one screen byte covers two DOOM texels
# horizontally and the second one can never be resolved. Storing every other
# column is therefore visually free and halves the VRAM cost of a level's texture
# set: E1M2 goes 619 kB -> 309 kB, i.e. from "does not fit in VBXE at all" to
# "fits in the existing $020000-$06FFFF arena". Vertically NOTHING is dropped:
# the 3D view is 168 rows, the same as DOOM's, so a vertical halving would show.
#
# Runtime cost: ZERO per column. One texel now spans two world units, so the
# engine just halves the per-seg u track once (seg_len in tw_setup.asm, guarded
# by the TEX_HALFW equ this module emits into {map}_textab.inc).
HALF_W = True


def half_cols(tx, w, h):
    """column-major bytes + the stored width, after the 2:1 downsample.

    The width is first rounded DOWN to a power of two -- exactly what DOOM's
    r_data.c does (texturewidthmask), so the dropped columns are columns
    NEITHER engine ever draws. It also keeps fold_width's pow2 scan honest:
    fed a non-pow2 width (AASTINKY is 24 wide, E1M2), its `pw <<= 1` walked
    past the real width and handed back phantom columns, which dedup_columns
    stored as one empty pool entry -- and the engine then read the NEXT
    texture's bytes for the right quarter of that wall (2026-08-10)."""
    pw = 1
    while pw * 2 <= w:
        pw <<= 1
    step = 2 if HALF_W else 1
    cols = bytearray()
    n = 0
    for x in range(0, pw, step):
        cols += bytes(tx[x])
        n += 1
    return bytes(cols), n


def fold_width(cols, w, h):
    """LOSSLESS horizontal fold: many DOOM textures are a pow2-periodic repeat
    of a narrower patch strip (SUPPORT2 is 8 identical 8px strips, STARTAN's
    128 is twice its 64...). The engine wraps u with WMASK (= stored w - 1)
    anyway, so storing ONE period and shrinking the mask reproduces the same
    texels with zero runtime cost -- only exact byte-equal repeats fold."""
    pw = 1
    while pw < w:
        if all(cols[x * h:(x + 1) * h] == cols[(x & (pw - 1)) * h:
                                               (x & (pw - 1)) * h + h]
               for x in range(pw, w)):
            break
        pw <<= 1
    return cols[:pw * h], pw


_PAL_CACHE = []


def _playpal_rgb():
    """PLAYPAL as a (256,3) array -- what the run converter needs to pick a
    colour. Read once; wadtex has the lump.

    The IWAD's OWN palette (source 0), not the merged view's: a layered WAD
    that ships a PLAYPAL is remapped INTO this one by wadtex, so its texture
    indices already mean these colours. Reading the merged lump measured every
    run's error against the wrong palette (2026-08-16)."""
    if not _PAL_CACHE:
        import numpy as np
        from wadlib import Wad, DEFAULT_WAD
        w = Wad(DEFAULT_WAD)
        raw = w.source_palette(0)
        if raw is None:
            i = w._index['PLAYPAL']
            _n, off, _s = w.lumps[i]
            raw = w.data[off:off + 768]
        _PAL_CACHE.append(np.frombuffer(bytes(raw),
                                        dtype=np.uint8).reshape(256, 3))
    return _PAL_CACHE[0]


def _payload(cols, w, h, masked=False):
    """The per-column bytes the engine will store: pixels, or RUN_K runs of
    (rows, colour) when RUN_TEXTURES. -> (bytes, w, stride)

    masked: this texture is a two-sided MIDDLE texture (a fence / support
    strut), so index 0 in `cols` means TRANSPARENT and the run split has to
    keep those stretches exact -- see texruns._masked_runs."""
    if not RUN_TEXTURES:
        return cols, w, h
    import texruns
    grid = [list(cols[c * h:(c + 1) * h]) for c in range(w)]
    blob, _painted = texruns.texture_runs(grid, _playpal_rgb(), RUN_K, masked)
    return blob, w, 2 * RUN_K


def dedup_columns(cols, w, h):
    """LOSSLESS column sharing: store each DISTINCT column once and hand the
    engine a byte per column saying which stored one to use.

    fold_width above only catches a texture that repeats as a whole; this
    catches the far commoner case of individual columns recurring anywhere in
    the texture (a light strip's two identical sides, a flat run either side of
    a rivet). Measured with tools/_tex_dedup.py: 14-34 % of the pixels per
    level, 23 % over episode 1.

    The index is a BYTE, so a texture may not have more than 256 distinct
    columns -- w is a power of two and never exceeds 128 (half_cols), so it
    cannot. The engine cost is one `lda abs,y` per column: tw_setup.asm's
    wall_src reads the index instead of using tex_x directly, and everything
    downstream -- the tiling mask, the 8x expander, the BCB -- is unchanged
    because a column is still `base + index*h` bytes of exactly h texels.

    -> (pool bytes, index bytes)"""
    pool, idx, at = bytearray(), bytearray(), {}
    for x in range(w):
        c = bytes(cols[x * h:(x + 1) * h])
        i = at.get(c)
        if i is None:
            i = at[c] = len(at)
            pool += c
        idx.append(i)
    return pool, idx


# ---------------------------------------------------------------------------
# 2026-07-30: THE BUILD NO LONGER SHIPS GENERAL WALL TEXTURES.
#
# WHY. VBXE has 512 KB of VRAM and it was full: the texture slot alone runs
# $018000..$06B000 (the weapon psprites), and E1M2's set is 329 KB of that --
# about 1 KB of slack left. Animated sprites and more digitized SFX have
# nowhere to go, and textures are by far the biggest tenant, so they are the
# thing that gives way. Walls are drawn flat, in each texture's own dominant
# PLAYPAL colour -- the exact picture the 'T' key (tex_off) has always shown.
#
# WHAT SURVIVES. Only the faces a player has to be able to READ: door faces and
# their tracks, lift / platform faces, and switches (p_switch.c's own list,
# incl. the exit switch). Those stay pixel-accurate -- see _is_moving_face, and
# _seg_slots for why each of them gets a texid of its own.
#
# NOTHING WAS REMOVED FROM THE ENGINE. The whole per-column texture pipeline --
# textures.asm, tw_setup.asm, colmerge.asm, the BCB chain, twdeform -- is still
# in the tree and still runs, for the textures above. This is a DATA decision,
# taken here, in one place. Flip SHIP_ALL_TEXTURES to True and the fully
# textured build comes back byte for byte (and no longer fits in VRAM:
# make_atr_doom.py's assert will say so).
#
# HOW THE ENGINE IS TOLD. A dropped texture keeps its table row -- the row is
# where its dominant colour lives -- but its height is packed as 0. h = 0 is
# impossible for a real texture, so seg_draw.asm reads it as "pixels are not in
# this build", keeps the colour and parks rs_wtexid = $FF, i.e. the same flat
# state the 'T' toggle produces. See docs/TEXTURES-OFF.md.
# ---------------------------------------------------------------------------
SHIP_ALL_TEXTURES = True             # 2026-08-03: back ON -- the VRAM diet
                                     #   (T4 sprite crop + A2 region spill,
                                     #   docs/VRAM-PLAN.md) pays for it on all
                                     #   nine maps; make_atr still asserts

# Which specials are doors and which move a floor is NOT decided here -- see
# doomspecs.py, the one definition every tool in tools/ shares.


def _moving_sectors(md):
    """(door sectors, plat/lift sectors) -- the sectors the port's own movers
    drive, found the same way pack_map.py _doors and movers.asm's triggers do."""
    doors, plats, dtags, ptags = set(), set(), set(), set()
    for ld in md.linedefs:
        if not ld.special:
            continue
        if ld.special in doomspecs.MANUAL_DOOR and ld.left != NO_SIDEDEF:
            doors.add(md.sidedefs[ld.left].sector)
        elif ld.tag and ld.special in doomspecs.TAG_DOOR:
            dtags.add(ld.tag)
        elif ld.tag and ld.special in doomspecs.FLOORS:
            ptags.add(ld.tag)
    for i, s in enumerate(md.sectors):
        if s.tag and s.tag in dtags:
            doors.add(i)
        if s.tag and s.tag in ptags:
            plats.add(i)
    return doors, plats


ROLE_TAG = '@D'      # marks the private copy a door / lift face gets (see below)

# The key-coloured door faces. Aliasing one of these is not a cosmetic slip --
# a blue door painted DOORRED2 tells the player to go and find the wrong key --
# so they are protected whatever else happens, and no ordinary wall may alias
# ONTO them either (that would paint a fake locked door on a plain wall).
KEY_DOOR_TEX = re.compile(r'^DOOR(BLU|RED|YEL)2?$')


def _is_moving_face(md, doors, plats, sg, slot):
    """Is this seg slot ('w' = wall/upper/middle, 'l' = lower) a surface that
    MOVES -- the thing the player has to be able to read?

      * door face  -- wall slot of a two-sided seg looking INTO a door sector:
                      the slab that slides up out of the ceiling;
      * door track -- wall slot of a ONE-sided seg inside a door sector
                      (DOORTRAK / DOORSTOP). A flat track around a textured
                      door reads as a bug, and it is two textures;
      * door step  -- low slot looking into a door sector (EXITDOOR is on both
                      slots; missing this dropped it on E1M3/5/6);
      * lift face  -- low slot looking into a plat sector: the step that rides
                      up and down.

    Deliberately NOT included: the one-sided walls inside a plat sector. Half
    of DOOM's "plats" are raise-floor specials on whole ROOMS, so that clause
    pulled the room's own walls in -- E1M3 went to 61 texids and 211 KB.
    """
    ld = md.linedefs[sg.linedef]
    fsd, bsd = (ld.right, ld.left) if sg.side == 0 else (ld.left, ld.right)
    two = (bsd != NO_SIDEDEF) and bool(ld.flags & ML_TWOSIDED)
    front = md.sidedefs[fsd].sector
    into = md.sidedefs[bsd].sector if two else front
    if slot == 'w':
        return into in doors
    return two and (into in plats or into in doors)


def _functional_names(md, slots):
    """The texture names that a player has to be able to READ: every door /
    lift face, door track and door step in the level (_is_moving_face), by the
    name the seg slot actually carries.

    This used to be answered by the ROLE_TAG suffix alone -- but _seg_slots
    only tags when SHIP_ALL_TEXTURES is False, and it has been True since
    2026-08-03, so with the full-texture build the texid alias below saw NO
    protected doors at all: E2M6 merged BIGDOOR2 into STARGR2 (the first door
    of the level), E2M2 BIGDOOR2 into DOORYEL, E3M3 the DOORTRAK track itself.
    The role is a property of the SEG, not of the name, so ask the geometry.
    """
    doors, plats = _moving_sectors(md)
    out = set()
    for i, sg in enumerate(md.segs):
        for k, slot in enumerate(('w', 'l')):        # 'm' is never a door face
            nm = slots[i][k]
            if nm and _is_moving_face(md, doors, plats, sg, slot):
                out.add(nm)
    return out


# A switch face is a WALL texture with a button composited on top (SW1STRTN is
# STARTAN plus SW1S0), so shipping it whole puts one fully detailed wall panel
# in the middle of a level of flat ones -- the switch reads as a texturing bug
# rather than as a switch. Ship the BUTTON only: the background goes to the
# texture's own dominant colour, which is what the wall around it is drawn in,
# so the button sits on flat wall exactly like every other surface. Set
# SWITCH_BUTTON_ONLY = False to ship the switch panels whole again.
SWITCH_BUTTON_ONLY = False
# Which patch IS the button is read out of DOOM's own texture definitions, not
# guessed: SW1x and SW2x are the same wall with the up / down button composited
# at the same spot, so the button is the patch whose name differs between the
# pair AT THE SAME OFFSET. (SW1DIRT/SW2DIRT also differ in a base wall strip,
# but at offsets the other one has nothing at, so the offset match drops it.)
# The name rule is only a fallback for a texture with no mate in the list.
SWITCH_PATCH = re.compile(r'^(SW\dS[01]|SW\d_\d|WARN[AB]0)$')


def is_switch(name):
    """DOOM's test (p_switch.c alphSwitchList), via doomspecs."""
    return doomspecs.is_switch(name)


def switch_button(wt, name, tx, w, h):
    """`tx` (column-major) with everything but the button replaced by the
    texture's dominant colour. See SWITCH_BUTTON_ONLY."""
    from collections import Counter
    td = wt.texdefs.get(name.upper())
    if td is None:
        return tx
    mate = wt.texdefs.get((doomspecs.switch_mate(name) or '').upper())
    button = []
    if mate is not None:
        # a texdef's patches are NAMES since 2026-08-30 (wadtex._read_textures:
        # the index only ever meant something in its own file's PNAMES)
        at = {(ox, oy): p.upper() for p, ox, oy in mate[2]}
        button = [(p, ox, oy) for p, ox, oy in td[2]
                  if at.get((ox, oy), p.upper()) != p.upper()]
    if not button:
        button = [p for p in td[2] if SWITCH_PATCH.match(p[0].upper())]
    if not button:
        print(f'    ! {name}: no button patch recognised, shipping it whole')
        return tx
    dom = Counter(px for col in tx for px in col).most_common(1)[0][0]
    out = [[dom] * h for _ in range(w)]
    for (pname, ox, oy) in button:
        pat = wt.get_patch(pname)
        if pat is None:
            continue
        pw, _ph, cols = pat
        for cx in range(pw):
            dx = ox + cx
            if not 0 <= dx < w:
                continue
            for (topdelta, pix) in cols[cx]:
                for k, px in enumerate(pix):
                    dy = oy + topdelta + k
                    if 0 <= dy < h:
                        out[dx][dy] = px
    return out


SCROLL_TAG = '@S'                 # marks the private copy a scrolling wall gets


def tex_base(name):
    """A tagged texid name back to the WAD texture it is a copy of."""
    for tag in (ROLE_TAG, SCROLL_TAG):
        while name and name.endswith(tag):
            name = name[:-len(tag)]
    return name


def _seg_slots(md):
    """Per seg -> (wall_name, low_name, mid_name), mirroring pack_map's
    col_a/col_b/segmid resolution. wall = solid middle / portal upper,
    low = portal lower, mid = the TWO-SIDED middle texture (the see-through
    support struts and fences, r_segs.c R_RenderMaskedSegRange). '-' -> None.

    A seg on the FRONT of a special-48 line (p_spec.c "ANIMATE LINE SPECIALS":
    sides[line->sidenum[0]].textureoffset += FRACUNIT every tic) gets its texture
    name tagged, so it lands on a texid of its own -- E1M7 scrolls BROWN96, which
    41 other sidedefs also use and which must NOT move.

    A seg that draws a MOVING face (see _is_moving_face) gets the same treatment
    with ROLE_TAG, and for the same reason: the engine resolves pixels per
    TEXID, so a door faced with BROWN96 could not be textured without texturing
    every BROWN96 wall in the level -- E1M9's doors are nearly all like that.
    The private copy is what lets doors, lifts and switches keep their pixels
    while the ordinary walls that share their name go flat."""
    scroll = {i for i, ld in enumerate(md.linedefs) if ld.special == 48}
    doors, plats = _moving_sectors(md)
    out = []
    for sg in md.segs:
        ld = md.linedefs[sg.linedef]
        tag = SCROLL_TAG if (sg.linedef in scroll and sg.side == 0) else ''
        fsd, bsd = (ld.right, ld.left) if sg.side == 0 else (ld.left, ld.right)
        fs = md.sidedefs[fsd]
        two = (bsd != NO_SIDEDEF) and bool(ld.flags & ML_TWOSIDED)
        mid = None
        if two:
            wall = fs.upper if fs.upper != '-' else None
            low = fs.lower if fs.lower != '-' else None
            mid = fs.middle if fs.middle != '-' else None
        else:
            wall = fs.middle if fs.middle != '-' else None
            low = None
        pair = []
        for slot, nm in (('w', wall), ('l', low), ('m', mid)):
            if not nm:
                pair.append(None)
                continue
            nm += tag
            if slot != 'm' and not SHIP_ALL_TEXTURES and not is_switch(nm) \
                    and _is_moving_face(md, doors, plats, sg, slot):
                nm += ROLE_TAG
            pair.append(nm)
        out.append(tuple(pair))
    return out


class TexPool:
    """The EPISODE-wide texture store (2026-08-14).

    Before this, pack_map_textures emitted one .tex per level, so a wall used by
    six maps was stored six times: 974 KB across E1 for 109 distinct textures.
    Now every level interns its payloads here and the whole episode ships ONE
    blob, so a texture streamed for E1M1 is already resident when E1M4 asks for
    it (tools/pool_plan.py measures the streaming this saves: 71 %).

    Two phases, which fall out of pack_map.py's existing two passes for free:
      pass 1 (capacities)  -- intern() records the payload, returns 0. Nothing
                              needs real addresses yet, only the table LENGTH.
      finish()             -- lay the blob out and freeze it.
      pass 2 (emit)        -- intern() returns the final offset.
    So the same pack_map_textures call sites do both jobs unchanged.

    Layout, and why:
      [0 .. ix_end)   the column-index arrays, substring-aliased as before.
                      They go FIRST because the engine addresses them with a
                      16-BIT offset off the blob base (texcol.asm tex_setix),
                      so they must sit inside the first 64 KB. They are a few
                      KB, so this is never tight.
      [ix_end .. )    the texture payloads, each padded to a whole 128-byte
                      SECTOR -- that is what lets a single texture be streamed
                      on its own, and it makes a texture's SDRAM home identical
                      to its disk home (read_sectors' tee parks sector n at
                      PRE0_BASE + (n - PRE0_SEC)*128).
    """
    SECTOR = 128

    def __init__(self):
        self._payloads = {}          # payload bytes -> offset (after finish)
        self._ix = {}                # index array bytes -> offset (after finish)
        self.blob = b''
        self.frozen = False

    def intern(self, payload):
        if self.frozen:
            return self._payloads[payload]
        self._payloads.setdefault(payload, 0)
        return 0

    def intern_ix(self, arr):
        if self.frozen:
            return self._ix[arr]
        self._ix.setdefault(arr, 0)
        return 0

    def finish(self):
        # index arrays first, biggest first so the substring aliasing that
        # pack_map_textures used per level keeps working across the episode
        store = bytearray()
        for a in sorted(self._ix, key=len, reverse=True):
            p = bytes(store).find(a)
            if p < 0:
                p = len(store)
                store += a
            self._ix[a] = p
        pad = -len(store) % self.SECTOR
        base = len(store) + pad
        assert base < 0x10000, \
            f'column-index store {base} B >= 64 KB -- tex_setix addresses it ' \
            f'with a 16-bit offset (texcol.asm)'
        body = bytearray()
        for pl in sorted(self._payloads, key=lambda b: (-len(b), b)):
            self._payloads[pl] = base + len(body)
            body += pl + bytes(-len(pl) % self.SECTOR)
        blob = bytes(store) + bytes(pad) + bytes(body)
        # Pad to a whole 1 KB: load_textures drains the blob eight sectors at a
        # time through the 1 KB staging buffer, so a partial last pass would
        # either overrun the buffer or need a tail case in the 6502 loop.
        self.blob = blob + bytes(-len(blob) % 1024)
        self.frozen = True
        return self.blob


def pack_map_textures(md, wt, xpool=None):
    slots = _seg_slots(md)
    used = {n for (wall, low, _mid) in slots for n in (wall, low) if n}
    # Switch faces flip SW1* -> SW2* at run time (p_switch.c
    # P_ChangeSwitchTexture): force every used SW1's mate into the set so the
    # flipped face has pixels + a texid. The mate id rides in textab row 6.
    for name in [n for n in used if is_switch(n)]:
        mate = doomspecs.switch_mate(name)
        if mate and wt.get_texture(mate) is not None:
            used.add(mate)
    # The TWO-SIDED MIDDLE textures come last -- only so that adding them does
    # not renumber every wall texid in a diff. A texture used ONLY as a mid
    # texture is composed MASKED (index 0 = "no patch covered this texel"); one
    # that is also a wall somewhere keeps its opaque form, which is exact for
    # every such case episode 1 has (BROWNGRN, and it has no holes).
    mid_only = sorted({m for (_w, _l, m) in slots if m} - used)
    masked = set(mid_only)
    used = sorted(used) + mid_only                            # deterministic order

    from collections import Counter

    # ---- TEXID ALIAS (2026-08-18, E2/E3): the seg texid is 6 bits and seven
    # E2/E3 maps carry up to 98 distinct textures. Over the 63 rows, the
    # RAREST unprotected textures alias to the visually nearest keeper
    # (dominant PLAYPAL colour distance, height mismatch penalised) -- the
    # same id-sharing the flat-colour rows always did. Switches, scroll walls
    # and role-tagged door/lift copies never alias: they are functional.
    # Masked (two-sided mid) textures only alias among themselves.
    alias = {}
    if len(used) > NONE_SEG_ID:
        freq = Counter()
        for (wall, low, mid) in slots:
            for n in (wall, low, mid):
                if n:
                    freq[n] += 1

        functional = _functional_names(md, slots)

        def _reads_as(n):
            """Does this texture CARRY A MESSAGE -- switch, key colour, door
            slab, EXIT lettering, or a scrolling copy? Those are the surfaces a
            player acts on, so they may neither be aliased away nor painted
            onto an ordinary wall. It is a question about the NAME, not about
            the geometry: `functional` below finds the faces a door actually
            hangs on, which on E2M6 includes plain WOOD1/WOOD3/BROWN1 -- real
            wall textures that merely happen to face a door, and perfectly good
            things for another wall to alias onto."""
            b = tex_base(n)
            return (is_switch(b) or SCROLL_TAG in n or KEY_DOOR_TEX.match(b)
                    or 'DOOR' in b or b == 'EXITSIGN')

        def _protected(n):
            # Functional surfaces never alias: switches (p_switch.c's list),
            # scroll walls, key doors, and every door / lift / track face.
            # The protected set is 45 names at its worst (E2M6) -- see
            # tools/tests/_audit_texalias.py -- so 18+ ids are always left for
            # the ordinary walls the alias is actually meant to merge.
            #   ...and any texture the WAD NAMES as a door face, whether or not
            # a door hangs on it. `functional` above asks the GEOMETRY, so it
            # only sees doors that move; a DOOR3 painted on a plain one-sided
            # wall is decoration to the geometry and was the rarest name on the
            # map, i.e. the alias pass's first victim. Seven such faces were
            # being folded into ordinary walls across episodes 2-3 -- E2M6's
            # DOOR3 (the recess 107 units from the player start, the first
            # thing the level shows you) became GRAY2, E2M2's became AASTINKY.
            # A door that reads as a wall is the one substitution a player
            # always notices, so the name decides it: DOOR3, BIGDOOR*,
            # EXITDOOR, ICKDOOR1, DOORTRAK/DOORSTOP and the key doors all carry
            # DOOR in the name and none of them may alias.
            #   ...and EXITSIGN, for the same reason one step further: it is
            # LETTERING. Protecting the doors above pushed E2M6's exit sign out
            # of the keeper set (it had been one), and E2M2/E2M7/E3M3 were
            # already folding it into STEPTOP -- an exit the player cannot read
            # is worth more than any wall the alias would merge instead.
            return (_reads_as(n) or n.endswith(ROLE_TAG) or n in functional)

        def _dom_h(n):
            t = wt.get_texture(tex_base(n), n in masked)
            if t is None:
                return None
            w0, h0, tx = t
            cols, _w = half_cols(tx, w0, h0)
            hist = Counter(c for c in cols if c)
            return (hist.most_common(1)[0][0] if hist else 0, h0)

        info = {n: _dom_h(n) for n in used}
        pal = wt.playpal

        def _dist(a, b):
            (da, ha), (db, hb) = info[a], info[b]
            ra, rb = pal[da], pal[db]          # wt.playpal: (r, g, b) tuples
            return (sum((x - y) ** 2 for x, y in zip(ra, rb))
                    + (0 if ha == hb else 3000))

        for n in sorted(used, key=lambda x: (freq[x], x)):    # rarest first
            if len(used) - len(alias) <= NONE_SEG_ID:
                break
            if _protected(n) or info[n] is None:
                continue
            cands = [k for k in used
                     if k != n and k not in alias and info[k] is not None
                     and (k in masked) == (n in masked)]
            # ... and nothing may alias ONTO a protected surface either:
            # that is how an ordinary wall ends up painted as a switch the
            # player walks up and presses (E2M6 sent DOOR3 to SW1COMM, right
            # where the level's first door is), as a locked door, as a door
            # slab in a blank wall (E3M4 sent three walls to BIGDOOR5), or --
            # worst -- onto the SCROLL copy, whose pixels slide every tic.
            # They stay keepers, never targets; fall back only if the map
            # offers nothing else at all.
            #   This is _reads_as, the same predicate the protection above
            # is built on -- keeping the two halves as separate hand-kept lists
            # is what let E2M6 paint a STEP5 band with the red EXIT sign, E2M2
            # paint STONE/STONE2 as DOORSTOP and AASTINKY as a DOOR3 slab, and
            # E2M7 paint GRAYPOIS/SHAWN3 as DOOR3. A wall that reads EXIT or
            # DOOR is worse than any wall that merely reads wrong.
            plain = [k for k in cands if not _reads_as(k)]
            cands = plain or cands
            if not cands:
                continue
            alias[n] = min(cands, key=lambda k: _dist(n, k))
        # NO CHAINS. The loop above runs rarest-first and a name may pick a
        # target that is itself aliased further down the list, so the hops
        # compose into something neither step chose: E2M6 sent WOODSKUL and
        # WOODGARG to WOOD4, WOOD4 to STARBR2 and STARBR2 to STARG2, i.e. five
        # brown wooden walls all ended up grey-green. The set of survivors is
        # only known once the loop has finished, so re-point every alias at the
        # nearest one of THOSE.
        if alias:
            keep = [k for k in used if k not in alias and info[k] is not None]
            for n in list(alias):
                c = [k for k in keep if (k in masked) == (n in masked)]
                c = [k for k in c if not _reads_as(k)] or c
                if c:
                    alias[n] = min(c, key=lambda k: _dist(n, k))
        if alias:
            used = [n for n in used if n not in alias]
            print(f'  texid alias ({len(alias)} merged, {len(used)} ids): '
                  + ', '.join(f'{a}>{b}' for a, b in sorted(alias.items())))
    tex_blob = bytearray()
    table = []                                                # (name, addr, w, h, dom)
    name_id = {}
    seen = {}                                                 # pixel blob -> VRAM addr
    colidx = {}                                               # texid -> column indices
    flat_row = {}                                             # dom colour -> texid
    raw = 0
    flat = []
    scroll_ids = []
    for name in used:
        base = tex_base(name)
        t = wt.get_texture(base, name in masked)
        if t is None:
            continue
        w, h, tx = t
        if SWITCH_BUTTON_ONLY and is_switch(base):
            tx = switch_button(wt, base, tx, w, h)            # button, not panel
        cols, w = half_cols(tx, w, h)                         # column-major, 2:1 H
        cols, w = fold_width(cols, w, h)                      # lossless period fold
        # Representative PLAYPAL index for the flat fill. Index 0 is excluded:
        # it is pure black in PLAYPAL *and* what get_texture leaves where no
        # patch covered, so it wins the count on dark textures (DOORTRAK,
        # EXITDOOR, TEKWALL4/5) and would paint those walls invisible. The most
        # common NON-black index still reads as "dark metal", and 0 survives
        # only for a texture that is nothing else.
        hist = Counter(c for c in cols if c)
        dom = hist.most_common(1)[0][0] if hist else 0

        textured = SHIP_ALL_TEXTURES or is_switch(base) or name.endswith(ROLE_TAG)
        if not textured:
            # FLAT (see SHIP_ALL_TEXTURES). A flat wall is nothing but its
            # dominant colour, so every dropped texture of the SAME colour can
            # share one row -- which matters: the seg texid is six bits, and
            # merging is what buys back the ids the door / lift copies spend.
            if dom not in flat_row:
                flat_row[dom] = len(table)
                table.append((f'flat{dom:02X}', 0, 1, 0, dom))
            name_id[name] = flat_row[dom]
            flat.append(base)
            continue

        name_id[name] = len(table)
        raw += len(cols)
        if name.endswith(ROLE_TAG + ROLE_TAG):                # defensive: one copy
            raise AssertionError(f'{name}: role tag applied twice')
        if SCROLL_TAG in name:
            # Stored TWICE end to end. update_scroll walks the base address
            # forward one column per step, so the rightmost column of a wall
            # reads up to (w-1) columns past it -- inside the copy, never into
            # the next texture. Costs w*h extra VRAM, and nothing per frame.
            # That sliding base is why this one is NOT column-deduped: the
            # index array is fixed but the base moves, so the only mapping that
            # survives is the identity one -- i.e. exactly what it does today.
            scroll_ids.append(len(table))
            body, _w, stride = _payload(cols, w, h, name in masked)
            pool, idx = bytearray(body + body), bytes(range(w))
        else:
            pool, idx = dedup_columns(*_payload(cols, w, h, name in masked))
        if xpool is not None:                                 # EPISODE pool: the
            addr = xpool.intern(bytes(pool))                  #   blob is shared,
            colidx[len(table)] = idx                          #   so the offset
            table.append((name, addr, w, h, dom))             #   comes from there
            continue
        addr = seen.get(bytes(pool))                          # byte-identical texture
        if addr is None:                                      #   -> alias the pixels
            # B2 (docs/VRAM-PLAN.md par.5): the textab carries the texture's
            # FILE OFFSET (texix header + pixel position), not a VRAM address
            # -- pixels live in SDRAM and tex_fget copies them into the VRAM
            # arena on first resolve. Contract: tools/_verify_arena.py.
            addr = TEXIX_RESERVE + len(tex_blob)
            seen[bytes(pool)] = addr
            tex_blob += pool
        colidx[len(table)] = idx
        table.append((name, addr, w, h, dom))
    for a in alias:                      # aliased names share the keeper's id;
        b, hops = a, set()               # chains resolve transitively (A>B may
        while b in alias and b not in hops:      # precede B>C in rarity order)
            hops.add(b)
            b = alias[b]
        if b in name_id:
            name_id[a] = name_id[b]
    if raw:
        print(f'  dedup: {raw} -> {len(tex_blob)} B '
              f'({100 - 100 * len(tex_blob) // raw}% saved)')
    ntex = sum(1 for t in table if t[3])
    print(f'  {ntex} textured (doors/lifts/switches) + {len(table) - ntex} flat '
          f'colour rows = {len(table)} texids, {len(set(flat))} wall textures '
          f'flattened  [{", ".join(sorted(t[0] for t in table if t[3]))}]')
    # A seg texid is SIX BITS with $3F reserved for "no texture", so ids 0..62
    # are usable -- 63 rows, not 62. (This assert read `< NONE_SEG_ID` and so
    # gave away the last row; E1M3 is exactly 63 once its struts are in.)
    assert len(table) <= NONE_SEG_ID, \
        f'{len(table)} texids > {NONE_SEG_ID}: the seg texid field is 6 bits ' \
        f'(0..{NONE_SEG_ID - 1}, ${NONE_SEG_ID:02X} = none)'

    # switch mate ids: table entry grows to (name, addr, w, h, dom, mate)
    # (mate = texid of the SW2 partner, $FF = not a switch face)
    table = [t + (name_id.get(doomspecs.switch_mate(t[0]) or '', 0xFF),)
             for t in table]

    # texture table
    tab = bytearray(struct.pack('<H', len(table)))
    for (name, a, w, h, dom, _mate) in table:
        wlog2 = w.bit_length() - 1                            # widths are pow2
        tab += struct.pack('<HBHHBB8s', a & 0xFFFF, (a >> 16) & 0xFF, w, h, wlog2, dom,
                           name.encode('ascii', 'replace')[:8].ljust(8, b'\x00'))

    # column index arrays (dedup_columns). One blob, streamed to TEXIX_BASE in
    # base RAM -- NOT VRAM, the 6502 has to read it:
    #     +0        u8  texture count
    #     +1        u8  pad (keeps the offset table word aligned)
    #     +2        u16 offset of texid n's array, from the blob start
    #     ...       the arrays, one byte per column, w bytes per texture
    # A flat row (h == 0) has no pixels and no array; its offset is 0 and the
    # engine never reads it, because rs_wtexid is $FF for those segs.
    nt = len(table)
    if xpool is not None:
        # POOLED (2026-08-14): the arrays live ONCE in the shared blob and the
        # per-texid OFFSET rides in the map's textab (MAP_TEXIXLO/HI) instead of
        # in a header at the front of the blob -- there is no per-level front
        # any more. tex_setix then reads two bytes and adds tex_sdram, which is
        # also one indirect read less per seg than the header walk it replaces.
        texix = [xpool.intern_ix(bytes(colidx[i])) if colidx.get(i) else 0
                 for i in range(nt)]
        tex_blob = bytearray()
    else:
        hdr = bytearray(struct.pack('<BB', nt, 0)) + bytearray(2 * nt)
    # The arrays ALIAS (2026-08-03, the full-texture set blew the 2 KB slot):
    # tex_setix's reader takes exactly w bytes at the offset and nothing says
    # two offsets cannot overlap, so any array that appears as a SUBSTRING of
    # the store reuses those bytes. Half the arrays are identity prefixes of
    # one another, so this is 40-50% off (E1M2 2993 -> 1488 B) for free.
        store = bytearray()
        for i in sorted((i for i in range(nt) if colidx.get(i)),
                        key=lambda i: len(colidx[i]), reverse=True):
            a = bytes(colidx[i])
            p = bytes(store).find(a)
            if p < 0:
                p = len(store)
                store += a
            struct.pack_into('<H', hdr, 2 + 2 * i, len(hdr) + p)
        texix = hdr + store

    # per-seg texture ids (index-aligned with pack_map's segs). segmid is the
    # THIRD slot -- the two-sided middle texture -- and it is a full byte
    # ($FF = none), not a 6-bit field: it rides in MAP_SEGMID, not in the seg
    # record, which has no room left.
    segtex = bytearray()
    segmid = bytearray()
    for (wall, low, mid) in slots:
        segtex += bytes([name_id.get(wall, NONE_ID), name_id.get(low, NONE_ID)])
        segmid += bytes([name_id.get(mid, NONE_ID)])

    return tex_blob, tab, segtex, table, scroll_ids, texix, segmid


def write_playpal(wt, out_dir=None):
    """playpal.bin: the FOUR palettes the engine installs, shared by all maps.

    DOOM's PLAYPAL lump is FOURTEEN 768-byte palettes, not one: slot 0 is
    normal, 1..8 are the damage red shifts, 9..12 the item-pickup gold ones and
    13 the radiation-suit green (st_stuff.c ST_doPaletteStuff picks one and
    I_SetPalette installs it). VBXE holds four at once (VBXE_PSEL 0..3) and the
    XDL selects which the overlay uses, so a flash costs ONE byte per frame
    instead of a 768-byte upload -- but only four slots fit, so PAL_SLOTS names
    the four DOOM sends most often. The WAD's own bytes: no tint maths here.

    THIS IS THE ONLY WRITER. pack_map.py used to write its own single-palette
    version of this file, and whichever tool ran last decided what shipped --
    with pack_map last, PAL_COUNT came out 1, palettes 1..3 were never uploaded
    to VBXE, and every item pickup flashed whatever garbage the hardware held.

    It is the IWAD's PLAYPAL and not the merged view's (2026-08-16): a layered
    WAD with a palette of its own (heretic.wad, hexen.wad, a total conversion)
    would otherwise ship ITS palette under DOOM's status bar, weapons and
    monsters. wadtex.py remaps that file's graphics into this palette instead
    -- see the WadTextures docstring.
    """
    raw = wt.playpal_lump
    playpal = bytearray()
    for slot in PAL_SLOTS:
        playpal += raw[slot * 768:(slot + 1) * 768]
    out = os.path.join(out_dir or OUT_DIR, 'playpal.bin')
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, 'wb') as f:
        f.write(playpal)
    return playpal


def main():
    names = [a for a in sys.argv[1:] if not a.startswith('--')] or ['E1M1']
    wad = Wad(DEFAULT_WAD)
    wt = WadTextures(wad)
    os.makedirs(OUT_DIR, exist_ok=True)

    playpal = write_playpal(wt)

    for nm in names:
        md = wad.load_map(nm)
        pool, tab, segtex, table, scroll_ids, texix, segmid = \
            pack_map_textures(md, wt)
        assert len(texix) <= TEXIX_RESERVE, \
            f'{nm}: column index blob {len(texix)} B > TEXIX_RESERVE ' \
            f'{TEXIX_RESERVE} -- with RUN_TEXTURES that reserve is FILE space ' \
            f'and can simply grow; without it, it is base RAM and has to be ' \
            f'raised in memory_map.inc TEXIX_MAX as well'
        blob = bytes(texix) + bytes(TEXIX_RESERVE - len(texix)) + bytes(pool)
        for ext, data in (('tex', blob), ('textab', tab), ('segtex', segtex),
                          ('segmid', segmid), ('texix', texix)):
            with open(os.path.join(OUT_DIR, f'{nm}.{ext}'), 'wb') as f:
                f.write(data)
        end = TEX_VRAM_BASE + len(blob)
        print(f'{nm}: {len(table)} textures, {len(pool)} B ({len(pool)/1024:.1f} KB) '
              f'VRAM ${TEX_POOL_BASE:06X}..${end:06X}  | segtex {len(segtex)} B '
              f'({len(segtex)//2} segs) | textab {len(tab)} B | texix {len(texix)} B'
              + (f' | scroll texids {scroll_ids}' if scroll_ids else ''))
    print(f'playpal.bin: {len(playpal)} B = PLAYPAL slots {list(PAL_SLOTS)} '
          f'(normal, red x2, gold)  ->  {OUT_DIR}')


if __name__ == '__main__':
    main()
