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
.proc seg_len
        sec                          ; m_a = |dx|
        lda zp_rx2
        sbc zp_rx1
        sta m_a
        lda zp_rx2+1
        sbc zp_rx1+1
        sta m_a+1
        bpl ?dxp
        jsr m_neg
?dxp    sec                          ; m_b = |dy|
        lda zp_ry2
        sbc zp_ry1
        sta m_b
        lda zp_ry2+1
        sbc zp_ry1+1
        sta m_b+1
        bpl ?dyp
        jsr m_negb
?dyp    lda m_a+1                    ; order so m_a = max, m_b = min
        cmp m_b+1
        bcc ?swap
        bne ?omax
        lda m_a
        cmp m_b
        bcs ?omax
?swap   lda m_a
        ldy m_b
        sty m_a
        sta m_b
        lda m_a+1
        ldy m_b+1
        sty m_a+1
        sta m_b+1
?omax   lsr m_b+1                    ; min/2
        ror m_b
        lda m_a                      ; max/8 -> m_res
        sta m_res
        lda m_a+1
        sta m_res+1
        lsr m_res+1
        ror m_res
        lsr m_res+1
        ror m_res
        lsr m_res+1
        ror m_res
        clc                          ; L = max + min/2 - max/8
        lda m_a
        adc m_b
        sta rs_seglen
        lda m_a+1
        adc m_b+1
        sta rs_seglen+1
        sec
        lda rs_seglen
        sbc m_res
        sta rs_seglen
        lda rs_seglen+1
        sbc m_res+1
        sta rs_seglen+1
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
.endp

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
.proc tw_texmask
        lda #$FF
        sta rs_texmask
        lda rs_texh_cur
        sec
        sbc #1
        sta rs_texmask+1
        and rs_texh_cur
        sta rs_texpow2
        rts
.endp
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
.proc wall_src
        lda rs_uacc+1                ; tex_x = world u along the seg (Q8 -> texels)
        and rs_wtexwm
    .if TEX_RUNS
        stx pc_sx                    ; the index array is in SDRAM now (texcol.asm)
        tax                          ;   and absolute long is X-indexed only
wix     lda.l $000000,x
        ldx pc_sx                    ;   ... X is the caller's column counter
    .else
        tay                          ; ...and then which STORED column that is:
wix     lda $FFFF,y                  ;   pack_textures.dedup_columns keeps one copy
    .endif
        sta rs_txx                   ;   of each distinct column and this array says
                                     ;   which. The operand is patched per SEG in
                                     ;   seg_draw (?wix), never per column, so the
                                     ;   whole dedup costs 4 cycles here.
        lda rs_wtexh
        sta rs_texh_cur
        jsr tw_texmask               ; tile mask + pow2 flag for this texture
    .if TEX_RUNS
        lda #0                       ; a stored column is TEX_RUNK runs of
        sta qs_p+1                   ;   (rows, colour) -- a FIXED record again,
        lda rs_txx                   ;   so the address is still base + index *
        ldy #TEX_RUNSH               ;   stride, only the stride is a power of
?rsh    asl @                        ;   two now: five shifts, no multiply
        rol qs_p+1
        dey
        bne ?rsh
        sta qs_p
    .else
        qsmul rs_txx, rs_wtexh       ; qs_p = tex_x * texH  (<=127*128, fits 16b)
    .endif
        clc                          ; rs_tsrc = wtexad + qs_p
        lda rs_wtexad
        adc qs_p
        sta rs_tsrc
        lda rs_wtexad+1
        adc qs_p+1
        sta rs_tsrc+1
        lda rs_wtexad+2
        adc #0
        sta rs_tsrc+2
        rts
.endp

.proc low_src
        lda rs_uacc+1                ; world u, same track as wall_src
        and rs_ltexwm
    .if TEX_RUNS
        stx pc_sx
        tax
lix     lda.l $000000,x              ; the LOWER step's own index array, in SDRAM
        ldx pc_sx
    .else
        tay
lix     lda $FFFF,y                  ; the LOWER step's own column index array
    .endif
        sta rs_txx
        lda rs_ltexh
        sta rs_texh_cur
        jsr tw_texmask               ; tile mask + pow2 flag for this texture
    .if TEX_RUNS
        lda #0                       ; run records: base + index*2*TEX_RUNK
        sta qs_p+1
        lda rs_txx
        ldy #TEX_RUNSH
?lsh    asl @
        rol qs_p+1
        dey
        bne ?lsh
        sta qs_p
    .else
        qsmul rs_txx, rs_ltexh
    .endif
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
        rts
.endp

;--------------------------------------------------------------
; draw_twall_clip -- like draw_clip but textured: clip raw signed16 rows
;   rs_ra/rs_rb to [rs_top,rs_bot] -> rs_spa/rs_spb, then draw the textured
;   column (rs_tsrc/rs_texh_cur must already be set for this column). Preserves X.
;--------------------------------------------------------------
.proc draw_twall_clip
        lda rs_ra+1                  ; a = max(rs_ra, top); >bot -> nothing
        bmi ?atop
        bne ?out
        lda rs_ra
        cmp rs_top
        bcc ?atop
        cmp rs_bot
        beq ?ara
        bcs ?out
?ara    lda rs_ra
        jmp ?aset
?atop   lda rs_top
?aset   sta rs_spa
        lda rs_rb+1                  ; b = min(rs_rb, bot); <top -> nothing
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot
        bcc ?brb
        beq ?brb
?bbot   lda rs_bot
        jmp ?bset
?brb    lda rs_rb
?bset   sta rs_spb
        lda rs_spb                   ; draw only if spb >= spa
        cmp rs_spa
        bcc ?out
        sec
        sbc rs_spa
        clc
        adc #1
        tay                          ; height = spb-spa+1
        lda rs_spa                   ; top row
    .if TEX_RUNS
        jmp paint_col                ; tail-call (preserves X) -- paint.asm
    .else
        jmp draw_twall_col           ; tail-call (preserves X)
    .endif
?out    rts
.endp
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

