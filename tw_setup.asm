; AUTO-SPLIT from textures.asm 2026-07-24 -- assembled in place via icl (verified
; byte-identical). Everything the textured wall blit needs BEFORE the blit, and
; all of it relocated out of the cramped $A800 segment:
;   TWCLIP_BASE  seg_len, tw_texmask, wall_src, low_src, draw_twall_clip
;   TWSETUP_BASE tw_setup (per-column texel rate: tpr, oversampling S, SRC_STEPY,
;                ZOOMY), plus the long commentary on why the rate ladder exists.
twclip_resume = *
        ; PINNED FAST (2026-08-11): the hottest former win2 block (~21% of the
        ; frame in x11.2 fetches) -- never move it back to $8000-$BFFF.
        org TWCLIP_BASE
; seg_len -- GONE (2026-09-28). It estimated |v2 - v1| as max - max/8 + min/2,
;   which is 12.5 % SHORT on an axis-aligned seg (112 for a 128-unit door):
;   the texture was stretched by a seventh. rs_seglen is the map's own number
;   now, exact and cheaper -- MAP_SEGLEN (pack_map.py _seglen), read where
;   process_seg marks the line for the automap.

;--------------------------------------------------------------
; tw_texmask -- from rs_texh_cur derive rs_texmask = texH*256-1 and rs_texpow2 =
;   texH AND (texH-1). When that flag is 0 the texture height is a power of two
;--------------------------------------------------------------
twmask_resume = *
        org TWMASK_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tw_texmask
        lda #$FF
        sta rs_texmask
        lda rs_texh_cur
	dec
        sta rs_texmask+1
        and rs_texh_cur
        sta rs_texpow2
        rts
.endp
        .endseg
    .if * > TWMASK_END+1
        ert 'tw_texmask outgrew TWMASK_BASE..TWMASK_END (memory_map.inc)'
    .endif
        org twmask_resume

;--------------------------------------------------------------
; wall_src / low_src -- compute the current column's texture source addr into
;   rs_tsrc and rs_texh_cur, for the WALL (col_a) resp. LOWER-step (col_b)
;   texture. tex_x = (col - sxL) & wmask (linear-u first cut; per-seg restart,
;   seams accepted -- see textures-prototype memory). Column-major layout:
;   src = base + tex_x*texH. Caller must have set rs_wtex*/rs_ltex* per seg.
;--------------------------------------------------------------
    .if TEX_RUNS
    .if TEX_RUNSH < 6 || TEX_RUNSH > 7
        ert 'the closed form below is TEX_RUNSH = 6 or 7 -- see map_syms.inc'
    .endif
;--------------------------------------------------------------
; wall_src / low_src (2026-09-29) -- clip rs_ra/rs_rb to [rs_top, rs_bot] ->
;   rs_spa/rs_spb, then the column's run address to paint_col.pc_in: A = its
;   low word, Y = its bank. tx_slot picks the tile (0 wall, 1 lower step).
;   IN: 8-bit M, X = the column. OUT: 8-bit M, X kept.
;--------------------------------------------------------------
tx_slot = rs_vsh
        .segment B1
.proc wall_src
        lda rs_ra+1                  ; a = max(rs_ra, top); > bot -> nothing
        bmi ?atop
        bne ?out
        lda rs_ra
        cmp rs_top
        bcc ?atop
        cmp rs_bot
        bcc ?aset                    ; (cmp keeps A = rs_ra)
        beq ?aset
?out    rts
?atop   lda rs_top
?aset   sta rs_spa
        lda rs_rb+1                  ; b = min(rs_rb, bot); < top -> nothing
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot                   ; rb < bot is the common case: it falls through
        bcs ?bbot
?bset   sta rs_spb
        cmp rs_spa                   ; draw only if spb >= spa
        bcc ?out
        stz tx_slot                  ; the WALL's tile
        lda rs_uacc+1                ; tex_x = world u along the seg (Q8 -> texels)
        and rs_wtexwm
        txy                          ; the column waits in Y: long is X-indexed only
        tax
wix     lda.l $000000,x              ; which STORED column that is (pack_textures
        tyx                          ;   dedup_columns; the operand is per seg)
        xba                          ; A = column << 8 as a word: the byte into B,
        lda #0                       ;   a written 0 under it
        rep #$20
        .LONGA ON
        .rept 8-TEX_RUNSH            ; the stride is 64 or 128
        lsr @
        .endr
        adc rs_wtexad                ; + the texture's base (C = 0: zeros shifted out)
        ldy rs_wtexad+2              ; ... and its SDRAM bank byte, with the carry
        bcs ?binc
        jmp paint_col.pc_in
?binc   iny
        jmp paint_col.pc_in
        .LONGA OFF
?bbot   lda rs_bot                   ; (the rare b >= bot, out of line)
        bra ?bset
.endp
        .endseg

        .segment B1
.proc low_src
        lda rs_ra+1                  ; (the clip, as wall_src)
        bmi ?atop
        bne ?out
        lda rs_ra
        cmp rs_top
        bcc ?atop
        cmp rs_bot
        bcc ?aset
        beq ?aset
?out    rts
?atop   lda rs_top
?aset   sta rs_spa
        lda rs_rb+1
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot
        bcs ?bbot
?bset   sta rs_spb
        cmp rs_spa
        bcc ?out
        lda #1                       ; the LOWER step's tile
        sta tx_slot
        lda rs_uacc+1                ; world u, same track as wall_src
        and rs_ltexwm
        txy
        tax
lix     lda.l $000000,x              ; the LOWER step's own index array, in SDRAM
        tyx
        xba
        lda #0
        rep #$20
        .LONGA ON
        .rept 8-TEX_RUNSH
        lsr @
        .endr
        adc rs_ltexad
        ldy rs_ltexad+2
        bcs ?binc
        jmp paint_col.pc_in
?binc   iny
        jmp paint_col.pc_in
        .LONGA OFF
?bbot   lda rs_bot
        bra ?bset
.endp
        .endseg
    .else                            ; !TEX_RUNS: the blitted walls, as they were
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wall_src
        lda rs_uacc+1                ; tex_x = world u along the seg (Q8 -> texels)
        and rs_wtexwm
    .if TEX_RUNS
                                      ; 2026-09-23: the column index waits in Y, not on
        txy                          ;   the stack (Y is dead here: the tay below
        tax                          ;   and absolute long is X-indexed only
wix     lda.l $000000,x
        tyx
	tay                          ; the stored column, PARKED IN Y (2026-09-15):
    .else
        tay                          ; ...and then which STORED column that is:
wix     lda $FFFF,y                  ;   pack_textures.dedup_columns keeps one copy
    .endif
                                     ;   of each distinct column and this array says
                                     ;   which.
        lda rs_wtexh                 ; tw_texmask INLINED (2026-09-15): the mask
        sta rs_texh_cur              ;   (texH*256-1) and the pow2 flag, without
        dec                          ;   the jsr/rts and the rs_texh_cur reload.
        sta rs_texmask+1             ;   rs_texmask's low byte is rewritten
        and rs_wtexh                 ;   because the cell lives in the SIO staging
        sta rs_texpow2               ;   pages (see tw_texmask's header)
                                      ; ... but NOTHING reads that low byte: paint.asm
    .if TEX_RUNS
    .if TEX_RUNSH < 6 || TEX_RUNSH > 7
        ert 'the closed form below is TEX_RUNSH = 6 or 7 -- see map_syms.inc'
    .endif
        ; 16-BIT A (2026-08-31, the drac030 hand-review): the split ...
        rep #$20
        .LONGA ON
        tya                          ; the column: Y is 8-bit, so B comes out 0
	xba
        .rept 8-TEX_RUNSH            ; (2026-09-28: the stride is 64 or 128)
	lsr
        .endr
;       clc
        adc rs_wtexad                ; rs_tsrc = wtexad + (txx<<TEX_RUNSH)
        sta rs_tsrc
        .LONGA OFF
        sep #$20
        lda rs_wtexad+2              ; ... + the SDRAM bank byte, with the
        adc #0                       ;     16-bit add's carry
        sta rs_tsrc+2
        bra draw_twall_clip          ; TAIL CALL (2026-09-15): both callers jsr'd
    .else
        qsmul rs_txx, rs_wtexh, qs_p       ; qs_p = tex_x * texH  (<=127*128, fits 16b)
	rep #$21
	.LONGA ON
        lda rs_wtexad
        adc qs_p
        sta rs_tsrc
	sep #$20
	.LONGA OFF
        lda rs_wtexad+2
        adc #0
        sta rs_tsrc+2
        jmp draw_twall_clip          ; (tail call, as the TEX_RUNS path above)
    .endif
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc low_src
        lda rs_uacc+1                ; world u, same track as wall_src
        and rs_ltexwm
    .if TEX_RUNS
                                      ; 2026-09-23: as wall_src -- X waits in Y
        txy
        tax
lix     lda.l $000000,x              ; the LOWER step's own index array, in SDRAM
        tyx
	tay                          ; (as wall_src: the column parks in Y)
    .else
        tay
lix     lda $FFFF,y                  ; the LOWER step's own column index array
    .endif
        lda rs_ltexh                 ; tw_texmask inlined (as wall_src, 2026-09-15)
        sta rs_texh_cur
        dec
        sta rs_texmask+1
        and rs_ltexh
        sta rs_texpow2
                                      ; (the low byte has no reader, as wall_src)
    .if TEX_RUNS
    .if TEX_RUNSH < 6 || TEX_RUNSH > 7
        ert 'the closed form below is TEX_RUNSH = 6 or 7 -- see map_syms.inc'
    .endif
        rep #$20                     ; same 16-bit fusion as wall_src above
        .LONGA ON
        tya
	xba
        .rept 8-TEX_RUNSH
	lsr
        .endr
;       clc
        adc rs_ltexad                ; rs_tsrc = ltexad + (txx<<TEX_RUNSH)
        sta rs_tsrc
        .LONGA OFF
        sep #$20
        lda rs_ltexad+2
        adc #0
        sta rs_tsrc+2
                                      ; FALLS THROUGH into draw_twall_clip, the next
    .else
        qsmul rs_txx, rs_ltexh, qs_p
        clc
        lda rs_ltexad
        adc qs_p
        sta rs_tsrc
        lda rs_ltexad+1
        adc qs_p+1
        sta rs_tsrc+1
        lda rs_ltexad+2
        adc #0
        sta rs_tsrc+2
                                      ; (falls through, as the TEX_RUNS path above)
    .endif
.endp
        .endseg

;--------------------------------------------------------------
; draw_twall_clip -- like draw_clip but textured: clip raw signed16 rows
;   rs_ra/rs_rb to [rs_top,rs_bot] -> rs_spa/rs_spb, then draw the textured
;   column (rs_tsrc/rs_texh_cur must already be set for this column). Preserves X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc draw_twall_clip
        lda rs_ra+1                  ; a = max(rs_ra, top); >bot -> nothing
        bmi ?atop
        bne ?out
        lda rs_ra
        cmp rs_top
        bcc ?atop
        cmp rs_bot
        bcc ?aset                    ; cmp does not touch A, so A IS rs_ra here:
        bne ?out                     ;   the old ?ara reloaded what it had, and
        bra ?aset                    ;   the jmp round it went away with it
?atop   lda rs_top
?aset   sta rs_spa
        lda rs_rb+1                  ; b = min(rs_rb, bot); <top -> nothing
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot                   ; 2026-09-27 (6502-cycles-layout): rb < bot is
        bcs ?bbot                    ;   298 of 350 a frame -- it falls through now
?bset   sta rs_spb
        cmp rs_spa                   ; draw only if spb >= spa; A is the value
        bcc ?out                     ;   just stored, so no reload
    .if TEX_RUNS
        ; THE HEIGHT/TOP HANDOFF IS DEAD HERE (2026-08-30). paint_col reads the ...
        jmp paint_col.pc_in          ; tail-call (preserves X) -- paint.asm
    .else
;       sec                          ; draw_twall_col DOES take A=top, Y=height
        sbc rs_spa
	inc
        tay                          ; height = spb-spa+1
        lda rs_spa                   ; top row
        jmp draw_twall_col           ; tail-call (preserves X)
    .endif
?out    rts
?bbot   lda rs_bot                   ; (the rare b >= bot, out of line, 2026-09-27)
        bra ?bset
.endp
        .endseg
    .endif                           ; TEX_RUNS
    .if * > TWCLIP_END+1
        ert 'seg_len/wall_src/low_src/draw_twall_clip outgrew TWCLIP_BASE..END (memory_map.inc)'
    .endif
        org twclip_resume            ; back to the $A800 blit segment

; tw_setup -- DELETED 2026-08-27. It computed tpr = 4096*worldH/dscr with a
; udiv24 per call, and because tpr is a RECIPROCAL and curves, colmerge.asm
; carried a whole anchor/interpolate machine to avoid paying that per column.
; rs_tpr is now one table reciprocal of rs_rpt, which pt_seg already tracks
; exactly-linearly -- see pt_recip in paint.asm, which took over this block
; (PTRECIP_BASE == the old TWSETUP_BASE). The rate ladder the .if !TEX_RUNS
; half configured (tw_use8/tw_s/tw_ssh/tw_rsh/tw_spy/tw_rpt) only ever drove
; the BLITTER, which TEX_RUNS replaced in 2026-08; it went with it.

