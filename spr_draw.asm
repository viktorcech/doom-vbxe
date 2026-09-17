; AUTO-SPLIT from sprites.asm 2026-07-24 -- assembled in place via icl (verified
; byte-identical). The DRAWING half of the billboard renderer: spr_draw (back to
; front selection sort), spr_one (per-sprite setup + the per-column loop with the
; rate ladder) and spr_blit. sprites.asm keeps collection: spr_reset, spr_add,
; spr_proj, spr_pickup and give_bonus.
;--------------------------------------------------------------
; spr_draw -- draw every collected sprite BACK TO FRONT, after the BSP walk has
;   painted the walls. spr_proj already keeps vs_ord sorted NEAR..FAR (insertion
;   into an almost-sorted list, since the BSP hands sprites over front-to-back),
;   so drawing is just that list walked backwards -- no per-frame sort at all.
;--------------------------------------------------------------
    .if * > SPRITES_END+1
        ert 'spr_add+spr_proj outgrew SPRITES_BASE..SPRITES_END (memory_map.inc)'
    .endif
        org SPRDRAW_BASE             ; 2026-08-11 win2 evacuation T2: the drawing
                                     ;   flow splits in three (memory_map.inc)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_draw
 .if 1
	ldy sp_n
	beq ?ret
?loop	dey			;save 10 bytes and 7 clock cycles per iteration
	phy			;eliminate static sp_oi (used only here)
	ldx vs_ord,y
	jsr spr_one
	ply
	bne ?loop
 .else
        lda sp_n
        beq ?ret
        sta sp_oi
?loop   dec sp_oi
        ldx sp_oi
        lda vs_ord,x
        tax
        jsr spr_one
        lda sp_oi
        bne ?loop
 .endif
?ret    rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_one -- draw one vissprite (X = record offset). One blit per screen column.
;--------------------------------------------------------------
    .if * > SPRDRAW_END+1
        ert 'spr_draw outgrew SPRDRAW_BASE..SPRDRAW_END (memory_map.inc)'
    .endif
        org SPRONE_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_one
 .if 1
        ldy vs_x1l,x		;eliminate one memory load lda sp_x1, replace with tya
	sty sp_x1		;save 3 bytes
 .else
        lda vs_x1l,x
	sta sp_x1
 .endif
        lda vs_x1h,x
        sta sp_x1+1
        bmi ?xa0                     ; xa = max(x1, 0), rebuilt instead of stored:
 .if 1
        tya	                    ; x1 >= 256 was rejected at collection, so the
        bra ?xas                     ; hi byte is either 0 (xa = the low byte, and
 .else
	lda sp_x1
	jmp ?xas
 .endif
?xa0    lda #0                       ; it is < SCREEN_WIDTH) or negative (xa = 0)
?xas    sta sp_xa
        sta sp_col
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
                                     ;   by draw time it still points at the
                                     ;   LAST projected thing -- barrels came
                                     ;   out as the zombieman's frames whenever
                                     ;   one was projected after them
        lda vs_th,x                  ; dying? -> sp_tab already points at the row
        jsr spr_shadow               ;   (preserves X). spr_shadow points the
                                     ;   sprite BCB at this thing's blit mode
                                     ;   (MF_SHADOW = see-through) and then IS
                                     ;   spr_dyn -- see the block at the end of
                                     ;   this file, the $B000 segment is full
        bcs ?have
        lda vs_sid,x                 ; live thing: sprite-table row AND the T4
        jsr spr_sidtab               ;   coltab pointer, both from the id
                                     ;   (SPRCROP block -- this segment is full)
?have   lda (sp_tab)                 ; byte 0 = the FRAME ID (B1): resolve it
        jsr spr_fget                 ;   to an arena address -- fetching the
                                     ;   pixels from SDRAM on the first look
                                     ;   -- and to its coltab (SPRCROP block)
        ldy #3
 .if 1
	rep #$20
        lda (sp_tab),y
        sta sp_w			;sp_h is sp_w+1, so OK to do word-store
	sep #$20			;save 3 cycles and 2 bytes
 .else
        lda (sp_tab),y
        sta sp_w
        iny
        lda (sp_tab),y
        sta sp_h
 .endif
        lda #$FF                     ; no source column in the scratch yet: this
        sta sp_lastx                 ;   sprite may reuse the previous one's
                                     ;   column number at a different scale
        lda sp_h                     ; rows on screen = (h*scale)>>8
        sta m_a
        stz m_a+1
        lda sp_scale
        sta m_b
        lda sp_scale+1
        sta m_b+1

        jsr umul16
 .if 1
	rep #$21		;switch to 16-bit A, clear C
        .LONGA ON
        lda m_prod+1		; bottom row = ytop + rows - 1
;       sta sp_rows		;eliminate use of sp_rows here
        adc sp_ytop
	dec
        sta sp_ybot		; 5 inss, 11 bytes, 19 cycles, continue with 16-bit accumulator
 .else
        lda m_prod+1		; 18 inss, 46 bytes, 58 cycles
        sta sp_rows
        lda m_prod+2
        sta sp_rows+1
        clc                          ; bottom row = ytop + rows - 1
        lda sp_ytop
        adc sp_rows
        sta sp_ybot
        lda sp_ytop+1
        adc sp_rows+1
        sta sp_ybot+1
        sec
        lda sp_ybot
        sbc #1
        sta sp_ybot
        lda sp_ybot+1
        sbc #0
        sta sp_ybot+1
 .endif
        ; --- vertical rate ---------------------------------------------------
        ; The scratch holds S = 8 samples per texel and SRC_STEPY alone carries
        ; the rate: spy = round(2048 / scale) samples per screen row.
        ;
        ; The final blit does NOT zoom (2026-08-04). It used to: a z of 1/2/4/8
        ; in ZOOM_Y emitted z rows per source read, which bought a 1/8-sample
        ; ladder (~1% rate error instead of up to 25% at high magnification).
        ; Dropped because SRC_STEPY and ZOOM are known to MULTIPLY on the metal
        ; (the bench note behind the VBXE limits) -- a zoomed screen blit would
        ; then walk the source z times too fast and read past the column's
        ; expanded span. The WALL path already ships ZOOM = 0 for that reason,
        ; with the note "the 8x scratch carries the zoom" (textures.asm), and
        ; this was the only place left putting a non-zero ZOOM_Y on a screen
        ; blit. z > 1 needed scale > 512, so only a sprite magnified past 2x
        ; ever reached it.
        ; HONEST NOTE: this was NOT what made the missile invisible -- that was
        ; a sign lost across umul16 in proj.asm's pj_leg, and the missile flew
        ; off the map. The zoom change neither fixed nor broke that; it is kept
        ; because a screen blit that relies on ZOOM_Y is unsound here either
        ; way, not because it was ever shown to misdraw.
        ; The cost is the ladder itself -- the rate now quantises to whole
        ; samples, up to ~13% short vertically at the very largest scales.
        ;   spy8 = round(8 * 2048 / scale), so spy = (spy8 + 4) >> 3
 .if 1
	lda sp_scale		;16-bit accumulator and M, continued
	and #$fffe
	sta m_den
;	sta sp_scale		;this gets updated in the original, but see comment below in the 8-bit section
        lsr
;       clc
        adc #$4000
        sta m_prod		;max. $7FFF+$4000=$BFFF, C always 0
	sep #$20		;switch to 8-bit A
        .LONGA OFF
	stz m_prod+2		;no Carry into m_prod+2
 .else
        stz m_prod		;23 inss, 53 bytes, 81 cycles
        lda #$40                     ; 16384 = 8*2048
        sta m_prod+1
 .if 1
	stz m_prod+2
 .else
        lda #0
        sta m_prod+2
 .endif
        lsr sp_scale+1               ; + scale/2 (round to nearest)
        ror sp_scale	;<-- here sp_scale loses its lowest bit and it is not restored by asl/rol below, not sure if intentionally

        clc
        lda m_prod
        adc sp_scale
        sta m_prod
        lda m_prod+1
        adc sp_scale+1
        sta m_prod+1
        lda m_prod+2
        adc #0
        sta m_prod+2

        asl sp_scale                 ; put scale back
        rol sp_scale+1

        lda sp_scale
        sta m_den
        lda sp_scale+1
        sta m_den+1
 .endif
        jsr udiv24                   ; m_quot = spy8 = samples per row at z = 8

        ; 16-BIT A (2026-08-31, drac030 round two): this built (m_quot+4)>>3 by STORING the sum and
        ; then shifting it IN MEMORY, six lsr/ror abs pairs at 12 cycles each,
        ; with an lda/ora/bne re-load to test what the accumulator had just
        ; held. The whole thing is one 16-bit accumulator expression now --
        ; and `inc @` fixes a latent bug on the way: the old minified-path
        ; clamp tested sp_spy's LOW byte alone, so a value of exactly $0100
        ; would have been "zero" and bumped to $0101.
        rep #$21		;clear C to avoid CLC below
        .LONGA ON
        lda m_quot
;	clc			;eliminate
        adc #4                       ; rounding
        lsr @
        lsr @
        lsr @                        ; /8 -- in A, 2 cycles a shift
        bne ?spyok
        inc @                        ; never zero (65816 inc a)
?spyok  sta sp_spy
 .if 1
        ldx #8                       ; the scratch always holds 8 samples/texel
	ldy sp_scale+1		;X/Y are still 8-bit, take advantage of that
	bne ?fine		;to avoid rep/sep
	ldy sp_scale
	cpy #65
	bcs ?fine
	ldx #1
        lda sp_spy
        lsr
        lsr
        lsr
        bne ?nz2
        inc                        ; never zero -- ALL 16 bits tested now
?nz2    sta sp_spy
?fine	stx sp_s
        stz m_prod
        ldy #1
        sty m_prod+2
        lda sp_hs
        sta m_den
        .LONGA OFF
        sep #$20
 .else
        .LONGA OFF
        sep #$20
        ; z IS 1 -- always, since 2026-08-04 (the note above). Everything that
        ; used to key off it is gone with it: sp_zsh (written 0 here and read
        ; nowhere else), the spr_zm rounding table, the spr_zoom BCB table and
        ; the three shift loops they fed. 74 B and the reads that went with it.
        lda #8                       ; the scratch always holds 8 samples/texel
        sta sp_s
        lda sp_scale+1               ; minified 4x or more: skip the expansion and
        bne ?fine                    ; sample the raw column (nothing to gain),
        lda sp_scale                 ; which is the same rate divided by 8
        cmp #65
        bcs ?fine
        lda #1
        sta sp_s
        rep #$20
        .LONGA ON
        lda sp_spy
        lsr @
        lsr @
        lsr @
        bne ?nz2
        inc @                        ; never zero -- ALL 16 bits tested now
?nz2    sta sp_spy
        .LONGA OFF
        sep #$20
?fine
 .if 1
        stz m_prod                   ; texels per screen column = 65536 / hs (Q8)
        stz m_prod+1
 .else
	lda #0                       ; texels per screen column = 65536 / hs (Q8)
        sta m_prod
        sta m_prod+1
 .endif
        lda #1
        sta m_prod+2
        lda sp_hs
        sta m_den
        lda sp_hs+1
        sta m_den+1
 .endif
        jsr udiv24

 .if 1
	rep #$20
	.LONGA ON
        lda m_quot
        sta sp_ustep
        sta m_b
	lda sp_xa
	and #$00ff
	sec
	sbc sp_x1
	sta m_a
	sep #$20
	.LONGA OFF
 .else
        lda m_quot
        sta sp_ustep
        lda m_quot+1
        sta sp_ustep+1
        sec                          ; u at the first visible column
        lda sp_xa
        sbc sp_x1
        sta m_a
        lda #0
        sbc sp_x1+1
        sta m_a+1
        lda sp_ustep
        sta m_b
        lda sp_ustep+1
        sta m_b+1
 .endif
        jsr umul16

        lda m_prod
        sta sp_uacc
        lda m_prod+1
        sta sp_uacc+1

; ===================== per-column loop =====================

 .if 1
	rep #$21		;clear C to avoid CLC below
	.LONGA ON
?col	lda (sp_clip)                ; this column's clip window
        sta sp_t		; write sp_t and sp_b, they're consecutive in memory
        lda sp_cstep                 ; 0 when one window covers the whole sprite
	and #$00ff
        adc sp_clip
        sta sp_clip
	sep #$20
	.LONGA OFF
 .else
?col	ldy #0                       ; this column's clip window
        lda (sp_clip),y
        sta sp_t
        iny
        lda (sp_clip),y
        sta sp_b
        clc
        lda sp_clip
        adc sp_cstep                 ; 0 when one window covers the whole sprite
        sta sp_clip
        bcc ?c1
        inc sp_clip+1
?c1
 .endif

; the spr_ncut seems called only once
; inline this to save jsr/rts overhead
;
	jsr spr_ncut                 ; a wall the walk reached LATER can still be
                                     ;   NEARER than this sprite: spr_ncut forces
                                     ;   sp_t to 255 for those columns
        lda sp_t
        cmp #255
 .if 1
	jeq ?cnext
 .else
        bne ?cvis                    ; covered by nearer geometry
        jmp ?cnext
?cvis
 .endif
	lda sp_uacc+1                ; source column = u >> 8
        cmp sp_w
        bcc ?tok
        lda sp_w
 .if 1
	dec
 .else
        sec
        sbc #1                       ; clamp (right-edge rounding)
 .endif
?tok    bit sp_dfix                  ; the mirrored profile (DOOM rot 7): the
        bpl ?nofl                    ;   SAME stored image, columns read from
        eor #$FF                     ;   the other end -- A = w-1-A (255-A+w
        clc                          ;   mod 256; A < w always, so it is exact)
        adc sp_w
?nofl   cmp sp_lastx
        beq ?haveco                  ; same source column as the previous one
        sta sp_lastx
        jsr spr_ctcol                ; T4: coltab[x] -> rs_tsrc (cropped column
                                     ;   base), sp_ctop/sp_clen -- and the 8x
                                     ;   expander over exactly the stored span
                                     ;   (SPRCROP block; replaces the x*h mul)
?haveco lda sp_ytop+1                ; y0 = max(ytop, window top)
        bne ?useT                    ; negative (or off-screen, already rejected)
        lda sp_ytop
        cmp sp_t
        bcs ?y0set
?useT   lda sp_t
?y0set  sta sp_y0
        lda sp_ybot+1                ; y1 = min(ybot, window bottom)
 .if 1
	jmi ?cnext		;auto-shortened to bmi when in range
 .else
        bpl ?ynn
?cjmp   jmp ?cnext                   ; (trampoline: ?cnext is out of branch range)
?ynn
 .endif
	bne ?useB
        lda sp_ybot
        cmp sp_b
        bcc ?y1set
?useB   lda sp_b
?y1set  sta sp_y1
        cmp sp_y0
 .if 1
        jcc ?cnext                   ; auto-shortened to bcc when in range
 .else
        bcc ?cjmp                    ; nothing visible in this column
 .endif

 .if 1
	rep #$20
	.LONGA ON
	lda sp_y0
	and #$00ff
;	sec
	sbc sp_ytop
	sta sp_q
	sep #$20
	.LONGA OFF
 .else
;       sec                          ; d = rows into the sprite at the clip top
        lda sp_y0
        sbc sp_ytop
        sta m_a
        lda #0
        sbc sp_ytop+1
        sta m_a+1
        lda m_a                      ; q = d: one source read per dest row (z = 1),
        sta sp_q                     ;   so there is no ceil() and no shift -- the
        lda m_a+1                    ;   rounding term spr_zm[0] was 0 and the
        sta sp_q+1                   ;   shift count sp_zsh was 0 on every path
 .endif
        jsr spr_cspan                ; T4 (SPRCROP block): raise q to the crop
        bcc ?cnext                   ;   top, y0 with it, cap the reads at the

        jsr spr_blit                 ;   stored end, sp_soff into the CROPPED
                                     ;   data -- C=0 = nothing left to draw.
                                     ;   MF_SHADOW costs nothing here: spr_shadow
                                     ;   left the BCB in its see-through mode
?cnext
 .if 1
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
 .else
	clc                          ; u += ustep, next column
        lda sp_uacc
        adc sp_ustep
        sta sp_uacc
        lda sp_uacc+1
        adc sp_ustep+1
        sta sp_uacc+1

        lda sp_col
        cmp sp_xb
        beq ?done
        inc sp_col
        jmp ?col

?done   rts                          ; (invalidated the expander's tw_lastsrc
                                     ;  cache here until 2026-08-14 -- that
                                     ;  cache is gone, see textures.asm)
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_blit
        lda sp_s
        cmp #2
        bcs ?ex
; if we get here, C=0
;       clc                          ; SRC = sprite column + offset
        lda rs_tsrc
        adc sp_soff
        sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR
        lda rs_tsrc+1
        adc sp_soff+1
        sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR+1
        lda rs_tsrc+2
 .if 1
	bra ?srchi
 .else
        adc #0
        jmp ?srchi
 .endif
?ex     rep #$21                     ; SRC = expanded scratch + offset. tw_base,
        .LONGA ON                    ;   not a constant: the expander alternates
        lda tw_base                  ;   between TWO scratches now (chains). The
        adc sp_soff                  ;   low word in one add and ONE chip-bus
        sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR   ; word write (drac030, 2026-09-14)
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        lda tw_base+2
 .if 1
?srchi	adc #0
	sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR+2
 .else
        adc #0
?srchi  sta MEMW+MEMW_SP_OFF+BCB_SRC_ADDR+2
 .endif
        rep #$20                     ; SRC_STEPY as one word: its two chip-bus
        .LONGA ON                    ;   writes back to back (drac030, 2026-09-14)
        lda sp_spy
        sta MEMW+MEMW_SP_OFF+BCB_SRC_STEPY
        .LONGA OFF
        sep #$20
        ldx sp_y0                    ; DST = row(y0) + column, back buffer
        lda row_lo,x
        clc
        adc sp_col
        sta MEMW+MEMW_SP_OFF+BCB_DST_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_SP_OFF+BCB_DST_ADDR+1
        lda zback_hi
        sta MEMW+MEMW_SP_OFF+BCB_DST_ADDR+2
        lda sp_bh                    ; HEIGHT = source reads - 1
        sta MEMW+MEMW_SP_OFF+BCB_HEIGHT
        stz MEMW+MEMW_SP_OFF+BCB_ZOOM ; ZOOM_Y = 0: z is 1, one row per read.
                                     ;   stz, not `lda #0`+`sta`: A is reloaded
                                     ;   right after blitter_wait, and this code
                                     ;   runs from win2 at x11.2 -- the dead
                                     ;   load was ~540 cyk/frame (_an_waste)
        jsr blitw_hard               ; a START while busy is silently dropped
 .if 1
        stz VBXE_BL_ADR0             ; <VRAM_BCB_SPR = 0 and its bank byte too
        lda #>VRAM_BCB_SPR
        sta VBXE_BL_ADR1
        stz VBXE_BL_ADR2
    .if [VRAM_BCB_SPR & $FF] != 0 || [VRAM_BCB_SPR >> 16] != 0
        ert 'VRAM_BCB_SPR moved off a page in bank 0: put the lda #< / #>>16 back'
    .endif
 .else
        lda #<VRAM_BCB_SPR
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_SPR
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_SPR>>16]
        sta VBXE_BL_ADR2
 .endif
        lda #1
        sta VBXE_BL_START
        rts
.endp
        .endseg
    .if * > SPRBLIT_END+1
        ert 'spr_blit outgrew SPRBLIT_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; MF_SHADOW -- the spectre, drawn SEE-THROUGH (2026-08-16).
;
;   R_DrawFuzzColumn never draws the spectre's own pixels. It takes the pixel
;   ALREADY ON SCREEN and runs it through COLORMAP row 6
;   (`*dest = colormaps[6*256 + dest[...]]`, r_draw.c), so what you see is the
;   wall behind the monster, darkened. The lookup is out of reach here -- the
;   blitter's entire per-pixel path is
;       c = (src AND andMask) XOR xorMask;  dst = c | c+d | c|d | c&d | c^d
;   (_pomocne/alt-src/Altirra/source/vbxe.cpp:3676 ff, the authority) -- but it
;   does not have to be reached. The framebuffer holds REAL PLAYPAL indices and
;   DOOM's palette is 16 ramps of 16, each running BRIGHT -> DARK as the low
;   nibble grows, so
;
;       AND = $00      XOR = FUZZ_OR      CTRL = BLT_OR    ->    dst |= FUZZ_OR
;
;   slides every pixel under the spectre toward the dark end of ITS OWN ramp:
;   same hue, the wall still legible through it, and the sprite's own colours
;   never reach the screen. AND = 0 is what makes the source irrelevant (c is
;   then the constant XOR whatever byte was fetched), and OR only ever sets
;   bits, so a pixel can darken but never light up and nothing can flicker.
;   Measured over every wall texture E1M7 uses plus its flat colours
;   (tools/tests/_probe_fuzz.py, previews in _pomocne/preview): mean luminance x0.75
;   where DOOM's row 6 is x0.82, 0.5 % of indices come out brighter, 18 % sit
;   at their ramp's dark end already and do not move.
;
;   The shape is the CROP, i.e. each column's first..last opaque texel, not the
;   per-texel silhouette: with AND = 0 the source bytes cannot stencil. The
;   only difference is that a hole inside the outline (between the legs) fills
;   in. Driving the mask off the art instead (AND = FUZZ_OR, XOR = 0, so
;   c = texel & 7) does keep the exact silhouette, and it was tried -- it turns
;   the demon's own texture into noise, which sounds like fuzz and looks like
;   dirt, and every background pixel of index 0 comes back as $04, which is
;   PLAYPAL's WHITE. See spectre_art07.png next to spectre_span07.png.
;
;   WHAT THIS REPLACES. Two earlier attempts, both wrong:
;     * every other SCREEN COLUMN, the parity flipped per frame. That painted
;       the demon's own red pixels in venetian blinds and, because the parity
;       moved, alternately covered and exposed everything behind it -- at this
;       frame rate a strobe, not a shimmer ("priserý su ciarkovane" on E1M7,
;       whose spectre at (192,-192) is the only MF_SHADOW thing in the
;       episode's first eight maps at this skill).
;     * AND = $40 / BLT_OR, on the reading that an index is (shade << 5) | base
;       so $40 is "two shades darker". That is tools/palette32.py's layout and
;       it was never shipped: setup_palette installs the real 256-colour
;       PLAYPAL, so $40 is just bit 6 of an arbitrary index -- the blit put
;       colour noise wherever the ART happened to carry that bit and nothing at
;       all anywhere else. It also ran 13 bytes past the block into blk_ox /
;       blk_oy, en_solid's 3x3 neighbourhood, because SPRFUZZ_END was $A2BF and
;       BLKTAB_BASE is $A2A0. Both are fixed here and in memory_map.inc.
;
;   ONE PATCH PER SPRITE, not per column: spr_shadow already runs once per
;   vissprite, and every sprite writes all three BCB bytes on its way in, so
;   there is no state to restore and no way to leave the blitter in the wrong
;   mode. spr_blit is the only user of VRAM_BCB_SPR (the HUD has its own copy
;   at MEMW_HD_OFF), so nothing else can see the mode change.
;==============================================================
FUZZ_OR equ $07                      ; how far down its ramp a pixel behind the
                                     ;   spectre slides. THE one byte to tune:
                                     ;   $03 = half as deep, $0F = the ramp's
                                     ;   last entry (too dark, and it inverts
                                     ;   the five ramps that are not monotone).
                                     ;   Must stay inside the low nibble, or it
                                     ;   changes hue instead of brightness.
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SPRFUZZ_BASE
 .endif
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; spr_shadow -- A = thing index, the way spr_dyn wants it. Points the sprite
;   BCB at this thing's blit mode and then IS spr_dyn (tail call, so A, X and
;   the carry come back exactly as before; Y is dead here).
;   254 and 255 are the PSEUDO things -- the player's missile (proj.asm) and the
;   imp's fireball (ball.asm) -- and they have no record in the blob at all:
;   th_things + 254*8 lands past its end, in whatever the level slot still
;   holds, and an F_FUZZ bit there drew the missile as a SPECTRE.
;
;   The three BCB bytes fall out of the flag by shifting, which is why there is
;   no table and no second copy of the code:
;       flags AND F_FUZZ  =  $08 spectre        $00 ordinary
;       >>2, OR $01       =  $03 BLT_OR         $01 BLT_BSTENCIL   CTRL
;       >>3, minus 1      =  $00                $FF                AND
;       EOR $FF, AND 7    =  $07 = FUZZ_OR      $00                XOR
;   The three guards below fail the build if any of those constants moves.
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_shadow
        pha                          ; spr_dyn wants the index back in A
        cmp #254
        bcs ?pseudo
 .if 1
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
 .else
        sta m_prod                   ; record = th_things + i*8
        stz m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc th_things
        sta sp_tab                   ; sp_tab is free right here: both of
        lda m_prod+1                 ;   spr_one's paths load it right after
        adc th_things+1
        sta sp_tab+1
 .endif
        ldy #7
        lda (sp_tab),y
        and #F_FUZZ
?mode   tay                          ; park the flag; A gets shifted apart
        lsr
        lsr
        ora #BLT_BSTENCIL            ; BLT_OR for the spectre
        sta MEMW+MEMW_SP_OFF+BCB_CTRL
        tya
        lsr
        lsr
        lsr
 .if 1
	dec
 .else
        sec
        sbc #1                       ; $00 = ignore the source (spectre),
 .endif
        sta MEMW+MEMW_SP_OFF+BCB_AND ;   $FF = the art straight through
        eor #$FF
        and #FUZZ_OR                 ; the constant the OR writes, or 0
        sta MEMW+MEMW_SP_OFF+BCB_XOR
        pla
        jmp spr_dyn

?pseudo lda #0                       ; no record to read: never a spectre
 .if 1
	bra ?mode
 .else
        beq ?mode                    ;   (always taken)
 .endif
.endp
        .endseg

 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SPRFUZZ_END+1
        ert 'spr_shadow outgrew SPRFUZZ_BASE..END (blk_ox at $A2A0; memory_map.inc)'
    .endif
 .endif
        org sb_resume                ; back to the $B000 sprite block

;==============================================================
; T4 COLUMN CROP + B1 SPRITE ARENA (docs/VRAM-PLAN.md A1 + par.5). The .spr
; file stores each column only from its first to its last opaque texel and
; NEVER preloads: it sits in SDRAM (the level-cache tee) and spr_fget copies
; a frame into the VRAM arena above the level's textures on first use. The
; helpers here are the whole engine side, pinned by tools/_verify_sprcrop.py
; and tools/_verify_arena.py:
;   spr_sidtab   sp_tab = th_sprtab + id*8 (a live thing's row)
;   spr_fget     row byte 0 (frame id) -> sp_addr in the arena + sp_ctab,
;                fetching from SDRAM through the MEMAC window on a miss,
;                flush-when-full (the ONLY path that needs a blitter_wait)
;   spr_ctcol    coltab[x] -> rs_tsrc + sp_ctop/sp_clen (+expand)
;   spr_cspan    raise q over the crop top (qmin = ceil(ctop*S/spy), no div
;                when the span already clears it), y0 16-bit, then cap the
;                reads at the stored end
; zp_ptr lo/hi are free scratch here (the BSP walk is over at draw time and
; every later user reloads them); +2 stays MAP_EXT_BANK = $01, which is
; exactly the bank the .sprcol lives in -- nothing to park back. The copy
; borrows zp_vptr for the SDRAM side and PARKS its bank byte back.
;==============================================================
scrop_resume = *
        org SPRCROP_BASE

;--------------------------------------------------------------
; spr_sidtab -- A = sprite id (a LIVE thing). sp_tab = th_sprtab + id*8.
;   Preserves X. (Lived inline in spr_one; the $B000 segment is full.)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_sidtab
 .if 1
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
 .else
        sta m_prod
        stz m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        clc
        lda m_prod
        adc th_sprtab
        sta sp_tab
        lda m_prod+1
        adc th_sprtab+1
        sta sp_tab+1
 .endif
        rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_fget -- A = frame id. sp_addr = the frame's ARENA address and sp_ctab =
;   its coltab, straight from the FTAB; on a residency miss the pixels are
;   copied out of SDRAM first (spr_fcopy). Flush-when-full: wipe FARENA, bump
;   back to the arena floor -- with ONE blitter_wait, because a queued blit
;   may still be reading the old bytes; the ordinary fetch needs none (it
;   writes above everything a queued blit can see). Clobbers X on a flush
;   (spr_one is past its ,x reads by the time it resolves the frame).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_fget
        sta sp_fid
 .if 1                               ; 2026-09-15: ON -- native from urom_init (DRAC_PLAN 4a) and the
                                     ;   .else side reps itself. Was .if 0:  E=1 BLOCK (2026-09-09): arena_prefetch calls this at LEVEL LOAD
                                     ;   with the ROM IN = emulation mode, where rep/sep cannot touch M/X:
                                     ;   `and #$00ff` decodes as and #$FF + BRK at $7917 (tools/tests/
                                     ;   _probe_draco_emu.py, _bench_frame.py). The .else side is what runs
                                     ;   until the prefetch moves behind rom_out.
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
                                     ;   >FARENA_EXT ($FC) has clear. So the
                                     ;   whole low half of the add is a no-op and
                                     ;   the high half cannot carry: ora IS the
                                     ;   add here, and the .if above fails the
                                     ;   BUILD if that ever stops being true.
                                     ;   (2026-08-25: this and the stz above pay
                                     ;   for the 24-bit ceiling test below --
                                     ;   $7900-$7C9D was full to the byte.)
;       lda zp_ptr                   ; the flush path clobbers zp_ptr -- keep
        sta sf_ent                   ;   the entry address for the store back
        lda [zp_ptr]		;word fetch
        sta sp_addr		;word write
        ldy #2

	sep #$20
	.LONGA OFF
 .else
        sta zp_ptr                   ; FTAB entry = FTAB_EXT + id*8
        stz zp_ptr+1
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
        lda #SPRCOL_BANK             ; the FTAB rode out of bank $01 with the
        sta zp_ptr+2                 ;   coltab it indexes

        ldy #0                       ; u24 file offset
        lda [zp_ptr],y
        sta sf_off
        iny
        lda [zp_ptr],y
        sta sf_off+1
        iny
        lda [zp_ptr],y
        sta sf_off+2
        iny
        lda [zp_ptr],y               ; u16 stored size
        sta sf_size
        iny
        lda [zp_ptr],y
        sta sf_size+1
        iny
        lda [zp_ptr],y               ; u16 coltab addr
        sta sp_ctab
        iny
        lda [zp_ptr],y
        sta sp_ctab+1

        lda #MAP_EXT_BANK            ; FARENA is runtime-only and stayed behind
        sta zp_ptr+2
        lda sp_fid                   ; FARENA entry = FARENA_EXT + id*3: id*2
        rep #$20                     ;   + id in A, the page bits of FARENA_EXT
        .LONGA ON                    ;   or'ed in (it is page-aligned and the
        and #$00FF                   ;   entry is at most 762, see the ert),
        sta zp_ptr                   ;   one word store (drac030 idiom)
        asl @                        ; (C = 0: a byte doubled)
        adc zp_ptr
        ora #[FARENA_EXT & $FFFF]
        sta zp_ptr
        .LONGA OFF
        sep #$20
;       sta zp_ptr+1
    .if [FARENA_EXT & $FF] > 0 || [[FARENA_EXT >> 8] & $03] > 0
        ert 'FARENA_EXT moved: the ora below is no longer the 16-bit add'
    .endif
;       lda zp_ptr+1                 ; + FARENA_EXT. It is PAGE-ALIGNED and id*3
                                     ;   >FARENA_EXT ($FC) has clear. So the
                                     ;   whole low half of the add is a no-op and
                                     ;   the high half cannot carry: ora IS the
                                     ;   add here, and the .if above fails the
                                     ;   BUILD if that ever stops being true.
                                     ;   (2026-08-25: this and the stz above pay
                                     ;   for the 24-bit ceiling test below --
                                     ;   $7900-$7C9D was full to the byte.)
        lda zp_ptr                   ; the flush path clobbers zp_ptr -- keep
        sta sf_ent                   ;   the entry address for the store back
        lda zp_ptr+1
        sta sf_ent+1
        ldy #0
        lda [zp_ptr],y
        sta sp_addr
        iny
        lda [zp_ptr],y
        sta sp_addr+1
        iny
 .endif
        lda [zp_ptr],y
        sta sp_addr+2
        ora sp_addr+1
        ora sp_addr
        beq ?miss
        rts                          ; resident: nothing to copy

?miss   rep #$21                     ; room? bump + size vs the ceiling: the low
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
        bcc ?fits                    ; 2026-08-25: this used to be `ora m_a /
        bne ?flush                   ;   beq ?fits`, i.e. "over unless dead on
        lda m_a                      ;   $xx0000". That is only right while the
        beq ?fits                    ;   top sits ON a 64 KB boundary, and it
                                     ;   did ($040000) until 2026-08-18 moved it
                                     ;   to $03D000 for the EPISODE menu. From
                                     ;   then the test rounded the ceiling DOWN
                                     ;   to $030000: the 12 KB that change meant
                                     ;   to spend cost 64 KB, and the arena ran
                                     ;   at 96 KB of its 148 -- below the 128 KB
                                     ;   that was already known to flush too
                                     ;   much. Measured, not read: see
                                     ;   tools/tests/_verify_arena.py part 6,
                                     ;   which now pins eff ceiling == the equ.
                                     ;   (end-EXCLUSIVE: end == the top fits)
?flush  jsr blitter_wait             ; a queued blit may read the old frames

 .if 1
	rep #$20
	.LONGA ON
	lda #FARENA_EXT
	sta zp_ptr

	ldx #3
	ldy #0
	tya			;16-bits from Y to A
?clb    sta [zp_ptr],y		;14 cycles * 384 iterations = 5376+33 cycles
        iny
	iny
        bne ?clb
        inc zp_ptr+1		;zp_ptr=$01FC00, never exceeds $01FF00
        dex
        bne ?clb

        lda ar_base                  ; bump back to the arena floor
        sta ar_bump
        ldy ar_base+2
        sty ar_bump+2

	sep #$20
	.LONGA OFF
 .else
        lda #<FARENA_EXT             ; FARENA[*] = 0 (3 pages cover 765 B)
        sta zp_ptr
        lda #>FARENA_EXT
        sta zp_ptr+1

        ldx #3
        lda #0
        tay
?clb    sta [zp_ptr],y		;11 cycles * 768 iterations = 8448+30 cycles
        iny
        bne ?clb
        inc zp_ptr+1
        dex
        bne ?clb

        lda ar_base                  ; bump back to the arena floor
        sta ar_bump
        lda ar_base+1
        sta ar_bump+1
        lda ar_base+2
        sta ar_bump+2
 .endif

?fits
 .if 1                               ; 2026-09-15: ON -- native from urom_init (DRAC_PLAN 4a) and the
                                     ;   .else side reps itself. Was .if 0:  E=1 BLOCK (2026-09-09): arena_prefetch calls this at LEVEL LOAD
                                     ;   with the ROM IN = emulation mode, where rep/sep cannot touch M/X:
                                     ;   `and #$00ff` decodes as and #$FF + BRK at $7917 (tools/tests/
                                     ;   _probe_draco_emu.py, _bench_frame.py). The .else side is what runs
                                     ;   until the prefetch moves behind rom_out.
	rep #$20		;branches here with 8-bit accumulator, so we have to do this switch, sadly
	.LONGA ON
	lda sf_ent
        sta zp_ptr

        lda ar_bump
        sta sp_addr
        sta [zp_ptr]
	ldy #2

	sep #$20
	.LONGA OFF
 .else
	lda sf_ent
        sta zp_ptr
        lda sf_ent+1
        sta zp_ptr+1

        ldy #0                       ; FARENA[id] = sp_addr = the bump
        lda ar_bump
        sta sp_addr
        sta [zp_ptr],y
        iny
        lda ar_bump+1
        sta sp_addr+1
        sta [zp_ptr],y
        iny
 .endif
        lda ar_bump+2
        sta sp_addr+2
        sta [zp_ptr],y
 .if 1                               ; 2026-09-15: ON -- native from urom_init (DRAC_PLAN 4a) and the
                                     ;   .else side reps itself. Was .if 0:  E=1 BLOCK (2026-09-09): arena_prefetch calls this at LEVEL LOAD
                                     ;   with the ROM IN = emulation mode, where rep/sep cannot touch M/X:
                                     ;   `and #$00ff` decodes as and #$FF + BRK at $7917 (tools/tests/
                                     ;   _probe_draco_emu.py, _bench_frame.py). The .else side is what runs
                                     ;   until the prefetch moves behind rom_out.
	rep #$21
	.LONGA ON
        lda ar_bump
        adc sf_size
        sta ar_bump
	bcc ?skip1
	ldy ar_bump+2
	iny
	sty ar_bump+2
	clc
?skip1
;       clc                          ; sf_src = spr_sdram + sf_off (tex_fget
        lda spr_sdram                ;   hands spr_fcopy its own source)
        adc sf_off
        sta sf_src
	sep #$20
	.LONGA OFF
 .else
        clc                          ; bump += size (the copy reads sp_addr)
        lda ar_bump
        adc sf_size
        sta ar_bump
        lda ar_bump+1
        adc sf_size+1
        sta ar_bump+1
        lda ar_bump+2
        adc #0
        sta ar_bump+2

        clc                          ; sf_src = spr_sdram + sf_off (tex_fget
        lda spr_sdram                ;   hands spr_fcopy its own source)
        adc sf_off
        sta sf_src
        lda spr_sdram+1
        adc sf_off+1
        sta sf_src+1
 .endif
        lda spr_sdram+2
        adc sf_off+2
        sta sf_src+2
        ; fall through: fetch the pixels
.endp
        .endseg
;--------------------------------------------------------------
; spr_fcopy -- sf_size bytes, SDRAM (sf_src) -> VRAM at sp_addr, through the
;   MEMAC window. Byte loop (~30 cyc/B: 2 KB typical frame is ~3 ms, the
;   plan's first-look hitch). Parks the window back on the overhead bank and
;   zp_vptr+2 back on MAP_EXT_BANK. Preserves X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_fcopy
        lda sf_size                  ; nothing stored (every column empty)?
        ora sf_size+1
        bne ?go
        rts

?go     lda sf_src                   ; zp_vptr walks the SDRAM source
        sta zp_vptr
        lda sf_src+1
        sta zp_vptr+1
        lda sf_src+2
        sta zp_vptr+2

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
        ora #BANK_EN
        sta VBXE_BANK_SEL
        lda sp_addr                  ; window ptr = MEMW + (dst & $0FFF)
        sta zp_ptr
        lda sp_addr+1
 .if 1                                ; DRAC_PLAN 3b: 16 KB window
        and #$3F
        ora #>MEMW16
        sta zp_ptr+1
 .else
        and #$0F
        ora #>MEMW
        sta zp_ptr+1
 .endif
 .if 1                               ; 2026-09-15: ON -- native from urom_init (DRAC_PLAN 4a); snd_irq
                                     ;   pushes X at 16 bits first, so the width is IRQ-safe. Was .if 0:  E=1 BLOCK (2026-09-09): arena_prefetch calls this at LEVEL LOAD
                                     ;   with the ROM IN = emulation mode, where rep/sep cannot touch M/X:
                                     ;   `and #$00ff` decodes as and #$FF + BRK at $7917 (tools/tests/
                                     ;   _probe_draco_emu.py, _bench_frame.py). The .else side is what runs
                                     ;   until the prefetch moves behind rom_out.
	phx
	rep #$10
	.LONGI ON
	ldx sf_size
?byte   lda [zp_vptr]
        sta (zp_ptr)
 .else
        ldy #0
?byte   lda [zp_vptr],y
        sta (zp_ptr),y
 .endif
        inc zp_vptr                  ; 24-bit source walk (SDRAM is linear)
        bne ?s1
        inc zp_vptr+1
        bne ?s1
        inc zp_vptr+2
?s1     inc zp_ptr                   ; window walk, re-banking every 4 KB
        bne ?d1
        inc zp_ptr+1
        lda zp_ptr+1
 .if 1                                ; DRAC_PLAN 3b: 16 KB window
        cmp #[>MEMW16]+$40
        bcc ?d1
        lda sf_bank                  ; next 16 KB page
        and #$7C
        clc
        adc #4
        sta sf_bank
        ora #BANK_EN
        sta VBXE_BANK_SEL
        lda #>MEMW16
        sta zp_ptr+1
 .else
        cmp #[>MEMW]+$10
        bcc ?d1
        inc sf_bank
        lda sf_bank
        ora #BANK_EN
        sta VBXE_BANK_SEL
        lda #>MEMW
        sta zp_ptr+1
 .endif
?d1
 .if 1                               ; 2026-09-15: ON -- native from urom_init (DRAC_PLAN 4a); snd_irq
                                     ;   pushes X at 16 bits first, so the width is IRQ-safe. Was .if 0:  E=1 BLOCK (2026-09-09): arena_prefetch calls this at LEVEL LOAD
                                     ;   with the ROM IN = emulation mode, where rep/sep cannot touch M/X:
                                     ;   `and #$00ff` decodes as and #$FF + BRK at $7917 (tools/tests/
                                     ;   _probe_draco_emu.py, _bench_frame.py). The .else side is what runs
                                     ;   until the prefetch moves behind rom_out.
	dex
        bne ?byte
	sep #$10
	.LONGI OFF
	plx
 .else
	lda sf_size                  ; 16-bit countdown, 8-bit A: borrow first
        bne ?d2
        dec sf_size+1
?d2     dec sf_size                  ; dec sets Z -> no reload; lo != 0 loops,
        bne ?byte                    ;   lo == 0 loops while hi != 0 (== the
        lda sf_size+1                ;   old lda/ora). The .else side had lost
        bne ?byte                    ;   its loop branch: 1 byte/frame copied
                                     ;   (spr.png, 2026-09-09)
 .endif

        lda #BANK_EN|BANK_OVERHEAD   ; park the window back on the BCB bank
        sta VBXE_BANK_SEL
        lda #MAP_EXT_BANK            ; ...and the borrowed pointer's bank byte
        sta zp_vptr+2                ;   (engine-wide constant, see init_level)
        rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_ctcol -- A = source column x. Reads coltab entry x (4 B: u16 off,
;   u8 top, u8 len): rs_tsrc = sp_addr + off (the CROPPED column's base),
;   sp_ctop/sp_clen the crop -- and for S = 8 expands exactly the stored
;   span into the scratch (the crop cap makes the old +12 guard unreachable,
;   so none is expanded). len 0 leaves rs_tsrc dangling on purpose: spr_cspan
;   returns C=0 for it before anything reads pixels.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_ctcol
 .if 1
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
	ldy #1

	sep #$20
	.LONGA OFF
 .else
        sta m_a                      ; entry = sp_ctab + x*4
        stz m_a+1
        asl m_a
        rol m_a+1
        asl m_a
        rol m_a+1

        clc
        lda m_a
        adc sp_ctab
        sta zp_ptr
        lda m_a+1
        adc sp_ctab+1
        sta zp_ptr+1
        lda #SPRCOL_BANK
        sta zp_ptr+2

        ldy #0
        lda [zp_ptr],y               ; off, frame-relative
        clc
        adc sp_addr
        sta rs_tsrc
        iny
        lda [zp_ptr],y
        adc sp_addr+1
        sta rs_tsrc+1
 .endif
        lda #0
        adc sp_addr+2
        sta rs_tsrc+2
        iny
        lda [zp_ptr],y               ; top
        sta sp_ctop
        iny
        lda [zp_ptr],y               ; len
        sta sp_clen		;clen address is ctop+1
        beq ?out                     ; fully transparent: nothing to expand

        lda sp_s
        cmp #2
        bcc ?out                     ; S = 1: blit straight from the sprite
        stz tw_t0
        lda sp_clen                  ; expand the stored span only; 128 texels
        cmp #129                     ;   = the whole 1 KB scratch, and the cap
        bcc ?need                    ;   keeps every read under min(len,128)*8
        lda #128
?need   sta tw_need
        lda sp_s
        sta tw_s
        jsr tw_expand_spr            ; column -> the current scratch, S samples
                                     ;   per texel (a chain of one: the sprite
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
;       C=0: nothing of this column survives the crop/clip.
;   Clobbers A/X/Y, m_a/m_b/m_prod/m_den/m_quot (umul16 + up to 2 udiv24).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_cspan
        lda sp_clen
        bne ?some
?none   clc                          ; empty column
        rts
?some
 .if 1
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
	lda sp_q
	sta m_a
	lda sp_spy
	sta m_b
	sep #$20
	.LONGA OFF
 .else
	lda sp_ctop                  ; sp_csmp = ctop * S, in samples
        sta sp_csmp
        stz sp_csmp+1
        lda sp_s
        cmp #2
        bcc ?cs
        asl sp_csmp
        rol sp_csmp+1
        asl sp_csmp
        rol sp_csmp+1
        asl sp_csmp
        rol sp_csmp+1
?cs     lda sp_q                     ; m_prod = q * spy (the raw offset)
        sta m_a
        lda sp_q+1
        sta m_a+1
        lda sp_spy
        sta m_b
        lda sp_spy+1
        sta m_b+1
 .endif
        jsr umul16

 .if 1
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

	sep #$20
	.LONGA OFF
 .else
        lda m_prod                   ; already at/below the crop top?
        cmp sp_csmp
        lda m_prod+1
        sbc sp_csmp+1
        bcs ?soff                    ; yes: no division, just subtract

;       clc                          ; qmin = ceil(csamp/spy): divide
        lda sp_csmp                  ;   (csamp + spy - 1) by spy
        adc sp_spy
        sta m_prod
        lda sp_csmp+1
        adc sp_spy+1
        sta m_prod+1

        sec
        lda m_prod
        sbc #1
        sta m_prod
        lda m_prod+1
        sbc #0
        sta m_prod+1
        stz m_prod+2

        lda sp_spy
        sta m_den
        lda sp_spy+1
        sta m_den+1
 .endif
        jsr udiv24
 .if 1
	rep #$20
	.LONGA ON
        lda m_quot                   ; q = qmin, and redo q*spy with it
        sta sp_q
        sta m_a
        lda sp_spy
        sta m_b
	sep #$20
	.LONGA OFF
 .else
        lda m_quot                   ; q = qmin, and redo q*spy with it
        sta sp_q
        sta m_a
        lda m_quot+1
        sta sp_q+1
        sta m_a+1
        lda sp_spy
        sta m_b
        lda sp_spy+1
        sta m_b+1
 .endif
        jsr umul16
?soff
 .if 1
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
 .else
	sec                          ; sp_soff = q*spy - csamp (>= 0 now)
        lda m_prod
        sbc sp_csmp
        sta sp_soff
        lda m_prod+1
        sbc sp_csmp+1
        sta sp_soff+1

        lda sp_q                     ; y0 = ytop + q, 16-BIT: the crop raise
        sta m_a                      ;   can push it past the screen, where the
        lda sp_q+1                   ;   old byte add silently wrapped. (q*z, and
        sta m_a+1                    ;   z is 1 -- the shift loop went with it)
        clc
        lda m_a
        adc sp_ytop
        sta sp_y0
        lda m_a+1
        adc sp_ytop+1
        beq ?rd
 .endif
?off    clc                          ; y0 >= 256: below every window
        rts

?rd     sec                          ; reads = y1 - y0 + 1 (z is 1: no >> zsh)
        lda sp_y1
        sbc sp_y0
        bcc ?off
 .if 1
	; nothing
 .else
        inc
        sec
        sbc #1
        bcc ?off                     ; less than one source read fits
 .endif
        sta sp_bh                    ; the clip half of the count

        lda sp_clen                  ; smax+1 = min(len, S=8 ? 128 : len) * S
        ldx sp_s
        cpx #2
        bcc ?sm1
        cmp #129
        bcc ?sm8
        lda #128                     ; the scratch holds 128 texels
 .if 1                                ; 2026-09-15: smax stays in A -- the x8, the
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
        sta m_prod
        stz m_prod+2                 ; (a word: +2 and +3)
        lda sp_spy
        sta m_den
        .LONGA OFF
        sep #$20                     ; (sep keeps C: the sbc's)
        bcc ?off                     ; the whole span starts past the crop end
 .else
?sm8    sta m_a
	stz m_a+1
	rep #$20
	.LONGA ON
	lda m_a
	asl
	asl
	asl
	sta m_a
	sep #$20
	.LONGA OFF
	bra ?room
?sm1    sta m_a
	stz m_a+1
?room
	rep #$20
	.LONGA ON
	lda m_a
	dec
	sec
	sbc sp_soff
	sta m_prod
	sep #$20
	.LONGA OFF
        bcc ?off                     ; the whole span starts past the crop end

        stz m_prod+2
        lda sp_spy
        sta m_den
        lda sp_spy+1
        sta m_den+1
 .endif

        jsr udiv24                   ; m_quot = cap-1 = floor(room/spy)

        lda m_quot+1
        bne ?ok                      ; cap >= 256 reads: the clip count stands
        lda m_quot
        cmp sp_bh
 .if 1
	bcs ?ox
	sta sp_bh
?ok	sec
?ox	rts
 .else
        bcs ?ok
        sta sp_bh                    ; the crop end is the tighter limit
?ok     sec
	rts
 .endif
.endp
        .endseg
    .if * > SPRCROP_END+1
        ert 'the T4 crop helpers outgrew SPRCROP_BASE..END (memory_map.inc)'
    .endif
        org scrop_resume
