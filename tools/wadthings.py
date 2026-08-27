#!/usr/bin/env python3
"""DOOM THINGS -> sprites: the item/decoration layer the port was missing.

Data side only (like wadtex.py is for walls):
  * MOBJ            -- doomednum -> (sprite base, frame, class, radius, height,
                       hangs-from-ceiling), the DOOM 1 subset of mobjinfo.c
  * Sprites         -- lump index S_START..S_END -> (base, frame, rotation, flip)
  * map_things()    -- skill + single-player filtered THINGS of a map, each one
                       resolved to a real sprite lump (or reported unresolved)

Rotation follows DOOM: rot = ((angle viewer->thing) - thing.angle + 202.5deg)/45,
lump rotation digit 1..8, digit 0 = one sprite for all angles. Lumps named
XXXXA2A8 hold frame A rot 2 and, mirrored, rot 8 (flip=True).

CLI (verification):
  python wadthings.py            -> E1M1 inventory + sprite resolution
  python wadthings.py --verify   -> resolve EVERY MOBJ entry against the WAD
  python wadthings.py --dump BAR1A0 -> _pomocne/preview/<lump>.png
"""
import math
import os
import struct
import sys
from collections import Counter

from wadlib import Wad, DEFAULT_WAD
from wadtex import WadTextures

_HERE = os.path.dirname(os.path.abspath(__file__))

# THINGS flags (MTF_*)
MTF_EASY = 1            # skill 1+2
MTF_NORMAL = 2          # skill 3
MTF_HARD = 4            # skill 4+5
MTF_AMBUSH = 8          # deaf
MTF_MULTIPLAYER = 16    # not in single player

# classes -- what the renderer/engine does with it
C_START = 'start'       # player/DM start, teleport dest: nothing is drawn
C_MONSTER = 'monster'   # 8 rotations, blocks movement
C_WEAPON = 'weapon'
C_AMMO = 'ammo'
C_HEALTH = 'health'
C_ARMOR = 'armor'
C_POWER = 'power'       # counts as "item" in the DOOM item %
C_KEY = 'key'
C_OBSTACLE = 'obstacle'  # decoration that blocks (barrel, pillar, lamp)
C_DECOR = 'decor'        # decoration that does not block (corpse, candle)

PICKUP = (C_WEAPON, C_AMMO, C_HEALTH, C_ARMOR, C_POWER, C_KEY)
# DOOM's ITEMCOUNT (the "Items %" on the intermission screen) -- MF_COUNTITEM.
# NOTE: green/blue armor (2018/2019) are NOT counted items in mobjinfo.c.
COUNTITEM = {2013, 2014, 2015, 2022, 2023, 2024, 2025, 2026, 2045, 83}

# doomednums whose sprites only exist in DOOM 2 (missing from a DOOM 1 IWAD)
DOOM2_ONLY = {79, 80, 81}

# doomednum: (sprite, frame, class, radius, height, ceiling-hung)
MOBJ = {
    1:    ('PLAY', 'A', C_START, 16, 56, 0),
    2:    ('PLAY', 'A', C_START, 16, 56, 0),
    3:    ('PLAY', 'A', C_START, 16, 56, 0),
    4:    ('PLAY', 'A', C_START, 16, 56, 0),
    11:   ('PLAY', 'A', C_START, 16, 56, 0),
    14:   ('TFOG', 'A', C_START, 16, 56, 0),
    # --- monsters ---
    3004: ('POSS', 'A', C_MONSTER, 20, 56, 0),   # zombieman
    9:    ('SPOS', 'A', C_MONSTER, 20, 56, 0),   # shotgun guy
    3001: ('TROO', 'A', C_MONSTER, 20, 56, 0),   # imp
    3002: ('SARG', 'A', C_MONSTER, 30, 56, 0),   # demon
    58:   ('SARG', 'A', C_MONSTER, 30, 56, 0),   # spectre
    3006: ('SKUL', 'A', C_MONSTER, 16, 56, 0),   # lost soul
    3005: ('HEAD', 'A', C_MONSTER, 31, 56, 0),   # cacodemon
    3003: ('BOSS', 'A', C_MONSTER, 24, 64, 0),   # baron
    # The FINAL BOSSES, real since 2026-08-20 (a baron stood in for both from
    # 2026-08-18). They are ordinary MK_ORDER kinds now -- info.c radius and
    # height verbatim, which is what _check_radius_rule and en_radfill want --
    # and the two big sets cost only what the level they stand on can afford:
    # the pixels live in Rapidus SDRAM and plan_views prices the coltab run,
    # so E3M8's spider drops to a two-image walk cycle and keeps its four
    # views. p_enemy.c A_BossDeath fires off THEIR type on E2M8/E3M8, not off
    # the baron's -- see pack_things BOSS_TYPE and enemy.asm en_bossdie.
    16:   ('CYBR', 'A', C_MONSTER, 40, 110, 0),  # cyberdemon      (E2M8, E3M9)
    7:    ('SPID', 'A', C_MONSTER, 128, 100, 0), # spider mastermind (E3M8)
    # --- weapons ---
    2005: ('CSAW', 'A', C_WEAPON, 20, 16, 0),
    2001: ('SHOT', 'A', C_WEAPON, 20, 16, 0),
    2002: ('MGUN', 'A', C_WEAPON, 20, 16, 0),
    2003: ('LAUN', 'A', C_WEAPON, 20, 16, 0),
    2004: ('PLAS', 'A', C_WEAPON, 20, 16, 0),
    2006: ('BFUG', 'A', C_WEAPON, 20, 16, 0),
    # --- ammo ---
    2007: ('CLIP', 'A', C_AMMO, 20, 16, 0),
    2048: ('AMMO', 'A', C_AMMO, 20, 16, 0),
    2010: ('ROCK', 'A', C_AMMO, 20, 16, 0),
    2046: ('BROK', 'A', C_AMMO, 20, 16, 0),
    2047: ('CELL', 'A', C_AMMO, 20, 16, 0),
    17:   ('CELP', 'A', C_AMMO, 20, 16, 0),
    2008: ('SHEL', 'A', C_AMMO, 20, 16, 0),
    2049: ('SBOX', 'A', C_AMMO, 20, 16, 0),
    8:    ('BPAK', 'A', C_AMMO, 20, 16, 0),
    # --- health / armor (BON1/BON2/SOUL animate A-B-C-D) ---
    2011: ('STIM', 'A', C_HEALTH, 20, 16, 0),
    2012: ('MEDI', 'A', C_HEALTH, 20, 16, 0),
    2014: ('BON1', 'A', C_HEALTH, 20, 16, 0),   # health bonus
    2013: ('SOUL', 'A', C_HEALTH, 20, 16, 0),   # soulsphere
    2015: ('BON2', 'A', C_ARMOR, 20, 16, 0),    # armor bonus
    2018: ('ARM1', 'A', C_ARMOR, 20, 16, 0),    # green armor
    2019: ('ARM2', 'A', C_ARMOR, 20, 16, 0),    # blue armor
    # --- powerups ---
    2022: ('PINV', 'A', C_POWER, 20, 16, 0),
    2023: ('PSTR', 'A', C_POWER, 20, 16, 0),
    2024: ('PINS', 'A', C_POWER, 20, 16, 0),
    2025: ('SUIT', 'A', C_POWER, 20, 16, 0),
    2026: ('PMAP', 'A', C_POWER, 20, 16, 0),
    2045: ('PVIS', 'A', C_POWER, 20, 16, 0),
    # --- keys ---
    5:    ('BKEY', 'A', C_KEY, 20, 16, 0),
    40:   ('BSKU', 'A', C_KEY, 20, 16, 0),
    6:    ('YKEY', 'A', C_KEY, 20, 16, 0),
    39:   ('YSKU', 'A', C_KEY, 20, 16, 0),
    13:   ('RKEY', 'A', C_KEY, 20, 16, 0),
    38:   ('RSKU', 'A', C_KEY, 20, 16, 0),
    # --- obstacles (block the player) ---
    2035: ('BAR1', 'A', C_OBSTACLE, 10, 42, 0),   # explosive barrel
    2028: ('COLU', 'A', C_OBSTACLE, 16, 48, 0),   # floor lamp
    48:   ('ELEC', 'A', C_OBSTACLE, 16, 128, 0),  # tall techno pillar
    30:   ('COL1', 'A', C_OBSTACLE, 16, 48, 0),
    31:   ('COL2', 'A', C_OBSTACLE, 16, 40, 0),
    32:   ('COL3', 'A', C_OBSTACLE, 16, 48, 0),
    33:   ('COL4', 'A', C_OBSTACLE, 16, 40, 0),
    36:   ('COL5', 'A', C_OBSTACLE, 16, 40, 0),
    37:   ('COL6', 'A', C_OBSTACLE, 16, 40, 0),
    41:   ('CEYE', 'A', C_OBSTACLE, 16, 56, 0),
    42:   ('FSKU', 'A', C_OBSTACLE, 16, 56, 0),
    43:   ('TRE1', 'A', C_OBSTACLE, 16, 56, 0),
    44:   ('TBLU', 'A', C_OBSTACLE, 16, 56, 0),
    45:   ('TGRN', 'A', C_OBSTACLE, 16, 56, 0),
    46:   ('TRED', 'A', C_OBSTACLE, 16, 56, 0),
    55:   ('SMBT', 'A', C_OBSTACLE, 16, 56, 0),
    56:   ('SMGT', 'A', C_OBSTACLE, 16, 56, 0),
    57:   ('SMRT', 'A', C_OBSTACLE, 16, 56, 0),
    47:   ('SMIT', 'A', C_OBSTACLE, 16, 56, 0),
    54:   ('TRE2', 'A', C_OBSTACLE, 32, 108, 0),
    35:   ('CBRA', 'A', C_OBSTACLE, 16, 56, 0),   # candelabra
    # --- hanging bodies (ceiling-anchored; 49-53 block, 59-63 do not) ---
    49:   ('GOR1', 'A', C_OBSTACLE, 16, 68, 1),
    50:   ('GOR2', 'A', C_OBSTACLE, 16, 84, 1),
    51:   ('GOR3', 'A', C_OBSTACLE, 16, 84, 1),
    52:   ('GOR4', 'A', C_OBSTACLE, 16, 68, 1),
    53:   ('GOR5', 'A', C_OBSTACLE, 16, 52, 1),
    59:   ('GOR2', 'A', C_DECOR, 16, 84, 1),
    60:   ('GOR4', 'A', C_DECOR, 16, 68, 1),
    61:   ('GOR3', 'A', C_DECOR, 16, 84, 1),
    62:   ('GOR5', 'A', C_DECOR, 16, 52, 1),
    63:   ('GOR1', 'A', C_DECOR, 16, 68, 1),
    # --- non-blocking decoration / gore ---
    34:   ('CAND', 'A', C_DECOR, 20, 16, 0),      # candle
    25:   ('POL1', 'A', C_OBSTACLE, 16, 56, 0),   # impaled human
    26:   ('POL6', 'A', C_OBSTACLE, 16, 56, 0),
    27:   ('POL4', 'A', C_OBSTACLE, 16, 56, 0),
    28:   ('POL2', 'A', C_OBSTACLE, 16, 56, 0),
    29:   ('POL3', 'A', C_OBSTACLE, 16, 56, 0),
    24:   ('POL5', 'A', C_DECOR, 20, 16, 0),      # pool of blood and flesh
    79:   ('POB1', 'A', C_DECOR, 20, 16, 0),
    80:   ('POB2', 'A', C_DECOR, 20, 16, 0),
    81:   ('BRS1', 'A', C_DECOR, 20, 16, 0),
    10:   ('PLAY', 'W', C_DECOR, 20, 16, 0),      # bloody mess
    12:   ('PLAY', 'W', C_DECOR, 20, 16, 0),
    15:   ('PLAY', 'N', C_DECOR, 20, 16, 0),      # dead player
    18:   ('POSS', 'L', C_DECOR, 20, 16, 0),      # dead zombieman
    19:   ('SPOS', 'L', C_DECOR, 20, 16, 0),      # dead shotgun guy
    20:   ('TROO', 'M', C_DECOR, 20, 16, 0),      # dead imp
    21:   ('SARG', 'N', C_DECOR, 20, 16, 0),      # dead demon
    22:   ('HEAD', 'L', C_DECOR, 20, 16, 0),      # dead cacodemon
    23:   ('SKUL', 'K', C_DECOR, 20, 16, 0),      # dead lost soul (no sprite)
}


class Sprites:
    """S_START..S_END lump index: base -> frame -> rot -> (lumpname, flip)."""

    def __init__(self, wad, wt=None):
        self.w = wad
        self.wt = wt or WadTextures(wad)
        self.frames = {}
        names = [n for n, _, _ in wad.lumps]
        try:
            i0, i1 = names.index('S_START'), names.index('S_END')
        except ValueError:
            raise ValueError('WAD has no S_START/S_END sprite section')
        for nm in names[i0 + 1:i1]:
            if len(nm) not in (6, 8):
                continue
            base = nm[:4]
            for k in (4, 6):
                if k + 1 >= len(nm):
                    break
                fr, rot = nm[k], nm[k + 1]
                if not rot.isdigit():
                    continue
                self.frames.setdefault(base, {}).setdefault(fr, {})[int(rot)] = (nm, k == 6)

    def lump_for(self, base, frame, rot=0):
        """(lumpname, flip) for base/frame at rotation 1..8, or None."""
        fr = self.frames.get(base, {}).get(frame)
        if not fr:
            return None
        if 0 in fr:                       # angle-independent sprite
            return fr[0]
        return fr.get(rot or 1) or fr.get(1) or next(iter(fr.values()))

    def patch(self, lumpname):
        """(w, h, left, top, cols) -- cols[x] = [(topdelta, [pixels]), ...].
        Gaps between posts are transparent (that is the masked sprite column)."""
        p = self.wt.get_patch(lumpname)
        if p is None:
            return None
        w, h, cols = p
        left, top = self.wt.patch_offset(lumpname)
        return (w, h, left, top, cols)


def rot_for(view_x, view_y, t):
    """DOOM R_ProjectSprite rotation index 1..8 for thing t seen from view_x/y."""
    ang = math.degrees(math.atan2(t.y - view_y, t.x - view_x))
    rel = (ang - t.angle + 202.5) % 360.0        # + 45/2*9, as in the source
    return int(rel // 45.0) + 1


def skill_ok(flags, skill=4, multiplayer=False):
    """DOOM P_SpawnMapThing filter: skill bit + 'not in single player'."""
    if not multiplayer and (flags & MTF_MULTIPLAYER):
        return False
    bit = MTF_EASY if skill <= 2 else (MTF_NORMAL if skill == 3 else MTF_HARD)
    return bool(flags & bit)


def map_things(md, skill=4, multiplayer=False, drop=('start',)):
    """Renderable things of a map: [(thing, sprite, frame, class, radius,
    height, ceiling)]; unknown doomednums are returned with sprite None."""
    out = []
    for t in md.things:
        if not skill_ok(t.flags, skill, multiplayer):
            continue
        e = MOBJ.get(t.type)
        if e is None:
            out.append((t, None, None, 'unknown', 20, 16, 0))
            continue
        if e[2] in drop:
            continue
        out.append((t,) + e)
    return out


# ---- CLI verification -------------------------------------------------------
def _verify_all(w, sp):
    bad = []
    for num, (base, frame, cls, _r, _h, _c) in sorted(MOBJ.items()):
        if cls == C_START or num in DOOM2_ONLY:
            continue
        if sp.lump_for(base, frame, 1) is None:
            bad.append((num, base + frame))
    print(f'MOBJ table: {len(MOBJ)} doomednums ({len(DOOM2_ONLY)} DOOM-2-only skipped), '
          f'{len(sp.frames)} sprite bases in WAD')
    if bad:
        print(f'  UNRESOLVED ({len(bad)}): ' +
              ', '.join(f'{n}={s}' for n, s in bad))
    else:
        print('  all entries resolve to a real sprite lump')
    return bad


def _inventory(w, sp, mapname, skill=4):
    md = w.load_map(mapname)
    all_things = md.things
    kept = map_things(md, skill=skill, drop=())
    print(f'{mapname}: {len(all_things)} THINGS in lump, '
          f'{len(kept)} after skill={skill} single-player filter')
    unknown = [t for (t, s, f, c, *_ ) in kept if c == 'unknown']
    per_class = Counter(c for (_t, _s, _f, c, *_) in kept)
    print('  by class: ' + ', '.join(f'{k}={v}' for k, v in sorted(per_class.items())))
    print(f'  unknown doomednums: {sorted(set(t.type for t in unknown)) or "none"}')
    miss = []
    rows = []
    for (t, base, frame, cls, r, h, ceil) in kept:
        if cls == C_START:
            continue
        lf = sp.lump_for(base, frame, rot_for(0, 0, t))
        if lf is None:
            miss.append((t.type, base, frame))
        else:
            pat = sp.patch(lf[0])
            rows.append((t.type, cls, base + frame, lf[0], pat[0], pat[1]))
    print(f'  drawable: {len(rows)} sprites, unresolved: {miss or "none"}')
    seen = {}
    for ty, cls, bf, lump, pw, ph in rows:
        seen.setdefault((ty, cls, bf), [0, lump, pw, ph])[0] += 1
    for (ty, cls, bf), (n, lump, pw, ph) in sorted(seen.items(), key=lambda kv: (kv[0][1], -kv[1][0])):
        print(f'    {ty:>4}  {cls:<8} {bf:<5} x{n:<3} {lump:<9} {pw:>3}x{ph:<3}')
    items = sum(1 for t in md.things
                if t.type in COUNTITEM and skill_ok(t.flags, skill))
    monst = sum(1 for (_t, _b, _f, c, *_ ) in kept if c == C_MONSTER)
    starts = Counter(t.type for t in md.things if t.type in (1, 2, 3, 4, 11))
    print(f'  DOOM item% count = {items}, monsters = {monst}, '
          f'starts p1..p4={[starts.get(i, 0) for i in (1, 2, 3, 4)]} dm={starts.get(11, 0)}')
    return md, kept


def _dump(sp, lumpname):
    from PIL import Image
    pat = sp.patch(lumpname.upper())
    if pat is None:
        print(f'no such sprite lump: {lumpname}')
        return
    pw, ph, left, top, cols = pat
    img = Image.new('RGBA', (pw, ph), (0, 0, 0, 0))
    px = img.load()
    pal = sp.wt.playpal
    for x in range(pw):
        for (td, pix) in cols[x]:
            for k, c in enumerate(pix):
                if 0 <= td + k < ph:
                    px[x, td + k] = pal[c] + (255,)
    out_dir = os.path.join(os.path.dirname(_HERE), '_pomocne', 'preview')
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f'{lumpname.upper()}.png')
    img.resize((pw * 3, ph * 3), Image.NEAREST).save(out)
    print(f'{lumpname.upper()}: {pw}x{ph} off=({left},{top}) -> {out}')


def main():
    w = Wad(DEFAULT_WAD)
    sp = Sprites(w)
    if '--dump' in sys.argv:
        _dump(sp, sys.argv[sys.argv.index('--dump') + 1])
        return
    _verify_all(w, sp)
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    skill = 4
    if '--skill' in sys.argv:
        skill = int(sys.argv[sys.argv.index('--skill') + 1])
    for mn in (args or ['E1M1']):
        print()
        _inventory(w, sp, mn, skill)


if __name__ == '__main__':
    main()
