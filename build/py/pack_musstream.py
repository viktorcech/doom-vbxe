#!/usr/bin/env python3
"""pack_musstream -- DOOM's intermission song (D_INTER, a MUS lump) arranged for
POKEY voices 2-4 and PRE-PLAYED into the register stream music.asm sends: one
record a PAL frame, `mask, values` for $D200-$D207 (bits 0-1, voice 1, are never
set: it is the SFX mixer's), $FF = the end, the player loops there.

    python build/py/pack_musstream.py            -> build/assets/music/music.stream,
                                                 music_syms.inc, music_tabs.inc
    python build/py/pack_musstream.py --info     the PC song and the arrangement, in numbers
    python build/py/pack_musstream.py --wav      + music/music_pc_ref.wav (the MUS
                                                 on a plain synth: the notes and the
                                                 rhythm of the PC version, not its OPL
                                                 timbre) and music_atari.wav (the
                                                 stream through a POKEY model)
    python build/py/pack_musstream.py --play FILE NAME   any stream file -> music/NAME.wav

THE PC SONG (2026-10-06, read off the lump): 201 s, six parts --
    MUS 2   electric bass          D1..C#2   the riff
    MUS 0/1 two distortion guitars D2..C#3 and a fifth above: power chords,
                                             the riff an octave over the bass
    MUS 3   saw lead               F#3..F4   the melody
    MUS 4   calliope lead          A3..G#4   its second voice
    MUS 15  drums                            kick, snare, hats, toms, crash
THE ARRANGEMENT, three voices and AUDCTL = 0 (64 kHz; the mixer owns AUDCTL):
    voice 3  the bass, distortion C (RMT's "bass table 2": f = 63337/15/(N+1)),
             at the PC's own octave -- the buzz is the guitar's weight too
    voice 2  the melody when it plays (pure tone, delayed vibrato), else the
             guitar's fifth (pure tone: the bass and it make the power chord)
    voice 4  the drums, and the melody's second voice in their gaps
The frequency tables and the instrument envelopes are RASTER Music Tracker's
(RITMO-Music-Tracker-master: asm/Legacy/rmt.a65 frqtabpure / frqtabbass2,
rmt/instruments/*.rti -- bass2, pure5, pure3v, drums/bassdrum, snaredrum,
hihatclosed, hihatopen), copied here so the build does not need that tree.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))      # build/py -> the repo root
WAD = os.environ.get('DOOMWAD') or os.path.join(HERE, 'DOOM.WAD')
STREAM = os.path.join(ROOT, 'build', 'assets', 'music', 'music.stream')
SPLIT = os.path.join(ROOT, 'build', 'assets', 'music', 'music.split')
SPLIT_M = os.path.join(ROOT, 'build', 'assets', 'music', 'music_mono.split')   # the mono set
WAVDIR = os.path.join(ROOT, 'tools', 'tests', 'out')
MUSDIR = os.path.join(ROOT, 'music')                  # the songs as WAV / RMT / SAP (2026-10-15)
MUS_BANK0 = 0x84                     # the songs' first SDRAM bank (music.asm's guards):
                                     #   behind the world maps ($7C-$83) since 2026-10-06 --
                                     #   with a level's song they are past 64 KB
FPS = 1773447 / (312 * 114)          # PAL frames a second: 49.86
CLK64 = 1773447 / 28                 # POKEY's 64 kHz base clock (PAL): 63337.4 Hz
TICKS = 140                          # MUS ticks a second

# ---- RMT's tables (asm/Legacy/rmt.a65) --------------------------------------
BASS2 = bytes.fromhex(               # frqtabbass2: distortion C, index = note - C0
    'FFF1E4D8CAC0B5ABA2998E877F797370' '66615A55524B48433F3C393733302D2A'
    '282524211F1E1C1B1917161513121110' '0F0E0D0C0B0A09080706050403020100')
PURE = bytes.fromhex(                # frqtabpure: distortion A, index = note - C3
    'F3E6D9CCC1B5ADA2999088807972' '6C66' '605B55514C4844403C3935322F2D2A28'
    '2523211F1D1C1A18171614131211100F' '0E0D0C0B0A0908070605040302010000')
assert len(BASS2) == 64 and len(PURE) == 64
# ---- RMT's envelopes (rmt/instruments), a step a frame: (volume, AUDC high
#      nibble, AUDF or None = the note's own) ---------------------------------
KICK = ((15, 0x00, 0x03), (15, 0xA0, 0xD0), (15, 0xA0, 0xE0), (11, 0xA0, 0xF0), (7, 0xA0, 0xF8),
        (4, 0x00, 0x04), (3, 0x00, 0x04), (3, 0x00, 0x04))
SNARE = ((15, 0x00, 0x07), (13, 0xA0, 0x98), (12, 0xA0, 0xA8), (11, 0xA0, 0xB8), (2, 0xA0, 0xCF),
         (9, 0x80, 0x08), (8, 0x80, 0x08), (7, 0x80, 0x08), (6, 0x80, 0x08), (5, 0x80, 0x08),
         (4, 0x80, 0x08), (3, 0x80, 0x08), (2, 0x80, 0x08), (2, 0x80, 0x08), (1, 0x80, 0x08))
HATC = ((15, 0x80, 0x00), (8, 0x80, 0x01), (2, 0xA0, 0x02))
HATO = ((15, 0x80, 0x02), (11, 0x80, 0x00), (8, 0x80, 0x01), (6, 0x00, 0x00), (5, 0x00, 0x00),
        (4, 0x00, 0x00), (3, 0x00, 0x00), (2, 0x00, 0x00), (2, 0x00, 0x00), (1, 0x00, 0x00),
        (1, 0x00, 0x00))
CRASH = tuple((v, 0x80, 0x00 if i < 2 else 0x01) for i, v in enumerate(
    (15, 14, 13, 12, 11, 10, 9, 9, 8, 8, 7, 7, 6, 6, 5, 5, 4, 4, 3, 3, 3, 2, 2, 2, 1, 1, 1, 1)))
PURE5 = (8, 12, 14, 15, 12, 9, 7, 6)     # the lead's volumes, then held at the last
BASSV = (13, 15, 14, 13, 12, 11, 11, 10)  # a plucked bass2 (RMT's is a flat 15)
CHUG = (15, 13, 11, 10, 9, 8, 8, 7)      # the guitar: a pure tone, struck and damped


def tom(key):
    """a tom: the kick's pure sweep, higher by the drum (GM 41..50)"""
    f0 = 0x90 - (key - 41) * 8
    return ((15, 0x00, 0x05), (15, 0xA0, f0), (14, 0xA0, f0 + 10), (12, 0xA0, f0 + 20),
            (9, 0xA0, f0 + 30), (6, 0xA0, f0 + 38), (3, 0xA0, f0 + 44))


DRUM = {35: (KICK, 5), 36: (KICK, 5), 37: (HATC, 2), 38: (SNARE, 4), 39: (SNARE, 4), 40: (SNARE, 4),
        42: (HATC, 1), 44: (HATC, 1), 46: (HATO, 2), 49: (CRASH, 3), 51: (HATO, 2), 52: (CRASH, 3),
        53: (HATO, 2), 55: (CRASH, 3), 57: (CRASH, 3), 59: (HATO, 2)}
for _k in (41, 43, 45, 47, 48, 50):
    DRUM[_k] = (tom(_k), 4)
# the voices' loudest volume: three POKEY voices at 15 clip the mixer
VOL_BASS, VOL_LEAD, VOL_GTR, VOL_DRUM, VOL_HARM = 10, 10, 6, 11, 5
VOL_ROOT, VOL_HARM2, VOL_CYM = 7, 7, 7           # the second POKEY's three
# 2026-10-06 ("praska"): POKEY's mixer is NOT linear -- past a sum of about 8 the
# output saturates (alt-src ATAudio pokey.cpp UpdateMixTable: an exponential knee,
# then the amplifier's clamp), so loud voices squeeze each other: harshness, and
# quiet tones gone. The classic rule is a chip's four volumes add up to 32 at
# most; the two songs the ear passed peak at 30-32. A level's song is held there.
VOL_SUM = 32


VOLEV = []                           # parse_mus: (tick, channel, controller-3 volume)
EXPR, BENDS, PROG = [], [], {}       # ... expression, pitch wheel; channel -> program


def curve(events, ch, nfr, default):
    """a controller of one channel as a value a frame (the last event at or
    before the frame's tick)"""
    out, v, i = [default] * nfr, default, 0
    ev = [(t, val) for t, c, val in events if c == ch]
    for f in range(nfr):
        tick = (f + 1) * TICKS / FPS
        while i < len(ev) and ev[i][0] <= tick:
            v = ev[i][1]
            i += 1
        out[f] = v
    return out


def vol_at(ch, tick):
    v = 100
    for t, c, val in VOLEV:
        if c == ch and t <= tick:
            v = val
    return v


# ---- the lump ----------------------------------------------------------------
def lump(name, wad=WAD):
    d = open(wad, 'rb').read()
    n, off = struct.unpack('<II', d[4:12])
    for i in range(n):
        p, s, nm = struct.unpack('<II8s', d[off + i * 16:off + i * 16 + 16])
        if nm.rstrip(b'\0').decode() == name:
            return d[p:p + s]
    sys.exit(f'{name} is not in {wad}')


def parse_mus(m):
    """-> (notes, end): notes = [(start, stop, channel, key, velocity)], in ticks;
    vols = the channels' controller-3 volume"""
    if m[:4] != b'MUS\x1a':
        sys.exit('not a MUS lump')
    pos = struct.unpack('<H', m[6:8])[0]
    t, last, on, notes, vols = 0, [100] * 16, {}, [], [100] * 16
    del VOLEV[:], BENDS[:], EXPR[:]
    PROG.clear()
    while True:
        b = m[pos]
        pos += 1
        typ, ch = (b >> 4) & 7, b & 15
        if typ == 0:                                 # release
            k = m[pos] & 127
            pos += 1
            if (ch, k) in on:
                st, v = on.pop((ch, k))
                notes.append((st, t, ch, k, v))
        elif typ == 1:                               # play (bit 7: a new velocity)
            k = m[pos]
            pos += 1
            if k & 128:
                last[ch] = m[pos] & 127
                pos += 1
            k &= 127
            if (ch, k) in on:
                st, v = on.pop((ch, k))
                notes.append((st, t, ch, k, v))
            on[(ch, k)] = (t, last[ch])
        elif typ == 4:                               # controller
            if m[pos] == 3:
                vols[ch] = m[pos + 1]
                VOLEV.append((t, ch, m[pos + 1]))    # the volume over time: D_INTRO's swell
            elif m[pos] == 5:
                EXPR.append((t, ch, m[pos + 1]))     # expression: a second volume
            elif m[pos] == 0:
                PROG.setdefault(ch, m[pos + 1])      # the channel's instrument (its first)
            pos += 2
        elif typ == 6:
            break
        elif typ == 2:                               # pitch wheel: 128 = none, +-64 a semitone
            BENDS.append((t, ch, m[pos]))
            pos += 1
        else:                                        # system event
            pos += 1
        if b & 128:
            dl = 0
            while True:
                x = m[pos]
                pos += 1
                dl = dl * 128 + (x & 127)
                if not x & 128:
                    break
            t += dl
    for (ch, k), (st, v) in on.items():
        notes.append((st, t, ch, k, v))
    notes.sort()
    return notes, t, vols


# ---- the arrangement ---------------------------------------------------------
def frame_of(tick):
    return int(tick * FPS / TICKS)


def line(notes, ch, nfr, pick='last'):
    """a MUS channel as ONE voice: per frame (key, frames since its start,
    velocity) or None. Where the channel sounds two notes at once (a guitar's
    power chord) `pick` says which: 'last' the note struck last (D_INTER, whose
    chords are two channels), 'low' the root, 'high' the note over it."""
    out = [None] * nfr
    for st, en, c, k, v in notes:
        if c != ch:
            continue
        a, b = frame_of(st), max(frame_of(en), frame_of(st) + 1)
        for f in range(a, min(b, nfr)):
            o = out[f]
            if (o is None or pick == 'last' or (pick == 'low' and k < o[0])
                    or (pick == 'high' and k > o[0])):
                out[f] = (k, f - a, v)
    return out


def scale(v, top, vel):
    """an envelope step 0..15 under the voice's ceiling and the note's velocity"""
    return max(1, min(15, round(v * top / 15 * (0.55 + 0.45 * vel / 100)))) if v else 0


def bass_audf(key):
    """distortion C: the poly4 pattern repeats every 15 pulses, f = 63337/15/(N+1),
    as long as N+1 shares no factor with 15 (else the pattern is shorter: another
    pitch, or silence). RMT's frqtabbass2 where it is within 10 cents, else the
    nearest divider of that kind (its D#1 is 69 cents flat)."""
    from math import gcd, log2
    f = 440 * 2 ** ((key - 69) / 12)

    def cents(n):
        return abs(1200 * log2(CLK64 / 15 / n / f))
    rmt = BASS2[key - 12] + 1
    if gcd(rmt, 15) == 1 and cents(rmt) <= 10:
        return rmt - 1
    return min((n for n in range(2, 257) if gcd(n, 15) == 1), key=cents) - 1


def pure_audf(key):
    while key < 48:                   # below C3 the 64 kHz divider has no pure
        key += 12                     #   tone (B2 is AUDF 255.5): up an octave
    return PURE[min(key - 48, 61)]


def arrange(notes, end):
    nfr = frame_of(end) + 1
    bass, gtr, groot = line(notes, 2, nfr), line(notes, 1, nfr), line(notes, 0, nfr)
    lead, harm = line(notes, 3, nfr), line(notes, 4, nfr)
    drums, cymb = {}, {}
    for st, en, c, k, v in notes:                    # one hit a frame: the heaviest
        if c == 15 and k in DRUM:
            f = frame_of(st)
            if f not in drums or DRUM[k][1] > DRUM[drums[f][0]][1]:
                drums[f] = (k, v)
            if DRUM[k][0] in (HATC, HATO, CRASH) and (f not in cymb or DRUM[k][1] > DRUM[cymb[f][0]][1]):
                cymb[f] = (k, v)
    frames, hit, cym = [], None, None                # hit = (envelope, its frame 0, prio, vel)
    for f in range(nfr):
        r = [0] * 12                                 # AUDF2, AUDC2 .. AUDC4, twice: POKEY1, POKEY2
        n = lead[f]                                  # ---- voice 2
        if n:
            k, age, v = n
            a = pure_audf(k)
            if age >= 10:                            # pure3v: the vibrato comes late
                a = max(0, min(255, a + (0, 1, 0, -1)[(age - 10) // 2 % 4]))
            r[0], r[1] = a, 0xA0 | scale(PURE5[min(age, len(PURE5) - 1)], VOL_LEAD, v)
        elif gtr[f]:
            k, age, v = gtr[f]
            r[0], r[1] = pure_audf(k), 0xA0 | scale(CHUG[min(age, len(CHUG) - 1)], VOL_GTR, v)
        n = bass[f]                                  # ---- voice 3
        if n:
            k, age, v = n
            r[2], r[3] = bass_audf(k), 0xC0 | scale(BASSV[min(age, len(BASSV) - 1)], VOL_BASS, v)
        if f in drums:                               # ---- voice 4
            k, v = drums[f]
            env, prio = DRUM[k]
            if hit is None or prio >= hit[2] or f - hit[1] >= 4:
                hit = (env, f, prio, v)
        if hit and f - hit[1] >= len(hit[0]):
            hit = None
        if hit:
            vol, dist, audf = hit[0][f - hit[1]]
            r[4], r[5] = audf & 0xFF, dist | scale(vol, VOL_DRUM, hit[3])
        elif harm[f]:
            k, age, v = harm[f]
            r[4], r[5] = pure_audf(k), 0xA0 | scale(PURE5[min(age, len(PURE5) - 1)], VOL_HARM, v)
        # ---- the SECOND POKEY (a stereo machine): the three parts one chip has
        #      no voice for -- with them all six of the PC's sound at once
        if groot[f]:                                 # voice 2': the guitar's root, the
            k, age, v = groot[f]                     #   bass's buzz an octave up
            r[6], r[7] = bass_audf(k), 0xC0 | scale(CHUG[min(age, len(CHUG) - 1)], VOL_ROOT, v)
        if gtr[f]:                                   # voice 3': its fifth, all the time
            k, age, v = gtr[f]
            r[8], r[9] = pure_audf(k), 0xA0 | scale(CHUG[min(age, len(CHUG) - 1)], VOL_GTR, v)
        if f in cymb:                                # voice 4': the melody's second
            cym = (DRUM[cymb[f][0]][0], f, cymb[f][1])   # voice, the cymbals in its rests
        if cym and f - cym[1] >= len(cym[0]):
            cym = None
        if harm[f]:
            k, age, v = harm[f]
            r[10], r[11] = pure_audf(k), 0xA0 | scale(PURE5[min(age, len(PURE5) - 1)], VOL_HARM2, v)
        elif cym:
            vol, dist, audf = cym[0][f - cym[1]]
            r[10], r[11] = audf & 0xFF, dist | scale(vol, VOL_CYM, cym[2])
        for i in (1, 3, 5, 7, 9, 11):                # a silent voice: AUDC 0, and the
            if not r[i] & 15:                        #   AUDF it had (no byte for it)
                r[i] = 0
                r[i - 1] = frames[-1][i - 1] if frames else 0
        frames.append(r)
    return frames


TIMP = (15, 14, 12, 10, 9, 7, 6, 5, 4, 3, 2, 1)      # a timpani stroke, rung out
KICKSNARE = KICK[:5] + SNARE[5:12]                   # the two on one beat


def arrange_intro(notes, end):
    """D_INTRO, the title's seven seconds: a timpani heartbeat fading out (MUS 1),
    a kick and a snare on each of its beats and a crash on the first, and a G#
    dim7 pad (MUS 2-5: G#1 D2 B2 F3) swelling in by the channels' VOLUME over an
    organ drone (MUS 8, F0). One POKEY: the heartbeat, the drums (the crash rings
    on between them) and the pad as an arpeggio D3 F3 G#3 B3. The second one
    holds the pad's notes, the drone and the crash."""
    nfr = frame_of(end) + 26
    beats = {frame_of(st): v for st, en, c, k, v in notes if c == 1}
    crash = min((frame_of(st) for st, en, c, k, v in notes if c == 15 and k in (49, 57)), default=None)
    drone = line(notes, 8, nfr)
    pad = line(notes, 2, nfr)
    frames, beat = [], None
    for f in range(nfr):
        r = [0] * 12
        tick = f * TICKS / FPS
        if f in beats:
            beat = (f, beats[f])
        age = f - beat[0] if beat else 99
        sw = vol_at(2, tick) if pad[f] else 0        # the pad's swell, 0..127
        if sw:                                       # voice 2: the pad, arpeggiated
            r[0], r[1] = pure_audf((50, 53, 56, 59)[f // 2 % 4]), 0xA0 | scale(15, 9, sw * 100 / 127)
        if age < len(TIMP):                          # voice 3: the timpani
            r[2], r[3] = bass_audf(32), 0xC0 | scale(TIMP[age], 13, beat[1])
        ring = crash is not None and 0 <= f - crash < len(CRASH)
        if age < len(KICKSNARE):                     # voice 4: kick + snare, the crash
            vol, dist, audf = KICKSNARE[age]         #   ringing on in between
            r[4], r[5] = audf, dist | scale(vol, VOL_DRUM, beat[1])
        elif ring:
            vol, dist, audf = CRASH[f - crash]
            r[4], r[5] = audf, dist | scale(vol, 8, 100)
        if drone[f]:                                 # voice 2': the drone, else the pad's D
            r[6], r[7] = bass_audf(17), 0xC0 | scale(15, 7, drone[f][2] * vol_at(8, tick) / 127)
        elif sw:
            r[6], r[7] = bass_audf(38), 0xC0 | scale(15, 6, sw * 100 / 127)
        if sw:                                       # voice 3': its B
            r[8], r[9] = pure_audf(59), 0xA0 | scale(15, 7, sw * 100 / 127)
        if ring:                                     # voice 4': the crash, then its F
            vol, dist, audf = CRASH[f - crash]
            r[10], r[11] = audf, dist | scale(vol, 10, 100)
        elif sw:
            r[10], r[11] = pure_audf(53), 0xA0 | scale(15, 7, sw * 100 / 127)
        for i in (1, 3, 5, 7, 9, 11):
            if not r[i] & 15:
                r[i] = 0
                r[i - 1] = frames[-1][i - 1] if frames else 0
        frames.append(r)
    frames.append([0] * 12)                          # ... and silence: it plays ONCE
    return frames


# ---- a LEVEL's song, whatever its parts (2026-10-06) ---------------------------
# What the PC plays is the MUS score THROUGH the WAD's GENMIDI lump (DMX's OPL
# instruments), and both are read here:
#   * the pitch: DMX plays a note an octave over its MIDI number, and the patch
#     moves it again -- its base note offset and its operators' frequency
#     multipliers (x0.5 is common). `semis` is the sum, from the MIDI number.
#   * the loudness in time: the carrier's attack, decay, sustain level and
#     RELEASE rates. Strings, choirs and leads ring on for 0.15-0.6 s after the
#     key is up; a distortion guitar is flat and stops dead; a bass fades.
#   * the level: DMX's velocity x channel-volume curve.
BUZZERS = set(range(24, 40)) | {87}  # guitars, basses, "bass & lead": their low notes buzz
_GM, _BUZZ, _GRIT, _ENV = {}, {}, {}, {}
JOIN = False                         # arrange_level: the song just arranged has a 16-bit bass
LEVEL_GAIN = 0.5                     # a level's song under its sound effects (BOTH: they are
                                     #   one voice a chip, +-8 round the DAC's middle)


def genmidi():
    """program -> (semitones from the MIDI note, attack, decay, sustain level,
    release, sustaining) of the PC's patch"""
    if not _GM:
        from math import gcd, log2
        g = lump('GENMIDI')
        for p in range(128):
            b = g[8 + p * 36:8 + p * 36 + 36]
            mod, car = b[4:10], b[11:17]
            off = struct.unpack('<h', b[18:20])[0]
            cm, mm = (1 if m & 15 == 0 else 2 * (m & 15) for m in (car[0], mod[0]))
            _GM[p] = (12 + off + round(12 * log2(gcd(cm, mm) / 2)),
                      car[1] >> 4, car[1] & 15, car[2] >> 4, car[2] & 15, car[0] >> 5 & 1)
    return _GM


def envelope(prog, held):
    """the note's amplitude a frame, 0..1: the patch's attack, decay and sustain
    for the `held` frames the key is down, then its release until it is gone"""
    if (prog, held) not in _ENV:
        from math import log10
        _, A, D, SL, R, sus = genmidi()[prog]
        ms = 1000 / FPS
        ta = 2826 / 2 ** A if A else 1e9             # OPL2: 0..full in 2826 ms / 2^rate
        dec = 96 * 2 ** D / 39280 * ms if D else 0   # ... 96 dB in 39280 ms / 2^rate
        rel = 96 * 2 ** R / 39280 * ms if R else 0
        sl = 93 if SL == 15 else SL * 3
        out, db = [], 0.0
        for f in range(held):
            t = (f + 0.5) * ms
            if t < ta:
                out.append(t / ta)
                continue
            if db < sl:
                db = min(sl, db + dec)
            elif not sus:
                db += rel                            # a percussive patch runs on down
            out.append(10 ** (-db / 20))
        db = -20 * log10(max(out[-1], 1e-4))
        while len(out) < held + 90:                  # the key is up
            db += rel if rel else 96
            if db > 26:
                break
            out.append(10 ** (-db / 20))
        _ENV[prog, held] = out
    return _ENV[prog, held]


def loud(vel, cvol):
    """DMX's note level: velocity x channel volume through its curve (VOLMAP
    below), as an amplitude against a plain note's (velocity 100, volume 100)"""
    full = (VOLMAP[min(vel, 127)] * 2 * (VOLMAP[min(int(cvol), 127)] + 1)) >> 9
    return min(1.3, 10 ** (-(63 - full) * 0.75 / 20) / REF_LOUD)


# chocolate-doom i_oplmusic.c volume_mapping_table: DMX's MIDI volume -> OPL level.
# SetVoiceVolume: full = (map[velocity] * 2 * (map[channel volume] + 1)) >> 9, and
# the carrier is attenuated by (63 - full) * 0.75 dB.
VOLMAP = (0, 1, 3, 5, 6, 8, 10, 11, 13, 14, 16, 17, 19, 20, 22, 23,
          25, 26, 27, 29, 30, 32, 33, 34, 36, 37, 39, 41, 43, 45, 47, 49,
          50, 52, 54, 55, 57, 59, 60, 61, 63, 64, 66, 67, 68, 69, 71, 72,
          73, 74, 75, 76, 77, 79, 80, 81, 82, 83, 84, 84, 85, 86, 87, 88,
          89, 90, 91, 92, 92, 93, 94, 95, 96, 96, 97, 98, 99, 99, 100, 101,
          101, 102, 103, 103, 104, 105, 105, 106, 107, 107, 108, 109, 109, 110, 110, 111,
          112, 112, 113, 113, 114, 114, 115, 115, 116, 117, 117, 118, 118, 119, 119, 120,
          120, 121, 121, 122, 122, 123, 123, 123, 124, 124, 125, 125, 126, 126, 127, 127)
REF_LOUD = 10 ** (-(63 - ((VOLMAP[100] * 2 * (VOLMAP[100] + 1)) >> 9)) * 0.75 / 20)


def buzz_div(freq):
    """distortion C's divider for `freq` (see bass_audf)"""
    from math import gcd, log2
    key = round(freq * 16)
    if key not in _BUZZ:
        _BUZZ[key] = min((n for n in range(2, 257) if gcd(n, 15) == 1),
                         key=lambda n: abs(log2(CLK64 / 15 / n / freq))) - 1
    return _BUZZ[key]


def grit_div(freq):
    """distortion C's OTHER voice, RMT's "gritty bass" (its distortion E): a
    divider that is a multiple of 3 steps poly4 through 5 of its 15 states --
    another tone colour at clock / 5 / n, and a tone at every phase (a multiple
    of 5 has a silent one: not used). None under its lowest note, 50 Hz."""
    from math import log2
    key = round(freq * 16)
    if key not in _GRIT:
        n = min((n for n in range(3, 257, 3) if n % 5), key=lambda n: abs(log2(CLK64 / 5 / n / freq)))
        _GRIT[key] = n - 1 if abs(log2(CLK64 / 5 / n / freq)) < 1 / 24 else None
    return _GRIT[key]


def tone(prog, key, bend, vol):
    """one note on a POKEY voice -> (AUDF, AUDC), at the pitch the PC sounds it.
    Low notes have no pure tone (none under B2) and take distortion C, which has
    TWO voices (RMT: C "buzzy bass", E "gritty bass"): a GUITAR's low notes are
    the gritty one, a bass's -- and any other patch's lowest -- the buzzy one.
    2026-10-06 ("nepocujem v e1m1 tie basy od 17. sekundy"): there the PC's bass
    plays the guitars' own E2; as one buzz the three were ONE tone on POKEY."""
    f = 440 * 2 ** ((key + bend - 69) / 12)
    if 24 <= prog < 32 and key < 48 and grit_div(f) is not None:
        return grit_div(f), 0xC0 | vol
    if (prog in BUZZERS and key < 48) or f < CLK64 / 2 / 256:
        return buzz_div(f), 0xC0 | vol               # (any patch's note under B2: the
    return max(0, min(255, round(CLK64 / 2 / f) - 1)), 0xA0 | vol   # buzz has that pitch)


def arrange_level(notes, end, stats=None, who=None, mono=False):
    """ANY level's song on EIGHT voices, all four of TWO POKEYs -- RMT's stereo
    layout, tracks L1-L4 and R1-R4 (2026-10-06: six were too few, E1M3 sounds
    seven notes at once and its pad's inner notes found no voice a quarter of
    the time; while a level's song plays nothing else sounds, so the mixer's
    voice 1 is the song's too -- mus_level). A stereo machine only. Each PC
    channel has a HOME SIDE and stays there (see below): the leading part -- the
    melodic ones, mean key G3 up, before the rest, each kind by how much it plays
    -- is left, the bass (the lowest part, if the song has one) right.
      left  L1-L3   the left parts that sound       L4   the drums
      right R1      the bass, R2-R3 the right parts R4   the cymbals
    A side's parts are its channels' held roots, then the top notes of their
    chords, then the notes between, then the notes still ringing out; what finds
    no voice at home takes a free one across, and the drums' and cymbals' gaps
    take what is left. A frame is 16 registers: AUDF1, AUDC1 .. AUDC4 of POKEY1,
    then POKEY2's. Every note keeps the PC's pitch, length, loudness, envelope,
    release and bend."""
    gm = genmidi()
    nfr = frame_of(end) + 60
    mel = [n for n in notes if n[2] != 15]
    chans = sorted({n[2] for n in mel})
    prog = {c: PROG.get(c, 0) for c in chans}
    vol = {c: curve(VOLEV, c, nfr, 100) for c in chans}   # (DMX's OPL driver knows the
                                                          #   volume controller only)
    bnd = {c: curve(BENDS, c, nfr, 128) for c in chans}
    energy = {c: sum((en - st) * v for st, en, ch, k, v in mel if ch == c) for c in chans}
    meank = {c: gm[prog[c]][0] + sum((en - st) * k for st, en, ch, k, v in mel if ch == c)
             / max(1, sum(en - st for st, en, ch, k, v in mel if ch == c)) for c in chans}
    low = min(chans, key=meank.get) if chans else None
    bass = low if low is not None and meank[low] < 46 else None
    rest = [c for c in chans if c != bass]
    order = (sorted((c for c in rest if meank[c] >= 55), key=lambda c: -energy[c])
             + sorted((c for c in rest if meank[c] < 55), key=lambda c: -energy[c]))
    # EVERY NOTE and the frames it sounds: (channel, key as the PC sounds it, first
    # frame, the frame its key goes up, its loudness a frame)
    N, at = [], [[] for _ in range(nfr)]
    for st, en, c, k, v in mel:
        a, b = frame_of(st), max(frame_of(en), frame_of(st) + 1)
        amps = [amp * loud(v, vol[c][a + i])
                for i, amp in enumerate(envelope(prog[c], b - a)) if a + i < nfr]
        for i in range(len(amps)):
            at[a + i].append(len(N))
        N.append((c, k + gm[prog[c]][0], a, b, amps))
    drums, cymb = {}, {}
    for st, en, c, k, v in notes:
        if c == 15 and k in DRUM:
            f = frame_of(st)
            if f not in drums or DRUM[k][1] > DRUM[drums[f][0]][1]:
                drums[f] = (k, v)
            if DRUM[k][0] in (HATC, HATO, CRASH) and (f not in cymb or DRUM[k][1] > DRUM[cymb[f][0]][1]):
                cymb[f] = (k, v)

    # EVERY PART HAS A HOME SIDE, so nothing wanders across the stereo picture
    # when another part rests: the bass is right, the leading part left, and the
    # rest go to whichever side has played less so far (by note time x velocity).
    side, load = {}, [0, energy.get(bass, 0)]
    for c in order:
        side[c] = 0 if load[0] <= load[1] else 1
        load[side[c]] += energy[c]
    lead = order[0] if order else None
    # THE BASS IS A PURE 16-BIT TONE (2026-10-06, "nepocujem v e1m1 tie basy"): as
    # a buzz it had the guitars' colour, and at their E2 it was gone among them.
    # RMT's clean bass: the second POKEY's channels 3+4 JOINED and clocked at 1.79
    # MHz (its AUDCTL $28, mus_ac) -- a square wave at the exact pitch, on R4. Its
    # buzzing copy stays, as a part of the left side and the last in line for a
    # voice. The cymbals then share the drums' voice (`drums` has every stroke).
    # mono (2026-10-15, "v atari nemam stereo"): ONE POKEY, four voices -- every part
    # on it, the bass a buzz in line right behind the lead, the cymbals the drums'
    global JOIN
    JOIN = join = bass is not None and not mono
    if mono:
        side = {c: 0 for c in side}
        if bass is not None:
            side[bass] = 0
            order = order[:1] + [bass] + order[1:]
        cymb = {}
    if join:
        side[bass] = 0
        order = order + [bass]
        cymb = {}
    rank = {c: i for i, c in enumerate(order)}
    # VOICE 1 OF EACH CHIP COMES LAST (2026-10-06, the BOTH setting): the game's
    # sound effects are mixed into L1 and R1 while one plays, so a note lands
    # there only when the side's other voices are busy -- and a double first.
    LV, DRV = (2, 4, 0), 6                           # L2, L3, L1; the drums' L4
    RV, CYV, JV = ((10, 8), None, (12, 14)) if join else ((10, 12, 8), 14, ())
    if mono:
        RV, CYV = (), None

    # A NOTE KEEPS ITS VOICE from its first frame to the end of its release
    # (2026-10-06, "ta melodia praska ... a vypadava"): the notes used to be dealt
    # afresh every frame, and a tone that lands on another voice starts its square
    # wave again at another phase -- a click, 3,193 of them in E2M1. Now a new note
    # takes a FREE voice (home side first), and only when none is free a voice is
    # taken from a double, then from a quieter note that is ringing out; what is
    # cut short stays silent (dealt again it would click twice).
    # The bass and the leading part are DOUBLED across while a voice there is
    # free -- from the note's start to its end: the same tone in both ears is in
    # the MIDDLE, where a mix has its bass and its melody.
    own = {}                                         # voice -> (note, True = its double)
    ride = {}                                        # note -> the voice it is in unison with
    dead = set()                                     # notes cut short
    frames, hit, cym = [], None, None
    for f in range(nfr):
        r = [0] * 16
        live = {}                                    # note -> ((AUDF, AUDC), key down, loudness)
        for n in at[f]:
            c, k, a, b, amps = N[n]
            amp = amps[f - a]                        # (a note the PC still sounds, -28 dB
            v = min(15, max(round(((11 if mono else 7) if c == bass else 10 if c == lead else 9) * amp),
                            amp >= 0.04))
            if v and n not in dead:                  #   up, is never rounded away)
                live[n] = (tone(prog[c], k, (bnd[c][f] - 128) / 64, v), f < b, amp)
        if join:                                     # the bass itself: its lowest held note,
            bn = [(f < N[n][3], N[n][1], N[n][4][f - N[n][2]]) for n in at[f] if N[n][0] == bass]
            down = [x for x in bn if x[0]]           #   or the loudest one ringing out
            _, k, amp = min(down, key=lambda x: x[1]) if down else max(
                bn, key=lambda x: x[2], default=(0, 0, 0))
            v = min(15, max(round(13 * amp), amp >= 0.04))
            if v:
                d = div16(k, (bnd[bass][f] - 128) / 64)
                r[12], r[14], r[15] = d & 0xFF, d >> 8, 0xA0 | v

        def cut(i):
            """voice i is taken from whoever has it; a NOTE cut short goes silent
            for good, its double with it"""
            n, dbl = own.pop(i)
            if not dbl:
                dead.add(n)
                live.pop(n, None)
                for j in [j for j, o in own.items() if o[0] == n]:
                    del own[j]
                    r[j + 1] = 0

        if f in drums:                               # the drums and the cymbals first: L4
            k, v = drums[f]                          #   and R4 are theirs while they sound
            env, prio = DRUM[k]
            if hit is None or prio >= hit[2] or f - hit[1] >= 4:
                hit = (env, f, prio, v)
        if hit and f - hit[1] >= len(hit[0]):
            hit = None
        if hit:
            if DRV in own:
                cut(DRV)
            dv, dist, audf = hit[0][f - hit[1]]
            r[DRV], r[DRV + 1] = audf & 0xFF, dist | scale(dv, VOL_DRUM, hit[3])
        if f in cymb:
            cym = (DRUM[cymb[f][0]][0], f, cymb[f][1])
        if cym and f - cym[1] >= len(cym[0]):
            cym = None
        if cym:
            if CYV in own:
                cut(CYV)
            dv, dist, audf = cym[0][f - cym[1]]
            r[CYV], r[CYV + 1] = audf & 0xFF, dist | scale(dv, VOL_CYM, cym[2])

        for i, (n, dbl) in list(own.items()):        # the notes that go on, and their
            if n in live:                            #   doubles, stay where they are
                r[i], r[i + 1] = live[n][0]
            else:
                del own[i]
        has = {n for n, dbl in own.values() if not dbl}

        def twin(chip, t, skip=None):
            """the voice of `chip` that sounds tone t already, or None"""
            return next((j for j in range(chip, chip + 8, 2)
                         if j != skip and j not in JV and r[j + 1] & 15
                         and r[j] == t[0] and not (r[j + 1] ^ t[1]) & 0xE0), None)

        def merge(j, t):
            """ONE DIVIDER TWICE ON A CHIP is not two notes -- the two square waves
            sit at whatever phase their counters happen to have, anything from
            twice the tone to none at all. Two notes in unison are ONE voice at
            their joint loudness (powers add)."""
            r[j + 1] = (r[j + 1] & 0xE0) | min(15, round(((r[j + 1] & 15) ** 2 + (t[1] & 15) ** 2) ** 0.5))

        for n, j in list(ride.items()):              # still in unison with its voice?
            if n in live and j in own and twin(j & 8, live[n][0]) == j:
                merge(j, live[n][0])
            else:
                del ride[n]

        held = {}
        for n, (t, down, amp) in live.items():
            if down:
                held.setdefault(N[n][0], []).append(N[n][1])

        def kind(n):
            """0 its channel's root, 1 its top note, 2 a note between, 3 ringing out"""
            if not live[n][1]:
                return 3
            ks = held[N[n][0]]
            return 0 if N[n][1] == min(ks) else 1 if N[n][1] == max(ks) else 2

        def double(n):
            c, t = N[n][0], live[n][0]
            j = next((j for j in sorted(RV if side[c] == 0 else LV, key=lambda j: j & 7 != 0)
                      if j not in own and twin(j & 8, t) is None), None)
            if j is not None:
                own[j] = (n, True)
                r[j], r[j + 1] = t

        new = []
        for n in sorted((n for n in live if n not in has and n not in ride),
                        key=lambda n: (kind(n), rank[N[n][0]], -live[n][2])):
            if n not in live:                        # (cut in this very pass)
                continue
            c, (t, down, amp) = N[n][0], live[n]
            home, away = (LV, RV) if side[c] == 0 else (RV, LV)
            # STRUCK AGAIN while the same tone still rings out: the new note takes
            # that note's voice over, and its double's -- the same string, no gap
            # in either ear (a bass repeating one note did this 793 times in E1M3)
            j = next((j for j in (twin(home[0] & 8, t), twin((away or home)[0] & 8, t))
                      if j is not None and j in own and not live[own[j][0]][1]), None)
            if j is not None and down:
                m = own[j][0]
                for i, o in list(own.items()):
                    if o[0] == m:
                        own[i] = (n, o[1])
                        r[i], r[i + 1] = t
                dead.add(m)
                del live[m]
                if c == lead and not any(o == (n, True) for o in own.values()):
                    double(n)
                continue
            i = next((i for i in home + away if i not in own and twin(i & 8, t) is None), None)
            if i is None:
                j = next((j for j in (twin(home[0] & 8, t), twin((away or home)[0] & 8, t))
                          if j is not None and j in own), None)
                if j is not None:                    # in unison with a voice: see merge
                    ride[n] = j
                    merge(j, t)
                    continue
                if not down:                         # a note already ringing out takes
                    continue                         #   no one's voice
                groups = ([i for i, (m, dbl) in own.items() if dbl],
                          sorted((i for i, (m, dbl) in own.items()
                                  if not dbl and not live[m][1] and live[m][2] < amp),
                                 key=lambda i: live[own[i][0]][2]),
                          [i for i in (DRV, CYV) if i is not None and i not in own
                           and not r[i + 1] & 15])
                i = next((i for g in groups for i in sorted(g, key=lambda i: i & 8 != home[0] & 8)
                          if twin(i & 8, t, i) is None), None)
                if i is None:
                    continue                         # no voice: it waits for one
                if i in own:
                    cut(i)
            own[i] = (n, False)
            r[i], r[i + 1] = t
            new.append(n)
        for n in new:
            if N[n][0] == lead and live.get(n, (0, 0))[1]:
                double(n)

        untwin(r, join)                              # (two bends, or a drum, can still meet)
        for chip, pv, perc in ((0, DRV, hit), (8, 14, cym)):    # VOL_SUM: the notes of a chip
            vs = [i for i in range(chip, chip + 8, 2)           #   give way together, the
                  if r[i + 1] & 15 and not (perc and i == pv)]  #   drum stroke keeps its own
            room = VOL_SUM - (r[pv + 1] & 15 if perc else 0)
            tot = sum(r[i + 1] & 15 for i in vs)
            if tot > room:
                for i in vs:
                    r[i + 1] = (r[i + 1] & 0xF0) | max(1, (r[i + 1] & 15) * room // tot)
        if stats is not None:                        # every note the PC sounds this frame:
            for n in at[f]:                          #   (frame, channel, key, amplitude,
                c, k, a, b, amps = N[n]              #    held, does a voice sound its tone)
                af, ac = tone(prog[c], k, (bnd[c][f] - 128) / 64, 1)
                stats.append((f, c, k, amps[f - a], f < b, any(
                    r[j] == af and r[j + 1] & 15 and not (r[j + 1] ^ ac) & 0xE0
                    for j in range(0, 16, 2) if j not in JV) or bool(
                    join and c == bass and r[15] & 15
                    and r[12] | r[14] << 8 == div16(k, (bnd[c][f] - 128) / 64))))
        if who is not None:                          # whose each of the eight voices is this
            w = [None] * 8                           #   frame: a PC channel, 15 = the drums,
            for i, (n, dbl) in own.items():          #   'bass16' = the joined pair
                w[i // 2] = N[n][0]
            if hit:
                w[DRV // 2] = 15
            if cym:
                w[CYV // 2] = 15
            if join and r[15] & 15:
                w[6] = w[7] = 'bass16'
            who.append(w)
        for i in range(1, 16, 2):                    # (a silent voice keeps its divider: no
            if not r[i] & 15 and not (i == 13 and join and r[15] & 15):   # byte in the stream;
                r[i] = 0                             #   R3 is the sounding bass's low byte)
                r[i - 1] = frames[-1][i - 1] if frames else 0
        frames.append(r)
    while len(frames) > frame_of(end) + 1 and not any(v & 15 for v in frames[-1][1::2]):
        frames.pop()                                 # (the last notes' release, no more)
    for r in frames:                                 # 2026-10-15 ("hudba je moc nahlas,
        for i in range(1, 16, 2):                    #   nepocut ked strielam z pistole"):
            if r[i] & 15:                            #   the whole song at LEVEL_GAIN, a
                r[i] = (r[i] & 0xF0) | max(1, round((r[i] & 15) * LEVEL_GAIN))   # note stays
    return frames


def div16(key, bend):
    """the divider of a pure tone on two JOINED channels clocked at 1.79 MHz
    (AUDCTL $28, channels 3+4): low byte AUDF3, high byte AUDF4, the tone on
    channel 4 at clock / 2 / (divider + 7) -- alt-src ATAudio pokey.cpp
    RecomputeTimerPeriod. Exact at any pitch: RMT's clean bass."""
    return max(0, min(0xFFFF, round(1773447 / 2 / (440 * 2 ** ((key + bend - 69) / 12))) - 7))


def twins(frames, join=False):
    """frames in which two voices of ONE chip sound the same tone (divider and
    distortion alike): on POKEY that is one tone at an accidental phase -- double
    or gone -- never two notes (2026-10-06, see arrange_level's merge). join: the
    second chip's 3+4 are one 16-bit voice (div16), no part of this."""
    n = 0
    for r in frames:
        for chip in (0, 8):
            v = [(r[chip + i], r[chip + i + 1] & 0xE0) for i in ((0, 2) if join and chip else (0, 2, 4, 6))
                 if r[chip + i + 1] & 15 and r[chip + i + 1] & 0xE0 in (0xA0, 0xC0, 0xE0)]
            if len(set(v)) < len(v):
                n += 1
                break
    return n


def untwin(r, join=False):
    """a frame's twins (see twins) -> ONE voice each, at their joint loudness
    (powers add); the other voice of the pair is silent for the frame"""
    for chip in (0, 8):
        top = chip + (4 if join and chip else 8)
        for a in range(chip, top - 2, 2):
            for b in range(a + 2, top, 2):
                da, db = r[a + 1] & 0xE0, r[b + 1] & 0xE0
                va, vb = r[a + 1] & 15, r[b + 1] & 15
                if va and vb and r[a] == r[b] and da == db and da in (0xA0, 0xC0, 0xE0):
                    r[a + 1] = da | min(15, round((va * va + vb * vb) ** 0.5))
                    r[b + 1] = 0
    return r


def level_roles():
    """the PC synth's voice for each channel of the song just parsed"""
    def kind(p):
        return ('bass' if 32 <= p < 40 else 'gtr' if 24 <= p < 32 else 'lead' if 80 <= p < 88
                else 'organ' if 16 <= p < 24 else 'strings' if 40 <= p < 56 or 88 <= p < 96
                else 'calliope')
    return {c: kind(p) for c, p in PROG.items()}


def pack(frames, end=0xFF, join=False, one=False):
    """a frame = POKEY1's record, then POKEY2's: `mask, values`, bit i = the
    chip's register i (AUDF1, AUDC1 .. AUDF4, AUDC4) changes -- and the player
    writes ONLY those (mus_play). A song starts on AUDCs of 0 (mus_reset stops
    what played) and AUDFs that are anyone's: frame 0 carries every AUDF. A song
    that never sounds voice 1 (the title's, the stats screen's) never names its
    registers: they are the SFX mixer's there. POKEY1's mask is the frame's
    FIRST byte, and $FF there ends the song (loop), $FE stops it (a song DOOM
    plays once) -- so when all of AUDC1..AUDC4's seven bits would be set, ONE
    VOLUME WAITS A FRAME, the one that moves least (`frames` is changed).
    one: a mono set's song -- POKEY2 is never named, frame 0 too (2026-10-15)."""
    out, shadow = bytearray(), [None, 0] * 8
    if one:
        shadow[8:] = [0] * 8
    if not any(r[i] for r in frames for i in (0, 1, 8, 9)):
        shadow[0] = shadow[8] = 0
    for r in frames:
        if all(shadow[i] != r[i] for i in range(1, 8)):
            new = list(r)                            # (... and that makes no twin: the
            for i in sorted((1, 3, 5, 7), key=lambda i: (      # old volume on a new tone)
                    bool((shadow[i] ^ new[i]) & 0xE0), abs((shadow[i] & 15) - (new[i] & 15)))):
                r[:] = new
                r[i] = shadow[i]
                if not twins([r], join):
                    break
        for chip in (0, 8):
            mask, vals = 0, []
            for i in range(8):
                if shadow[chip + i] != r[chip + i]:
                    mask |= 1 << i
                    vals.append(r[chip + i])
            out.append(mask)
            out += bytes(vals)
        shadow = r
    out.append(end)
    return bytes(out)


def split(song):
    """a song's stream bytes (pack) the way the DISK carries them (2026-10-06,
    "lepsia kompresia hudby"): the records' masks as one run, then for each of
    the 16 registers the run of ITS values alone -- the same bytes, sorted, and
    DEFLATE packs them 28 % smaller (a register's envelopes and notes repeat;
    woven into the frames they do not). music.asm mus_join weaves them back at
    boot. A block:  frames (word) | the end mark | 16 run lengths (words) |
    the masks, two a frame | run 0 .. run 15."""
    masks, runs, pos, n = bytearray(), [bytearray() for _ in range(16)], 0, 0
    while song[pos] < 0xFE:
        for chip in (0, 8):
            mask = song[pos]
            masks.append(mask)
            pos += 1
            for i in range(8):
                if mask >> i & 1:
                    runs[chip + i].append(song[pos])
                    pos += 1
        n += 1
    block = (struct.pack('<HB', n, song[pos]) + b''.join(struct.pack('<H', len(r)) for r in runs)
             + bytes(masks) + b''.join(bytes(r) for r in runs))
    if pos + 1 != len(song) or len(block) > 0xFFFF or n > 0x7FFF:
        sys.exit('split: a song past 64 KB, or bytes behind its end mark')
    return block


def weave(blocks):
    """mus_join in Python: the split blocks -> the stream (the check of split)"""
    out, b = bytearray(), 0
    while True:
        n = struct.unpack_from('<H', blocks, b)[0]
        if not n:
            return bytes(out)
        endm, cur, o = blocks[b + 2], [], 35 + 2 * n
        for i in range(16):
            cur.append(o)
            o += struct.unpack_from('<H', blocks, b + 3 + 2 * i)[0]
        for f in range(n):
            for chip in (0, 8):
                mask = blocks[b + 35 + 2 * f + chip // 8]
                out.append(mask)
                for i in range(8):
                    if mask >> i & 1:
                        out.append(blocks[b + cur[chip + i]])
                        cur[chip + i] += 1
        out.append(endm)
        b += o


def unpack(data, pos=0):
    """one song's frames (16 registers each), from `pos`"""
    shadow, frames = [0] * 16, []
    while data[pos] < 0xFE:
        for chip in (0, 8):
            mask = data[pos]
            pos += 1
            for i in range(8):
                if mask >> i & 1:
                    shadow[chip + i] = data[pos]
                    pos += 1
        frames.append(list(shadow))
    return frames


SONGS = ['D_INTER', 'D_INTRO'] + [f'D_E{e}M{m}' for e in (1, 2, 3) for m in range(1, 10)]


def built():
    """the songs as the build has them: name -> (frames, the second POKEY's 3+4
    are joined), out of music.stream by music_tabs.inc's rows"""
    import re
    t = open(os.path.join(ROOT, 'music_tabs.inc')).read()
    col = [re.findall(r'[$\w+]+', t.split(k + '\n')[1].split('\n')[0].replace('dta', ''))
           for k in ('mus_b0', 'mus_b1', 'mus_b2', 'mus_ac')]
    data, out = open(STREAM, 'rb').read(), {}
    for i, nm in enumerate(SONGS):
        hi = int(col[2][i].split('+')[1]) if '+' in col[2][i] else 0
        out[nm] = (unpack(data, int(col[0][i][1:], 16) | int(col[1][i][1:], 16) << 8 | hi << 16),
                   col[3][i] != '$00')
    return out


# ---- the POKEY model (four voices, AUDCTL 0) ----------------------------------
def lfsr(bits, tap):
    n, reg, out = (1 << bits) - 1, (1 << bits) - 1, []
    for _ in range(n):
        out.append(reg & 1)
        reg = (reg >> 1) | (((reg ^ (reg >> tap)) & 1) << (bits - 1))
    return out


def pokey_mix(frames, chip, rate, join=False):
    """one POKEY's four voices (frames[..][chip..chip+7]) -> samples at `rate`,
    mixed as the chip mixes them (2026-10-06, alt-src ATAudio pokey.cpp
    UpdateMixTable): the volume bits' own uneven weights, and the sum through
    the output's saturation curve -- a plain sum sounded cleaner than the game.
    join: AUDCTL $28, channels 3+4 one 16-bit voice at 1.79 MHz (div16)"""
    import numpy as np
    wt = np.array([sum(w for b, w in enumerate((0.12, 0.26, 0.56, 1.12)) if v >> b & 1) / 8.24
                   for v in range(16)], dtype=np.float32)
    p4, p5, p17 = (np.array(lfsr(b, t), dtype=np.int8) for b, t in ((4, 1), (5, 2), (17, 5)))
    per = CLK64 / FPS
    total = int(len(frames) * per) + 1
    mix = np.zeros(total, dtype=np.float32)
    for ch in range(4):
        if join and ch == 2:                         # (the 16-bit voice's low half: no
            continue                                 #   sound of its own, its AUDC is 0)
        cnt, lvl = 1, 0                              # ticks to the next pulse, the flip-flop
        for f, r in enumerate(frames):
            a, b = int(f * per), int((f + 1) * per)
            n, period, audc = b - a, r[chip + 2 * ch] + 1, r[chip + 2 * ch + 1]
            if join and ch == 3:                     # in 64 kHz ticks, a fraction and all
                period = ((r[chip + 4] | r[chip + 6] << 8) + 7) / 28
            vol, dist = audc & 15, audc & 0xE0
            t = np.arange(cnt, n, period)            # this frame's pulses
            cnt = cnt - n if not len(t) else t[-1] + period - n
            t = np.floor(t).astype(np.int64)
            if not len(t):
                if vol:
                    mix[a:b] += wt[vol] * lvl
                continue
            m = (a + t).astype(np.int64) * 28        # machine cycles: the polys' clock
            if dist in (0xA0, 0xE0):
                lv = (lvl + 1 + np.arange(len(t))) & 1
            elif dist == 0xC0:
                lv = p4[m % 15]
            elif dist == 0x80:
                lv = p17[m % 131071]
            else:                                    # the poly5 gate first
                gate = p5[m % 31].astype(bool)
                src = p17[m % 131071] if dist == 0x00 else p4[m % 15] if dist == 0x40 else None
                lv, cur, tog = np.empty(len(t), dtype=np.int8), lvl, lvl
                for i in range(len(t)):
                    if gate[i]:
                        cur = int(src[i]) if src is not None else cur ^ 1
                    lv[i] = cur
            seg = np.diff(np.concatenate(([0], t, [n])))
            wave = np.repeat(np.concatenate(([lvl], lv)), seg)
            lvl = int(lv[-1])
            if vol:
                mix[a:b] += wt[vol] * wave[:n]
    mix = np.where(mix < 0.14, mix, 0.14 + (1 - np.exp(-2.85 * (mix - 0.14))) / 2.85) * 2.1
    mix -= mix.mean()
    cs = np.concatenate(([0.0], np.cumsum(mix, dtype=np.float64)))
    edges = np.arange(0, total, CLK64 / rate)        # box-filter down to `rate`
    return np.diff(np.interp(edges, np.arange(total + 1), cs)) / (CLK64 / rate) * 0.9


def pokey_wav(frames, path, stereo=False, rate=44100, join=False):
    """the stream as a mono machine plays it (POKEY1 alone), or left = POKEY1,
    right = POKEY2 as the $D210 stereo board wires them"""
    import numpy as np
    left = pokey_mix(frames, 0, rate)                # four voices at 15 = full scale
    save_wav(path, np.stack([left, pokey_mix(frames, 8, rate, join)], axis=1) if stereo else left,
             rate)


def save_wav(path, x, rate):
    import wave
    import numpy as np
    os.makedirs(os.path.dirname(path), exist_ok=True)
    pcm = (np.clip(x, -1, 1) * 32767).astype('<i2').tobytes()
    with wave.open(path, 'wb') as w:
        w.setnchannels(x.shape[1] if x.ndim == 2 else 1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)


# ---- the PC song on a plain synth: what it plays, not how OPL sounds ---------
INTER_ROLES = {2: 'bass', 0: 'gtr', 1: 'gtr', 3: 'lead', 4: 'calliope'}
INTRO_ROLES = {0: 'timp', 1: 'timp', 6: 'timp', 2: 'strings', 3: 'strings', 4: 'strings',
               5: 'strings', 7: 'strings', 8: 'organ', 9: 'organ', 10: 'organ'}


def pc_wav(notes, end, vols, path, roles=INTER_ROLES, rate=44100):
    import numpy as np
    rng = np.random.default_rng(1)
    buf = np.zeros(int((end / TICKS + 2) * rate), dtype=np.float32)

    def saw(f, t, harm):
        return sum(np.sin(2 * np.pi * f * h * t) / h for h in range(1, harm + 1) if f * h < rate / 2)

    def chvol(ch, st, n):                            # the channel's volume while the note sounds
        pts = [(t, val) for t, c, val in VOLEV if c == ch] or [(0, 100)]
        i = np.searchsorted([p[0] for p in pts], st + np.arange(n) / rate * TICKS, side='right') - 1
        return np.array([p[1] for p in pts], dtype=np.float32)[np.clip(i, 0, None)] / 127

    for st, en, ch, k, v in notes:
        a = int(st / TICKS * rate)
        g = v / 127 * vols[ch] / 127
        if ch == 15:
            n = int(rate * (1.2 if k in (49, 52, 55, 57) else 0.35))
            t = np.arange(n) / rate
            nz = rng.standard_normal(n).astype(np.float32)
            if k in (35, 36):
                x = np.sin(2 * np.pi * (50 * t + 100 / 30 * (1 - np.exp(-30 * t)))) * np.exp(-12 * t) * 1.6
            elif k in (38, 39, 40):
                x = nz * np.exp(-18 * t) * 0.7 + np.sin(2 * np.pi * 180 * t) * np.exp(-25 * t) * 0.5
            elif k in (41, 43, 45, 47, 48, 50):
                f0 = 80 + (k - 41) * 12
                x = np.sin(2 * np.pi * (f0 * t + f0 / 20 * (1 - np.exp(-20 * t)))) * np.exp(-9 * t)
            elif k in (49, 52, 55, 57):
                x = np.diff(nz, prepend=0) * np.exp(-4 * t) * 0.4
            elif k in (46, 51, 53, 59):
                x = np.diff(nz, prepend=0) * np.exp(-12 * t) * 0.35
            else:
                x = np.diff(nz, prepend=0) * np.exp(-70 * t) * 0.35
            buf[a:a + n] += (x * g).astype(np.float32)[:len(buf) - a]
            continue
        n = max(int((en - st) / TICKS * rate), 1) + int(0.03 * rate)
        t = np.arange(n) / rate
        f = 440 * 2 ** ((k - 69) / 12)
        rel = np.minimum(1, (n - np.arange(n)) / (0.03 * rate))
        kind = roles.get(ch, 'calliope')
        if kind == 'bass':
            x = saw(f, t, 8) * (0.5 + 0.5 * np.exp(-6 * t)) * 0.8
        elif kind == 'gtr':
            x = np.tanh(3 * saw(f, t, 14)) * (0.6 + 0.4 * np.exp(-5 * t)) * 0.45
        elif kind == 'lead':
            x = saw(f, t + 0.0001 * (1 - np.cos(2 * np.pi * 5.5 * t)), 12) * 0.45   # a slow vibrato
        elif kind in ('timp', 'strings', 'organ'):   # (D_INTRO's: a swell is the channel's
            if f < 20:                               #   volume moving under a held note)
                continue
            if kind == 'timp':
                n = int(0.5 * rate)
                t = np.arange(n) / rate
                rel = 1
                x = np.sin(2 * np.pi * f * (t + 0.02 * (1 - np.exp(-20 * t)))) * np.exp(-6 * t) * 1.2
            elif kind == 'strings':
                x = saw(f, t, 8) * 0.3
            else:
                x = (np.sin(2 * np.pi * f * t) + 0.6 * np.sin(4 * np.pi * f * t)
                     + 0.4 * np.sin(8 * np.pi * f * t)) * 0.5
            g = v / 127 * chvol(ch, st, n)
        else:
            x = (np.sin(2 * np.pi * f * t) + 0.3 * np.sin(4 * np.pi * f * t)) * 0.4
        buf[a:a + n] += (x * rel * np.minimum(1, t / 0.004) * g).astype(np.float32)[:len(buf) - a]
    save_wav(path, buf / max(1e-9, float(np.abs(buf).max())) * 0.9, rate)


NAMES = 'C C# D D# E F F# G G# A A# B'.split()


def nname(k):
    return f'{NAMES[k % 12]}{k // 12 - 1}'


def info(notes, end, frames, data):
    from collections import Counter
    print(f'D_INTER: {end} ticks = {end / TICKS:.1f} s, {len(notes)} notes')
    for ch in sorted({n[2] for n in notes}):
        ks = Counter(n[3] for n in notes if n[2] == ch)
        top = ', '.join(f'{nname(k) if ch != 15 else k} x{c}' for k, c in ks.most_common(6))
        print(f'  MUS {ch:2}: {sum(ks.values()):4} notes, {nname(min(ks))}..{nname(max(ks))}: {top}')
    on = [sum(1 for r in frames if r[2 * i + 1] & 15) * 100 // len(frames)
          for i in (1, 2, 3, 5, 6, 7)]
    print(f'the stream: {len(frames)} frames ({len(frames) / FPS:.1f} s), {len(data)} bytes; '
          f'voices 2/3/4 sound in {on[0]} / {on[1]} / {on[2]} % of the frames, '
          f"the second POKEY's in {on[3]} / {on[4]} / {on[5]} %")
    cents = []
    for st, en, ch, k, v in notes:                   # how far off the tables are
        if ch in (1, 3, 4):
            kk = k
            while kk < 48:
                kk += 12
            cents.append(abs(1200 * __import__('math').log2(
                CLK64 / 2 / (PURE[min(kk - 48, 61)] + 1) / (440 * 2 ** ((kk - 69) / 12)))))
        elif ch == 2:
            cents.append(abs(1200 * __import__('math').log2(
                CLK64 / 15 / (bass_audf(k) + 1) / (440 * 2 ** ((k - 69) / 12)))))
    print(f'pitch error of the notes played: mean {sum(cents) / len(cents):.0f} cents, '
          f'worst {max(cents):.0f}')


def stems(name):
    """--stems NAME (2026-10-06, "urob mi vsetky nastroje ako wav a ja ti poviem
    ktory v hre nepocut"): the song's parts ONE AT A TIME, each on the very voices
    it has in the game -- a PC channel's notes, the drums, and the bass's two
    halves apart (its pure 16-bit voice on the right chip, its buzzing copy)."""
    notes, end, _ = parse_mus(lump(name))
    who = []
    frames = arrange_level(notes, end, who=who)
    kinds = level_roles()
    parts = {}
    for w in who:
        for x in w:
            if x is not None and x not in parts:
                parts[x] = ('drums' if x == 15 else 'bass_pure16_right' if x == 'bass16' else
                            f'ch{x}_{kinds.get(x, "part")}' + ('_buzz_copy' if JOIN and kinds.get(x) == 'bass' else ''))
    for x, label in sorted(parts.items(), key=lambda kv: kv[1]):
        fr = [[r[i] if i % 2 == 0 or w[i // 2] == x else 0 for i in range(16)]
              for r, w in zip(frames, who)]
        path = os.path.join(MUSDIR, f'music_{name[2:].lower()}_only_{label}.wav')
        pokey_wav(fr, path, stereo=True, join=JOIN)
        on = sum(1 for r in fr if any(v & 15 for v in r[1::2])) / FPS
        print(f'  {os.path.relpath(path, ROOT)}  (sounds for {on:.0f} s)', flush=True)


def main():
    args = sys.argv[1:]
    if '--stems' in args:
        return stems(args[args.index('--stems') + 1].upper())
    if '--mono' in args:                             # 2026-10-15: the songs for ONE POKEY,
        for name in SONGS:                           #   as WAVs only -- the stream is not touched
            notes, end, _ = parse_mus(lump(name))
            wav = 'music' if name == 'D_INTER' else 'music_' + name[2:].lower()
            if name in ('D_INTER', 'D_INTRO'):       # (their first chip IS their mono arrangement)
                frames = (arrange if name == 'D_INTER' else arrange_intro)(notes, end)
                frames = [[0, 0] + list(r[:6]) + [0] * 8 for r in frames]
            else:
                frames = arrange_level(notes, end, mono=True)
            pokey_wav(frames, os.path.join(MUSDIR, wav + '_mono.wav'))
            print(f'{name}: music/{wav}_mono.wav', flush=True)
        return
    if '--play' in args:                             # a stream's first song -> a wav
        i = args.index('--play')
        fr = unpack(open(args[i + 1], 'rb').read())
        pokey_wav(fr, os.path.join(MUSDIR, args[i + 2] + '.wav'), stereo=True)
        print(f'{args[i + 1]} -> music/{args[i + 2]}.wav')
        return
    # song 0 = D_INTER (the intermission, looped), song 1 = D_INTRO (the title,
    # ONCE: d_main.c starts it with looping off) -- music_syms.inc's indices
    # songs 2.. = the LEVELS' (looped), in the ATR's level order E1M1..E3M9: song
    #   MUS_LEVEL0 + current_level, played when the setting is music
    #   (mus_vm, the mixer's top voice while a song plays: snd_vmax -- 0 = one SFX
    #    voice, the song has voices 2-4)
    songs = [('D_INTER', arrange, 0xFF, INTER_ROLES, 'music'),
             ('D_INTRO', arrange_intro, 0xFE, INTRO_ROLES, 'music_intro')]
    songs += [(f'D_E{e}M{m}', arrange_level, 0xFF, None, f'music_e{e}m{m}')
              for e in (1, 2, 3) for m in range(1, 10)]
    wavs = (set(args[args.index('--songs') + 1].upper().split(',')) if '--songs' in args
            else {'D_INTER', 'D_INTRO', 'D_E1M1'})
    if 'ALL' in wavs:
        wavs = {s[0] for s in songs}
    rate = int(args[args.index('--rate') + 1]) if '--rate' in args else 44100
    lite = '--lite' in args          # the PC song and the stereo stream only
    global JOIN
    data, offs, vm, ac = bytearray(), [], [0] * len(songs), []
    stored = {}                                      # a lump's bytes -> its song's index
    blocks = bytearray()                             # the songs as the disk has them (split)
    for name, arr, endm, roles, wav in songs:
        notes, end, vols = parse_mus(lump(name))
        JOIN = False                                 # (arrange_level says: a 16-bit bass)
        frames = arr(notes, end)
        join = JOIN
        if arr is not arrange_level:                 # 2026-10-06: the two hand-arranged
            # songs keep their frames AS THEY ARE (the ear passed them; joining
            # their unisons crackled) and their six voices -- 2-4 of each chip,
            # voice 1 is the SFX mixer's while they play -- in the 16 registers
            frames = [[0, 0] + list(r[:6]) + [0, 0] + list(r[6:]) for r in frames]
        roles = roles or level_roles()
        twin_of = stored.get(lump(name))             # 2026-10-06: the WAD has six songs
        if twin_of is not None:                      #   twice (E2M9 = E3M1 ...): ONE copy
            offs.append(offs[twin_of])               #   in the stream, two rows in the tables
            ac.append(ac[twin_of])
            frames = unpack(bytes(data), offs[-1])   # (as pack left them)
            print(f'{name}: the same lump as {songs[twin_of][0]} -- its frames, at ${offs[-1]:05X}')
        else:
            stored[lump(name)] = len(offs)
            offs.append(len(data))
            ac.append(0x28 if join else 0)
            data += pack(frames, endm, join)
            blocks += split(data[offs[-1]:])
        if unpack(bytes(data), offs[-1]) != frames:
            sys.exit(f'{name}: the stream does not unpack to its frames')
        if '--info' in args and name == 'D_INTER':
            info(notes, end, frames, data)
        if arr is arrange_level and twins(frames, join):
            sys.exit(f'{name}: {twins(frames, join)} frames with one tone on two voices of a chip')
        print(f'{name}: {len(frames)} frames ({len(frames) / FPS:.1f} s), at ${offs[-1]:05X}')
        if '--wav' in args and name in wavs:
            if not lite:
                pc_wav(notes, end, vols, os.path.join(MUSDIR, wav + '_pc_ref.wav'), roles, rate)
                pokey_wav(frames, os.path.join(MUSDIR, wav + '_atari_mono.wav'), rate=rate)
            pokey_wav(frames, os.path.join(MUSDIR, wav + '_atari_stereo.wav'), stereo=True,
                      rate=rate, join=join)
            print(f'  music/{wav}_atari_stereo.wav', flush=True)
    if '--info' in args or '--nowrite' in args:      # (--nowrite: the WAVs only)
        return
    # THE MONO SET (2026-10-15, "v atari nemam stereo"): the same songs for ONE
    # POKEY, which load_music loads instead on a mono machine -- a level's on its
    # four voices (arrange_level mono), the two hand-arranged songs their first
    # chip. POKEY2's records are empty (pack one=True: not even frame 0's AUDFs),
    # as on one chip $D21x IS $D20x -- mus_cont and snd_irqb's sweep write POKEY2
    # first for that, so POKEY1's values are the ones the chip keeps.
    mdata, moffs, mstored, mblocks = bytearray(), [], {}, bytearray()
    for name, arr, endm, roles, wav in songs:
        notes, end, _ = parse_mus(lump(name))
        twin_of = mstored.get(lump(name))
        if twin_of is not None:
            moffs.append(moffs[twin_of])
            continue
        if arr is arrange_level:
            fr = [r[:8] for r in arrange_level(notes, end, mono=True)]
        else:
            fr = [[0, 0] + list(r[:6]) for r in arr(notes, end)]
        fr = [r + [0] * 8 for r in fr]
        if arr is arrange_level and twins(fr):
            sys.exit(f'{name} (mono): {twins(fr)} frames with one tone on two voices')
        mstored[lump(name)] = len(moffs)
        moffs.append(len(mdata))
        mdata += pack(fr, endm, one=True)
        mblocks += split(mdata[moffs[-1]:])
        if unpack(bytes(mdata), moffs[-1]) != fr:
            sys.exit(f'{name} (mono): the stream does not unpack to its frames')
        print(f'{name} (mono): {len(fr)} frames, at ${moffs[-1]:05X}')
    mblocks += bytes(2)
    if weave(bytes(mblocks)) != bytes(mdata):
        sys.exit('the split mono songs do not weave back into the stream')
    if len(mdata) > len(data):
        sys.exit('the mono songs outgrew the stereo ones: MUS_CHUNKS is the stereo size')
    # ... and behind its last block (the 0 that ends mus_join's walk) the mono
    # set's five song tables, mus_b0..mus_ac's layout: load_music copies them
    # from the depacked split over the stereo ones -- no resident byte for them
    mtab = (bytes(o & 255 for o in moffs) + bytes(o >> 8 & 255 for o in moffs)
            + bytes(MUS_BANK0 + (o >> 16) for o in moffs) + bytes(vm) + bytes(len(moffs)))
    blocks += bytes(2)                               # (0 frames: no more songs)
    if weave(bytes(blocks)) != bytes(data):
        sys.exit('the split songs do not weave back into the stream')
    os.makedirs(os.path.dirname(STREAM), exist_ok=True)
    open(STREAM, 'wb').write(data)                   # what the SDRAM holds, the player's
    open(SPLIT, 'wb').write(blocks)                  # ... and what the disk carries
    open(SPLIT_M, 'wb').write(mblocks + mtab)        # the mono set's (on the disk only)
    with open(os.path.join(ROOT, 'music_syms.inc'), 'w', newline='\n') as f:
        f.write('; AUTO-GENERATED by build/py/pack_musstream.py -- do not edit.\n'
                '; The songs as POKEY register streams in Rapidus SDRAM.\n'
                '; load_music brings them in once at boot; mus_play feeds one\n'
                '; frame of them to both POKEYs per VBLANK. MUS_INTER is the\n'
                '; intermission (looped), MUS_INTRO the title (once).\n'
                f'MUS_BANK0    equ ${MUS_BANK0:02X}\nMUS_COUNT    equ {len(offs)}\n'
                f'MUS_BYTES    equ {len(data)}\nMUS_SPLIT    equ {max(len(blocks), len(mblocks) + len(mtab))}'
                '    ; the disk\'s split form, depacked (mus_join): the larger set\n'
                f'MUSM_TAB     equ {len(mblocks)}    ; the mono split\'s five song tables, from MUS_TMP\n'
                'MUS_INTER    equ 0\nMUS_INTRO    equ 1\n'
                'MUS_LEVEL0   equ 2    ; + current_level = that level\'s song (E1M1..E3M9)\n')
    with open(os.path.join(ROOT, 'music_tabs.inc'), 'w', newline='\n') as f:
        f.write("; Each song's 24-bit address in Rapidus SDRAM, as an offset into the stream\n"
                '; load_music depacks at MUS_BANK0 (music_syms.inc): mus_reset loads mus_p\n'
                '; from these by song index.\n'
                'mus_b0\n        dta ' + ', '.join(f'${o & 255:02X}' for o in offs) + '\n'
                'mus_b1\n        dta ' + ', '.join(f'${o >> 8 & 255:02X}' for o in offs) + '\n'
                'mus_b2\n        dta ' + ', '.join(f'MUS_BANK0+{o >> 16}' for o in offs) + '\n'
                '; snd_vmax while the song plays: 0 = the mixer keeps voice 1 (the song has\n'
                '; voices 2-4), 2 = it keeps voices 1-2 (a level: the song has 3-4)\n'
                'mus_vm\n        dta ' + ', '.join(str(v) for v in vm) + '\n'
                '; the SECOND POKEY\'s AUDCTL while the song plays: $28 = its channels 3+4\n'
                '; joined and clocked at 1.79 MHz -- the bass, a pure 16-bit tone\n'
                'mus_ac\n        dta ' + ', '.join(f'${v:02X}' for v in ac) + '\n')
    print(f'music.stream: {len(data)} bytes')


if __name__ == '__main__':
    main()
