#!/usr/bin/env python3
"""Pack a map's THINGS (items, decorations, monsters) into the form the 6502
engine renders billboards from. The asm side is sprites.asm; the Python
reference/spec is render_tex.py + wadthings.py (see docs/THINGS.md).

Three outputs per map, into build/assets/things/:

  {map}.spr     the sprite pixel file. B1 (docs/VRAM-PLAN.md par.5): it never
                preloads into VRAM -- it sits in Rapidus SDRAM (the level
                cache tee) and spr_fget copies a FRAME into the VRAM arena
                above the level's textures on first use. Frames tile the file
                back to back; every column is stored CROPPED (T4): only its
                [first..last] opaque texels, located by the .sprcol tables --
                a screen column is still one blit (SRC = arena base + off[x],
                SRC_STEPY = 1), spr_one just intersects the span with
                [top, top+len). Interior transparent texels stay: index 0,
                skipped by BLT_BSTENCIL; DOOM sprites use 0 as real black, so
                opaque 0 remaps to the darkest non-zero PLAYPAL entry. (DOOM
                is the prior art twice over: column_t posts are the crop --
                r_defs.h:287 -- and PU_CACHE is the arena, r_things.c:408.)
                Contracts: tools/_verify_sprcrop.py + tools/_verify_arena.py.

  {map}.sprcol  ONE stream into Rapidus SRAM bank $01 at SPRCOL_EXT ($9400):
                  +$0000  the T4 coltab blocks, packed back to back
                          (w x {u16 off, u8 top, u8 len} per frame)
                  +$6000  FTAB (lands at $01:F400): NFRAMES_MAX x
                          {u24 file_off, u16 size, u16 coltab addr, pad}
                A row carries its FRAME ID in byte 0 (bytes 1-2 spare) and
                the FTAB says everything else; FARENA ($01:FC00, cleared at
                level load) holds the frame's arena address, 0 = not there.
                off is frame-relative, top/len are texels; len 0 = fully
                transparent column, no blit at all.

  {map}.things  RAM blob, loaded at THINGS_BASE ($B000) AFTER the texture/sprite
                streaming has finished with the staging buffer there:
                  +0  u16 n_things
                  +2  u16 n_ss                 subsector count
                  +4  u8  n_sprites
                  +5  u16 p_ss                 6502 addr: per-subsector prefix
                  +7  u16 p_things             6502 addr: thing array
                  +9  u16 p_sprtab             6502 addr: sprite table
                  +16 ss prefix   (n_ss+1 bytes) things of subsector s are
                                  [prefix[s], prefix[s+1]) -- things are sorted
                                  by subsector, so one byte per subsector is
                                  enough (n_things <= 255).
                      things      n * 8: i16 x, i16 y, i16 z (sprite anchor,
                                  = sector floor, or ceiling-height for hung),
                                  u8 sprite id, u8 flags (bit0 = can be picked
                                  up, bit1 = blocks the player)
                      sprtab      n_sprites * 8: u8 frame id, 2 spare, u8 w,
                                  u8 h, i8 leftoffset, u8 topoffset, pad

Usage: python pack_things.py [E1M1 ...] [--skill N]   (default skill 2)
"""
import math
import os
import re
import struct
import sys

import doomspecs
import doomstates
import pack_los
from wadlib import Wad, DEFAULT_WAD, NO_SIDEDEF, ML_TWOSIDED
from wadtex import WadTextures
from wadthings import (Sprites, map_things, MOBJ, PICKUP, C_OBSTACLE,
                       C_MONSTER, C_DECOR)

F_STAY, F_USE, F_DOOR = 0x8000, 0x4000, 0x2000
F_ONCE, F_DSTAY, F_TELE, F_DCLOSE = 0x1000, 0x0800, 0x0400, 0x0200
# F_ONCE has a SECOND job on a USE record: it is P_ChangeSwitchTexture's
# `useAgain` argument, inverted. doors.asm sw_swap reads it as "S1 -- the button
# stays pressed"; without it the face flips back BUTTONTIME later, which is what
# a p_switch.c BUTTON (42/43/45/60..70) does and an S1 switch does not. Every
# S1 entry below therefore carries F_ONCE even where F_STAY already spends the
# fired-bitmap bit for it (mv_sndst) -- the bit is what the switch FACE reads.
F_GUN = 0x0100                               # b8: a BULLET fires it, not USE and
                                             # not a walkover (doors.asm gun_match)
# Floor kinds (dst formula, from linuxdoom p_floor.c/p_plats.c):
#   1 min neighbour floor        (lowerFloorToLowest / plat low point)
#   2 max neighbour floor + 8    (turboLower; also the old W1 approximation)
#   3 next HIGHER neighbour floor (raiseFloorToNearest / raiseToNearestAndChange)
#   4 min neighbour ceiling      (raiseFloor), capped at the own ceiling
#   8 own floor + a FIXED amount (raiseAndChange / raiseFloor24) -- RAISE_BY
#   6 donut                      (EV_DoDonut) -- two records, ring then pillar
#   5 stair chain                (EV_BuildStairs build8) -- ONE RECORD PER
#     STEP, not one per tagged sector: _build_stairs() walks the chain and
#     each step gets its own target. mv_start finishes a raise on the spot,
#     so check_triggers/switch_match fire the whole flight in one scan.
# NOTE kinds 3/4/5 RAISE: update_movers only slides downward, so a raise
# lands on its first step -- the floor snaps to the target. Functional, not
# smooth (DOOM's build8 creeps up at FLOORSPEED/4).
# p_plats.c:184 raiseToNearestAndChange -- the platform that comes up OUT OF THE
# NUKAGE takes the floor of the sector on the line's FRONT side, and its damage
# stops ("NO MORE DAMAGE, IF APPLICABLE", sec->special = 0). Without it the lift
# rises wearing slime and still burns you, which is what it looked like in E1M3
# at (-1115,-792) (2026-08-07). Five lines in episode 1: E1M3 x2, E1M5, E1M7,
# E1M9 -- every one of them lifting a NUKAGE3 sector.
CHANGE_SPECS = {20, 22, 47, 68, 95,
                14,   # S1 plat raise 32 AND CHANGE (E2M1's slime step)
                37,   # W1 floor lower AND CHANGE (E2M1/E3 nukage rooms; DOOM
                      # models the change off a NUMERIC-model sector, the
                      # port's front-side rule is the same reduction 20/22 use
                59}   # W1 raise 24 AND CHANGE (E2M2)

# ---- SPEED (p_floor.c / p_plats.c) -----------------------------------------
# The port has ONE speed per direction: mv_step slides DOWN at PLATSPEED*4
# (140 units/s, p_plats.c downWaitUpStay) and mv_raise climbs at FLOORSPEED
# (35 units/s). Those are DOOM's own numbers for the FAST movers and 4x too
# quick for everything else -- E1M8's 666 wall dropped in 2.5 s where DOOM
# takes 9.8, and its staircase built in 3.2 s where DOOM takes 12.8. DOOM's
# slowness there is the effect, not an accident.
# So each record carries a SHIFT: the frame's Q8 step is halved this many
# times. Two bits cover every speed in episodes 1-3 exactly:
#   down  0 = PLATSPEED*4 / FLOORSPEED*4 (140)   2 = FLOORSPEED (35)
#   up    0 = FLOORSPEED (35)   1 = PLATSPEED/2 (17.5)   2 = FLOORSPEED/4 (8.75)
SPEED = {
    19: 2, 38: 2, 23: 2, 82: 2, 37: 2, 102: 2,   # lowerFloor(ToLowest) = FLOORSPEED
    20: 1, 22: 1, 14: 1,                         # raiseToNearestAndChange = PLATSPEED/2
    7: 2, 8: 2,                                  # EV_BuildStairs(build8) = FLOORSPEED/4
    87: 2,                                       # perpetualRaise = PLATSPEED (35)
}                                                # 9 (the donut) is per-HALF: see _donut
# ---- PER-MAP overrides of the above (2026-08-25) ---------------------------
# The port's PLAYER is the odd one out in the whole timing model: SPD is 24
# units per FRAME (memory_map.inc), not per unit of time, so his real speed is
# 24*fps -- 240 u/s running at 5 fps, against DOOM's 583. Every mover above is
# DOOM-exact (measured: mv_step returns 35 u/s at any frame rate), which means
# every mover is effectively ~2.4x faster than DOOM RELATIVE TO THE MAN, and a
# crossing DOOM gives you plenty of time for can become impossible.
# E3M1 is the one that actually bites. Six W1 37 lines drop a chain of stepping
# stones 40 units to the nukage below, and ONE of the six -- linedef 52, tag 4,
# a 286-unit slab -- takes 1.14 s to go while the runner covers 274. He misses
# it by TWELVE UNITS, every time, on the level's main route. The other five
# clear it, so this is not "the port is too slow", it is one slab on one map.
# Halving that map's 37s (17.5 u/s) buys 549 units running and still leaves 274
# WALKING, so the crossing keeps DOOM's own rule that you must run it. The whole
# chain moves together on purpose: slowing only linedef 52 would make one stone
# in six sink at a different rate, which reads as a bug.
# NOT APPLIED ELSEWHERE. The same arithmetic flags E2M1/E2M6/E3M6/E3M7, but
# there the "distance" is the tagged sector's own diagonal (353..1024 units) and
# those are big floors that drop to open a way, not stones you sprint across --
# the metric over-reports and there is no report from play. Scope one when one
# shows up.
# THE REAL FIX is a time-scaled PLR_STEP: it needs move_player's halfway
# collision probe to subdivide (it assumes step <= 24), and simply running
# faster trades the miss for visible teleporting -- 120 units between two drawn
# frames at 5 fps instead of 48. Delete this table the day that lands.
SPEED_MAP = {
    'E3M1': {37: 3},         # the stepping stones -- see above
}
SPEED_BOSS = 2               # A_BossDeath's tag 666 is lowerFloorToLowest

# ---- RAISE_BY: kind 8, the raises that go up a FIXED number of units --------
# p_plats.c:197 raiseAndChange and p_floor.c:347 raiseFloor24 both set
#     floordestheight = sec->floorheight + amount
# and never look at a neighbour at all. Folding them into kind 3 (next HIGHER
# neighbour) reads as a harmless approximation and is not one: when the tagged
# sector has no higher neighbour, kind 3 returns the sector's OWN floor and the
# record moves nothing. Five of the eleven such records in episodes 1-3 were
# exactly that -- dead on arrival.
# The one that got reported: E2M1's switch at (1272,-283), linedef 382 special
# 14 tag 17. Sector 1 is a 16x64 slab sitting INSIDE sector 0, both at floor
# -64, and sector 0 is its only neighbour. DOOM lifts it to -32; that 32-unit
# step is what uncovers the SW1SLAD lower textures on linedefs 379 and 381 --
# the two switches that are the point of the room. Under kind 3 the switch
# clicked, sector 1 "rose" to -64, and no wall ever came out.
# The other four: E2M2's three tag-15/17/19 slabs (special 59) and E2M4's tag
# 28 (special 58). Two more records moved but to the wrong height (E2M2 tag 21
# went to 72 instead of 64, E2M4 tag 8/17 to -48 instead of -56).
RAISE_BY = {14: 32, 58: 24, 59: 24}

SPEC = {                     # special: (flags, floor kind)
    88: (0, 1),                                  # WR plat DWU (E1M1 lift)
    36: (F_STAY, 2), 19: (F_STAY, 2), 38: (F_STAY, 2),  # W1 lower floor
    62: (F_USE, 1),                              # SR plat DWU (switch lift)
    21: (F_USE | F_ONCE, 1),                     # S1 plat DWU
    23: (F_USE | F_ONCE | F_STAY, 1),            # S1 floor lower to lowest, stays
                                                 #   (E1M8 start switch; STAY also
                                                 #    spends a fired-bitmap bit)
    82: (F_STAY, 1),                             # WR floor lower to lowest (stays,
                                                 #   so the spent bit is a no-op)
    70: (F_USE | F_STAY, 2),                     # SR turbo lower (8 above highest)
    98: (F_STAY, 2),                             # WR turbo lower
    18: (F_USE | F_ONCE | F_STAY, 3),            # S1 floor raise to next higher
    20: (F_USE | F_ONCE | F_STAY, 3),            # S1 plat raise AND CHANGE
    22: (F_STAY, 3),                             # W1 plat raise AND CHANGE
    5:  (F_STAY, 4),                             # W1 floor raise to lowest ceiling
    91: (F_STAY, 4),                             # WR floor raise (stays at top)
    8:  (F_STAY, 5),                             # W1 stairs raise 8 (E1M3: the
                                                 #   flight up to the exit door)
    7:  (F_USE | F_ONCE | F_STAY, 5),            # S1 stairs raise 8 (E1M8, E2M8)
    97: (F_TELE, 0),                             # WR teleport (E1M5/E1M8/E1M9)
    9:  (F_USE | F_ONCE | F_STAY, 6),            # S1 donut: pillar down, ring
                                                 #   up (E1M2's one, linedef 604)
    # ---- E2 (2026-08-18, first E2 maps; doomspecs.FLOORS carries them too) --
    37: (F_STAY, 1),                             # W1 floor lower to lowest AND
                                                 #   CHANGE (CHANGE_SPECS)
    102: (F_USE | F_ONCE | F_STAY, 2),           # S1 floor lower to highest
                                                 #   neighbour (kind 2 = +8
                                                 #   turbo approx, like 19/38)
    14: (F_USE | F_ONCE | F_STAY, 8),            # S1 plat raise 32 AND CHANGE
                                                 #   (RAISE_BY: +32 from its own
                                                 #   floor -- E2M1's two-switch
                                                 #   slab has no higher
                                                 #   neighbour to aim at)
    # ---- the full E2+E3 sweep (2026-08-18) ----------------------------------
    30: (F_STAY, 3),                             # W1 raise by SHORTEST LOWER
                                                 #   texture -> kind 3 approx
                                                 #   (E2M2/E3M2 nukage steps)
    56: (F_STAY, 4),                             # W1 crush-raise -> plain
                                                 #   raise to lowest ceiling
                                                 #   (no crush machinery)
    58: (F_STAY, 8),                             # W1 raise 24 (RAISE_BY)
    59: (F_STAY, 8),                             # W1 raise 24 AND CHANGE
    87: (0, 1),                                  # WR perpetual platform ->
                                                 #   behaves as the WR lift 88
                                                 #   (89 STOP: nothing moves
                                                 #   perpetually, so unneeded)
    24: (F_GUN | F_STAY, 4),                     # G1 raise floor on IMPACT
                                                 #   (E2M4), like 46's gun path
    39: (F_TELE | F_ONCE, 0),                    # W1 teleport (E3M6/E3M9) --
                                                 #   the once flavour of 97
    40: (F_DOOR | F_ONCE | F_DSTAY, 0),          # W1 ceiling raise to highest
                                                 #   -> door-open-stays approx
                                                 #   (E3M5; doomspecs TAG_DOOR
                                                 #   carries it so the door
                                                 #   records exist)
    16: (F_DOOR | F_DCLOSE | F_ONCE, 0),         # W1 door close 30 s, then open
    76: (F_DOOR | F_DCLOSE, 0),                  # WR door close 30 s, then open
                                                 #   (E1M6 has all three)
    103: (F_USE | F_DOOR | F_ONCE | F_DSTAY, 0),  # S1 door open, stays
    29: (F_USE | F_DOOR | F_ONCE, 0),            # S1 door raise
    63: (F_USE | F_DOOR, 0),                     # SR door raise
    2: (F_DOOR | F_ONCE | F_DSTAY, 0),           # W1 door open, stays
    90: (F_DOOR, 0),                             # WR door raise
    86: (F_DOOR | F_DSTAY, 0),                   # WR door open, stays
    # p_spec.c case 35 "Lights Very Dark": EV_LightTurnOn(line, 35) drops every
    # sector with the line's tag to light level 35. E1M3's three W1 lines at the
    # blue key (1017-1019, tag 13) are the only light specials in episode 1 --
    # the room goes dark the moment you take the card. Encoded as F_DOOR|F_STAY,
    # a pair the floor and door kinds can never both set, so trig_fire tells it
    # apart with no new flag bit (the word has none left); the LEVEL rides in
    # the record's dst field.
    35: (F_DOOR | F_STAY | F_ONCE, 7),           # W1 lights very dark (35)
    13: (F_DOOR | F_STAY | F_ONCE, 7),           # W1 lights to 255 (E2M2);
                                                 #   dst baked per special
    104: (F_DOOR | F_STAY | F_ONCE, 7),          # W1 lights to darkest
                                                 #   neighbour (E2M5/E3M9)
    46: (F_GUN | F_DOOR | F_DSTAY, 0),           # GR door open on IMPACT, stays
                                                 #   (p_spec.c P_ShootSpecialLine
                                                 #    case 46 = EV_DoDoor(open)).
                                                 #   E1M2's secret door, and the
                                                 #   only gun line in episode 1
    # ---- CRUSHERS (2026-08-29, p_ceilng.c EV_DoCeiling) --------------------
    # Door records again -- the tagged sectors already carry one (pack_map
    # _doors, LOCK bit3), and the port's only ceiling machinery is the door
    # mover. What tells trig_fire this is a crusher and not a door is the DST
    # field, which a door record has never used ("MAP_DOORS has the height"):
    # CRUSH_SLOW/FAST start it, CRUSH_HALT is EV_CeilingCrushStop. All three
    # are WR -- no F_ONCE, no fired bit, cross them as often as you like.
    73: (F_DOOR, 0),                             # WR crushAndRaise (CEILSPEED)
    77: (F_DOOR, 0),                             # WR fastCrushAndRaise (x2)
    74: (F_DOOR, 0),                             # WR stop the crusher
}
# A door record's dst: 0 = an ordinary door, the rest are p_ceilng.c's.
CRUSH_SLOW, CRUSH_FAST, CRUSH_HALT = 1, 2, 3


_HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'things')

# ---- the per-level VRAM pool ($018000-$070000, 352 KB) ----------------------
# Since B1 only the TEXTURES preload into it; the remainder above them is the
# sprite ARENA (spr_fget), so no sprite address is baked anywhere any more --
# the blob is pure file-relative data and the arena bounds are the engine's
# per-level variables (ar_base/ar_top, from LVL_TEXCH).
POOL_BASE = 0x018000          # = pack_textures.TEX_VRAM_BASE
SPR_VRAM_TOP = 0x070000       # the pool's ceiling: TEX8, the 8x column-expander
                              # scratch, then the active-weapon slot ($071000)
TEX_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures')


# ---- B1 sprite ARENA (docs/VRAM-PLAN.md par.5; contract
#      tools/_verify_arena.py) --------------------------------------------------
# Sprite pixels no longer preload into VRAM at all: the .spr file (CONTIGUOUS
# again -- A2's region spill died here) lives in Rapidus SDRAM via the level
# cache tee, and spr_fget copies a FRAME into the VRAM arena above the level's
# textures on first use. A row therefore carries a FRAME ID, not a VRAM
# address; everything a frame is -- where in the file, how big, which coltab
# -- lives in the FTAB half of the .sprcol stream.

NFRAMES_MAX = 255                      # the id is a byte; $FF stays unused
FTAB_OFF = 0xE000                      # FTAB rides at .sprcol + $A000 -> lands
                                       #   at $01:F400 (memory_map FTAB_EXT)

def _mm_equ(name):
    """an $XXXX equ out of memory_map.inc -- the engine's side of the contract"""
    import re as _re
    _p = os.path.join(os.path.dirname(_HERE), 'memory_map.inc')
    m = _re.search(r'^%s\s+equ\s+\$([0-9A-Fa-f]+)' % name,
                   open(_p, encoding='latin-1').read(), _re.M)
    assert m, 'memory_map.inc has no %s' % name
    return int(m.group(1), 16)


# THE CONTRACT. FTAB_OFF is where THIS file puts the FTAB in the blob; FTAB_EXT
# is where the ENGINE reads it. They are the same number seen from two sides and
# nothing else checks them -- on 2026-08-21 they drifted by $1000 while the run
# was being sized, and the symptom was every sprite in the game drawn as
# vertical bands of noise (the FTAB read garbage, so every coltab pointer was
# garbage) with the walls and the status bar perfectly fine. Cheap to assert.
assert FTAB_OFF == _mm_equ('FTAB_EXT') - _mm_equ('SPRCOL_EXT'), (
    'FTAB_OFF (0x%04X) != FTAB_EXT - SPRCOL_EXT (0x%04X - 0x%04X) -- the packer '
    'and the engine disagree about where the FTAB is'
    % (FTAB_OFF, _mm_equ('FTAB_EXT'), _mm_equ('SPRCOL_EXT')))
FTAB_ROW = 8                           # u24 file_off, u16 size, u16 coltab, pad
THINGS_BASE = 0xC000          # 6502 RAM: sprite code, then the wall-blit setup block
THINGS_MAX = 0x0F80           # $C000..$CF7F under the OS ROM: 31 whole SECTORS.
                              # load_things streams the full slot (THG_SECTORS x
                              # 128 B) including the zero padding, so the limit
                              # is a sector-rounded bound, not the blob's own
                              # size, and the wall above it is BTNUPD_BASE
                              # ($CFC8, memory_map.inc). ram_map.py derives the
                              # RESERVED range from THG_SECTORS, so growth past
                              # this fails the BUILD, never the game. History:
                              # $C00 -> $CE7F (door-close records) -> $CEC9
                              # (fireball burst; switch_match then sat at $CECA
                              # and the slot PADDING wiped it -- the 2026-08-04
                              # freeze) -> switch_match moved to $8120 and the
                              # missile sprites (proj.asm) pushed E1M6 to 3821.
                              # 2026-08-29: this is PIECE 1 only -- header,
                              # subsector prefix, things, sprite table.
THINGS_SECT = THINGS_MAX // 128        # 31 -- load_things' first read
THINGS2_BASE = 0xDA00         # PIECE 2: triggers, raise-and-change, teleport
THINGS2_MAX = 0x0780          #   destinations, spawnhealth. $DA00..$E17F, the
                              # map HIGH region's unused tail (pack_map.HI_LIMIT
                              # stops at $DA00 to hand it over) and the last
                              # base RAM in the machine that is neither hot nor
                              # behind a Rapidus bank. It exists because the
                              # crushers' trigger records (E2M2: 10 WR lines x 3
                              # tagged sectors) do not fit the 31 sectors above,
                              # on a map that was ALREADY dropping decorations.
                              # Ordinary RAM, absolute addressing, same speed.
# Skill the engine ships with: 2 = "Hey, not too rough" (skills 1 and 2 share the
# MTF_EASY flag). E1M1 then has 4 monsters instead of 29 on UV -- item and
# decoration counts barely change.
# One bit each in movers.asm's FIRED bitmap (mv_used), so this MUST match
# MV_TRIGS in memory_map.inc -- the engine silently treats anything past the
# bitmap as repeatable.
TRIG_MAX = 192

SKILL = 2
# Bonus ids, mirrored by the BN_* tables in sprites.asm. Keyed by doomednum; the
# id travels in the SPRITE table (one pickup type = one sprite), so the engine
# only needs the sprite id it already has when the player touches a thing.
BONUS = {
    2011: 1,   # stimpack        2012: medikit     2014: health bonus
    2012: 2, 2014: 3, 2013: 4,   # 2013: soulsphere
    2015: 5, 2018: 6, 2019: 7,   # armor bonus / green / blue armour
    2007: 8, 2048: 9,            # clip / box of bullets
    2008: 10, 2049: 11,          # 4 shells / box of shells
    2010: 12, 2046: 13,          # rocket / box of rockets
    2047: 14, 17: 15,            # cell / cell pack
    2001: 16, 2002: 17, 2003: 18, 2004: 19, 2006: 20, 2005: 21,   # weapons
    # keys: cards and skulls open the same locks (the same PS_KEYS bit --
    # give_bonus's key branch reads BN_AMT alone), but they are SEPARATE bonus
    # ids since 2026-08-31 so the E2/E3 skulls say "skull key" and not
    # "keycard" (d_englsh.h GOTBLUESKUL vs GOTBLUECARD; ids 32-34 carry the
    # same 1/2/4 in BN_AMT).
    5: 22, 6: 23, 13: 24,                                         # keycards
    40: 32, 39: 33, 38: 34,                                       # skull keys
    # 25..31 the POWERS + the backpack (2026-08-01, powerups.asm). 2022/2023 are
    # not reachable in episode 1 at SKILL 2, but the id costs nothing and a UV
    # build then needs no change here. 83 (megasphere) is DOOM II only.
    8: 25,                       # backpack
    2024: 26, 2025: 27,          # blur sphere / radiation suit
    2026: 28, 2045: 29,          # computer map / light-amp visor (taken, no-ops)
    2022: 30, 2023: 31,          # invulnerability / berserk
}
NF_SUBSECTOR = 0x8000
# SHOOTABLE things -> info.c spawnhealth, keyed by doomednum. These are DOOM's own
# numbers, verbatim from _pomocne/_doomsrc/info.c; 0/absent = not shootable, which
# is what the engine tests, so decorations and pickups need no entry.
# u16 in the blob on purpose: BRUISER is 1000, so a byte would silently make the
# barons of E1M8 four times cheaper to kill.
# Straight out of info.c's spawnhealth (via doomstates), not retyped: this used
# to be a hand-written dict and it is exactly the sort of table that drifts.
# Every MF_SHOOTABLE mobj is included, so a later episode needs no change here.
MONSTER_HP = {num: doomstates.doom().spawnhealth(num)
              for num, e in doomstates.doom().mobj.items()
              if 'MF_SHOOTABLE' in e.get('flags', '') and doomstates.doom().spawnhealth(num)}

# --- monster "kind": one byte per SPRITE, riding in the sprtab row's last byte.
# That byte already carries the BONUS id, but a sprite is either a pickup or a
# monster and never both (asserted below), so the two share it -- the readers
# disambiguate by context (sprites.asm looks at it only for a thing flagged
# pickable, enemy.asm only for one with health). Zero blob growth, which is what
# this had to be: E1M6's blob has 17 B of headroom.
# The kind indexes MK_ORDER, and mk_tables.inc turns it into the pain/death SFX
# and the pain chance -- all of them info.c's own values.
MK_ORDER = doomstates.MONSTERS
CACO = 3005                   # MT_HEAD's doomednum. Its ball (MT_HEADSHOT,
                              #   BAL2) rides on any level that spawns one --
                              #   thirteen of the twenty-seven (E2M3 on).
BARON = 3003                  # MT_BRUISER's doomednum -- the kind EPISODE 1
                              # runs A_BossDeath on (p_enemy.c: gameepisode 1,
                              # gamemap 8). memory_map.inc MK_BOSS is its kind
                              # byte, pinned by the .if emitted below.
CYBORG = 16                   # MT_CYBORG -- episode 2's boss, and E3M9's (where
                              # A_BossDeath's gamemap gate means its death does
                              # nothing at all, exactly like vanilla)
SPIDER = 7                    # MT_SPIDER -- episode 3's


def boss_type_of(mapname):
    """p_enemy.c A_BossDeath, the gate half: which mobj TYPE fires the hook on
    this map, 0 = none. Verbatim from the switch on gameepisode -- ep 1/2/3 are
    map 8 and MT_BRUISER / MT_CYBORG / MT_SPIDER, ep 4 is map 6 (cyborg) or map
    8 (spider). Vanilla's `default:` arm (episode 5+, which no DOOM ships)
    accepts ANY type on map 8; there is no such episode here, so it answers 0
    and that level simply has no boss hook."""
    m = re.fullmatch(r'E(\d)M(\d)', mapname or '')
    if not m:
        return 0
    ep, mp = int(m.group(1)), int(m.group(2))
    if ep == 4:
        return CYBORG if mp == 6 else SPIDER if mp == 8 else 0
    if mp != 8:
        return 0
    return {1: BARON, 2: CYBORG, 3: SPIDER}.get(ep, 0)


MK_INC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      'mk_tables.inc')


def _sfx_ids():
    """{POPAIN: 13, ...} from the generated sound_tables.inc, so the kind table
    and the sound player cannot disagree about an id."""
    p = os.path.join(os.path.dirname(_HERE), 'sound_tables.inc')
    if not os.path.exists(p):
        return {}
    return {m.group(1): int(m.group(2)) for m in
            re.finditer(r'^SFX_(\w+)\s+equ\s+(\d+)', open(p).read(), re.M)}


# p_enemy.c's xspeed[]/yspeed[] in DI_* order. The diagonals are 47000/65536 of
# a unit; this port walks in whole map units, so the per-kind step is
# round(info.c speed * that) -- speed 8 -> 8/6, speed 10 -> 10/7.
DIAG = 47000 / 65536.0
XSPEED = (1.0, DIAG, 0.0, -DIAG, -1.0, -DIAG, 0.0, DIAG)
YSPEED = (0.0, DIAG, 1.0, DIAG, 0.0, -DIAG, -1.0, -DIAG)


def _snd_id(ids, num, d, field):
    """A mobjinfo sound field -> its SFX id, $FF if the kind has none or the
    lump is not in the blob (wadsound.py SFX is the authority on what shipped)."""
    v = d.mobj.get(num, {}).get(field, '0')
    return ids.get(v[4:].upper(), 0xFF) if v.startswith('sfx_') else 0xFF


def _see_base(num, d):
    """info.c's seesound name for a kind, e.g. 'sfx_posit1' -> 'POSIT1'."""
    s = d.mobj.get(num, {}).get('seesound', '0')
    return s[4:].upper() if s.startswith('sfx_') else ''


def _see_n(num, d):
    """How many numbered variants A_Look picks between. p_enemy.c switches on
    exactly two families: posit1..3 and bgsit1..2; everything else is one."""
    b = _see_base(num, d)
    return 3 if b.startswith('POSIT') else (2 if b.startswith('BGSIT') else
                                            (1 if b else 0))


def _death_base(num, d):
    """A_Scream's BASE lump name. p_enemy.c rerolls the whole family whatever
    info.c seeded -- SPOS carries sfx_podth2 but still cries podth1..3 -- so
    podth2/3 normalise to PODTH1 and bgdth2 to BGDTH1."""
    s = d.mobj.get(num, {}).get('deathsound', '0')
    b = s[4:].upper() if s.startswith('sfx_') else ''
    if b.startswith('PODTH'):
        return 'PODTH1'
    if b.startswith('BGDTH'):
        return 'BGDTH1'
    return b


def _death_id(ids, num, d):
    """The base variant's SFX id ($FF = silent kind or lump not shipped).
    en_die_snd adds P_Random()%mk_dthn on top, so the ids must be consecutive
    -- wadsound.py keeps the families that way (same rule as the seesounds)."""
    b = _death_base(num, d)
    return ids.get(b, 0xFF) if b else 0xFF


def _death_n(num, d):
    """How many death cries A_Scream picks between: podth1..3, bgdth1..2."""
    b = _death_base(num, d)
    return 3 if b == 'PODTH1' else (2 if b == 'BGDTH1' else (1 if b else 0))


def _see_id(ids, num, d):
    """The FIRST variant's SFX id ($FF = this kind is silent). A_Look plays
    base + P_Random()%n, so the variants have to be consecutive in the SFX list
    -- wadsound.py keeps them that way."""
    b = _see_base(num, d)
    if b.startswith('POSIT'):
        b = 'POSIT1'
    elif b.startswith('BGSIT'):
        b = 'BGSIT1'
    return ids.get(b, 0xFF) if b else 0xFF


_radius_noted = set()


def _check_radius_rule(mapname, dnum, lump, cls, radius):
    """en_radfill derives the PIT_CheckThing radius instead of reading a table
    (see OBSTACLE_R). Fail the build the moment a thing stops fitting the rule,
    because the engine has no way to notice -- the monster would just get the
    wrong blockdist and clip."""
    want = (doomstates.doom().radius(dnum) if dnum in MK_ORDER
            else OBSTACLE_R if cls == C_OBSTACLE else 0)
    if want == radius:
        return
    if dnum in MK_ORDER:
        raise SystemExit(
            f'  ERROR: {mapname}: {lump} (doomednum {dnum}) has radius {radius}, '
            f'but en_radfill would give it {want}. Either add it to MK_ORDER or '
            f'give the blob a real radius table (see the OBSTACLE_R note).')
    # A DECORATION that does not fit the rule is not worth failing a build over,
    # and tools/wadconv.py exists to convert WADs nobody wrote this table for:
    # DOOM's own TRE2 is 32 units and never appears in episode 1, but it does in
    # other people's maps. It gets OBSTACLE_R instead -- you can walk a little
    # closer to the tree than DOOM lets you, and that is the whole consequence.
    if (mapname, dnum) in _radius_noted:      # once per kind, not per instance:
        return                                #   MAP03 has 16 of the same tree
    _radius_noted.add((mapname, dnum))
    print(f'  note: {mapname}: {lump} (doomednum {dnum}) has radius {radius}, '
          f'the engine gives every obstacle {want} -- kept, collision is that '
          f'much tighter')


def _thrust_q4(mass):
    """p_inter.c P_DamageMobj hands a damaged thing momentum:

        thrust = damage*(FRACUNIT>>3)*100/mass          units per tic

    and p_mobj.c P_XYMovement then eats it at FRICTION (0.90625) a tic, so the
    SLIDE you see is thrust/(1-FRICTION) = damage*133.33/mass units. The engine
    has no momentum (enemy_ai.asm en_thrust), so it spends that whole distance
    at once and only needs the per-damage-point factor, in Q4: 21 for a mass of
    100 (the barrel, the zombieman), 5 for a demon, 2 for the baron."""
    return round(2133.333 / mass) if mass else 0


WI_INC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      'wi_tables.inc')
AT_INC = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      'at_tables.inc')

# Which MISSILE each p_enemy.c attack action spawns, and where the level's
# .things header keeps that missile's FLIGHT sprite id. The missile belongs to
# the ACTION, not to the kind: two kinds that share an action share the missile,
# which is exactly what info.c and p_enemy.c say --
#     A_TroopAttack : P_SpawnMissile (actor, actor->target, MT_TROOPSHOT)
#     A_BruisAttack : P_SpawnMissile (actor, actor->target, MT_BRUISERSHOT)
#     A_CyberAttack : P_SpawnMissile (actor, actor->target, MT_ROCKET)
# The header offsets are pack_things' own (see HEADER): +18 BAL1 A, +33 BAL7 A,
# +20 MISL A. Each one's BURST is that id + 1 by construction -- the three sets
# are packed A-then-burst, back to back -- so only the one byte is stored.
#     A_HeadAttack  : P_SpawnMissile (actor, actor->target, MT_HEADSHOT)
ATK_MISSILE = {3: ('MT_TROOPSHOT', 18),
               4: ('MT_HEADSHOT', 35),
               5: ('MT_BRUISERSHOT', 33),
               6: ('MT_ROCKET', 20)}
ATM_LO = min(ATK_MISSILE)          # the tables are emitted from here up, and
ATM_HI = max(ATK_MISSILE)          #   ball.asm indexes them at `tab-ATM_LO,x`.
                                   # NB the names: AT_FIRE/AT_LAST below are the
                                   # attack ROW's tics-byte flags and have
                                   # nothing to do with these.


def _substeps(d, mtname):
    """The SHIFT ball_frame applies to its sub-step count for this missile:
    0 = one 7-unit sub-step per VBLANK, 1 = two.

    ball.asm flies every missile at the k7 scale, which is MT_TROOPSHOT's
    10*FRACUNIT/tic = exactly 7 u/VBLANK on PAL. info.c does not give them all
    the same speed: MT_ROCKET is 20, i.e. DOUBLE, and the cyberdemon's rocket
    was crawling at half its rate -- easy to walk away from where DOOM's is not.
    The step itself must NOT be doubled (?chk runs on every sub-step precisely
    so a missile cannot tunnel a thin shut door); twice as many sub-steps is the
    same distance and the same collision resolution.

    FLOORED, and only 0 or 1 come out of DOOM 1: MT_BRUISERSHOT is 15, i.e.
    1.5x, and floors to 1x -- exactly what it flies today, so the baron does not
    change. Rounding it up would have made it 33% too fast, which is worse than
    the 33% too slow it already is."""
    base = 10                                    # MT_TROOPSHOT, the k7 scale
    v = d.fields_of_type(mtname).get('speed', '0')
    m = re.match(r'(\d+)\s*\*\s*FRACUNIT', v)
    spd = int(m.group(1)) if m else 0
    n = max(1, spd // base)
    assert n in (1, 2),         f'{mtname} flies {spd}/{base} = {n}x the k7 scale -- bl_subs can only '         f'shift, so 1x or 2x; a third rate needs a real multiply'
    return n - 1


def _explodes(d, mtname):
    """1 when this missile's DEATH chain runs A_Explode -- i.e. it does splash.

    In DOOM 1 that is MT_ROCKET alone: S_EXPLODE1 is {A_Explode} and the imp's
    S_TBALLX1..3 and the baron's S_BRBALLX1..3 carry no action at all, so a
    fireball only ever hurts what it lands ON. The port had no splash for ANY
    monster missile, which was right for two of the three and took most of the
    cyberdemon's teeth: in DOOM a rocket that lands NEAR you still does
    128 - dist. Read off the chain, not hardcoded, so a mod that gave the imp
    an exploding ball would get one."""
    st = d.fields_of_type(mtname).get('deathstate', 'S_NULL')
    return 1 if any(a == 'A_Explode' for _b, _f, _t, a in d._chain(st)) else 0


def emit_at_tables(rows, d):
    """at_tables.inc: what a monster missile IS, indexed by mk_atk.

    ball.asm has one missile in flight and re-reads these at every spawn, so
    the imp, the cacodemon, the baron and the cyberdemon share one flight path
    and differ only in these bytes. Every row 3..6 is a real missile since
    2026-08-20 -- A_SargAttack left the middle of the range for 7 so the table
    could take MT_HEADSHOT without growing (see ATK_ACTIONS)."""
    ids = _sfx_ids()

    def snd(field, mt):
        v = d.fields_of_type(mt).get(field, '0')
        i = ids.get(v[4:].upper(), 0xFF) if v.startswith('sfx_') else 0xFF
        assert i != 0xFF, \
            f'{mt} {field} is {v} and tools/wadsound.py does not ship that ' \
            f'lump -- a missile with no voice is a silent one'
        return i

    def row(f):
        return [f(*ATK_MISSILE.get(a, ATK_MISSILE[ATM_LO]))
                for a in range(ATM_LO, ATM_HI + 1)]
    tabs = (('at_mspr', row(lambda mt, off: off),
             'the .things header offset of the FLIGHT sprite id (burst = +1)'),
            ('at_mdmg', row(lambda mt, off: int(d.fields_of_type(mt)['damage'])),
             'info.c damage: PIT_CheckThing rolls ((P_Random()&7)+1) * this'),
            ('at_lsnd', row(lambda mt, off: snd('seesound', mt)),
             'P_SpawnMissile plays the seesound AT THE LAUNCH'),
            ('at_xsnd', row(lambda mt, off: snd('deathsound', mt)),
             'P_ExplodeMissile plays the deathsound at the burst'),
            ('at_boom', row(lambda mt, off: _explodes(d, mt)),
             'A_Explode on the DEATH chain -> P_RadiusAttack(128) at the burst'),
            ('at_ssh', row(lambda mt, off: _substeps(d, mt)),
             'info.c speed / MT_TROOPSHOT: ball_frame sub-steps << this'))
    with open(AT_INC, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_things.py -- DO NOT EDIT.\n')
        w('; The MISSILE a p_enemy.c attack action throws, indexed by mk_atk\n')
        w('; (mk_tables.inc). Emitted from ATM_LO up, so every read is\n')
        w(f'; `lda at_xxx-{ATM_LO},x` -- see ball.asm bl_pick / bl_roll.\n')
        w(f'ATM_LO       equ {ATM_LO}\n')
        w(f'ATM_HI       equ {ATM_HI}\n\n')
        for tag, vals, what in tabs:
            w(f'{tag}\n        ; {what}\n')
            for a, v in zip(range(ATM_LO, ATM_HI + 1), vals):
                mt = ATK_MISSILE.get(a)
                note = mt[0] if mt else 'no missile -- never read'
                w(f'        dta ${v & 0xFF:02X}    ; mk_atk {a}: {note}\n')
            w('\n')
    print(f'at_tables.inc ({ATM_HI - ATM_LO + 1} attack actions) -> {AT_INC}')


def emit_wi_tables(rows, d):
    """The INTERMISSION tally's two membership tables (wi.asm).

    p_inter.c:686 / p_mobj.c:789 count a kill only for MF_COUNTKILL, and
    p_inter.c:655 / p_mobj.c:791 an item only for MF_COUNTITEM. Both come
    straight out of info.c rather than being retyped, because the surprises are
    real: the LOST SOUL has no MF_COUNTKILL (info.c MT_SKULL), so it is not a
    kill; the BARREL has none either; and the RADIATION SUIT (2025) is NOT
    MF_COUNTITEM though every other powerup is. A hand-written list gets all
    three wrong, and a wrong one is invisible -- it just shows the player the
    wrong percentage forever.

    A FILE OF ITS OWN, not more rows in mk_tables.inc: these 42 bytes are read
    ONCE per level, by the intermission, so they belong in the overlay that
    reads them and not in base RAM. mk_tables.inc lives in MKTAB_BASE..END and
    putting them there overran it (the RAM budget at the top of memory_map.inc
    says why there is nowhere else)."""
    ck = [1 if 'MF_COUNTKILL' in d.mobj.get(r[0], {}).get('flags', '') else 0
          for r in rows]
    nbonus = max(BONUS.values()) + 1
    ci = [0] * nbonus
    for dnum, bid in BONUS.items():
        if 'MF_COUNTITEM' in d.mobj.get(dnum, {}).get('flags', ''):
            ci[bid] = 1
    with open(WI_INC, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_things.py -- DO NOT EDIT.\n')
        w('; The intermission tally\'s membership tables, from info.c. icl\'d by\n')
        w('; wi.asm INSIDE the overlay, so they cost no base RAM.\n')
        w('; p_inter.c:686 P_KillMobj -- 1 = this kind bumps killcount, and its\n'
          '; spawn bumps totalkills. Indexed by the kind byte (TH_KIND).\n')
        w('mk_ckill\n        dta 0    ; kind 0 = not a monster\n')
        for r, v in zip(rows, ck):
            w(f'        dta {v}    ; {r[1]} ({r[0]})\n')
        w('\n')
        w('; p_inter.c:655 P_TouchSpecialThing -- 1 = this BONUS ID bumps\n'
          '; itemcount. Indexed by the bonus id in the sprtab row (byte 7).\n')
        w(f'BN_COUNT     equ {nbonus}\n')
        w('bn_citem\n')
        for i, v in enumerate(ci):
            names = sorted(k for k, b in BONUS.items() if b == i)
            w(f'        dta {v}    ; id {i}'
              f'{" (" + ",".join(str(n) for n in names) + ")" if names else ""}\n')
    print(f'wi_tables.inc ({len(ck) + 1} kinds, {nbonus} bonus ids) -> {WI_INC}')


def emit_mk_tables():
    """mk_pain / mk_death / mk_chance and the AI's per-kind tables, indexed by
    the kind byte (0 = none). Everything here is level-INDEPENDENT: what a kind
    does, not what a level could afford. The per-level half (which walk frames
    got packed) is WTAB_EXT/WTAB_N in the .dtab blob."""
    d = doomstates.doom()
    ids = _sfx_ids()
    rows = []
    speeds = []                   # distinct info.c speeds -> a step-table row
    for num in MK_ORDER:
        s = d.sounds(num)
        run = d.run_chain(num)
        nst = len(run)                                  # RUN states, e.g. POSS 8
        nimg = len({f for _b, f, _t, _a in run})        # distinct frames, POSS 4
        spd = d.speed(num)
        if spd and spd not in speeds:
            speeds.append(spd)
        rows.append((num, d.death_chain(num)[0][0] if d.death_chain(num) else '?',
                     ids.get(s.get('pain', '')[2:], 0xFF),
                     _death_id(ids, num, d),            # base of the family --
                                                        #   SPOS's podth2 -> podth1
                     min(255, d.painchance(num)),       # SKUL's is 256 = always
                     run[0][2] if run else 0,           # 5: tics per RUN state
                     nst,                               # 6: RUN state count
                     1 if nimg and nst == 2 * nimg else 0,   # 7: state->image shift
                     speeds.index(spd) if spd in speeds else 0,   # 8: speed row
                     next((ATK_ACTIONS[a] for _b, _f, _t, a in atk_chain_of(d, num)
                           if a in ATK_ACTIONS), 0),          # 9: damage roll
                     1 if not d.atk_chain(num) else 0,        # 10: melee only
                     _see_id(ids, num, d),                    # 11: A_Look seesound
                     _see_n(num, d),                          # 12: ...variants
                     _snd_id(ids, num, d, 'activesound'),     # 13: A_Chase grunt
                     min(255, d.radius(num)),                 # 14: PIT_CheckThing
                     min(31, d.reactiontime(num)),            # 15: A_Chase counts (5 bits)
                     d.has_melee(num),                        # 16: A_Chase branch
                     _death_n(num, d),                        # 17: A_Scream variants
                     _thrust_q4(d.mass(num)),                 # 18: the damage kick
                     min(255, int(d.mobj.get(num, {}).get('spawnhealth', 0)
                                  or 0))))                     # 19: the gib test
    with open(MK_INC, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/pack_things.py -- DO NOT EDIT.\n')
        w('; Monster "kind" -> what info.c says it does. The kind byte itself rides\n')
        w('; in the sprtab row (see pack_things.py MK_ORDER); 0 = not a monster, so\n')
        w('; every table has a dummy row 0.\n')
        w(f'MK_COUNT     equ {len(rows) + 1}\n')
        w(f'MK_OBSTR     equ {OBSTACLE_R}           '
          '; radius of an obstacle decoration that is\n'
          f'{"":29}; not a monster kind (pillar, lamp, tree).\n'
          f'{"":29}; pack_things._check_radius_rule enforces it\n')
        # NB: pulled into a local on purpose. Inlining the call inside the
        # f-string needs single quotes inside a single-quoted f-string, which
        # only parses from Python 3.12 (PEP 701) -- on anything older this file
        # raises SyntaxError at IMPORT, and every tool that imports it dies with
        # a message about line 293 rather than about itself.
        plrad = d.radius_of_type('MT_PLAYER')
        w(f'MK_PLRAD     equ {plrad}'
          f'{"":<{max(1, 13 - len(str(plrad)))}}'
          '; MT_PLAYER radius -- the other half of every\n'
          f'{"":29}; blockdist the player is involved in\n')
        nbr = noblast_radius()
        d2 = doomstates.doom()
        w(f'MK_NOBLAST_R equ {nbr}'
          f'{"":<{max(1, 13 - len(str(nbr)))}}'
          '; p_map.c PIT_RadiusAttack: a thing THIS wide\n'
          f'{"":29}; takes no concussion damage at all --\n'
          f'{"":29}; "Boss spider and cyborg", the only\n'
          f'{"":29}; immunity in DOOM, and the only place a\n'
          f'{"":29}; TYPE is named in the damage path. Read\n'
          f'{"":29}; out of the C (noblast_types) and pinned\n'
          f'{"":29}; to a radius so en_bdist can ask it in one\n'
          f'{"":29}; compare: {", ".join(str(n) for n in sorted(noblast_types() & set(MK_ORDER)))}'
          f' = radius {"/".join(str(d2.radius(n)) for n in sorted(noblast_types() & set(MK_ORDER)))}\n')
        # MK_BEXP is hand-written in memory_map.inc (pf_gore needs it for
        # MF_NOBLOOD and that file assembles first), so pin it here: reordering
        # MK_ORDER would otherwise silently make the barrel bleed again.
        w(f'    .if MK_BEXP != {MK_ORDER.index(2035) + 1}\n'
          f"        ert 'MK_BEXP (memory_map.inc) is not the barrel kind any "
          f"more -- MK_ORDER moved it to {MK_ORDER.index(2035) + 1}'\n"
          '    .endif\n')
        # Same deal for the BARON. No 6502 reads MK_BOSS since 2026-08-20 --
        # A_BossDeath fires on a different TYPE per episode, so the kind rides
        # in the .things header instead -- but the pin is what makes MK_ORDER
        # append-only, and that is worth keeping on its own: every kind byte
        # already shipped inside a packed level blob.
        w(f'    .if MK_BOSS != {MK_ORDER.index(3003) + 1}\n'
          f"        ert 'MK_BOSS (memory_map.inc) is not the baron kind any "
          f"more -- MK_ORDER moved it to {MK_ORDER.index(3003) + 1}'\n"
          '    .endif\n')
        # mk_rt WAS a table until 2026-08-20, and every entry in it was 8:
        # info.c hands the same reactiontime to every mobj in the game. It is
        # MK_RT in memory_map.inc now (12 B of MKTAB back, which the two final
        # bosses needed), so pin the assumption the way MK_BOSS is pinned --
        # a WAD or a mod that gave one kind a different reactiontime would
        # otherwise be silently flattened to 8.
        rts = {r[15] for r in rows}
        assert len(rts) == 1, \
            f'reactiontime is no longer one number ({sorted(rts)}) -- MK_RT ' \
            f'(memory_map.inc) has to become a table again, and MKTAB_END ' \
            f'has to find {len(rows) + 1} more bytes'
        w(f'    .if MK_RT != {rts.pop()}\n'
          f"        ert 'MK_RT (memory_map.inc) is not info.c reactiontime any "
          f"more'\n"
          '    .endif\n\n')
        # ---- A_Hoof / A_Metal: MK_WSND, and the shape ai_state hardcodes ----
        # The ONLY two RUN chains in DOOM that do more than A_Chase. info.c:
        #   S_CYBER_RUN1 A_Hoof, S_CYBER_RUN7 A_Metal          (states 0 and 6)
        #   S_SPID_RUN1/5/9 A_Metal                            (states 0, 4, 8)
        # enemy_ai.asm's ai_state hook is 25 bytes and spends none of them on a
        # table: it tests `cpx #MK_WSND` (the two are the LAST kinds), then
        # state 6 / state 0 for the cyberdemon and `and #3` for the spider.
        # That is only correct while info.c still says exactly this, so say it
        # here -- the same contract MK_BEXP/MK_BOSS/MK_RT are pinned by, and
        # why this is derived from run_chain() instead of typed out twice.
        wsnd = {n: {i: a for i, (_s, _f, _t, a) in enumerate(d2.run_chain(n))
                    if a and a != 'A_Chase'} for n in MK_ORDER}
        wsnd = {n: t for n, t in wsnd.items() if t}
        assert list(wsnd) == [16, 7], \
            'the RUN chains with a non-A_Chase action are no longer the ' \
            f'cyberdemon and the spider ({sorted(wsnd)}) -- the walk-sound ' \
            "hook in enemy_ai.asm ai_state has to be rewritten"
        assert list(MK_ORDER[-2:]) == [16, 7], \
            'the cyberdemon and the spider are no longer the last two kinds ' \
            f'({list(MK_ORDER[-2:])}) -- ai_state sorts every other kind out ' \
            'with `cpx #MK_WSND / bcc`, which only works while they are the ' \
            'tail of MK_ORDER'
        assert wsnd[16] == {0: 'A_Hoof', 6: 'A_Metal'}, \
            'the cyberdemon walk cycle is not hoof@0 + metal@6 any more ' \
            f'({wsnd[16]}) -- ai_state hardcodes exactly those two states'
        assert set(wsnd[7]) == {0, 4, 8} and set(wsnd[7].values()) == {'A_Metal'}, \
            f'the spider walk cycle is not metal every 4th state ({wsnd[7]}) ' \
            '-- ai_state tests it with `and #3`'
        w(f'MK_WSND      equ {MK_ORDER.index(16) + 1}'
          f'{"":10}; the CYBERDEMON kind -- and the FIRST kind\n'
          f'{"":29}; with a walk sound. info.c gives a RUN\n'
          f'{"":29}; state an action other than A_Chase for\n'
          f'{"":29}; these two mobjs and no others, and they\n'
          f'{"":29}; are the tail of MK_ORDER, so ai_state\n'
          f'{"":29}; sorts every other kind out with one cpx.\n'
          f'{"":29}; CYBR = A_Hoof at RUN state 0 + A_Metal at\n'
          f'{"":29}; 6, SPID = A_Metal at 0/4/8 -- pack_things\n'
          f'{"":29}; asserts every word of that against info.c\n\n')
        for tag, col, what in (('mk_pain', 2, 'pain SFX'),
                               ('mk_death', 3, 'death SFX'),
                               ('mk_chance', 4, 'P_Random < this -> pain'),
                               ('mk_ctic', 5, 'tics per RUN state = the A_Chase rate'),
                               ('mk_wst', 6, 'RUN states in the walk cycle'),
                               ('mk_wsh', 7, 'state >> this = the image index'),
                               ('mk_spd', 8, 'row in mk_stepx'),
                               ('mk_atk', 9, 'p_enemy.c damage roll, 0 = none'),
                               ('mk_mel', 10, '1 = melee only (no missilestate)'),
                               ('mk_see', 11, 'A_Look seesound, $FF = silent'),
                               ('mk_seen', 12, '...how many variants to pick between'),
                               ('mk_act', 13, 'A_Chase patrol grunt, $FF = silent'),
                               ('mk_rad', 14, 'info.c radius, units (PIT_CheckThing)'),
                               ('mk_hmel', 16, '1 = has a meleestate (A_Chase branch)'),
                               ('mk_dthn', 17, 'A_Scream death-cry variants (consecutive ids)'),
                               ('mk_thr', 18, 'P_DamageMobj kick: units of slide per damage point, Q4'),
                               ('mk_hp', 19, 'info.c spawnhealth: overkill past THIS gibs (p_inter.c:719)')):
            w(f'{tag}\n        dta ${0xFF if col < 4 else 0:02X}'
              f'    ; kind 0 = not a monster ({what})\n')
            for r in rows:
                w(f'        dta ${r[col] & 0xFF:02X}    ; {r[1]} ({r[0]})\n')
            w('\n')
        # The step table. One 8-byte row per DISTINCT speed, so the engine turns
        # (kind, direction) into a step with one shift and one add.
        #
        # There is no mk_stepy (2026-08-20). p_enemy.c's yspeed[] is xspeed[]
        # turned two octants -- yspeed[d] == xspeed[(d+6)&7] for every d, which
        # is just cos/sin of the same eight angles -- so the second table was
        # the same eight numbers stored twice. ai_move rotates the index
        # instead; the assert below is what says the identity still holds.
        for i in range(8):
            assert abs(YSPEED[i] - XSPEED[(i + 6) % 8]) < 1e-9, \
                'yspeed[] is no longer xspeed[] rotated -- ai_move reads one ' \
                'table for both axes'
        w('; p_enemy.c P_Move: tryx = x + speed*xspeed[movedir], in whole units.\n')
        w('; Row = mk_spd[kind], column = movedir (DI_EAST..DI_SOUTHEAST).\n')
        w('; yspeed[] is this table read at (movedir + 6) & 7 -- see ai_move.\n')
        w('mk_stepx\n')
        for spd in speeds:
            step = [int(round(spd * v)) for v in XSPEED]
            vals = ','.join(f'${v & 0xFF:02X}' for v in step)
            w(f'        dta {vals}    ; speed {spd}: '
              f'{",".join(str(v) for v in step)}\n')
        w('\n')
    emit_at_tables(rows, d)       # ...the per-ATTACK-ACTION missile tables, and
    emit_wi_tables(rows, d)       #    the intermission's two, each in its own
                                  #    file (see emit_wi_tables for why)
    return rows
HEADER = 38                   # +36 BFS1 A and +37 BFE1 A, the BFG ball's flight
                              # and burst ($FF = the level packed neither, which
                              # makes pj_bspawn land the shot at once). 2026-08-28.
                              # +35 BAL2 A, the CACODEMON's fireball (2026-08-20;
                              # $FF = this level has no cacodemon), burst = +1 like
                              # the other two.
                              # +2 for p_hp at 16, +1 for the fireball sprite id,
                              # +33 BAL7 A, the BARON's fireball ($FF = this level
                              # has no baron). Its burst is that id + 1 by
                              # construction -- ball.asm bl_pick just inc's, like
                              # it does for BAL1.
                              # +31 the tag-666 record's trigger INDEX ($FF = the
                              # level has none, $FE = end the level instead) and
                              # +32 how many BOSSES must die before it fires --
                              # the engine COUNTS THAT DOWN IN PLACE (enemy.asm
                              # en_bossdie), so the blob is reloaded per level.
                              # +34 the KIND byte a death must carry for that to
                              # happen (2026-08-20). p_enemy.c A_BossDeath gates
                              # on the mobj TYPE and it is a different one per
                              # episode -- baron / cyberdemon / spider -- so the
                              # engine cannot compare against a constant any
                              # more. 0 = this level has no boss hook.
                              #   +4 missiles, the PUFF at 24, the BLOOD at 25
                              # +20/21 rocket flight/burst ids, +22/23 plasma
                              # flight/burst ids (proj.asm, 2026-08-04)
                              # +26/27 and +28/29 the GUN line's two seg RECORD
                              # ADDRESSES (front side, back side -- the shot and
                              # the USE ray can each arrive from either), +30 its
                              # trigger index (doors.asm gun_seg_p / gun_match);
                              # 0/0/$FF when the level has no 46 line.
                              # Everything after the header is reached through
                              # the p_* pointers, so growing it shifts nothing.
                              # at 18, +1 for its burst's FIRST id at 19 (C of
                              # C/D/E, consecutive; $FF = no burst packed). The
                              # engine reads the other pointers at +5/+11/+13/
                              # +14 -- appending keeps them valid. Every byte
                              # counts: E1M6's blob has 3712 B before it runs
                              # into use_side at $CE80.
# PIT_CheckThing needs a radius per thing, and the blob has no room for one:
# E1M6 is 16 B under its 3712 B cap. It does not need one either -- across all
# nine maps the radius is exactly
#     pickup            -> 0   (MF_SPECIAL, never MF_SOLID)
#     kind != 0         -> mk_rad[kind]      (monsters AND the barrel)
#     obstacle flag     -> OBSTACLE_R
#     otherwise         -> 0
# and both inputs are already in the blob (sprtab byte 7, thing flags bit 0/1).
# en_radfill applies it at level init. _check_radius_rule() below fails the
# build if a map ever stops obeying it -- e.g. TRE2, the one 32-unit obstacle
# in the table, showing up in an episode.
OBSTACLE_R = 16


def darkest_nonzero(playpal):
    """PLAYPAL index (1..255) with the lowest luminance -- stands in for index 0
    inside sprites so 0 can mean 'transparent' for the blitter stencil."""
    best, bi = 1e9, 1
    for i in range(1, 256):
        r, g, b = playpal[i]
        lum = 0.30 * r + 0.59 * g + 0.11 * b
        if lum < best:
            best, bi = lum, i
    return bi


def _cols_of(w, h, cols, black, flip=False):
    """A patch's rectangular columns, exactly as the engine wants the texels:
    index 0 = transparent, opaque 0 remapped to `black`, columns in as-drawn
    order (flip reverses them -- pack-time profile normalisation)."""
    out = []
    for x in range(w):
        col = bytearray(h)
        for (td, pix) in cols[w - 1 - x if flip else x]:
            for k, c in enumerate(pix):
                if 0 <= td + k < h:
                    col[td + k] = c if c else black
        out.append(col)
    return out


def _store_frame(blob, colpix, frames, coltabs):
    """T4: append a frame's columns CROPPED to [first..last] opaque texel and
    register its column table (shared frames share pixels AND table via the
    caller's caches). Interior zeros stay for the stencil; a fully transparent
    column stores nothing and len 0 tells spr_one not to blit it at all.
    B1: returns the FRAME ID the rows carry; the file offset and stored size
    go to the FTAB half of .sprcol (tools/_verify_arena.py), and the file is
    plain sequential again -- frames tile it with no VRAM addresses anywhere.
    B2 (2026-08-18, THE SPRITE POOL): `blob` is ONE pool shared by every
    level of the run (pack() hands out SPRPOOL), and identical frames -- same
    crop table AND same pixel bytes -- are stored once: _POOL_IX remembers
    where. 27 maps repeat the same POSS/TROO/SARG sets, so per-level .spr
    files (150-190 KB each, x27) collapse to one ~300 KB blob the engine
    streams once, exactly like the texture pool. FTAB offsets stay relative
    to LVL_SPRSD, which now points every level at the pool's SDRAM home --
    spr_fget cannot tell the difference.
    Contracts: tools/_verify_sprcrop.py + tools/_verify_arena.py."""
    tab, slices, total = [], [], 0
    for col in colpix:
        first = last = None
        for i, c in enumerate(col):
            if c:
                last = i
                if first is None:
                    first = i
        if first is None:                 # len 0 = never blitted; off still
            tab.append((total, 0, 0))     #   carries the running sum, so offs
        else:                             #   stay monotone
            tab.append((total, first, last - first + 1))
            s = col[first:last + 1]
            slices.append(s)
            total += len(s)
    assert total < 0x10000, 'a frame must stay under 64 KB stored'
    fid = len(frames)
    if fid >= NFRAMES_MAX - 1:        # the id is a byte and $FF is reserved.
        return None                   #   _blit_frame's callers all read None
                                      #   as "no room, keep what you have"
    joined = b''.join(bytes(s) for s in slices)
    key = (tuple(tab), joined)
    off = _POOL_IX.get(key)
    if off is None:
        off = len(blob)
        blob += joined
        _POOL_IX[key] = off
    frames.append((off, total))
    coltabs.append(tab)
    return fid


SPRPOOL = bytearray()                  # B2: the one sprite-pixel pool of the run
_POOL_IX = {}                          # (coltab tuple, pixel bytes) -> pool off


def emit_sprcol(frames, coltabs):
    """The .sprcol v2 blob (B1): the coltab blocks packed from $9400, padded
    to +$6000, then the FTAB -- NFRAMES_MAX x {u24 file_off, u16 size,
    u16 coltab addr, pad}. One read_ext run lands the coltabs at SPRCOL_EXT
    and the FTAB at FTAB_EXT. The old per-sid/per-row directories died with
    B1: a row's byte 0 IS the frame id, and the FTAB knows the rest."""
    out = bytearray()
    ptrs = []
    for tab in coltabs:
        ptrs.append(SPRCOL_BASE + len(out))
        for (off, top, ln) in tab:
            out += struct.pack('<HBB', off, top, ln)
    if len(out) > FTAB_OFF:
        sys.exit(f'  ERROR: coltab region {len(out)} B > the {FTAB_OFF} B '
                 f'run $9400-$F3FF ({len(coltabs)} frames)')
    out += bytes(FTAB_OFF - len(out))
    for i in range(NFRAMES_MAX):
        if i < len(frames):
            fo, sz = frames[i]
            assert fo < 0x1000000
            out += struct.pack('<HBHHB', fo & 0xFFFF, fo >> 16, sz,
                               ptrs[i], 0)
        else:
            out += bytes(FTAB_ROW)
    return bytes(out)


def wad_subsector(md, x, y):
    nid = len(md.nodes) - 1
    while not (nid & NF_SUBSECTOR):
        n = md.nodes[nid]
        nid = n.child[0] if (y - n.y) * n.dx < n.dy * (x - n.x) else n.child[1]
    return nid & (NF_SUBSECTOR - 1)


def wad_sector_of_ss(md, ssid):
    sg = md.segs[md.ssectors[ssid].first]
    ld = md.linedefs[sg.linedef]
    return md.sidedefs[ld.right if sg.side == 0 else ld.left].sector


def _map_segs_base():
    """MAP_SEGS from map_syms.inc -- pack_map.py is the single source of truth
    for the LOW-blob layout, and it must have run for THIS level set first
    (the trigger table stores absolute seg record addresses)."""
    import re
    p = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                     'map_syms.inc')
    m = re.search(r'MAP_SEGS\s+equ\s+\$([0-9A-Fa-f]+)', open(p).read())
    assert m, 'map_syms.inc has no MAP_SEGS -- run pack_map.py first'
    return int(m.group(1), 16)


def _neigh_heights(md, si):
    """(floors, ceilings) of every sector sharing a two-sided line with si --
    p_floor.c's P_FindLowestFloorSurrounding & co. walk exactly this set. Falls
    back to the sector's own heights when it borders nothing, so min()/max()
    always have something to chew on."""
    nb, nbc = [], []
    for l in md.linedefs:
        if l.left == NO_SIDEDEF or l.right == NO_SIDEDEF:
            continue
        a, b = md.sidedefs[l.right].sector, md.sidedefs[l.left].sector
        o = b if si == a else a if si == b else None
        if o is None:
            continue
        nb.append(md.sectors[o].floor_h)
        nbc.append(md.sectors[o].ceil_h)
    if not nb:
        nb, nbc = [md.sectors[si].floor_h], [md.sectors[si].ceil_h]
    return nb, nbc


def _build_stairs(md, tag, stepsize=8):
    """EV_BuildStairs(build8), p_floor.c -- [(sector, target floor), ...].
    The tagged sector rises one step, then the chain walks on: a two-sided line
    whose FRONT side is the current sector leads to the next step, provided its
    floor flat matches. A sector already in the chain is skipped but still costs
    a step (DOOM bumps `height` before the specialdata test)."""
    lines_of = _sector_lines(md)
    out, done = [], set()
    for start, s in enumerate(md.sectors):
        if s.tag != tag or start in done:
            continue
        sec, done = start, done | {start}
        height = md.sectors[sec].floor_h + stepsize
        flat = md.sectors[sec].floor_flat
        out.append((sec, height))
        ok = True
        while ok:
            ok = False
            for li in lines_of[sec]:
                ld = md.linedefs[li]
                if not (ld.flags & ML_TWOSIDED) or NO_SIDEDEF in (ld.right, ld.left):
                    continue
                if md.sidedefs[ld.right].sector != sec:
                    continue
                nxt = md.sidedefs[ld.left].sector
                if md.sectors[nxt].floor_flat != flat:
                    continue
                height += stepsize
                if nxt in done:
                    continue
                sec = nxt
                done.add(sec)
                out.append((sec, height))
                ok = True
                break
    return out


def _sector_lines(md):
    """P_GroupLines: sector -> the linedefs touching it, in map order."""
    out = {}
    for li, ld in enumerate(md.linedefs):
        for sd in (ld.right, ld.left):
            if sd != NO_SIDEDEF:
                out.setdefault(md.sidedefs[sd].sector, []).append(li)
    return out


def _donut(md, tag):
    """EV_DoDonut (p_floor.c) -> [(ring, height), (pillar, height)].
    The tagged sector is the PILLAR; getNextSector on its FIRST linedef gives
    the donut RING, and the ring's first line that does not lead back to the
    pillar names the sector both end up level with. The ring comes FIRST in the
    list on purpose: it rises, mv_start finishes a raise on the spot, and that
    leaves the one mover slot free for the pillar, which really slides down."""
    lines_of = _sector_lines(md)
    out = []
    for s1, sec in enumerate(md.sectors):
        if sec.tag != tag:
            continue
        l0 = md.linedefs[lines_of[s1][0]]                  # s1->lines[0]
        if l0.right == NO_SIDEDEF or l0.left == NO_SIDEDEF:
            continue                                       # getNextSector: NULL
        f, b = md.sidedefs[l0.right].sector, md.sidedefs[l0.left].sector
        s2 = b if f == s1 else f                           # the donut ring
        for li in lines_of[s2]:
            ld = md.linedefs[li]
            if not (ld.flags & ML_TWOSIDED) or NO_SIDEDEF in (ld.right, ld.left):
                continue
            s3 = md.sidedefs[ld.left].sector               # ->backsector
            if s3 == s1:
                continue
            h = md.sectors[s3].floor_h
            # p_spec.c EV_DoDonut runs BOTH halves at FLOORSPEED/2 (17.5
            # units/s). The port's two bases differ, so the shift does too: the
            # ring RISES off mv_raise's 35, the pillar DROPS off mv_step's 140.
            out += [(s2, h, 1), (s1, h, 3)]
            break
    return out


def _tele_dests(md):
    """The MT_TELEPORTMAN things (doomednum 14) EV_Teleport lands on:
    ({sector: index}, [(x, y, BAM angle), ...]). DOOM picks the teleport man
    that sits in a sector carrying the line's tag, so the record only has to
    store an index into this table."""
    by_sector, tab = {}, []
    for t in md.things:
        if t.type != 14:
            continue
        sec = wad_sector_of_ss(md, wad_subsector(md, t.x, t.y))
        if sec in by_sector:
            continue                   # one destination per sector is enough
        by_sector[sec] = len(tab)
        tab.append((t.x, t.y, int(t.angle * 256 / 360) & 0xFF))
    return by_sector, tab


DTAB_HDR = 16                 # bytes reserved for the per-kind first-row index
DTAB_NHDR = 10                # ...and how many such headers the blob carries.
                              # memory_map.inc DTAB_ROWS is DTAB_EXT + this
                              # many pages of 16 B and NOTHING derives it from
                              # the other side -- the two are the same number
                              # seen from the packer and from the 6502, so
                              # moving one without the other puts every row
                              # index 16 B off (2026-08-26, PTIC_EXT).
DTAB_MAX = 2048               # the bank $01 slot ($01:8C00..$01:93FF -- moved
                              # 2026-08-03: the old $6600 home really ended at
                              # TH_STATE $6800, i.e. 512 B, and the rotation
                              # rows overflowed it straight onto the AI pages).
                              # 160 B of headers + 236 rows; the row index is a
                              # byte (row+1), so 254 is the hard ceiling.
_DTAB_OLD = 1024              # the lie the old slot told ($01:6600+). 512 until
                              # the attack states landed (2026-07-31): five 16 B
                              # headers now, and death + attack + walk rows.
DTAB_ROW = 8

# ---- T4 column crop (.sprcol, docs/VRAM-PLAN.md par.4 A1) --------------------
# The bank $01 home is the PINNED interface -- tools/_verify_sprcrop.py is the
# contract, memory_map.inc SPRCOL_EXT the equ. Since B1 the stream is v2:
# coltab blocks from $9400, the FTAB at +$6000 (see the arena block below).
SPRCOL_BASE = 0x0000          # bank $08 (SPRCOL_BANK): where load_sprcol
                              #   streams the blob -- it left bank $01 on
                              #   2026-08-21, see memory_map.inc

# Tics byte of a death row, and the only place the chain's SHAPE is encoded:
#   $FF     stay here forever  -- DOOM's tics = -1, i.e. the corpse
#   bit7    last row: when its tics run out the thing DISAPPEARS (the chain ran
#           into S_NULL -- that is the barrel, which leaves nothing)
#   bit6    this row's state runs A_Explode (p_enemy.c: P_RadiusAttack 128).
#           $FF is tested FIRST, so it never collides with bit7|bit6|63 --
#           no death state is anywhere near 63 tics long.
#   bits0-5 how many tics the row lasts
DT_FREEZE = 0xFF
DT_LAST = 0x80
DT_BOOM = 0x40                # bit6: run A_Explode when this row is ENTERED


def atk_reserve(sp, kinds_present, have):
    """The coltab bytes the ATTACK chains will want at ONE view -- the floor
    under plan_views' ladder, and what pack_death has to leave behind.

    pack_death runs FIRST and used to be unbounded, which is fine while the
    corpses fit. E3M9 is where that stopped being true (2026-08-20): five
    barons, a cyberdemon and 45 death rows put the run 484 B over before
    plan_views was even asked, and plan_views can only give up the WALK cycle
    -- pack_atk runs whatever it is handed. Losing a corpse animation is
    cosmetic (en_kill has a no-death-chain exit and takes it); losing an attack
    chain is a monster that cannot fight. So the reserve is priced here and
    pack_death spends only what is left."""
    d = doomstates.doom()
    seen, need = set(have), 0
    for ki, num in enumerate(MK_ORDER):
        if (ki + 1) not in kinds_present:
            continue
        chain = atk_chain_of(d, num)
        if not chain or not any(a in ATK_ACTIONS for _b, _f, _t, a in chain):
            continue
        for (base, fr, _t, _a) in chain:
            key = lump_norm(sp, base, fr, 1)
            if key is None or key in seen:
                continue
            seen.add(key)
            pat = sp.patch(key[0])
            if pat:
                need += 4 * pat[0]
    return need


def pack_death(sp, blob, black, kinds_present, frames, coltabs,
               budget=1 << 30, boss_kind=0):
    """Death-animation frames for the kinds this level spawns.

    Appends their pixels to the sprite blob (same VRAM slot, same column-major
    layout as a live sprite) and returns the .dtab blob: a 16-byte header of
    per-kind first-row indexes ($FF = this kind is not in the level), then
    8-byte rows of `addr(3), w, h, left, top, tics`.

    The rows are SELF-DESCRIBING on purpose -- the tics byte says when the chain
    ends and how -- so the engine needs no per-kind length table and no lookup
    beyond TH_STATE, which holds the absolute row index + 1.

    ADAPTIVE since 2026-08-20, the way the idle rings and the gib chains have
    always been: a chain that will not fit `budget` bytes of the coltab run is
    DROPPED whole, and the kind dies without an animation (en_kill's ?none
    exit). The level's BOSS goes first, because its corpse is the one the map
    is about -- A_BossDeath fires either way (en_kill calls en_bossdie from
    both exits), but a boss that blinks out of existence is the worst-looking
    drop there is.
    """
    d = doomstates.doom()
    first = [0xFF] * DTAB_HDR
    rows = []
    order = sorted(range(len(MK_ORDER)), key=lambda k: k + 1 != boss_kind)
    for ki in order:
        num = MK_ORDER[ki]
        if (ki + 1) not in kinds_present:
            continue
        chain = d.death_chain(num)
        if not chain:
            continue
        want = 0
        for (base, frame, _t, _a) in chain:
            got = sp.lump_for(base, frame, 1)
            pat = sp.patch(got[0]) if got else None
            if pat:
                want += 4 * pat[0]
        left = budget - sum(4 * len(t) for t in coltabs)
        if want > left:
            print(f'  death: {chain[0][0]} chain dropped -- wants {want} B of '
                  f'coltab, {left} B left')
            continue
        start = len(rows)
        packed = []
        for n, (base, frame, tics, act) in enumerate(chain):
            got = sp.lump_for(base, frame, 1)
            pat = sp.patch(got[0]) if got else None
            if pat is None:
                print(f'  ! {base}{frame}: no sprite lump, death chain cut short')
                break
            w, h, left, top, cols = pat
            if not (0 < w < 256 and 0 < h < 256 and -128 <= left < 128 and 0 <= top < 256):
                print(f'  ! {got[0]}: {w}x{h} off=({left},{top}) out of byte range')
                break
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            last = (n == len(chain) - 1)
            if tics < 0:
                t = DT_FREEZE                       # corpse: stays for good
            else:
                assert 0 < tics < DT_BOOM,                     f'{got[0]}: {tics} tics does not fit in 6 bits'
                t = tics
                if last:
                    t |= DT_LAST
                if act == 'A_Explode':
                    t |= DT_BOOM
            packed.append((addr, w, h, left, top, t))
        # The BOSS gets a whole chain or no chain at all. bd_at (enemy.asm) fires
        # A_BossDeath when the chain reaches its FROZEN row, and a chain cut
        # short by a missing lump has no frozen row -- the level's exit would
        # never open and the M8 could not be finished. `continue` here is the
        # safe half of the same bargain: en_kill's ?none exit still fires the
        # hook off the kill for a kind with no chain at all.
        # (`packed` has not been appended to `rows` yet, so dropping it is just
        # dropping the list -- the frames it blitted stay in the pool unreferenced,
        # which costs bytes on a path that has never once been taken.)
        if packed and ki + 1 == boss_kind and len(packed) != len(chain):
            print(f'  death: {chain[0][0]} chain came up short '
                  f'({len(packed)}/{len(chain)}) and it is the BOSS -- dropped '
                  f'whole so A_BossDeath fires off the kill instead')
            packed = []
        if packed:
            # Indexed by the KIND BYTE, not by the MK_ORDER position: the engine
            # has the kind (1..N, 0 = not a monster) and nothing else, so slot 0
            # stays $FF and kind k lives at first[k]. Getting this off by one is
            # invisible in the data and shows up as "monsters just vanish".
            first[ki + 1] = start
            rows += packed
    return first, rows


def pack_xdeath(sp, blob, black, kinds_present, frames, coltabs, base_row):
    """The GIB chains (p_inter.c:719) -- what a rocket earns.

    Same rows, same format and the same 8-byte array as pack_death; only the
    chain differs (S_x_XDIE, nine frames for the two zombies and eight for the
    imp -- info.c gives the demon, the lost soul, the cacodemon, the baron and
    the barrel no xdeathstate at all, so those kinds keep $FF here and simply
    die the ordinary way, exactly as they do in DOOM).

    Appended AFTER every other chain (`base_row`), so no existing row index
    moves: death, attack and walk rows keep the numbers they already had.
    """
    d = doomstates.doom()
    first = [0xFF] * DTAB_HDR
    rows = []
    # ADAPTIVE, like the walk cycle: the gib chains are the LAST thing packed,
    # so they get whatever coltab room the level has left and no more. The
    # binding limit is not VRAM -- the pixels live in SDRAM with the arena
    # caching them -- it is the 24 KB coltab run at $01:9400, four bytes per
    # sprite COLUMN. A level that cannot afford a kind's nine frames simply
    # keeps that kind's ordinary death, which is what shipped before anyway.
    used = sum(4 * len(t) for t in coltabs)
    for ki, num in enumerate(MK_ORDER):
        if (ki + 1) not in kinds_present:
            continue
        chain = d.xdeath_chain(num)
        if not chain:
            continue
        cost = 0                                # price it BEFORE storing a byte
        for base, frame, _t, _a in chain:
            got = sp.lump_for(base, frame, 1)
            pat = sp.patch(got[0]) if got else None
            if pat:
                cost += 4 * pat[0]
        nfr = len(chain)                        # ...and frame IDS, a byte
        if used + cost > FTAB_OFF or len(frames) + nfr >= NFRAMES_MAX - 1:
            print(f'  gib: {chain[0][0]} chain dropped -- wants {cost} B of '
                  f'coltab ({FTAB_OFF - used} left) and {nfr} frame ids '
                  f'({NFRAMES_MAX - 1 - len(frames)} left)')
            continue
        used += cost
        start = base_row + len(rows)
        packed = []
        for n, (base, frame, tics, act) in enumerate(chain):
            got = sp.lump_for(base, frame, 1)
            pat = sp.patch(got[0]) if got else None
            if pat is None:
                print(f'  ! {base}{frame}: no sprite lump, gib chain cut short')
                break
            w, h, left, top, cols = pat
            if not (0 < w < 256 and 0 < h < 256
                    and -128 <= left < 128 and 0 <= top < 256):
                print(f'  ! {got[0]}: {w}x{h} off=({left},{top}) out of range')
                break
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            last = (n == len(chain) - 1)
            if tics < 0:
                t = DT_FREEZE                       # the gibs stay for good
            else:
                assert 0 < tics < DT_BOOM, f'{got[0]}: {tics} tics needs 6 bits'
                t = tics
                if last:
                    t |= DT_LAST
                if act == 'A_Explode':
                    t |= DT_BOOM
            packed.append((addr, w, h, left, top, t))
        if packed:
            first[ki + 1] = start                   # by KIND BYTE, see pack_death
            rows += packed
    return first, rows


def pain_tics():
    """PTIC_EXT: how long the flinch holds, in tics, per KIND BYTE (0 = this
    kind has no painstate at all -- the barrel).

    info.c's pain chain is states of ONE image falling straight back into
    S_x_RUN1, so its total duration is the whole of what the port has to
    reproduce and the sum is exact for every kind but one. What it is NOT
    exact for is the cacodemon: S_HEAD_PAIN is three states, E(3) E(3) F(6),
    and the port shows E for the full 12 -- the third state is a DIFFERENT
    image and a second row plus a chain step is the pain STATE machine the
    design refuses (enemy_ai_attack.asm's flinch block). The duration is
    right; the second image is the gap.

    Until 2026-08-26 this was PAIN_TICS, ONE number (6) for every kind, and
    it was wrong for five of the nine: the imp, the demon and the baron flinch
    4 tics in DOOM, the cyberdemon 10 and the cacodemon 12.
    """
    d = doomstates.doom()
    out = [0] * DTAB_HDR
    for ki, num in enumerate(MK_ORDER):
        chain = d.pain_chain(num)
        if not chain:
            continue                    # no painstate -> the barrel, and its
        t = sum(c[2] for c in chain)    #   painchance is 0 anyway
        assert 0 < t < 256,             f'{num}: painstate chain is {t} tics, which is not a byte'
        out[ki + 1] = t
    return out


def pack_pain(sp, blob, black, kinds_present, have, frames, coltabs,
              rots, base_row):
    """The FLINCH frame -- info.c's painstate, one image per kind.

    DOOM's pain chain is two states of the same image that fall straight back
    into S_x_RUN1, so the engine needs no chain for it: ai_pain_row drops this
    row into TH_WROW for PTIC_EXT[kind] tics and the next RUN state takes the
    row back (enemy_ai_attack.asm). That is why only chain[0] is packed, and
    why the DURATION rides in a header of its own (pain_tics) instead of in
    the row -- ai_pain2 has the kind in Y and would have to multiply a row
    index by 8 to reach the row's own tics byte, which that 25-byte block
    cannot afford.

    Stored in the WALK cycle's NSTOR views, so spr_wrot turns the flinch with
    the monster; the row the header points at is view 0, exactly like WTAB_EXT.

    LAST in the blob and priced like the gib chains: a level that cannot afford
    a kind's frame leaves PTAB_EXT at $FF and that kind keeps its old,
    flinch-less behaviour. Nothing that already shipped can lose a frame to
    this.
    """
    d = doomstates.doom()
    pfirst = [0xFF] * DTAB_HDR
    rows, cache, flat = [], dict(have), []
    used = sum(4 * len(t) for t in coltabs)
    for ki, num in enumerate(MK_ORDER):
        if (ki + 1) not in kinds_present:
            continue
        chain = d.pain_chain(num)
        if not chain:
            continue                        # the barrel: no painstate, and its
        base, frame = chain[0][0], chain[0][1]      # painchance is 0 anyway
        if (DTAB_NHDR * DTAB_HDR
                + 8 * (base_row + len(rows) + len(rots))) > DTAB_MAX:
            print(f'  pain: {base}{frame} dropped -- the .dtab row space is full')
            break
        def price(views):                   # price it BEFORE storing a byte
            c = 0
            for rot in views:
                key = lump_norm(sp, base, frame, rot)
                pat = sp.patch(key[0]) if key else None
                if pat:
                    c += 4 * pat[0]
            return c

        # The flinch is stored in the walk cycle's FULL view set or not at all.
        # A one-view form (four rows pointing at the same lump, 150 B against
        # 600) was tried and thrown out: a monster that snaps to face the
        # camera for six tics whenever it is hit is worse than one that does
        # not flinch, and it would have been the form nearly every level got.
        views, cost = rots, price(rots)
        if used + cost > FTAB_OFF or len(frames) + len(views) >= NFRAMES_MAX - 1:
            print(f'  pain: {base}{frame} dropped -- wants {cost} B of coltab '
                  f'({FTAB_OFF - used} left) and {len(views)} frame ids '
                  f'({NFRAMES_MAX - 1 - len(frames)} left)')
            continue
        group = []
        for rot in views:
            key = lump_norm(sp, base, frame, rot)
            f = (_blit_frame(sp, blob, black, key[0], cache, frames, coltabs,
                             key[1]) if key else None)
            if f is None:
                print(f'  ! {base}{frame}/{rot}: no sprite lump, no flinch')
                break
            group.append(f + (0,))          # tics byte unused: the duration is
        if len(group) < len(rots):           #   PTIC_EXT[kind], not per row
            continue
        used += cost
        flat.append(f'{base}{frame}' + ('' if views is rots else '(1 view)'))
        pfirst[ki + 1] = base_row + len(rows)       # by KIND BYTE, see pack_death
        rows += group
    return pfirst, rows, flat


def _blit_frame(sp, blob, black, lump, cache, frames, coltabs, flip=False):
    """One sprite lump -> (addr, w, h, left, top) in the shared VRAM blob.
    `cache` maps (lump, flip) -> row so a frame the level already carries (the
    spawn frame IS run frame A) costs nothing the second time. None = unusable.
    `flip` stores the image MIRRORED -- pack-time normalisation for the rare
    WAD whose profile pair is named the other way round (see pack_walk): the
    engine's constant ROT4 table can then assume slot pixels are always the
    as-displayed rot-3 view. The left offset mirrors with it (w - left)."""
    key = (lump, bool(flip))
    if key in cache:
        return cache[key]
    pat = sp.patch(lump)
    if pat is None:
        return None
    w, h, left, top, cols = pat
    if flip:
        left = w - left
    if not (0 < w < 256 and 0 < h < 256 and -128 <= left < 128 and 0 <= top < 256):
        print(f'  ! {lump}: {w}x{h} off=({left},{top}) out of byte range')
        return None
    addr = _store_frame(blob, _cols_of(w, h, cols, black, flip), frames,
                        coltabs)
    if addr is None:                  # frame ids exhausted -- see _store_frame
        return None
    out = (addr, w, h, left, top)
    cache[key] = out
    return out


def _crop_cost(pat):
    """The bytes a patch REALLY costs stored (T4 crop): per column, first to
    last opaque texel. plan_views used w*h and with full textures on that
    overestimate (~1.6x) made it drop walk images levels can in fact afford."""
    w, h, _l, _t, cols = pat
    total = 0
    for posts in cols:
        lo = hi = None
        for (td, pix) in posts:
            a, b = max(0, td), min(h - 1, td + len(pix) - 1)
            if b < a:
                continue
            if lo is None:
                lo = a
            hi = b
        if lo is not None:
            total += hi - lo + 1
    return total


# The stored views, as DOOM LUMP ROTATION DIGITS. A monster frame ships five
# distinct images in the WAD (POSSA1, POSSA2A8, POSSA3A7, POSSA4A6, POSSA5) and
# the engine mirrors 2/3 back into DOOM rots 7/6, so these four cover SIX of
# the eight views with DOOM's own pixels: the two 3/4-BACK views (rots 3 and 5,
# digits 4 and 6) fall back on the plain back. Digit 4 is the one left out
# because a monster's back is what the player looks at least.
# (2026-08-25: said SEVEN here and in three other files, in every case while
#  listing six. Six is what the shipped spr_wrot actually returns.)
# Order matters: it IS the slot order (spr_wrot's swr_rot4 indexes it).
STORED_ROTS = (1, 2, 3, 5)


def lump_norm(sp, base, fr, rot):
    """(lump, store_flipped) for the STORED slot of `rot`, or None.
    store_flipped normalises the profile: the stored pixels are always the
    as-displayed rot view, whatever the WAD called the mirrored pair."""
    got = sp.lump_for(base, fr, rot)
    if got is None:
        return None
    return (got[0], bool(got[1]))


# plan_views prices the walk cycle and the attack states it PICKS, but `seen`
# is a set of (lump, flip) keys and the packers turn some of those into more
# than one stored frame -- and pack_idle, the gib chains, the pain rows and the
# flinch rows all run AFTER it and take ids of their own. The gap used to be
# invisible because the coltab ran out first; with the run at 40 KB it is not,
# and the way it showed was pack_walk asserting mid-level ("255 frames overflow
# the one-byte frame id"). So plan_views keeps a margin and steps down a rung
# instead. Empirical: E2M5 at a 48 KB run overflows without it.
FRAME_RESERVE = 40

def plan_views(sp, kinds_present, have, budget, base_rows, base_cols):
    """ONE decision for the whole level: (walk image cap, stored rotations).
    The attack chains and the walk cycle share it -- the engine has a single
    NSTOR (wn[0]) -- so the trial costs BOTH against the pixel budget AND
    against the DTAB row cap (the $0400 bank-01 slot: 118 rows after the five
    16-byte headers) AND against the coltab run (`base_cols` = the bytes the
    death frames and the sprite table already spent of the 24 KB at
    $01:9400; four per sprite COLUMN). Preference order: rotations first
    (that is the feature), a longer front-only cycle second; attack frames
    always ride along -- a level that cannot afford them drops the rotations
    before the attack (pack_atk packed first for exactly that reason, and
    still does).

    STORED_ROTS is DOOM lump digits 1/2/3/5 = four of the five distinct
    images a monster frame has in the WAD, which the engine mirrors back
    into six of DOOM's eight views (see pack_walk). NSTOR is 4 or 1 and
    NOTHING ELSE: spr_wrot's rot table and ai_setrow's img*NSTOR are both
    written for exactly those two, so a three-view trial would index rows
    that are not there. The 24 KB coltab run is what makes the choice
    binding -- E1M1/E1M2/E1M5 keep the four-image walk cycle, the crowded
    maps drop to two so the views fit."""
    d = doomstates.doom()
    kinds = [(ki, num) for ki, num in enumerate(MK_ORDER)
             if (ki + 1) in kinds_present and d.run_chain(num)]

    def wframes(num, cap):
        seen = []
        for _b, f, _t, _a in d.run_chain(num):
            if f not in seen:
                seen.append(f)
        return seen[:cap]

    def cost_of(key, seen):
        """(pixels, coltab bytes) a not-yet-stored (lump, flip) costs."""
        if key in seen:
            return 0, 0
        seen.add(key)
        pat = sp.patch(key[0])
        return (_crop_cost(pat), 4 * pat[0]) if pat else (0, 0)

    row_cap = (DTAB_MAX - DTAB_NHDR * DTAB_HDR) // 8   # + gib, the idle
                                                      #   trio and PTIC
    # ORDER = the preference. Rotations first while the cycle still ANIMATES,
    # but a one-image cycle is a monster standing still, and that is worse to
    # look at than one that walks and only ever shows you its front -- so the
    # front-only cycles come BEFORE (1, STORED_ROTS), not after. E3M9 is the
    # level that showed it: at a 44 KB run it took 1 image + 4 views over
    # 4 images + 1 view, and the cyberdemon stopped moving its legs.
    for cap, rots in ((6, STORED_ROTS), (4, STORED_ROTS), (2, STORED_ROTS),
                      (6, (1,)), (4, (1,)), (2, (1,)),
                      (1, STORED_ROTS), (1, (1,))):
        need, nrows, seen = 0, base_rows, set(have)
        ncol = base_cols
        ok = True
        for ki, num in enumerate(MK_ORDER):
            if (ki + 1) not in kinds_present:
                continue
            chain = atk_chain_of(d, num)
            if chain and any(a in ATK_ACTIONS for _b, _f, _t, a in chain):
                for (base, fr, _t, _a) in chain:
                    nrows += len(rots)
                    for rot in rots:
                        key = lump_norm(sp, base, fr, rot)
                        if key is None:
                            ok = False
                            break
                        px, cb = cost_of(key, seen)
                        need += px
                        ncol += cb
                    if not ok:
                        break
            if not ok:
                break
        for _ki, num in kinds:
            if not ok:
                break
            base = d.run_chain(num)[0][0]
            for fr in wframes(num, cap):
                nrows += len(rots)
                for rot in rots:
                    key = lump_norm(sp, base, fr, rot)
                    if key is None:
                        ok = False
                        break
                    px, cb = cost_of(key, seen)
                    need += px
                    ncol += cb
                if not ok:
                    break
        if (ok and need <= budget and nrows <= row_cap and ncol <= FTAB_OFF
                and len(seen) < NFRAMES_MAX - 1):
            return cap, rots
    return 0, (1,)


def pack_walk(sp, blob, black, kinds_present, nrows, have, cap, rots, frames,
              coltabs, cache=None):
    """The A_Chase walk frames, appended to the same VRAM blob and the same row
    array as the death frames (nrows = how many rows are already in it).

    ADAPTIVE, and that is the whole point: the sprite slot has 24 KB spare on
    E1M7 against the 26 KB a four-frame cycle for its five monster kinds wants
    (tools/_walk_budget.py), so the packer takes the widest cycle that FITS --
    4 images, else 2, else 1 -- and tells the engine how many via WTAB_N. The
    RUN state machine is 1:1 with info.c either way (8 states, A_Chase on each);
    only how many distinct legs you see changes.

    A row's tics byte is unused here (the state machine owns the timing, from
    mk_ctic) and is written 0.

    ROTATIONS (2026-08-03, the VRAM the pool freed; widened 2026-08-07):
    every walk image is stored in the four STORED_ROTS views -- DOOM lump
    digits 1 (front), 2 (3/4 front), 3 (profile) and 5 (back). Digits 2 and 3
    are drawn MIRRORED for DOOM rots 7 and 6 (the blitter's per-column draw
    indexes from the other end), which is exactly how the WAD itself ships
    them (A2A8 and A3A7 are ONE lump each), so six of DOOM's eight views
    are its own pixels and the front is 45 deg wide, not 135.
    THAT was the bug this replaced: with only rots 1/3/5 stored, the two 3/4
    front views collapsed onto the full front and every monster within 67
    degrees of the player's line stared straight at him.
    Rows are image-major: [img0: 4 views][img1: ...], so the engine's row is
    wfirst + img*NSTOR + slot. NSTOR (4, or 1 when only the front view fits --
    never anything else, see plan_views) travels in wn[0]; kind slot 0 means
    "not a monster" and is unused in every header. Each stored view is
    NORMALISED to its as-displayed image (_blit_frame flips it at pack time
    if the WAD's pair is named the other way round), so the engine's
    rot->slot/flip table is a constant -- enemy.asm swr_rot4.
    """
    d = doomstates.doom()
    kinds = [(ki, num) for ki, num in enumerate(MK_ORDER)
             if (ki + 1) in kinds_present and d.run_chain(num)]

    def frames_of(num, cap):
        seen = []
        for _b, f, _t, _a in d.run_chain(num):
            if f not in seen:
                seen.append(f)
        return seen[:cap]

    def lump_of(base, fr, rot):
        return lump_norm(sp, base, fr, rot)

    wfirst = [0xFF] * DTAB_HDR
    wn = [0] * DTAB_HDR
    rows = []
    if cache is None:                  # shared with pack_atk -- see there
        cache = dict(have)
    for ki, num in kinds:
        if not cap:
            break
        base = d.run_chain(num)[0][0]
        packed = []
        for fr in frames_of(num, cap):
            group = []
            for rot in rots:
                key = lump_of(base, fr, rot)
                f = (_blit_frame(sp, blob, black, key[0], cache, frames,
                                 coltabs, key[1])
                     if key else None)
                if f is None:
                    break
                group.append(f + (0,))
            if len(group) < len(rots):
                break
            packed.append(group)
        # WTAB_N used to index with a MASK, which forced a power of two and cost
        # the spider mastermind two of its six walk images. ai_setrow does a
        # modulo since 2026-08-21 (`cmp [dp],y / sbc [dp],y`), so a kind now
        # keeps every image it actually has.
        n = len(packed)
        if not n:
            continue
        wfirst[ki + 1] = nrows + len(rows)
        wn[ki + 1] = n
        for group in packed[:n]:
            rows += group
    wn[0] = len(rots)                  # WROT_NSTOR: the engine's single stored-
                                       #   view count (attack rows share it)
    assert wn[0] in (1, 4), (          # spr_wrot's `cmp #4` and ai_setrow's
        f'NSTOR {wn[0]}: the engine knows 4 stored views or 1, nothing else')
    return wfirst, wn, rows, cap       #   img*4 are written for exactly these


AT_FIRE = 0x40                # this attack state's action deals the damage
AT_LAST = 0x80                # ...and this one is the last: back to the RUN chain
AT_REFIRE = 0x20              # ...unless the chain LOOPS from here instead of
                              # ending -- p_enemy.c A_SpidRefire, which is what
                              # makes the spider mastermind a chaingun and not a
                              # shotgun guy with 3000 hit points. ai_refire
                              # (enemy_ai_attack.asm) is the engine half.
AT_TICS = 0x1F                # what is left for info.c's own tics once those
                              # three flags have had their bits. The longest
                              # attack state in DOOM is S_SPID_ATK1's 20, and
                              # the assert in pack_atk holds every kind to it.

# p_enemy.c's attack actions, as the engine's damage-roll selector. mk_atk
# carries this per kind; 0 = the kind has no attack this port can do. That is
# the LOST SOUL alone now: A_SkullAttack is a charge, not a projectile -- the
# monster itself becomes the missile (MF_SKULLFLY), which is a mover this
# engine does not have. The baron got its ball in 2026-08-08, the cacodemon
# on 2026-08-20.
ATK_ACTIONS = {'A_PosAttack': 1, 'A_SPosAttack': 2,
               'A_TroopAttack': 3, 'A_HeadAttack': 4,
               'A_BruisAttack': 5, 'A_CyberAttack': 6,
               'A_SargAttack': 7}
# THE ORDER IS LOAD-BEARING (2026-08-20). at_tables.inc is emitted over
# ATM_LO..ATM_HI and lives in a 25-byte hole at $F067 with fps_win hard against
# it, so it has room for FOUR rows of six tables and not five. Putting
# A_HeadAttack on 4 -- the slot A_SargAttack used to waste, because the demon
# is melee-only and throws nothing -- keeps every MISSILE action contiguous at
# 3..6 and the table exactly the size it always was. A_SargAttack moved to 7,
# outside the range, which it can afford: ai_fire routes it to its own melee
# branch and it never reaches ball.asm at all.
# 7 = A_HeadAttack (2026-08-20), the CACODEMON -- the one monster in episodes
# 1-3 that had no attack at all: mk_atk 0 meant pack_atk skipped its chain, so
# it chased the player and never did a thing. p_enemy.c gives it A_TroopAttack's
# shape with two numbers changed -- melee (P_Random()%6+1)*10 instead of
# (%8+1)*3, and NO attacksound where the imp plays sfx_claw -- and its missile
# is MT_HEADSHOT, the red BAL2 ball, damage 5 at MT_TROOPSHOT's own speed.
# 6 = A_CyberAttack (p_enemy.c): P_SpawnMissile(MT_ROCKET) and no melee branch
# at all. ai_fire routes it straight to ball_spawn, and ball.asm's bl_pick /
# bl_roll read the SAME mk_atk byte to pick MISL over BAL1/BAL7 and damage 20
# over 3/8. The SPIDER needs no entry of its own: its missile chain is
# A_SPosAttack, the shotgun guy's three-pellet burst, so it lands on 2 the way
# SPOS does -- one hitscan path, two kinds.


def noblast_types():
    """p_map.c PIT_RadiusAttack, the two lines nothing else in DOOM has:

        // Boss spider and cyborg
        // take no damage from concussion.
        if (thing->type == MT_CYBORG || thing->type == MT_SPIDER)
            return true;

    A rocket, a barrel and another cyberdemon's rocket all bounce off the two
    final bosses -- it is the only immunity in the game and it is hardcoded, not
    a flag, so it is READ OUT OF THE C here rather than retyped. -> the set of
    doomednums."""
    src = open(os.path.join(os.path.dirname(doomstates.SRC), 'p_map.c'),
               encoding='latin-1').read()
    body = re.search(r'PIT_RadiusAttack\s*\([^)]*\)\s*\{.*?\n\}', src, re.S)
    if not body:
        sys.exit('  ERROR: PIT_RadiusAttack not found in _pomocne/_doomsrc/p_map.c')
    d = doomstates.doom()
    out = set()
    for mt in re.findall(r'thing->type\s*==\s*(MT_\w+)', body.group(0)):
        dn = d.fields_of_type(mt).get('doomednum')
        if dn and dn.lstrip('-').isdigit():
            out.add(int(dn))
    return out


def noblast_radius():
    """...expressed as the one number the engine can afford: the smallest
    PIT_CheckThing radius among those types.

    en_bdist (enemy.asm) has no room for a per-kind table and TH_RAD is already
    a page it can reach, so the test is `radius >= this`. That is only the same
    question while the immune types are exactly the WIDEST ones, which is what
    the assert pins -- a WAD that broke it fails the pack instead of silently
    handing some other monster a boss's immunity."""
    d = doomstates.doom()
    immune = noblast_types() & set(MK_ORDER)
    if not immune:
        return 256                                  # nothing immune: unreachable
    r = min(d.radius(n) for n in immune)
    wide = {n for n in MK_ORDER if d.radius(n) >= r}
    assert wide == immune, \
        f'PIT_RadiusAttack exempts {sorted(immune)} but radius >= {r} also ' \
        f'catches {sorted(wide - immune)} -- en_bdist\'s one-compare form is ' \
        f'no longer the same question, so it needs a real per-kind table'
    return r


def atk_chain_of(d, num):
    """The chain a kind actually attacks with: its missilestate if it has one,
    otherwise its meleestate. For the imp and the baron info.c gives BOTH names
    the same S_x_ATK states, so this is one chain either way and the action on
    the last state decides what it does."""
    ch = d.atk_chain(num)
    return ch if ch else d.atk_chain(num, melee=True)


def atk_loop_of(d, num):
    """...and where THAT chain's last state loops back to (None = it ends).
    Same missile-then-melee order as atk_chain_of, so the two always describe
    the one chain that got packed."""
    return d.atk_loop(num) if d.atk_chain(num) else d.atk_loop(num, melee=True)


def pack_atk(sp, blob, black, kinds_present, nrows, have, frames, coltabs,
             rots=(1,), cache=None):
    """The A_Chase attack states, into the same blob and row array as the death
    and walk frames. Packed BEFORE the walk cycle on purpose: a level that
    cannot afford both gives up walk images (cosmetic) rather than the attack
    (gameplay) -- E1M8 is the one that has to, because the baron's frames are
    enormous.

    A row's tics byte carries info.c's own tics plus AT_FIRE on the state whose
    action deals damage, AT_LAST on the last one, and AT_REFIRE beside AT_LAST
    when info.c points that last state back INTO the chain instead of at
    S_x_RUN1 -- p_enemy.c A_SpidRefire, the spider mastermind's chaingun (see
    doomstates.atk_loop and enemy_ai_attack.asm ai_refire).

    `cache` is SHARED with pack_walk (2026-08-20). It used to be a fresh
    dict(have) in each, which cost nothing while no kind's attack chain reused
    a walk image -- and every episode-1 kind runs A-D and attacks with E-G. The
    SPIDER MASTERMIND is the first that does not: S_SPID_ATK1 is SPID A, its
    own first RUN image, so the two passes stored that frame twice, in all four
    views. plan_views has always priced attack and walk against ONE `seen`, so
    the two agree again now -- and on E3M8 that is 3356 B of the 24 KB coltab
    run and ~100 KB of pool, which is the difference between the spider keeping
    its four views and dropping to one.
    """
    d = doomstates.doom()
    afirst = [0xFF] * DTAB_HDR
    an = [0] * DTAB_HDR
    rows = []
    if cache is None:
        cache = dict(have)
    for ki, num in enumerate(MK_ORDER):
        if (ki + 1) not in kinds_present:
            continue
        chain = atk_chain_of(d, num)
        if not chain or not any(a in ATK_ACTIONS for _b, _f, _t, a in chain):
            continue                       # projectile-only: nothing to pack
        loop = atk_loop_of(d, num)         # p_enemy.c A_SpidRefire, or None
        # Every REFIRE chain in DOOM loops back to state 1 -- SPID, and DOOM 2's
        # CPOS/BSPI/SSWV -- which is the only target ai_refire can express (it
        # zeroes ai_awst and lets ai_atk_next's own +1 do the rest). The LOST
        # SOUL is the one chain that loops anywhere else: S_SKULL_ATK4 -> ATK3,
        # a charge animation that P_SkullAttack's collision breaks out of, not a
        # refire at all. It never reaches here (A_SkullAttack is not an
        # ATK_ACTION, so the `continue` above skips the kind), and if it ever
        # does this has to be looked at rather than shipped.
        if loop not in (None, 1):
            sys.exit(f'  ERROR: {chain[0][0]}: info.c loops its attack chain '
                     f'back to state {loop}, not state 1. ai_refire '
                     f'(enemy_ai_attack.asm) can only express 1 -- see the note '
                     f'above before adding this kind\'s action to ATK_ACTIONS.')
        packed = []                        # groups: one state = len(rots) rows
        for n, (base, frame, tics, act) in enumerate(chain):
            assert 0 < tics <= AT_TICS, \
                f'{base}{frame}: {tics} tics does not fit in five -- AT_REFIRE ' \
                f'took bit 5 for the spider (memory_map.inc)'
            t = tics
            if act in ATK_ACTIONS:
                t |= AT_FIRE
            if n == len(chain) - 1:
                t |= AT_LAST
            group = []
            for rot in rots:               # state-major x NSTOR, every slot with
                key = lump_norm(sp, base, frame, rot)   # the SAME tics byte --
                f = (_blit_frame(sp, blob, black, key[0], cache, frames,
                                 coltabs, key[1])
                     if key else None)     # ai_atk_tics reads slot 0's
                if f is None:
                    print(f'  ! {base}{frame}/{rot}: no sprite lump, '
                          f'attack chain cut short')
                    break
                group.append(f + (t,))
            if len(group) < len(rots):
                break
            packed.append(group)
        if not packed:
            continue
        # AT_LAST on the REAL last state, in every slot copy -- and AT_REFIRE
        # beside it only when the WHOLE chain made it in. A chain cut short by a
        # missing lump would otherwise loop a monster round two of its four
        # states for ever, which is a worse answer than "it stops shooting".
        last = AT_LAST | (AT_REFIRE if loop is not None
                          and len(packed) == len(chain) else 0)
        for s in range(len(rots)):
            packed[-1][s] = packed[-1][s][:5] + (packed[-1][s][5] | last,)
        afirst[ki + 1] = nrows + len(rows)
        an[ki + 1] = len(packed)
        for group in packed:
            rows += group
    return afirst, an, rows


# ---------------------------------------------------------------------------
# IDLE ANIMATION (2026-08-07, "barely by mali byt animovane.. a aj ine veci").
# info.c gives the barrel spawnstate S_BAR1 <-> S_BAR2 and most pickups a
# ping-pong: BON1/BON2/SOUL/PMAP are ABCDCB at 6 tics, PINS ABCD, the keys AB at
# 10, TRED ABCD at 4. The port drew frame A and stopped.
#
# It rides the DTAB rows the death/walk/attack machines already use -- byte 0 is
# the frame id and bytes 3-6 are w/h/left/top, exactly the sprite table's own
# layout -- so an_tick (sprites.asm) advances a ring by COPYING a row over the
# sprite table entry. No per-thing state: every item of a kind spawns on the
# same tic in DOOM, so they animate in phase off one counter, and the engine
# pays one byte-decrement per ring per DOOM tic.
#
# MONSTERS ARE EXCLUDED on purpose: their idle A/B breathing would fight the
# walk cycle's own rows, and an awake one is already animated by the RUN chain.
ITAB_MAX = 16


def _idle_ring(doomednum):
    """info.c spawnstate chain -> (sprite base, [(frame letter, tics)]) when it
    really moves.

    The SEQUENCE, not the distinct images: BON1 is ABCDCB, a ping-pong over four
    lumps, and _blit_frame's cache makes the repeats free. One frame (or a -1
    tics frame) means static -- every wall torch, corpse and tree in episode 1.
    """
    d = doomstates.doom()
    e = d.mobj.get(doomednum)
    if not e:
        return None
    chain = d._chain(e.get('spawnstate', 'S_NULL'))
    if len({f for _s, f, _t, _a in chain}) < 2:
        return None
    if any(t <= 0 for _s, _f, t, _a in chain):
        return None
    return chain[0][0], [(f, t) for _s, f, t, _a in chain]


def pack_idle(sp, blob, black, anim_of, have, frames, coltabs, base_row,
              coltab_used):
    """Idle rings for the level's animated NON-monster sprites.

    anim_of: sprite id -> (sprite base, [(frame letter, tics), ...]).
    Returns (sid, first, n, rows, coltab used) -- three ITAB_MAX-byte arrays.
    """
    sid = [0xFF] * ITAB_MAX
    first = [0xFF] * ITAB_MAX
    count = [0] * ITAB_MAX
    rows = []
    used = coltab_used
    slot = 0
    cache = dict(have)

    def ring_cost(spr_id, base_cache):
        """Coltab bytes this ring would really add: each DISTINCT new lump
        once. The old estimate had no dedup inside the chain, so a ping-pong
        (BON1 is ABCDCB) priced B and C twice -- rings were dropped for
        budget they never needed, and `used` swallowed the phantom bytes
        too (2026-08-10)."""
        base, chain = anim_of[spr_id]
        c, seen = 0, set(base_cache)
        for fr, _t in chain:
            got = sp.lump_for(base, fr, 1)
            pat = sp.patch(got[0]) if got else None
            if pat and (got[0], False) not in seen:
                seen.add((got[0], False))
                c += 4 * pat[0]
        return c

    # CHEAPEST FIRST. The order used to be the sprite id -- whatever the
    # level's spawn order made it -- so one expensive PMAP ring could eat
    # the budget three torches would have shared: E1M8's RED torches stood
    # still while the green and blue ones flickered. Greedy by cost is the
    # order that animates the most sprites a fixed budget can carry, and
    # the big pickup rings are the ones a player watches least.
    for spr_id in sorted(anim_of,
                         key=lambda s: (ring_cost(s, have), anim_of[s][0])):
        if slot >= ITAB_MAX:
            print(f'  idle: no ring slot left for sprite {spr_id}')
            break
        base, chain = anim_of[spr_id]
        cost = ring_cost(spr_id, cache)           # price it BEFORE storing
        if used + cost > FTAB_OFF or len(frames) + len(chain) >= NFRAMES_MAX - 1:
            print(f'  idle: {base} ring dropped -- wants {cost} B of coltab '
                  f'({FTAB_OFF - used} left) and {len(chain)} frame ids '
                  f'({NFRAMES_MAX - 1 - len(frames)} left)')
            continue
        used += cost
        packed = []
        for fr, tics in chain:
            got = sp.lump_for(base, fr, 1)
            if got is None:
                packed = []
                break
            f = _blit_frame(sp, blob, black, got[0], cache, frames, coltabs)
            if f is None:
                packed = []
                break
            assert 0 < tics < 128, f'{base}{fr}: {tics} tics needs 7 bits'
            packed.append((f[0], f[1], f[2], f[3], f[4], tics))
        if len(packed) < 2:
            continue
        sid[slot] = spr_id
        first[slot] = base_row + len(rows)
        count[slot] = len(packed)
        rows += packed
        slot += 1
    return sid, first, count, rows, used


def emit_dtab(dfirst, wfirst, wn, afirst, pfirst, xfirst, isid, ifirst, icnt,
              ptic, rows):
    """The .dtab blob: TEN 16-byte headers (death first-row, walk first-row,
    walk image count, attack first-row, FLINCH first-row, gib first-row, the
    idle ring's sprite id / first row / row count, and the FLINCH TICS) then
    the 8-byte rows every one of those machines shares.

    Header 5 was the attack STATE COUNT until 2026-08-16 -- emitted from the
    day the attack chain landed and never read by one line of 6502, since
    ai_atk_next ends the chain off the row's own AT_LAST bit. The flinch took
    the slot rather than a tenth header, which would have moved DTAB_ROWS.

    Header 10 (PTIC_EXT, 2026-08-26) is the one that finally did move it, and
    the row array starts at $01:8CA0 now. It buys the flinch its info.c
    DURATION -- PAIN_TICS used to be one number for every kind and the
    cyberdemon's painstate is 10 tics against the imp's 4 -- and it is here
    rather than in a base-RAM mk_* table because base RAM has not one block of
    16 B left (tools/ram_map.py) while the row array had sixteen: the busiest
    level in the game, E1M6, packs 222 rows of the 236 ten headers leave.
    ai_pain2 reads it with the low byte of the pointer it already has on
    PTAB_EXT, which is why this header has to stay on page $8C with that one."""
    out = (bytearray(dfirst) + bytearray(wfirst) + bytearray(wn)
           + bytearray(afirst) + bytearray(pfirst) + bytearray(xfirst)
           + bytearray(isid) + bytearray(ifirst) + bytearray(icnt)
           + bytearray(ptic))
    assert len(out) == DTAB_NHDR * DTAB_HDR,         f'{len(out)} B of headers, not {DTAB_NHDR} x {DTAB_HDR} -- '         'memory_map.inc DTAB_ROWS moves with this'
    for (fid, w, h, left, top, t) in rows:
        out += struct.pack('<BBBBBbBB', fid, 0, 0,    # B1: byte 0 = frame id,
                           w, h, left, top, t)        #   bytes 1-2 spare
    if len(out) > DTAB_MAX:
        sys.exit(f'  ERROR: .dtab {len(out)} B > the {DTAB_MAX} B bank $01 slot '
                 f'({len(rows)} death + walk frames)')
    return bytes(out)


def pack(md, sp, skill=SKILL, decor_cut=0, obst_cut=0, bfg=True):
    """bfg=False (2026-08-28): leave MT_BFG's own frames out. The LAST rung of
    main()'s ladder, below every decoration: a dropped lamp is missing from the
    room forever, a dropped BFG ball only means that on this one level the shot
    resolves the tic it is fired instead of flying (pj_bspawn's $FF path). Only
    E2M2 needs it.

    decor_cut/obst_cut (2026-08-18, E2/E3): drop the LAST n non-blocking
    C_DECOR things (corpses, gore piles), then -- if still over -- the last n
    C_OBSTACLE decorations (lamps, pillars; BARRELS never, they are
    gameplay). main() retries with growing cuts when the RAM blob overflows
    THINGS_MAX -- E2M2's 725-subsector prefix plus 229 things beat the $C000
    slot, and cosmetics are the honest thing to lose. Dropping a blocker
    only OPENS space, so it can never wall a route off."""
    black = darkest_nonzero(sp.wt.playpal)
    sprites = {}                       # lump -> id
    bonus_of = {}                      # sprite id -> bonus id
    hp_of = {}                         # sprite id -> info.c spawnhealth (u16)
    kind_of = {}                       # sprite id -> MK_ORDER index + 1
    blob = SPRPOOL                     # B2: every level packs into THE pool
    frames = []                        # frame id -> (POOL offset, stored size)
    coltabs = []                       # frame id -> [(off, top, len)]
    tab = []                           # (frame id, w, h, left, top, lump)
    things = []                        # (ssid, x, y, z, sprid)
    anim_of = {}                       # sprite id -> (base, [(frame, tics)])

    mts = map_things(md, skill=skill)
    for cls_cut, n_cut, spare in ((C_DECOR, decor_cut, ()),
                                  (C_OBSTACLE, obst_cut, ('BAR1',))):
        if not n_cut:
            continue
        cuttable = [e for e in mts if e[3] == cls_cut and e[1] not in spare]
        keep = len(cuttable) - n_cut
        kept, out_mts = 0, []
        for e in mts:
            if e[3] == cls_cut and e[1] not in spare:
                kept += 1
                if kept > keep:
                    continue
            out_mts.append(e)
        mts = out_mts
    for (t, base, frame, cls, radius, height, hung) in mts:
        if base is None:
            continue
        got = sp.lump_for(base, frame, 1)
        if got is None:
            continue
        lump = got[0]
        if lump not in sprites:
            pat = sp.patch(lump)
            if pat is None:
                continue
            w, h, left, top, cols = pat
            if not (0 < w < 256 and 0 < h < 256 and -128 <= left < 128 and 0 <= top < 256):
                print(f'  skip {lump}: {w}x{h} off=({left},{top}) out of byte range')
                continue
            sprites[lump] = len(tab)
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            tab.append((addr, w, h, left, top, lump))
        ssid = wad_subsector(md, t.x, t.y)
        sec = md.sectors[wad_sector_of_ss(md, ssid)]
        z = (sec.ceil_h - height) if hung else sec.floor_h
        bn = BONUS.get(t.type, 0)
        if bn:
            bonus_of[sprites[lump]] = bn
        if cls != C_MONSTER and sprites[lump] not in anim_of:
            ring = _idle_ring(t.type)          # info.c spawnstate, >1 frame?
            if ring:
                anim_of[sprites[lump]] = ring
        fl = (1 if cls in PICKUP else 0) | (2 if cls == C_OBSTACLE else 0)
        # bit3 = MF_SHADOW (info.c MT_SPECTRE). It has to ride on the THING and
        # not on the sprite: the spectre and the demon are both SARG, one sprite
        # id, so the sprite table cannot tell them apart. spr_draw.asm draws a
        # flagged thing see-through (every other screen column).
        fl |= 8 if t.type == 58 else 0
        # bits 4-6 = the SPAWN FACING as an octant: P_SpawnMapThing does
        # mobj->angle = ANG45 * (mthing->angle/45), and an idle monster shows
        # you its back if you come from behind. en_init seeds TH_DIR from this,
        # so the same rotation pick (spr_wrot) serves idle and chasing alike.
        fl |= ((t.angle // 45) & 7) << 4
        # p_map.c PIT_CheckThing blocks on MF_SOLID: monsters and the obstacle
        # decorations (barrel, pillar, lamp). A pickup is MF_SPECIAL, never
        # MF_SOLID, so it stays walk-through. No radius is stored -- see the
        # OBSTACLE_R note; this only checks the rule still holds.
        if cls in (C_MONSTER, C_OBSTACLE):
            _check_radius_rule(md.name, t.type, lump, cls, radius)
        hp = MONSTER_HP.get(t.type, 0)
        if hp and t.type in MK_ORDER:
            kind_of[sprites[lump]] = MK_ORDER.index(t.type) + 1
        if hp:
            hp_of[sprites[lump]] = hp     # per SPRITE entry, not per thing: one
                                          #   monster type = one spawn sprite, and
                                          #   there are ~30 sprites against ~255
                                          #   things (the blob has no room for the
                                          #   per-thing form -- E1M6 overflowed)
        things.append((ssid, t.x, t.y, z, sprites[lump], fl, hp, t.type))

    # --- the imp's fireball (MT_TROOPSHOT). It is not a map thing, so nothing
    #     above pulls its sprite in: force BAL1 A/B into the table on any level
    #     that spawns an imp, and hand the engine the id. 15x15 twice = 450 B,
    #     which fits even E1M7's 2656 B of headroom. The EXPLOSION frames
    #     (BAL1 C/D/E, 5055 B) do NOT fit five of the nine levels, so the port
    #     has none anywhere -- the ball simply stops existing. Consistency beats
    #     a puff that only some maps can afford. Only frame A is packed, not the
    #     A/B flicker: a second sprtab row is 8 B of the .things blob and E1M6
    #     has four to spare. The ball is 15x15 and moving; the flicker would not
    #     be visible at this resolution anyway.
    ball_id = 0xFF
    ball_xid = 0xFF
    if any(t.type == 3001 for (t, b, _f, _c, _r, _h, _hu)
           in map_things(md, skill=skill) if b is not None):
        # A = the ball in flight (the A/B flicker is still one frame -- 15x15
        # and moving, invisible at this resolution). C/D/E = S_TBALLX1..3,
        # P_ExplodeMissile's burst, 6 tics each; they were once dropped for
        # VRAM ("fits no more than 4 of 9 arenas") but B1 killed the byte
        # budget -- pixels live in SDRAM and the arena caches them -- so the
        # burst costs three sprtab rows and nothing else. Packed back to
        # back, so C/D/E hold CONSECUTIVE ids and the engine just inc's.
        for fr in 'ACDE':
            got = sp.lump_for('BAL1', fr, 1)
            if got is None or got[0] in sprites:
                continue
            pat = sp.patch(got[0])
            if pat is None:
                break
            w, h, left, top, cols = pat
            sprites[got[0]] = len(tab)
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            tab.append((addr, w, h, left, top, got[0]))
        got = sp.lump_for('BAL1', 'A', 1)
        if got and got[0] in sprites:
            ball_id = sprites[got[0]]
        got = sp.lump_for('BAL1', 'C', 1)
        if got and got[0] in sprites:
            ball_xid = sprites[got[0]]
        print(f'  fireball: BAL1 A -> sprite {ball_id}, '
              f'burst C/D/E -> {ball_xid}..+2')

    # --- MT_BRUISERSHOT, the BARON's fireball (2026-08-08). Same four frames in
    #     the same order, so the engine's "burst = flight + 1" holds for this one
    #     too and bl_pick only has to choose ONE id. BAL7's flight frames are
    #     ROTATED in the WAD (BAL7A1A5 and friends) where BAL1's are rotation 0;
    #     lump_for(.., 1) asks for the same view either way. Only E1M8 pays for
    #     it -- it is the only map in the episode with a baron on skill 2.
    bal7_id = 0xFF
    if any(t.type == BARON for (t, b, _f, _c, _r, _h, _hu)
           in map_things(md, skill=skill) if b is not None):
        for fr in 'ACDE':
            got = sp.lump_for('BAL7', fr, 1)
            if got is None or got[0] in sprites:
                continue
            pat = sp.patch(got[0])
            if pat is None:
                break
            w, h, left, top, cols = pat
            sprites[got[0]] = len(tab)
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            tab.append((addr, w, h, left, top, got[0]))
        got = sp.lump_for('BAL7', 'A', 1)
        if got and got[0] in sprites:
            bal7_id = sprites[got[0]]
            burst = sp.lump_for('BAL7', 'C', 1)
            assert burst and sprites.get(burst[0]) == bal7_id + 1, \
                'BAL7 C must land right behind A -- bl_pick derives the burst id'
        print(f'  baron fireball: BAL7 A -> sprite {bal7_id}, '
              f'burst C/D/E -> {bal7_id + 1}..+2')

    # --- MT_HEADSHOT, the CACODEMON's ball (2026-08-20). Third instance of the
    #     same four frames in the same order (flight A, burst C/D/E), so
    #     bl_pick's "burst = flight + 1" holds here too and the engine needs no
    #     new code at all -- at_tables.inc carries the damage (5, not 3 or 20),
    #     the launch sfx_firsht and the burst sfx_firxpl, and ball.asm reads
    #     them off mk_atk exactly as it does for the imp and the baron.
    #     BAL2 A is 16x16, the burst 45x48/50x42/53x47: ~7 KB of pool, which
    #     goes to SDRAM (B2), and ~656 B of the level's 24 KB coltab run.
    bal2_id = 0xFF
    if any(t.type == CACO for (t, b, _f, _c, _r, _h, _hu)
           in map_things(md, skill=skill) if b is not None):
        for fr in 'ACDE':
            got = sp.lump_for('BAL2', fr, 1)
            if got is None or got[0] in sprites:
                continue
            pat = sp.patch(got[0])
            if pat is None:
                break
            w, h, left, top, cols = pat
            sprites[got[0]] = len(tab)
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            tab.append((addr, w, h, left, top, got[0]))
        got = sp.lump_for('BAL2', 'A', 1)
        if got and got[0] in sprites:
            bal2_id = sprites[got[0]]
            burst = sp.lump_for('BAL2', 'C', 1)
            assert burst and sprites.get(burst[0]) == bal2_id + 1,                 'BAL2 C must land right behind A -- bl_pick derives the burst id'
        print(f'  cacodemon fireball: BAL2 A -> sprite {bal2_id}, '
              f'burst C/D/E -> {bal2_id + 1}..+2')

    # --- the player's missiles (2026-08-04): MT_ROCKET and MT_PLASMA fly as
    #     visible sprites (proj.asm). Not map things either, and the launcher
    #     travels with the player, so the frames go in on EVERY level.
    #     info.c: rocket = MISL A flight + MISL B/C/D burst (S_EXPLODE1..3,
    #     8/6/4 tics); plasma = PLSS A flight (the A/B flicker is one frame,
    #     the ball's own reduction) + PLSE A/B/C burst (of A..E -- the last
    #     two are the fade; three rows keep the fattest arenas honest).
    #     ...and the bullet PUFF (2026-08-05). p_map.c spawns MT_PUFF wherever a
    #     hitscan stops on a line, so every level needs it -- the player always
    #     carries a hitscan. S_PUFF1..4 = PUFF A/B/C/D at 4 tics each, packed
    #     back to back so the engine just inc's the id (proj.asm pf_frameb).
    #     454 B of pixels for all four, less than ONE PLSE frame.
    #     ...and BLOOD (p_map.c:1005): a hitscan that reaches a THING spawns
    #     MT_BLOOD unless it has MF_NOBLOOD (of everything in E1 that is only
    #     the barrel, info.c MT_BARREL). info.c runs the chain BACKWARDS --
    #     S_BLOOD1/2/3 are BLUD C, B, A -- so they are packed C,B,A and the
    #     engine can walk them with an inc like every other chain here.
    #     ...and the BFG BALL (2026-08-28). info.c MT_BFG: spawnstate
    #     S_BFGSHOT = BFS1 A/B at 4 tics, deathstate S_BFGLAND = BFE1 A..F at
    #     8. Cut the same way the two above are: ONE flight frame (the A/B
    #     flicker is what the plasma already gives up) and THREE burst frames
    #     of the six (the last three are the fade). It fired a PLASMA bolt for
    #     one build and that was simply the wrong picture of the right event.
    missiles = [('MISL', 'ABCD'), ('PLSS', 'A'), ('PLSE', 'ABC'),
                ('PUFF', 'ABCD'), ('BLUD', 'CBA')]
    if bfg:
        missiles[3:3] = [('BFS1', 'A'), ('BFE1', 'ABC')]
    for spr, frs in missiles:
        for fr in frs:
            got = sp.lump_for(spr, fr, 1)
            if got is None or got[0] in sprites:
                continue
            pat = sp.patch(got[0])
            if pat is None:
                break
            w, h, left, top, cols = pat
            sprites[got[0]] = len(tab)
            addr = _store_frame(blob, _cols_of(w, h, cols, black), frames,
                                coltabs)
            tab.append((addr, w, h, left, top, got[0]))

    def _msid(spr, fr):
        got = sp.lump_for(spr, fr, 1)
        return sprites.get(got[0], 0xFF) if got else 0xFF
    rock_id, rock_xid = _msid('MISL', 'A'), _msid('MISL', 'B')
    plas_id, plas_xid = _msid('PLSS', 'A'), _msid('PLSE', 'A')
    puff_id, blud_id = _msid('PUFF', 'A'), _msid('BLUD', 'C')
    bfgs_id = _msid('BFS1', 'A') if bfg else 0xFF
    bfge_id = _msid('BFE1', 'A') if bfg else 0xFF
    print(f'  missiles: MISL A -> {rock_id}, burst B/C/D -> {rock_xid}..+2 | '
          f'PLSS A -> {plas_id}, PLSE A/B/C -> {plas_xid}..+2 | '
          f'BFS1 A -> {bfgs_id}, BFE1 A/B/C -> {bfge_id}..+2 | '
          f'PUFF A/B/C/D -> {puff_id}..+3 | BLUD C/B/A -> {blud_id}..+2')

    things.sort(key=lambda r: r[0])
    n_ss = len(md.ssectors)
    if len(things) > 255:
        print(f'  WARNING: {len(things)} things > 255 -- keeping the first 255')
        things = things[:255]

    prefix = bytearray(n_ss + 1)                          # prefix[s] = first index
    i = 0
    for s in range(n_ss + 1):
        while i < len(things) and things[i][0] < s:
            i += 1
        prefix[s] = i

    p_ss = THINGS_BASE + HEADER
    p_things = p_ss + len(prefix)
    p_sprtab = p_things + len(things) * 8

    # ---- trigger table: walkover (W1/WR) + switches (S1/SR) + walkover doors --
    # Verified against _pomocne/_doomsrc p_spec.c (P_CrossSpecialLine) and
    # p_switch.c (P_UseSpecialLine). One 16 B record per (line, tagged sector);
    # readers: movers.asm mv_start/check_triggers, doors.asm switch_match/
    # trig_fire.
    #   walkover: a1,a2 rooms | x1,y1,x2,y2 line   | sector|flags | dst floor
    #   USE/GUN:  $8000,$8000 | 4x seg RECORD ADDR | sector|flags | dst floor
    # A USE record's room test can never pass ($8000 is no sector id), so the
    # walkover scan skips it for free; try_use matches its hit seg by ADDRESS
    # (MAP_SEGS + i*8, from map_syms.inc), so USE runs no geometry at all. A GUN
    # record is matched the same way, by gun_match, against the seg the BULLET
    # stopped on (doors.asm / pf_shot).
    # Flags: b15 floor stays down (mv_start also marks the fired bitmap)
    #        b14 USE  b13 DOOR action (dst unused: MAP_DOORS has the height)
    #        b12 once (spend a fired-bitmap bit)  b11 the door stays open
    #        b10 TELEPORT (dst = index into the destination table, not a height)
    #        b9  the DOOR action CLOSES (specials 16/76) instead of opening
    #        b8  GUN (impact) -- fired by a shot, never by USE or a walkover
    # so a sector id has b0-b7, 0..255 (E1M6, the biggest, has 250 sectors).
    # (the flags and SPEC itself are module level -- doomspecs.py cross-checks
    #  them against the shared special sets, and _verify_* tools read them)
    seg_base = _map_segs_base()
    tele_of, tele = _tele_dests(md)
    trig = []
    chg = []                     # (trigger index, the floor colour it takes)
    xkind = {}                   # trigger index -> byte 3: 1 = EXIT, 2 = SECRET
    # p_spec.c P_CrossSpecialLine: `case 52: G_ExitLevel()` and
    # `case 124: G_SecretExitLevel()`. They are WALKOVER exits -- the whole of
    # episode 3 plus E2M9 end that way (E3M6's is the teleport-looking alcove at
    # ld596) -- and until 2026-08-27 the port could not finish any of them: the
    # EXIT bit on the seg is only ever read by use_leaf, i.e. the USE ray.
    # They drive no mover and carry no tag, so they get a record for one reason
    # only: check_triggers' crossing test has to SEE the line. Byte 3 of the
    # record is a pad, which is where "which exit" goes.
    WALK_EXITS = {52: 1, 124: 2}
    gun_segs, gun_idx = [0, 0], 0xFF  # the header trio doors.asm reads (0 = none)
    for li, ld in enumerate(md.linedefs):
        xk = WALK_EXITS.get(ld.special)
        if xk:
            xa1 = md.sidedefs[ld.right].sector if ld.right != NO_SIDEDEF else 0xFF
            xa2 = md.sidedefs[ld.left].sector if ld.left != NO_SIDEDEF else xa1
            xv1, xv2 = md.vertices[ld.v1], md.vertices[ld.v2]
            xkind[len(trig)] = xk
            trig.append((xa1, xa2,
                         struct.pack('<hhhh', xv1.x, xv1.y, xv2.x, xv2.y),
                         F_ONCE, 0, 0))      # no sector, no height, no speed
            continue
        spec = SPEC.get(ld.special)
        if not spec or not ld.tag:
            continue
        flags, kind = spec
        spd = SPEED_MAP.get(md.name, {}).get(ld.special,
                            SPEED.get(ld.special, 0))
        if flags & (F_USE | F_GUN):
            idxs = [i for i, sg in enumerate(md.segs)
                    if sg.linedef == li and sg.side == 0]
            assert 1 <= len(idxs) <= 4, \
                f'switch line {li}: {len(idxs)} front segs (1..4 supported)'
            if flags & F_GUN:
                # ONE gun line per level, one seg per side: the engine compares
                # an address instead of walking the trigger table, both when a
                # bullet stops on it (gun_match) and when the USE ray crosses it
                # (try_use has to refuse it -- see gun_seg_p). BOTH sides go in:
                # standing INSIDE the opened secret and pressing USE crosses the
                # other face of the very same line, and that closed the door.
                both = [i for i, sg in enumerate(md.segs) if sg.linedef == li]
                if gun_segs != [0, 0]:
                    # E2/E3 (2026-08-18): a SECOND impact line -- the header
                    # holds exactly one (gun_segs + gun_idx). The first wins,
                    # the rest stay inert walls; E2M4 pairs a G1 floor with
                    # the GR door and only one can be the gun line.
                    print(f'  {md.name}: gun line {li} dropped -- the header '
                          f'holds one gun line and it is taken')
                    continue
                assert len(both) <= 2, \
                    f'gun line {li}: {len(both)} segs, the header holds two'
                gun_segs = [(seg_base + i * 8) & 0xFFFF for i in both]
                gun_segs += [0] * (2 - len(gun_segs))
                gun_idx = len(trig)      # the record this line is about to add
            mid = struct.pack('<HHHH',
                              *[(seg_base + i * 8) & 0xFFFF for i in idxs]
                              + [0] * (4 - len(idxs)))
            a1 = a2 = -32768             # rooms no player is ever "in"
        else:
            # the rooms the line separates: standing in EITHER counts, so the
            # crossing fires whichever way the player approaches
            a1 = md.sidedefs[ld.right].sector if ld.right != NO_SIDEDEF else 0xFF
            a2 = md.sidedefs[ld.left].sector if ld.left != NO_SIDEDEF else a1
            if a1 == a2 and ld.right != NO_SIDEDEF:
                # SELF-REFERENCING line: both sidedefs name the same sector, so
                # the pair says nothing about where the player has to stand.
                # E1M3's three light lines round the blue key (1017-1019) are
                # drawn inside sector 27 but the step that crosses them lands on
                # the pedestal, sector 28, and mv_crossed's room gate threw it
                # away -- the lights never went out (2026-08-07). Ask the BSP for
                # the sector a player RADIUS out from the line's middle and keep
                # it as the second room. STRICTLY ADDITIVE: a1 is still the
                # sidedef sector, so every one of episode 1's 28 self-referencing
                # trigger lines fires exactly where it fired before, and this one
                # also fires where it could not. (DOOM gates on nothing at all --
                # P_TryMove fires every special line the move crossed.)
                vv1, vv2 = md.vertices[ld.v1], md.vertices[ld.v2]
                mx, my = (vv1.x + vv2.x) / 2.0, (vv1.y + vv2.y) / 2.0
                ex, ey = vv2.x - vv1.x, vv2.y - vv1.y
                ln = math.hypot(ex, ey) or 1.0
                nx, ny = -ey / ln * 24, ex / ln * 24
                for sx, sy in ((mx + nx, my + ny), (mx - nx, my - ny)):
                    o = wad_sector_of_ss(md, wad_subsector(md, round(sx),
                                                           round(sy)))
                    if o != a1:
                        a2 = o
                        break
            v1, v2 = md.vertices[ld.v1], md.vertices[ld.v2]
            mid = struct.pack('<hhhh', v1.x, v1.y, v2.x, v2.y)
        if kind == 5:                    # a stair flight is a CHAIN, so the tag
            for si, dst in _build_stairs(md, ld.tag):   # picks the first step
                trig.append((a1, a2, mid, si | flags, dst, spd))   # only
            continue
        if kind == 6:                    # EV_DoDonut: two sectors, one line
            for si, dst, dspd in _donut(md, ld.tag):
                trig.append((a1, a2, mid, si | flags, dst, dspd))
            continue
        if flags & F_TELE:               # EV_Teleport: the tagged sector has to
            for si, sec in enumerate(md.sectors):    # hold a teleport man, and
                if sec.tag == ld.tag and si in tele_of:   # "dst" is its index
                    trig.append((a1, a2, mid, si | flags, tele_of[si], spd))
            continue
        for si, sec in enumerate(md.sectors):
            if sec.tag != ld.tag:
                continue
            if kind == 7:                # EV_LightTurnOn: the LEVEL, not a
                                         #   height. BEFORE the F_DOOR test --
                                         #   a light record wears that bit
                                         #   only to reach trig_fire's door
                                         #   branch. p_spec.c: case 35 -> 35,
                                         #   case 13 -> 255, case 104 -> each
                                         #   tagged sector goes to its
                                         #   DARKEST neighbour (one shared
                                         #   record here, so min over them)
                if ld.special == 13:
                    dst = 255
                elif ld.special == 104:
                    dst = min([md.sectors[md.sidedefs[s2].sector].light
                               for ld2 in md.linedefs
                               for s1, s2 in ((ld2.right, ld2.left),
                                              (ld2.left, ld2.right))
                               if s1 not in (-1, NO_SIDEDEF)
                               and s2 not in (-1, NO_SIDEDEF)
                               and md.sidedefs[s1].sector == si]
                              or [sec.light])
                else:
                    dst = 35
            elif ld.special in doomspecs.CRUSHER:
                dst = (CRUSH_SLOW if doomspecs.CRUSHER[ld.special] == 1
                       else CRUSH_FAST)
            elif ld.special in doomspecs.CRUSH_STOP:
                dst = CRUSH_HALT
            elif flags & F_DOOR:
                dst = 0
            elif kind == 8:                  # RAISE_BY: a fixed climb, and the
                                             #   neighbours have no say in it
                dst = sec.floor_h + RAISE_BY[ld.special]
            else:
                nb, nbc = _neigh_heights(md, si)
                if kind == 1:
                    dst = min(nb)
                elif kind == 2:
                    dst = max(nb) + 8
                elif kind == 3:              # P_FindNextHighestFloor
                    hi = [f for f in nb if f > sec.floor_h]
                    dst = min(hi) if hi else sec.floor_h
                else:                        # 4: P_FindLowestCeilingSurrounding
                    dst = min(min(nbc), sec.ceil_h)
            trig.append((a1, a2, mid, si | flags, dst, spd))
            if ld.special in CHANGE_SPECS and ld.right != NO_SIDEDEF:
                front = md.sectors[md.sidedefs[ld.right].sector]
                pal = sp.wt.flat_dominant(front.floor_flat)
                if pal != sp.wt.flat_dominant(sec.floor_flat) or sec.special:
                    chg.append((len(trig) - 1, pal))
    # ---- p_enemy.c A_BossDeath: the trigger with no line ---------------------
    # Everything above walks LINEDEFS, which is why this one was missing for as
    # long as the port has existed: no linedef carries doomspecs.BOSS_TAG. DOOM
    # fabricates a junk line with it the moment the last MT_BRUISER dies and
    # runs EV_DoFloor(lowerFloorToLowest) on the sectors that do -- E1M8's 22,
    # the wall standing between the boss room and the level's ONLY exit.
    # It is packed as an ordinary 16 B record so trig_fire drives it through the
    # same mover the walkover floors use; en_bossdie (enemy.asm) fires it BY
    # INDEX, and the two fields that would let anything else fire it are poison:
    #   rooms -32768 -- mv_crossed compares them against the sector under the
    #                   player, which is 0..255, so no walkover can match,
    #   segs  0      -- switch_match / gun_seg_p match by seg record ADDRESS,
    #                   and MAP_SEGS never places a seg at 0, so neither USE nor
    #                   a bullet can match either.
    # F_STAY is the bit special 82 (WR lower to lowest) already wears: down, and
    # it stays down. No F_ONCE -- mv_start marks the fired bitmap for stay-down
    # floors itself. check_triggers still walks the record every frame and pays
    # it one mv_sector, exactly as it already does for the level's USE records;
    # the room gate then refuses it, which is the whole point of the -32768.
    # WHICH type fires A_BossDeath here (p_enemy.c's switch on gameepisode --
    # boss_type_of), and therefore which KIND byte a death has to carry. It used
    # to be MK_BOSS, hard-coded: episode 1 was all there was and the baron was
    # the only boss. The cyberdemon and the spider mastermind made that wrong on
    # E2M8/E3M8 -- their kinds are 10 and 11 -- so the kind rides in the header
    # (+34) and en_bossdie reads it. 0 = no boss hook, i.e. every map but the
    # three M8s.
    boss_num = boss_type_of(md.name)
    boss_kind = (MK_ORDER.index(boss_num) + 1) if boss_num in MK_ORDER else 0
    assert boss_num == 0 or boss_kind, \
        f'{md.name}: A_BossDeath fires on doomednum {boss_num}, which is not ' \
        f'in MK_ORDER -- the level could never open its exit'
    boss_idx, boss_left = 0xFF, 0
    boss_secs = [si for si, sec in enumerate(md.sectors)
                 if sec.tag == doomspecs.BOSS_TAG]
    assert len(boss_secs) <= 1, \
        f'{len(boss_secs)} sectors tagged {doomspecs.BOSS_TAG}: en_bossdie ' \
        f'fires exactly ONE record'
    for si in boss_secs:
        boss_idx = len(trig)
        trig.append((0xFF, 0xFF, bytes(8), si | F_STAY,
                     min(_neigh_heights(md, si)[0]), SPEED_BOSS))
    # A_BossDeath on E2M8/E3M8 is G_ExitLevel, not a 666 floor (p_enemy.c):
    # no sector wears the tag, the level simply ENDS on the last boss death.
    # Header index $FE is en_bossdie's sentinel for that -- it raises
    # EXIT_REQ instead of firing a trigger record. (E3M9 has a real cyberdemon
    # too, but it is not map 8, so it gets no sentinel and its death means
    # nothing -- exactly like vanilla's gate on gamemap.)
    if boss_idx == 0xFF and boss_num:
        boss_idx = 0xFE
        # en_bossdie raises EXIT_REQ with an INC, not a store, which is one
        # byte and one byte is what the block had. That is exact only if
        # EXIT_REQ is 0 when the last boss falls -- so assert here that the map
        # has no OTHER way to raise it in the same frame. It cannot: a map that
        # needs the sentinel is a map with no exit of its own, which is the
        # whole reason the sentinel exists.
        assert not any(l.special in doomspecs.EXIT for l in md.linedefs), \
            f'{md.name}: A_BossDeath ends the level here, but the map also ' \
            f'carries an EXIT linedef -- en_bossdie increments EXIT_REQ and ' \
            f'would see it already set (enemy.asm)'
        assert not any(s.special in (11, 52) for s in md.sectors), \
            f'{md.name}: A_BossDeath ends the level here, but the map also ' \
            f'carries an exit SECTOR special -- see above'
    # ...and how many of them have to fall first. DOOM re-walks the thinker list
    # looking for a survivor OF THE SAME TYPE; the engine counts down instead,
    # which is the same answer for a tenth of the 6502 and is exact because
    # en_kill runs exactly once per thing -- en_shoot bails on "health 0 ->
    # already dead" and en_bthings skips anything with TH_STATE set.
    if boss_idx != 0xFF:
        boss_left = sum(1 for t in things if t[7] == boss_num)
        assert boss_left, \
            f'{md.name}: A_BossDeath fires on doomednum {boss_num} but the ' \
            f'level spawns none at skill {skill} -- its exit could never open'
    assert boss_idx in (0xFF, 0xFE) or boss_idx < TRIG_MAX, \
        'the boss record fell outside the fired bitmap (movers.asm)'

    assert len(chg) < 255, 'the raise-and-change table is $FF-terminated'
    assert len(trig) <= TRIG_MAX, \
        f'{len(trig)} triggers > {TRIG_MAX} -- the fired bitmap ' \
        f'(movers.asm) is full'
    assert all((sw & 0xFF) < len(md.sectors) for _, _, _, sw, _, _ in trig), \
        'a sector id ran into the flag bits (b8 = gun, b9 = door-close, b10 = tele)'
    assert len(md.sectors) <= 255, \
        f'{len(md.sectors)} sectors: a trigger record only has b0-b7 for the id'
    # ---- PIECE 2 (2026-08-29). Everything from the trigger table on lives at
    # THINGS2_BASE ($DA00-$E2FF, memory_map.inc), not behind the sprite table:
    # the 31 sectors at $C000 end at $CF7F with BTNUPD right above, and E2M2
    # was already dropping decorations and the BFG ball's frames to fit. The
    # crushers' trigger records (10 lines x 3 sectors on E2M2 alone) did not.
    # $DA00 is the map HIGH region's unused tail -- HIGH has been 4 sectors
    # since SSECTORS left for the EXT bank, and pack_map.HI_LIMIT now stops at
    # $DA00 to say so. It is ORDINARY under-ROM RAM, so nothing that reads a
    # trigger, a teleport destination or a spawnhealth got slower: the readers
    # follow the header's absolute pointers and never knew where they pointed.
    # load_things streams it with a second read_urom (load_things2, diskio.asm).
    p_trig = THINGS2_BASE
    # the raise-and-change table rides straight behind the triggers, so the
    # engine finds it with no header field of its own: p_trig + n_trig*16.
    # (u8 trigger index, u8 the floor colour that sector takes), $FF ends it.
    p_chg = p_trig + len(trig) * 16
    p_tele = p_chg + len(chg) * 2 + 1             # trig_walk: dest index * 8
    p_hp = p_tele + len(tele) * 8                 # [N] u16 spawnhealth per thing

    out = bytearray(HEADER)
    struct.pack_into('<HHBHHHHBHHBBBBBBBB', out, 0, len(things), n_ss, len(tab),
                     p_ss, p_things, p_sprtab, p_trig, len(trig), p_tele, p_hp,
                     ball_id, ball_xid, rock_id, rock_xid, plas_id, plas_xid,
                     puff_id, blud_id)
    struct.pack_into('<HHB', out, 26, gun_segs[0], gun_segs[1], gun_idx)
    struct.pack_into('<BB', out, 31, boss_idx, boss_left)
    struct.pack_into('<B', out, 33, bal7_id)
    struct.pack_into('<B', out, 35, bal2_id)
    struct.pack_into('<B', out, 34, boss_kind)
    struct.pack_into('<BB', out, 36, bfgs_id, bfge_id)
    out += prefix
    for (ssid, x, y, z, sid, fl, _hp, _ty) in things:
        out += struct.pack('<hhhBB', x, y, z, sid, fl)
    for i, (fid, w, h, left, top, lump) in enumerate(tab):
        assert not (bonus_of.get(i) and kind_of.get(i)),             f'{lump}: both a bonus and a monster -- the shared sprtab byte cannot say both'
        out += struct.pack('<BBBBBbBB', fid, 0, 0,    # B1: byte 0 = frame id
                           w, h, left, top,
                           bonus_of.get(i, 0) or kind_of.get(i, 0))
    out2 = bytearray()                 # ...and PIECE 2, based at THINGS2_BASE
    for _ti, (a1, a2, mid, sec_w, dst, spd) in enumerate(trig):   # 16 B each
        # roomA, SPEED, roomB, pad. A sector id is a byte (the assert above), so
        # the two u16 room slots were carrying a zero high byte each; one of them
        # is the per-record floor speed now. $FF = "no room", which cannot be a
        # sector id because the assert stops one short of it.
        out2 += struct.pack('<BBBB', a1 & 0xFF, spd, a2 & 0xFF,
                            xkind.get(_ti, 0)) + mid + struct.pack('<Hh', sec_w, dst)
    for ti, pal in chg:                             # p_plats.c raise AND CHANGE
        out2 += struct.pack('<BB', ti, pal)
    out2 += bytes([0xFF])
    for (tx, ty, tang) in tele:                     # 8 B each (index * 8)
        out2 += struct.pack('<hhBBBB', tx, ty, tang, 0, 0, 0)
    for i in range(len(tab)):                       # [len(tab)] u16 spawnhealth,
        out2 += struct.pack('<H', hp_of.get(i, 0))  #   0 = not shootable
    n_shoot = sum(1 for t in things if t[6])
    if n_shoot:
        print(f'  shootable: {n_shoot} of {len(things)} things, '
              f'{len(hp_of)} of {len(tab)} sprites carry hp '
              f'(max {max(hp_of.values())})')
    print(f'  triggers: {len(trig)}: '
          + ', '.join(f'sec{sw & 0xFF}'
                      + ('/gun' if sw & 0x0100 else
                         '/use' if sw & 0x4000 else '/walk')
                      + ('/tele' if sw & 0x0400 else
                         '/shut' if sw & 0x0200 else
                         '/door' if sw & 0x2000 else f'->{d}')
                      for _, _, _, sw, d, _ in trig))
    if gun_segs[0]:
        print(f'  gun line (special 46): seg records '
              + ' + '.join(f'${a:04X}' for a in gun_segs if a)
              + f', trigger {gun_idx} -> sector {trig[gun_idx][3] & 0xFF}')
    if tele:
        print(f'  teleport dests: ' + ', '.join(f'({x},{y}) ang {a}'
                                                for x, y, a in tele))
    kinds_here = set(kind_of.values())
    # keys are (lump, flip) since the rotation slice -- the sprite table only
    # ever holds unflipped images
    have = {(row[5], False): (row[0], row[1], row[2], row[3], row[4])
            for row in tab}
    # The corpses get the run MINUS what the attack chains will need (see
    # atk_reserve): pack_death is first and would otherwise spend gameplay's
    # room on cosmetics.
    dfirst, drows = pack_death(sp, blob, black, kinds_here, frames, coltabs,
                               FTAB_OFF - atk_reserve(sp, kinds_here, have),
                               boss_kind)
    if drows:
        print(f'  death frames: {len(drows)}, sprite pixels now {len(blob)} B')
    # ---- ONE view plan for attack + walk together: the engine has a single
    #      NSTOR, so both must store the same rotation set. B1: pixels live in
    #      SDRAM and the VRAM arena caches them, so the byte budget is gone --
    #      the plan is bounded by the DTAB row cap and the coltab region only
    #      (emit_sprcol fails the build if the latter overflows, so plan_views
    #      prices the coltab run itself and steps down instead).
    cap, rots = plan_views(sp, kinds_here, have, 1 << 30, len(drows),
                           sum(4 * len(t) for t in coltabs))
    # ---- attack states BEFORE the walk cycle: see pack_atk. ONE cache across
    #      the two, because plan_views prices them against one `seen` and the
    #      spider mastermind attacks with a walk image (pack_atk's note).
    aw_cache = dict(have)
    afirst, _an, arows = pack_atk(sp, blob, black, kinds_here, len(drows), have,
                                  frames, coltabs, rots,    # _an: the state count
                                  aw_cache)                 # is dead data -- see
                                                            # emit_dtab
    if arows:
        print(f'  attack frames: {len(arows)} ({len(rots)} view(s)/state), '
              f'sprite pixels now {len(blob)} B')
    # ---- A_Chase walk frames, into the SAME blob and the same row array
    wfirst, wn, wrows, _ = pack_walk(sp, blob, black, kinds_here,
                                     len(drows) + len(arows), have, cap, rots,
                                     frames, coltabs, aw_cache)
    # ---- idle rings BEFORE the gibs: 356-976 B of coltab a level against the
    #      1.7 KB one gib chain wants, and an animated barrel is on screen the
    #      whole level where a gib is one corpse
    isid, ifirst, icnt, irows, _icol = pack_idle(
        sp, blob, black, anim_of, have, frames, coltabs,
        len(drows) + len(arows) + len(wrows),
        sum(4 * len(t) for t in coltabs))
    if irows:
        print(f'  idle rings: {sum(1 for v in isid if v != 0xFF)} sprites, '
              f'{len(irows)} frames, sprite pixels now {len(blob)} B')
    # ---- and the GIB chains, last so no row index above moves
    xfirst, xrows = pack_xdeath(sp, blob, black, kinds_here, frames, coltabs,
                                len(drows) + len(arows) + len(wrows)
                                + len(irows))
    if xrows:
        print(f'  gib frames: {len(xrows)} (p_inter.c xdeathstate), '
              f'sprite pixels now {len(blob)} B')
    # ---- and the FLINCH frames, after even the gibs: one image a kind, and
    #      nothing that already shipped may lose a frame to it (pack_pain)
    pfirst, prows, pflat = pack_pain(sp, blob, black, kinds_here, have,
                                     frames, coltabs, rots,
                                     len(drows) + len(arows) + len(wrows)
                                     + len(irows) + len(xrows))
    if prows:
        print(f'  flinch frames: {len(prows)} rows, {len(rots)} view(s) each: '
              + ', '.join(pflat))
    allrows = drows + arows + wrows + irows + xrows + prows
    dtab = emit_dtab(dfirst, wfirst, wn, afirst, pfirst, xfirst,
                     isid, ifirst, icnt, pain_tics(), allrows)
    sprcol = emit_sprcol(frames, coltabs)
    if wrows:
        print(f'  walk frames: {len(wrows)} ({cap}-image cycle, '
              f'{len(rots)} view(s)), '
              f'{len(dtab)} B .dtab, sprite pixels now {len(blob)} B')
    elif kinds_here:
        print('  walk frames: NONE -- the sprite slot had no room for a cycle')
    # ---- barrel sight table (pack_los.py): A_Explode's P_CheckSight, precomputed
    bar = pack_los.barrels_of(things)
    los = pack_los.pack(md, bar)
    if bar:
        print(f'  barrel LOS: {len(bar)} barrels x {pack_los.GRID_N}x'
              f'{pack_los.GRID_N} cells ({len(los)} B .los)')
    print(f'  T4 crop + B1 ftab: {len(frames)} frames, .sprcol {len(sprcol)} B '
          f'(coltabs {SPRCOL_BASE:#06x}+, ftab @+{FTAB_OFF:#06x})')
    # ---- the .things file is the TWO pieces back to back, with piece 1 padded
    # out to its whole 31 sectors: load_things reads THINGS_SECT of them to
    # $C000 and the rest to THINGS2_BASE, so the pad is what puts the second
    # read on a sector boundary. main() checks piece 1 (and retries with fewer
    # decorations when it is over); piece 2 has no cosmetics to drop, so it
    # fails the build outright.
    if len(out2) > THINGS2_MAX:
        sys.exit(f'  ERROR: {md.name} piece 2 is {len(out2)} B > {THINGS2_MAX} '
                 f'(${THINGS2_BASE:04X}..${THINGS2_BASE+THINGS2_MAX-1:04X} is '
                 f'all there is between the map HIGH region and USERAY_BASE '
                 f'-- see memory_map.inc THINGS2_BASE)')
    print(f'  RAM blob: piece 1 {len(out)}/{THINGS_MAX} B at ${THINGS_BASE:04X}, '
          f'piece 2 {len(out2)}/{THINGS2_MAX} B at ${THINGS2_BASE:04X} '
          f'({len(trig)} triggers)')
    blk = bytes(out) + bytes(max(0, THINGS_MAX - len(out))) + bytes(out2)
    return blob, blk, tab, things, dtab, los, sprcol


def things_p1_len(blk):
    """Piece 1's real length, out of the blob's own header: the sprite table is
    the last thing in it. main()'s decoration-cut retry gates on this, not on
    len(blk) -- the file carries piece 2 behind the padding now."""
    p_sprtab = struct.unpack_from('<H', blk, 9)[0]
    return p_sprtab + blk[4] * 8 - THINGS_BASE


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    skill = SKILL
    if '--skill' in sys.argv:
        skill = int(sys.argv[sys.argv.index('--skill') + 1])
    names = args or ['E1M1']
    wad = Wad(DEFAULT_WAD)
    wt = WadTextures(wad)
    sp = Sprites(wad, wt)
    os.makedirs(OUT_DIR, exist_ok=True)
    rows = emit_mk_tables()           # mk_tables.inc: level-independent, but it
    print(f'  mk_tables.inc: {len(rows)} monster kinds')   # MUST be rewritten
                                      # whenever MK_ORDER changes, or the kind
                                      # byte indexes past the table
    for nm in names:
        md = wad.load_map(nm)
        for bfg, dc, oc in [(b, d, o) for b in (True, False)
                            for d, o in ((0, 0), (24, 0), (48, 0), (96, 0),
                                         (96, 12), (96, 32), (160, 64))]:
            blob, blk, tab, things, dtab, los, sprcol = pack(md, sp, skill,
                                                             dc, oc, bfg)
            if things_p1_len(blk) <= THINGS_MAX:
                if not bfg:
                    print(f'  {nm}: RAM blob over ${THINGS_MAX:04X} -- dropped '
                          f'the BFG BALL\'s frames (the shot lands at once here)')
                if dc or oc:
                    print(f'  {nm}: RAM blob over ${THINGS_MAX:04X} -- dropped '
                          f'{dc} decor + {oc} obstacle decorations to fit')
                break
        sp_old = os.path.join(OUT_DIR, f'{nm}.spr')       # B2: per-level .spr
        if os.path.exists(sp_old):                        # died with the pool;
            os.remove(sp_old)                             # kill stale ones
        with open(os.path.join(OUT_DIR, f'{nm}.things'), 'wb') as f:
            f.write(blk)
        with open(os.path.join(OUT_DIR, f'{nm}.dtab'), 'wb') as f:
            f.write(dtab + bytes(DTAB_MAX - len(dtab)))   # padded: fixed slot
        with open(os.path.join(OUT_DIR, f'{nm}.los'), 'wb') as f:
            f.write(los)                                  # already a fixed slot
        with open(os.path.join(OUT_DIR, f'{nm}.sprcol'), 'wb') as f:
            f.write(sprcol)                               # coltabs + FTAB (B1)
        p1 = things_p1_len(blk)
        print(f'{nm}: {len(things)} things, {len(tab)} sprites | '
              f'pool now {len(blob)} B -> SDRAM (arena-cached, B2) | '
              f'RAM blob {p1} B (${THINGS_BASE:04X}..${THINGS_BASE+p1:04X}) '
              f'+ {len(blk)-THINGS_MAX} B at ${THINGS2_BASE:04X}')
        if p1 > THINGS_MAX:
            sys.exit(f'  ERROR: {nm}.things piece 1 is {p1} B > {THINGS_MAX} '
                     f'(the sector-rounded slot would run into BTNUPD at '
                     f'$CFC8 -- see memory_map.inc)')

    # ---- B2: the sprite pool, ONE file for the whole run ---------------------
    # 1 KB pad: it rides the disk right behind pool.tex and load_textures
    # drains the combined region in 8-sector passes. The .sprmeta sidecars all
    # carry the FINAL pool size and are written only now -- a partial
    # `pack_things.py E1M3` run leaves every OTHER level's sidecar stale, and
    # make_atr_doom.py fails the build instead of shipping FTABs that point
    # into a pool that no longer has their frames.
    pool = bytes(SPRPOOL)
    pool += bytes(-len(pool) % 1024)
    with open(os.path.join(OUT_DIR, 'sprpool.bin'), 'wb') as f:
        f.write(pool)
    for nm in names:
        with open(os.path.join(OUT_DIR, f'{nm}.sprmeta'), 'w') as f:
            f.write(f'{len(pool)}\n')
        # the shipped contract, re-read from disk: every FTAB row of every
        # level must land inside the pool that was just written
        sc = open(os.path.join(OUT_DIR, f'{nm}.sprcol'), 'rb').read()
        for i in range(NFRAMES_MAX):
            r = sc[FTAB_OFF + i * FTAB_ROW:FTAB_OFF + (i + 1) * FTAB_ROW]
            if len(r) < FTAB_ROW or not any(r):
                continue
            lo, hi, sz = struct.unpack_from('<HBH', r)
            if (lo | (hi << 16)) + sz > len(pool):
                sys.exit(f'  ERROR: {nm} FTAB row {i} runs past sprpool.bin '
                         f'({(lo | (hi << 16)) + sz} > {len(pool)})')
    print(f'  sprpool.bin: {len(pool)} B, {len(_POOL_IX)} distinct frames '
          f'({len(names)} level(s) deduped)')


if __name__ == '__main__':
    main()
