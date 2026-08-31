#!/usr/bin/env python3
"""bank_map -- what lives in Rapidus bank $01, and whether any of it collides.

tools/ram_map.py has covered the 6502's own 64 KB since the beginning. Bank $01
never had a map, and on 2026-08-20 that cost the port a real bug: PJSLOT_EXT
(the player's eight projectile contexts, 512 B) sat exactly on top of TH_TARG
and TH_THRS (the infighting target and threshold pages). Both comments in
memory_map.inc claimed "the first free page of the bank"; they were written
months apart and nothing in the build could tell them apart, because the
assembler never sees these -- they are equates the engine reaches with
`lda [zp_ptr],y` and a bank byte, not segments MADS lays out.

So this is the guard that did not exist. It reads the equates straight out of
memory_map.inc, prices every region from the same constants the engine uses, and
fails if two overlap or one runs past the bank.

    python tools/bank_map.py            # the map
    python tools/bank_map.py --check    # ...and exit 1 on an overlap
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
INC = os.path.join(ROOT, 'memory_map.inc')

BANK = 0x10000                       # bank $01 is 64 KB like every other


def equs():
    """Every `NAME equ <number>` in memory_map.inc, decimal or $hex. Expressions
    (DOOR_STATE = DOOR_BASE+..., RECIP_EXT+$600) are deliberately NOT evaluated:
    the regions below name their own base, and a half-resolved symbol table is
    worse than a missing one."""
    out = {}
    for m in re.finditer(r'^(\w+)\s+equ\s+(\$[0-9A-Fa-f]+|\d+)\s*(;|$)',
                         open(INC, encoding='latin-1').read(), re.M):
        v = m.group(2)
        out[m.group(1)] = int(v[1:], 16) if v.startswith('$') else int(v)
    return out


E = equs()


def n(name, default=None):
    if name in E:
        # RECIP_EXT is written as a full 24-bit $018000; everything else is a
        # bare bank offset. Mask so both describe the same 64 KB.
        return E[name] & 0xFFFF if E[name] > 0xFFFF else E[name]
    if default is not None:
        return default
    sys.exit(f'bank_map: {name} is not an equate in memory_map.inc any more')


# (base symbol, size, what it is). The SIZE is priced from the same constants
# the engine indexes with, so a table that grows moves the map with it.
REGIONS = [
    ('DOOR_EXT',   13 * n('DOORS_NMAX'), 'door arrays (13 x DOORS_NMAX)'),
    ('TH_TARG',    256, 'mobj_t.target, per thing (infight.asm)'),
    ('TH_HPL',     256, 'health, low'),
    ('TH_HPH',     256, 'health, high'),
    ('TH_CELL',    256, 'blockmap cell'),
    ('TH_BNEXT',   256, 'next thing in that cell'),
    ('TH_STATE',   256, 'death-animation row + 1 (0 = alive)'),
    ('TH_TICS',    256, 'tics left in that row'),
    ('LOS_EXT',    n('LOS_NMAX') * n('LOS_REC'), 'barrel line-of-sight grids'),
    ('BLK_HEAD',   64,  'first thing in each blockmap cell'),
    ('TH_WROW',    256, 'walk row + 1 (0 = not chasing)'),
    ('TH_WST',     256, 'RUN state index'),
    ('TH_WTIC',    256, 'tics left in that state'),
    ('TH_DIR',     256, 'movedir'),
    ('TH_MCNT',    256, 'movecount'),
    ('TH_KIND',    256, 'the kind byte (en_kfill)'),
    ('TH_MODE',    256, 'RUN chain or ATTACK chain + the mode bits'),
    ('TH_SEEN',    256, 'the cached sight answer'),
    ('TH_RAD',     256, 'PIT_CheckThing radius'),
    ('RECIP_EXT',  n('RECIP_BYTES'), 'reciprocal + trig tables (RECIP+TRGX)'),
    ('PJSLOT_EXT', n('PJ_NSLOT') * n('PJ_SLSTR'), "the player's missile contexts"),
    ('DTAB_EXT',   n('DTAB_BYTES'), 'death/walk/attack/gib/idle rows + 10 headers'),
    # SNDX_BYTES is written as SNDX_N*5 and equs() only reads plain numbers, so
    # price it from SNDX_N here the way the other five-array sums are priced.
    ('SNDX_EXT',   n('SNDX_N') * 5, 'the five per-SFX arrays (sound_tables.inc)'),
    # 2026-08-26: CODE, not data. bank01.asm's procedures are assembled at
    # B1CODE_OFF and copied here by b1_to_ext at boot; the 65816 executes them
    # in place at full speed (the fetch goes through the PROGRAM bank register
    # and the SRAM layer is FastBus -- see memory_map.inc). Priced at
    # B1CODE_MAX, not at what the block happens to hold today, because that is
    # the bound b1_to_ext and bank01.asm's own ert are written against.
    ('B1CODE_OFF',  n('B1CODE_MAX'), 'bank01.asm: cold engine code, run in place'),
    # 2026-08-31: the frac-table pages, the SQ2 masters and the second code
    # block (see memory_map.inc's B1CODE2 banner for the whole story).
    ('TSIN_LO',    6 * 256, 'TSIN/TCOS frac tables (b1_build_frac writes, FMUL reads long)'),
    ('SQ2L_EXT',   512, 'SQ2L master (b1_sq2_restore repaints $C900 from it)'),
    ('SQ2H_EXT',   512, 'SQ2H master (... and $CB00)'),
    ('B1CODE2_OFF', n('B1CODE2_MAX'), 'bank01.asm: b1_build_frac + b1_sq2_restore + b1_amopen'),
    ('AMOVL_EXT',  5 * 256, 'the automap overlay (b1_amopen serves it per frame)'),
    # SPRCOL_EXT and FTAB_EXT left this bank on 2026-08-21 for bank $08
    # (SPRCOL_BANK): the 24 KB coltab run here was what made plan_views drop
    # NSTOR to 1 -- no side or back views for any monster -- and bank $01 had
    # 219 B free, so it could not grow. Bank $08 is empty and whole. They are
    # NOT listed below any more: this map is bank $01's.
    ('FARENA_EXT', 255 * 3, 'frame -> VRAM arena address (runtime)'),
    ('TH_THRS',    256, 'mobj_t.threshold, per thing'),
]

# The map itself owns everything below DOOR_EXT: pack_map.py EXT_LIMIT is what
# holds it there, and it is a per-level blob, not an equate.
MAP_TOP = 'DOOR_EXT'


def main():
    rows = sorted(((n(sym), n(sym) + size - 1, sym, what)
                   for sym, size, what in REGIONS))
    top = n(MAP_TOP)
    print(f'Rapidus bank $01 ({BANK // 1024} KB)\n')
    print(f'  $0000-${top - 1:04X}  {top:6} B  the streamed MAP blob '
          f'(pack_map.py EXT_LIMIT)')
    bad, cur = 0, top
    for lo, hi, sym, what in rows:
        if lo > cur:
            print(f'  $%04X-$%04X  %6d B  -- free --' % (cur, lo - 1, lo - cur))
        if lo < cur:
            bad += 1
            print(f'  $%04X-$%04X  %6d B  {sym:12} {what}' % (lo, hi, hi - lo + 1))
            print(f'  {"":24}^^ COLLISION: starts ${cur - lo} bytes inside the '
                  f'region above')
            cur = max(cur, hi + 1)
            continue
        print(f'  $%04X-$%04X  %6d B  {sym:12} {what}' % (lo, hi, hi - lo + 1))
        cur = hi + 1
    if cur < BANK:
        print(f'  $%04X-$FFFF  %6d B  -- free --' % (cur, BANK - cur))
    if cur > BANK:
        bad += 1
        print(f'  ^^ the bank ENDS at $FFFF and this runs {cur - BANK} B past it')
    free = BANK - top - sum(hi - lo + 1 for lo, hi, _s, _w in rows)
    print(f'\n  {free} B free in the bank, largest run '
          f'{max_run(rows, top)} B')
    if bad:
        print(f'\n{bad} COLLISION(S) -- two regions share bytes. Nothing in the '
              f'build can\nsee this on its own: these are equates the engine '
              f'reaches through a bank\nbyte, not segments the assembler lays '
              f'out.')
    else:
        print('\nno collisions')
    return 1 if bad and '--check' in sys.argv else 0


def max_run(rows, top):
    best, cur = 0, top
    for lo, hi, _s, _w in rows:
        best = max(best, lo - cur)
        cur = max(cur, hi + 1)
    return max(best, BANK - cur)


if __name__ == '__main__':
    sys.exit(main())
