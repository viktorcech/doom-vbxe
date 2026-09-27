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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lt_seg
                                      ; 2026-09-22: no visor test -- the visor is a
        ldy #4                       ;   per-TIC fact, so lt_pick points process_seg's
        lda (zp_ptr),y               ;   ltsj at lt_segv while it lights (-6 a seg)
        lsr @                        ; row = (255-L)>>3 = (L>>3)^31; the row (bits
        lsr @                        ;   0-4) and >CMAP_EXT (bits 5-7) never overlap,
        lsr @                        ;   so ONE eor puts both in
        eor #[>CMAP_EXT]|$1F
    .if [>CMAP_EXT] & $1F
        ert 'lt_seg merges the row into >CMAP_EXT: its low five bits must be clear'
    .endif
lts_add sta zp_cm+1                  ; (lt_segv joins here with row 0)
        iny                          ; floor_pal @5
        lda (zp_ptr),y
        tay
        lda [zp_cm],y
        sta rs_floorcol
        ldy #6                       ; ceil_pal @6
        lda (zp_ptr),y
        tay
        lda [zp_cm],y
        sta rs_ceilcol
        rts
.endp
        .endseg

;--------------------------------------------------------------
; lt_segv -- lt_seg while the light-amp visor lights (p_user.c:371): every
;   surface full bright, colormap row 0 = the base page.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc lt_segv
        ldy #4
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
        .segment B1                  ; DRAC_PLAN 2b: its only jump comes from process_seg (bank $01)
.proc lt_seg_flash
        ldy #4                       ; BUG FIX 2026-09-15: before the visor test, as
                                      ; 2026-09-22: never reached with the visor lit
        lda (zp_ptr),y
        eor #$FF                     ; row = (255 - light) >> 3
        lsr @
        lsr @
        lsr @
        sec                          ; ... minus the flash's 2 or 4 rows --
        sbc EXTRALIGHT               ;   DOOM's lightnum+extralight on this
        bcs ?cl                      ;   port's 32-row ladder
        lda #0                       ; brighter than row 0 IS row 0 (r_main.c
                                      ;   clamps lightnum the same way)
?cl     ora #>CMAP_EXT               ; 2026-09-22: ora as lt_seg (row 0..31, the base's
?st
        sta zp_cm+1
        iny                          ; floor_pal @5
        lda (zp_ptr),y
        tay
        lda [zp_cm],y
        sta rs_floorcol
        ldy #6                       ; ceil_pal @6
        lda (zp_ptr),y
        tay
        lda [zp_cm],y
        sta rs_ceilcol
        rts
.endp
        .endseg

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
