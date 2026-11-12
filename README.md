# DOOM VBXE

[![DOOM ATARI XE/XL, VBXE, Rapidus](https://img.youtube.com/vi/VKz5vFticOs/maxresdefault.jpg)](https://www.youtube.com/watch?v=VKz5vFticOs)

DOOM for the **Atari XL/XE**: a BSP renderer, all three episodes, 65816 assembly.
The original game data is **not** included.

## Hardware

- Atari XL/XE with **VBXE** and **Rapidus** (both required)
- The ATR mounted as **D1:** on a mass-storage device; **SIDE 3** recommended

## Controls

| Key | Action |
|-----|--------|
| Joystick | move, turn, fire |
| SPACE | use |
| 1–7 | weapons |
| TAB | automap |
| − / = | view size / automap zoom |
| T | flat walls on/off |
| F | FPS |
| ESC | menu |

## Build

You need [MADS](https://github.com/tebe6502/Mad-Assembler) (`mads.exe` in the project root),
[TinyCC](https://bellard.org/tcc/) in `tools/tcc` (`tools/tcc/tcc.exe`), and Python 3 with `pillow` and `numpy`.

1. Copy your own IWAD to `build/py/DOOM.WAD` (registered or Ultimate).
2. Get id's DOOM C source. The packers read `info.c` and others from it:
   `git clone https://github.com/id-Software/DOOM.git`, then copy the files of
   `DOOM/linuxdoom-1.10` into `_doomsrc` in the project root.
3. Build the build program: `tools	cc	cc.exe -o build_atr.exe build\cuild_atr.c`.
   The other C tools in `build/c` are compiled by it on their own; copy the
   `zx02.exe` it makes from `build/exe` to `tools/`.
4. Run `build_atr.exe -Full`. It writes `build/doom.atr` (Rapidus) and
   `build/doom_bsp_ant2.atr` (ANTONIA II hardware mul/div).

After that, `build_atr.exe` rebuilds incrementally.
The default build is for the **VBXE FX core 1.27** (textures drawn by the core's blitter);
for the FX 1.26 core add `-Fx127:false`.

## License

Free software under the GNU GPL v2 (see [LICENSE](LICENSE)). DOOM game data is not included and remains © id Software.

## WAD online converter

If you have your own WAD with maps/addons, you can convert it to ATR and play in your ATARI.

https://atari.turiecfoto.sk/wad/

## Credits

DOOM © id Software, 1993. Atari port: **w1k**.
