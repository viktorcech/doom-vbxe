#!/usr/bin/env python3
"""rmt_render -- read an RMT 1.x module and walk it the way the player does.

This is the file pack_musstream.py imports and that went missing with the rest
of the music subsystem (bsp_main.asm:1050 still claims "the file, its packer and
its two verifiers are intact" -- only the packer survived). It is rebuilt here
against two authorities that ARE in the tree:

  * mads-src/players/rmt_player_relocator/rmt_format1x.txt -- the module layout
  * mads-src/players/rmt_player_relocator/rmt_player.a65   -- the player itself,
    which is where the frequency tables and the distortion mapping below come
    from verbatim (labels frqtabpure / frqtabbass1 / frqtabbass2 and the
    tabbeganddistor table at line 126).

The API is exactly what pack_musstream.py calls:
    load_mod(path)                              -> (mod_bytes, base_address)
    load_instruments(mod, base)                 -> [(env, eloop, orn, oloop, tspd)]
        env steps are (vol, dist, cmd, xy) -- the COMMAND matters: the drum
        instruments in instruments/drums/ are built on command 1, "play the
        frequency $XY directly" (rmt_en.html), and reading only vol+dist
        renders them as ordinary notes.
    expand_track(mod, base, tlo, thi, tn, tlen) -> [row, ...]
    TABDIST[dist]                               -> (freq_table, audc_base)

A ROW is one of:
    ('n', note, instr, trkvol)   a new note
    ('v', vol)                   volume change only
    None                         silence from here
    ''                           nothing happens this row (sustain)
"""
import os
import struct
import sys

# ---- the player's own tables, transcribed from rmt_player.a65 --------------
# frqtabpure: AUDF per note 0..60 for the pure-tone distortions. Note 0 is
# AUDF $F3 -> 63337/(2*244) = 129.8 Hz, i.e. about C3 (MIDI 48), which is what
# fixes the MIDI->RMT note offset in mus2rmt.py.
FRQ_PURE = [
    0xF3, 0xE6, 0xD9, 0xCC, 0xC1, 0xB5, 0xAD, 0xA2, 0x99, 0x90, 0x88, 0x80,
    0x79, 0x72, 0x6C, 0x66, 0x60, 0x5B, 0x55, 0x51, 0x4C, 0x48, 0x44, 0x40,
    0x3C, 0x39, 0x35, 0x32, 0x2F, 0x2D, 0x2A, 0x28, 0x25, 0x23, 0x21, 0x1F,
    0x1D, 0x1C, 0x1A, 0x18, 0x17, 0x16, 0x14, 0x13, 0x12, 0x11, 0x10, 0x0F,
    0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09, 0x08, 0x07, 0x06, 0x05, 0x04, 0x03,
    0x02, 0x01, 0x00, 0x00,
]
FRQ_BASS1 = [
    0xBF, 0xB6, 0xAA, 0xA1, 0x98, 0x8F, 0x89, 0x80, 0xF2, 0xE6, 0xDA, 0xCE,
    0xBF, 0xB6, 0xAA, 0xA1, 0x98, 0x8F, 0x89, 0x80, 0x7A, 0x71, 0x6B, 0x65,
    0x5F, 0x5C, 0x56, 0x50, 0x4D, 0x47, 0x44, 0x3E, 0x3C, 0x38, 0x35, 0x32,
    0x2F, 0x2D, 0x2A, 0x28, 0x25, 0x23, 0x21, 0x1F, 0x1D, 0x1C, 0x1A, 0x18,
    0x17, 0x16, 0x14, 0x13, 0x12, 0x11, 0x10, 0x0F, 0x0E, 0x0D, 0x0C, 0x0B,
    0x0A, 0x09, 0x08, 0x07,
]
FRQ_BASS2 = [
    0xFF, 0xF1, 0xE4, 0xD8, 0xCA, 0xC0, 0xB5, 0xAB, 0xA2, 0x99, 0x8E, 0x87,
    0x7F, 0x79, 0x73, 0x70, 0x66, 0x61, 0x5A, 0x55, 0x52, 0x4B, 0x48, 0x43,
    0x3F, 0x3C, 0x39, 0x37, 0x33, 0x30, 0x2D, 0x2A, 0x28, 0x25, 0x24, 0x21,
    0x1F, 0x1E, 0x1C, 0x1B, 0x19, 0x17, 0x16, 0x15, 0x13, 0x12, 0x11, 0x10,
    0x0F, 0x0E, 0x0D, 0x0C, 0x0B, 0x0A, 0x09, 0x08, 0x07, 0x06, 0x05, 0x04,
    0x03, 0x02, 0x01, 0x00,
]

# rmt_player.a65:126 `tabbeganddistor` -- (table, AUDC distortion bits) per
# envelope distortion value 0..7. Distortion 5 is $A0, the pure tone.
TABDIST = [
    (FRQ_PURE, 0x00), (FRQ_PURE, 0x20), (FRQ_PURE, 0x40), (FRQ_BASS1, 0xC0),
    (FRQ_PURE, 0x80), (FRQ_PURE, 0xA0), (FRQ_BASS1, 0xC0), (FRQ_BASS2, 0xC0),
]
DIST_PURE = 5                      # the one mus2rmt.py writes

INSTRPAR = 12                      # bytes before an instrument's note table


# ---- the module ------------------------------------------------------------
def load_mod(path):
    """(module bytes, load address). An .rmt is a DOS binary: $FFFF, start,
    end, then the module -- the layout rmt_relocator.mac patches."""
    b = open(path, 'rb').read()
    if b[0:2] == b'\xFF\xFF':
        start, end = struct.unpack('<HH', b[2:6])
        return b[6:6 + (end - start + 1)], start
    raise ValueError('%s: no $FFFF DOS header' % path)


def header(mod):
    """(magic, tracklen, speed, freq, version, pinstr, ptlo, pthi, psong)."""
    return (mod[0:4].decode('latin-1'), mod[4] or 256, mod[5], mod[6], mod[7],
            mod[8] | (mod[9] << 8), mod[10] | (mod[11] << 8),
            mod[12] | (mod[13] << 8), mod[14] | (mod[15] << 8))


def load_instruments(mod, base):
    """[(env, eloop, orn, oloop, tspd)] -- env is [(vol, dist)], orn is a list
    of note offsets. Instrument struct per rmt_format1x.txt:
        0 tlen  1 tgo  2 elen  3 ego  4 tspd|tmode|ttype  5 audctl
        6 vslide 7 vmin 8 delay 9 vibrato 10 fshift 11 -   12.. notes, envelope
    tlen/elen/tgo/ego are offsets from the START of the instrument."""
    _, _, _, _, _, pinstr, ptlo, _, _ = header(mod)
    ti = pinstr - base
    # the instrument table runs until the first pointer table begins
    n = max(0, (ptlo - pinstr) // 2)
    out = []
    for k in range(n):
        p = mod[ti + k * 2] | (mod[ti + k * 2 + 1] << 8)
        if p == 0:
            out.append(None)
            continue
        q = p - base
        if q < 0 or q + INSTRPAR >= len(mod):
            out.append(None)
            continue
        tlen, tgo, elen, ego = mod[q], mod[q + 1], mod[q + 2], mod[q + 3]
        tspd = (mod[q + 4] & 0x3F) or 1
        orn = list(mod[q + INSTRPAR:q + tlen + 1]) or [0]
        orn = [x - 256 if x > 127 else x for x in orn]      # signed offsets
        # ENVELOPE STEP COUNT, and it is easy to get wrong by one. The player
        # (rmt_player.a65, pp1) reads three bytes at instridx, adds 3, and
        # continues while the NEW index is <= elen -- `cmp trackn_instrlen,x /
        # bcc pp2 / beq pp2`. So the last step STARTS at elen: for Epilogue's
        # instrument 0 (tlen 12, elen 31) the steps are at 13,16,...,31 = SEVEN,
        # not six. The first version of this loop stopped at 28 and silently
        # dropped every instrument's final envelope step -- which is usually the
        # quiet tail, so the damage was a note that never decayed.
        env = []
        e = q + tlen + 1
        while e <= q + elen and e + 2 < len(mod):
            vol = mod[e] & 0x0F
            dist = (mod[e + 1] >> 1) & 7
            cmd = (mod[e + 1] >> 4) & 7     # rmt_en.html, "Envelope command"
            env.append((vol, dist, cmd, mod[e + 2]))
            e += 3
        if not env:
            env = [(0, DIST_PURE, 0, 0)]
        eloop = max(0, (ego - tlen - 1) // 3)
        oloop = max(0, tgo - INSTRPAR)
        out.append((env, min(eloop, len(env) - 1), orn,
                    min(oloop, len(orn) - 1), tspd))
    return out


def expand_track(mod, base, tlo, thi, tn, tracklen):
    """One track -> exactly `tracklen` rows. TRACK struct per rmt_format1x.txt:
    a byte is volume/pause/special in bits 6-7 and a note in bits 0-5."""
    p = (mod[tlo + tn] | (mod[thi + tn] << 8)) - base
    rows = []
    while len(rows) < tracklen and 0 <= p < len(mod):
        b = mod[p]
        p += 1
        note, top = b & 0x3F, (b >> 6) & 3
        if note <= 0x3C:                       # a note: instrument + volume
            b2 = mod[p]
            p += 1
            vol = (top << 2) | (b2 & 3)
            rows.append(('n', note, b2 >> 2, min(15, vol)))
        elif note == 0x3D:                     # volume only
            b2 = mod[p]
            p += 1
            rows.append(('v', min(15, (top << 2) | (b2 & 3))))
        elif note == 0x3E:                     # pause
            n = top if top else mod[p]
            if not top:
                p += 1
            rows.extend([''] * max(1, n))
        else:                                  # 0x3F: speed / jump / end
            if top == 0:
                p += 1                         # set speed -- not per-row here
            elif top == 1:
                p += 1                         # track jump
                break
            else:
                break                          # end of track
    rows = rows[:tracklen]
    rows.extend([''] * (tracklen - len(rows)))
    return rows


def song_lines(mod, base, nch=4):
    """The SONG list: one line per set of track numbers, $FE ends it."""
    _, _, _, _, _, _, _, _, psong = header(mod)
    i = psong - base
    lines = []
    while i + nch <= len(mod) and len(lines) < 256:
        if mod[i] == 0xFE:
            break
        lines.append(list(mod[i:i + nch]))
        i += nch
    return lines


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    mod, base = load_mod(sys.argv[1])
    magic, tracklen, speed, freq, ver, pi, pl, ph, ps = header(mod)
    print('%s  base $%04X  %d B' % (magic, base, len(mod)))
    print('  tracklen %d  speed %d  player freq %d  version %d'
          % (tracklen, speed, freq, ver))
    ins = load_instruments(mod, base)
    print('  instruments %d, song lines %d'
          % (sum(1 for x in ins if x), len(song_lines(mod, base))))
    for k, e in enumerate(ins):
        if e:
            print('    instr %d: env %d steps, loop %d, orn %d, tspd %d'
                  % (k, len(e[0]), e[1], len(e[2]), e[4]))


if __name__ == '__main__':
    main()
