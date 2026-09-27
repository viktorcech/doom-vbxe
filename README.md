# DOOM VBXE

[![DOOM ATARI XE/XL, VBXE, Rapidus](https://img.youtube.com/vi/VKz5vFticOs/maxresdefault.jpg)](https://www.youtube.com/watch?v=VKz5vFticOs)

A port of **DOOM** to the **Atari XL/XE** with **VBXE**: a real BSP renderer with textured walls,
sprites, monsters and the full three-episode campaign. The engine is written in 65816 assembly, and a
Python pipeline builds the assets.

This repo has the **engine source and the build tools**. It does **not** include the original game
data (see below).

## Hardware

- **Atari XL/XE** with **VBXE**. The framebuffer, the palette and every blit go through it.
- **Rapidus** accelerator, **required**. The engine is assembled as 65816 code, and the BSP nodes,
  the texture pool and the sprite pool live in Rapidus SRAM banks.
- A **mass-storage device for D1:**. The game boots from one large ATR image and streams levels,
  textures and sprites from it while you play.
- **SIDE 3** cartridge, **recommended**. You feel the loading speed for the whole game.

## Controls

| Input | Action |
|-------|--------|
| **Joystick (port 1)** | move / turn, fire |
| **SPACE** | use (doors, switches) |
| **1**…**7** | select weapon (7 = BFG9000) |
| **TAB** | automap |
| **−** / **=** (or **<** / **>**) | view window size; zoom on the automap |
| **T** | flat (untextured) walls on/off, for a faster frame |
| **F** | FPS readout |
| **ESC** | menu (new game, options, load, save, read this, quit) |

## Build requirements

- **[Mad Assembler (MADS)](https://github.com/tebe6502/Mad-Assembler)**. Put `mads.exe` in the
  project root or in the folder above it. It is not distributed here.
- **Python 3** with **Pillow** and **NumPy**:
  ```
  pip install pillow numpy
  ```
- **PowerShell**, because the build scripts are `.ps1` files.
- **The DOOM IWAD** and **id's DOOM C source**. The build needs both, and neither is included. See below.

## Original game data (not included)

The build packs every asset straight out of the **DOOM IWAD**, which is id Software's copyrighted
data. Use your own legally owned copy of the registered or Ultimate IWAD (episodes 1-3):

```
tools/DOOM.WAD
```

If you would rather not copy the file in, set `DOOMWAD` to its path. `DOOMPWAD` adds PWADs on top. It
takes a list separated by `;`, and later files win, like DOOM's `-file`.

**The packers also read id's DOOM C source.** Monster stats and state chains live in `info.c`, not in
the WAD, so the pipeline parses them from there. The linedef specials come from
`p_spec.c`/`p_switch.c`/`p_doors.c`. The source is GPL, and you check it out yourself:

```powershell
git clone https://github.com/id-Software/DOOM.git DOOM-master
```

The tools look for `info.c` in `_doomsrc/` first and then in `DOOM-master/linuxdoom-1.10/`.

## Build

From the project root:

```powershell
.\build_atr.ps1 -Full
```

That writes **`build/doom.atr`**: the boot loader, the engine and all 27 maps of episodes 1-3. Mount
it as **D1:** and boot.

| Command | What it does |
|---------|--------------|
| `.\build_atr.ps1 -Full` | re-packs every asset from the WAD. **Required on a fresh checkout.** |
| `.\build_atr.ps1` | incremental. Reuses `build/assets`, re-assembles the engine and rebuilds the ATR |
| `.\build_atr.ps1 E1M1 E1M8` | builds only the listed levels |
| `.\build_atr.ps1 -Time` | also prints how many seconds each step takes |
| `.\build_atr.ps1 -Antonia2` | `build/doom_bsp_ant2.atr` with ANTONIA II hardware mul/div. It does **not** run on Rapidus |
| `.\build.ps1` | builds the engine XEX only. Run `build_atr.ps1` once before using it |

The packers write the generated sources (`map_syms.inc`, `atr_layout.inc`, `sound_tables.inc`,
`weap_tables.inc` and the others) into the project root at build time. They are not committed.

### Custom maps (wadconv)

`tools/wad/wadconv.py` is a GUI that turns a map PWAD into a bootable ATR. Pick the WAD and the maps,
and it runs the normal build with the PWAD on top of `DOOM.WAD`. Before converting, it also reports
what the engine cannot handle, such as too many things or sectors, unsupported specials or monsters
without sprites.

```
python tools/wad/wadconv.py                          # GUI
python tools/wad/wadconv.py --check MYMAPS.WAD       # the report only
python tools/wad/wadconv.py --build MYMAPS.WAD E1M1  # build without the GUI
```

## Layout

| Path | Contents |
|------|----------|
| `bsp_main.asm` | the root source of the engine. Every other file is `icl`'d from it |
| `boot.asm` | the ATR boot loader |
| `console.asm` | the PC-style text startup screen shown while the game loads |
| `memory_map.inc` | the one place that defines every fixed address (6502 RAM, VBXE VRAM, MEMAC window, SRAM banks) |
| `tools/` | the Python pipeline: WAD readers, asset packers, the ATR builder and the build guards |
| `tools/wad/` | wadconv, the custom map converter |
| `build_atr.ps1` | the full build (bootable ATR) |
| `build.ps1` | the engine XEX alone |

## Credits

- Original game: **DOOM**, id Software, 1993. The game data and trademarks belong to id Software. The
  DOOM source is GPL.
- Atari XL/XE + VBXE port: **w1k**.
