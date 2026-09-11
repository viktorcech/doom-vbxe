#!/usr/bin/env python3
"""mus2pokey -- a DOOM MUS lump -> the port's POKEY register stream.

WHY NOT RMT. The music was wired up on 2026-08-08 and taken out the same day:
"the RMT renderings did not sound right" (sound.asm:742). That was a verdict on
the RMT route, not on music -- and the route had a second problem anyway, which
pack_musstream.py's own header spells out: the RMT player needs ~1.4 KB of
bank-0 RAM the port does not have, and cannot run from a Rapidus bank because a
65816 hardware interrupt in EMULATION mode pushes no program bank, so RTI comes
back in bank 0. So this goes straight from the IWAD's own MUS lump to the
register stream and never involves RMT at all.

THE OUTPUT FORMAT is pack_musstream.py's, unchanged, because make_atr_doom.py
already reads it (build/assets/music/music.stream -> SDRAM $550000, MUS_SEC1 /
MUS_CHUNKS in atr_layout.inc):

    per frame:  mask byte -- bit n set = register $D200+n changed this frame
                values    -- one byte per set bit, low bit first
    a mask of 0 is one byte: nothing changed this frame

THE THREE HARD CONSTRAINTS, all from that same header and kept here:
  * AUDCTL is never written -- it must stay 0 for the Timer-1 digi mixer.
  * POKEY channel 1 ($D200/$D201) is never written: AUDF1 is the divisor the
    digi IRQ clocks itself with, and while that IRQ is enabled channel 1 cannot
    be deferred, so a note there multiplies POKEY's event rate.
  * The music therefore gets $D202-$D207 -- THREE voices, not four.

WHAT THAT COSTS MUSICALLY, and what this does about it:
  * 3 voices. DOOM's MUS is up to 16 channels, so notes are dropped: the three
    HIGHEST sounding notes win (melody survives; inner harmony is what goes).
  * AUDCTL=0 means every channel is 8-bit off the 64 kHz clock, so
        AUDF = 63337 / (2*f) - 1,  AUDF <= 255
    puts a floor at 63337/512 = 123.7 Hz, just under B2. Anything lower is
    transposed UP in octaves until it fits, which is audible on bass lines and
    is reported per song as "octave lifts".
  * MUS channel 15 is percussion. POKEY can only do it as noise, and a noise
    voice would cost one of the three. Dropped -- counted in the report.

  python tools/mus2pokey.py D_INTER            # -> bench/D_INTER.stream + .wav
  python tools/mus2pokey.py D_INTER --seconds 30
  python tools/mus2pokey.py --list

Outputs land in bench/ ON PURPOSE, not in build/assets/music/: dropping a
music.stream into the build tree makes the next make_atr_doom allocate
MUS_CHUNKS sectors for a stream nothing in the ASM loads yet (music.asm and
mus_play are both gone -- see bsp_main.asm:1050). Move it over when the four
hooks go back in.
"""
import os
import struct
import sys
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WAD = os.path.join(ROOT, 'tools', 'DOOM.WAD')
OUT = os.path.join(ROOT, 'bench')

# POKEY, PAL: the 64 kHz base wadsound.py already pins down.
POKEY_BASE = 1773447 // 28              # 63337 Hz
FRAME_HZ = 50.0                         # PAL frame -- one stream record each
MUS_TICK_HZ = 140.0                     # DMX MUS score tick
NVOICE = 3                              # $D202-$D207
AUDC_TONE = 0xA0                        # pure tone distortion, volume in 0-3
PERC_CHAN = 15                          # MUS percussion channel


# ---- the WAD ---------------------------------------------------------------
def wad_lump(name):
    with open(WAD, 'rb') as f:
        magic, n, off = struct.unpack('<4sii', f.read(12))
        f.seek(off)
        raw = f.read(n * 16)
        for i in range(n):
            lo, ln, nm = struct.unpack('<ii8s', raw[i * 16:(i + 1) * 16])
            if nm.rstrip(b'\0').decode('latin-1') == name:
                f.seek(lo)
                return f.read(ln)
    return None


def wad_music_names():
    with open(WAD, 'rb') as f:
        magic, n, off = struct.unpack('<4sii', f.read(12))
        f.seek(off)
        raw = f.read(n * 16)
        out = []
        for i in range(n):
            lo, ln, nm = struct.unpack('<ii8s', raw[i * 16:(i + 1) * 16])
            nm = nm.rstrip(b'\0').decode('latin-1')
            if nm.startswith('D_'):
                out.append((nm, ln))
        return out


# ---- MUS -------------------------------------------------------------------
def parse_mus(b):
    """(tick, kind, chan, a, b) events. Kinds: 'on', 'off', 'vol'.

    DMX MUS: header 'MUS\\x1a', scoreLen, scoreStart, channels, secChannels,
    instrCnt, dummy, then instrCnt u16 instrument numbers. Each event byte is
    last(1) | type(3) | channel(4); when `last` is set a variable-length delay
    in ticks follows, 7 bits per byte, high bit = continue.
    """
    assert b[:4] == b'MUS\x1a', 'not a MUS lump'
    score_len, score_start = struct.unpack('<HH', b[4:8])
    p, end, tick = score_start, score_start + score_len, 0
    ev = []
    while p < end:
        d = b[p]
        p += 1
        if d == 0x60:                          # score end
            break
        last, typ, ch = d & 0x80, (d >> 4) & 7, d & 15
        if typ == 0:                           # release note
            ev.append((tick, 'off', ch, b[p] & 0x7F, 0))
            p += 1
        elif typ == 1:                         # play note (+ optional volume)
            nb = b[p]
            p += 1
            vol = None
            if nb & 0x80:
                vol = b[p] & 0x7F
                p += 1
            ev.append((tick, 'on', ch, nb & 0x7F, vol))
        elif typ == 2:                         # pitch bend -- ignored: POKEY's
            p += 1                             #   8-bit AUDF cannot express it
        elif typ == 3:                         # system event
            p += 1
        elif typ == 4:                         # controller
            ctl, val = b[p], b[p + 1] & 0x7F
            p += 2
            if ctl == 3:                       # 3 = channel volume
                ev.append((tick, 'vol', ch, val, 0))
        elif typ == 5:                         # end of measure
            pass
        elif typ == 7:
            p += 1
        if last:
            dt = 0
            while p < end:
                c = b[p]
                p += 1
                dt = (dt << 7) | (c & 0x7F)
                if not (c & 0x80):
                    break
            tick += dt
    return ev


# ---- MUS -> POKEY ----------------------------------------------------------
def note_audf(note):
    """MIDI note -> (AUDF, octave lifts). AUDCTL=0: 8-bit off the 64 kHz clock,
    so AUDF = base/(2f) - 1 and AUDF > 255 simply cannot sound. Lift octaves
    until it fits rather than dropping the note."""
    lifts = 0
    while True:
        f = 440.0 * 2.0 ** ((note - 69) / 12.0)
        audf = int(round(POKEY_BASE / (2.0 * f) - 1.0))
        if audf <= 255:
            return max(audf, 0), lifts
        note += 12
        lifts += 1


def render(ev, seconds=None):
    """Walk the score at MUS tick rate, snapshot $D202-$D207 once per frame."""
    active = {}                     # (chan, note) -> volume 0..127
    chvol = {c: 127 for c in range(16)}
    frames, stats = [], {'drop_perc': 0, 'lifts': 0, 'dropped_notes': 0,
                         'max_active': 0, 'voice_frames': 0,
                         'lifted_notes': set()}
    ticks_per_frame = MUS_TICK_HZ / FRAME_HZ
    i, tick_f = 0, 0.0
    last_tick = ev[-1][0] if ev else 0
    limit = int(seconds * FRAME_HZ) if seconds else None

    while True:
        tick_f += ticks_per_frame
        tick = int(tick_f)
        while i < len(ev) and ev[i][0] <= tick:
            t, kind, ch, a, bb = ev[i]
            i += 1
            if ch == PERC_CHAN:
                if kind == 'on':
                    stats['drop_perc'] += 1
                continue
            if kind == 'on':
                active[(ch, a)] = bb if bb is not None else chvol[ch]
            elif kind == 'off':
                active.pop((ch, a), None)
            elif kind == 'vol':
                chvol[ch] = a
                for k in list(active):
                    if k[0] == ch:
                        active[k] = a

        stats['max_active'] = max(stats['max_active'], len(active))
        # three voices: the HIGHEST sounding notes keep the melody
        picked = sorted(active.items(), key=lambda kv: -kv[0][1])[:NVOICE]
        if len(active) > NVOICE:
            stats['dropped_notes'] += len(active) - NVOICE

        regs = [0] * 6                          # AUDF2,AUDC2,AUDF3,AUDC3,...
        for v, ((ch, note), vol) in enumerate(picked):
            audf, lifts = note_audf(note)
            stats['voice_frames'] += 1
            if lifts:
                stats['lifts'] += 1             # voice-frames that needed one,
                stats['lifted_notes'].add(note)  #   and which notes they were
            regs[v * 2] = audf
            regs[v * 2 + 1] = AUDC_TONE | max(1, min(15, vol * 15 // 127))
        frames.append(regs)

        if limit and len(frames) >= limit:
            break
        if not limit and i >= len(ev) and tick > last_tick:
            break
    return frames, stats


def encode(frames):
    """pack_musstream.py's format: mask of changed $D200+n, then the values."""
    out = bytearray()
    prev = [None] * 6
    for regs in frames:
        mask, vals = 0, []
        for k in range(6):
            if regs[k] != prev[k]:
                mask |= 1 << (k + 2)            # k=0 is $D202 -> bit 2
                vals.append(regs[k])
        out.append(mask)
        out += bytes(vals)
        prev = list(regs)
    return bytes(out)


# ---- an audible preview ----------------------------------------------------
def to_wav(frames, path, rate=22050):
    """Square waves straight off the AUDF/AUDC pairs, so the ear judges the
    SAME numbers the Atari gets -- not a MIDI rendering of the source."""
    spf = int(rate / FRAME_HZ)
    phase = [0.0] * NVOICE
    buf = bytearray()
    for regs in frames:
        for n in range(spf):
            acc = 0
            for v in range(NVOICE):
                audf, audc = regs[v * 2], regs[v * 2 + 1]
                vol = audc & 15
                if not vol or not audc:
                    continue
                f = POKEY_BASE / (2.0 * (audf + 1))
                phase[v] += f / rate
                acc += vol if (phase[v] % 1.0) < 0.5 else -vol
            s = max(-32767, min(32767, acc * 600))
            buf += struct.pack('<h', s)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(buf))


def main():
    if '--list' in sys.argv:
        for nm, ln in wad_music_names():
            print('%-10s %6d B' % (nm, ln))
        return
    name = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith('-') \
        else 'D_INTER'
    seconds = None
    if '--seconds' in sys.argv:
        seconds = float(sys.argv[sys.argv.index('--seconds') + 1])

    lump = wad_lump(name)
    if lump is None:
        sys.exit('no lump %s in %s' % (name, WAD))
    ev = parse_mus(lump)
    frames, st = render(ev, seconds)
    stream = encode(frames)

    os.makedirs(OUT, exist_ok=True)
    sp = os.path.join(OUT, name + '.stream')
    wp = os.path.join(OUT, name + '.wav')
    open(sp, 'wb').write(stream)
    to_wav(frames, wp)

    secs = len(frames) / FRAME_HZ
    print('%s: %d B lump, %d events' % (name, len(lump), len(ev)))
    print('  %d frames = %.1f s at %g Hz' % (len(frames), secs, FRAME_HZ))
    print('  stream %d B  (%.2f B/frame, %.1f KB per minute)'
          % (len(stream), len(stream) / len(frames),
             len(stream) / secs * 60 / 1024))
    print('  max notes sounding at once: %d (3 voices -> %d note-frames dropped)'
          % (st['max_active'], st['dropped_notes']))
    vf = max(st['voice_frames'], 1)
    print('  octave lifts (note below POKEY\'s 8-bit floor, 123.7 Hz): '
          '%d of %d voice-frames = %.0f %%, %d distinct notes'
          % (st['lifts'], vf, 100.0 * st['lifts'] / vf,
             len(st['lifted_notes'])))
    print('  percussion note-ons dropped: %d' % st['drop_perc'])
    print('  -> %s' % sp)
    print('  -> %s' % wp)


if __name__ == '__main__':
    main()
