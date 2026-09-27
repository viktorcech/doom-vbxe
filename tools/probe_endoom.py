#!/usr/bin/env python3
"""ENDOOM (console.asm con_end) as VBXE would show it: boot the sim to con_off,
run con_end in its place, stop at its key wait, and render the 80x25 text map
(VRAM $004000, palette 1 as written, the ROM font's layout) to tools/out/endoom.png."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(HERE, 'tests'))    # _bench_frame, sim6502

import _bench_frame as BF
from PIL import Image


class Stop(Exception):
    pass


def main():
    fb = BF.FrameBench()
    fb.use_snap = False
    s = fb.s
    off, end = fb.sym('con_off'), fb.sym('con_end')
    epal = fb.sym('con_epal')
    pal = {}
    st = {'csel': 0, 'psel': 0, 'rgb': [0, 0, 0], 'in': False}
    orig_wr = s.wr

    def wr(a, v):
        a16 = a & 0xFFFF
        if a16 == 0xD645:
            st['psel'] = v & 3
        elif a16 == 0xD644:
            st['csel'] = v & 0xFF
        elif 0xD646 <= a16 <= 0xD648:
            st['rgb'][a16 - 0xD646] = v & 0xFF
            if a16 == 0xD648 and st['psel'] == 1:
                pal[st['csel']] = tuple(st['rgb'])
        return orig_wr(a, v)
    s.wr = wr
    orig = s.step

    # --type: drive the DOS prompt with a key script (hardware key codes, each
    # held 2 frames then released 2), render after it. Default: stop at the
    # prompt's first SKSTAT read (the plain ENDOOM screen).
    typing = '--type' in sys.argv[1:]
    script = [0x10, 0x2A, 0x28, 0x0C,              # VER <RETURN>
              0x16, 0x2B, 0x17, 0x0C,              # XYZ <RETURN>
              0x0C,                                # <RETURN>
              0x3A, 0x0D, 0x28, 0x0C,              # DIR <RETURN>
              0x3A, 0x0D, 0x28, 0x1C,              # DIR <ESC>
              0x3A, 0x0D, 0x28, 0x46, 0x34,        # DIR\ <BACKSPACE>
              0x3A, 0x08, 0x08, 0x25]              # DOOM (no RETURN)
    FR = BF.VBI_PERIOD

    def step(pc):
        k = (s.pbr << 16) | pc
        if k == off:
            st['in'] = True
            st['t0'] = s.cyc + 10 * FR
            return orig(end & 0xFFFF)          # con_end instead of con_off
        if st['in'] and not typing and end <= k < epal:
            if list(s.code[pc:pc + 3]) == [0xAD, 0x0F, 0xD2]:   # lda SKSTAT
                raise Stop
        if st['in'] and typing:
            i = (s.cyc - st['t0']) // (4 * FR)
            s.key_from = s.key_until = 0       # (the harness's own title taps
            if 0 <= i < len(script):           #   must not type here)
                s.key_code = script[i]
                s.key_from = st['t0'] + i * 4 * FR
                s.key_until = s.key_from + 2 * FR
            elif i >= len(script) + 3:
                raise Stop
        return orig(pc)
    s.step = step
    try:
        fb.run(frames=0)
    except Stop:
        pass
    else:
        sys.exit('FAIL: never reached con_end\'s key wait')

    v = s.vram
    # the sim has no OS ROM behind $E000, so con_init's font copy is noise:
    # draw the codes with Altirra's kernel font (the XL ROM's layout)
    fnt = open(os.path.join(ROOT, 'alt-src', 'Kernel', 'source', 'Shared',
                            'atarifont.bin'), 'rb').read() * 2
    img = Image.new('RGB', (640, 200))
    px = img.load()
    for r in range(25):
        for c in range(80):
            ch, at = v[0x4000 + r * 160 + c * 2], v[0x4000 + r * 160 + c * 2 + 1]
            ink = pal.get(at & 0x7F, (0, 0, 0))
            paper = pal.get(0x80 + (at & 0x7F) if at & 0x80 else 0x80, (0, 0, 0))
            for y in range(8):
                b = fnt[ch * 8 + y]
                for x in range(8):
                    px[c * 8 + x, r * 8 + y] = ink if b & (0x80 >> x) else paper
    out = os.path.join(ROOT, 'tools', 'out')
    os.makedirs(out, exist_ok=True)
    p = os.path.join(out, 'endoom.png')
    img.resize((1280, 400), Image.NEAREST).save(p)
    print('XDL @ $005100:', v[0x5100:0x5100 + 27].hex(' '))
    print('palette 1 entries:', {hex(k): v2 for k, v2 in sorted(pal.items())})
    print('->', p)


if __name__ == '__main__':
    main()
