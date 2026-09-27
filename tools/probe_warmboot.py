#!/usr/bin/env python3
"""QUIT DOOM -> ENDOOM's DOS -> "DOOM" -> the warm reboot, in the frame sim.

Full boot (_bench_frame, no snapshot) to the boot menu, then the menu's own
quit path: mn_open on the savegame overlay's SG_E_QUIT entry -> sg_quit (its
mixer wait skipped: the sim has no POKEY IRQ) -> con_end -> the prompt, typed
D O O M <RETURN> -> sg_bye -> the ATR loader -> the XEX again -> main.

Flags what real iron dies on and the flat sim would not: the CPU NATIVE with
the OS ROM banked in (PORTB bit0 = 1) while executing $C000-$FFFF, or an NMI
taken native with the ROM in (its vector would come from ROM bytes).

  python tools/probe_warmboot.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'tests'))

import _bench_frame as BF                                     # noqa: E402

KEYS = [0x3A, 0x08, 0x08, 0x25, 0x0C]          # D O O M <RETURN>


class Done(Exception):
    pass


def main():
    fb = BF.FrameBench()
    fb.use_snap = False
    s, m = fb.s, fb.s.mem
    FR = BF.VBI_PERIOD
    mn_boot, mn_open = fb.sym('mn_boot'), fb.sym('mn_open')
    qwait, cend, bye = fb.sym('sg_qwait'), fb.sym('con_end'), fb.sym('sg_bye')
    main_ = fb.sym('main')
    st = {'stage': 'boot', 'keys': None}
    orig = s.step

    def rom_native(pc):
        portb = s.hw.get(0xD301, 0xFF)
        return (not s.e and portb & 1 and s.pbr == 0
                and pc >= 0xC000 and not 0xD000 <= pc < 0xD800)

    def step(pc):
        k = (s.pbr << 16) | pc
        g = st['stage']
        if g == 'boot' and k == mn_boot:
            st['stage'] = 'quit'
            print(f'boot menu at cyc={s.cyc:,}: QUIT DOOM', flush=True)
            s.a = (s.a & 0xFF00) | 0x80 | 0x0F   # BANK_EN | SGOVL_BANK
            s.x = 3                              # SG_E_QUIT
            return orig(mn_open & 0xFFFF)
        if g != 'boot':
            if k == qwait:
                m[0x10] = 0                      # POKMSK: the mixer "drained"
            if k == cend and st['keys'] is None:
                st['keys'] = s.cyc + 20 * FR
                print(f'con_end at cyc={s.cyc:,}', flush=True)
            if k == bye and g == 'quit':
                st['stage'] = 'bye'
                print(f'sg_bye at cyc={s.cyc:,}', flush=True)
            if g == 'bye' and pc == 0x0706 and s.pbr == 0:
                st['stage'] = 'loader'
                print(f'the ATR loader at cyc={s.cyc:,}', flush=True)
            if g == 'loader' and k == main_:
                raise Done
            s.key_from = s.key_until = 0         # the harness's own menu taps
            if st['keys'] is not None:           #   must not type here
                i = (s.cyc - st['keys']) // (6 * FR)
                if 0 <= i < len(KEYS):
                    s.key_code = KEYS[i]
                    s.key_from = st['keys'] + i * 6 * FR
                    s.key_until = s.key_from + 3 * FR
            if rom_native(pc):
                raise RuntimeError(f'NATIVE code at ${pc:04X} with the OS ROM in '
                                   f'(PORTB=${s.hw.get(0xD301, 0xFF):02X}), '
                                   f'stage {g}')
        return orig(pc)
    s.step = step
    ovbi = fb._vbi

    def vbi(pc):
        if st['stage'] != 'boot' and not s.e and s.hw.get(0xD40E, 0) & 0x40 \
                and s.hw.get(0xD301, 0xFF) & 1:
            raise RuntimeError(f'NMI while NATIVE with the ROM in at ${pc:04X} '
                               f'(PORTB=${s.hw.get(0xD301, 0xFF):02X}), '
                               f'stage {st["stage"]}')
        return ovbi(pc)
    fb._vbi = vbi
    try:
        fb.run(frames=10 ** 9)
    except Done:
        print(f'OK: main reached again at cyc={s.cyc:,}')
        return
    except RuntimeError as e:
        sys.exit(f'FAIL: {e}')
    sys.exit(f'FAIL: the run ended at stage {st["stage"]}')


if __name__ == '__main__':
    main()
