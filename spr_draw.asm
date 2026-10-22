;--------------------------------------------------------------
; spr_draw.asm -- part of sprites.asm (icl in place): the drawing half --
;   spr_draw (back to front), spr_one, spr_blit.
;--------------------------------------------------------------
; spr_draw -- draw every collected sprite BACK TO FRONT, after the BSP walk has
;   painted the walls. spr_proj already keeps vs_ord sorted NEAR..FAR (insertion
;   into an almost-sorted list, since the BSP hands sprites over front-to-back),
;--------------------------------------------------------------
    .if * > SPRITES_END+1
        ert 'spr_add+spr_proj outgrew SPRITES_BASE..SPRITES_END (memory_map.inc)'
    .endif
        org SPRDRAW_BASE             ; 2026-08-11 win2 evacuation T2: the drawing
                                     ;   flow splits in three (memory_map.inc)
        .segment B1
.proc spr_draw
	ldy sp_n
	beq ?ret
?loop	dey			;save 10 bytes and 7 clock cycles per iteration
	phy			;eliminate static sp_oi (used only here)
	ldx vs_ord,y
	jsr spr_one
	ply
	bne ?loop
    .ifdef FX127
?ret    jmp ptc_fire                 ; launch the sprite links (textures.asm)
    .else
?ret    rts
    .endif
.endp
        .endseg

;--------------------------------------------------------------
; spr_one -- draw one vissprite (X = record offset). One blit per screen column.
;--------------------------------------------------------------
    .if * > SPRDRAW_END+1
        ert 'spr_draw outgrew SPRDRAW_BASE..SPRDRAW_END (memory_map.inc)'
    .endif
        org SPRONE_BASE
        .segment B1
.proc spr_one
        ldy vs_x1l,x		;eliminate one memory load lda sp_x1, replace with tya
	sty sp_x1		;save 3 bytes
        lda vs_x1h,x
        sta sp_x1+1
        bmi ?xa0                     ; xa = max(x1, 0), rebuilt instead of stored:
        tya	                    ; x1 >= 256 was rejected at collection, so the
        bra ?xas                     ; hi byte is either 0 (xa = the low byte, and
?xa0    lda #0                       ; it is < SCREEN_WIDTH) or negative (xa = 0)
?xas    sta sp_xa
        sta sp_col
    .ifdef FX127
        stz sp_col+1                 ; sp_col and sp_y0 are read as words
        stz sp_y0+1                  ;   (spr_clink): zero high bytes
    .endif
        lda vs_xb,x
        sta sp_xb
        lda vs_ytl,x
        sta sp_ytop
        lda vs_yth,x
        sta sp_ytop+1
        lda vs_sch,x                 ; scale, and hs = scale >> 1: the word is
        xba                          ;   assembled in C (hi first, then lo) and
        lda vs_scl,x                 ;   shifted in A, not in memory (drac030
        rep #$20                     ;   idiom)
        .LONGA ON
        sta sp_scale
        lsr @
        sta sp_hs
        .LONGA OFF
        sep #$20
        lda vs_cpl,x                 ; clip block (the pool is one page, hi = $07);
        tay                          ; bit 0 = ONE window for every column, and then
        and #$FE                     ; the per-column step is 0 instead of 2
        sta sp_clip                  ;   (parked in Y, not on the stack: 2026-09-15)
        lda #>CLIP_BASE
        sta sp_clip+1
        tya
        and #1
        eor #1
        asl
        sta sp_cstep
        lda vs_flip,x                ; REPLAY the projection-time rotation --
        sta sp_dfix                  ;   zp_rx/ry belong to another thing by now
                                     ;   (spr_wrot's fixed mode; bit7 doubles as
                                     ;   the mirror flag for the column loop)
        lda vs_th,x                  ; rebuild sp_ptr = THIS thing's record:
        jsr en_thing.en_th2          ;   wrot_idle reads the sid through it, and
                                     ;   by draw time it still points at the ...
        lda vs_th,x                  ; dying? -> sp_tab already points at the row
        jsr spr_shadow               ;   (preserves X). spr_shadow points the
                                     ;   sprite BCB at this thing's blit mode ...
        bcs ?have
        lda vs_sid,x                 ; live thing: sprite-table row AND the T4
        jsr spr_sidtab               ;   coltab pointer, both from the id
                                     ;   (SPRCROP block -- this segment is full)
?have   lda (sp_tab)                 ; byte 0 = the FRAME ID (B1): resolve it
        jsr spr_fget                 ;   to an arena address -- fetching the
                                     ;   pixels from SDRAM on the first look
                                     ;   -- and to its coltab (SPRCROP block)
        ldy #3
	rep #$20
        lda (sp_tab),y
        sta sp_w			;sp_h is sp_w+1, so OK to do word-store
	sep #$20			;save 3 cycles and 2 bytes
        lda #$FF                     ; no source column in the scratch yet: this
        sta sp_lastx                 ;   sprite may reuse the previous one's
                                     ;   column number at a different scale
  .ifdef ANTONIA2                    ; 2026-10-15 (6502-idioms: compute in A): h*scale
	rep #$21                     ;   on the card, bytes 1-2 of the product read
	.LONGA ON                    ;   straight into the add (C = 0 from the rep)
	lda sp_h
	and #$00FF
	sta.l ANT_MUL
	lda sp_scale
	sta.l ANT_MUL+2
	lda.l ANT_MUL+1
  .else
        lda sp_h                     ; rows on screen = (h*scale)>>8
        sta m_a
        stz m_a+1
        lda sp_scale
        sta m_b
        lda sp_scale+1
        sta m_b+1

        jsr umul16
	rep #$21		;switch to 16-bit A, clear C
        .LONGA ON
        lda m_prod+1		; bottom row = ytop + rows - 1
  .endif
;       sta sp_rows		;eliminate use of sp_rows here
        adc sp_ytop
	dec
        sta sp_ybot		; 5 inss, 11 bytes, 19 cycles, continue with 16-bit accumulator
  .ifndef FX127                    ; (FX127: the raycaster steps the texture rows itself)
        ; --- vertical rate ---------------------------------------------------
        ; The scratch holds S = 8 samples per texture row and SRC_STEPY alone carries
        ; the rate: spy = round(2048 / scale) samples per screen row.
  .ifdef ANTONIA2                    ; 2026-10-15: the 16-bit divide on the card
	lda sp_scale                 ;   (udiv24a_v2's ?fast16): (scale>>1) + $4000,
	lsr @                        ;   then the even scale itself -- no m_den cell
	clc                          ;   (6502-idioms: no RAM cell for a value that
	adc #$4000                   ;   only waits). C = 0 out of the adc (< $C000)
	sta.l ANT_DIV                ;   and the and keeps it -- no rep #$21 below
	lda sp_scale
	and #$FFFE
	sta.l ANT_DIV+2
	lda.l ANT_DIV
  .else
	lda sp_scale		;16-bit accumulator and M, continued
	and #$fffe
	sta m_den
;	sta sp_scale		;this gets updated in the original, but see comment below in the 8-bit section
        lsr
;       clc
        adc #$4000
        sta m_prod		;max. $7FFF+$4000=$BFFF, C always 0
                                     ; m_prod+2 = 0 through X (udiv24 loads X
	ldx #0                       ;   itself), so no sep here and no rep past
	stx m_prod+2                 ;   udiv24's entry (65816-windows)
	jsr udiv24.ud_w16
        .LONGA OFF

        ; 16-BIT A (2026-08-31, drac030 round two): this built (m_quot+4)>>3 by STORING the sum and ...
        UD16C                        ; (udiv24 hands back 16-bit A) C = 0 below
        .LONGA ON
        UDQ                          ; A = m_quot (2026-09-26: no reload)
  .endif
        adc #4                       ; rounding
        lsr @
        lsr @
        lsr @                        ; /8 -- in A, 2 cycles a shift
        bne ?spyok
        inc @                        ; never zero (65816 inc a)
?spyok  sta sp_spy
        ldx #8                       ; the scratch always holds 8 samples/texture row
	ldy sp_scale+1		;X/Y are still 8-bit, take advantage of that
	bne ?fine		;to avoid rep/sep
	ldy sp_scale
	cpy #65
	bcs ?fine
	ldx #1
                                      ; 2026-09-22 idiom: A IS sp_spy (?spyok stored it;
        lsr
        lsr
        lsr
        bne ?nz2
        inc                        ; never zero -- ALL 16 bits tested now
?nz2    sta sp_spy
?fine	stx sp_s
  .endif
  .ifdef ANTONIA2                    ; 2026-10-15: 65536/hs on the 16/16 card as
	lda #$FFFF                   ;   65535/hs, +1 when the remainder is hs-1
	sta.l ANT_DIV                ;   (65536 = 65535 + 1) -- exact, also for
	lda sp_hs                    ;   hs = 1 (the quotient wraps to 0 as
	sta.l ANT_DIV+2              ;   udiv24a_v2's does); then ustep * (xa-x1)
	lda.l ANT_DIV+2              ;   on the card, C = 0 into the loop as the
	inc @                        ;   rep #$21 left it
	cmp sp_hs
	lda.l ANT_DIV
	bcc ?nq
	inc @
?nq     sta sp_ustep
	sta.l ANT_MUL
	lda sp_xa
	and #$00ff
	sec
	sbc sp_x1
	sta.l ANT_MUL+2
	clc
	lda.l ANT_MUL
        sta sp_uacc
  .else
        stz m_prod
        ldy #1
        sty m_prod+2
        lda sp_hs
        sta m_den
        jsr udiv24.ud_w16            ; past udiv24's rep, still 16-bit (no sep/rep pair)
        .LONGA OFF

	UD16                         ; (udiv24 hands back 16-bit A)
	.LONGA ON
        UDQ                          ; A = m_quot (2026-09-26: no reload)
        sta sp_ustep
        sta m_b
	lda sp_xa
	and #$00ff
	sec
	sbc sp_x1
	sta m_a
	sep #$20
	.LONGA OFF
        jsr umul16

                                      ; 2026-09-21 (drac030 #37): this word copy sat between

; ===================== per-column loop =====================

	rep #$21		;clear C to avoid CLC below
	.LONGA ON
        lda m_prod                   ; sp_uacc = the product, as ONE word (lda/sta keep C)
        sta sp_uacc
  .endif
    .ifdef FX127                     ; the vertical step = ustep/2, 8.8 texture rows a
        lda sp_ustep                 ;   row, and -tpr split into the link's two
        lsr @                        ;   words (spr_clink); C = 0 into ?col
        sta sp_tpr
        eor #$FFFF
        inc @
        pha
        and #$7F00
        sta sp_st26
        pla
        xba
        and #$FF00
        sta sp_st5
        clc
    .endif
?col	lda (sp_clip)                ; this column's clip window
        sta sp_t		; write sp_t and sp_b, they're consecutive in memory
        lda sp_cstep                 ; 0 when one window covers the whole sprite
	and #$00ff
        adc sp_clip
        sta sp_clip
	sep #$20
	.LONGA OFF

; the spr_ncut seems called only once
; inline this to save jsr/rts overhead
;
	jsr spr_ncut                 ; a wall the walk reached LATER can still be
                                     ;   NEARER than this sprite: spr_ncut forces
                                     ;   sp_t to 255 for those columns
        lda sp_t
        cmp #255
	jeq ?cnext
	lda sp_uacc+1                ; source column = u >> 8
        cmp sp_w
        bcc ?tok
        lda sp_w
	dec
?tok    bit sp_dfix                  ; the mirrored profile (DOOM rot 7): the
        bpl ?nofl                    ;   SAME stored image, columns read from
        eor #$FF                     ;   the other end -- A = w-1-A (255-A+w
        clc                          ;   mod 256; A < w always, so it is exact)
        adc sp_w
?nofl   cmp sp_lastx
        beq ?haveco                  ; same source column as the previous one
        sta sp_lastx
        jsr spr_ctcol                ; T4: coltab[x] -> rs_tsrc (cropped column
                                     ;   base), sp_ctop/sp_clen -- and the 8x ...
    .ifdef FX127
?haveco lda sp_cbot                  ; an empty column (spr_ctcol)
        jeq ?cnext
        lda sp_rt+1                  ; y0 = max(the crop's first row, window top)
        bmi ?useT                    ;   -- negative: above the screen; positive:
        jne ?cnext                   ;   the crop starts under it
        lda sp_rt
        cmp sp_t
        bcs ?y0set
?useT   lda sp_t
?y0set  sta sp_y0
        lda sp_rb+1                  ; y1 = min(the crop's last row, window bottom)
        jmi ?cnext
        bne ?useB
        lda sp_rb
        cmp sp_b
        bcc ?y1set
?useB   lda sp_b
?y1set  sta sp_y1
        cmp sp_y0
        jcc ?cnext
        lda sp_two                   ; a column of two tiles?
        bne ?twol
        jsr spr_clink                ; the column's link (SPRCROP block)
    .else
?haveco lda sp_ytop+1                ; y0 = max(ytop, window top)
        bne ?useT                    ; negative (or off-screen, already rejected)
        lda sp_ytop
        cmp sp_t
        bcs ?y0set
?useT   lda sp_t
?y0set  sta sp_y0
        lda sp_ybot+1                ; y1 = min(ybot, window bottom)
	jmi ?cnext		;auto-shortened to bmi when in range
	bne ?useB
        lda sp_ybot
        cmp sp_b
        bcc ?y1set
?useB   lda sp_b
?y1set  sta sp_y1
        cmp sp_y0
        jcc ?cnext                   ; auto-shortened to bcc when in range

	rep #$20
	.LONGA ON
	lda sp_y0
	and #$00ff
;	sec
	sbc sp_ytop
	sta sp_q
	sep #$20
	.LONGA OFF
        jsr spr_cspan                ; T4 (SPRCROP block): raise q to the crop
        bcc ?cnext                   ;   top, y0 with it, cap the reads at the

        jsr spr_blit                 ;   stored end, sp_soff into the CROPPED
                                     ;   data -- C=0 = nothing left to draw.
    .endif
?cnext
	rep #$21		;switch to 16-bit acc. and clear C
	.LONGA ON
        lda sp_uacc
        adc sp_ustep
        sta sp_uacc

        ldy sp_col
        cpy sp_xb
        beq ?done
	iny			;if we are here, C=0
        sty sp_col
	jmp ?col

?done	sep #$20
	.LONGA OFF
	rts
    .ifdef FX127
?twol   jsr spr_two                  ; (out of line: the boss sprites' tallest
        bra ?cnext                   ;   columns)
    .endif
.endp
        .endseg

; (the spr_zm / spr_zoom pair lived here: z = 1,2,4,8 indexed by log2(z). z has
;  been fixed at 1 since 2026-08-04 -- see spr_one -- so both were read at index
;  0 only, i.e. 0 and $00.)

    .if * > SPRONE_END+1
        ert 'spr_one outgrew SPRONE_BASE..SPRONE_END (en_boomat at $75C0; memory_map.inc)'
    .endif

;--------------------------------------------------------------
; spr_blit -- one column slice: rows sp_y0..sp_y1 of column sp_col, source
;   sp_soff samples into the expanded scratch (S > 1) or into the raw sprite
;   column (S = 1), stepping SRC_STEPY = sp_spy. BLT_BSTENCIL drops index 0.
;   Relocated to SPRBLIT_BASE: the $B000 sprite block runs into hud.asm's
;   $B810 block, and the bigger vissprite table needed those bytes back.
;--------------------------------------------------------------
sb_resume = *
        org SPRBLIT_BASE
    .ifndef FX127                    ; (FX127: spr_clink, SPRCROP block)
        .segment B1
.proc spr_blit
        lda sp_s
        cmp #2
        bcs ?ex
                                      ; 2026-09-22 (rapidus-bus-timing): SRC lo/mid as ONE
        rep #$21                     ;   bus word, as the ?ex path (C = 0 either way:
        .LONGA ON                    ;   the bcs fell through)
        lda rs_tsrc                  ; SRC = sprite column + offset
        adc sp_soff
        sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone: the bank byte takes it)
        lda rs_tsrc+2
        bra ?srchi
?ex     rep #$21                     ; SRC = expanded scratch + offset. tw_base,
        .LONGA ON                    ;   not a constant: the expander alternates
        lda tw_base                  ;   between TWO scratches now (chains). The
        adc sp_soff                  ;   low word in one add and ONE chip-bus
        sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR   ; word write (drac030, 2026-09-14)
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        lda tw_base+2
?srchi	adc #0
	sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR+2
                                      ; 2026-09-22 (vbxe-blitter: write only what changes):
        ldx sp_y0                    ;   DST's bank byte is the FRAME's (ptc_frame stamps
        lda row_hi,x                 ;   zback_hi into it), so DST lo/mid is one bus word
        xba                          ;   in SRC_STEPY's block. A:B = row(y0) + column:
        lda row_lo,x                 ;   the carry goes into B by the xba pair
        clc                          ;   (<= $7CFF: no carry out)
        adc sp_col
        xba
        adc #0
        xba
        rep #$20
        .LONGA ON
        sta MEMW+MEMW_SP_OFF+BCB_DST_ADDR      ; [6-7]
        lda sp_spy                   ; [3-4] SRC_STEPY as one word
        sta MEMW+MEMW_SP_OFF+BCB_SRC_STEPY
        .LONGA OFF
        sep #$20
        lda sp_bh                    ; HEIGHT = source reads - 1
        sta MEMW+MEMW_SP_OFF+BCB_HEIGHT
                                      ; 2026-09-22 (vbxe-blitter): ZOOM = 0 is the template's
        jsr blitw_hard               ; a START while busy is silently dropped
    .ifdef FX127
        lda #<VRAM_BCB_SPR           ; (the templates share a page under FX127)
        sta VBXE_BL_ADR0
    .else
        stz VBXE_BL_ADR0             ; <VRAM_BCB_SPR = 0 and its bank byte too
    .if [VRAM_BCB_SPR & $FF] != 0
        ert 'VRAM_BCB_SPR moved off a page: put the lda #< back'
    .endif
    .endif
        lda #>VRAM_BCB_SPR
        sta VBXE_BL_ADR1
        stz VBXE_BL_ADR2
    .if [VRAM_BCB_SPR >> 16] != 0
        ert 'VRAM_BCB_SPR left bank 0: put the lda #>>16 back'
    .endif
        lda #1
        sta VBXE_BL_START
        rts
.endp
        .endseg
    .endif
    .if * > SPRBLIT_END+1
        ert 'spr_blit outgrew SPRBLIT_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; MF_SHADOW -- the spectre, drawn SEE-THROUGH (2026-08-16).
;==============================================================
FUZZ_OR equ $07                      ; how far down its ramp a pixel behind the
                                     ;   spectre slides.
        .segment D0

;--------------------------------------------------------------
; spr_shadow -- A = thing index, the way spr_dyn wants it. Points the sprite
;   BCB at this thing's blit mode and then IS spr_dyn (tail call, so A, X and
;   the carry come back exactly as before; Y is dead here).
;--------------------------------------------------------------
    .if F_FUZZ - $08
        ert 'spr_shadow shifts F_FUZZ into place -- it must be bit 3'
    .endif
    .if BLT_OR - [BLT_BSTENCIL | 2]
        ert 'spr_shadow derives CTRL by OR-ing the shifted flag into BLT_BSTENCIL'
    .endif
    .if FUZZ_OR & $F8
        ert 'FUZZ_OR must fit the low 3 bits (spr_shadow masks with EOR/AND)'
    .endif
        .endseg
        .segment B1
.proc spr_shadow
        pha                          ; spr_dyn wants the index back in A
        cmp #254
        bcs ?pseudo
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
;	clc
	adc th_things
	sta sp_tab
	sep #$20
	.LONGA OFF
        ldy #7
        lda (sp_tab),y
        and #F_FUZZ
    .ifdef FX127
?mode   tay                          ; park the flag; A gets shifted apart
        lsr
        lsr
        ora #BLT_BSTENCIL|BLT_NEXT|BLT_EXT   ; MODE 3 (OR) for the spectre
        sta sp_ctlw+1
        tya
        lsr
        lsr
        lsr
        dec                          ; AND: $00 = ignore the source (spectre),
        sta sp_andw+1                ;   $FF = the art straight through
        eor #$FF
        and #FUZZ_OR                 ; XOR: the constant the OR writes, or 0
        sta sp_xorw
        pla
        jmp spr_dyn
    .else
?mode   tay                          ; park the flag; A gets shifted apart
        lsr
        lsr
        ora #BLT_BSTENCIL            ; BLT_OR for the spectre
        sta MEMW+MEMW_SP_OFF+BCB_CTRL
        tya
        lsr
        lsr
        lsr
	dec
                                      ; 2026-09-22 (rapidus-bus-timing): AND [15] and XOR
        tay                          ;   [16] as ONE bus word (Y is dead here; C is the
        eor #$FF                     ;   last lsr's, as before -- rep/sep keep it)
        and #FUZZ_OR                 ; the constant the OR writes, or 0
        xba
        tya                          ; A = AND: $00 = ignore the source (spectre),
        rep #$20                     ;   $FF = the art straight through
        .LONGA ON
        sta MEMW+MEMW_SP_OFF+BCB_AND
        .LONGA OFF
        sep #$20
        pla
        jmp spr_dyn
    .endif

?pseudo lda #0                       ; no record to read: never a spectre
	bra ?mode
.endp
        .endseg

        org sb_resume                ; back to the $B000 sprite block

;==============================================================
; T4 COLUMN CROP + B1 SPRITE ARENA. The .spr
; file stores each column only from its first to its last opaque texture pixel and
; NEVER preloads: it sits in SDRAM (the level-cache tee) and spr_fget copies
; a frame into the VRAM arena above the level's textures on first use.
;==============================================================
scrop_resume = *
        org SPRCROP_BASE

;--------------------------------------------------------------
; spr_sidtab -- A = sprite id (a LIVE thing). sp_tab = th_sprtab + id*8.
;   Preserves X. (Lived inline in spr_one; the $B000 segment is full.)
;--------------------------------------------------------------
        .segment B1
.proc spr_sidtab
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
;	clc
	adc th_sprtab
	sta sp_tab
	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ar_alloc -- sp_addr = room for sf_size bytes at the arena's bump, which
;   moves past them. When they would not fit the arena is flushed first:
;   every frame out (FX127: every texture too), the bump back at the floor.
;   8-bit in and out; keeps X, Y and m_a (seg_draw holds the back sector in
;   it across tex_vget). (spr_fget's own until 2026-10-19: tex_vget allocates
;   the same way.)
;--------------------------------------------------------------
        .segment B1
.proc ar_alloc
    .ifdef FX127
        lda ar_bump+2                ; past the hole: only the top limits
        cmp #[ARENA_HOLE_END>>16]
        beq ?main
        pei (m_a)
        rep #$21
        .LONGA ON
        lda ar_bump                  ; (bump + size) >> 8, 16 bits: the low byte's
        and #$00FF                   ;   carry into it
        adc sf_size
        sta m_a                      ; (its low byte: the end's low byte)
        xba
        and #$00FF
        bcc ?nc
        ora #$0100
?nc     clc
        adc ar_bump+1                ; + (mid, bank)
        cmp #[ARENA_HOLE_LO>>8]
        bcc ?ok                      ; the end is under the hole
        bne ?skip
        lda m_a                      ; == its start: fits when the end's low
        and #$00FF                   ;   byte is 0
        beq ?ok
?skip   lda #ARENA_HOLE_END&$FFFF    ; over the hole
        sta ar_bump
        .LONGA OFF
        sep #$20
        lda #ARENA_HOLE_END>>16
        sta ar_bump+2
        rep #$20
        .LONGA ON
?ok     pla
        sta m_a
        .LONGA OFF
        sep #$20
?main
    .endif
        pei (m_a)
        rep #$21                     ; room? bump + size vs the ceiling: the low
        .LONGA ON                    ;   word in one add, its carry into the
        lda ar_bump                  ;   bank byte (drac030 idiom)
        adc sf_size
        sta m_a
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        lda ar_bump+2
        adc #0
        cmp #[ARENA_SPR_TOP>>16]
        bcc ?fits
        bne ?flush                   ; past the top bank: over
        lda m_a+1                    ; SAME BANK -- compare the MIDDLE byte too
        cmp #[[ARENA_SPR_TOP>>8]&$FF]
        bcc ?fits                    ; (the top is off a 64 KB boundary since
        bne ?flush                   ;   2026-08-18: the EPISODE menu)
        lda m_a
        beq ?fits
    .ifdef FX127
?flush  jsr ptc_fire_wait            ; the open chain's links read the tiles, a
        stz rs_wtexad+2              ;   queued blit the old frames; the seg's
                                     ;   wall tiles go too (seg_draw ?lgo refetches)
    .else
?flush  jsr blitter_wait             ; a queued blit may read the old frames
    .endif
        phy                          ; (spr_one's caller holds the thing in Y)
        phx
        rep #$20
        .LONGA ON
        lda #ARCLR_BASE              ; FARENA (FX127: and the TEXVR_HI page under
        sta zp_ptr                   ;   it) to 0: nothing resident
        ldx #ARCLR_N
        ldy #0
        tya                          ; 16 bits from Y to A
?clb    sta [zp_ptr],y               ; (zp_ptr+2 = MAP_EXT_BANK, the caller's)
        iny
        iny
        bne ?clb
        inc zp_ptr+1                 ; (16-bit: the page byte and the bank -- no
        dex                          ;   carry, the last page is $FE)
        bne ?clb
        lda ar_base                  ; bump back to the arena floor
        sta ar_bump
        ldy ar_base+2
        sty ar_bump+2
        sep #$20
        .LONGA OFF
        plx
        ply
?fits   rep #$21
        .LONGA ON
        lda ar_bump                  ; the room, the bump past it
        sta sp_addr
        adc sf_size
        sta ar_bump
        pla                          ; m_a back (the room test's scratch)
        sta m_a
        .LONGA OFF
        sep #$20
        lda ar_bump+2
        sta sp_addr+2
        adc #0                       ; (C: the add's carry)
        sta ar_bump+2
        rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_fget -- A = frame id. sp_addr = the frame's ARENA address and sp_ctab =
;   its coltab, straight from the FTAB; on a residency miss the pixels are
;   copied out of SDRAM first (ar_alloc, spr_fcopy). Keeps X.
;--------------------------------------------------------------
        .segment B1
.proc spr_fget
        sta sp_fid
                                     ; 2026-09-15: ON -- native from urom_init and the
                                     ;   .else side reps itself.
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
;	clc
	adc #FTAB_EXT
	sta zp_ptr
        ldy #SPRCOL_BANK             ; the FTAB rode out of bank $01 with the
        sty zp_ptr+2                 ;   coltab it indexes

;       ldy #0                       ; u24 file offset
        lda [zp_ptr]		;fetch word
        sta sf_off		;write word
        ldy #2
        lda [zp_ptr],y		;fetch word
	tax
        stx sf_off+2		;write byte
        iny
        lda [zp_ptr],y               ; u16 stored size, fetch word
        sta sf_size		;write word
        ldy #5
        lda [zp_ptr],y               ; u16 coltab addr, fetch word
        sta sp_ctab		;write word

        ldy #MAP_EXT_BANK            ; FARENA is runtime-only and stayed behind
        sty zp_ptr+2

        lda sp_fid                   ; FARENA entry = FARENA_EXT + id*3
	and #$00ff
	sta zp_ptr
	asl
	adc zp_ptr

    .if [FARENA_EXT & $FF] > 0 || [[FARENA_EXT >> 8] & $03] > 0
        ert 'FARENA_EXT moved: the ora below is no longer the 16-bit add'
    .endif
                                     ; + FARENA_EXT. It is PAGE-ALIGNED and id*3
        ora #FARENA_EXT              ;   is at most 762 ($02FA), so its high byte
        sta zp_ptr                   ;   only ever sets bits 0-1 -- which
                                     ;   >FARENA_EXT ($FC) has clear.
;       lda zp_ptr                   ; the flush path clobbers zp_ptr -- keep
        sta sf_ent                   ;   the entry address for the store back
        lda [zp_ptr]		;word fetch
        sta sp_addr		;word write
        ldy #2

	sep #$20
	.LONGA OFF
        lda [zp_ptr],y
        sta sp_addr+2
        ora sp_addr+1
        ora sp_addr
        beq ?miss
        rts                          ; resident: nothing to copy

?miss
    .ifdef FX127
        rep #$21                     ; the frame 128-ALIGNED: its column tiles are
        .LONGA ON                    ;   aligned to their size inside it
        lda ar_bump                  ;   (pack_things), 128 at most
        adc #127
        and #$FF80
        sta ar_bump
        .LONGA OFF
        sep #$20
        bcc ?al
        inc ar_bump+2
?al
    .endif
        jsr ar_alloc                 ; sp_addr = room for the frame (a flush when
        rep #$20                     ;   none)
        .LONGA ON
        lda sf_ent                   ; FARENA[id] = sp_addr: resident
        sta zp_ptr
        lda sp_addr
        sta [zp_ptr]
        ldy #2
        sep #$20
        .LONGA OFF
        lda sp_addr+2
        sta [zp_ptr],y
        rep #$21
        .LONGA ON
        lda spr_sdram                ; sf_src = spr_sdram + sf_off (tex_vget
        adc sf_off                   ;   hands spr_fcopy its own source)
        sta sf_src
        sep #$20
        .LONGA OFF
        lda spr_sdram+2
        adc sf_off+2
        sta sf_src+2
        ert *<>spr_fcopy             ; falls through: fetch the pixels
.endp
        .endseg
;--------------------------------------------------------------
; spr_fcopy -- sf_size bytes, SDRAM (sf_src) -> VRAM at sp_addr, through the
;   MEMAC window, a word a pass: the window is the chip bus, a byte over it
;   is a chip cycle, and the 21 fast cycles between two words round up to
;   two more. Parks the window back on the overhead bank and zp_vptr+2 back
;   on MAP_EXT_BANK. Eats sf_size. Preserves X, Y and zp_ptr+2.
;--------------------------------------------------------------
        .segment B1
.proc spr_fcopy
        rep #$20
        .LONGA ON
        lda sf_size                  ; nothing stored (every column empty)?
        bne ?go
        sep #$20
        .LONGA OFF
        rts
?go     .LONGA ON
        lda sf_src                   ; zp_vptr walks the SDRAM source
        sta zp_vptr
        lda sp_addr                  ; window ptr = MEMW16 + (dst & $3FFF)
        and #$3FFF
        ora #MEMW16
        sta zp_ptr
        sep #$20
        .LONGA OFF
        lda sf_src+2
        sta zp_vptr+2
        lda zp_ptr+2                 ; the window through [zp_ptr],y: a long
        pha                          ;   store does not read its target first
        stz zp_ptr+2
        phx
        phy
        lda sp_addr+1                ; window bank = dst >> 12
        lsr
        lsr
        lsr
        lsr
        sta sf_bank
        lda sp_addr+2
        asl
        asl
        asl
        asl
        ora sf_bank
        sta sf_bank
?chunk  ora #BANK_EN
        sta VBXE_BANK_SEL
        rep #$21
        .LONGA ON
        lda #MEMW16+$4001            ; C = 0: the bytes to the window's end
        sbc zp_ptr
        cmp sf_size
        bcc ?part
        lda sf_size
?part   pha                          ; this pass: that many
        eor #$FFFF
        sec
        adc sf_size
        sta sf_size
        pla
        lsr @                        ; words, C = the odd byte
        pha
        bcc ?blk
        sep #$20
        .LONGA OFF
        lda [zp_vptr]
        sta [zp_ptr]
        rep #$20
        .LONGA ON
        inc zp_ptr
        inc zp_vptr
        bne ?blk
        sep #$20
        inc zp_vptr+2
        rep #$20
?blk    lda 1,s                      ; 128 words a block: Y is the cursor
        beq ?cend
        sec
        sbc #128
        bcs ?full
        lda 1,s
        tax
        lda #0
?full   sta 1,s
        bcc ?run
        ldx #128
?run    ldy #0
?w      lda [zp_vptr],y
        sta [zp_ptr],y
        iny
        iny
        dex
        bne ?w
        tya
        beq ?page
        clc                          ; the last block of the pass
        adc zp_ptr
        sta zp_ptr                   ; (C = 0: the window ends at $C000)
        tya
        adc zp_vptr
        sta zp_vptr
        bcc ?blk
        sep #$20
        inc zp_vptr+2
        rep #$20
        bra ?blk
?page   inc zp_ptr+1                 ; (words at +1: the page and the bank)
        inc zp_vptr+1
        bra ?blk
?cend   pla
        lda sf_size
        beq ?done
        lda #MEMW16                  ; the next 16 KB of VRAM
        sta zp_ptr
        sep #$20
        .LONGA OFF
        lda sf_bank
        and #$7C
        clc
        adc #4
        sta sf_bank
        jmp ?chunk
?done   .LONGA ON
        sep #$20
        .LONGA OFF
        ply
        plx
        pla
        sta zp_ptr+2
        lda #BANK_EN|BANK_OVERHEAD   ; park the window back on the BCB bank
        sta VBXE_BANK_SEL
        lda #MAP_EXT_BANK            ; ...and the borrowed pointer's bank byte
        sta zp_vptr+2                ;   (engine-wide constant, see init_level)
        rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_ctcol -- A = source column x. FX127: rs_tsrc = its tile, sp_ctop/sp_cbot
;   its crop (cbot = 0: empty), sp_topw, sp_patw (size code + CTRL), and the
;   crop as screen rows sp_rt/sp_rb (16-bit signed; rb capped at the sprite's
;   last row). Clobbers A/Y, m_a/m_b/m_prod.
;--------------------------------------------------------------
    .ifdef FX127
        .segment B1
.proc spr_ctcol
        rep #$20
        .LONGA ON
        and #$00FF
        asl @
        asl @
        adc sp_ctab                  ; (C = 0: the shifts' top bits were 0)
        sta zp_ptr
        ldy #SPRCOL_BANK
        sty zp_ptr+2
        lda [zp_ptr]                 ; (off >> 3) | code << 13
        pha
        and #$1FFF
        asl @
        asl @
        asl @
        adc sp_addr                  ; (C = 0: the masked bits shifted out)
        sta rs_tsrc
        lda sp_addr+2                ; the bank + the carry; rs_tsrc+3 = 0
        and #$00FF
        adc #0
        sta rs_tsrc+2
        ldy #2
        lda [zp_ptr],y               ; (top, cbot)
        sta sp_ctop
        and #$00FF
        xba
        sta sp_topw
        pla
        and #$E000                   ; the size code, bits 15-13 -> the PATTERN
        xba                          ;   byte, the CTRL above it
        lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        cmp #5
        bcs ?twj                     ; 5-7: two tiles (out of line, past a jmp:
                                     ;   ?twot is out of a branch's reach)
        ora sp_ctlw
        sta sp_patw
        stz sp_two
?pats   lda sp_ctop
        xba
        and #$00FF                   ; cbot
        beq ?out                     ; empty: sp_cbot = 0 says so
        jsr ?ceil                    ; rb = ytop + min(ceil(cbot*scale/256), rows) - 1
        dec @
        sta m_a
        lda sp_ybot
        sec
        sbc sp_ytop                  ; rows-1
        cmp m_a
        bcc ?less
        lda m_a
?less   clc
        adc sp_ytop
        sta sp_rb
        lda sp_ctop
        and #$00FF
        jsr ?ceil                    ; rt = ytop + ceil(top*scale/256)
        clc
        adc sp_ytop
        sta sp_rt
?out    .LONGA OFF
        sep #$20
        lda #MAP_EXT_BANK            ; the map's bank back on zp_ptr
        sta zp_ptr+2
        lda rs_tsrc                  ; 2026-10-20: Y0 = the tile's place in its 64-byte
        and #$38                     ;   block over the tile size. The raycaster REPLACES
        lsr                          ;   address bits 5:0 with the texture pixel's Y:X (1.27
        lsr                          ;   manual), so a tile under 64 B off a 64-byte
        ldy sp_patw                  ;   boundary is read from the block's start unless
        iny                          ;   Y names its slot: (bits 5:3) >> (code + 3).
?ysh    lsr                          ;   Two tiles are 128-aligned: 0 either way
        dey
        bne ?ysh
        sta sp_st26                  ; [25] under the step's high byte (spr_clink)
        rts
        .LONGA ON
?twj    jmp ?twot                    ; (6502-cycles-layout: the rare case's trampoline)
?twot   sbc #5                       ; (C = 1) the second tile: 8 << (code - 5)
        ora sp_ctlw                  ;   texture rows, right behind the first's 128
        sta sp_patb
        lda #4
        ora sp_ctlw
        sta sp_patw
        sta sp_pata
        lda rs_tsrc
        clc
        adc #128
        sta sp_srcb
        lda rs_tsrc+2
        adc #0
        sta sp_srcb+2
        lda sp_ctop                  ; the row the second tile starts on
        and #$00FF
        clc
        adc #128
        jsr ?ceil
        clc
        adc sp_ytop
        sta sp_rsplit
        lda #1
        sta sp_two
        jmp ?pats                    ; (out of a branch's reach: the rare path pays)
?ceil                                ; A = a texture row count: ceil(A * scale / 256)
  .ifdef ANTONIA2
        sta.l ANT_MUL
        lda sp_scale
        sta.l ANT_MUL+2
        lda.l ANT_MUL
        and #$00FF
        cmp #1                       ; C = a fraction
        lda.l ANT_MUL+1
        adc #0
        rts
  .else
        sta m_a
        lda sp_scale
        sta m_b
        .LONGA OFF
        sep #$20
        jsr umul16
        rep #$20
        .LONGA ON
        lda m_prod
        and #$00FF
        cmp #1                       ; C = a fraction
        lda m_prod+1
        adc #0
        rts
  .endif
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; spr_clink -- the column's link: rows sp_y0..sp_y1 of column sp_colw out of
;   the tile rs_tsrc, bottom-up like every link: X0 = the texture row at row y1
;   less the crop top, the step -tpr (sp_st5/sp_st26), MODE 1 (sp_ctlw; the
;   spectre: MODE 3, AND 0, XOR FUZZ_OR). Nine bus words. 8-bit in and out;
;   clobbers A/Y, m_a/m_b/m_prod.
;--------------------------------------------------------------
        .segment B1
.proc spr_clink
        rep #$20
        .LONGA ON
        lda sp_y1                    ; rows from the sprite's top to its last row
        and #$00FF
        sec
        sbc sp_ytop
  .ifdef ANTONIA2
        sta.l ANT_MUL                ; x tpr: the texture row there, 8.8 (under h: a word)
        lda sp_tpr
        sta.l ANT_MUL+2
        lda.l ANT_MUL
  .else
        sta m_a
        lda sp_tpr
        sta m_b
        .LONGA OFF
        sep #$20
        jsr umul16
        rep #$20
        .LONGA ON
        lda m_prod
  .endif
        sec
        sbc sp_topw                  ; [22-23] X0: into the tile
        ldy #BCB_SIZE+1
        sta [zp_pt],y
        lda rs_tsrc                  ; [0-1] SRC lo/mid
        sta [zp_pt]
        lda rs_tsrc+2                ; [2-3] SRC bank, SRC_STEPY lo = 0
        ldy #BCB_SRC_ADDR+2
        sta [zp_pt],y
        lda sp_st5                   ; [4-5] = (0, step lo)
        ldy #BCB_SRC_STEPY+1
        sta [zp_pt],y
        lda sp_st26                  ; [25-26] = (0, step hi)
        ldy #BCB_SIZE+4
        sta [zp_pt],y
        lda sp_xorw                  ; [16-17] = (XOR, cmask 0)
        ldy #BCB_XOR
        sta [zp_pt],y
        lda sp_patw                  ; [19-20] = (the tile's size code, CTRL)
        ldy #BCB_PATTERN
        sta [zp_pt],y
        ldy sp_y1                    ; [14-15] = (rows-1, AND): y1 - y0 (sp_y0's
        tya                          ;   high byte is 0; 8-bit Y: B = 0)
        sec
        sbc sp_y0
        ora sp_andw
        pha
        lda row_hi-1,y               ; DST = row*160 + the column at the LAST row:
        .LONGA OFF                   ;   row_hi[y1] into B by a word read,
        sep #$20                     ;   row_lo[y1] under it
        lda row_lo,y
        rep #$21
        .LONGA ON
        adc sp_colw
        ldy #BCB_DST_ADDR
        sta [zp_pt],y
        pla
        ldy #BCB_HEIGHT
        sta [zp_pt],y
        lda zp_pt                    ; the next slot (C = 0: row*160+col < $8000)
        adc #BCB_SLOT
        sta zp_pt
sc_cend cmp #BCB_SLOT*TW_MAXLINKS+PT_ZPOFF   ; the END slot (its high byte: ptc_open)
        .LONGA OFF
        sep #$20
        beq ?full
        rts
?full   jmp ptc_fire                 ; (8-bit; textures.asm)
.endp
        .endseg

;--------------------------------------------------------------
; spr_two -- the column's link(s) when its texture rows are two tiles: the rows
;   under sp_rsplit come from the second (SRC + 128, its own size code, X0
;   less 128 texture rows). 8-bit in and out; clobbers A/Y, m_*.
;--------------------------------------------------------------
        .segment B1
.proc spr_two
        lda sp_rsplit+1              ; the split row against the window
        bmi ?b                       ; above the screen: every row is the second's
        jne spr_clink                ; under it: the first's
        lda sp_rsplit
        cmp sp_y0
        bcc ?b
        beq ?b                       ; split <= y0: the second's
        cmp sp_y1
        bcc ?split
        beq ?split                   ; split <= y1: both
        jmp spr_clink
?split  lda sp_y1                    ; the first: y0..split-1
        pha
        lda sp_rsplit
        dec @
        sta sp_y1
        jsr spr_clink
        pla
        sta sp_y1
        lda sp_rsplit                ; the second: split..y1
        sta sp_y0
?b      rep #$20
        .LONGA ON
        lda sp_srcb                  ; the second tile in the first's place
        sta rs_tsrc
        lda sp_srcb+2
        sta rs_tsrc+2
        lda sp_patb
        sta sp_patw
        lda sp_topw
        ora #$8000                   ; X0 less 128 texture rows
        sta sp_topw
        .LONGA OFF
        sep #$20
        jsr spr_clink
        rep #$20
        .LONGA ON
        lda rs_tsrc                  ; ...and the first back
        sec
        sbc #128
        sta rs_tsrc
        lda rs_tsrc+2
        sbc #0
        sta rs_tsrc+2
        lda sp_pata
        sta sp_patw
        lda sp_topw
        and #$7FFF
        sta sp_topw
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg
    .else
;--------------------------------------------------------------
; spr_ctcol -- A = source column x.
;--------------------------------------------------------------
        .segment B1
.proc spr_ctcol
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
;	clc
	adc sp_ctab
	sta zp_ptr
        ldy #SPRCOL_BANK
        sty zp_ptr+2

        lda [zp_ptr]                 ; off, frame-relative
        clc
        adc sp_addr
        sta rs_tsrc
        ldy #2                       ; [2] top, [3] len as ONE word into sp_ctop/sp_clen
        lda [zp_ptr],y               ;   (clen is ctop+1); lda/sta keep the add's C
        sta sp_ctop
	sep #$20
	.LONGA OFF
        lda #0
        adc sp_addr+2
        sta rs_tsrc+2
        lda sp_clen
        beq ?out                     ; fully transparent: nothing to expand

        lda sp_s
        cmp #2
        bcc ?out                     ; S = 1: blit straight from the sprite
        stz tw_t0
        lda sp_clen                  ; expand the stored span only; 128 texture pixels
        cmp #129                     ;   = the whole 1 KB scratch, and the cap
        bcc ?need                    ;   keeps every read under min(len,128)*8
        lda #128
?need   sta tw_need
        lda sp_s
        sta tw_s
        jsr tw_expand_spr            ; column -> the current scratch, S samples
                                     ;   per texture pixel (a chain of one: the sprite
                                     ;   blit does its own wait)
?out    lda #MAP_EXT_BANK            ; the coltab lives in bank $08 now; put the
        sta zp_ptr+2                 ;   map's bank back on the ONE exit. Safe to
        rts                          ;   leave it set across tw_expand_spr above:
.endp                                ;   tw_setup.asm never touches zp_ptr.
        .endseg

;--------------------------------------------------------------
; spr_cspan -- the span intersection with the crop, on the existing z/spy
;   ladder (contract: tools/_verify_sprcrop.py). IN: sp_q (clip-top reads,
;   16b), sp_zsh/sp_spy/sp_s, sp_ctop/sp_clen, sp_ytop (16b signed), sp_y1.
;   OUT C=1: sp_y0, sp_bh (reads-1), sp_soff (into the CROPPED data).
;   Clobbers A/X/Y, m_a/m_b/m_prod/m_den/m_quot (umul16 + up to 2 udiv24).
;--------------------------------------------------------------
        .segment B1
.proc spr_cspan
        lda sp_clen
        bne ?some
?none   clc                          ; empty column
        rts
?some
	rep #$20
	.LONGA ON
	lda sp_ctop
	and #$00ff
	ldy sp_s
	cpy #2
	bcc ?cs
	asl
	asl
	asl
?cs	sta sp_csmp
  .ifdef ANTONIA2                    ; 2026-10-15 (6502-idioms: compute in A; 65816-
	lda sp_q                     ;   windows: one 16-bit run): q*spy, the divide
	sta.l ANT_MUL                ;   of a 16-bit dividend and the second product
	lda sp_spy                   ;   on the card, no calls, no sep/rep. The
	sta.l ANT_MUL+2              ;   divide is udiv24a_v2's ?fast16 itself (a
	lda.l ANT_MUL                ;   divisor 0 goes to the card there too)
	sta m_prod
        cmp sp_csmp
        bcs ?soff
        lda sp_csmp
        adc sp_spy
	dec
	sta.l ANT_DIV
        lda sp_spy
	sta.l ANT_DIV+2
	lda.l ANT_DIV
        sta sp_q
	sta.l ANT_MUL
        lda sp_spy
	sta.l ANT_MUL+2
	lda.l ANT_MUL
	sta m_prod
  .else
	lda sp_q
	sta m_a
	lda sp_spy
	sta m_b
	sep #$20
	.LONGA OFF
        jsr umul16                   ; (no phx/plx: X is dead here -- spr_cspan and
                                     ;   spr_one's column loop reload it, and spr_one's
                                     ;   caller keeps its index in Y; 2026-09-23)

	rep #$20
	.LONGA ON
        lda m_prod                   ; already at/below the crop top?
        cmp sp_csmp
        bcs ?soff                    ; yes: no division, just subtract

;	clc
        lda sp_csmp                  ;   (csamp + spy - 1) by spy
        adc sp_spy
	dec
        sta m_prod
	ldy #0
	sty m_prod+2
        lda sp_spy
        sta m_den
	jsr udiv24.ud_w16            ; past udiv24's rep, still 16-bit (no sep/rep pair)
	.LONGA OFF
	UD16                         ; (udiv24 hands back 16-bit A)
	.LONGA ON
        UDQ                          ; q = qmin (A = m_quot, 2026-09-26), redo q*spy with it
        sta sp_q
        sta m_a
        lda sp_spy
        sta m_b
	sep #$20
	.LONGA OFF
        jsr umul16                   ; (no phx/plx: X is dead here -- spr_cspan and
                                     ;   spr_one's column loop reload it, and spr_one's
                                     ;   caller keeps its index in Y; 2026-09-23)
  .endif
?soff
	rep #$20
	.LONGA ON
	sec                          ; sp_soff = q*spy - csamp (>= 0 now)
        lda m_prod
        sbc sp_csmp
        sta sp_soff

        lda sp_q                     ; y0 = ytop + q, 16-BIT: the crop raise
        clc                          ;   can push it past the screen, where the
        adc sp_ytop                  ;   old byte add silently wrapped. (q*z, and
	sep #$20                     ;   z is 1 -- the shift loop went with it.)
	.LONGA OFF                   ;   The add in A, its high byte the test
        sta sp_y0                    ;   (2026-09-15: no m_a round trip)
        xba
        beq ?rd
?off    clc                          ; y0 >= 256: below every window
        rts

?rd     sec                          ; reads = y1 - y0 + 1 (z is 1: no >> zsh)
        lda sp_y1
        sbc sp_y0
        bcc ?off
	; nothing
        sta sp_bh                    ; the clip half of the count

        lda sp_clen                  ; smax+1 = min(len, S=8 ? 128 : len) * S
        ldx sp_s
        cpx #2
        bcc ?sm1
        cmp #129
        bcc ?sm8
        lda #128                     ; the scratch holds 128 texture pixels
                                      ; 2026-09-15: smax stays in A -- the x8, the
?sm8    rep #$20                     ;   -1 and the subtract in one window, the
        .LONGA ON                    ;   divisor set up inside it (no m_a stores,
        and #$00FF                   ;   no reloads: ~18 cycles a call)
        asl
        asl
        asl
        bra ?room
        .LONGA OFF
?sm1    rep #$20
        .LONGA ON
        and #$00FF
?room   dec                          ; room = smax - 1 - soff
        sec
        sbc sp_soff
  .ifdef ANTONIA2                    ; 2026-10-15: room / spy on the card (a 16-bit
        sta.l ANT_DIV                ;   dividend: udiv24a_v2's ?fast16), sent
        lda sp_spy                   ;   before the test -- a dead divide on the
        sta.l ANT_DIV+2              ;   rare off path costs nothing; C is the sbc's
        .LONGA OFF
        sep #$20
        bcc ?off
        lda.l ANT_DIV+1
        bne ?ok
        lda.l ANT_DIV
  .else
        sta m_prod
        stz m_prod+2                 ; (a word: +2 and +3)
        lda sp_spy
        sta m_den
        .LONGA OFF
        sep #$20                     ; (sep keeps C: the sbc's)
        bcc ?off                     ; the whole span starts past the crop end

        jsr udiv24                   ; m_quot = cap-1 = floor(room/spy)
        UD8                          ; (udiv24 hands back 16-bit A)

        lda m_quot+1
        bne ?ok                      ; cap >= 256 reads: the clip count stands
        lda m_quot
  .endif
        cmp sp_bh
	bcs ?ox
	sta sp_bh
?ok	sec
?ox	rts
.endp
        .endseg
    .if * > SPRCROP_END+1
        ert 'the T4 crop helpers outgrew SPRCROP_BASE..END (memory_map.inc)'
    .endif
    .endif                           ; FX127 / the scratch path
        org scrop_resume
