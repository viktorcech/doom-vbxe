#!/usr/bin/env python3
"""Monster pain / death state chains and sounds, read out of DOOM's info.c.

Companion to doomspecs.py: where that one owns the linedef specials, this one
owns what a monster DOES when it is shot. Both read _pomocne/_doomsrc so the
port and the original game cannot drift apart.

info.c is machine-readable as it ships:

    {SPR_POSS,7,5,{NULL},S_POSS_DIE2,0,0},   // S_POSS_DIE1
     ^sprite  ^fr ^tics   ^next            ^the state's own name

    3004,               // doomednum
    S_POSS_DIE1,        // deathstate
    sfx_podth1,         // deathsound

so `states` is parsed as an ordered list (its index IS the state number, and
the trailing comment names it) and `mobjinfo` as one dict per entry.

API:
    d = doom()
    d.death_chain(3004)   -> [('POSS','H',5,''), ..., ('POSS','L',-1,'')]
                             the 4th field is the state's ACTION ('A_Explode'
                             on the barrel's 4th BEXP frame, p_enemy.c)
    d.pain_chain(3004)    -> [('POSS', 'G', 3), ('POSS', 'G', 3)]
    d.sounds(3004)        -> {'pain': 'DSPOPAIN', 'death': 'DSPODTH1', ...}
    d.spawnhealth(3004)   -> 20

tics -1 means "stay here forever" -- the corpse. Frames are letters, the way
the WAD names its lumps (frame 7 -> 'H'), so they feed Sprites.lump_for
directly.

CLI:  python doomstates.py [doomednum ...]   (default: the E1 monsters)
"""
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(_HERE), '_pomocne', '_doomsrc', 'info.c')

# mobjinfo fields this port cares about, by the comment id.c writes after them.
# speed/reactiontime/meleestate/missilestate came in with the AI work (A_Chase's
# P_Move step and A_Chase's two attack tests, p_enemy.c).
_WANTED = ('doomednum', 'spawnstate', 'spawnhealth', 'seestate', 'seesound',
           'reactiontime', 'attacksound',
           'painstate', 'painchance', 'painsound',
           'meleestate', 'missilestate', 'deathstate', 'xdeathstate',
           'deathsound', 'speed', 'radius', 'mass', 'activesound', 'flags')

MAX_CHAIN = 12                     # runaway guard; the longest real one is XDIE (9)


class Info:
    def __init__(self, text):
        self.text = text
        self.sprnames = self._sprnames(text)
        self.states, self.state_id = self._states(text)
        self.mobj = self._mobjinfo(text)

    # ---- parsing ----------------------------------------------------------
    @staticmethod
    def _sprnames(text):
        m = re.search(r'sprnames\[NUMSPRITES\]\s*=\s*\{(.*?)\};', text, re.S)
        return re.findall(r'"(\w+)"', m.group(1)) if m else []

    @staticmethod
    def _states(text):
        m = re.search(r'state_t\s+states\[NUMSTATES\]\s*=\s*\{(.*?)\n\};', text, re.S)
        out, ids = [], {}
        if not m:
            return out, ids
        row = re.compile(r'\{\s*SPR_(\w+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,'
                         r'\s*\{(\w*)\}\s*,\s*(\w+)\s*,.*?\}\s*,?\s*(?://\s*(\w+))?')
        for line in m.group(1).splitlines():
            r = row.search(line)
            if not r:
                continue
            spr, frame, tics, act, nxt, name = r.groups()
            if name:
                ids[name] = len(out)
            # info.c keeps the fullbright flag INSIDE the frame field (p_pspr.h
            # FF_FULLBRIGHT 0x8000 / FF_FRAMEMASK 0x7fff) -- SKUL's whole state
            # set is written as 32768+n. The port has no per-thing light, so the
            # flag just gets masked off.
            out.append((spr, int(frame) & 0x7FFF, int(tics), nxt,
                        '' if act == 'NULL' else act))
        return out, ids

    @staticmethod
    def _mobjinfo(text):
        m = re.search(r'mobjinfo\[NUMMOBJTYPES\]\s*=\s*\{(.*)\n\};', text, re.S)
        if not m:
            return {}
        out = {}
        cur = {}
        for line in m.group(1).splitlines():
            f = re.match(r'\s*(.+?)\s*,?\s*//\s*(\w+)\s*$', line)
            if f and f.group(2) in _WANTED:
                cur[f.group(2)] = f.group(1).rstrip(',').strip()
            elif re.match(r'\s*\}\s*,?\s*$', line) and cur:
                if 'doomednum' in cur:
                    try:
                        out[int(cur['doomednum'])] = cur
                    except ValueError:
                        pass
                cur = {}
        return out

    # ---- queries ----------------------------------------------------------
    def _chain(self, start):
        """[(sprite base, frame letter, tics)] from state `start` until the
        chain stops (tics -1 = frozen), leaves the sprite, or loops."""
        out, seen = [], set()
        if start == 'S_NULL':          # "this mobj has no such chain". NOT the
            return out                 #   same as "not found": S_NULL is state
        i = self.state_id.get(start)   #   0, a real TROO frame, so the lookup
        if i is None:                  #   below happily returns an imp standing
            return out                 #   still (the barrel has no seestate).
        base0 = self.states[i][0]
        while i is not None and i not in seen and len(out) < MAX_CHAIN:
            seen.add(i)
            spr, frame, tics, nxt, act = self.states[i]
            if spr != base0:                       # walked into another actor
                break
            out.append((spr, chr(ord('A') + frame), tics, act))
            if tics < 0 or nxt == 'S_NULL':
                break
            i = self.state_id.get(nxt)
        return out

    def death_chain(self, doomednum):
        e = self.mobj.get(doomednum, {})
        return self._chain(e.get('deathstate', 'S_NULL'))

    def xdeath_chain(self, doomednum):
        """The GIB chain (S_x_XDIE), the one a rocket earns.

        p_inter.c:719 -- `if (target->health < -target->info->spawnhealth &&
        target->info->xdeathstate)` the corpse goes here instead of to
        deathstate. It is a separate chain, not a longer one: POSS_XDIE is nine
        frames of the zombieman coming apart and shares nothing with POSS_DIE.
        Empty for anything info.c gives no xdeathstate (the barrel already
        explodes; its deathstate IS the burst)."""
        e = self.mobj.get(doomednum, {})
        return self._chain(e.get('xdeathstate', 'S_NULL'))

    def _named_chain(self, start, want):
        """The chain from `start` while the state NAME still contains `want`.
        Every non-death chain in info.c falls back into the RUN loop when it is
        done (S_POSS_PAIN2 -> S_POSS_RUN1, S_POSS_ATK3 -> S_POSS_RUN1), so the
        raw walk would drag the whole walk cycle in with it -- the name is what
        marks the end. [(sprite base, frame letter, tics, action)]."""
        out, i, seen = [], self.state_id.get(start), set()
        while i is not None and i not in seen:
            name = next((k for k, v in self.state_id.items() if v == i), '')
            if want not in name:
                break
            seen.add(i)
            spr, frame, tics, nxt, act = self.states[i]
            out.append((spr, chr(ord('A') + frame), tics, act))
            i = self.state_id.get(nxt)
        return out

    def pain_chain(self, doomednum):
        """Just the flinch (S_x_PAIN, S_x_PAIN2), without its RUN fallback."""
        e = self.mobj.get(doomednum, {})
        return [(s, f, t) for (s, f, t, _a)
                in self._named_chain(e.get('painstate', 'S_NULL'), 'PAIN')]

    def run_chain(self, doomednum):
        """The walk cycle off seestate. It LOOPS (S_POSS_RUN8 -> S_POSS_RUN1),
        so _chain's own seen-set ends it; POSS is 8 states over 4 frames
        (A,A,B,B,C,C,D,D), the cacodemon is one state that points at itself."""
        e = self.mobj.get(doomednum, {})
        return self._chain(e.get('seestate', 'S_NULL'))

    def atk_chain(self, doomednum, melee=False):
        """The missile (or melee) attack states, cut before the RUN fallback.
        Both are named S_x_ATK* in info.c, including the ones a melee-only mobj
        like the demon puts in meleestate."""
        e = self.mobj.get(doomednum, {})
        key = 'meleestate' if melee else 'missilestate'
        return self._named_chain(e.get(key, 'S_NULL'), 'ATK')

    def atk_loop(self, doomednum, melee=False):
        """Where the attack chain's LAST state points back to, as an index into
        atk_chain()'s list -- None when it falls through to the RUN cycle like
        every ordinary chain does.

        p_enemy.c A_SpidRefire is the only action in DOOM that needs this, and
        the spider mastermind is the only mobj in DOOM 1 that runs it:
        S_SPID_ATK4 -> S_SPID_ATK2, which is what keeps a 3000-hit-point boss
        firing instead of taking one burst and walking away. atk_chain cannot
        say it -- _named_chain stops ON the revisited state and drops the fact
        -- so this walks the same names again and keeps the index."""
        e = self.mobj.get(doomednum, {})
        key = 'meleestate' if melee else 'missilestate'
        order, i = [], self.state_id.get(e.get(key, 'S_NULL'))
        while i is not None:
            name = next((k for k, v in self.state_id.items() if v == i), '')
            if 'ATK' not in name:
                return None                 # ran into the RUN fallback: no loop
            if i in order:
                return order.index(i)
            order.append(i)
            i = self.state_id.get(self.states[i][3])    # [3] = nextstate
        return None

    def speed(self, doomednum):
        """info.c speed: the P_Move step in whole map units (monsters are not
        MF_MISSILE, so it is NOT a fixed_t -- p_enemy.c multiplies it by the
        FRACUNIT-scaled xspeed[] table)."""
        v = self.mobj.get(doomednum, {}).get('speed', '0')
        return int(v) if v.isdigit() else 0

    def fields_of_type(self, mtname):
        """Every _WANTED field of the mobjinfo entry whose `// MT_x` comment is
        `mtname`, plus 'damage'. The doomednum-keyed table cannot reach these:
        MT_PLAYER, every MISSILE and every puff carry doomednum -1 and would
        all collide on one key. p_enemy.c names a monster's missile by TYPE
        (P_SpawnMissile(actor, target, MT_TROOPSHOT)), so this is the only way
        to ask what that missile does."""
        m = re.search(r'\{\s*//\s*' + re.escape(mtname) + r'\s*\n(.*?)\n\s*\}',
                      self.text, re.S)
        if not m:
            return {}
        out = {}
        for line in m.group(1).splitlines():
            f = re.match(r'\s*(.+?)\s*,?\s*//\s*(\w+)\s*$', line)
            if f and (f.group(2) in _WANTED or f.group(2) == 'damage'):
                out[f.group(2)] = f.group(1).rstrip(',').strip()
        return out

    def radius_of_type(self, mtname):
        """info.c radius of a mobjinfo entry looked up by its `// MT_x` comment,
        in whole map units. radius() cannot reach MT_PLAYER: its doomednum is
        -1, which it shares with every missile and puff in the table."""
        v = self.fields_of_type(mtname).get('radius', '')
        r = re.match(r'(\d+)\s*\*\s*FRACUNIT\s*$', v)
        return int(r.group(1)) if r else 0

    def radius(self, doomednum):
        """info.c radius in whole map units. Unlike speed this IS a fixed_t --
        it is written `20*FRACUNIT` -- and p_map.c PIT_CheckThing compares it
        against thing coordinates, which the port keeps in whole units."""
        v = self.mobj.get(doomednum, {}).get('radius', '0')
        m = re.match(r'(\d+)\s*\*\s*FRACUNIT\s*$', v)
        if m:
            return int(m.group(1))
        return int(v) >> 16 if v.isdigit() else 0

    def spawnhealth(self, doomednum):
        v = self.mobj.get(doomednum, {}).get('spawnhealth', '0')
        return int(v) if v.isdigit() else 0

    def mass(self, doomednum):
        """info.c mass. P_DamageMobj's kick divides by it: a hit hands the
        victim `damage*(FRACUNIT>>3)*100/mass` of momentum, so the barrel and
        a zombieman (100) slide four times as far as a demon (400)."""
        v = self.mobj.get(doomednum, {}).get('mass', '0')
        return int(v) if v.isdigit() else 0

    def reactiontime(self, doomednum):
        """info.c reactiontime: A_Chase counts it down and P_CheckMissileRange
        refuses to fire while it is nonzero -- the pause after a monster wakes."""
        v = self.mobj.get(doomednum, {}).get('reactiontime', '0')
        return int(v) if v.isdigit() else 0

    def has_melee(self, doomednum):
        """meleestate != S_NULL. A_Chase's melee branch needs it, and
        P_CheckMissileRange fires from 128 units further out without it."""
        v = self.mobj.get(doomednum, {}).get('meleestate', '0')
        return 0 if v in ('0', 'S_NULL') else 1

    def painchance(self, doomednum):
        v = self.mobj.get(doomednum, {}).get('painchance', '0')
        return int(v) if v.isdigit() else 0

    def sounds(self, doomednum):
        """{'pain'/'death'/'see'/'active': WAD lump name} -- sfx_popain -> DSPOPAIN.
        Entries whose sound is 0 (silent) are left out."""
        e = self.mobj.get(doomednum, {})
        out = {}
        for key, field in (('pain', 'painsound'), ('death', 'deathsound'),
                           ('see', 'seesound'), ('active', 'activesound')):
            v = e.get(field, '0')
            if v.startswith('sfx_'):
                out[key] = 'DS' + v[4:].upper()
        return out

    def is_monster(self, doomednum):
        return 'MF_COUNTKILL' in self.mobj.get(doomednum, {}).get('flags', '')


_cache = None


def doom():
    global _cache
    if _cache is None:
        if not os.path.exists(SRC):
            raise FileNotFoundError(
                f'{SRC} missing -- the DOOM source tree is the authority for '
                f'monster states; check out _pomocne/_doomsrc')
        _cache = Info(open(SRC, encoding='latin-1').read())
    return _cache


# The shootable things the built EPISODES spawn, in the order pack_things.py
# turns into its "kind" byte. The BARREL is one of them: info.c gives it
# MF_SHOOTABLE, 20 health, a BEXP death chain and sfx_barexp -- it is a monster
# as far as this port's damage code is concerned, it just explodes instead of
# dying.
#
# APPEND ONLY. The kind byte is 1 + the index here, and memory_map.inc pins two
# of them by number (MK_BOSS = the baron, MK_BEXP = the barrel); pack_things.py
# emits an `ert` for each, so reordering the first nine fails the build rather
# than silently renumbering a kind the 6502 compares against.
#
# 2026-08-20: the two FINAL BOSSES joined the roster (they were deferred on
# 2026-08-18 and a baron stood in for both). The cyberdemon is E2M8's and
# E3M9's, the spider mastermind is E3M8's -- p_enemy.c A_BossDeath gates on
# exactly those types per episode, and en_bossdie now reads the level's boss
# kind out of the .things header instead of comparing against MK_BOSS.
MONSTERS = (3004, 9, 3001, 3002, 58, 3006, 3005, 3003, 2035, 16, 7)
E1_MONSTERS = MONSTERS            # the old name; episode 1 is no longer all of it


def main():
    d = doom()
    nums = [int(a) for a in sys.argv[1:]] or list(MONSTERS)
    print(f'{len(d.states)} states, {len(d.mobj)} mobjinfo entries, '
          f'{len(d.sprnames)} sprite names')
    for num in nums:
        if num not in d.mobj:
            print(f'{num}: not in mobjinfo')
            continue
        dc, pc = d.death_chain(num), d.pain_chain(num)
        s = d.sounds(num)
        print(f'\n{num:5} {dc[0][0] if dc else "?":4}  hp {d.spawnhealth(num):4}  '
              f'painchance {d.painchance(num):3}  monster={d.is_monster(num)}')
        # built outside the f-string on purpose: nesting a "..." f-string inside
        # a "..." f-string expression only parses from Python 3.12 (PEP 701),
        # and a SyntaxError here kills the IMPORT -- which took pack_things and
        # everything that imports it with it.
        deaths = ' '.join('%s/%s%s' % (f, t, '*' + a if a else '')
                          for _b, f, t, a in dc)
        print(f'      death {deaths}')
        print(f'      pain  {" ".join(f"{f}/{t}" for _b, f, t in pc)}')
        print(f'      snd   {s}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
