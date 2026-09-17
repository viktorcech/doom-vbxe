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
;--------------------------------------------------------------
; seg_len -- rs_seglen = |v2 - v1| in world units, from the player-relative
;   endpoints (rotation preserves length). Octagonal approximation
;   max + min/2 - max/8, ~3% high; a constant per-seg scale error is invisible,
;   a sqrt per seg would not be. Clobbers A/Y and m_a/m_b.
;--------------------------------------------------------------
; 16-BIT (2026-08-29). The two differences, the unsigned compare that orders
; them, the swap and the shifts are all 16-bit quantities; only m_neg/m_negb
; are 8-bit code. `sep` touches M alone, so the N the subtract set survives it
; and the `bpl` still reads the sign of the 16-bit result.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc seg_len
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
seg_len16                            ; (am_mark arrives 16-bit already)
        sec                          ; m_a = |dx|
        lda zp_rx2
        sbc zp_rx1
 .if 1
	bpl ?dxp
	eor #$ffff
	inc
?dxp	sta m_a

        sec                          ; m_b = |dy|
        lda zp_ry2
        sbc zp_ry1
	bpl ?dyp
	eor #$ffff
	inc
?dyp	sta m_b
 .else
        sta m_a
        .LONGA OFF
        sep #$20
        bpl ?dxp
        jsr m_neg
?dxp    rep #$20
        .LONGA ON
        sec                          ; m_b = |dy|
        lda zp_ry2
        sbc zp_ry1
        sta m_b
        .LONGA OFF
        sep #$20
        bpl ?dyp
        jsr m_negb
?dyp    rep #$20
        .LONGA ON
 .endif
        lda m_a                      ; which is the max? -- one unsigned 16-bit
        cmp m_b                      ;   compare, and then NO swap: each order
        bcs ?omax                    ;   has its own tail (2026-09-15). The tail
 .if 1                                ;   is L = max - max/8 + min/2, the max/8
        lsr m_a                      ;   negated in A (~q + 1 + max) so nothing
        lda m_b                      ;   goes through m_res -- same 16-bit sum
        lsr                          ;   as max + min/2 - max/8
        lsr
        lsr
        eor #$FFFF
        sec
        adc m_b                      ; max - max/8 (this add always carries out)
        clc
        adc m_a                      ; + min/2
        bra ?fin
?omax   lsr m_b                      ; min/2
  .if 1                               ; A still holds m_a: the lda at the top, and
  .else                               ;   cmp/bcs/lsr m_b leave A alone (-4/seg)
        lda m_a
  .endif
        lsr
        lsr
        lsr
        eor #$FFFF
        sec
        adc m_a
        clc
        adc m_b
?fin
 .else
	pha			;A is already loaded, contains m_a
	lda m_b
	sta m_a
	pla
	sta m_b
?omax   lsr m_b                      ; min/2
        lda m_a                      ; max/8 -> m_res
	lsr
	lsr
	lsr
	sta m_res
        clc                          ; L = max + min/2 - max/8
        lda m_a
        adc m_b
        sec
        sbc m_res
 .endif
 .if 1
    .if TEX_HALFW
        ; 2:1 HORIZONTAL DOWNSAMPLE (pack_textures.py HALF_W). The stored texture
        ; is half as wide, so one texel spans TWO world units along the wall. u is
        ; a world-unit track, so halving it here -- once per seg -- is the entire
        ; runtime cost of the change: wall_src/low_src and the per-column loop are
        ; untouched, and the AND wrap still works because w/2 stays a power of two.
    	lsr
    .endif
	bne ?ok
	inc
?ok	sta rs_seglen
	sep #$20
	.LONGA OFF
	rts
 .else
        sta rs_seglen
        .LONGA OFF
        sep #$20
    .if TEX_HALFW
        ; 2:1 HORIZONTAL DOWNSAMPLE (pack_textures.py HALF_W). The stored texture
        ; is half as wide, so one texel spans TWO world units along the wall. u is
        ; a world-unit track, so halving it here -- once per seg -- is the entire
        ; runtime cost of the change: wall_src/low_src and the per-column loop are
        ; untouched, and the AND wrap still works because w/2 stays a power of two.
        lsr rs_seglen+1
        ror rs_seglen
    .endif
        lda rs_seglen+1
        ora rs_seglen                ; L >= 1
        bne ?ok
        inc rs_seglen
?ok     rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; tw_texmask -- from rs_texh_cur derive rs_texmask = texH*256-1 and rs_texpow2 =
;   texH AND (texH-1). When that flag is 0 the texture height is a power of two
;   (25 of E1M1's 29 are) and "wt mod texH*256" collapses from a udiv24 to an AND.
;
; 2026-08-10: parked at TWMASK_BASE ($78EA) -- the largest truly free fast-
;   window hole the machine has left (22 B, ram_map + RESERVED). Down here in
;   win2 its ~2 fetches/column cost x11.2; the move shaves ~7 ms off a 360 ms
;   Rapidus frame for free (bench/bench_fps.txt). Called only by wall_src/
;   low_src below, via absolute jsr.
;--------------------------------------------------------------
twmask_resume = *
        org TWMASK_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tw_texmask
        lda #$FF
        sta rs_texmask
        lda rs_texh_cur
 .if 1
	dec
 .else
        sec
        sbc #1
 .endif
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wall_src
        lda rs_uacc+1                ; tex_x = world u along the seg (Q8 -> texels)
        and rs_wtexwm
    .if TEX_RUNS
 .if 1
	phx			;eliminate pc_sx variable (used only twice)
 .else
        stx pc_sx                    ; the index array is in SDRAM now (texcol.asm)
 .endif
        tax                          ;   and absolute long is X-indexed only
wix     lda.l $000000,x
 .if 1
	plx
	tay                          ; the stored column, PARKED IN Y (2026-09-15):
 .else                                ;   nothing but this proc read rs_txx, and
        ldx pc_sx                    ;   tya below zero-extends it for free
 .endif
    .else
        tay                          ; ...and then which STORED column that is:
wix     lda $FFFF,y                  ;   pack_textures.dedup_columns keeps one copy
    .endif
                                     ;   of each distinct column and this array says
                                     ;   which. The operand is patched per SEG in
                                     ;   seg_draw (?wix), never per column, so the
                                     ;   whole dedup costs 4 cycles here.
        lda rs_wtexh                 ; tw_texmask INLINED (2026-09-15): the mask
        sta rs_texh_cur              ;   (texH*256-1) and the pow2 flag, without
        dec                          ;   the jsr/rts and the rs_texh_cur reload.
        sta rs_texmask+1             ;   rs_texmask's low byte is rewritten
        and rs_wtexh                 ;   because the cell lives in the SIO staging
        sta rs_texpow2               ;   pages (see tw_texmask's header)
 .if 1                                ; ... but NOTHING reads that low byte: paint.asm
 .else                                ;   and textures.asm only `and rs_texmask+1`
        lda #$FF                     ;   (2026-09-15, -6/column)
        sta rs_texmask
 .endif
    .if TEX_RUNS
    .if TEX_RUNSH <> 6
        ert 'the closed form below is TEX_RUNSH=6 only -- see map_syms.inc'
    .endif
        ; 16-BIT A (2026-08-31, the drac030 hand-review): the split
        ; shift (hi = x>>2, lo = x<<6) and the halved add were 50 cycles;
        ; x<<6 in one 16-bit accumulator lands STRAIGHT in the tsrc add --
        ; no qs_p staging at all. 37 cycles, bit-identical, and the 16-bit
        ; adc's carry rides into the bank byte through the sep (M only).
        rep #$20
        .LONGA ON
        tya                          ; the column: Y is 8-bit, so B comes out 0
 .if 1
	xba
	lsr
	lsr
 .else
        asl @
        asl @
        asl @
        asl @
        asl @
        asl @                        ; tex_x * 64 = the stored column's offset
 .endif
;       clc
        adc rs_wtexad                ; rs_tsrc = wtexad + (txx<<6)
        sta rs_tsrc
        .LONGA OFF
        sep #$20
        lda rs_wtexad+2              ; ... + the SDRAM bank byte, with the
        adc #0                       ;     16-bit add's carry
        sta rs_tsrc+2
        ldy #0                       ; the old loop always exited with Y=0; keep that
 .if 1
        jmp draw_twall_clip          ; TAIL CALL (2026-09-15): both callers jsr'd
 .else                                ;   draw_twall_clip right after (-9/column)
        rts
 .endif
    .else
        qsmul rs_txx, rs_wtexh, qs_p       ; qs_p = tex_x * texH  (<=127*128, fits 16b)
 .if 1
	rep #$21
	.LONGA ON
        lda rs_wtexad
        adc qs_p
        sta rs_tsrc
	sep #$20
	.LONGA OFF
 .else
        clc                          ; rs_tsrc = wtexad + qs_p
        lda rs_wtexad
        adc qs_p
        sta rs_tsrc
        lda rs_wtexad+1
        adc qs_p+1
        sta rs_tsrc+1
 .endif
        lda rs_wtexad+2
        adc #0
        sta rs_tsrc+2
 .if 1
        jmp draw_twall_clip          ; (tail call, as the TEX_RUNS path above)
 .else
        rts
 .endif
    .endif
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc low_src
        lda rs_uacc+1                ; world u, same track as wall_src
        and rs_ltexwm
    .if TEX_RUNS
 .if 1
	phx			;eliminate pc_sx variable (used only twice)
 .else
        stx pc_sx
 .endif
        tax
lix     lda.l $000000,x              ; the LOWER step's own index array, in SDRAM
 .if 1
	plx
	tay                          ; (as wall_src: the column parks in Y)
 .else
        ldx pc_sx
 .endif
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
 .if 1                                ; (the low byte has no reader, as wall_src)
 .else
        lda #$FF
        sta rs_texmask
 .endif
    .if TEX_RUNS
    .if TEX_RUNSH <> 6
        ert 'the closed form below is TEX_RUNSH=6 only -- see map_syms.inc'
    .endif
        rep #$20                     ; same 16-bit fusion as wall_src above
        .LONGA ON
        tya
 .if 1
	xba
	lsr
	lsr
 .else
        asl @
        asl @
        asl @
        asl @
        asl @
        asl @
 .endif
;       clc
        adc rs_ltexad                ; rs_tsrc = ltexad + (txx<<6)
        sta rs_tsrc
        .LONGA OFF
        sep #$20
        lda rs_ltexad+2
        adc #0
        sta rs_tsrc+2
        ldy #0                       ; the old loop always exited with Y=0; keep that
 .if 1                                ; FALLS THROUGH into draw_twall_clip, the next
 .else                                ;   proc of this org block (2026-09-15, -12/col)
        rts
 .endif
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
 .if 1                                ; (falls through, as the TEX_RUNS path above)
 .else
        rts
 .endif
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
 .if 1
        bra ?aset                    ;   the jmp round it went away with it
 .else
        beq ?aset                    ;   the jmp round it went away with it
 .endif
?atop   lda rs_top
?aset   sta rs_spa
        lda rs_rb+1                  ; b = min(rs_rb, bot); <top -> nothing
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot
        bcc ?bset                    ; same as above -- A is still rs_rb, and
;       beq ?bset                    ;   ?bbot now FALLS THROUGH to ?bset
?bbot   lda rs_bot
?bset   sta rs_spb
        cmp rs_spa                   ; draw only if spb >= spa; A is the value
        bcc ?out                     ;   just stored, so no reload
    .if TEX_RUNS
        ; THE HEIGHT/TOP HANDOFF IS DEAD HERE (2026-08-30). paint_col reads the
        ; span back out of rs_spa/rs_spb itself and kills A (lda rs_texh_cur)
        ; and Y (jsr pt_mul) before either could be read -- it only ever took
        ; A/Y because it stepped into draw_twall_col's calling convention. The
        ; sec/sbc/clc/adc/tay/lda that built them cost 20 cycles a column.
        jmp paint_col                ; tail-call (preserves X) -- paint.asm
    .else
;       sec                          ; draw_twall_col DOES take A=top, Y=height
        sbc rs_spa
 .if 1
	inc
 .else
        clc
        adc #1
 .endif
        tay                          ; height = spb-spa+1
        lda rs_spa                   ; top row
        jmp draw_twall_col           ; tail-call (preserves X)
    .endif
?out    rts
.endp
        .endseg
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

