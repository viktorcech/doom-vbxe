;--------------------------------------------------------------
; Part of bsp_main.asm (icl in place): the BCB templates, load_sprites,
;   arena_init/arena_prefetch and load_things.
;--------------------------------------------------------------
bcbt_resume = *
        org BCBT_STAGE
; vline: 1 px wide, height patched, colour via XOR (AND=0)
bcb_vline_tmpl
        dta <VRAM_BCB_FF,>VRAM_BCB_FF,[VRAM_BCB_FF>>16]   ; src addr: ONE $FF byte,
                                     ;   steps 0 -> every pixel = ($FF AND and_mask)
                                     ;   XOR 0 = and_mask.
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
                                      ; DRAC_PLAN 3a: nothing lives here any more (the

;--------------------------------------------------------------
; load_sprites -- B1 (docs/VRAM-PLAN.md par.5): the .spr never lands in VRAM.
;--------------------------------------------------------------
sprld2_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_sprites
        rts                          ; B2 (2026-08-18): the sprite pool rides
.endp                                ;   the POOL region -- load_textures'
        .endseg
                                     ;   drain streams it with the textures, ...
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; arena_init -- the per-level B1 reset, chained off load_sprcol: FARENA
;   cleared, the arena bounds set from the level's texture chunks, the SDRAM
;   base of its .spr from LVL_SPRSD. zp_ptr+2 is still MAP_EXT_BANK here
;   (read_ext parked it).
;--------------------------------------------------------------
        org ARINIT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc arena_init
        lda #MAP_EXT_BANK            ; load_sprcol streamed into bank $08 and
        sta ll_bank                  ;   left ll_bank there; its own block is
                                     ;   47 B and had no room to put it back
        sta zp_ptr+2                 ; ...AND THE SAME FOR zp_ptr+2 (2026-08-25).
        lda #<FARENA_EXT             ; FARENA is 765 B ($01:FC00-$FEFC), so three
        sta zp_ptr                   ;   pages cover it. The fourth ($FF00, the
        lda #>FARENA_EXT             ;   old TEXAR) went with the texture arena
        sta zp_ptr+1                 ;   (2026-08-14) and is free bank-$01 RAM.
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
        ldx #3                       ;   two bytes a store, the page step 8-bit
        ldy #0                       ;   (a 16-bit inc would touch zp_ptr+2)
?clp    rep #$20
        .LONGA ON
        lda #$0000
?clb    sta [zp_ptr],y
        iny
        iny
        bne ?clb
        sep #$20
        .LONGA OFF
        inc zp_ptr+1
        dex
        bne ?clp                     ; A = 0 on the way out, as before
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
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>arena_prefetch       ;   next byte of this segment -- fall through
.endp                                ;   play has no first-look copy hitches
        .endseg

;--------------------------------------------------------------
; arena_prefetch -- fetch every sprite frame into the arena at LEVEL LOAD, in
;   id order, until one would not fit.
;--------------------------------------------------------------
apref_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc arena_prefetch
        stz apf_i                    ; (stz/the ora loop below buy the 4 B the
?spr    lda apf_i                    ; FTAB[id]: zp_ptr = FTAB_EXT + id*8, in A:
        asl                          ;   lo = (id<<3) & $FF, hi = >FTAB_EXT | (id>>5)
        asl                          ;   (<FTAB_EXT = 0 and id>>5 <= 7 sits in the
        asl                          ;   clear low bits of >FTAB_EXT, so the ora IS
        sta zp_ptr                   ;   the add: ert below). 30 cycles for the old
        lda apf_i                    ;   60 of asl/rol pairs on the cell.
        lsr
        lsr
        lsr
        lsr
        lsr
        ora #>FTAB_EXT
        sta zp_ptr+1
    .if [FTAB_EXT & $FF] != 0 || [[>FTAB_EXT] & 7] != 0
        ert 'arena_prefetch: FTAB_EXT is not $xx00 with >FTAB_EXT bits 0-2 clear -- put the adds back'
    .endif
        lda #SPRCOL_BANK             ; 2026-08-25: the FTAB is in bank $08 and
        sta zp_ptr+2                 ;   THIS loop never said so -- it rode the
                                     ;   bank read_ext happened to leave behind.
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
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
apf_i   dta 0
apf_t   dta 0,0
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        lda #THINGS_SECT             ; PIECE 1 only: the blob lives UNDER the ROM
        sta ll_left                  ; ($C000) -- it outgrew the old $BAC0 hole once
                                     ; the build was
        lda #<THINGS_BASE            ; a whole episode, so it stages across like the
                                     ; map's HIGH region
        sta ll_dst
        lda #>THINGS_BASE
        sta ll_dst+1
        jsr read_urom
                                     ; (the blob's header -> th_ss/th_things/th_sprtab ...
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
        bra ?psdone                  ;   whatever wp_cur holds, so the weapon you
                                     ;   finish a level with carries into the next
                                     ;   one -- P_SetupPsprites, not a re-arm.
                                      ; 2026-09-22 idiom: stz -- A is dead at ?psdone
?keysonly stz PSTATE+PS_KEYS         ;   (the other way in arrives with A = WP_PISTOL,
?psdone jsr pw_level                 ; ...and neither do the POWERS (the backpack
                                     ;   is not one -- powerups.asm)
        lda #1                       ; a fresh level: put his FEET on the spawn
        sta pl_snap                  ;   floor instead of dropping him into it
                                     ;   from wherever the last one left pl_z
                                      ; 2026-09-22 (drac030 stz): A is dead --
        stz pl_dead                  ;   load_things2 starts with a load
        stz pl_keyw
        ldx #EYE_H
        stx pl_vh
        stz mv_i
                                      ; 2026-09-23 BUG FIX: MV_TABEND-MV_TAB-1 = $C7 has bit 7
        ldx #MV_TABEND-MV_TAB        ;   set, so dex/bpl stopped after ONE byte. X = n..1
?mv     stz MV_TAB-1,x               ;   -> bytes n-1..0, dex/bne (n <= 255: ert below)
        dex
        bne ?mv
    .if MV_TABEND-MV_TAB > 255
        ert 'load_things clears MV_TAB with an 8-bit X: it must be <= 255 bytes'
    .endif
        jmp load_things2             ; the blob's PIECE 2 -> THINGS2_BASE, then on
.endp                                ;   into load_dtab: still inside the SIO
        .endseg
                                     ;   window, ROM in.
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
ps_started dta 0                     ; 0 until the boot-time PSTATE init has run
        .endseg
        org bcbt_resume

