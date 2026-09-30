;--------------------------------------------------------------
; lights.asm -- sector light: DOOM's light thinkers (p_lights.c) and the colormap
;   shade of flat-painted surfaces. A blitted texture cannot be shaded.
;--------------------------------------------------------------
LT_SEC      equ 0                    ; record fields
LT_KIND     equ 1
LT_MIN      equ 2
LT_MAX      equ 3
LT_DARK     equ 4
LT_CNT      equ 5
LT_TAB      equ [MAP_SEG_BANK*$10000]+MAP_LIGHTS

LT_FLASH    equ 0                    ; kinds -- see tools/doomspecs.py
LT_STROBE   equ 1
LT_GLOW     equ 2
LT_FIRE     equ 3                    ; T_FireFlicker -- NOT its own path here:
                                     ;   no episode-1 map carries sector special ...
LT_DIR      equ $40                  ; glow: set = rising (we scribble the byte)
STROBE_VB   equ 7                    ; STROBEBRIGHT = 5 tics
FLASH_LONG  equ 93                   ; T_LightFlash's long bright: 65 tics.
GLOW_STEP   equ 6                    ; GLOWSPEED 8/tic = 5.6 units per VBLANK
LT_DTMAX    equ 32                   ; frame-delta clamp: a level-load hitch must
                                     ;   not slam every light, and GLOW_STEP*dt
                                     ;   has to stay inside a byte

;--------------------------------------------------------------
; lt_init -- per level (mv_reset tail-calls it, init_level's $1B00 block being
;   full to its last byte). Only the halves of zp_cm that never change: the
;   colormap is one 8 KB block at a fixed SRAM address, so the row index is a
;   single add on the HIGH byte (lt_seg).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lt_init
        lda #<CMAP_EXT
        sta zp_cm
        lda #[CMAP_EXT>>16]
        sta zp_cm+2
        bra an_init                  ; ...and the idle rings on frame A
.endp                                ;   (sprites.asm). Chained here, at the end
        .endseg
                                     ;   of init_level's mv_reset -> lt_init run: ...

;--------------------------------------------------------------
; lt_seg -- process_seg's front sector is in zp_ptr: pick this sector's
;   colormap row and shade the floor and ceiling colours with it.
;   Called once per drawn seg (~140 a frame). A/Y clobbered, X PRESERVED --
;   the caller is mid-way through resolving the wall texture handle.
;--------------------------------------------------------------
; 2026-09-28: DOOM's ladder (r_main.c scalelight / zlight), counted UP from
;   black: row = 60 - 4*lightnum - the rows the distance takes off. A WALL's
;   lightnum carries its fake contrast (rs_lcon) and its scale takes pc_dim
;   rows (paint_col's bake); a FLAT is one colour a sector, so it loses
;   zlight's mean over a view, LT_FLATDIM.
;   LT_ROW[i] = zp_cm's high byte for row 64 - i, clamped to the 32 rows;
;   i = 4*lightnum + rs_lcon + pc_dim, 0..68+23.
LT_FLATDIM  equ 8
LT_PAGE     equ [CMAP_EXT>>8]&$FF
        .segment D0
LT_ROW  :33 dta LT_PAGE+31           ; i = 0..32: darker than row 31 is row 31
        :32 dta LT_PAGE+31-#         ; i = 33..64
        :27 dta LT_PAGE              ; i = 65..91
        .endseg

;--------------------------------------------------------------
; lt_seg_flash -- lt_seg while the muzzle flash lights: r_segs.c adds
;   extralight to lightnum, EXTRALIGHT holds it in light units (WS_LIGHT).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lt_seg_flash
        ldy #4
        lda (zp_ptr),y
        clc
        adc EXTRALIGHT
        bcc lt_seg.lts_l
        lda #$FF                     ; (lightnum stops at 15)
        bra lt_seg.lts_l
.endp
.proc lt_seg
                                      ; 2026-09-22: no visor test -- the visor is a
        ldy #4                       ;   per-TIC fact, so lt_pick points process_seg's
        lda (zp_ptr),y               ;   ltsj at lt_segv while it lights (-6 a seg)
lts_l   and #$F0
        lsr @
        lsr @                        ; 4*lightnum. C = 0: the mask cleared what falls out
        tay
        adc rs_lcon                  ; the walls' (<= 68: C = 0 out)
        sta rs_wlit
        lda LT_ROW+4+LT_FLATDIM,y    ; the flats' row
lts_add sta zp_cm+1                  ; (lt_segv joins here with row 0)
        ldy #5                       ; floor_pal @5
        lda (zp_ptr),y
        tay
        lda [zp_cm],y
        sta rs_floorcol
        ldy #6                       ; ceil_pal @6
        lda (zp_ptr),y
        tay
        lda [zp_cm],y
        sta rs_ceilcol
        lda rs_wlit                  ; the walls' row stays in zp_cm for the painter.
        adc pc_dim                   ;   C = 0 still: nothing above touches it (the
        tay                          ;   visor's index is >= 64 with either carry)
        lda LT_ROW,y
        sta zp_cm+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; lt_flat -- the colour of an UNTEXTURED wall ('T', or no pixels shipped): its
;   texture's dominant colour under the seg's light, at the flats' distance.
;   2026-09-28. IN: X = texid (kept). OUT: A. zp_cm is left as it was.
;--------------------------------------------------------------
        .segment B1
.proc lt_flat
        lda zp_cm+1
        pha
        ldy rs_wlit
        lda LT_ROW+LT_FLATDIM,y
        sta zp_cm+1
        ldy MAP_TEXDOM,x
        lda [zp_cm],y
        tay
        pla
        sta zp_cm+1
        tya
        rts
.endp
        .endseg

;--------------------------------------------------------------
; lt_segv -- lt_seg while the light-amp visor lights (p_user.c:371): every
;   surface full bright, colormap row 0 = the base page.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lt_segv
        lda #64                      ; (2026-09-28: LT_ROW[64 + pc_dim] is row 0 too)
        sta rs_wlit
        lda #>CMAP_EXT
        bra lt_seg.lts_add
.endp
        .endseg

;--------------------------------------------------------------
; lt_pick -- point process_seg's ltsj at the shade routine for THIS tic: the
;   visor outranks the muzzle flash's extralight, which outranks plain light.
;   pw_tic calls it when vis_lit changes, wp_flight when EXTRALIGHT does.
;   Clobbers A/X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lt_pick
        rep #$20
        .LONGA ON
        lda #lt_segv
        ldx vis_lit
        bne ?set
        lda #lt_seg
        ldx EXTRALIGHT
        beq ?set
        lda #lt_seg_flash
?set    sta.l B1CODE_BASE+process_seg.ltsj+1
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; THE GAMMA KEY (2026-09-28) -- DOOM's F11, '8' here. m_menu.c steps usegamma
;   0..4 and I_SetPalette sends every colour through gammatable[usegamma]
;   (v_video.c), level 0 too. The tables and the PLAYPAL slots, as R/G/B
;   planes, are in SDRAM (GAMMA_EXT / PALRAW_EXT, tools/doomgamma.py): the
;   colour is the index of every read. Nothing here runs in a frame.
;--------------------------------------------------------------
GM_MSG0     equ 37+MSG_IDX0          ; GAMMALVL0's line (pack_menu.py)
        .segment D0
gm_lvl  dta 0                        ; usegamma
; PAL_SLOTS (pack_textures.py) -> VBXE palette. The XDL names one of these and
; update_flash swaps between them, so the order here IS the FL_PAL_* map in
; memory_map.inc: normal, damage red, pickup gold.
pld_psel dta 1, 2, 3                 ; ...and NEVER palette 0: see FL_PAL_GOLD
gm_page :PAL_COUNT dta [[PALRAW_EXT>>8]&$FF]+3*#  ; the slot's R plane: a page a plane
        .endseg
    .if [PALRAW_EXT & $FF] | [GAMMA_EXT & $FF]
        ert 'gm_apply: GAMMA_EXT and PALRAW_EXT must start on a page'
    .endif
        .segment B1
.proc gm_next                        ; the key: the next level, its line ...
        ldx gm_lvl
        inx
        cpx #5
        bcc ?k
        ldx #0
?k      stx gm_lvl
        txa
        clc                          ; (C = 1 on the wrap)
        adc #GM_MSG0
        jsr msg_set.msg_arm
        ert *<>gm_apply              ; ... and its palettes: falls through
.endp
; gm_apply -- every PLAYPAL slot into its VBXE palette, through usegamma's
;   table. 8-bit on purpose: the boot installs the palettes through here too
;   (load_palette_w1). Clobbers A/X/Y; zp_ptr is parked.
.proc gm_apply
        pei (zp_ptr)
        lda zp_ptr+2
        pha
        stz zp_ptr                   ; [zp_ptr],y = gammatable[usegamma][y]
        clc
        lda gm_lvl
        adc #>GAMMA_EXT
        sta zp_ptr+1
        lda #[GAMMA_EXT>>16]
        sta zp_ptr+2
        ldx #PAL_COUNT-1
?pal    lda pld_psel,x
        sta VBXE_PSEL
        stz VBXE_CSEL
        lda gm_page,x                ; the slot's three planes into the readers
        sta.l B1CODE_BASE+?r+2
        inc @
        sta.l B1CODE_BASE+?g+2
        inc @
        sta.l B1CODE_BASE+?b+2
        phx
        ldx #0                       ; X = the colour, counting up to the wrap:
?r      lda.l PALRAW_EXT,x           ;   CSEL steps the same way
        tay
        lda [zp_ptr],y
        sta VBXE_CR                  ; (plain abs: no indexed dummy read of the chip)
?g      lda.l PALRAW_EXT,x
        tay
        lda [zp_ptr],y
        sta VBXE_CG
?b      lda.l PALRAW_EXT,x
        tay
        lda [zp_ptr],y
        sta VBXE_CB                  ; commits the colour, CSEL steps
        inx
        bne ?r
        plx
        dex
        bpl ?pal
        pla
        sta zp_ptr+2
        pla                          ; (pei pushed the word: its low byte comes first)
        sta zp_ptr
        pla
        sta zp_ptr+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; update_lights -- one pass over the level's light thinkers, once a frame.
;   p_lights.c T_LightFlash / T_StrobeFlash / T_Glow / T_FireFlicker, with the
;   tic counters read as VBLANKs. Writes sector->lightlevel in the map slot;
;   nothing else in the engine touches that byte.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_lights
                                      ; 2026-09-22 (skills pass): zp_ptr points AT the
        ldx MAP_HNLIGHT              ;   lightlevel (+4), so every access is (zp_ptr)
        bne ?any                     ;   and Y is free to hold the record's kind byte
        rts                          ;   -- no ldy #4, no re-read of LT_KIND
?any    stx lt_n
        lda dt_vbl                    ; VBLANKs this frame (frame_dt), clamped
        cmp #LT_DTMAX
        bcc ?dt
        lda #LT_DTMAX
?dt     sta lt_dt
        asl                          ; the glow step 6*dt, once for the pass
        sta lt_t
        asl                          ; (C = 0: dt <= 32)
        adc lt_t
        sta lt_t
        ldx #0                       ; X = BYTE offset of the record (pack_map
                                     ;     keeps the section inside one page)
?rec    lda.l LT_TAB+LT_SEC,x        ; zp_ptr = &MAP_SECTORS[sector].lightlevel
        rep #$20
        .LONGA ON
        and #$00ff
        asl
        asl
        asl                          ; (C = 0: sector*4 < $8000)
        adc #MAP_SECTORS+4
        sta zp_ptr
        sep #$20
        .LONGA OFF
        lda.l LT_TAB+LT_KIND,x
        tay                          ; Y = the kind byte, for the whole record
        and #$0F
        cmp #LT_GLOW                 ; the glow ramps EVERY frame; the other
        jeq ?glow                    ;   three are countdown-driven
        lda.l LT_TAB+LT_CNT,x
        sec
        sbc lt_dt
        bcc ?fire                    ; ran out (or underflowed) -> switch
        beq ?fire
        sta.l LT_TAB+LT_CNT,x
        jmp ?next
?fire   tya
        and #$0F
        cmp #LT_STROBE               ; flash and fire flicker share this path
        bne ?flash
        lda.l LT_TAB+LT_MIN,x        ; --- T_StrobeFlash: min <-> max
        cmp (zp_ptr)                 ; at minlight -> go bright
        bne ?dark
        lda.l LT_TAB+LT_MAX,x
        sta (zp_ptr)
        lda #STROBE_VB
        bra ?setcnt
?dark   sta (zp_ptr)                 ; A = minlight still
        lda.l LT_TAB+LT_DARK,x
?setcnt sta.l LT_TAB+LT_CNT,x
        jmp ?next
?flash  lda.l LT_TAB+LT_MAX,x        ; --- T_LightFlash: max <-> min, random counts
        cmp (zp_ptr)                 ; at maxlight -> drop to min
        bne ?fbright
        lda.l LT_TAB+LT_MIN,x
        sta (zp_ptr)
        lda RANDOM                   ; (P_Random()&mintime)+1, mintime = 7 tics
        and #7
        adc #2-1                     ; C = 1: the cmp above was equal
        bra ?setcnt
?fbright sta (zp_ptr)                ; A = maxlight, from the compare above
        lda #FLASH_LONG
        bit RANDOM
        bvs ?setcnt
        lda #2
        bra ?setcnt
?glow   tya                          ; --- T_Glow: a triangle wave, min..max
        and #LT_DIR
        bne ?gup
        lda (zp_ptr)                 ; going DOWN. C = 1 already: cmp #LT_GLOW was
        sbc lt_t                     ;   equal, and tya/and/bne keep it
        bcc ?gmin                    ; wrapped past 0
        cmp.l LT_TAB+LT_MIN,x
        bcc ?gmin
        beq ?gmin
        sta (zp_ptr)
        bra ?next
?gmin   lda.l LT_TAB+LT_MIN,x        ; hit the floor: park and turn around
        sta (zp_ptr)
        tya
        ora #LT_DIR
        sta.l LT_TAB+LT_KIND,x
        bra ?next
?gup    clc                          ; going UP (C = 1 from the cmp: clear it)
        lda (zp_ptr)
        adc lt_t
        bcs ?gmax                    ; past 255
        cmp.l LT_TAB+LT_MAX,x
        bcs ?gmax
        sta (zp_ptr)
        bra ?next
?gmax   lda.l LT_TAB+LT_MAX,x
        sta (zp_ptr)
        tya
        and #[$FF-LT_DIR]
        sta.l LT_TAB+LT_KIND,x
?next   txa
        clc
        adc #LIGHT_SIZE
        tax
        dec lt_n
        jne ?rec
        rts
.endp
        .endseg
                                     ;   segment never had to grow a byte.
; (lt_n / lt_dt / lt_t moved to memory_map.inc's D0 block, 2026-09-26: out of the
;  $6780 write-through window -- update_lights stores them every frame)
	;nothing, unreferenced variable removed
    .if * > LIGHTS_END+1
        ert 'lights.asm outgrew LIGHTS_BASE..LIGHTS_END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; THE MUZZLE FLASH (A_Light1/A_Light2, 2026-08-31 -- see the FLASH banner in
; memory_map.inc). Two procs, both OUTSIDE every per-frame path:
;--------------------------------------------------------------
ltsf_resume = *
        org LTSEGF_BASE
                                     ; (2026-09-28: lt_seg_flash sits ahead of lt_seg,
                                     ;   in the reach of a branch)
;--------------------------------------------------------------
; wp_flight -- wp_fenter's tail (P_SetPsprite for ps_flash ends here): read the
;   NEW flash state's extralight off WS_LIGHT and point process_seg's lt_seg
;   call at the right variant. Runs 2-4 times per SHOT, never per frame; the
;   win2 table read is as cold as the transition itself.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wp_flight
        ldy wp_fstate
                                      ; 2026-09-22: the target is lt_pick's call now
        ldx WS_LIGHT,y               ;   (the visor outranks the flash)
        stx EXTRALIGHT
        jmp lt_pick
.endp
        .endseg
    .if * > LTSEGF_END+1
        ert 'lt_seg_flash + wp_flight outgrew LTSEGF_BASE..END (memory_map.inc)'
    .endif
        org ltsf_resume
