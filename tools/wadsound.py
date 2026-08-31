#!/usr/bin/env python3
"""DOOM DS* sound lumps -> one Rapidus-resident 4-bit sample blob + MADS tables.

The Atari plays digitized SFX the way the wolf3d port does (w3d/src/sound.asm,
HW-verified): a POKEY Timer-1 IRQ at ~3959 Hz (PAL, AUDF1 = 15) writes one 4-bit
sample per interrupt into an AUDCn as a volume-only DAC. Two samples pack into a
byte (hi nibble first), so ONE voice costs ~1980 B/s. Since 2026-08-06 there are
SND_NV = 4 of those voices, one per POKEY channel, summed in POKEY itself -- the
blob format is unchanged, four readers walk it at once.

The samples are far too big for the port's ~130 free bytes of RAM, so the whole
blob lives in VBXE VRAM ($07C000 = MEMAC-B bank 31, the 16 KB above the HUD
graphics) and the IRQ reads ONE byte at a time through the MEMAC-B window
($4000-$7FFF, mapped for ~3 instructions per read). This tool builds that blob
plus `sound_tables.inc`, whose per-SFX tables address the samples at their window
address ($4000 + offset), so the player needs no arithmetic at all.

Conversion per lump:
  * DMX header (u16 fmt=3, u16 rate, u32 nsamples) + 16 pad samples at each end,
  * box-average resample 11025 Hz -> the POKEY IRQ rate (a plain decimation
    aliases audibly),
  * peak-normalize (4 bits of DAC is little; a quiet lump would be inaudible),
  * quantize to 4 bits, with a short ramp in/out so AUDC4 does not step from 0 to
    mid-scale and click at every sound start/end.

Usage:  python tools/wadsound.py [--wad DOOM.WAD] [--rate 3959] [--wav]
Output: build/assets/sounds/sounds.bin   (padded to whole 4 KB VBXE banks)
        sound_tables.inc                 (SFX_* ids + sfx_lo/hi + sfx_nlo/nhi)
        --wav: build/assets/sounds/*.wav -- EXACTLY what the Atari will play
        (decoded back from the packed nibbles), so the 4-bit quality can be
        judged without booting the ATR.
"""
import os
import struct
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
_PROJ = os.path.dirname(_HERE)
sys.path.insert(0, _HERE)
from wadlib import Wad, DEFAULT_WAD

OUT_BIN = os.path.join(_PROJ, 'build', 'assets', 'sounds', 'sounds.bin')
OUT_INC = os.path.join(_PROJ, 'sound_tables.inc')
OUT_PITCH = os.path.join(_PROJ, 'snd_pitch.inc')

# POKEY Timer-1: PAL 64 kHz base = 1773447/28 = 63337 Hz, AUDF1 = 15 -> /16.
POKEY_RATE = 63337 // 16              # 3958 Hz -- one IRQ = one 4-bit sample
WINDOW_BASE = 0x4000                  # MEMAC-B window: VRAM bank -> $4000-$7FFF
BANK_BYTES = 0x4000                   # MEMAC-B bank size (16 KB) -- the hard cap
CHUNK = 0x1000                        # VBXE bank granularity for the ATR streamer
RAMP = 6                              # samples of click-suppression at each end
MAX_GAIN = 6.0                        # normalization ceiling (don't amplify hiss)
# Per-SFX cap in PACKED bytes. The bank is a hard 16 KB and DSPLPAIN alone wants
# 3781 B of it, which does not fit alongside the rest -- so it is cut short and
# faded out. The scream's character is all in its first third anyway.
# 2026-07-30 (weapons): the two gunshots had to come out of the same 16 KB, so
# the three longest sounds are capped. All three are tails, not attacks:
#   TELEPT  1.45 s -> 0.76 s   the rising whoosh; the pitch sweep is at the front
#   PISTOL  0.51 s -> 0.24 s   DOOM's clip is mostly decay after the crack
#   SHOTGN  0.85 s -> 0.38 s   ditto (the pump is a separate lump we don't use)
# 2026-07-30 (chainsaw): SAWFUL is the saw's firing buzz and had to come out of
# a bank with 181 B free, so the two DOOR sounds pay for it. Both are 1.25 s
# hydraulic hisses whose character is in the first half -- and unlike a gunshot
# they play at a distance, where the tail is the least audible part.
# 2026-08-07: THE CAPS ARE GONE. Every line above is about ONE 16 KB MEMAC-B
# bank, and REGIONS has been two 64 KB Rapidus banks for a while now -- region 0
# was full (65120/65536) but region 1 sat at 16747/65536, i.e. 48 KB unused,
# and the first-fit loop below spills into it by itself. The player heard the
# difference: "the shotgun and the door sounds only play halfway" -- DOROPN and
# DORCLS were cut to 57 % of themselves and SHOTGN to 45 %.
MAX_BYTES = {}

# The MEMAC-B window maps ONE 16 KB VBXE bank at a time, so a "bank" is the hard
# unit here: a sound lives in exactly one, and snd_play maps its bank before the
# first read. Bank 0 filled up exactly (16384 B of 16384), which is why the
# monster sounds needed a second one -- 2026-07-30, out of the VRAM the flat-wall
# change freed. Both must stay 16 KB aligned: MEMAC-B has no finer granularity.
# 2026-07-30 (second pass): bank 1 started at $050000, but the death frames then
# needed the sprite slot to grow from 32 KB to 108 KB and $050000 is where it
# now starts -- so bank 1 moved into the 12 KB the sprites vacated at $071000+
# ($074000 is the 16 KB-aligned address inside it). See the VRAM map in
# memory_map.inc.
#
# 2026-07-31 -- THE SAMPLES LEFT VBXE ENTIRELY. Nothing about them ever needed
# VRAM: the Timer-1 IRQ reads them ONE BYTE AT A TIME with the CPU (snd_fetch),
# the blitter never touches them, and paying for that through the MEMAC-B window
# cost a map/read/unmap per sample plus a wait for the blitter to go idle. They
# now live in Rapidus RAM at bank $02 and the IRQ does a single 65816
# `lda.l` -- cheaper, and it hands 32 KB of VBXE VRAM back to the sprite slot,
# which is what the monsters' attack frames needed.
# The 16 KB two-bank split went with it: that was the MEMAC-B window's
# granularity, and there is no window any more.
EXT_BANK = 0x02               # Rapidus bank of REGION 0 (memory_map SND_EXT)
# 2026-08-03 -- MULTI-BANK (T5 of _navrh_vram.txt): the 60 KB cap died. Each SFX
# carries its own BANK byte now (sfx_bnk, copied into the playing voice's sv_ab
# by snd_play), so the blob spans REGIONS: whole Rapidus banks, filled first-fit.
# The one hard rule stands PER SOUND: a sample may not cross a 64 KB bank end
# (the IRQ increments only the low two operand bytes) -- guaranteed here by
# assigning each sound wholly to one region.
# Banks $03 (map segs), $04/$05 (weapon master) are taken; $07 is left free for
# the RMT music plan. 128 KB of sample room, ~2x today's whole set.
REGIONS = ((0x020000, 0x10000),      # bank $02 -- SND_EXT, region 0
           (0x060000, 0x10000))     # bank $06 -- overflow

# id order == play order in sound_tables.inc. Keep the USED ones only: every
# entry costs VRAM and boot-time SIO. (DSGETPOW is not in DOOM.WAD -- powerups
# and keys use DSITEMUP here.)
SFX = [
    ('DOROPN', 'DSDOROPN', 0),        # door starts opening      (try_use)
    ('DORCLS', 'DSDORCLS', 0),        # door starts closing      (try_use / dwell over)
    ('ITEMUP', 'DSITEMUP', 0),        # health / armor / ammo / key picked up
    ('WPNUP',  'DSWPNUP',  0),        # weapon picked up
    ('NOWAY',  'DSNOWAY',  0),        # USE pressed, nothing there
    ('PSTART', 'DSPSTART', 0),        # lift starts moving
    ('PSTOP',  'DSPSTOP',  0),        # lift back at the top
    ('SWTCHN', 'DSSWTCHN', 0),        # switch pressed / SR button pops back out
    ('TELEPT', 'DSTELEPT', 0),        # teleporter (p_telept.c, at both ends)
    ('PISTOL', 'DSPISTOL', 0),        # pistol + chaingun shot (A_FirePistol /
                                      #   A_FireCGun both S_StartSound sfx_pistol)
    ('SHOTGN', 'DSSHOTGN', 0),        # shotgun shot          (A_FireShotgun)
    ('PLASMA', 'DSPLASMA', 0),        # plasma bolt            (A_FirePlasma)
    ('SAWFUL', 'DSSAWFUL', 0),        # chainsaw firing        (A_Saw). DOOM also
                                      #   has sawup/sawidl/sawhit; one digi
                                      #   channel and 181 B of bank meant one of
                                      #   the four, and this is the one that
                                      #   plays when you pull the trigger.
    ('PLDETH', 'DSPLDETH', 0),        # A_PlayerScream: the death cry. Same bank
                                      #   as the pain grunt -- they are the same
                                      #   voice and never overlap, so if one fits
                                      #   the other does. Capped like PLPAIN is.
    ('PLPAIN', 'DSPLPAIN', 0),        # the player takes damage (P_DamageMobj ->
                                      #   S_StartSound sfx_plpain). This WAS
                                      #   DSOOF, which is the bumped-into-a-wall
                                      #   grunt and sounded wrong. DSPLPAIN is
                                      #   longer than the bank has room for, so
                                      #   it is truncated -- see MAX_BYTES.
    # --- bank 1: the monsters. Which sound belongs to which type is NOT chosen
    #     here -- info.c's painsound/deathsound is, via tools/doomstates.py, and
    #     pack_things.py turns that into the per-sprite MK_* kind byte the
    #     engine looks up. These are the lumps E1's roster actually reaches at
    #     skill 2 (POSS/SPOS/TROO/SARG, plus BOSS on E1M8).
    ('POPAIN', 'DSPOPAIN', 1),        # zombieman / shotgun guy / imp hurt
    ('DMPAIN', 'DSDMPAIN', 1),        # demon / baron hurt
    # A_Scream rolls the humanoid death cries the same way A_Look rolls the
    # sight ones: podth1..3 for the two zombies, bgdth1..2 for the imp
    # (p_enemy.c `sound = sfx_podth1 + P_Random()%3`). Consecutive ids are the
    # contract -- mk_dthn carries the variant count to en_die_snd (2026-08-04).
    ('PODTH1', 'DSPODTH1', 1),        # zombieman / shotgun guy dies (1 of 3)
    ('PODTH2', 'DSPODTH2', 1),
    ('PODTH3', 'DSPODTH3', 1),
    ('BGDTH1', 'DSBGDTH1', 1),        # imp dies (1 of 2)
    ('BGDTH2', 'DSBGDTH2', 1),
    ('SGTDTH', 'DSSGTDTH', 1),        # demon dies
    ('BRSDTH', 'DSBRSDTH', 1),        # baron dies (E1M8)
    ('BAREXP', 'DSBAREXP', 1),        # barrel explodes (A_Explode, p_enemy.c)
    # A_Look's seesound, 2026-07-31. These had nowhere to go while a 16 KB MEMAC-B
    # bank was the unit and both were full; the move to Rapidus RAM left 17 KB in
    # one run. info.c names one per type and A_Look picks at random among the
    # numbered variants -- posit1..3 for the zombieman and the shotgun guy,
    # bgsit1..2 for the imp -- which is what mk_seen carries to the engine.
    ('POSIT1', 'DSPOSIT1', 1),        # zombieman spots you (sfx_posit1..3)
    ('POSIT2', 'DSPOSIT2', 1),
    ('POSIT3', 'DSPOSIT3', 1),
    ('BGSIT1', 'DSBGSIT1', 1),        # imp   (sfx_bgsit1..2)
    ('BGSIT2', 'DSBGSIT2', 1),
    ('SGTSIT', 'DSSGTSIT', 1),        # demon / spectre
    ('CACSIT', 'DSCACSIT', 1),        # cacodemon
    ('BRSSIT', 'DSBRSSIT', 1),        # baron (E1M8)
    # A_Chase's activesound -- the patrol grunt, played on `P_Random () < 3`, so
    # roughly one RUN state in 85. info.c gives every type one; three cover all
    # of episode 1.
    ('POSACT', 'DSPOSACT', 1),        # zombieman / shotgun guy on patrol
    ('BGACT',  'DSBGACT',  1),        # imp
    ('DMACT',  'DSDMACT',  1),        # demon, cacodemon, baron, lost soul
    # The melee hit itself. p_enemy.c plays this from INSIDE the attack action,
    # not from a state: A_TroopAttack and A_BruisAttack both
    #     if (P_CheckMeleeRange (actor)) { S_StartSound (actor, sfx_claw); ... }
    # so it is the imp's scratch (and the baron's, once that kind attacks).
    # A_SargAttack has no sound of its own -- the demon's sfx_sgtatk comes from
    # A_Chase's `info->attacksound` on entering the melee state, which is a
    # different hook and a different lump.
    ('CLAW',   'DSCLAW',   1),        # imp / baron melee connects (sfx_claw)
    # --- 2026-08-04, the E1 gap fill (tools/_gap_scan.py): bank $02 ran out of
    #     room mid-list, so the tail spills into region 1 (bank $06) -- which is
    #     the whole point of the T5 multi-bank move.
    ('SGTATK', 'DSSGTATK', 1),        # demon bite connects (ai_fire, the same
                                      #   damage-then-voice slot the claw uses)
    ('PUNCH',  'DSPUNCH',  1),        # A_Punch CONNECTS (wp_fire_a + en_hit;
                                      #   a whiff is silent, like DOOM's)
    ('SLOP',   'DSSLOP',   1),        # A_XScream (p_enemy.c:1572): the GIB
                                      #   scream. p_inter.c:719 sends a corpse to
                                      #   xdeathstate instead of deathstate when
                                      #   health < -spawnhealth, and that chain
                                      #   opens with A_XScream, not A_Scream --
                                      #   a rocketed zombie does not yell the
                                      #   ordinary death cry.
    ('SAWUP',  'DSSAWUP',  1),        # P_BringUpWeapon: the saw revs on arrival
    ('SAWIDL', 'DSSAWIDL', 1),        # A_WeaponReady idle putter, WS_SAW entry
                                      #   only, and only into an EMPTY sound
                                      #   slot -- ambience must not eat events
    ('SAWHIT', 'DSSAWHIT', 1),        # A_Saw: the buzz when it BITES (en_hit)
    ('RXPLOD', 'DSRXPLOD', 1),        # the launcher's shot: launch + impact are
                                      #   the same instant here (no missile
                                      #   mobj), and the impact half is the
                                      #   informative one -- was DSBAREXP
    ('STNMOV', 'DSSTNMOV', 1),        # T_MoveFloor's grind: floors, stairs, the
                                      #   donut -- every 8th jiffy, weak-queued
                                      #   (movers.asm mv_grind)
    ('SWTCHX', 'DSSWTCHX', 1),        # the EXIT switch (p_switch.c plays it for
                                      #   specials 11/51 instead of swtchn)
    # --- STAGED, no trigger yet: the imp/baron fireball and the flying rocket
    #     are not modelled (ai_fire claws only in melee; en_rocket lands the
    #     same tic). The lumps ride along now so the missile-mobj work only has
    #     to wire ids -- and bank $06 has room for all of E2's roster besides.
    ('RLAUNC', 'DSRLAUNC', 1),        # rocket LEAVES the tube (needs flight)
    ('FIRSHT', 'DSFIRSHT', 1),        # imp/baron ball spawns (needs the ball)
    ('FIRXPL', 'DSFIRXPL', 1),        # ...and bursts (BAL1 C-E, needs the ball)
    # The INTERMISSION's three sounds are sfx_pistol (the tick as a percentage
    # counts up), sfx_barexp (a row lands) and this one -- wi_stuff.c:1416 plays
    # sgcock when the tally is done and the world map comes up. The first two
    # were already here for the gun and the barrel; this is the only lump the
    # intermission adds. APPENDED, never inserted: the id is the index in this
    # list and sound_tables.inc's ids are baked into mk_tables.inc and the weapon
    # tables, so inserting one in the middle silently renumbers every sound after
    # it. Region 1 ($060000) had 39 KB free, this is 6 KB of it.
    ('SGCOCK', 'DSSGCOCK', 1),        # wi_stuff.c: the tally is finished
    # --- 2026-08-20, the two FINAL BOSSES. info.c gives the cyberdemon and the
    #     spider mastermind sfx_dmpain and sfx_dmact, which the demon already
    #     brought, so only the sight and death cries are new -- four lumps,
    #     11.5 KB, three more 4 KB chunks. APPENDED, like every entry since the
    #     intermission's (see the note above).
    #     NOT here: sfx_hoof and sfx_metal. A_Hoof/A_Metal hang off the WALK
    #     states, and this port's walk cycle is a tics counter with no per-state
    #     action hook -- there is nowhere to play them from.
    ('CYBSIT', 'DSCYBSIT', 1),        # cyberdemon spots you  (E2M8, E3M9)
    ('CYBDTH', 'DSCYBDTH', 1),        # ...and dies
    ('SPISIT', 'DSSPISIT', 1),        # spider mastermind spots you (E3M8)
    ('SPIDTH', 'DSSPIDTH', 1),        # ...and dies
    # --- 2026-08-21, A_Hoof / A_Metal. The note above said these two "hang off
    #     the WALK states, and this port's walk cycle is a tics counter with no
    #     per-state action hook -- there is nowhere to play them from". Half of
    #     that was never true: ai_state ADVANCES TH_WST by one every mk_ctic
    #     tics and knows the index it just wrote, which is exactly the hook
    #     info.c needs (S_CYBER_RUN1 = A_Hoof, RUN7 = A_Metal; SPID_RUN1/5/9 =
    #     A_Metal). What was missing was 25 bytes in the AI block, and the
    #     65816 `stz`/`inc @`/`dec @` this port had never used freed 32.
    #     APPENDED, like every entry since the intermission's, and IN THIS
    #     ORDER: enemy_ai.asm's ai_state hook is the only reader of either.
    #     Room: region 1 sat at 38568/65536 B and these are 727 + 1439 B, which
    #     the existing 10 chunks already cover -- no new SIO, no new RAM.
    ('HOOF',   'DSHOOF',   1),        # cyberdemon's forefoot   (A_Hoof)
    ('METAL',  'DSMETAL',  1),        # ...its hind hoof, and the spider's legs
    # --- 2026-08-28, the BFG9000. ONE new lump: A_BFGsound (p_pspr.c:822) plays
    #     sfx_bfg on S_BFG1, and MT_BFG's deathsound is sfx_rxplod, which the
    #     rocket launcher already brought in. The charge-up is the whole point
    #     of it -- 20 tics of winding noise before the shot is what tells you a
    #     BFG went off -- so it is not one of the lumps that can be dropped.
    #     APPENDED, like every entry since the intermission's.
    ('BFG',    'DSBFG',    1),        # A_BFGsound: the 20-tic wind-up
]


def lump_samples(wad, name):
    """DMX lump -> (rate, [unsigned 8-bit samples]) with the 16-sample pads cut."""
    for nm, off, ln in wad.lumps:
        if nm == name:
            fmt, rate, ns = struct.unpack_from('<HHI', wad.data, off)
            if fmt != 3:
                sys.exit(f'{name}: unexpected DMX format {fmt}')
            s = list(wad.data[off + 8: off + 8 + ns])
            return rate, s[16:-16] if len(s) > 32 else s
    sys.exit(f'{name}: lump not found in the WAD')


def resample(s, in_rate, out_rate):
    """Box-average decimation. in_rate/out_rate is ~2.8, so each output sample
    averages ~3 inputs -- that low-pass is what keeps the 4-bit result clean."""
    n = max(1, int(len(s) * out_rate / in_rate))
    step = len(s) / n
    out = []
    for i in range(n):
        a = int(i * step)
        b = max(a + 1, int((i + 1) * step))
        seg = s[a:min(b, len(s))]
        out.append(sum(seg) // len(seg))
    return out


def to_nibbles(s):
    """Unsigned 8-bit -> 4-bit, peak-normalized, with ramps at both ends."""
    peak = max((abs(v - 128) for v in s), default=0)
    gain = min(MAX_GAIN, 127.0 / peak) if peak else 1.0
    n = []
    for v in s:
        w = int(round((v - 128) * gain)) + 128
        n.append(max(0, min(15, (max(0, min(255, w)) + 8) >> 4)))
    # AUDC4 sits at 0 between sounds; stepping straight to mid-scale clicks.
    for i in range(min(RAMP, len(n))):
        k = (i + 1) / (RAMP + 1)
        n[i] = int(round(n[i] * k))
        n[-1 - i] = int(round(n[-1 - i] * k))
    return n


def pack(n):
    """2 samples per byte, hi nibble first (the IRQ's phase 0)."""
    if len(n) & 1:
        n = n + [n[-1]]
    return bytes((n[i] << 4) | n[i + 1] for i in range(0, len(n), 2))


# ---- DOOM'S PER-PLAY PITCH (s_sound.c:326-345 + i_sound.c:415) --------------
# Every S_StartSound rolls the playback rate: `pitch += 16 - (M_Random()&31)`
# for everything except sfx_itemup and sfx_tink, `pitch += 8 - (M_Random()&15)`
# for the four chainsaw sounds, around NORM_PITCH = 128. i_sound.c turns that
# into the step the mixer walks the sample with,
#     steptablemid[i] = pow(2.0, (i/64.0)) * 65536
# so the rate is 2^(delta/64) -- 0.850x .. 1.189x, i.e. -2.81 .. +3.00
# semitones, and the sound comes out that much shorter or longer.
#
# The Atari does the same walk with one byte of fraction per voice: snd_irq
# adds sv_stp to sv_frc every interrupt and takes the next BYTE on the carry,
# so PITCH_ONE = 128 is "half a byte per interrupt" -- exactly the fixed rate
# the port used to play everything at.
# The table is indexed by the raw random byte's low 5 bits, i = rnd & 31, with
# delta = 16 - i: DOOM's own expression, and no arithmetic on the 6502. The
# chainsaw's narrower roll is the SAME table at i = (rnd & 15) + 8, which is
# delta = +8 .. -7, so the saw range falls out of the wide one for free.
PITCH_ONE = 128


def pitch_table():
    return [int(round(PITCH_ONE * 2.0 ** ((16 - i) / 64.0))) for i in range(32)]


def write_pitch_inc(path):
    tab = pitch_table()
    assert all(1 <= v <= 255 for v in tab), tab
    with open(path, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/wadsound.py -- DO NOT EDIT.\n')
        w('; DOOM\'s per-play pitch: s_sound.c:326-345 rolls a delta around\n')
        w('; NORM_PITCH 128, i_sound.c:415 makes it a step of 2^(delta/64).\n')
        w('; Here a step is in 1/128ths of a sample BYTE per interrupt, so\n')
        w('; SND_PITCH_ONE = {} is the rate the port used to play everything\n'
          .format(PITCH_ONE))
        w('; at. Index = rnd & 31 (delta 16-i); the chainsaw group uses\n')
        w('; (rnd & 15) + 8, which is this same table\'s delta +8..-7.\n\n')
        w('SND_PITCH_ONE equ {}\n\n'.format(PITCH_ONE))
        w('snd_pitch\n')
        for i, v in enumerate(tab):
            d = 16 - i
            w('        dta {:<3d}    ; delta {:+3d}  x{:.4f}  {:+.2f} semitones\n'
              .format(v, d, 2.0 ** (d / 64.0), 12 * d / 64.0))


def write_wav(path, data, rate):
    """Decode the packed nibbles back to 8-bit mono -- the Atari's exact output."""
    pcm = bytearray()
    for b in data:
        pcm.append((b >> 4) * 17)
        pcm.append((b & 15) * 17)
    with open(path, 'wb') as f:
        f.write(b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt ')
        f.write(struct.pack('<IHHIIHH', 16, 1, 1, rate, rate, 1, 8))
        f.write(b'data' + struct.pack('<I', len(pcm)) + bytes(pcm))


def main():
    args = sys.argv[1:]
    wad_path = DEFAULT_WAD
    rate = POKEY_RATE
    if '--wad' in args:
        wad_path = args[args.index('--wad') + 1]
    if '--rate' in args:
        rate = int(args[args.index('--rate') + 1])
    wad = Wad(wad_path)

    regions = [bytearray() for _ in REGIONS]
    rows = []                        # (name, lump, offset16, len, dur, region)
    for nm, lump, _grp in SFX:
        in_rate, s = lump_samples(wad, lump)
        nib = to_nibbles(resample(s, in_rate, rate))
        cap = MAX_BYTES.get(nm)
        if cap and len(nib) > cap * 2:
            nib = nib[:cap * 2]
            for i in range(min(RAMP * 4, len(nib))):   # fade the cut edge out
                k = (i + 1) / (RAMP * 4 + 1)
                nib[-1 - i] = int(round(nib[-1 - i] * k))
        data = pack(nib)
        for g, (base, size) in enumerate(REGIONS):     # first-fit whole region:
            if len(regions[g]) + len(data) <= size:    # a sound never crosses a
                break                                  # bank end (see REGIONS)
        else:
            sys.exit(f'{nm}: {len(data)} B fits no sound region -- add a bank '
                     f'to REGIONS (banks $03-$05 are taken, see the note)')
        rows.append((nm, lump, len(regions[g]), len(data),
                     len(data) * 2 / rate, g))
        regions[g] += data
        if '--wav' in args:
            os.makedirs(os.path.dirname(OUT_BIN), exist_ok=True)
            write_wav(os.path.join(os.path.dirname(OUT_BIN), nm.lower() + '.wav'),
                      data, rate)

    # The blob is region 0's bytes, then region 1's, each padded to whole 4 KB
    # chunks -- load_sounds streams SND_RCHn chunks into bank SND_RBKn, in order.
    blob = bytearray()
    gchunks = []
    for g, b in enumerate(regions):
        c = (len(b) + CHUNK - 1) // CHUNK
        gchunks.append(c)
        blob += b + bytes(c * CHUNK - len(b))
    chunks = sum(gchunks)

    os.makedirs(os.path.dirname(OUT_BIN), exist_ok=True)
    with open(OUT_BIN, 'wb') as f:
        f.write(blob)

    with open(OUT_INC, 'w') as f:
        w = f.write
        w('; AUTO-GENERATED by tools/wadsound.py -- DO NOT EDIT.\n')
        w(f'; {len(rows)} digitized SFX, 4-bit @ {rate} Hz, {len(blob)} B '
          f'({chunks} x 4 KB chunk(s)).\n')
        w('; sfx_lo/hi are OFFSETS inside the sound\'s own Rapidus bank and\n')
        w('; sfx_bnk IS that bank: snd_play copies all three into the chosen\n')
        w('; VOICE (sv_al/ah/ab), and snd_fetch feeds them to the one shared\n')
        w('; `lda.l`. A sound never crosses a bank end (the IRQ increments only\n')
        w('; the low two address bytes) -- REGIONS guarantees it.\n')
        w('; sfx_nlo/nhi hold the NEGATED byte count, so the IRQ ends a sound with\n')
        w('; `inc sv_rl,x / bne` instead of a 16-bit end-pointer compare.\n')
        w('; load_sounds streams SND_RCHn x 4 KB into bank SND_RBKn, in order\n')
        w('; (the blob is the regions back to back, each chunk-padded).\n\n')
        for i, (nm, lump, addr, ln, dur, grp) in enumerate(rows):
            w(f'SFX_{nm:<8s} equ {i:<3d}    ; {lump} {ln} B, {dur:.2f} s, '
              f'bank ${REGIONS[grp][0] >> 16:02X}\n')
        w(f'\nSFX_COUNT        equ {len(rows)}\n')
        w(f'SND_BLOB_BYTES   equ {len(blob)}\n')
        w(f'SND_EXT_BANK     equ ${EXT_BANK:02X}     ; region 0 (= SND_EXT)\n')
        w(f'SND_NREG         equ {len(REGIONS)}\n')
        for g, (base, _size) in enumerate(REGIONS):
            w(f'SND_RBK{g}         equ ${base >> 16:02X}     ; Rapidus bank\n')
            w(f'SND_RCH{g}         equ {gchunks[g]:<3d}    ; 4 KB chunks in the blob\n')
        w('\n')                      ; # SND_CHUNKS comes from atr_layout.inc
                                     # (make_atr_doom sizes it from the .bin)
        for tag, val in (('sfx_lo', lambda a, l, g: a & 0xFF),
                         ('sfx_hi', lambda a, l, g: a >> 8),
                         ('sfx_bnk', lambda a, l, g: REGIONS[g][0] >> 16),
                         ('sfx_nlo', lambda a, l, g: (-l) & 0xFF),
                         ('sfx_nhi', lambda a, l, g: ((-l) >> 8) & 0xFF)):
            w(tag + '\n')
            for nm, lump, addr, ln, dur, grp in rows:
                w(f'        dta ${val(addr, ln, grp):02X}    ; SFX_{nm}\n')
            w('\n')
    write_pitch_inc(OUT_PITCH)
    tot = sum(r[3] for r in rows)
    print(f'  {len(rows)} SFX, {tot} B packed -> {chunks} x 4 KB chunk(s) '
          f'({tot * 2 / rate:.1f} s of audio @ {rate} Hz)')
    for g, ((addr, size), c) in enumerate(zip(REGIONS, gchunks)):
        used = sum(r[3] for r in rows if r[5] == g)
        print(f'    Rapidus ${addr:06X}: {used} / {size} B '
              f'({c} x 4 KB chunks, {size - used} B free)')
    for nm, lump, addr, ln, dur, grp in rows:
        print(f'    SFX_{nm:<8s} {lump:<9s} b{grp} ${addr:04X}  {ln:5d} B  {dur:.2f} s')
    print(f'  wrote {os.path.relpath(OUT_BIN, _PROJ)} + '
          f'{os.path.relpath(OUT_INC, _PROJ)}')


if __name__ == '__main__':
    main()
