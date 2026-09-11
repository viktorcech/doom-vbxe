#!/usr/bin/env python3
"""mus2rmt -- a DOOM MUS lump -> an RMT 1.x module the tracker can open.

The chain this completes:

    DOOM.WAD  --mus2rmt-->  .rmt  --rmt_render-->  POKEY frames
                             |                          |
                      Raster Music Tracker      pack_musstream.py
                      (hand-tune it here)       -> music.stream -> ATR

RMT is the AUTHORING format, not a runtime one. The player itself is 1178 B
(measured off mads-src/players/rmt_player_relocator/example/_rmt_player_demo.obx
-- segments $3182, $3200, $3300) and the port's biggest contiguous free block is
173 B, so it could only live in the MENU_RUN overlay window ($1000-$14FF), which
the intermission screen's own overlay already owns. pack_musstream.py's header
settled this from the start: "the player runs HERE instead, once, at build time".

VOICE ASSIGNMENT is dictated by pack_musstream.py, which maps RMT voices to
POKEY channels as VOICE_CHANNEL = {0: 1, 2: 2, 3: 3} -- voice 1 is DROPPED
("Voice 1 (harmony) is the one that goes") because POKEY channel 1 is the digi
mixer's Timer-1 divisor. So this writes:

    voice 0 -> lead   (the highest sounding note)
    voice 1 -> unused, left empty on purpose
    voice 2 -> bass   (the lowest)
    voice 3 -> inner  (whatever is left, nearest the lead)

NOTE RANGE. rmt_render.FRQ_PURE[0] is AUDF $F3 = 129.8 Hz, about C3, so RMT note
0 is MIDI 48 and the module spans MIDI 48..108. MUS notes below that are lifted
by octaves rather than dropped -- with AUDCTL pinned at 0 for the digi mixer
there is no 16-bit channel to put them on, and the count is reported.

  python tools/mus2rmt.py D_INTER
  python tools/mus2rmt.py D_INTER --speed 2 --tracklen 64 --seconds 45
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import rmt_render as R                                        # noqa: E402
from mus2pokey import parse_mus, wad_lump                     # noqa: E402

ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, 'bench')

BASE = 0x4000                     # module load address (the example's)
NOTE0_MIDI = 48                   # FRQ_PURE[0] ~ 129.8 Hz ~ C3
NOTE_MAX = 60                     # RMT notes are $00-$3C
MUS_TICK_HZ = 140.0
PLAYER_HZ = 50                    # PAL frame rate -- used for TIMING only
ENGINE_SPEED = 1                  # module byte 6. rmt_format1x.txt calls it
                                  #   "player freq" and that name is a trap: the
                                  #   manual (rmt_en.html, INFO EDIT) says it is
                                  #   "Engine speed, from $1 to $8 (X player
                                  #   calls per frame)". Every module in the
                                  #   tree -- music.rmt, ilusia.rmt, mlaticka.rmt
                                  #   -- carries 1. Writing 50 here is out of
                                  #   range and RMT will not play the module.
PERC_CHAN = 15
EMPTY = 0xFF                      # song list: no track on this voice


def midi_to_rmt(note):
    """RMT note + how many octaves it had to be lifted to be playable."""
    lifts = 0
    n = note - NOTE0_MIDI
    while n < 0:
        n += 12
        lifts += 1
    while n > NOTE_MAX:
        n -= 12
    return n, lifts



# ---- the shipped instrument library ---------------------------------------
# instruments/*.rti. A .rti is 'RTI', a version byte, a 32-char name, then a
# length byte at 37 and the data at 38. For VERSION 1 that data IS the in-module
# instrument struct, so it drops straight into the module with no translation --
# which is what makes instruments/drums/ usable here. The 29 version-0 files
# (pure*.rti, bass*.rti, curious/) use a different layout whose envelope starts
# at offset 16 instead of tlen+1; they are not read, and the pure-tone shape
# taken from pure5.rti is transcribed into instrument() instead.
RTI_DIR = os.path.join(ROOT, 'instruments')


def load_rti(name):
    b = open(os.path.join(RTI_DIR, name), 'rb').read()
    assert b[0:3] == b'RTI', name
    assert b[3] == 1, '%s is .rti version %d -- only 1 is the module struct' % (
        name, b[3])
    return b[38:38 + b[37]]


# GM percussion -> the four drums in instruments/drums/. MUS channel 15 is the
# percussion channel and its "note" is the instrument, not a pitch.
DRUMS = [
    ('drums/bassdrum.rti',    (35, 36, 41, 43, 45, 47, 48, 50)),
    ('drums/snaredrum.rti',   (37, 38, 39, 40)),
    ('drums/hihatclosed.rti', (42, 44, 54, 56, 58, 60, 61, 62, 63, 64)),
    ('drums/hihatopen.rti',   (46, 49, 51, 52, 53, 55, 57, 59)),
]
DRUM_NOTE = 24                    # what pitch to strike a drum at; command-1
                                  # envelope steps ignore it, the tail steps
                                  # that fall back to command 0 do not


def drum_slot(note):
    for k, (_f, notes) in enumerate(DRUMS):
        if note in notes:
            return k
    return 2                      # anything unmapped ticks as a closed hihat


def score_rows(ev, rows_hz, seconds=None):
    """Walk the MUS score and snapshot which notes sound on each RMT row."""
    active, chvol = {}, {c: 127 for c in range(16)}
    rows, st = [], {'perc': 0, 'max_active': 0}
    ticks_per_row = MUS_TICK_HZ / rows_hz
    i, tick_f = 0, 0.0
    hit = [None]                  # the drum struck on the row being built
    last = ev[-1][0] if ev else 0
    limit = int(seconds * rows_hz) if seconds else None
    while True:
        tick_f += ticks_per_row
        tick = int(tick_f)
        while i < len(ev) and ev[i][0] <= tick:
            t, kind, ch, a, b = ev[i]
            i += 1
            if ch == PERC_CHAN:
                if kind == 'on':
                    st['perc'] += 1
                    hit[0] = drum_slot(a)     # the row's drum, if any
                continue
            if kind == 'on':
                active[(ch, a)] = b if b is not None else chvol[ch]
            elif kind == 'off':
                active.pop((ch, a), None)
            elif kind == 'vol':
                chvol[ch] = a
                for k in list(active):
                    if k[0] == ch:
                        active[k] = a
        st['max_active'] = max(st['max_active'], len(active))
        rows.append((dict(active), hit[0]))
        hit[0] = None
        if limit and len(rows) >= limit:
            break
        if not limit and i >= len(ev) and tick > last:
            break
    return rows, st


def pick_voices(snap, drum):
    """One row -> what each of the four RMT voices plays.

    Three channels have to carry a score that runs to ten simultaneous notes,
    and the answer every richer module in ex/ uses is the ORNAMENT: a note table
    that steps once per frame and adds semitones to the base note, so one
    channel arpeggiates a chord (Sonic 3 Special Stage has 45 instruments with
    one, Sieur Goupil 19). So:

        voice 0 -> LEAD, the top line, plain
        voice 1 -> nothing; pack_musstream drops it (POKEY ch1 is the digi timer)
        voice 2 -> BASS, the bottom line, plain
        voice 3 -> a DRUM if percussion struck this row, else the rest of the
                   harmony as an arpeggiated chord

    Percussion used to be thrown away entirely -- 1682 note-ons on D_INTER.
    Giving it voice 3 costs the chord only on the rows a drum actually lands.

    Each cell is (note, volume, kind); kind is ('plain',), ('drum', slot) or
    ('chord', intervals).
    """
    if drum is not None:
        third = (DRUM_NOTE, 110, ('drum', drum))
    else:
        third = None
    if not snap:
        return [None, None, None, third]
    notes = sorted(snap.items(), key=lambda kv: kv[0][1])       # by pitch
    lead = (notes[-1][0][1], notes[-1][1], ('plain',))
    bass = (notes[0][0][1], notes[0][1], ('plain',)) if len(notes) > 1 else None
    if third is None and len(notes) > 2:
        mid = [n for (_c, n), _v in notes[1:-1]]
        root = mid[0]
        iv = []
        for n in mid[1:]:
            d = (n - root) % 24
            if d and d not in iv:
                iv.append(d)
            if len(iv) == 2:
                break
        vol = notes[1][1]
        third = (root, vol, ('chord', tuple(iv)) if iv else ('plain',))
    return [lead, None, bass, third]


def build_tracks(voice_rows, tracklen):
    """Rows -> (track bytes list, song column). Identical tracks are shared."""
    uniq, order, col = {}, [], []
    for s in range(0, len(voice_rows), tracklen):
        chunk = voice_rows[s:s + tracklen]
        chunk += [None] * (tracklen - len(chunk))
        data, prev_vol, cur = bytearray(), None, None
        pause = 0

        def flush_pause():
            nonlocal pause
            while pause > 0:
                n = min(pause, 255)
                if n <= 3:
                    data.append(0x3E | (n << 6))
                    pause -= n
                else:
                    data.append(0x3E)
                    data.append(n)
                    pause -= n

        for cell in chunk:
            if cell is None:
                if cur is not None:                 # silence: volume 0
                    flush_pause()
                    data.append(0x3D)               # volume-only row, vol 0
                    data.append(0x00)
                    cur, prev_vol = None, 0
                else:
                    pause += 1
                continue
            note, vol, ins = cell
            v = max(1, min(15, vol * 15 // 127))
            if cur == (note, ins) and prev_vol == v:
                pause += 1
                continue
            flush_pause()
            if cur == (note, ins):                   # same note, new volume
                data.append(0x3D | ((v >> 2) << 6))
                data.append(v & 3)
            else:
                data.append(note | ((v >> 2) << 6))
                data.append((ins << 2) | (v & 3))
            cur, prev_vol = (note, ins), v
        data.append(0xFF)                            # end of track
        key = bytes(data)
        if key not in uniq:
            uniq[key] = len(order)
            order.append(key)
        col.append(uniq[key])
    return order, col


def instrument(orn=(0,)):
    """One pure-tone instrument, ENVELOPE + optional ORNAMENT.

    ENVELOPE. The first version was a single step at full volume held forever --
    an organ drone, which is why the first render did not sound like anything.
    The shape is instruments/pure5.rti, which ships in this repo: volumes
    8,C,E,F,C,9,7,6 at distortion $0A (pure tone), looping the last step so a
    held note keeps sounding.

    ORNAMENT (the note table) is how three POKEY channels play more than three
    notes, and every richer module in ex/ does it -- Sonic 3 Special Stage has
    45 instruments with one, Sieur Goupil 19:

        orn=[0, 12, 7, 7, 0]             root + octave + fifth
        orn=[0, 12, 4, 4, 0]             root + octave + major third
        orn=[0, 0, 7, 7, 3, 3, 0, 0, 0]  a minor chord
        orn=[0, 12, 0]                   octave doubling

    The table steps once per frame (tspd 1) and adds its value to the base note,
    so ONE channel arpeggiates a whole chord. Values are signed semitones.

    LAYOUT, verified against "22 - Epilogue.rmt" instrument 0 and the player
    (rmt_player.a65): the note table starts at INSTRPAR=12 and `tlen` is the
    index of its LAST byte; the envelope starts at tlen+1, three bytes per step,
    and `elen` is the index where the LAST step STARTS, not one past it. `ego` is
    where the envelope jumps back to when it runs out. A one-entry table is
    inert -- the player skips it (`cpy #INSTRPAR+1 / bcc`), which is exactly what
    the plain lead/bass instrument wants.

    AUDCTL STAYS 0. Every real instrument in the tree sets it -- Epilogue's
    clarinet uses $51 (15 kHz + join 1+2 + 1.79 MHz ch1) -- and none of it is
    available here: sound.asm's Timer-1 digi mixer requires AUDCTL = 0, which is
    also why the bass is octave-lifted instead of put on a 16-bit channel.
    """
    ENV = [0x8, 0xC, 0xE, 0xF, 0xC, 0x9, 0x7, 0x6]   # instruments/pure5.rti
    INSTRPAR = R.INSTRPAR                            # 12
    orn = list(orn) or [0]
    tlen = INSTRPAR + len(orn) - 1
    elen = tlen + 1 + (len(ENV) - 1) * 3             # where the LAST step starts
    b = bytearray(12)
    b[0] = tlen
    b[1] = INSTRPAR                 # tgo: the table loops as a whole
    b[2] = elen
    b[3] = elen                     # ego: hold the final volume
    b[4] = 1                        # tspd = 1 -- one table step per frame
    b[5] = 0                        # audctl: see above, MUST stay 0
    b[6] = 0                        # vslide: the decay is explicit in the
                                    #   envelope, because pack_musstream.py's
                                    #   renderer does not model the slide
    b[7] = 0                        # vmin
    for v in orn:
        b.append(v & 0xFF)          # signed semitone offsets
    for v in ENV:
        b.append(v | (v << 4))      # volume, both stereo halves
        b.append(R.DIST_PURE << 1)  # distortion 5 -> AUDC $A0, pure tone
        b.append(0)                 # XY (command 0 = play the base note)
    return bytes(b)


def write_rmt(path, tracks, song, tracklen, speed, song_name='DOOM',
              instrs=None):
    instrs = instrs or [instrument()]
    ni, nt, nl = len(instrs), len(tracks), len(song)
    p_instr = BASE + 16
    p_tlo = p_instr + ni * 2
    p_thi = p_tlo + nt
    p_song = p_thi + nt
    p_ibody = p_song + nl * 4 + 4          # +4 for the $FE terminator line
    p_tbody = p_ibody + sum(len(x) for x in instrs)

    out = bytearray()
    out += b'RMT4'
    out.append(tracklen & 0xFF)
    out.append(speed)
    out.append(ENGINE_SPEED)
    out.append(1)
    out += struct.pack('<HHHH', p_instr, p_tlo, p_thi, p_song)
    off = p_ibody
    for x in instrs:
        out += struct.pack('<H', off)
        off += len(x)
    lo, hi, body, off = bytearray(), bytearray(), bytearray(), p_tbody
    for t in tracks:
        lo.append(off & 0xFF)
        hi.append((off >> 8) & 0xFF)
        body += t
        off += len(t)
    out += lo + hi
    for line in song:
        out += bytes(line)
    out += bytes([0xFE, 0, 0, 0])                          # end of song list
    for x in instrs:
        out += x
    out += body

    # A real .rmt is a MULTI-segment Atari DOS binary. "22 - Epilogue.rmt" in
    # the repo root is the reference: segment 1 is the module, segment 2 is a
    # NAME BLOCK -- the song name, then one name per instrument, each NUL
    # terminated (13 instruments there, 14 strings, 209 B). RMT writes it on
    # every save, so a file without it is not shaped like anything the tracker
    # produced. It costs nothing, so emit it.
    names = (song_name.encode('latin-1') + b'\x00'
             + b'\x00'.join([b'DOOM pure tone'] * ni) + b'\x00')
    n_start = BASE + len(out)

    with open(path, 'wb') as f:
        f.write(b'\xFF\xFF')
        f.write(struct.pack('<HH', BASE, BASE + len(out) - 1))
        f.write(out)
        f.write(struct.pack('<HH', n_start, n_start + len(names) - 1))
        f.write(names)
    return len(out)


def main():
    name = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') \
        else 'D_INTER'

    def opt(flag, d, cast=int):
        return cast(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else d
    speed = opt('--speed', 2)
    tracklen = opt('--tracklen', 64)
    seconds = opt('--seconds', None, float)

    lump = wad_lump(name)
    if lump is None:
        sys.exit('no lump %s' % name)
    ev = parse_mus(lump)
    rows_hz = PLAYER_HZ / speed
    rows, st = score_rows(ev, rows_hz, seconds)

    picked = [pick_voices(snap, drum) for snap, drum in rows]

    # ---- the instrument table ------------------------------------------
    # 0            the plain pure tone (lead and bass)
    # 1..4         the four drums, straight out of instruments/drums/*.rti
    # 5..          one per distinct chord shape, as an ORNAMENT
    # RMT allows $00-$3F, so the chord shapes are capped and the rest fall
    # back to a plain note on the chord root.
    instrs = [instrument()]
    drum_ix = {}
    for k, (fn, _notes) in enumerate(DRUMS):
        drum_ix[k] = len(instrs)
        instrs.append(load_rti(fn))
    chord_ix, MAXI = {}, 0x3F
    for cells in picked:
        c = cells[3]
        if c and c[2][0] == 'chord' and c[2][1] not in chord_ix:
            if len(instrs) >= MAXI:
                continue
            iv = c[2][1]
            # doubled steps, the way Sieur Goupil's chords are written:
            # [0,0,i1,i1,i2,i2] reads as a chord rather than a trill
            orn = [0, 0]
            for x in iv:
                orn += [x, x]
            chord_ix[iv] = len(instrs)
            instrs.append(instrument(orn))

    def ins_of(kind):
        if kind[0] == 'drum':
            return drum_ix[kind[1]]
        if kind[0] == 'chord':
            return chord_ix.get(kind[1], 0)
        return 0

    lifts = 0
    voices = []
    for v in range(4):
        col = []
        for p in picked:
            cell = p[v]
            if cell is None:
                col.append(None)
            else:
                n, lf = midi_to_rmt(cell[0])
                lifts += 1 if lf else 0
                col.append((n, cell[1], ins_of(cell[2])))
        voices.append(col)

    tracks, cols = [], []
    for v in range(4):
        if v == 1:                               # the sacrificed voice
            cols.append(None)
            tracks.append(None)
            continue
        t, c = build_tracks(voices[v], tracklen)
        tracks.append(t)
        cols.append(c)

    # one shared track pool, renumbered
    pool, colmap = [], [None] * 4
    for v in range(4):
        if tracks[v] is None:
            continue
        remap = {}
        for k, t in enumerate(tracks[v]):
            if t not in pool:
                pool.append(t)
            remap[k] = pool.index(t)
        colmap[v] = [remap[x] for x in cols[v]]

    nlines = max(len(c) for c in colmap if c)
    song = []
    for i in range(nlines):
        line = []
        for v in range(4):
            c = colmap[v]
            line.append(c[i] if c and i < len(c) else EMPTY)
        song.append(line)

    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + '.rmt')
    n = write_rmt(path, pool, song, tracklen, speed,
                  '%s - DOOM (id Software) via mus2rmt' % name,
                  instrs)

    secs = len(rows) / rows_hz
    print('%s: %d events -> %d rows at %.1f rows/s = %.1f s'
          % (name, len(ev), len(rows), rows_hz, secs))
    print('  %d tracks of %d rows, %d song lines, speed %d'
          % (len(pool), tracklen, len(song), speed))
    print('  %d instruments: 1 plain + %d drums + %d chord ornaments'
          % (len(instrs), len(DRUMS), len(chord_ix)))
    print('  module %d B  -> %s' % (n, path))
    print('  max notes sounding at once: %d (3 voices used)' % st['max_active'])
    print('  rows needing an octave lift: %d of %d' % (lifts, len(rows) * 3))
    print('  percussion note-ons PLAYED: %d' % st['perc'])


if __name__ == '__main__':
    main()
