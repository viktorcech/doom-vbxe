;==============================================================
; paint.asm -- WALLS THE ENGINE PAINTS, instead of walls it blits (TEX_RUNS).
;
; WHY (2026-08-06). Two things the blit path cannot do, and one it costs:
;   * VRAM. A blitted texture has to BE in VRAM: the old tex_fget copied each
;     texture out of SDRAM into a 192 KB arena, the single biggest tenant of a
;     512 KB machine. A painted wall reads its runs with the CPU, straight out
;     of SDRAM -- the arena, TEXAR, the expander scratch and the per-seg fetch
;     all drop out of the wall path. (That whole B2 texture arena was DELETED
;     on 2026-08-14: with TEX_RUNS=1 it had had no reachable caller since the
;     run format landed. $040000-$06FFFF of VRAM and the $7E40 fast-RAM block
;     came back with it -- memory_map.inc.)
;   * LIGHT. The blitter's whole per-pixel path is (src AND m) XOR x with no
;     lookup in it (lights.asm), so a blitted wall ignores the sector light.
;     A painted run is ONE palette index, so it goes through the colormap
;     exactly like a floor does -- textured walls blink with the lamps now.
;   * THE BLITTER. Measured A/B, same E1M1 frame, both builds, through
;     tools/_bench_spans.py: the blit path asked the VBXE for 463,380 cycles of
;     work in a frame the blitter has 228,384 for -- 203 %, i.e. it could not
;     keep up, and 415,910 of that was the 8x expander alone. Painting it is
;     fills only: 94,556 cycles, 41 %. The CPU pays for that: 3.82 M -> 4.23 M
;     6502 cycles per frame (+11 %), 4380 per painted column against 3948 per blitted
;     span. So this is not a CPU win -- it is a VRAM win, a light win, and it
;     takes the frame's actual bottleneck out.
;
; WHAT A COLUMN LOOKS LIKE (tools/texruns.py, pack_textures.RUN_TEXTURES):
;   TEX_RUNK runs of (rows, colour), 2*TEX_RUNK bytes, ONE fixed-size record
;   per stored column -- so the column address is still base + index*stride and
;   dedup_columns, the wmask tiling and the textab all mean what they meant.
;   `rows` are TEXELS and they sum to the texture height; `colour` is a PLAYPAL
;   index. The split is the exact k-segment dynamic program (v-optimal
;   histogram), not a greedy run-length pass: 79 % of COMPTILE's pixels come
;   back exactly right at K=16.
;
; THE MAPPING. The blit path tracks texels per screen row (rs_tpr) because it
; walks rows. The painter walks RUNS, so it needs the inverse -- screen rows
; per texel:
;       rpt_q8 = D / worldH,   D = rs_yfacc - rs_ycacc   (Q8 screen rows)
; and D advances by (rs_yfS - rs_ycS) per column, so rpt is EXACTLY linear in
; the column and one 24-bit add per column keeps it (pt_step). That is why
; there is no anchor/interpolate machinery here like tw_setup_sub's: tpr is a
; reciprocal and curves, rpt does not.
;==============================================================
PT_MAXRUN   equ 4*TEX_RUNK           ; REAL runs painted per column before the
                                     ;   tail is filled flat (zero-length pads
                                     ;   are free since 2026-08-10 -- see ?next).
                                     ; 2026-08-27: was TEX_RUNK+TEX_RUNK/2 (48),
                                     ;   and the old note here -- "the flat fill
                                     ;   is what minification would have
                                     ;   produced" -- was wrong twice over. The
                                     ;   fill is not an average, it is whatever
                                     ;   zp_color the LAST run happened to leave,
                                     ;   so a far wall got a slab of one
                                     ;   arbitrary shade; and 48 was reached by
                                     ;   ordinary geometry, not a pathological
                                     ;   case. E1M1 at (1858,-2558) facing east
                                     ;   (zp_ang $00) filled 10 columns flat over
                                     ;   ld406's COMPTILE at 446 units -- the
                                     ;   reported "fictional walls that blink"
                                     ;   (1.jpg), and it moved with the player
                                     ;   because the budget sat right on the
                                     ;   edge (~45 runs/column measured).
                                     ; THE CAP COSTS ALMOST NOTHING TO RAISE:
                                     ;   over four angles at that spot, 48 -> 64
                                     ;   changed the frame's run-walks by +15 in
                                     ;   ONE angle (7151 -> 7166) and by ZERO in
                                     ;   the other three, and 64 -> 255 changed
                                     ;   nothing at all -- only a handful of
                                     ;   columns ever reach the cap. 4*TEX_RUNK
                                     ;   keeps a margin for the other spots the
                                     ;   flat slab was reported at.
                                     ;   Scales with TEX_RUNK (24 at K=16, 48 at
                                     ;   K=32) so the knob in pack_textures.py
                                     ;   moves both halves together.

paint_resume = *
        org TWRUNS_BASE              ; the $0900 fast page tw_runs vacates. It is
                                     ; the same Rapidus window the blit path's
                                     ; hot loop was moved into on 2026-07-28, and
                                     ; for the same reason: this is per-column
                                     ; code, so its INSTRUCTION FETCHES are the
                                     ; cost. 1105 B here against TEXBLIT's 560.

;--------------------------------------------------------------
; pt_seg -- once per seg (beside tw_seg_init): rs_rpt for the seg's FIRST
;   column and rs_drpt, the per-column step. Both divisions live here so the
;   column loop pays only an add. Clobbers A/X/Y and the m_* scratch.
;   Per SEG, not per column, so it lives in the second block (PAINT2_BASE) and
;   leaves the $0900 page to the per-column code.
;--------------------------------------------------------------
pts_resume = *
        org PTSEG_BASE               ; the fast block tw_setup vacated -- pt_seg grew
                                     ;   past PAINT2 when it started rounding
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_seg
 .if 1
        stz rs_rptf
        stz rs_drpt
        stz rs_drpt+1
        stz rs_drpt+2
 .else
        lda #0
        sta rs_rptf
        sta rs_drpt
        sta rs_drpt+1
        sta rs_drpt+2
 .endif
        lda rs_worldh+1              ; worldH <= 0 (degenerate / closed door) ->
        bmi ?fj                      ;   one texel per row, like tw_setup's ?flat
        ora rs_worldh
        bne ?wok
?fj     jmp ?flat
?wok
 .if 1
	rep #$20
	.LONGA ON
	lda rs_worldh
        sta m_den
        sec                          ; D = yfacc - ycacc, the wall's screen height
        lda rs_yfacc                 ;     in Q8 rows
        sbc rs_ycacc
        sta m_prod
	sep #$20
	.LONGA OFF
        lda rs_yfacc+2
        sbc rs_ycacc+2
        sta m_prod+2
 .else
	lda rs_worldh
        sta m_den
        lda rs_worldh+1
        sta m_den+1
        sec                          ; D = yfacc - ycacc, the wall's screen height
        lda rs_yfacc                 ;     in Q8 rows
        sbc rs_ycacc
        sta m_prod
        lda rs_yfacc+1
        sbc rs_ycacc+1
        sta m_prod+1
        lda rs_yfacc+2
        sbc rs_ycacc+2
        sta m_prod+2
 .endif
 .if 1
	jmi ?flat
 .else
        bpl ?dpos0
        jmp ?flat                    ; ceiling below floor
?dpos0
 .endif
        ; ROUND (2026-08-27): dividend += worldH/2 before the divide. udiv24
        ; truncates, and now that paint_col takes the RECIPROCAL of rpt for
        ; rs_tpr (pt_recip), half an LSB low here is amplified into whole texels
        ; on a minified wall: over an E1M1 spawn frame this one add took the max
        ; |tpr error| from 32 to 18 and the mean from 2.54 to 1.41.
        ; The overflow guard moved BELOW it, so it sees the dividend actually
        ; divided -- rounding can push a quotient that was exactly 65535 over.
 .if 1
	rep #$20
	.LONGA ON
        lda rs_worldh
        lsr
        clc
        adc m_prod
        sta m_prod
	sep #$20
	.LONGA OFF
 .else
        lda rs_worldh+1
        lsr
        sta m_a+1
        lda rs_worldh
        ror
        sta m_a
        clc
        lda m_prod
        adc m_a
        sta m_prod
        lda m_prod+1
        adc m_a+1
        sta m_prod+1
 .endif
        bcc ?nc3                     ; the carry into byte 2 -- an inc only when
        inc m_prod+2                 ;   it is there; a wrap OUT of it saturates
        beq ?sat                     ;   (2026-09-15: was lda/adc #0/sta/bcs)
?nc3
        lda rs_worldh+1              ; D/worldH >= 65536 would wrap the quotient:
        bne ?nov                     ;   worldH >= 256 cannot (D is 24-bit)
        lda m_prod+2
        cmp rs_worldh
        bcc ?nov

?sat    lda #$FF                     ; saturate -- a sliver of wall stretched over
        sta rs_rpt                   ;   the whole screen
        sta rs_rpt+1
        rts

?nov    jsr udiv24                   ; rpt_q8 = (D + worldH/2) / worldH

 .if 1
	stz m_prod
	rep #$20
	.LONGA ON
        lda m_quot
        sta rs_rpt
        sec
        lda rs_yfS
        sbc rs_ycS
;       sta m_prod+1                 ; the << 8 is the byte placement
	bpl ?dpos

;	lda m_prod+1
	eor #$ffff
	inc
	sta m_prod+1
	sep #$20
	.LONGA OFF
 .else
        lda m_quot
        sta rs_rpt
        lda m_quot+1
        sta rs_rpt+1
        ; ---- step: drpt_q16 = ((yfS - ycS) << 8) / worldH, signed ----
        sec
        lda rs_yfS
        sbc rs_ycS
        sta m_prod+1                 ; the << 8 is the byte placement
        lda rs_yfS+1
        sbc rs_ycS+1
        sta m_prod+2

        lda #0
        sta m_prod

        lda m_prod+2
        bpl ?dpos

        sec                          ; |dS| << 8
        lda #0
        sbc m_prod+1
        sta m_prod+1
        lda #0
        sbc m_prod+2
        sta m_prod+2
 .endif
        jsr udiv24

        sec                          ; ... and negate the quotient back
        lda #0
        sbc m_quot
        sta rs_drpt
        lda #0
        sbc m_quot+1
        sta rs_drpt+1
        lda #0
        sbc #0
        sta rs_drpt+2

        rts

?dpos
 .if 1
	.LONGA ON
	sta m_prod+1
	sep #$20
	.LONGA OFF
 .else
	;nothing
 .endif
	jsr udiv24

        lda m_quot
        sta rs_drpt
        lda m_quot+1
        sta rs_drpt+1
 .if 1
        stz rs_drpt+2
 .else
        lda #0
        sta rs_drpt+2
 .endif
        rts

?flat
 .if 1
        stz rs_rpt
 .else
	lda #0                       ; 1.0 screen row per texel
        sta rs_rpt
 .endif
        lda #1
        sta rs_rpt+1
        rts
.endp
        .endseg


;--------------------------------------------------------------
; pt_step -- one column on: rpt += drpt (Q16). Called from the column loop's
;   ?cnext beside the plane accumulators, i.e. for EVERY column, drawn or
;   skipped -- an accumulator that only advanced on drawn columns would drift
;   away from the geometry over a seg. Clobbers A only.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_step
 .if 1                                ; DRAC_PLAN 5: 32-bit cells, word arithmetic:
        rep #$21                     ;   [rptf, rpt, rpt+1, pad] += rs_drpt, a
        .LONGA ON                    ;   word at a time (memory_map.inc D0)
        lda rs_rptf
        adc rs_drpt
        sta rs_rptf
        lda rs_rptf+2
        adc rs_drpt+2
        sta rs_rptf+2
        sep #$20
        .LONGA OFF
        rts
 .else
        clc
        lda rs_rptf
        adc rs_drpt
        sta rs_rptf
        lda rs_rpt
        adc rs_drpt+1
        sta rs_rpt
        lda rs_rpt+1
        adc rs_drpt+2
        sta rs_rpt+1
        rts
 .endif
.endp
        .endseg
    .if * > PTSEG_END+1
        ert 'pt_seg/pt_step outgrew PTSEG_BASE..PTSEG_END (memory_map.inc)'
    .endif
        org pts_resume

pt2_resume = *
        org PAINT2_BASE              ; the slot pt_seg left
;--------------------------------------------------------------
; pt_recip -- rs_tpr = 65536 / rs_rpt, by table, no divide.
;
; WHY THIS EXISTS (2026-08-27). rs_tpr is texels per screen row; rs_rpt is screen
; rows per texel. They are exact reciprocals in Q8:
;       tpr_q8 * rpt_q8 == 65536
; identically -- both are worldH and D = yfacc-ycacc, one each way up. tw_setup
; derived tpr straight from worldH/dscr with a udiv24, and BECAUSE a reciprocal
; curves, colmerge.asm carried a whole anchor/interpolate machine (tws_anchor +
; tw_setup_sub) to avoid paying that divide per column: two udiv24s per 8-column
; block plus the look-ahead's accumulator save/advance/restore. Measured, that
; machine plus its divides was 15.9 % of a wall frame and 7 % of the spawn.
;
; But pt_seg already tracks rpt, which is EXACTLY LINEAR in the column (two
; divides per SEG, one add per column -- pt_step), so tpr is just one reciprocal
; of a number the painter already has. And paint_col ALREADY memoises on rs_rpt
; for pt_mul, so this runs only where rs_rpt changed: 45 % of painted columns at
; a wall, 29 % at the spawn (tools/tests/_probe_tpr3.py).
;
; ACCURACY against the exact 65536*worldH/D over real frames, mean / max |error|
; in tpr LSBs (same probe):
;       spawn   tw_setup + interpolation  1.79 / 327     this  1.41 / 18
;       wall    tw_setup + interpolation  0.20 /   1     this  0.25 /  1
; It is not an approximation of the old path, it is BETTER than it: the old max
; error was a whole block's worth of interpolation drift.
;
; MATH: rpt ~ m << e with m in [256,512) (recip_norm), INV_TAB[m] = 2^23/m, so
;       65536/rpt = INV_TAB[m] >> (23 + e - 16) = INV_TAB[m] >> (RECIP_INV_K-16+e)
; A negative shift means tpr >= 65536 -- saturate, exactly as tw_setup's ?tprmax
; did, and rpt = 0 (a wall too far to cover one texel per row) saturates too.
; Clobbers A/X/Y and the m_* scratch -- paint_col calls it before it needs any
; of them. Per CHANGED column, so it sits beside pt_seg, not in the $0900 page.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_recip
        rep #$20                     ; rc_m = rpt as ONE word, Z = (rpt == 0):
        .LONGA ON                    ;   two byte copies and an `ora` before
        lda rs_rpt                   ;   (drac030, 2026-09-14)
        sta rc_m
        .LONGA OFF
        sep #$20                     ; (sep leaves Z alone)
        beq ?sat                     ; rpt = 0 -> tpr is off the top
        jsr recip_norm               ; X = mantissa index, rc_e = exponent

        lda.l RCX_INV_LO,x           ; INV_TAB[m] = round(2^23/m), bank $01
        sta m_prod
        lda.l RCX_INV_HI,x
        sta m_prod+1
        clc
        lda #RECIP_INV_K-16
        adc rc_e                     ; rc_e is signed
        bmi ?sat                     ; shift < 0 -> tpr >= 65536
        tax
        beq ?done
        cpx #8                       ; >= 8 -> drop the whole low byte first and
        bcc ?bits                    ;   leave at most 7 single shifts (shifting
        lda m_prod+1                 ;   14 times by ones would cost more than
        sta m_prod                   ;   the divide this replaces)
 .if 1
        stz m_prod+1
 .else
        lda #0
        sta m_prod+1
 .endif
        txa
        sec
        sbc #8
        beq ?done
        tax
?bits   rep #$20                     ; the 1..7 shifts on the WORD in A: 7 cycles
        .LONGA ON                    ;   a step where the lsr/ror pair on memory
        lda m_prod                   ;   was 15 (drac030, 2026-09-14: 346 steps
?b      lsr @                        ;   a frame)
        dex
        bne ?b
        sta rs_tpr                   ; ... and the result lands in rs_tpr directly
        .LONGA OFF
        sep #$20
        rts
 .if 1
?done   lda m_prod                   ; a lone dp -> abs word copy: two byte
        sta rs_tpr                   ;   copies (14) beat the rep/sep window (15),
        lda m_prod+1                 ;   ~485 times a frame
        sta rs_tpr+1
 .else
?done   rep #$20
        .LONGA ON
        lda m_prod
        sta rs_tpr
        .LONGA OFF
        sep #$20
 .endif
        rts
?sat    lda #$FF                     ; the saturation tw_setup's ?tprmax used
        sta rs_tpr
        sta rs_tpr+1
        rts
.endp
        .endseg
    .if * > PAINT2_END+1
        ert 'pt_recip outgrew PAINT2_BASE..PAINT2_END (memory_map.inc)'
    .endif
        org pt2_resume

;--------------------------------------------------------------
; pt_dy -- pc_dy (Q8 screen rows) = (pc_w + pc_f/256 texels) * rs_rpt.
;
;   The multiply is b. Fox/Tqa's fmulu_8x8 (_pomocne/mads-src/math), not the
;   qsmul macro: rs_rpt is the SAME for every run of a column, so its half of
;   the quarter-square lookup is baked into the instruction ADDRESSES once per
;   column (pt_mul, called from paint_col) and each run pays only
;       sec / lda SQ1L+b,y / sbc SQ2L+255-b,y / lda SQ1H+b,y / sbc SQ2H+..,y
;   -- no carry branch, no absolute value, ~20 cycles instead of ~40. The
;   mirrored table is what removes the sign work: SQ2[m] = f(m-255), so
;   SQ2[255-b+y] is f(y-b) whichever way round they are (tools/gen_qs.py).
;   Only the LOW byte of each base is patched: SQ1L/SQ2L are page aligned and
;   b <= 255, so the high byte cannot move.
;   Clobbers A/Y and qs_p.
;--------------------------------------------------------------
    .if [<SQ1L]|[<SQ1H]|[<SQ2L]|[<SQ2H]
        ert 'SQ1L/SQ1H/SQ2L/SQ2H must all be page aligned -- pt_mul patches only the LOW byte of each base'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_dy
        ; THE rpt_hi != 0 PATH ONLY (2026-09-14). paint_col's inline ?dyen
        ; computes w*rpt_lo in the accumulator and, for rpt_hi = 0 (every wall
        ; under one row per texel -- all 5,700 runs of the E1M1 bench frame),
        ; accumulates it without ever storing pc_dy. When rpt_hi != 0 (a
        ; magnified, close wall) pt_mul points paint_col.pc_wsel at pc_wide,
        ; which stores that product into pc_dy(0..1) and jumps here with Y = w.
        ; This adds (w*rpt_hi) << 8 and, on the anchor run, f*rpt_hi, exactly as
        ; before, then joins the loop's memory accumulate (pc_paint_mem), which
        ; also honours pc_dy+2. The m1a..m1d operands pt_mul used to bake here
        ; are paint_col.m1a..m1d now.
        stz pc_dy+2
        sec
m2a     lda SQ1L,y                   ; + (w * rpt_hi) << 8
m2b     sbc SQ2L+$FF,y
        sta qs_p
m2c     lda SQ1H,y
m2d     sbc SQ2H+$FF,y
        sta qs_p+1
        clc
        lda pc_dy+1
        adc qs_p
        sta pc_dy+1
        lda pc_dy+2
        adc qs_p+1
        sta pc_dy+2
        ldy pc_f                     ; the run the anchor lands INSIDE starts on
        beq ?done                    ;   a fraction of a texel; every later run
        sec                          ;   has pc_f = 0 and skips this
m3a     lda SQ1L,y                   ; + f * rpt_hi  (the f*rpt_lo term is worth
m3b     sbc SQ2L+$FF,y               ;   under 1/256 of a row and is dropped)
        sta qs_p
m3c     lda SQ1H,y
m3d     sbc SQ2H+$FF,y
        sta qs_p+1
        rep #$21                     ; pc_dy += the product, the low word in one
        .LONGA ON                    ;   add; its carry into byte 2 (drac030,
        lda pc_dy                    ;   2026-09-14)
        adc qs_p
        sta pc_dy
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        bcc ?done
        inc pc_dy+2
?done   stz pc_f                     ; the anchor run's part-texel is consumed
        jmp paint_col.pc_paint_mem
.endp
        .endseg

;--------------------------------------------------------------
; pt_mul -- bake rs_rpt into pt_dy's twelve table addresses. Once per COLUMN --
;   and since 2026-08-11 pm only per column WHERE rs_rpt CHANGED: paint_col
;   memoizes the last baked value in ptm_last and skips the call while it holds
;   (flat walls step rpt by under one LSB per column, so runs of columns share
;   one bake). Carved out of the $0900 page to PTMUL_BASE ($0E16, still fast)
;   -- its 52 bytes are the memo's + the inline emit's room.
;   base1 = SQ1x + b, base2 = SQ2x + (255-b) -- and since all four tables are
;   page aligned, "+ b" is just the low byte. Clobbers A.
;--------------------------------------------------------------
ptm_resume = *
        org PTMUL_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_mul
        stz pc_dy+2                  ; pt_dy's third byte: only the rpt_hi path
                                     ;   ever sets it, and rpt is per column
        lda rs_rpt                   ; rpt_lo -> the first product, which is
        sta.l B1CODE_BASE+paint_col.m1a+1    ;   inline in paint_col since 2026-09-14
        sta.l B1CODE_BASE+paint_col.m1c+1
        eor #$FF                     ; 255 - b, for the mirrored table
        sta.l B1CODE_BASE+paint_col.m1b+1
        sta.l B1CODE_BASE+paint_col.m1d+1
        lda rs_rpt+1                 ; rpt_hi -> the other two (pt_dy)
        sta.l B1CODE_BASE+pt_dy.m2a+1
        sta.l B1CODE_BASE+pt_dy.m2c+1
        sta.l B1CODE_BASE+pt_dy.m3a+1
        sta.l B1CODE_BASE+pt_dy.m3c+1
        eor #$FF
        sta.l B1CODE_BASE+pt_dy.m2b+1
        sta.l B1CODE_BASE+pt_dy.m2d+1
        sta.l B1CODE_BASE+pt_dy.m3b+1
        sta.l B1CODE_BASE+pt_dy.m3d+1
        ; ... and which way paint_col.pc_wsel branches: rpt_hi = 0 -> the
        ; register path (pc_acc16), else -> pc_wide -> pt_dy. The assembled
        ; displacement is the rpt_hi = 0 one, matching the rpt=0 bake above.
        lda #<[paint_col.pc_acc16-paint_col.pc_wsel-2]
        ldy rs_rpt+1
        beq ?w
        lda #<[paint_col.pc_wide-paint_col.pc_wsel-2]
?w      sta.l B1CODE_BASE+paint_col.pc_wsel+1
        rts
.endp
        .endseg
    .if * > PTMUL_END+1
        ert 'pt_mul outgrew PTMUL_BASE..END (memory_map.inc; AIDT_BASE $0E4D is the ceiling)'
    .endif
        org ptm_resume

;--------------------------------------------------------------
; pt_span -- EVERY span the frame draws lands here: the painter's runs AND the
;   ceiling/floor flats (draw_span tail-jmps in). A = top row, Y = rows (>= 1),
;   zp_color = the shade, zp_col = the column. Preserves X.
;
;   CHAINED (2026-08-10): instead of re-patching the one shared vline BCB and
;   firing the blitter per span (4 window writes + a busy spin + BL_START =
;   ~4000 submits a frame), the span is written into the NEXT chain slot --
;   dst lo/hi, height, colour; every other byte was prefilled by setup_chains
;   and the DST bank byte by ptc_frame's per-frame stamp -- and ptc_fire
;   launches the whole chain later: when the buffer fills (the dec below),
;   before cm_flush's copy reads what the chain paints, and before bg_fill/
;   sprites (renderer.asm). Pixel-identical: the same BCBs the shared-BCB path
;   submitted one by one, just linked by CTRL bit3 and latched by the blitter
;   link by link. What disappears per span is the busy spin and the BL_START
;   poke -- both chip-bus hits -- and per column the whole pt_setup.
;   zp_pt/zp_links are frame-scoped (ptc_open) aliases of loader zp scratch.
;--------------------------------------------------------------
zp_pt    = zp_tsrc                   ; -> current slot in the window (2 B; the
                                     ;   loaders' copy pointer, dead in-frame)
zp_links = mv_ss                     ; links left in the open chain (1 B; the
                                     ;   movers' descent scratch, dead in-frame)
; The painter's hottest cells, aliased onto more render-dead zp scratch
; (goal 2, 2026-08-10): loc_floor is locate_floor's per-call result and
; zp_mvsec is mv_secptr's per-call sector pointer -- movers, doors, AI and the
; player all run outside render_world. ~15 accesses per span go abs->zp.
pc_yacc  = loc_floor                 ; screen row accumulator, Q8 (frac, lo).
                                     ;   The old third byte was write-only --
                                     ;   the ?clamp carry test covers overflow
pc_y     = zp_mvsec                  ; row being painted
pc_yn    = zp_mvsec+1                ; first row past the current run
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_span
        stx zp_savex                 ; the caller's X, back at the rts
        tax                          ; top row -> the row-table index (X is
                                     ;   free the moment it is saved)
        dey                          ; BCB HEIGHT is rows-1
        tya
        xba                          ; B = height-1
        lda zp_color
        xba                          ; A = height-1, B = colour: one 16-bit store
        rep #$21                     ;   fills HEIGHT (14) and AND (15) -- the
        .LONGA ON                    ;   colour is the AND byte, see paint_col's
        ldy #BCB_HEIGHT              ;   emit (2026-09-14)
        sta (zp_pt),y
        .LONGA OFF
        sep #$20
        lda row_hi,x                 ; DST = row*160 + col, one 16-bit add/store
        xba
        lda row_lo,x
        rep #$21
        .LONGA ON
        adc pc_colw                  ; (process_seg's per-column word)
        ldy #BCB_DST_ADDR
        sta (zp_pt),y
        lda zp_pt                    ; slot += 21. C = 0: row*160+col < $8000
        adc #BCB_SIZE
        sta zp_pt
        .LONGA OFF
        sep #$20
        dec zp_links                 ; buffer full -> launch it and build on in
        beq ?full                    ;   the other one (order is preserved)
        ldx zp_savex
        rts
?full   jsl ptc_fire_w0
        ldx zp_savex
        rts
.endp
        .endseg

;--------------------------------------------------------------
; paint_col -- draw ONE wall column as painted runs. draw_twall_clip tail-calls
;   it with A = rs_spa and Y = the height, exactly as it called draw_twall_col;
;   the span itself is read back out of rs_spa/rs_spb. Preserves X.
;   IN: rs_tsrc  this stored column's 2*TEX_RUNK run bytes, in SDRAM
;       rs_texh_cur / rs_texmask / rs_texpow2   the tile (wall_src set them)
;       rs_tpr   texels per screen row (tw_setup / tw_setup_sub)
;       rs_rpt   screen rows per texel        (pt_seg / pt_step)
;       rs_pegrow / rs_vsh                    DOOM's peg (r_segs.c)
;       zp_cm    the sector's COLORMAP row    (lights.asm lt_seg)
;       zp_col   the screen column            (draw_vspan reads it)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc paint_col
        stx pc_x                     ; NOT zp_savex: draw_vspan owns that one,
                                     ;   and it is what carries the run index
                                     ;   across the fill below
        lda rs_texh_cur              ; texH 0 would divide by zero (and a flat
        bne ?texok                   ;   row has no runs at all)
        rts

?texok
 .if 1
	rep #$21		;absorb CLC
	.LONGA ON
	lda rs_tsrc                  ; point both run readers at this column
        sta.l B1CODE_BASE+?rlen+1
        sta.l B1CODE_BASE+?rlen2+1
        sta.l B1CODE_BASE+?rlenp+1   ; (the pad scan's reader, 2026-09-14)
        adc #1
        sta.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?ccol+1
        lda #$38A8                   ; 'tay / sec' = the FAST loop tail (see
        sta.l B1CODE_BASE+pc_bsel    ;   pc_bsel): every column starts uncounted
	sep #$20
	.LONGA OFF
 .else
	lda rs_tsrc                  ; point both run readers at this column
        sta ?rlen+1
        sta ?rlen2+1
        clc
        adc #1
        sta ?rcol+1
        lda rs_tsrc+1
        sta ?rlen+2
        sta ?rlen2+2
        adc #0
        sta ?rcol+2
 .endif
        lda rs_tsrc+2
        sta.l B1CODE_BASE+?rlen+3
        sta.l B1CODE_BASE+?rlen2+3
        sta.l B1CODE_BASE+?rlenp+3
        adc #0
        sta.l B1CODE_BASE+?rcol+3
        sta.l B1CODE_BASE+?ccol+3

                                     ; (pc_colw, the column as a word for the
                                     ;  emit's 16-bit DST add, is process_seg's
                                     ;  per-column store since 2026-09-14)
        rep #$20                     ; rs_rpt baked into pt_dy's table addresses,
        .LONGA ON                    ;   before the FIRST run uses them -- but
        lda rs_rpt                   ;   ONLY when it CHANGED since the last bake
        cmp ptm_last                 ;   (2026-08-11 pm): ONE word compare, and
        sta ptm_last                 ;   the memo stored on the spot (a store
        .LONGA OFF                   ;   changes no flag: Z is still the cmp's --
        sep #$20                     ;   drac030, 2026-09-14). setup_chains zeroes
        jeq ?baked                   ;   ptm_last, so the memo is consistent from
 .if 1                                ;   frame one; pt_dy's operands ASSEMBLE to
                                     ;   (jeq: the inlined bake below is past a
                                     ;   branch's reach -- +2 on the memo path)
                                     ;   the rpt=0 bake.
                                     ; pt_mul and pt_recip INLINED (2026-09-15):
                                     ;   one caller each, ~100 times a frame, 12
                                     ;   cycles of jsr/rts apiece. The procs stay
                                     ;   below as the reference text.
        stz pc_dy+2                  ; --- pt_mul: pt_dy's third byte
        lda rs_rpt                   ; rpt_lo -> the first product (inline in
        sta.l B1CODE_BASE+paint_col.m1a+1    ;   paint_col since 2026-09-14)
        sta.l B1CODE_BASE+paint_col.m1c+1
        eor #$FF                     ; 255 - b, for the mirrored table
        sta.l B1CODE_BASE+paint_col.m1b+1
        sta.l B1CODE_BASE+paint_col.m1d+1
        lda rs_rpt+1                 ; rpt_hi -> the other two (pt_dy)
        sta.l B1CODE_BASE+pt_dy.m2a+1
        sta.l B1CODE_BASE+pt_dy.m2c+1
        sta.l B1CODE_BASE+pt_dy.m3a+1
        sta.l B1CODE_BASE+pt_dy.m3c+1
        eor #$FF
        sta.l B1CODE_BASE+pt_dy.m2b+1
        sta.l B1CODE_BASE+pt_dy.m2d+1
        sta.l B1CODE_BASE+pt_dy.m3b+1
        sta.l B1CODE_BASE+pt_dy.m3d+1
        lda #<[paint_col.pc_acc16-paint_col.pc_wsel-2]
        ldy rs_rpt+1
        beq ?pm_w
        lda #<[paint_col.pc_wide-paint_col.pc_wsel-2]
?pm_w   sta.l B1CODE_BASE+paint_col.pc_wsel+1
        rep #$20                     ; --- pt_recip: rc_m = rpt as ONE word,
        .LONGA ON                    ;   Z = (rpt == 0)
        lda rs_rpt
        sta rc_m
        .LONGA OFF
        sep #$20                     ; (sep leaves Z alone)
        beq ?pr_sat                  ; rpt = 0 -> tpr is off the top
        jsr recip_norm               ; X = mantissa index, rc_e = exponent
        lda.l RCX_INV_LO,x           ; INV_TAB[m] = round(2^23/m), bank $01
        sta m_prod
        lda.l RCX_INV_HI,x
        sta m_prod+1
        clc
        lda #RECIP_INV_K-16
        adc rc_e                     ; rc_e is signed
        bmi ?pr_sat                  ; shift < 0 -> tpr >= 65536
        tax
        beq ?pr_done
        cpx #8                       ; >= 8 -> drop the whole low byte first and
        bcc ?pr_bits                 ;   leave at most 7 single shifts
        lda m_prod+1
        sta m_prod
        stz m_prod+1
        txa
        sec
        sbc #8
        beq ?pr_done
        tax
?pr_bits
        rep #$20                     ; the 1..7 shifts on the WORD in A
        .LONGA ON
        lda m_prod
?pr_b   lsr @
        dex
        bne ?pr_b
        sta rs_tpr                   ; ... and the result lands in rs_tpr directly
        .LONGA OFF
        sep #$20
        bra ?baked
?pr_done
        lda m_prod                   ; a lone dp -> abs word copy, as bytes
        sta rs_tpr
        lda m_prod+1
        sta rs_tpr+1
        bra ?baked
?pr_sat lda #$FF                     ; the saturation tw_setup's ?tprmax used
        sta rs_tpr
        sta rs_tpr+1
 .else
        jsr pt_mul                   ;   frame one; pt_dy's operands ASSEMBLE to
                                     ;   the rpt=0 bake
        jsr pt_recip                 ; ... and rs_tpr = 65536/rpt on the SAME
 .endif
                                     ;   memo (2026-08-27): tpr is rpt's exact
                                     ;   reciprocal, so it changes exactly when
                                     ;   rpt does -- which is what let the whole
                                     ;   tw_setup / tws_anchor divide-and-
                                     ;   interpolate path go away. See pt_recip.
?baked
        ; ---- wt = (spa - pegrow)*tpr + vsh*256, reduced mod texH*256 --------
        ;      the same texel anchor draw_twall_col computed, and for the same
        ;      reason: the texture is pinned to the WORLD, not to the span
        sec
        lda rs_spa
        sbc rs_pegrow
        sta m_a
        lda #0
        sbc rs_pegrow+1
        sta m_a+1
        bpl ?apos
 .if 1
        stz m_a
        stz m_a+1
 .else
        lda #0                       ; spa above the peg (clip slack) -> texel 0
        sta m_a
        sta m_a+1
 .endif
?apos
 .ifdef ANTONIA2
        lda m_a+1                    ; ANTONIA II: (spa-peg) * tpr_q8 in ONE
        ora rs_tpr+1                 ;   hardware multiply while both factors are
        bmi ?apsw                    ;   below $8000 (see smul32: bit 15 on the
        rep #$20                     ;   card is unproven); otherwise the software
        .LONGA ON                    ;   path right below, byte or wide
        lda m_a
        sta.l ANT_MUL
        lda rs_tpr
        sta.l ANT_MUL+2
        lda.l ANT_MUL
        sta m_prod
        lda.l ANT_MUL+2
        sta m_prod+2
        sep #$20
        .LONGA OFF
        jmp ?havep
?apsw
 .endif
        lda m_a+1                    ; (spa-peg) is a BYTE unless the peg row is far
 .if 1
	jne ?wide
 .else
        beq ?byte                    ;   off-screen (a close wall): then, and only
        jmp ?wide                    ;   then, pay for the full 16x16. The byte
?byte
 .endif
	qsmul m_a, rs_tpr, m_prod          ;   path is TWO quarter-squares against
                                     ;   umul16's four plus its carry chain --
                                     ;   ~200 cycles a column, and it is the
                                     ;   common case. STRAIGHT into m_prod: the
                                     ;   qs_p -> m_prod copy that stood here was
                                     ;   12 cycles a column (drac030, 2026-09-14)
        stz m_prod+2
        stz m_prod+3
        qsmul m_a, rs_tpr+1, qs_p          ; + (lo * tpr_hi) << 8
 .if 1
	rep #$21		;absorb CLC
	.LONGA ON
        lda m_prod+1
        adc qs_p
        sta m_prod+1
	sep #$20
	.LONGA OFF
 .else
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
 .endif
 .if 1
	bra ?havep
 .else
        jmp ?havep
 .endif
?wide   lda rs_tpr
        sta m_b
        lda rs_tpr+1
        sta m_b+1
        jsr umul16                   ; m_prod(32) = (spa-peg) * tpr_q8

?havep  lda rs_vsh                   ; DOOM's peg shift: whole texels
        beq ?novsh
        clc
        adc m_prod+1
        sta m_prod+1
        bcc ?novsh
        inc m_prod+2

?novsh  lda rs_texpow2               ; power-of-two texH -> the modulo is an AND
        bne ?slowmod
        lda m_prod
        sta tw_wt
        lda m_prod+1
        and rs_texmask+1
        sta tw_wt+1
 .if 1
        bra ?havewt
 .else
        jmp ?havewt
 .endif
?slowmod lda m_prod+3                ; cannot happen for real geometry, but a
        beq ?red0                    ;   32-bit product would break udiv24
 .if 1
        stz m_prod
        stz m_prod+1
        stz m_prod+2
 .else
        lda #0
        sta m_prod
        sta m_prod+1
        sta m_prod+2
 .endif
?red0
 .if 1
	                              ; m_den = texH*256 (one tile, Q8)
        stz m_den
 .else
	lda #0                       ; m_den = texH*256 (one tile, Q8)
        sta m_den
 .endif
        lda rs_texh_cur
        sta m_den+1
        jsr udiv24

        lda m_rem
        sta tw_wt
        lda m_rem+1
        sta tw_wt+1
?havewt
        ; ---- walk to the run holding texel wt>>8 ---------------------------
        ; COUNT DOWN, don't sum up. The old loop kept a running total in pc_cum
        ; and reloaded it every run (lda.l / clc / adc pc_cum / cmp / beq / bcs /
        ; sta pc_cum = 31 cycles a run, ~8 runs a column). Subtracting each run
        ; from the anchor instead needs no memory round-trip at all: the anchor
        ; is IN the accumulator and the borrow IS the "t0 lands in this run"
        ; test. 18 cycles a run instead of 31 -- ~100 a column, on the
        ; second-biggest fixed cost paint_col has.
        ;   found  <=>  cum + len > wt   <=>  len > wt - cum  <=>  borrow
        ; and the leftover the paint loop wants, (cum_after << 8) - wt, comes
        ; straight back out of the negated accumulator (see ?found).
        ; The `sec` is INSIDE the loop and has to be: the cpx at the bottom
        ; clobbers carry, and without it every run after the first subtracted
        ; one texel too many (69 runs a frame took the wrong branch -- caught by
        ; the span counts in tools/_bench_spans.py, which must not move).
        ldx #0
        lda tw_wt+1                  ; A = texels still ahead of the anchor
 .if 1
	ldy #TEX_RUNK		;load counter to Y
	sec			;get SEC outside the loop
?find
?rlen	sbc.l $000000,x
	bcc ?found
	inx
	inx
	dey
	bne ?find
 .else
?find   sec
?rlen   sbc.l $000000,x              ; run length, in texels (patched above).
        bcc ?found                   ;   A zero-length pad run cannot borrow, so
        inx                          ;   it is skipped for free.
        inx
        cpx #2*TEX_RUNK
        bcc ?find
 .endif
        ldx pc_x                     ; defensive: the runs must cover texH
        rts

?found  sta pc_w                     ; A = wt_hi - cum_after (i.e. -(the leftover))
        sec                          ; rem_q8 = (cum << 8) - wt: what is LEFT of
        lda #0                       ;   the run below the anchor
        sbc tw_wt
        sta pc_f
        lda #0                       ; ... and the high byte is 0 - (-leftover)
        sbc pc_w                     ;     minus the borrow the low byte made
        sta pc_w
 .if 1
                                     ; yacc = spa, Q8 -- set BEFORE the call now,
        stz pc_yacc                  ;   so pt_dy can tail-jump straight into the
 .else
        lda #0                       ; yacc = spa, Q8 -- set BEFORE the call now,
        sta pc_yacc                  ;   so pt_dy can tail-jump straight into the
 .endif
        lda rs_spa                   ;   loop instead of returning here
        sta pc_yacc+1
        sta pc_y
        ; ---- the PT_MAXRUN budget, per LAP (2026-09-14) ---------------------
        ; The tail used to cost `dec pc_g / bne` on every run (9 cycles x ~5.4k
        ; runs a frame). Real runs per lap of the table are constant: n, the
        ; pads being trailing zero-length runs (texruns.py asserts it). With the
        ; anchor at slot x0 the original counter, read just before its dec at
        ; the k-th run (anchor = 1st), is 130-k, and the 129th run is the tail.
        ; pc_g now holds that value for the FIRST run of the next lap:
        ;   129 - n + x0/2 at the anchor, minus n per lap. At a wrap, if it is
        ; <= n the 129th run falls inside the coming lap, so the loop's tail is
        ; patched to the counting form (pc_bsel -> ?cnt) and pc_g decrements
        ; per run exactly as before from there on. Pixel-identical: the same
        ; run fires ?tail. Set-up: 1-2 long reads for n (32 or 16 in E1M1).
        ; Most columns end (spb) before the table wraps, so n and the budget
        ; are computed at the FIRST wrap, not here: the anchor just records
        ; its slot and marks n unknown.
        stx pc_x0                    ; X = x0 (the anchor slot's byte index)
        stz pc_n
        ldy pc_w                     ; the anchor run's texels -> the inline
        jmp ?dyen                    ;   multiply (2026-09-14; was jmp pt_dy)
        ; ---- paint: one span per run, top down, until spb ------------------
        ; 2026-09-14 (bench: 5,700 runs a frame, 43 % of them end in the row
        ; they started): the product w*rpt_lo no longer goes through pc_dy --
        ; lo byte to B, hi byte to A, one xba and it IS the 16-bit dy for the
        ; accumulate; the colormap lookup happens only for runs that draw (and
        ; on the two column-ending paths, which read the index themselves);
        ; the rpt_hi != 0 walls (magnified, close) take pt_dy as before, joined
        ; through pc_paint_mem. Same sums, same carry order, same stores: the
        ; VRAM hash gate is the proof.
        ; LOOP LAYOUT (2026-09-15): the loop's tail FALLS INTO its head. ?rlen2 /
        ; pc_bsel sit right above ?dyen, so the fast tail is `tay` and the `sec`
        ; that opens the multiply -- the `jmp ?dyen` (3 cycles on every one of
        ; ~5,400 runs a frame) is gone, and ?next's lap check branches OUT to the
        ; cold lap code instead of over it (a not-taken bcs, 2 for 3). The
        ; counting tail's patch is the same two bytes ('bra ?cnt' over 'tay /
        ; sec'); pc_paint_mem and pc_wide moved below ?cend. Same instructions
        ; on every run, same order of stores: the VRAM hash gate is the proof.
?ynok   sta pc_yn                    ; yn <= spb here ALWAYS (the ?clamp fork
        sec                          ;   above took every other case), so after
        sbc pc_y                     ;   the span the loop continues without
        beq ?next                    ;   re-comparing against rs_spb.
                                     ;   yn == y: pc_y ALREADY holds yn, so ?adv's
                                     ;   copy is skipped (2,112 runs a frame on
                                     ;   the E1M1 bench, 2026-09-14)
        bcc ?adv                     ; (defensive: yn behind y -> skip, no blit)
        dec                          ; BCB HEIGHT = rows-1 ...
        xba                          ;   ... parked in B while the colour is read
?rcol   lda.l $000001,x              ; the run's PLAYPAL index (patched above).
        beq ?adv                     ;   0 = "no patch covered this texel", the
                                     ;   see-through half of a two-sided middle
                                     ;   texture (midtex.asm): advance y, draw
                                     ;   nothing, and what is behind stays.
                                     ;   texruns.py guarantees an OPAQUE texture
                                     ;   never carries a 0.
        tay
        lda [zp_cm],y                ; through the sector's colormap row -- which
                                     ;   is the thing a blitted wall cannot do
        ; ---- the emit, INLINE: pt_span's body minus the jsr/rts and the X
        ;      save/restore -- X (the run index) is never touched, the
        ;      row-table index rides Y (pc_y is zp).
        ; TWO 16-bit stores (2026-09-14): the colour is the link's AND byte
        ;   (15) now, next to HEIGHT (14) -- the template's SRC is a constant
        ;   $FF, so the blit paints ($FF AND colour) XOR 0 = colour -- and the
        ;   xba puts height low / colour high for ONE store; DST is the other.
        ;   Rapidus: a chip-bus write costs a whole chip cycle plus the wait for
        ;   its boundary; the second byte of a 16-bit store lands on the
        ;   boundary for free, so two pairs are cheaper than four singles.
        xba                          ; A = height-1, B = colour
        rep #$21
        .LONGA ON
        ldy #BCB_HEIGHT
        sta (zp_pt),y                ; [14] = HEIGHT, [15] = AND (the colour)
        .LONGA OFF
        sep #$20
        ldy pc_y                     ; DST = row*160 + col as ONE word: hi into B
        lda row_hi,y                 ;   (xba), lo into A, one 16-bit add of the
        xba                          ;   column word, one 16-bit store of lo+hi
        lda row_lo,y
	rep #$21
	.LONGA ON
        adc pc_colw
        ldy #BCB_DST_ADDR
        sta (zp_pt),y
        lda zp_pt                    ; slot += 21 -- no clc: the DST sum above is
        adc #BCB_SIZE                ;   row*160+col < $8000 (row_hi <= $7C), so
        sta zp_pt                    ;   its add cannot carry out; a 16-bit add
	sep #$20                     ;   replaces the lo/bcc/inc trio
	.LONGA OFF
        dec zp_links                 ; buffer full -> launch it and build on in
        bne ?adv                     ;   the other one (ptc_fire clobbers A only,
        jsl ptc_fire_w0              ;   X/Y survive -- ptc_put/ptc_tail too)
?adv    lda pc_yn
        sta pc_y
?next   inx
        inx
        cpx #2*TEX_RUNK              ; the texture TILES: past the last run is
        bcs ?lap                     ;   the first one again (the lap code is
?nlen                                ;   out of line: the common path falls on)
?rlen2  lda.l $000000,x
        beq ?next                    ; zero-length pad run: FREE
pc_bsel tay                          ; FAST tail: 'tay' and straight into the
                                     ;   'sec' below. The last lap patches these
                                     ;   two bytes to 'bra ?cnt'
?dyen   sec                          ; Y = w: dy = w * rpt_lo, in the accumulator
m1a     lda SQ1L,y                   ;   (the operands are pt_mul's bake -- they
m1b     sbc SQ2L+$FF,y               ;   were pt_dy.m1a..m1d until 2026-09-14;
        xba                          ;   the +$FF operands ARE the rpt=0 bake
m1c     lda SQ1H,y                   ;   ptm_last starts at, see setup_chains)
m1d     sbc SQ2H+$FF,y
        xba                          ; A = dy lo, B = dy hi
pc_wsel bra pc_acc16                 ; DISPLACEMENT PATCHED by pt_mul: pc_acc16
                                     ;   while rpt_hi = 0, pc_wide when it is not
pc_acc16
        rep #$21                     ; C = 0, and A:B is the 16-bit dy
        .LONGA ON
?acc    adc pc_yacc                  ; yacc += this run's screen extent
        sta pc_yacc
        bcs ?clamp                   ; past row 255 -> this run ends the span
        adc #$00FF                   ; y_next = CEIL(yacc) = (yacc + 255) >> 8. C=0
        bcs ?clamp                   ;   (the bcs), and a carry out is the old
        xba                          ;   "carried past row 255"; the >> 8 is xba
        sep #$20                     ;   (?clamp does its own sep)
        .LONGA OFF
        ; y_next = CEIL(yacc), not floor. Row y shows texel
        ; floor((y-peg)*tpr), so it still belongs to a run whose boundary falls
        ; anywhere inside that row -- the first row PAST the run is the ceiling
        ; of the boundary. Flooring it here put every boundary up to one row
        ; early, which at 3x minification moved a fifth of the rows
        ; (tools/_verify_paint.py measures exactly that against the mapping).
        cmp rs_spb
        bcc ?ynok
        beq ?ynok
?clamp  sep #$20                     ; (reached from the 16-bit blocks too)
?ccol   lda.l $000001,x              ; the run's PLAYPAL index (patched above):
        beq ?cend                    ;   transparent last run -> nothing to paint
        tay
        lda [zp_cm],y                ; its shade through the sector's colormap
        sta zp_color                 ;   row (lights.asm) -- pt_span reads it
        lda rs_spb                   ; this run ends the column: paint down to
        inc                          ;   spb and RETURN. pc_y/pc_yn are dead
        sec                          ;   past this point
        sbc pc_y
        beq ?cend
        tay                          ; height
        lda pc_y
        jsr pt_span
?cend   ldx pc_x
        rts
?cnt    dec pc_g                     ; COUNTING tail (the original): a REAL run
        bne ?nt                      ;   spends budget, the 129th fires ?tail
        jmp ?tail
?nt     tay                          ; w straight into the table index
        jmp ?dyen
pc_wide sta pc_dy                    ; rpt_hi != 0: the rpt_lo product to memory,
        xba                          ;   pt_dy adds the two rpt_hi products
        sta pc_dy+1                  ;   (Y = w still) and comes back through
        jmp pt_dy                    ;   pc_paint_mem below
pc_paint_mem                         ; from pt_dy: dy in pc_dy (3 B), rpt_hi != 0
        lda pc_dy+2                  ; a run 256+ rows tall cannot end inside a
        bne ?clamp                   ;   200-row span, so it ends it
        rep #$21
        .LONGA ON
        lda pc_dy
        bra ?acc
        .LONGA OFF
?lap    lda pc_n                     ; a lap ended. First wrap of this column?
        bne ?lapck
        ldx #2*TEX_RUNK-2            ; n: scan the trailing pads down from slot 31
?rlenp  lda.l $000000,x              ;   (patched above; a column has >= 1 run;
        bne ?nok                     ;    1 read for a full 32-run tile)
        dex
        dex
        bra ?rlenp
?nok    txa
        lsr                          ; A = slot index = n-1
        inc
        sta pc_n
        lda pc_x0
        lsr                          ; x0/2
        clc
        adc #PT_MAXRUN+1             ; + 129 (<= 160: fits)
        sec
        sbc pc_n                     ; - n  (>= 97: no borrow) = the budget as
        sta pc_g                     ;   the original held it for slot 0's run
?lapck  ldx #0
        lda pc_g                     ; does the 129th run fall in the coming lap?
        cmp pc_n                     ;   (see the comment at the anchor)
        bcc ?lastlap
        beq ?lastlap
        sbc pc_n                     ; no: one more uncounted lap (C=1: no borrow)
        sta pc_g
        jmp ?nlen
?lastlap
        rep #$20                     ; -> counting mode for the rest of the column
        .LONGA ON
        lda #$80|[[?cnt-pc_bsel-2]<<8]   ; 'bra ?cnt' over the 'tay / sec'
        sta.l B1CODE_BASE+pc_bsel
        sep #$20
        .LONGA OFF
        jmp ?nlen
        ; --- ?tail: fires only when a column crosses PT_MAXRUN real runs, i.e.
        ;     on a far, heavily minified tiled wall. The flat fill takes the
        ;     shade of the LAST RUN THE LOOP PROCESSED: the loop wrote zp_color
        ;     on every run before 2026-09-14, now only the drawing runs do, so
        ;     it is read back here -- walking from X over the zero-length pads
        ;     ?nlen skipped, through copies of the two patched readers (made
        ;     here, on the cold path, never per column).
?tail   lda rs_mpass                 ; the flat tail fill is a MINIFICATION
        bne ?tend                    ;   fallback -- on a masked column it would
                                     ;   paint the gaps shut, so a far strut
                                     ;   simply stops instead (midtex.asm)
        rep #$20
        .LONGA ON
        lda.l B1CODE_BASE+?rlen2+1
        sta.l B1CODE_BASE+?tlen+1
        lda.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?tcol+1
        sep #$20
        .LONGA OFF
        lda.l B1CODE_BASE+?rlen2+3
        sta.l B1CODE_BASE+?tlen+3
        lda.l B1CODE_BASE+?rcol+3
        sta.l B1CODE_BASE+?tcol+3
?tb     dex
        dex
        bpl ?tb2
        ldx #2*TEX_RUNK-2
?tb2
?tlen   lda.l $000000,x
        beq ?tb
?tcol   lda.l $000001,x
        tay
        lda [zp_cm],y
        sta zp_color
        sec                          ; rows = spb - y + 1
        lda rs_spb
        sbc pc_y
	inc
        tay
        lda pc_y
        jsr pt_span
?tend   ldx pc_x
        rts
 .if 1
 .else
    .if * > PTTAIL_END+1
        ert 'paint_col ?tail outgrew PTTAIL_BASE..END (memory_map.inc)'
    .endif
        org pc_resume
 .endif
.endp
        .endseg

    .if * > SGBSP_BASE
        ert 'paint.asm ran into sg_bsp at $0BFC -- the $0900 block ends there (cm_sscl left, memo+inline took its hole)'
    .endif
        org paint_resume
