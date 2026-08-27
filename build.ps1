# Build the DOOM BSP engine XEX -- the ENGINE ONLY, no assets and no ATR.
# For something you can boot, use .\build_atr.ps1 (that one packs the level
# assets, runs this same chain, and writes build/doom_e1.atr).
# Run from anywhere; paths are relative to this script.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$mads = Join-Path (Split-Path $PSScriptRoot -Parent) 'mads.exe'
if (-not (Test-Path $mads)) { $mads = Join-Path $PSScriptRoot 'mads.exe' }   # fall back to repo-root mads.exe

if (-not (Test-Path build)) { New-Item -ItemType Directory build | Out-Null }
& $mads -i:. bsp_main.asm -o:build/doom_bsp.xex -l:build/doom_bsp.lst
if ($LASTEXITCODE -ne 0) { Write-Error 'assemble failed'; exit 1 }

# The menu and save-game CODE overlays run at $1000 but MADS PARKS them in the
# XEX at $C000/$C400 (MNOVL_STAGE, SGOVL_STAGE) with a two-address org, and that
# is the THINGS slot at runtime -- so they must be lifted out into menu.bin
# before check_xex.py looks, exactly as build_atr.ps1 does between mads and its
# guards. Without this step check_xex fails on a block that is legitimately in
# the XEX for one more step (2026-08-11: this script never got the step and had
# been failing on it ever since the overlays landed).
$menuBin = 'build/assets/menu/menu.bin'
if (-not (Test-Path $menuBin)) {
  Write-Error "$menuBin missing -- run .\build_atr.ps1 once to pack the assets"
  exit 1
}
python tools/split_menu_ovl.py
if ($LASTEXITCODE -ne 0) { Write-Error 'menu overlay split failed'; exit 1 }

python tools/ram_map.py --update | Out-Null   # refresh the RAM budget comment
python tools/bank_map.py --check
if ($LASTEXITCODE -ne 0) { Write-Error 'two Rapidus bank $01 regions overlap'; exit 1 }
python tools/check_xex.py build/doom_bsp.xex
if ($LASTEXITCODE -ne 0) { Write-Error 'segment lands in reserved RAM'; exit 1 }
Write-Host "OK -> build/doom_bsp.xex (engine only -- build_atr.ps1 makes the ATR)" -ForegroundColor Green
