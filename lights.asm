;==============================================================
; lights.asm -- SECTOR LIGHT: DOOM's light thinkers (p_lights.c) and the shade
;   every flat-painted surface goes through (r_main.c's scalelight).
; RAM BUDGET: see the RAM-BUDGET block at the top of memory_map.inc.
;
; WHAT IS SHADED, AND WHY NOT EVERYTHING
;   DOOM shades per PIXEL: R_DrawColumn reads dc_colormap[texel]. This port
;   cannot -- a textured wall is a VBXE blit straight out of VRAM, and the
;   blitter's whole per-pixel path is
;       c = (src AND andMask) XOR xorMask;  dst = c | c+d | c|d | c&d | c^d
;   (_pomocne/alt-src/Altirra/source/vbxe.cpp:3676 ff -- the authority, not the
;   register doc). There is no lookup in it. The one that looks promising, ADD
;   against a pre-filled destination, would need DOOM's colormap to be a
;   constant offset per light row, and it is not: at row 8 the most common
;   delta covers 30 of 256 entries, so ~88 % of the pixels would come out the
;   wrong colour. Pre-shaded copies of the textures are out too: a level's pool
;   is 148-284 KB against a 192 KB VRAM arena, so even two shades would thrash.
;   What the port CAN shade costs nothing: every surface it paints in ONE
;   palette index -- floors, ceilings, and any wall drawn flat (the 'T' mode, a
;   texture whose pixels this build does not ship, the untextured fallback).
;   That is the floor and the ceiling of every room, i.e. the surfaces a
;   flickering lamp is actually seen on. Textured walls stay at full bright.
;
; THE SHADE ITSELF IS DOOM'S OWN
;   row = (255 - sector->lightlevel) >> 3, into the real COLORMAP lump
;   (tools/pack_cmap.py -> CMAP_EXT). That is r_main.c's
;   lightnum = lightlevel >> LIGHTSEGSHIFT on the colormap's 32-row ladder,
;   with the distance term (zlight) dropped -- there is no per-column light
;   here, so a surface gets one row for its whole span.
;
; TIMING
;   DOOM runs these thinkers on 35 Hz tics. The port has no tic: like the doors
;   (DOOR_DWELL_VB) every counter is in PAL VBLANKs and each frame subtracts
;   fps_n, so the rates hold at any frame rate. pack_map.py converted the two
;   constants that come from the map (FASTDARK 15 -> 21, SLOWDARK 35 -> 50).
;
; THE RECORD (pack_map.py _lights, LIGHT_SIZE bytes, in the map's SEG bank):
;   +0 sector   +1 kind (bit6 = glow going up, bit7 = strobe in sync)
;   +2 minlight +3 maxlight  +4 dark phase, VBLANKs  +5 countdown, VBLANKs
;   The last two bytes are WRITTEN at runtime: the bank is RAM, and the whole
;   region is re-streamed by every level load, so the state resets itself and
;   costs no base RAM (of which there are 179 B free in the machine).
;   2026-08-15: this table used to sit at the END of the EXT region, in bank
;   $01 -- and bank $01's next six pages from $6400 are the AI's per-thing
;   arrays (TH_HPL..TH_TICS). E1M1 has 4 thinkers and stayed clear; E1M2 has
;   26, ran 48 B into TH_HPL, and en_init's clear killed the last eight records
;   -- among them sector 180, the strobing wall by the secret door on the
;   staircase, which is why that one never blinked while every other light in
;   the game did. The SEG bank uses 15 KB of its 64 and has no such neighbour.
;==============================================================
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
                                     ;   no episode-1 map carries sector special
                                     ;   17 (checked over E1M1-E1M9: 29 flash,
                                     ;   26 strobe, 48 glow, 0 fire), and the
                                     ;   handler costs 52 B in a 384 B block.
                                     ;   pack_map packs it as a light flash off
                                     ;   the same minlight+16, which is what a
                                     ;   fire flicker looks like. If a PWAD ever
                                     ;   needs the real thing, p_lights.c
                                     ;   T_FireFlicker is 8 lines and this block
                                     ;   has room for it again once something
                                     ;   else leaves.
LT_DIR      equ $40                  ; glow: set = rising (we scribble the byte)
STROBE_VB   equ 7                    ; STROBEBRIGHT = 5 tics
FLASH_LONG  equ 93                   ; T_LightFlash's long bright: 65 tics.
                                     ;   DOOM's count is (P_Random()&maxtime)+1
                                     ;   with maxtime = 64 -- a MASK, so it is
                                     ;   1 or 65 tics and nothing in between.
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
.proc lt_init
        lda #<CMAP_EXT
        sta zp_cm
        lda #[CMAP_EXT>>16]
        sta zp_cm+2
        jmp an_init                  ; ...and the idle rings on frame A
.endp                                ;   (sprites.asm). Chained here, at the end
                                     ;   of init_level's mv_reset -> lt_init run:
                                     ;   the $1B00 block has one byte left, and
                                     ;   an_init MUST run where zp_ptr+2 is
                                     ;   already MAP_EXT_BANK and no loader is
                                     ;   mid-stream on zp_ptr                                ;   (sprites.asm). Chained here, at the end
                                     ;   of init_level's mv_reset -> lt_init run:
                                     ;   the $1B00 block has one byte left, and
                                     ;   an_init MUST run after it sets
                                     ;   zp_ptr+2 = MAP_EXT_BANK. Calling it from
                                     ;   load_dtab instead was the pink screen of
                                     ;   2026-08-07: read_ext walks zp_ptr, so
                                     ;   an_init landed in the middle of the
                                     ;   stream and load_los read from a pointer
                                     ;   it had moved.

;--------------------------------------------------------------
; lt_seg -- process_seg's front sector is in zp_ptr: pick this sector's
;   colormap row and shade the floor and ceiling colours with it.
;   Called once per drawn seg (~140 a frame). A/Y clobbered, X PRESERVED --
;   the caller is mid-way through resolving the wall texture handle.
;--------------------------------------------------------------
.proc lt_seg
        ldy #4                       ; sector->lightlevel
        lda (zp_ptr),y
        eor #$FF                     ; row = (255 - light) >> 3
        lsr @
        lsr @
        lsr @
        clc
        adc #>CMAP_EXT               ; ... a page per row, so the row IS the
        sta zp_cm+1                  ;     high byte (0..31 above the base)
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

;--------------------------------------------------------------
; update_lights -- one pass over the level's light thinkers, once a frame.
;   p_lights.c T_LightFlash / T_StrobeFlash / T_Glow / T_FireFlicker, with the
;   tic counters read as VBLANKs. Writes sector->lightlevel in the map slot;
;   nothing else in the engine touches that byte.
;--------------------------------------------------------------
.proc update_lights
        ldx MAP_HNLIGHT
        bne ?any
        rts
?any    stx lt_n
        lda fps_n                    ; VBLANKs this frame (frame_dt), clamped
        cmp #LT_DTMAX
        bcc ?dt
        lda #LT_DTMAX
?dt     sta lt_dt
        ldx #0                       ; X = BYTE offset of the record (pack_map
                                     ;     keeps the section inside one page)
?rec    lda.l LT_TAB+LT_SEC,x        ; zp_ptr = &MAP_SECTORS[sector]
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod                   ; sector*8 via shifts (tips #3)
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        lda.l LT_TAB+LT_KIND,x
        and #$0F
        cmp #LT_GLOW                 ; the glow ramps EVERY frame; the other
        bne ?timed                   ;   three are countdown-driven
        jmp ?glow
?timed
        lda.l LT_TAB+LT_CNT,x
        sec
        sbc lt_dt
        bcc ?fire                    ; ran out (or underflowed) -> switch
        beq ?fire
        sta.l LT_TAB+LT_CNT,x
        jmp ?next
?fire   lda.l LT_TAB+LT_KIND,x
        and #$0F
        cmp #LT_STROBE               ; flash and fire flicker share this path --
        bne ?flash                   ;   see LT_FIRE below

        ; --- T_StrobeFlash: min <-> max, bright STROBEBRIGHT, dark FAST/SLOW --
        lda.l LT_TAB+LT_MIN,x
        sta lt_t
        ldy #4
        cmp (zp_ptr),y               ; at minlight -> go bright
        bne ?dark
        lda.l LT_TAB+LT_MAX,x
        sta (zp_ptr),y
        lda #STROBE_VB
        bne ?setcnt                  ; (always)
?dark   lda lt_t
        sta (zp_ptr),y
        lda.l LT_TAB+LT_DARK,x
?setcnt sta.l LT_TAB+LT_CNT,x
        jmp ?next

        ; --- T_LightFlash: max <-> min on random counts --------------------
?flash  lda.l LT_TAB+LT_MAX,x
        ldy #4
        cmp (zp_ptr),y               ; at maxlight -> drop to min
        bne ?fbright
        lda.l LT_TAB+LT_MIN,x
        sta (zp_ptr),y
        lda RANDOM                   ; (P_Random()&mintime)+1, mintime = 7 tics
        and #7
        clc
        adc #2
        bne ?setcnt                  ; (always: >= 2)
?fbright sta (zp_ptr),y              ; A = maxlight, from the compare above
        lda RANDOM
        and #$40                     ; see FLASH_LONG: the mask IS the count
        beq ?fshort
        lda #FLASH_LONG
        bne ?setcnt
?fshort lda #2
        bne ?setcnt

        ; --- T_Glow: a triangle wave between min and max --------------------
?glow   lda lt_dt                    ; step = GLOW_STEP * dt
        asl @
        sta lt_t
        asl @
        clc
        adc lt_t                     ; 2*dt + 4*dt = 6*dt (dt <= 32)
        sta lt_t
        ldy #4
        lda.l LT_TAB+LT_KIND,x
        and #LT_DIR
        bne ?gup
        sec                          ; going DOWN
        lda (zp_ptr),y
        sbc lt_t
        bcc ?gmin                    ; wrapped past 0
        sta lt_u
        lda.l LT_TAB+LT_MIN,x
        cmp lt_u                     ; min < new -> keep falling
        bcc ?gput
?gmin   lda.l LT_TAB+LT_MIN,x        ; hit the floor: park and turn around
        sta lt_u
        lda.l LT_TAB+LT_KIND,x
        ora #LT_DIR
        sta.l LT_TAB+LT_KIND,x
?gput   lda lt_u
        sta (zp_ptr),y
        jmp ?next
?gup    clc                          ; going UP
        lda (zp_ptr),y
        adc lt_t
        bcs ?gmax                    ; past 255
        sta lt_u
        lda.l LT_TAB+LT_MAX,x
        cmp lt_u                     ; max >= new -> keep rising
        bcs ?gput
?gmax   lda.l LT_TAB+LT_MAX,x
        sta lt_u
        lda.l LT_TAB+LT_KIND,x
        and #[$FF-LT_DIR]
        sta.l LT_TAB+LT_KIND,x
        jmp ?gput

?next   txa
        clc
        adc #LIGHT_SIZE
        tax
        dec lt_n
        beq ?ret
        jmp ?rec
?ret    rts
.endp
                                     ;   segment never had to grow a byte.
lt_n    dta 0                        ; records left in this pass
lt_dt   dta 0                        ; VBLANKs this frame, clamped
lt_t    dta 0                        ; per-record scratch (step / candidate)
lt_u    dta 0
    .if * > LIGHTS_END+1
        ert 'lights.asm outgrew LIGHTS_BASE..LIGHTS_END (memory_map.inc)'
    .endif
