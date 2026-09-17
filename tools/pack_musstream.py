#!/usr/bin/env python3
"""pack_musstream.py -- the songs as a stream of POKEY register writes.

Running the RMT player on the Atari turned out to be impossible here: it needs
~1.4 KB of bank-0 RAM the port does not have, and putting it in a Rapidus SRAM
bank does not work -- in 65816 EMULATION mode a hardware interrupt pushes only
PC and P and forces the program bank to 0 (Altirra's own cpu.cpp: the emulation
path has no kStatePushPBKNative), so RTI returns to bank 0 and any code running
outside it dies on the first interrupt.

So the player runs HERE instead, once, at build time: tools/rmt_render.py
already simulates the module frame by frame, and what a player ultimately
produces is just eight POKEY bytes per frame. Those get written out, and the
Atari side becomes ~40 bytes that copy them to $D200-$D207 once per frame.

AUDCTL is deliberately NOT in the stream: sound.asm needs it at 0 for the
Timer-1 digi mixer, and every instrument the converter emits uses 0 anyway.

NEITHER IS POKEY CHANNEL 1. AUDF1 is the Timer-1 divisor the digi mixer clocks
itself with, and Altirra's pokey.cpp shows the cost of sharing it:
`mbAllowDeferredTimer[0] = !(mIRQEN & 0x01) && !(mSKCTL & 8)` -- while the digi
IRQ is enabled, channel 1 cannot be deferred and every one of its timer ticks
is a scheduled event, so a music note in AUDF1 multiplies that rate. Channels 3
and 4 are always deferrable and channel 2 nearly always. So the music gets
$D202-$D207 and channel 1 is left alone: three voices instead of four, and the
whole AUDF1 hazard (and the mus_guard that patched around it) disappears.

Format, per frame:
    mask byte   bit n set = register $D200+n changed this frame
    values      one byte per set bit, low bit first
A mask of 0 is a frame where nothing changed -- one byte. Decoding is a shift
and a store, which is the whole point.

  python tools/pack_musstream.py            -> build/assets/music/*.mus1 + sizes
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import rmt_render as R                                  # noqa: E402

_PROJ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(_PROJ, 'build', 'assets', 'music')
SRC_DIR = os.path.join(_PROJ, 'mus')     # the .rmt sources live here now
                                         # (_pomocne/preview/mus is not in the tree)


# RMT voice -> POKEY channel. Voice 1 (harmony) is the one that goes: lead,
# bass and drums carry the tune, and channel 1 belongs to the digi mixer.
VOICE_CHANNEL = {0: 1, 2: 2, 3: 3}        # lead -> ch2, bass -> ch3, drums -> ch4


def registers(path):
    """[(audf1,audc1,audf2,audc2,audf3,audc3,audf4,audc4)] per 50 Hz frame.

    The same walk rmt_render does, but stopping where the player stops: at the
    eight bytes it would have written to POKEY."""
    mod, base = R.load_mod(path)
    tracklen = mod[4] or 256
    speed = mod[5]
    tlo = (mod[10] | (mod[11] << 8)) - base
    thi = (mod[12] | (mod[13] << 8)) - base
    song = (mod[14] | (mod[15] << 8)) - base
    instrs = R.load_instruments(mod, base)

    lines = []
    i = song
    while i < len(mod) - 3 and len(lines) < 256:
        if mod[i] == 0xFE:
            break
        lines.append(list(mod[i:i + 4]))
        i += 4

    voices = []
    for v in range(4):
        rows = []
        for ln in lines:
            tn = ln[v]
            rows.extend([None] * tracklen if tn == 0xFF else
                        R.expand_track(mod, base, tlo, thi, tn, tracklen))
        voices.append(rows)

    nrows = len(voices[0])
    frames = [[0] * 8 for _ in range(nrows * speed)]
    for v in range(4):
        ch = VOICE_CHANNEL.get(v)
        if ch is None:                                   # dropped voice
            continue
        env = None
        env_i = eloop = 0
        orn = [0]
        orn_i = oloop = 0
        tspd = 1
        tcnt = 0
        note = 0
        trkvol = 15
        f = 0
        for r in voices[v]:
            if isinstance(r, tuple) and r[0] == 'n':
                _, note, instr, trkvol = r
                e = instrs[instr] if instr < len(instrs) else None
                if e:
                    env, eloop, orn, oloop, tspd = e
                    env_i = orn_i = tcnt = 0
            elif isinstance(r, tuple):
                trkvol = r[1]
            elif r is None:
                env = None
            for _ in range(speed):
                if env is None:
                    frames[f][ch * 2 + 1] = 0         # AUDCn = silence
                else:
                    vol, dist, cmd, xy = env[min(env_i, len(env) - 1)]
                    tab, audc = R.TABDIST[dist]
                    # ENVELOPE COMMAND (rmt_en.html, INSTRUMENT EDIT):
                    #   0 = play the base note shifted by $XY semitones
                    #   1 = play the frequency $XY DIRECTLY
                    # Command 1 is what every drum in instruments/drums/ is
                    # built on -- bassdrum sweeps $D0,$E0,$F0,$F8 and then
                    # drops to noise. Rendering only vol+dist turned those
                    # into ordinary pitched notes. Commands 2-7 (portamento,
                    # filter, AUDCTL) are not modelled; they fall back to 0,
                    # and mus2rmt.py does not emit them.
                    if cmd == 1:
                        audf = xy
                    else:
                        n = note + orn[min(orn_i, len(orn) - 1)]
                        if cmd == 0:
                            n += xy
                        n = max(0, min(len(tab) - 1, n))
                        audf = tab[n]
                    # the player's volume table is vol * trkvol / 15, rounded
                    # the way its 16x16 lookup does
                    out = (vol * trkvol) // 15
                    frames[f][ch * 2] = audf
                    frames[f][ch * 2 + 1] = audc | (out & 0x0F)
                    env_i = env_i + 1 if env_i + 1 < len(env) else eloop
                    tcnt += 1
                    if tcnt >= tspd:
                        tcnt = 0
                        orn_i = orn_i + 1 if orn_i + 1 < len(orn) else oloop
                f += 1
    return frames, speed


def encode(frames):
    """Frames -> the mask/value stream, terminated by $FF. Returns (bytes, n).

    $FF is stolen as the end marker: a frame that really would change all eight
    registers at once drops its top register from the mask instead, so that one
    write lands a frame late. Nothing audible -- AUDC4's volume arriving 20 ms
    later -- and it buys a one-byte loop test on the Atari (`cmp #$FF`) instead
    of a 24-bit end-pointer comparison every frame."""
    out = bytearray()
    # -1 = "unknown, write it on frame 0". Channel 1 ($D200/$D201) starts at 0
    # so it is never emitted at all -- not even once, because writing AUDF1 = 0
    # would give Timer-1 its shortest possible period for as long as it took the
    # next frame to come round.
    prev = [0, 0, -1, -1, -1, -1, -1, -1]
    for fr in frames:
        mask = 0
        for i in range(8):
            if fr[i] != prev[i]:
                mask |= 1 << i
        if mask == 0xFF:
            mask = 0x7F                   # leave bit 7 for the next frame
        out.append(mask)
        for i in range(8):
            if mask & (1 << i):
                out.append(fr[i])
                prev[i] = fr[i]
    out.append(0xFF)                      # end of song -> the player loops
    return bytes(out), len(frames)


# Bank-ALIGNED, not simply the first free byte (atr_layout.inc PRE_END):
# load_music streams in 4 KB chunks and detects the 64 KB bank rollover by
# ll_dst wrapping to 0 between chunks, which only works if the run starts at
# offset 0 of a bank.
# 2026-09-13: was $550000, chosen when the SDRAM level cache ended at $547200.
# With 27 levels the cache runs to $650700 and $55xxxx is E2M5's .sprcol slot
# (sectors 39899-40186): read_sectors' tee wrote it over the songs on the first
# E2M5 load. $66 is SPRCOL_BANK, so the first whole free bank is $67. music.asm
# fails the build if this ever lands inside the cache again (tools/bank_map.py
# --check says the same).
MUS_BASE = 0x670000


def main():
    # Index IS the engine's: song n is what current_level n plays. D_INTRO --
    # DOOM's title music (d_main.c D_DoAdvanceDemo starts mus_intro with
    # TITLEPIC) -- was packed here as song 9 and the menu played it, but the
    # RMT conversion of that piece sounds wrong, so it is off the list rather
    # than shipped dead. Put it back with:
    #     python tools/pack_musstream.py D_E1M1 ... D_E1M9 D_INTRO
    # and the MUS_INTRO equ reappears for menu.asm to use.
    names = sys.argv[1:] or [f'D_E1M{i}' for i in range(1, 10)]
    os.makedirs(OUT_DIR, exist_ok=True)
    HDR = 3 * len(names)                              # one 24-bit address each
    blob = bytearray(HDR)                             # filled in once sizes are known
    starts = []
    for nm in names:
        frames, _speed = registers(os.path.join(SRC_DIR, nm + '.rmt'))
        one, nfr = encode(frames)
        starts.append(MUS_BASE + len(blob))
        blob += one
        print(f'  {nm:<8} {nfr:6} frames ({nfr / 50:6.1f}s)  {len(one):7} B  '
              f'{len(one) / nfr:4.1f} B/frame  -> ${starts[-1]:06X}')
    # the header the Atari reads: lo[9], mid[9], hi[9] -- same shape as the
    # table used to have in bank 0, just living in SDRAM in front of the songs
    for i in range(3):
        for j, a in enumerate(starts):
            blob[i * len(names) + j] = (a >> (8 * i)) & 0xFF
    with open(os.path.join(OUT_DIR, 'music.stream'), 'wb') as f:
        f.write(blob)
    print(f'  total {len(blob)} B ({len(blob) / 1024:.0f} KB), '
          f'{(len(blob) + 127) // 128} sectors')

    with open(os.path.join(_PROJ, 'music_syms.inc'), 'w') as f:
        f.write('; AUTO-GENERATED by tools/pack_musstream.py -- do not edit.\n')
        f.write('; The E1 songs as POKEY register streams in Rapidus SDRAM.\n')
        f.write('; load_music brings them in once at boot; mus_play feeds one\n')
        f.write('; frame of them to $D200-$D207 per VBLANK. Song index = the\n')
        f.write('; level, except MUS_INTRO -- the title/menu song.\n')
        f.write('MUS_BANK0    equ $%02X\n' % (MUS_BASE >> 16))
        f.write('MUS_COUNT    equ %d\n' % len(names))
        f.write('MUS_BYTES    equ %d\n' % len(blob))
        # One equ per packed song, so no ASM file hard-codes an index.
        # D_INTER is wi_stuff.c:1514's mus_inter -- the stats screen after a
        # level; D_VICTOR is f_finale.c:114, after a whole episode.
        for j, nm in enumerate(names):
            f.write('MUS_%-8s equ %d\n' % (nm[2:], j))

    with open(os.path.join(_PROJ, 'music_tabs.inc'), 'w') as f:
        f.write('; AUTO-GENERATED by tools/pack_musstream.py -- do not edit.\n')
        f.write('; 24-bit Rapidus SDRAM address of each level song; mus_reset\n')
        f.write('; loads mus_p from these with current_level.\n')
        for i, part in enumerate(('mus_b0', 'mus_b1', 'mus_b2')):
            f.write(part + chr(10) + '        dta ' +
                    ','.join('$%02X' % ((a >> (8 * i)) & 0xFF) for a in starts)
                    + chr(10))


if __name__ == '__main__':
    main()
