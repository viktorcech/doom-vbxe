# DOOM VBXE

A port of **DOOM** to the **Atari XL/XE** with **VBXE** — a real BSP renderer with textured walls,
sprites, monsters and the full three-episode campaign, written in 6502/65816 assembly with a Python
asset pipeline.

The repo ships the **engine source and build tooling** — it does **not** include the original game
data (see below).

## Hardware

Runs on **real Atari hardware**.

- **Atari XE/XL** with **VBXE** — the framebuffer, the palette and every blit go through it.
- **Rapidus** accelerator — **required**, not optional. The engine assembles as 65816 (`opt c+`) and
  the BSP nodes, the texture pool and the sprite pool live in Rapidus SRAM banks.
- Boots from a **disk image in D1:**.

## Controls

| Input | Action |
|-------|--------|
| **Joystick (port 1)** | move / turn, fire |
| **SPACE** | use (doors, switches) |
| **1**…**6** | select weapon |
| **TAB** | automap |
| **−** / **=** | view window size — zoom on the automap |
| **ESC** | control panel (new game, options, load, save, read this, quit) |
| **F** | FPS readout |

## Build requirements

- **[Mad Assembler (MADS)](https://github.com/tebe6502/Mad-Assembler)** — put `mads.exe` in the
  project root. It is a third-party tool and is not distributed here.
- **Python 3** with **Pillow** and **NumPy** — the asset pipeline in `tools/`:
  ```
  pip install pillow numpy
  ```
- **PowerShell** — the build scripts are `.ps1`.

## Original game data (not included)

The build packs its assets straight out of the **DOOM IWAD**, which is id Software's copyrighted
data and is **not distributed here**. Supply your own legally-owned copy:

```
tools/DOOM.WAD          # the registered/Ultimate IWAD (episodes 1-3)
```

`DOOMWAD` overrides the path and `DOOMPWAD` adds PWADs (`os.pathsep`-separated, later ones win, like
DOOM's `-file`) if you would rather not copy the file in.

The packers also read the **original DOOM C source** — id Software's own `info.c` is the authority
for what every monster does when it is shot, and `p_map.c` for the splash-damage rule, so those
tables are derived rather than retyped. It is GPL and lives upstream, so it is not vendored here
either. Check it out into `_pomocne/_doomsrc/`:

```powershell
git clone https://github.com/id-Software/DOOM.git _doom_tmp
mkdir _pomocne\_doomsrc
copy _doom_tmp\linuxdoom-1.10\*.c _pomocne\_doomsrc\
copy _doom_tmp\linuxdoom-1.10\*.h _pomocne\_doomsrc\
```

Without it `pack_things.py` stops with `info.c missing`, and a clean checkout cannot build.

## Build

From the project root:

```powershell
.\build_atr.ps1 -Full
```

That produces **`build/doom_e1.atr`** — a bootable disk carrying the boot loader, the engine XEX and
all 27 maps of episodes 1-3, streamed off the disk level by level. Mount it as **D1:** and boot.

| Invocation | What it does |
|------------|--------------|
| `.\build_atr.ps1` | incremental (~3 s) — reuses `build/assets`, re-assembles and re-packs the ATR |
| `.\build_atr.ps1 -Full` | re-packs every asset out of the WAD (~90 s). **Required on a fresh checkout.** |
| `.\build_atr.ps1 E1M1 E1M8` | an explicit level set |
| `.\build_atr.ps1 -Check` | + the slow gates: boot simulation on `sim6502`, and the `_verify_*` suite where present |
| `.\build_atr.ps1 -Time` | + seconds per step |
| `.\build.ps1` | the **engine XEX only**, no assets and no ATR (needs one `build_atr.ps1` run first) |

Generated sources — `map_syms.inc`, `atr_layout.inc`, `sound_tables.inc`, `weap_tables.inc` and the
rest of the packer output — are written into the project root at build time and are not committed.
`trig.inc`, `recip.inc` and `qs_tables.inc`/`qs_mirror.inc` are committed: they are pure math tables,
regenerate them with `tools/gen_tables.py` and `tools/gen_qs.py`.

## Layout

| Path | Contents |
|------|----------|
| `bsp_main.asm` | the engine's root source — everything else is `icl`'d from it |
| `boot.asm` | the ATR boot loader |
| `memory_map.inc` | the single source of truth for every fixed address (6502 RAM, VBXE VRAM, MEMAC window, SRAM banks) |
| `tools/` | Python pipeline — WAD readers, asset packers, the ATR builder, the 6502/65816 simulator and the build guards |
| `build_atr.ps1` | the build (bootable ATR) |
| `build.ps1` | the engine XEX alone |

## Credits

- Original game: **DOOM** — id Software, 1993. Game data and trademarks are id Software's; the DOOM
  source is GPL.
- Atari XL/XE + VBXE port: **w1k**.
