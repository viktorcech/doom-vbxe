; Part of bsp_main.asm -- AUTO-SPLIT out of it 2026-08-09, assembled in place via
; icl at the exact point the text was cut from, so every org and every block
; guard below is unchanged (verified: build/doom_bsp.xex is byte-identical).
;   the $8600 staging segment: the BCB templates, load_sprites/arena_init/arena_prefetch and load_things
;==============================================================
; BCB templates
;   2026-08-11 pm: STAGED in TEX_STAGE (BCBT_STAGE $1302), behind the XDL list --
;   setup_bcbs + setup_chains consume them at boot, BEFORE the first SIO stream
;   reclaims the page (exactly xdl.asm's deal; ram_map.py STAGED carries the
;   claim). Their old $8600 home is hud_pain's now (HUDPAIN_BASE): win2 is the
;   right price for a per-damage-event routine, a boot-dead table was wasting it.
;==============================================================
bcbt_resume = *
        org BCBT_STAGE
; vline: 1 px wide, height patched, colour via XOR (AND=0)
bcb_vline_tmpl
        dta $00,$00,$00              ; src addr
        dta a($0000)                 ; src stepY
        dta $00                      ; src stepX
        dta <VRAM_SCREEN             ; dst addr (patched)
        dta >VRAM_SCREEN
        dta [VRAM_SCREEN>>16]
        dta a(SCREEN_WIDTH)          ; dst stepY (down one row)
        dta $01                      ; dst stepX
        dta a(0)                     ; width-1 = 0 (1 px)
        dta 0                        ; height-1 (patched)
        dta $00                      ; AND
        dta $00                      ; XOR (colour, patched)
        dta $00,$00,$00
        dta BLT_COPY

; clear: full screen
bcb_clear_tmpl
        dta $00,$00,$00
        dta a($0000)
        dta $00
        dta <VRAM_SCREEN
        dta >VRAM_SCREEN
        dta [VRAM_SCREEN>>16]
        dta a(SCREEN_WIDTH)
        dta $01
        dta a(SCREEN_WIDTH-1)
        dta VIEW_HEIGHT-1            ; clear only the 3D view; the bar owns the rest
        dta $00                      ; AND
        dta $00                      ; XOR (colour, patched)
        dta $00,$00,$00
        dta BLT_COPY

; sprite column: 1 byte wide, source = a column of the sprite (or of the
; expanded scratch), BLT_BSTENCIL so index-0 texels are left alone = transparent
bcb_spr_tmpl
        dta $00,$00,$00              ; SRC_ADDR (patched per column, all 3 bytes:
                                     ;   the sprite pool has no fixed bank since
                                     ;   the per-level split, atr_levels.inc)
        dta a(1)                     ; SRC_STEPY (patched = samples per row)
        dta 0                        ; SRC_STEPX = 0 (single column)
        dta <VRAM_SCREEN             ; DST_ADDR (patched)
        dta >VRAM_SCREEN
        dta [VRAM_SCREEN>>16]
        dta a(SCREEN_WIDTH)          ; DST_STEPY (down one row)
        dta 1                        ; DST_STEPX
        dta a(0)                     ; WIDTH-1 = 0 (1 byte / LR column)
        dta 0                        ; HEIGHT-1 (patched = dest rows - 1)
        dta $FF                      ; AND
        dta $00                      ; XOR
        dta $00                      ; COLLIDE
        dta $00                      ; ZOOM (the S-expanded source carries it)
        dta $00                      ; PATTERN
        dta BLT_BSTENCIL             ; CTRL: skip source bytes == 0
    .if * > $1400
        ert 'BCB templates outgrew the TEX_STAGE tail (BCBT_STAGE..$13FF)'
    .endif

; The two one-shot THINGS loaders live up here rather than in the packed $2000
; segment (which butts against the streamed map at $4000): they run once at boot.
        org $8640

;--------------------------------------------------------------
; load_sprites -- B1 (docs/VRAM-PLAN.md par.5): the .spr never lands in VRAM.
;   The FIRST visit reads the slot's sectors into the staging buffer purely
;   so read_sectors' TEE parks them in SDRAM -- the arena (spr_fget) fetches
;   frames from there. A REVISIT skips even that: the tee already holds the
;   file (ld_src, set by load_level_c from lvl_res).
;   Parked at SPRLD2_BASE, below $C000 like every SIOV driver. 2026-08-17
;   that is a win2 hole (read_sectors' old one): this is a per-PASS driver,
;   the per-byte work is read_sectors' -- which took this proc's fast run.
;--------------------------------------------------------------
sprld2_resume = *
        org SPRLD2_BASE
.proc load_sprites
        rts                          ; B2 (2026-08-18): the sprite pool rides
.endp                                ;   the POOL region -- load_textures'
                                     ;   drain streams it with the textures,
                                     ;   so nothing per-level is sprite-shaped
                                     ;   any more (LVL_SPRCH died with the
                                     ;   atr_levels.inc tables). The hole this
                                     ;   frees (SPRLD2_BASE..END) is free RAM.
    .if * > SPRLD2_END+1
        ert 'load_sprites outgrew SPRLD2_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; arena_init -- the per-level B1 reset, chained off load_sprcol: FARENA
;   cleared, the arena bounds set from the level's texture chunks, the SDRAM
;   base of its .spr from LVL_SPRSD. zp_ptr+2 is still MAP_EXT_BANK here
;   (read_ext parked it).
;   Kept in the fast run when load_sprites left it (ARINIT, 2026-08-17): the
;   768-iteration FARENA clear is the one loader loop that did NOT move to
;   win2.
;--------------------------------------------------------------
        org ARINIT_BASE
.proc arena_init
        lda #MAP_EXT_BANK            ; load_sprcol streamed into bank $08 and
        sta ll_bank                  ;   left ll_bank there; its own block is
                                     ;   47 B and had no room to put it back
        sta zp_ptr+2                 ; ...AND THE SAME FOR zp_ptr+2 (2026-08-25).
                                     ;   read_ext parks ll_bank in zp_ptr+2 on
                                     ;   every pass, so the .sprcol stream leaves
                                     ;   it on SPRCOL_BANK ($08) -- it was $01
                                     ;   until the coltab run left bank $01
                                     ;   (2026-08-21). The FARENA clear below is
                                     ;   an [zp_ptr],y walk: with the stale bank
                                     ;   it wiped 768 B of dead space at
                                     ;   $08:FC00 and FARENA at $01:FC00 KEPT THE
                                     ;   PREVIOUS LEVEL'S RESIDENCY. Every frame
                                     ;   id the last level had cached then read
                                     ;   "already in the arena" here, so
                                     ;   arena_prefetch copied nothing and the
                                     ;   new level drew the OLD level's pixels
                                     ;   for that id: E1M2's barrel (frame 20/109)
                                     ;   came out as E1M1's imp fireball and
                                     ;   health potion (frame 20/109 THERE),
                                     ;   flickering between the two on the
                                     ;   barrel's own 6-tic idle ring.
        lda #<FARENA_EXT             ; FARENA is 765 B ($01:FC00-$FEFC), so three
        sta zp_ptr                   ;   pages cover it. The fourth ($FF00, the
        lda #>FARENA_EXT             ;   old TEXAR) went with the texture arena
        sta zp_ptr+1                 ;   (2026-08-14) and is free bank-$01 RAM.
        ldx #3
        lda #0
        tay
?clb    sta [zp_ptr],y
        iny
        bne ?clb
        inc zp_ptr+1
        dex
        bne ?clb
        sta ar_base                  ; the ONE arena: sprites at $018000, ceiling
        sta ar_bump                  ;   ARENA_SPR_TOP $03D000 (A = 0 here)
        lda #[[ARENA_SPR_BASE>>8]&$FF]
        sta ar_base+1
        sta ar_bump+1
        lda #[ARENA_SPR_BASE>>16]
        sta ar_base+2
        sta ar_bump+2
        lda #<LVL_SPRSD_C            ; B2 (2026-08-18): both pools are SHARED,
        sta spr_sdram                ;   so the homes are build CONSTANTS
        lda #>LVL_SPRSD_C            ;   (atr_levels.inc equs) -- the per-level
        sta spr_sdram+1              ;   tables died with the 10-level build
        lda #[LVL_SPRSD_C>>16]       ;   (they ran WEAPLD2 into PJHK_BASE)
        sta spr_sdram+2
        lda #<LVL_TEXSD_C
        sta tex_sdram
        lda #>LVL_TEXSD_C
        sta tex_sdram+1
        lda #[LVL_TEXSD_C>>16]
        sta tex_sdram+2
        jmp arena_prefetch           ; warm both arenas NOW (load time), so
.endp                                ;   play has no first-look copy hitches

;--------------------------------------------------------------
; arena_prefetch -- fetch every sprite frame into the arena at LEVEL LOAD, in
;   id order, until one would not fit. That is the whole difference between
;   "smooth like the preload builds" and a copy hitch at every first sight:
;   E1M1 and E1M2 (141/145 KB) fit the 148 KB arena, so on those two sprites
;   never fetch in play at all. The other 25 maps do NOT -- with all three
;   episodes packed a set is 166-537 KB (E3M9), so the warmup fills what it can
;   and the tail stays lazy; that is by design, wadconv.py reports it as ok
;   ("the game runs, a full bestiary tour flushes the arena"). The loop
;   room-checks itself so it never triggers a flush. (It warmed the TEXTURE arena too until 2026-08-14; with TEX_RUNS=1
;   painted walls read their runs straight out of SDRAM, so there has been
;   nothing to warm there since -- see the deleted B2 arena in spr_draw.asm.)
;   LOAD-time cost: ~150 KB through the window, ~0.1-0.3 s -- invisible next
;   to the SIO. Parked at APREF_BASE (the slow $8000+ window: fine here).
;--------------------------------------------------------------
apref_resume = *
        org APREF_BASE
.proc arena_prefetch
        stz apf_i                    ; (stz/the ora loop below buy the 4 B the
?spr    stz zp_ptr+1                 ;  bank store costs: $80F5 is mtx_pegf's)
        lda apf_i                    ; FTAB[id]: zp_ptr = FTAB_EXT + id*8
        sta zp_ptr
        asl zp_ptr
        rol zp_ptr+1
        asl zp_ptr
        rol zp_ptr+1
        asl zp_ptr
        rol zp_ptr+1
        clc
        lda zp_ptr
        adc #<FTAB_EXT
        sta zp_ptr
        lda zp_ptr+1
        adc #>FTAB_EXT
        sta zp_ptr+1
        lda #SPRCOL_BANK             ; 2026-08-25: the FTAB is in bank $08 and
        sta zp_ptr+2                 ;   THIS loop never said so -- it rode the
                                     ;   bank read_ext happened to leave behind.
                                     ;   spr_fget parks zp_ptr+2 on MAP_EXT_BANK
                                     ;   (the FARENA half), so from the SECOND
                                     ;   id on the row was read out of bank $01
                                     ;   at $E000 -- free SRAM. Zeros there ended
                                     ;   the walk after one frame (the prefetch
                                     ;   did nothing and every frame fetched
                                     ;   lazily in play); non-zero junk would
                                     ;   have handed spr_fcopy a junk size.
        ldy #6                       ; an all-zero entry ends the frame list
        lda #0                       ;   (bytes 0..6 -- byte 7 is the pad).
?z      ora [zp_ptr],y               ;   Rolled up from seven straight-line
        dey                          ;   reads: X is dead here, so tax is the
        bpl ?z                       ;   cheapest way to keep the OR's Z flag
        tax                          ;   across the dey/bpl that ends the walk
        beq ?tex
        ldy #3                       ; room-check bump + size vs the sprite
        clc                          ;   top OURSELVES: the prefetch must not
        lda ar_bump                  ;   flush what it just warmed
        adc [zp_ptr],y
        sta apf_t
        iny
        lda ar_bump+1
        adc [zp_ptr],y
        sta apf_t+1
        lda ar_bump+2
        adc #0
        cmp #[ARENA_SPR_TOP>>16]
        bcc ?fit
        bne ?tex                     ; would not fit: leave the tail lazy
        lda apf_t+1                  ; same bank: the middle byte decides. See
        cmp #[[ARENA_SPR_TOP>>8]&$FF];   spr_fget's copy of this test -- the
        bcc ?fit                     ;   old `ora apf_t` only held while the top
        bne ?tex                     ;   was 64 KB-aligned, and it stopped being
        lda apf_t                    ;   that on 2026-08-18 (the EPISODE menu).
        bne ?tex
?fit    lda apf_i
        jsr spr_fget                 ; a guaranteed miss: copies the frame in
        inc apf_i
        bne ?spr                     ; (255 entries at most)
?tex    rts                          ; the frame list ended, or the next frame
                                     ;   would not fit: leave the tail lazy
.endp
apf_i   dta 0
apf_t   dta 0,0
    .if * > APREF_END+1
        ert 'arena_prefetch outgrew APREF_BASE..END (memory_map.inc)'
    .endif
        org apref_resume
    .if * > ARINIT_END+1
        ert 'arena_init outgrew ARINIT_BASE..END (memory_map.inc)'
    .endif
        org sprld2_resume

;--------------------------------------------------------------
; load_things -- stream the .things blob into THINGS_BASE ($B000) and cache the
;   three table pointers from its header. MUST run after load_textures /
;   load_sprites: they use the same RAM as their SIO staging buffer. From here
;   on $B000 holds live data (also PLAYPAL, which setup_palette reads).
;--------------------------------------------------------------
.proc load_things
        lda #<THG_SEC1
        sta ll_sec
        lda #>THG_SEC1
        sta ll_sec+1
        lda #<THG_SECTORS            ; level n's .things is THG_SECTORS further along
        sta ll_stride
        lda #>THG_SECTORS
        sta ll_stride+1
        jsr lvl_offset
        lda #THG_SECTORS             ; the blob lives UNDER the ROM ($C000) -- it
        sta ll_left                  ; outgrew the old $BAC0 hole once the build was
        lda #<THINGS_BASE            ; a whole episode, so it stages across like the
                                     ; map's HIGH region
        sta ll_dst
        lda #>THINGS_BASE
        sta ll_dst+1
        jsr read_urom
                                     ; (the blob's header -> th_ss/th_things/th_sprtab
                                     ;  is copied by init_level, which runs with the
                                     ;  ROM already banked out)
        ldx #31                      ; every thing starts un-collected (bitmap,
        lda #$FF                     ;   1 bit per thing: 256 things in 32 B)
?al     sta THING_ALIVE,x
        dex
        bpl ?al
        lda ps_started               ; ONLY at boot. load_things runs on every
        bne ?keysonly                ;   level load, and wiping PSTATE there sent
        inc ps_started               ;   the player into the NEXT level with 100 hp, a
        ldx #8                       ;   pistol and no shells. DOOM keeps all of
        lda #0                       ;   that: G_PlayerFinishLevel drops the
?ps     sta PSTATE-1,x               ;   POWERS and the CARDS and nothing else.
                                     ;   PSTATE-1 is pl_armt, the armortype: it
                                     ;   was put there so this loop clears it for
                                     ;   free ($0FDF..$0FE7 -- boot RAM is random
                                     ;   and a stale type would make the first
                                     ;   armour bonus the wrong colour)
        dex
        bpl ?ps
        sta PW_FLAGS                 ; G_PlayerReborn memsets the whole player, so
                                     ;   the BACKPACK and its doubled maxammo[] go
                                     ;   too -- only THIS path takes them back
        lda #START_HEALTH
        sta PSTATE+PS_HEALTH
        lda #START_BULLETS
        sta PSTATE+PS_BULLETS
        lda #START_WEAPONS           ; fist + pistol (DOOM's starting kit); the
        sta PSTATE+PS_WEAPONS        ;   bit number IS the wp_* id (weapon.asm)
        lda #WP_PISTOL               ; ...and the pistol is the one in your HANDS.
        sta wp_cur                   ;   Boot ONLY: from here on wp_init keeps
        jmp ?psdone                  ;   whatever wp_cur holds, so the weapon you
                                     ;   finish a level with carries into the next
                                     ;   one -- P_SetupPsprites, not a re-arm.
?keysonly lda #0                     ; a new level: the keys do NOT travel
        sta PSTATE+PS_KEYS
?psdone jsr pw_level                 ; ...and neither do the POWERS (the backpack
                                     ;   is not one -- powerups.asm)
        lda #1                       ; a fresh level: put his FEET on the spawn
        sta pl_snap                  ;   floor instead of dropping him into it
                                     ;   from wherever the last one left pl_z
        lda #0                       ; no mover running (RAM is random at boot --
        sta pl_dead                  ; ...and the player is alive, with a normal
        sta pl_keyw                  ; eye height. All three are read every frame,
        ldx #EYE_H                   ; so random RAM at boot would sink the view
        stx pl_vh                    ; or eat the first restart press
        sta mv_i                     ; a stale non-zero here would either freeze
        ldx #MV_TABEND-MV_TAB-1      ; every trigger or animate a random sector)
?mv     sta MV_TAB,x
        dex
        bpl ?mv
        jmp load_dtab                ; the death-frame table rides along (diskio):
.endp                                ;   still inside the SIO window, ROM in
ps_started dta 0                     ; 0 until the boot-time PSTATE init has run
        org bcbt_resume

