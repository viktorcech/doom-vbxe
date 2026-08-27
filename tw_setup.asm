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

tw_seg_resume = *
        org TWSETUP_BASE
.proc tw_setup
        stx zp_savex                 ; udiv* clobber X
        sec                          ; dscr Q4 = (yfacc - ycacc) >> 4. Taking it
        lda rs_yfacc                 ; from the 24-bit Q8 accumulators instead of
        sbc rs_ycacc                 ; the truncated row numbers keeps 1/16 of a
        sta m_prod                   ; row of precision -- a +-1 row error here is
        lda rs_yfacc+1               ; a whole rung of the rate ladder on a short
        sbc rs_ycacc+1               ; wall, i.e. per-column shimmer.
        sta m_prod+1
        lda rs_yfacc+2
        sbc rs_ycacc+2
        sta m_prod+2
        bmi ?dmin                    ; ceiling below floor -> clamp
        lda #0
        sta tw_dsh
        ldy #4
?dsh    lsr m_prod+2
        ror m_prod+1
        ror m_prod
        dey
        bne ?dsh
        ; A wall taller than 4095 rows (standing right against a tall one) does
        ; NOT clamp: clamping dscr while leaving worldH alone froze tpr and the
        ; texture stopped scaling -- ~350 rows of slide. Shift dscr down instead
        ; and take the same shifts off the dividend, which preserves the ratio.
?dfit   lda m_prod+2
        beq ?dok2
        lsr m_prod+2
        ror m_prod+1
        ror m_prod
        inc tw_dsh
        jmp ?dfit
?dok2   lda m_prod
        sta rs_dscr
        lda m_prod+1
        sta rs_dscr+1
        ora rs_dscr
        bne ?dok
?dmin   lda #1                       ; dscr >= 1/16 row
        sta rs_dscr
        lda #0
        sta rs_dscr+1
; --- the dscr MEMO lived here until 2026-08-14. It compared rs_dscr against
;     tw_lastdscr and jumped straight to ?cached on a match. MEASURED (with
;     tools/tests/_bench_cache.py, real ATR, real E1M1, 19 frames): 0 hits in
;     3000 calls -- it could not hit, ever. tw_setup has exactly THREE call
;     sites, all of them in colmerge.asm's anchors, and the F1 fix (2026-08-11)
;     made all three zero tw_lastdscr in the instruction before the jsr. The
;     "the memo still pays off between anchors" note that justified keeping it
;     was wrong: the anchors ARE every call. So this was a compare chain and
;     two stores per column, plus the invalidation stores at each call site,
;     paying for nothing. The call sites lost their zeroing with it.
?dok    lda rs_worldh+1              ; worldH <= 0 (degenerate / closed door) ->
        bpl ?wpos                    ; fall back to 1 texel per row
        jmp ?flat
?wpos   ora rs_worldh
        bne ?wnz
        jmp ?flat
?wnz    lda rs_worldh+1              ; worldH >= 4096 would overflow worldH<<12
        cmp #16
        bcc ?wfit
        jmp ?tprmax
?wfit   lda rs_worldh                ; overflow guard: worldH*4096/dscr >= 65536
        sta m_a                      ; <=> (worldH >> 4) >= dscr_q4
        lda rs_worldh+1
        sta m_a+1
        ldy #4
?whs    lsr m_a+1
        ror m_a
        dey
        bne ?whs
        lda m_a+1                    ; compare worldH>>4 with dscr
        cmp rs_dscr+1
        bcc ?nov
        beq ?eqhi
        jmp ?tprmax
?eqhi
        lda m_a
        cmp rs_dscr
        bcc ?nov
        lda tw_dsh                   ; dscr was shifted down -> it is >= 65536 and
        bne ?nov                     ; worldH would have to be ~1M to overflow
        jmp ?tprmax
?nov    lda #0                       ; m_prod = worldH << (12 - tw_dsh)
        sta m_prod
        lda rs_worldh
        sta m_prod+1
        lda rs_worldh+1
        sta m_prod+2
        sec
        lda #4
        sbc tw_dsh                   ; (the <<8 is already in the byte placement)
        beq ?wdone
        tay
?wsh    asl m_prod
        rol m_prod+1
        rol m_prod+2
        dey
        bne ?wsh
?wdone
        lda rs_dscr                  ; round: dividend += dscr/2. udiv24 truncates,
        lsr                          ; and ?wtcalc amplifies that by the lever arm
        sta m_a                      ; (row - pegrow), so half an LSB matters.
        lda rs_dscr+1
        lsr
        sta m_a+1
        lda rs_dscr
        and #1
        beq ?nocarry
        lda m_a
        ora #$80
        sta m_a
?nocarry clc
        lda m_prod
        adc m_a
        sta m_prod
        lda m_prod+1
        adc m_a+1
        sta m_prod+1
        lda m_prod+2
        adc #0
        sta m_prod+2
        lda rs_dscr
        sta m_den
        lda rs_dscr+1
        sta m_den+1
        jsr udiv24                   ; tpr_q8 = (4096*worldH + dscr/2) / dscr_q4
        lda m_quot
        sta rs_tpr
        lda m_quot+1
        sta rs_tpr+1
        ora rs_tpr
        bne ?have
?flat   lda #0                       ; tpr = 1.0 texel/row
        sta rs_tpr
        lda #1
        sta rs_tpr+1
        bne ?have
?tprmax lda #$FF                     ; saturate (a wall thinner than one row)
        sta rs_tpr
        sta rs_tpr+1
?have
    .if !TEX_RUNS
        lda #1
        sta tw_rpt
        ; Oversampling factor S. The rate ladder step is 1/(S*rpt) and we want it
        ; near 1/8 of tpr, so S ~ 8/tpr. The expander costs 2 VBXE cycles per
        ; sample it writes (vbxe.cpp:3861), so paying for S=8 on a minified column
        ; buys nothing -- the same relative accuracy needs far fewer samples there.
        ; Powers of two only, so the sample index stays a shift of tw_wt.
        ldx #3                       ; tpr < 2  -> S = 8
        lda #8
    .if TW_SAFE
        jmp ?sset                    ; TW_SAFE: S = 8 everywhere, always expand
    .endif
        ldy rs_tpr+1
        cpy #2
        bcc ?sset
        ldx #2                       ; tpr < 4  -> S = 4
        lda #4
        cpy #4
        bcc ?sset
        ldx #1                       ; tpr < 8  -> S = 2
        lda #2
        cpy #8
        bcc ?sset
        ldx #0                       ; tpr >= 8 -> no expansion at all
        lda #1
?sset   sta tw_s
        stx tw_ssh
        sec                          ; tw_rsh = 8 - ssh; sample index = tw_wt >> rsh
        lda #8
        sbc tw_ssh
        sta tw_rsh
        cpx #0
        bne ?use8
        jmp ?raw
?use8   lda #1
        sta tw_use8
        lda rs_tpr+1                 ; tpr >= 1 texel/row -> no vertical zoom
        bne ?spy8
        ; ZOOMY: hold each source sample for rpt = floor(1/tpr) rows. rpt is
        ; capped by the natural texel height, so the hold is always FINER than one
        ; texel -- no skipping -- while the rate ladder becomes 1/(8*rpt).
        lda rs_tpr                   ; rpt = floor(256/tpr) clamped 1..8, as a
        cmp #129                     ; threshold ladder -- a udiv16 here cost more
        bcs ?rpt1                    ; than the rest of tw_setup put together
        cmp #86
        bcs ?rpt2
        cmp #65
        bcs ?rpt3
        cmp #52
        bcs ?rpt4
        cmp #43
        bcs ?rpt5
        cmp #37
        bcs ?rpt6
        cmp #33
        bcs ?rpt7
        lda #8
        bne ?rptset
?rpt7   lda #7
        bne ?rptset
?rpt6   lda #6
        bne ?rptset
?rpt5   lda #5
        bne ?rptset
?rpt4   lda #4
        bne ?rptset
?rpt3   lda #3
        bne ?rptset
?rpt2   lda #2
        bne ?rptset
?rpt1   lda #1
?rptset sta tw_rpt
?spy8   qsmul tw_s, tw_rpt           ; k = S*rpt (<= 64), both bytes
        lda qs_p
        sta m_a
        qsmul m_a, rs_tpr            ; spy = round(k*tpr/256) = (k*tpr + 128) >> 8
        lda qs_p
        sta m_prod
        lda qs_p+1
        sta m_prod+1
        lda #0
        sta m_prod+2
        qsmul m_a, rs_tpr+1
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
        clc
        lda m_prod
        adc #128
        lda m_prod+1
        adc #0
        sta tw_spy
        lda m_prod+2
        adc #0
        sta tw_spy+1
        lda tw_spy
        ora tw_spy+1
        bne ?s8ok
        lda #1                       ; below one sample per row -> clamp
        sta tw_spy
?s8ok   jmp ?done
        ; ---- raw texture column: SRC_STEPY = round(tpr) = (tpr_q8+128)>>8 ------
?raw    lda #0
        sta tw_use8
        lda rs_tpr
        clc
        adc #128
        lda rs_tpr+1
        adc #0
        bcs ?spymax                  ; >= 256 texels/row -> saturate
        sta tw_spy
        bne ?spyok
?spymax lda #255
        sta tw_spy
?spyok  lda #0
        sta tw_spy+1
?done
    .endif                           ; !TEX_RUNS -- the whole rate LADDER (S,
                                     ; SRC_STEPY, ZOOMY) only ever configured the
                                     ; blitter. A painted column needs rs_tpr and
                                     ; nothing else, so with TEX_RUNS tw_setup
                                     ; ends at the divide and every textured
                                     ; column saves the ladder as well.
?cached ldx zp_savex
        rts
.endp
    .if * > TWSETUP_END+1
        ert 'tw_setup outgrew TWSETUP_BASE..END ($1500 fast page, memory_map.inc)'
    .endif
        org tw_seg_resume            ; back to the textured-blit segment
