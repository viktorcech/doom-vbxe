# Build the BOOTABLE DOOM ATR: boot loader + engine XEX + episode-1 map(s).
#   Boots from the ATR so the OS cold-starts cleanly (valid VIMIRQ) and the
#   engine's SIO level streaming works. Mount the result as D1: and boot it.
# Usage:  .\build_atr.ps1               # every level, INCREMENTAL (~3 s)
#         .\build_atr.ps1 E1M1 E1M8     # an explicit level set
#         .\build_atr.ps1 -Full         # re-pack every asset from the WAD
#         .\build_atr.ps1 -Check        # + the slow gates (boot sim, _verify_*)
#         .\build_atr.ps1 -Time         # + seconds per step
#
# WHY THE SWITCHES (2026-08-11). A full run is ~42 s and 35 of them are three
# packers that only ever read DOOM1.WAD:
#       pack_map      18.5 s     mads (engine)      1.4 s
#       pack_textures 16.7 s     everything else    1.7 s
#       check_boot     3.1 s
# Editing an .asm file cannot change one byte of what those three emit, so the
# default build reuses build/assets and rebuilds the ATR in ~3 s. They still run
# whenever anything they READ moved -- any tools\*.py, the WAD, a missing output
# or a different level set (map_syms.inc/mk_tables.inc carry capacities sized
# over the BUILT set, so a subset build has to re-emit them). -Full forces them.
# check_boot.py is a measurement, not a build step: it simulates the whole boot
# on sim6502 and answers "would this ATR come up", so it lives under -Check with
# the _verify_* tests. Ship-it runs want  .\build_atr.ps1 -Full -Check.
[CmdletBinding()]
param(
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$Levels,
  [switch]$Full,          # re-pack every asset even if it is up to date
  [switch]$Check,         # run the slow verification gates
  [switch]$Time           # print seconds per step
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
# WHICH INTERPRETER RUNS THE PACKERS. 'python' normally -- a developer checkout
# has one. The packaged wadconv.exe (tools/make_exe.py) has no Python on the
# user's machine at all, so it sets DOOM_PY to ITSELF and every packer below is
# re-run through the EXE, which carries the interpreter, numpy and PIL with it.
# Unset = exactly what this script always did.
$py = if ($env:DOOM_PY) { $env:DOOM_PY } else { 'python' }
$mads = Join-Path (Split-Path $PSScriptRoot -Parent) 'mads.exe'
if (-not (Test-Path $mads)) { $mads = Join-Path $PSScriptRoot 'mads.exe' }
if (-not (Test-Path build)) { New-Item -ItemType Directory build | Out-Null }
# ALL THREE EPISODES since 2026-08-18. The list order is the DISK order;
# the campaign graph (M8 -> next episode, secret exits through M9, M9's
# return map) is pack_map._next_level -- g_game.c G_DoCompleted's rules.
$lvls = if ($Levels -and $Levels.Count) { @($Levels) } else {
  @('E1M1','E1M2','E1M3','E1M4','E1M5','E1M6','E1M7','E1M8','E1M9',
    'E2M1','E2M2','E2M3','E2M4','E2M5','E2M6','E2M7','E2M8','E2M9',
    'E3M1','E3M2','E3M3','E3M4','E3M5','E3M6','E3M7','E3M8','E3M9') }
# NOTE the calls below pass $lvls, NOT @lvls. Splatting a one-element list splats
# the STRING one CHARACTER per argument -- with a single level the packers got
# E, 1, M, 9 and died with "map E not in WAD", so the documented
# `.\build_atr.ps1 E1M1` never worked. Passing the array to a native command
# unrolls it correctly for one, many or none.

$swAll = [Diagnostics.Stopwatch]::StartNew()
$swStep = [Diagnostics.Stopwatch]::StartNew()
function Lap([string]$what) {                    # -Time: one line per step
  if ($Time) { Write-Host ("  [{0,6:N2}s] {1}" -f $swStep.Elapsed.TotalSeconds, $what) -ForegroundColor DarkGray }
  $script:swStep.Restart()
}

# 1. boot loader -> raw boot.bin (strip the 6-byte XEX header, like woll3d)
& $mads -i:. boot.asm -o:build/boot.xex
if ($LASTEXITCODE -ne 0) { Write-Error 'boot assemble failed'; exit 1 }
& $py -c "open('build/boot.bin','wb').write(open('build/boot.xex','rb').read()[6:])"
Lap 'boot loader'

# 1b. digitized SFX blob + sound_tables.inc (both are inputs to the layout below:
#     SND_CHUNKS sizes the ATR slot, the tables are icl'd by sound.asm)
& $py tools\wadsound.py
if ($LASTEXITCODE -ne 0) { Write-Error 'sound extract failed'; exit 1 }

# 1c. weapon psprites + weap_tables.inc (same deal: WEAP_CHUNKS sizes the slot,
#     the WPF_*/WEAP_BKn equs are icl'd by weapon.asm)
# Skipped when its blobs are already there and newer than the packer + WAD.
# pack_weap imports pack_things, which reads the DOOM source tree at import
# time (doomstates.doom -> _pomocne\_doomsrc\info.c). That tree is not a
# build output, so without it a checkout could not build at all even though
# every asset it produces was already packed. -Full forces the repack.
$weapOut = 'build\assets\weap\weap.bin', 'build\assets\weap\weap.tab'
$weapDo = $Full.IsPresent -or @($weapOut | Where-Object { -not (Test-Path $_) }).Count
if (-not $weapDo) {
  $inN = (Get-ChildItem 'tools\pack_weap.py', 'tools\DOOM.WAD' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
  $outO = (Get-ChildItem $weapOut | Sort-Object LastWriteTimeUtc | Select-Object -First 1)
  if ($inN -and $outO.LastWriteTimeUtc -lt $inN.LastWriteTimeUtc) { $weapDo = $true }
}
if ($weapDo) {
  & $py tools\pack_weap.py
  if ($LASTEXITCODE -ne 0) { Write-Error 'weapon extract failed'; exit 1 }
} else {
  Write-Host 'weapon psprites up to date -- pack_weap skipped. Force with -Full' -ForegroundColor DarkGray
}

# 1c-2. DOOM's COLORMAP -> cmap.bin, the light table lights.asm shades every
#       flat surface with. Map-independent and chunk-sized, so it rides into
#       Rapidus SRAM behind the weapon master (make_atr_doom.py CMAP_EXT) --
#       it sizes that slot, so it has to exist before the layout is emitted.
& $py tools\pack_cmap.py
if ($LASTEXITCODE -ne 0) { Write-Error 'colormap extract failed'; exit 1 }

# 1c-3. status bar + every widget glyph -> hud.bin/hud.tab. Ran by hand until
#       2026-08-07 and it bit exactly the way pack_things once did: adding the
#       OUCH faces moved the table, the engine indexed face 26 and the ATR still
#       carried the 26-lump blob that has no face 26 in it.
& $py tools\pack_hud.py
if ($LASTEXITCODE -ne 0) { Write-Error 'hud pack failed'; exit 1 }
Lap 'wad assets (sound/weap/cmap/hud)'

# 1c-bis0. the build version: VERSION holds the minor number, every build bumps
#          it, and pack_menu.py bakes "DOOM VBXE, AUTHOR: W1K, AI CODE, 2026,
#          V0.<n>" into the READ THIS! screen. Must run BEFORE pack_menu.
$vf = Join-Path $PSScriptRoot 'VERSION'
$v = 0
if (Test-Path $vf) { try { $v = [int](Get-Content $vf -TotalCount 1) } catch { $v = 0 } }
$v += 1
Set-Content $vf $v -Encoding ascii
Write-Host "build version 0.$v"

# 1c-bis. the title + main menu graphics (DOOM's own M_* patches, halved like
#         the HUD). Must run BEFORE make_atr_doom.py, which sizes MENU_SEC1 from
#         the blob on disk, and before mads, which `ins`-es menu.tab.
#         Not skippable like the three below: it stamps the version above into
#         the CREDITS screen, and that number changes on every single build.
# 1c-bis-wi. the intermission graphics + wi_syms.inc, sized for THIS level
#            set (WILV name lumps, wi_lvx, wi_par, lnodes -- all per level).
#            Must run BEFORE pack_menu (menu.bin swallows wi.bin) and before
#            mads (wi.asm ins-es wi.tab + icl's wi_syms.inc).
& $py tools\pack_wi.py --levels ($lvls -join ',')
if ($LASTEXITCODE -ne 0) { Write-Error 'wi pack failed'; exit 1 }
# 1c-bis-fin. the END-OF-EPISODE finale (f_finale.c): fin.bin, the small
#             resident half (hu_font + the three flats + the three story
#             texts), and finpic.bin, the four full pages + the END letters.
#             Same rule as pack_wi: BEFORE pack_menu, which swallows fin.bin
#             into its boot stream, and before mads, which icl's fin_syms.inc.
#             finpic.bin is NOT swallowed -- 38 chunks would walk the boot
#             stream through FRAME_C -- it is its own ATR region (FIN_SEC1)
#             that the finale pulls into the sprite arena on demand.
& $py tools\pack_fin.py
if ($LASTEXITCODE -ne 0) { Write-Error 'finale pack failed'; exit 1 }
& $py tools\pack_menu.py --levels ($lvls -join ',')
if ($LASTEXITCODE -ne 0) { Write-Error 'menu pack failed'; exit 1 }
Lap 'menu + version'

# (no music step: the songs were in the build for one afternoon and came back
#  out -- the RMT renderings sounded wrong. `python tools\pack_musstream.py`
#  writes build/assets/music/music.stream and make_atr_doom.py picks it up on
#  its own, so re-enabling the ATR side is just running that once; the engine
#  side is the two tail calls named in music.asm's header.)

# 1d. the per-level blobs -- THE 35 SECONDS. These used to be run by hand and it
#     bit: pack_things defaults to E1M1 ALONE, so a change to the things/sprite
#     format silently left E1M2..E1M9 on the previous build's bytes. Both packers
#     take the level list, so pass it and there is nothing to forget.
#     ORDER MATTERS since the tex+spr pool split: pack_things derives each
#     level's sprite base from its .tex size, so pack_textures runs FIRST --
#     and make_atr_doom cross-checks the .sprmeta sidecar against the .tex on
#     disk, so a stale combination fails the build instead of shipping.
#
#     The skip below answers the same "stale bytes" worry the hard way, from
#     mtimes: EVERY output of all three must exist and be newer than EVERY
#     tools\*.py and the WAD. Touch any packer (or any library one of them
#     imports -- they all live in tools\) and the whole set re-packs. The level
#     list is stamped as well, because map_syms.inc's shared capacities and
#     mk_tables.inc are sized over the levels actually built, not per level.
$stamp = 'build\.packed.stamp'
$outs = @('map_syms.inc', 'mk_tables.inc', 'build\assets\textures\playpal.bin',
          'build\assets\things\sprpool.bin')   # B2: one sprite pool per build
foreach ($l in $lvls) {
  $outs += "build\assets\wadmaps\$l.bin"
  $outs += "build\assets\textures\$l.tex", "build\assets\textures\$l.texix",
           "build\assets\textures\$l.textab", "build\assets\textures\$l.segtex"
  $outs += "build\assets\things\$l.things",
           "build\assets\things\$l.dtab", "build\assets\things\$l.los",
           "build\assets\things\$l.sprcol", "build\assets\things\$l.sprmeta"
}
$repack = $Full.IsPresent
$why = 'forced (-Full)'
if (-not $repack) {
  $missing = @($outs | Where-Object { -not (Test-Path $_) })
  if ($missing.Count) { $repack = $true; $why = "$($missing[0]) is missing" }
}
if (-not $repack) {
  # The WAD is tools\DOOM.WAD (wadlib.DEFAULT_WAD), NOT DOOM1.WAD in the root --
  # that path has never existed, and with $ErrorActionPreference = 'Stop' this
  # line KILLED the build outright. It only ever ran when every output was
  # already present (the $missing branch above short-circuits it), which is why
  # it survived: the first build after a clean always takes the other path.
  # -ErrorAction SilentlyContinue so a moved/renamed WAD degrades to "the .py
  # files decide", instead of stopping the build again.
  # The stamp watches the PACKERS and their libraries, not every .py in
  # tools\ (2026-08-27) -- see this script's header.
  $newestIn = (Get-ChildItem 'tools\pack_*.py', 'tools\wad*.py',
                             'tools\doom*.py', 'tools\texruns.py',
                             'tools\pool_plan.py', 'tools\palette32.py',
                             'tools\DOOM.WAD' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
  $oldestOut = (Get-ChildItem $outs | Sort-Object LastWriteTimeUtc | Select-Object -First 1)
  if ($oldestOut.LastWriteTimeUtc -lt $newestIn.LastWriteTimeUtc) {
    $repack = $true; $why = "$($newestIn.Name) is newer than $($oldestOut.Name)"
  }
}
# ...and the WAD PAIR is part of that stamp, not just the level list
# (2026-08-16). The mtime test above only watches tools\*.py and tools\DOOM.WAD,
# so a wadconv.py conversion run right after a normal build found every output
# present and newer, skipped all three packers, and shipped THE PROJECT'S
# E1M1 -- DOOM's geometry and DOOM's textures -- inside an ATR whose palette,
# colormap and menu had just been rebuilt from heretic.wad. It looked like a
# palette bug and it was a staleness bug. DOOMWAD/DOOMPWAD are what wadconv
# sets, so putting them in the stamp makes any change of WAD a repack.
if (-not $repack) {
  $want = "$($env:DOOMWAD)|$($env:DOOMPWAD)|$($lvls -join ' ')"
  $have = if (Test-Path $stamp) { (Get-Content $stamp -TotalCount 1) } else { '' }
  if ($have -ne $want) { $repack = $true; $why = 'the WAD pair or level set changed' }
}
if ($repack) {
  Write-Host "packing levels: $why"
  & $py tools\pack_map.py $lvls
  if ($LASTEXITCODE -ne 0) { Write-Error 'map pack failed'; exit 1 }
  & $py tools\pack_textures.py $lvls
  if ($LASTEXITCODE -ne 0) { Write-Error 'texture pack failed'; exit 1 }
  & $py tools\pack_things.py $lvls
  if ($LASTEXITCODE -ne 0) { Write-Error 'things pack failed'; exit 1 }
  Set-Content $stamp "$($env:DOOMWAD)|$($env:DOOMPWAD)|$($lvls -join ' ')" -Encoding ascii
} else {
  Write-Host 'level assets up to date -- pack_map/pack_textures/pack_things skipped (~35 s). Force with -Full' -ForegroundColor DarkGray
}
Lap 'level assets'

# 2. level layout (atr_layout.inc) BEFORE building the XEX (load_level needs it)
& $py tools\make_atr_doom.py --dir $lvls
if ($LASTEXITCODE -ne 0) { Write-Error 'layout emit failed'; exit 1 }

# 3. engine XEX (now atr_layout.inc is correct)
#    -t writes build/doom_bsp.lab, which is what sim6502.load_syms reads: every
#    _verify_* that runs the shipped bytes resolves its symbols through it, and
#    a .lab left over from an older build resolves them to the WRONG addresses
#    without saying so. It costs nothing to emit here (2026-08-16).
& $mads -i:. bsp_main.asm -o:build/doom_bsp.xex -l:build/doom_bsp.lst -t:build/doom_bsp.lab
if ($LASTEXITCODE -ne 0) { Write-Error 'assemble failed'; exit 1 }
Lap 'mads'

# 3a. the menu CODE overlay out of the XEX and into menu.bin's reserved chunk.
#     It is assembled for $1000 and parked at $C000, so it must be gone before
#     check_xex.py looks (and before the boot loader ever writes it to RAM).
& $py tools\split_menu_ovl.py
if ($LASTEXITCODE -ne 0) { Write-Error 'menu overlay split failed'; exit 1 }

# 3b. no segment may land in RAM that is overwritten at runtime (TEX_STAGE!)
#     Both are cheap (~0.1 s) and they fail the build on a real defect, so they
#     stay in the default path -- they are guards, not measurements.
#     Both need tools/ram_map.py -- check_xex.py imports RESERVED/STAGED from it.
#     It was deleted on 2026-08-14, so both are skipped until it is back. The .asm
#     `ert` guards still catch every parked block that outgrows its hole.
if (Test-Path tools/ram_map.py) {
    & $py tools/ram_map.py --update | Out-Null   # refresh the RAM budget comment
    & $py tools/bank_map.py --check
if ($LASTEXITCODE -ne 0) { Write-Error 'two Rapidus bank $01 regions overlap'; exit 1 }
& $py tools/check_xex.py build/doom_bsp.xex
    if ($LASTEXITCODE -ne 0) { Write-Error 'segment lands in reserved RAM'; exit 1 }
} else {
    Write-Host 'SKIP RAM guards (tools/ram_map.py is missing)'
}
Lap 'overlay split + RAM guards'

# 4. assemble the bootable ATR (boot.bin + doom_bsp.xex + maps)
& $py tools\make_atr_doom.py $lvls
if ($LASTEXITCODE -ne 0) { Write-Error 'atr build failed'; exit 1 }
Lap 'ATR image'

# 5. THE MEASUREMENTS, -Check only. Everything below runs the real code on
#    sim6502 instead of just assembling it, which is why it is off by default.
#      * _verify_xdl / _verify_menu: the display list still covers 240 lines, a
#        menu patch still lands on the right row (~2 s).
#      * check_boot.py: the "will it even boot" gate (2026-08-10, the Rapidus
#        black-screen day) -- ATR boot sectors, the $0700 loader, every XEX
#        segment, VBI NMIs injected, RAM under the ROM virgin, simulated all the
#        way to main ($2000). 3.1 s.
#      * _verify_save: BOOTS a level and runs the real two-phase LOAD (~1 min).
#    NOT here either way: the two music checks. _verify_musstream.py needs the
#    stream on disk and the hooks in the engine, _verify_musram.py boots a level
#    and runs real frames (18 s) -- both are for whoever puts the songs back.
if ($Check) {
  $env:PYTHONPATH = '_pomocne/_tmp_pyc'
  # wpgive: P_GiveWeapon's "full ammo -> the gun stays on the floor" (runs the
  #   shipped bytes on sim6502). doorside: which SIDE of a door the spacebar
  #   opens it from, over every door face in the episode -- both are under a
  #   second and both guard rules that were wrong until 2026-08-11.
  # native: udiv24 runs on every column, and it used to return in EMULATION mode
  #   -- where rep/sep of the M/X bits is a no-op, so every 16-bit index in the
  #   engine silently became a byte (2026-08-14, the automap bug). This asserts
  #   the quotient AND that the caller's mode survives the call.
  # lights: every light thinker in the episode, link by link -- spawned, packed,
  #   inside the BYTE X update_lights walks it with, on the ATR inside the window
  #   load_level streams, and shading through two DIFFERENT colormap rows. Added
  #   2026-08-15: the LIGHTS section had grown past TH_HPL into the AI's health
  #   table, en_init wiped E1M2's last eight thinkers, and NOTHING in the build
  #   noticed -- because every link measured correct on its own.
  # title/msg: the HU strips (the automap's level names AND the pickup
  #   messages) are ONE packed array behind ONE blitter, and the engine finds a
  #   message in it by adding MSG_IDX0 to the bonus id. Nothing in the build
  #   fails if the packer and the engine disagree about that offset -- the
  #   wrong strip simply appears. _verify_title reads the array back out of
  #   menu.bin, _verify_msg runs the widget on the shipped bytes (2026-08-16).
  # spectre: MF_SHADOW's three BCB bytes, and -- the reason it is a gate at all
  #   -- that spr_shadow still FITS. It sat in a block whose declared END was
  #   inside BLKTAB, so it silently overwrote en_solid's 3x3 neighbourhood and
  #   the assembler said nothing (2026-08-16).
  # flinch: PTAB_EXT[kind] -> TH_WROW is a ROW+1, so a $FF that reaches it
  #   writes 0 = "not chasing" and ai_tick drops the monster for good. The test
  #   drives the real ai_pain_row and reads the shipped .dtab blobs back.
  # deathsnd: A_Scream vs A_XScream. p_inter.c:719 sends anything past
  #   -spawnhealth to the XDIE chain and that chain yells sfx_slop, not the
  #   kind's death cry -- for the three monsters info.c gives an xdeathstate
  #   (zombieman/shotgun guy/imp) AND for the player, at -100. Every boundary
  #   here is a strict "<", so an off-by-one is a wrong sound and nothing else
  #   in the build would ever say so. The test calls en_plr_hurt and en_gibq on
  #   the shipped bytes and then checks snd_play really arms the SLOP sample
  #   (2026-08-19).
  foreach ($t in 'xdl', 'menu', 'wpgive', 'doorside', 'native', 'lights',
  # pjz: the missile's vertical aim. The z leg pushed the per-bolt context past
  #   32 B, so PJ_SLSTR doubled and the eight slots went from one page of bank
  #   $01 to two -- pj_slot now has to carry a shift into the page byte, and
  #   the last slot has to stay clear of DTAB_EXT. Nothing in the build fails
  #   if it does not: the bolts would simply start eating the death-animation
  #   table. The test walks all eight and then checks the Q8 step arithmetic,
  #   sign extension included (2026-08-19).
  # spidfire: A_SpidRefire and A_BossDeath's timing (2026-08-20). The refire
  #   loop is the only attack chain in DOOM that does not end when its last
  #   state does, and it turns a shared shortcut into a LIVELOCK: aif_isvis
  #   answers "visible" for any monster target, A_Chase is the only thing that
  #   drops a DEAD one, and the loop never lets A_Chase run -- so the spider
  #   shot a cacodemon and then fired into the corpse for ever. Nothing in the
  #   build fails on that; it is a monster that stops behaving. The test drives
  #   ai_refire and bd_at on the shipped bytes over both.
  # missile: what a monster's missile does when it lands -- A_Explode for the
  #   rocket and only the rocket (info.c hangs it off S_EXPLODE1, and the two
  #   fireballs' burst chains carry no action), MT_ROCKET's double flight rate,
  #   and PIT_RadiusAttack's "Boss spider and cyborg take no damage from
  #   concussion", which this port simply did not have (2026-08-20).
  # switch: P_ChangeSwitchTexture. sw_swap probes the seg's WALL byte and then
  #   its LOWER byte, but $3F is "no texture", not a texid, and MAP_TEXSWMATE is
  #   63 entries wide -- so index $3F read the row after it and the empty wall
  #   byte ATE the swap on every switch that sits on a lower texture. Nine maps
  #   (E1M8, E2M1/5/7/8, E3M1/2/4/9) fired their action and stayed dark, and
  #   nothing in the build could say so. The test runs the shipped sw_swap on the
  #   real textab + seg bytes of every USE switch line in the set, S1 vs SR
  #   button included (2026-08-20).
                 'title', 'msg', 'spectre', 'flinch', 'deathsnd', 'pjz',
  # caco: the CACODEMON's attack (2026-08-20). mk_atk was 0 for MT_HEAD, so it
  #   chased the player through thirteen levels and could never touch him --
  #   and nothing in the build says so, because a monster that does not fight
  #   assembles exactly like one that does. The test drives bl_pick/bl_roll/
  #   ai_fire/ai_cdmg on the shipped bytes, checks the .things header carries
  #   BAL2 on exactly the cacodemon levels, and PINS the two documented melee
  #   reductions so they cannot drift unnoticed. It also guards the id layout
  #   at_tables.inc depends on: the four missile actions must stay at 3..6.
  # arena: the B1 sprite arena's PER-LEVEL reset (2026-08-25). FARENA is the
  #   frame-id -> arena-address residency table and it is runtime-only, so
  #   arena_init has to zero it at every level load -- but its clear is an
  #   `sta [zp_ptr],y` walk that never set zp_ptr+2, and the coltab run moved to
  #   bank $08 on 2026-08-21. From then on the clear wiped dead space at
  #   $08:FC00, FARENA kept the LAST level's table, and every frame id the new
  #   level reused answered "already resident": E1M2's barrel drew E1M1's imp
  #   fireball and health potion (ids 20/109 in both), swapping on its 6-tic
  #   idle ring. arena_prefetch had the mirror of it and read its FTAB rows out
  #   of bank $01 from the second id on. Nothing in the build fails on either:
  #   both blobs are correct, both guards pass, the wrong picture just appears.
                 'spidfire', 'missile', 'switch', 'caco', 'arena') {
    # a missing test file is an ENVIRONMENT failure, not a test failure -- the
    # same treatment _verify_save gets below (2026-08-10: most of tools/tests
    # went missing and the E1M6 build died here instead of building)
    if (-not (Test-Path "tools/tests/_verify_$t.py")) {
      Write-Host "SKIP _verify_$t (tools/tests/_verify_$t.py is missing)" -ForegroundColor Yellow
      continue
    }
    # via cmd so the 2>&1 merge happens OUTSIDE PowerShell: with this script's
    # $ErrorActionPreference='Stop', a native command's stderr line becomes a
    # terminating NativeCommandError right at the assignment
    $tout = cmd /c "$py tools/tests/_verify_$t.py 2>&1"
    if ($LASTEXITCODE -ne 0) {
      # 2026-08-10: _prof_procs/_verify_bootload exist only as .pyc compiled by
      # a NEWER Python than the installed 3.12 ("bad magic number"), so these
      # two tests cannot even import on this machine -- and an unconditional
      # exit here killed every build and every wadconv conversion at the very
      # last fence. An ENVIRONMENT failure is a SKIP with a warning (the same
      # treatment _verify_save's missing file gets below); a real test failure
      # still stops the build.
      if (($tout -join "`n") -match 'bad magic number|ModuleNotFoundError') {
        Write-Host "SKIP _verify_$t (its .pyc harness was compiled by another Python version)" -ForegroundColor Yellow
      } else {
        $tout | Select-Object -Last 12
        Write-Error "_verify_$t failed"; exit 1
      }
    } else {
      $tout | Select-Object -Last 1
    }
  }
  # 2026-08-09: the file is not in the tree any more, and an unconditional call
  # to a missing script aborted the build HERE -- before the ATR was ever
  # written. The engine had meanwhile grown past the sector window, unseen.
  if (Test-Path "tools/tests/_verify_save.py") {
    & $py "tools/tests/_verify_save.py" | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { Write-Error '_verify_save failed'; exit 1 }
  } else {
    Write-Host 'SKIP _verify_save (tools/tests/_verify_save.py is missing)' -ForegroundColor Yellow
  }
  & $py tools\check_boot.py
  if ($LASTEXITCODE -ne 0) { Write-Error 'boot check failed -- this ATR would not boot'; exit 1 }
  Lap 'verify gates'
} else {
  Write-Host 'gates skipped: boot sim + _verify_* (-Check runs them)' -ForegroundColor DarkGray
}

Write-Host ("OK -> build/doom.atr  ({0:N1}s)" -f $swAll.Elapsed.TotalSeconds) -ForegroundColor Green
