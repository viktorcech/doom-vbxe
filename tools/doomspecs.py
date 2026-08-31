#!/usr/bin/env python3
"""The linedef specials the port implements, in ONE place.

These sets used to be retyped in every tool that needed them -- pack_map.py
(_doors), pack_things.py (SPEC), _verify_spec_audit.py, _dbg_wad_doors.py --
and they had already started to drift. They are all verified against id's own
source in _pomocne/_doomsrc (p_doors.c EV_VerticalDoor, p_spec.c
P_CrossSpecialLine, p_switch.c P_UseSpecialLine, p_plats.c / p_floor.c); this
module is that shared definition, not a new opinion.

  MANUAL_DOOR  DR/D1 doors: no tag, the door is the sector on the line's BACK
               side (p_doors.c EV_VerticalDoor)
  TAG_DOOR     remote door actions; the doors are the sectors carrying the tag
  GUN_DOOR     IMPACT specials -- a BULLET opens them, USE does not (p_spec.c
               P_ShootSpecialLine, called from PTR_ShootTraverse p_map.c:920).
               46 GR open-stay is the only one episode 1 uses: E1M2's secret
               door at (-2176,-320)-(-2176,-448), tag 6
  FLOORS       everything that MOVES A FLOOR: lifts, raises, stairs, the donut
               (pack_things.py SPEC drives these; the value there is the target
               formula, here we only need "this sector moves")
  EXIT         exit lines (level end)
  SCROLL       p_spec.c "ANIMATE LINE SPECIALS" -- movers.asm update_scroll
  LIGHT_*      the SECTOR specials P_SpawnSpecials turns into a light thinker
               (p_spec.c:1053 ff -> p_lights.c). Sector specials, not linedef
               ones: they are the only entries here that index sector->special.

Switch faces come from DOOM's own alphSwitchList (p_switch.c), read out of the
source when it is present so the port and the game agree on what a switch is.

CLI:  python doomspecs.py    # print the sets and cross-check pack_things.SPEC
"""
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
from doomstates import SRC_DIR             # the ONE place the C tree is located

MANUAL_DOOR = {1, 26, 27, 28, 31, 32, 33, 34, 117, 118}
TAG_DOOR = {2, 16, 29, 63, 76, 86, 90, 103,
            # E3M5 (2026-08-18): 40 = W1 ceiling raise to HIGHEST neighbour.
            # The port's only ceiling machinery is the door mover, so the
            # tagged sectors become door records and the trigger opens them
            # once, stays -- the door target (lowest neighbour ceiling - 4)
            # instead of highest is the same class of reduction 19/38 ride.
            40}
GUN_DOOR = {46}          # 47 (G1 raise+change) has no E1-E3 user; 24 (G1
                         # raise floor, E2M4) is a gun FLOOR -- it lives in
                         # FLOORS below and carries F_GUN in pack_things.SPEC
FLOORS = {5, 7, 8, 9, 18, 19, 20, 21, 22, 23, 36, 38, 62, 70, 82, 88, 91, 98,
          # E2 additions (2026-08-18, first E2 maps): 14 S1 raise 32 + change,
          # 37 W1 lower to lowest + change, 102 S1 lower to highest neighbour.
          # Formulas are pack_things.SPEC's kinds 3/1/2 -- same reductions the
          # E1 set already uses (102 rides kind 2's "+8" turbo approximation,
          # the way plain W1 lowers 19/38 always have).
          14, 37, 102,
          # ...and the full-episode sweep (2026-08-18): 24 G1 raise (E2M4),
          # 30 W1 raise-by-shortest-lower-texture and 56 W1 crush-raise and
          # 58/59 W1 raise 24 (+change) -- all approximated with the nearest
          # existing kind; 87 WR perpetual platform behaves as the plain WR
          # lift 88 (each crossing runs one down-wait-up cycle; 89 STOP stays
          # unimplemented -- with no perpetual motion there is nothing to
          # stop).
          24, 30, 56, 58, 59, 87}
EXIT = {11, 51, 52, 124}
# EV_BuildStairs (p_floor.c:453) -> the step size in map units. A STAIRS line is
# the one floor special that recruits sectors NOBODY TAGGED: the tagged sector
# rises one step, and then the chain walks on through any two-sided neighbour
# whose front side is the current sector and whose floor flat matches the FIRST
# sector's. Every sector it reaches ends up at a DIFFERENT height, which is why
# wadlib's identical-row sector merge has to leave all of them alone -- see the
# no_merge block there. Episodes 1-3 use only the build8 pair; 100/127 are the
# turbo16 flavours, listed so a converted WAD cannot walk in unprotected.
STAIRS = {7: 8, 8: 8, 100: 16, 127: 16}
SCROLL = {48}
TELEPORT = {97, 39}      # 39 = the W1 (once) flavour: E3M6/E3M9 (2026-08-18)
# p_spec.c case 35 "Lights Very Dark": EV_LightTurnOn(line, 35). A LINEDEF
# special, unlike LIGHT_SECTOR below. It joined pack_things.SPEC on 2026-08-07
# (E1M3's blue key) but nobody added it here, so `python doomspecs.py` had been
# reporting the two tables as out of step ever since -- exactly the drift this
# module exists to catch.
LIGHT_LINE = {35,
              13,        # W1 lights to 255 (E2M2) -- same set-level record,
                         #   dst 255 instead of 35
              104}       # W1 lights to DARKEST neighbour (E2M5/E3M9): the
                         #   level is a pack-time constant per line, so it
                         #   rides the same kind-7 record with a computed dst

# ---- CRUSHERS (p_ceilng.c EV_DoCeiling / T_MoveCeiling) --------------------
# The ceiling that comes down on your head, goes back up and does it again for
# ever. Episodes 1-3 use exactly three of the six DOOM crusher actions, all WR:
#   73 crushAndRaise      CEILSPEED     (E2M2/E2M4/E2M6/E3M4/E3M5)
#   77 fastCrushAndRaise  CEILSPEED*2   (E2M2/E2M4)
#   74 EV_CeilingCrushStop -- park it where it stands (24 lines, every map that
#      has a crusher has some), and a later 73/77 starts it again.
# 6/25/49/141 have no user in E1-E3 and are NOT here: nothing would exercise
# them, and the value is per action, not per number.
# The port drives them through the DOOR ceiling machinery (doors.asm), which is
# why the tagged sectors become DOOR records in pack_map._doors -- a crusher is
# a door that never parks, aims at floor+8 instead of the floor, and hurts.
CRUSHER = {73: 1, 77: 2}             # value = the port's speed class (slow/fast)
CRUSH_STOP = {74}

DOORS = MANUAL_DOOR | TAG_DOOR | GUN_DOOR
SUPPORTED = (DOORS | FLOORS | EXIT | SCROLL | TELEPORT
             | set(CRUSHER) | CRUSH_STOP)

# The one trigger in episode 1 that has NO LINEDEF. p_enemy.c A_BossDeath: on
# E1M8, when the last MT_BRUISER dies, the engine builds a JUNK line carrying
# this tag and calls EV_DoFloor(lowerFloorToLowest). Nothing in the WAD points
# at it -- E1M8's sector 22 wears the tag and no linedef does -- so a packer
# that walks linedefs (pack_things.py's trigger table does) cannot find it and
# the sector stays the solid wall it ships as (floor == ceil == 208). That
# matters more than it sounds: E1M8 carries no exit linedef either, and its
# only exit is the special-11 sector behind that wall.
BOSS_TAG = 666

# ---- SECTOR specials that animate the light (p_spec.c P_SpawnSpecials) ------
# The value is (thinker kind, dark-phase tics); the port's kind ids are the
# ones lights.asm switches on. p_spec.h: FASTDARK 15, SLOWDARK 35.
LT_FLASH, LT_STROBE, LT_GLOW, LT_FIRE = 0, 1, 2, 3
LT_SYNC = 0x80                       # strobe started in step with the others
FASTDARK, SLOWDARK = 15, 35
LIGHT_SECTOR = {
    1:  (LT_FLASH, 0),               # P_SpawnLightFlash    (random off)
    2:  (LT_STROBE, FASTDARK),       # P_SpawnStrobeFlash(FASTDARK, 0)
    3:  (LT_STROBE, SLOWDARK),       # P_SpawnStrobeFlash(SLOWDARK, 0)
    4:  (LT_STROBE, FASTDARK),       # ... + 20% damage (the damage half is
                                     #     pack_map's DMG table)
    8:  (LT_GLOW, 0),                # P_SpawnGlowingLight
    12: (LT_STROBE | LT_SYNC, SLOWDARK),   # P_SpawnStrobeFlash(SLOWDARK, 1)
    13: (LT_STROBE | LT_SYNC, FASTDARK),   # P_SpawnStrobeFlash(FASTDARK, 1)
    # P_SpawnFireFlicker. Packed as a FLASH (off the fire flicker's own
    # minlight+16): no episode-1 map uses special 17, and lights.asm has no room
    # for a fourth handler -- see LT_FIRE there.
    17: (LT_FLASH, 0),
}

# DOOM shareware + registered switch pairs (p_switch.c alphSwitchList). Used
# only if _doomsrc is not checked out -- switch_pairs() prefers the real thing.
_FALLBACK_SWITCHES = {
    'SW1BRCOM': 'SW2BRCOM', 'SW1BRN1': 'SW2BRN1', 'SW1BRN2': 'SW2BRN2',
    'SW1BRNGN': 'SW2BRNGN', 'SW1BROWN': 'SW2BROWN', 'SW1COMM': 'SW2COMM',
    'SW1COMP': 'SW2COMP', 'SW1DIRT': 'SW2DIRT', 'SW1EXIT': 'SW2EXIT',
    'SW1GRAY': 'SW2GRAY', 'SW1GRAY1': 'SW2GRAY1', 'SW1METAL': 'SW2METAL',
    'SW1PIPE': 'SW2PIPE', 'SW1SLAD': 'SW2SLAD', 'SW1STARG': 'SW2STARG',
    'SW1STON1': 'SW2STON1', 'SW1STON2': 'SW2STON2', 'SW1STONE': 'SW2STONE',
    'SW1STRTN': 'SW2STRTN', 'SW1BLUE': 'SW2BLUE', 'SW1CMT': 'SW2CMT',
    'SW1GARG': 'SW2GARG', 'SW1GSTON': 'SW2GSTON', 'SW1HOT': 'SW2HOT',
    'SW1LION': 'SW2LION', 'SW1SATYR': 'SW2SATYR', 'SW1SKIN': 'SW2SKIN',
    'SW1VINE': 'SW2VINE', 'SW1WOOD': 'SW2WOOD',
}

_switch_cache = None
_door_cache = None


# ---- DOOR line types, read out of id's own dispatch -------------------------
# Not a list of "the ones some IWAD happens to use": every door type there is,
# with what it DOES, so a converter can substitute one for another without
# anybody having to know which game a WAD came from.
#
#   kind     the vldoor_e handed to EV_DoDoor -- normal / open / close /
#            close30ThenOpen and their blaze* twins (same door, faster)
#   trigger  'W' walk over (p_spec.c P_CrossSpecialLine), 'S' switch or use
#            (p_switch.c P_UseSpecialLine), 'G' shoot (P_ShootSpecialLine),
#            'D' manual -- the door is the sector behind the line itself
#            (p_doors.c EV_VerticalDoor)
#   repeat   fires again: a cross line that does NOT clear line->special, or
#            P_ChangeSwitchTexture(line, 1)
_CASE = re.compile(r'^\s*case\s+(\d+)\s*:', re.M)


def _bare(text):
    """A case label that FALLS THROUGH: nothing but whitespace and comments.
    `break`/`return`/a call all end the run -- without that test the walk below
    strolls out of one switch and into the next, and P_CrossSpecialLine opens
    with a switch of BARE labels (the ones a monster may trigger) that would
    then be grouped onto the first real door case after it: special 10 is a
    plat, 97 a teleport, and remapping either as a door moves the wrong
    sector."""
    return not re.search(r'\w+\s*\(|break|return|[{}]', text)


def _blocks(body):
    """(labels, text) per case block, genuine fallthrough labels grouped."""
    hits = list(_CASE.finditer(body))
    for i, m in enumerate(hits):
        end = hits[i + 1].start() if i + 1 < len(hits) else len(body)
        text = body[m.end():end].split('break;')[0]
        if _bare(text):
            continue                                  # the next label owns it
        labels, j = [int(m.group(1))], i
        while j > 0 and _bare(body[hits[j - 1].end():hits[j].start()]):
            j -= 1
            labels.append(int(hits[j].group(1)))
        yield sorted(labels), text


def _func(path, name):
    """The body of one C function, brace-matched."""
    txt = open(os.path.join(SRC_DIR, path), encoding='latin-1').read()
    i = txt.find(name)
    if i < 0:
        return ''
    i = txt.find('{', i)
    depth, j = 0, i
    while j < len(txt):
        if txt[j] == '{':
            depth += 1
        elif txt[j] == '}':
            depth -= 1
            if not depth:
                return txt[i:j]
        j += 1
    return txt[i:]


def door_actions():
    """{special: (kind, trigger, repeat)} for every door linedef type."""
    global _door_cache
    if _door_cache is not None:
        return _door_cache
    out = {}
    if not os.path.isdir(SRC_DIR):
        _door_cache = out
        return out
    ev = re.compile(r'EV_Do(?:Locked)?Door\s*\(\s*line\s*,\s*(\w+)')
    for path, fn, trig in (('p_spec.c', 'P_CrossSpecialLine', 'W'),
                           ('p_switch.c', 'P_UseSpecialLine', 'S'),
                           ('p_spec.c', 'P_ShootSpecialLine', 'G')):
        for labels, text in _blocks(_func(path, fn)):
            m = ev.search(text)
            if not m:
                continue
            if trig == 'S':
                again = re.search(r'P_ChangeSwitchTexture\s*\(\s*line\s*,\s*1', text)
            else:
                again = not re.search(r'line->special\s*=\s*0', text)
            for sp in labels:
                out[sp] = (m.group(1), trig, bool(again))
    # The manual ones carry their kind in EV_VerticalDoor's own switch, and the
    # door is the line's back sector -- no tag, so nothing can stand in for them
    # and nothing needs to.
    for labels, text in _blocks(_func('p_doors.c', 'EV_VerticalDoor')):
        for sp in labels:
            out.setdefault(sp, ('normal', 'D', True))
    _door_cache = out
    return out


# vldoor_e's fast half is the slow half at another speed, and only the NAMES
# say which is which (p_spec.h lists them as one flat enum). blazeRaise is a
# raise, i.e. `normal`; blazeOpen an open; blazeClose a close.
_SLOW = {'blazeraise': 'normal', 'blazeopen': 'open', 'blazeclose': 'close'}


def _slow(kind):
    k = (kind or '').lower()
    return _SLOW.get(k, k)


# ---- HEXEN-format maps -> DOOM linedef specials -----------------------------
# A Hexen map does not carry DOOM's action numbers at all: a linedef holds a
# SCRIPT special (0..255) with five arguments, and how it fires is in the flags
# (SPAC: cross / use / impact / push, plus a repeat bit) instead of being baked
# into the action number the way DOOM's W1/WR/S1/SR classes are. So a Hexen map
# has to be TRANSLATED, not just re-parsed -- and what it translates to is a
# DOOM special of the right action AND the right trigger class, which is
# exactly the (S1, SR, W1, WR) tuple below. wadlib.load_map picks the column
# from the linedef's own SPAC bits, then nearest_supported() does the rest.
#
# Where the two games disagree about the DETAIL the translation loses it, and
# the list says so: Hexen's args carry speed, delay, height and lock, none of
# which survive a DOOM special number. What is kept is what the port models --
# "this line opens that door", "this one is a lift", "this one is the exit".
#
# Sources: Hexen's own specials list (Door_*, Floor_*, Plat_*, Teleport_*,
# Scroll_Texture_*) against p_doors.c / p_floor.c / p_plats.c / p_telept.c for
# the DOOM side. Anything not here stays 0 and does nothing -- ACS_Execute (80)
# is the big one, and a scripted door cannot be salvaged without an interpreter.
HEXEN_SPAC_MASK = 0x1C00         # linedef flags bits 10-12 = the activation
HEXEN_SPAC_SHIFT = 10
HEXEN_REPEAT = 0x0200            # ...and bit 9 = "it may fire again"
HEXEN_LINE = {
    #  hexen               S1   SR   W1   WR
    10: (50, 42, 3, 75),          # Door_Close
    11: (103, 61, 2, 86),         # Door_Open           (open and stay)
    12: (29, 63, 4, 90),          # Door_Raise          (open, wait, close)
    13: (29, 63, 4, 90),          # Door_LockedRaise    -- the LOCK is dropped
    20: (23, 60, 38, 82),         # Floor_LowerByValue  ~ lower to lowest
    21: (23, 60, 38, 82),         # Floor_LowerToLowest
    22: (23, 60, 38, 82),         # Floor_LowerToNearest
    23: (18, 69, 5, 91),          # Floor_RaiseByValue  ~ raise to next/highest
    24: (18, 69, 5, 91),          # Floor_RaiseToHighest
    25: (18, 69, 5, 91),          # Floor_RaiseToNearest
    26: (7, 7, 8, 8),             # Stairs_BuildDown    ~ DOOM builds UP only
    27: (7, 7, 8, 8),             # Stairs_BuildUp
    28: (18, 69, 5, 91),          # Floor_RaiseAndCrush ~ raise, no crush
    31: (7, 7, 8, 8),             # Stairs_BuildDownSync
    32: (7, 7, 8, 8),             # Stairs_BuildUpSync
    35: (18, 69, 5, 91),          # Floor_RaiseByValueTimes8
    36: (23, 60, 38, 82),         # Floor_LowerByValueTimes8
    60: (21, 62, 10, 88),         # Plat_PerpetualRaise ~ a lift
    62: (21, 62, 10, 88),         # Plat_DownWaitUpStay
    63: (23, 60, 38, 82),         # Plat_DownByValue    ~ lower
    64: (21, 62, 10, 88),         # Plat_UpWaitDownStay
    65: (18, 69, 5, 91),          # Plat_UpByValue      ~ raise
    70: (97, 97, 97, 97),         # Teleport
    71: (97, 97, 97, 97),         # Teleport_NoFog
    74: (11, 11, 52, 52),         # Teleport_NewMap  == the level EXIT
    75: (11, 11, 52, 52),         # Teleport_EndGame == the level EXIT
    100: (48, 48, 48, 48),        # Scroll_Texture_Left
    101: (48, 48, 48, 48),        # Scroll_Texture_Right -- the port scrolls one
    102: (48, 48, 48, 48),        # Scroll_Texture_Up      way, so all four land
    103: (48, 48, 48, 48),        # Scroll_Texture_Down    on the same special
}


# The NAMES of the Hexen specials this port drops, so a report can say what it
# lost instead of printing a bare number. Only the ones that actually turn up
# in a dropped-special count are worth carrying: everything HEXEN_LINE already
# translates never reaches a report. Two families dominate and neither can be
# faked -- ACS_* runs the level's compiled scripts (the BEHAVIOR lump), and
# Polyobj_* is Hexen's rotating and sliding geometry, which a BSP renderer that
# only moves floors and ceilings has no way to express.
HEXEN_LINE_NAME = {
    1: 'Polyobj_StartLine',     2: 'Polyobj_RotateLeft',
    3: 'Polyobj_RotateRight',   4: 'Polyobj_Move',
    5: 'Polyobj_ExplicitLine',  6: 'Polyobj_MoveTimes8',
    7: 'Polyobj_DoorSwing',     8: 'Polyobj_DoorSlide',
    29: 'Pillar_Build',         30: 'Pillar_Open',
    40: 'Ceiling_LowerByValue', 41: 'Ceiling_RaiseByValue',
    42: 'Ceiling_CrushAndRaise', 43: 'Ceiling_LowerAndCrush',
    44: 'Ceiling_CrushStop',    45: 'Ceiling_CrushRaiseAndStay',
    46: 'Floor_CrushStop',      61: 'Plat_Stop',
    66: 'Floor_LowerInstant',   67: 'Floor_RaiseInstant',
    68: 'Floor_MoveToValueTimes8', 69: 'Ceiling_MoveToValueTimes8',
    72: 'ThrustThing',          73: 'DamageThing',
    80: 'ACS_Execute',          81: 'ACS_Suspend',
    82: 'ACS_Terminate',        83: 'ACS_LockedExecute',
    90: 'Polyobj_OR_RotateLeft', 91: 'Polyobj_OR_RotateRight',
    92: 'Polyobj_OR_Move',      93: 'Polyobj_OR_MoveTimes8',
    94: 'Pillar_BuildAndCrush', 95: 'FloorAndCeiling_LowerByValue',
    96: 'FloorAndCeiling_RaiseByValue', 109: 'Force_Lightning',
    110: 'Light_Raise',         111: 'Light_LowerByValue',
    112: 'Light_ChangeToValue', 113: 'Light_Fade',
    114: 'Light_Glow',          115: 'Light_Flicker',
    116: 'Light_Strobe',        120: 'Radius_Quake',
    121: 'Line_SetIdentification', 129: 'UsePuzzleItem',
    130: 'Thing_Activate',      131: 'Thing_Deactivate',
    132: 'Thing_Remove',        133: 'Thing_Destroy',
    134: 'Thing_Projectile',    135: 'Thing_Spawn',
    136: 'Thing_ProjectileGravity', 137: 'Thing_SpawnNoFog',
    138: 'Floor_Waggle',        140: 'Sector_ChangeSound',
}
HEXEN_ACS = {80, 81, 82, 83}
HEXEN_POLYOBJ = {1, 2, 3, 4, 5, 6, 7, 8, 90, 91, 92, 93}


def hexen_line_name(sp):
    """`80 ACS_Execute` -- the number with Hexen's name for it where we have
    one, the bare number where we do not. Never raises: an unknown number is
    still worth printing, it just cannot be explained."""
    nm = HEXEN_LINE_NAME.get(sp)
    return f'{sp} {nm}' if nm else str(sp)


def hexen_to_doom(special, flags):
    """(Hexen special, linedef flags) -> the DOOM special that means the same
    thing here, or 0 when nothing does. USE and PUSH both count as "the player
    presses it"; monster-cross and impact fall back to the walk-over column,
    which is what a port with no monster-triggered lines can honour."""
    row = HEXEN_LINE.get(special)
    if not row:
        return 0
    spac = (flags & HEXEN_SPAC_MASK) >> HEXEN_SPAC_SHIFT
    again = bool(flags & HEXEN_REPEAT)
    press = spac in (1, 4)                        # SPAC_Use, SPAC_Push
    return row[(0 if not again else 1) if press else (2 if not again else 3)]


def nearest_supported(sp):
    """A linedef special this port does not implement -> the closest one it
    does, or None when nothing fits.

    Only DOORS are substitutable, and only because DOOM's own door types are
    the same handful of actions repeated across triggers and speeds: a map that
    opens a tagged door with a trigger the port lacks still means "open that
    door". So the search is by ACTION first -- blaze* is the same door with a
    different speed, so it collapses onto its slow twin -- then by trigger
    class, then by repeat. What it cannot preserve it drops, in that order:
    speed, then repeatability, then the key.

    Deliberately NOT a table of one game's line types: it is derived from the
    dispatch, so a WAD from anywhere gets the same treatment."""
    if sp in SUPPORTED:
        return sp
    act = door_actions()
    want = act.get(sp)
    if not want:
        return None
    kind, trig, again = want
    base = _slow(kind)
    best, best_score = None, None
    for cand in sorted(DOORS):
        got = act.get(cand)
        if not got:
            continue
        k2, t2, a2 = got
        if _slow(k2) != base or t2 == 'D':
            continue                      # a manual door has no tag to aim at
        score = ((t2 != trig), (a2 != again), ('blaze' in k2) != ('blaze' in kind))
        if best_score is None or score < best_score:
            best, best_score = cand, score
    return best


def switch_pairs():
    """{SW1name: SW2name} -- P_InitSwitchList's table, straight out of
    p_switch.c when _doomsrc is there. THE WHOLE table, every episode.

    P_InitSwitchList gates the table on gamemode, and this used to hard-code
    one gamemode (`ep <= 2`, i.e. registered). That is not a decision a
    converter gets to make: it has no gamemode, it has whatever IWAD it was
    pointed at. So it takes the union and lets the WAD decide -- a name that is
    not in the IWAD cannot appear on a sidedef, and pack_map_textures only ever
    ships a mate it can actually find (`wt.get_texture(mate) is not None`).
    Gating it instead dropped every pair above the assumed gamemode, and those
    textures then came back "not a switch": no mate texid, no flip."""
    global _switch_cache
    if _switch_cache is not None:
        return _switch_cache
    _switch_cache = dict(_FALLBACK_SWITCHES)
    p = os.path.join(SRC_DIR, 'p_switch.c')
    if os.path.exists(p):
        txt = open(p, encoding='latin-1').read()
        blk = re.search(r'alphSwitchList\[\]\s*=\s*\{(.*?)\n\};', txt, re.S)
        if blk:
            found = {a.upper(): b.upper() for a, b, ep in re.findall(
                r'\{\s*"(\w+)"\s*,\s*"(\w+)"\s*,\s*(\d+)\s*\}', blk.group(1))
                if int(ep)}                      # ep 0 terminates the table
            if found:
                _switch_cache = found
    return _switch_cache


def is_switch(name):
    """DOOM's own test: this texture is one half of a switch pair."""
    up = (name or '').upper()
    sw = switch_pairs()
    return up in sw or up in set(sw.values())


def switch_mate(name):
    """The texture P_ChangeSwitchTexture flips to, or None."""
    up = (name or '').upper()
    sw = switch_pairs()
    if up in sw:
        return sw[up]
    for a, b in sw.items():
        if b == up:
            return a
    return None


def main():
    sw = switch_pairs()
    src = 'the WAD source tree' if os.path.exists(
        os.path.join(SRC_DIR, 'p_switch.c')) else 'the built-in fallback'
    print(f'MANUAL_DOOR ({len(MANUAL_DOOR):2}): {sorted(MANUAL_DOOR)}')
    print(f'TAG_DOOR    ({len(TAG_DOOR):2}): {sorted(TAG_DOOR)}')
    print(f'GUN_DOOR    ({len(GUN_DOOR):2}): {sorted(GUN_DOOR)}')
    print(f'FLOORS      ({len(FLOORS):2}): {sorted(FLOORS)}')
    print(f'EXIT        ({len(EXIT):2}): {sorted(EXIT)}')
    print(f'switches    ({len(sw):2}) from {src}')
    try:
        sys.path.insert(0, _HERE)
        import pack_things
        keys = set(pack_things.SPEC)
        mine = (FLOORS | TAG_DOOR | GUN_DOOR | TELEPORT | LIGHT_LINE
                | set(CRUSHER) | CRUSH_STOP)
        if keys != mine:
            print(f'  ! pack_things.SPEC disagrees: only there {sorted(keys - mine)}, '
                  f'only here {sorted(mine - keys)}')
        else:
            print('  pack_things.SPEC agrees')
    except Exception as e:                                  # pragma: no cover
        print(f'  (could not cross-check pack_things.SPEC: {e})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
