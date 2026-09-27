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

You need [MADS](https://github.com/tebe6502/Mad-Assembler) (`mads.exe` in the project root), Python 3
with `pillow` and `numpy`, and PowerShell.

1. Copy your own IWAD to `tools/DOOM.WAD` (registered or Ultimate).
2. Get id's DOOM C source. The packers read `info.c` from it:
   `git clone https://github.com/id-Software/DOOM.git DOOM-master`
3. Run `.\build_atr.ps1 -Full`. It writes `build/doom.atr`.

After that, `.\build_atr.ps1` rebuilds incrementally.

## Credits

DOOM © id Software, 1993. Atari port: **w1k**.
