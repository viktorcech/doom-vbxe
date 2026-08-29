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
.proc pt_seg
        lda #0
        sta rs_rptf
        sta rs_drpt
        sta rs_drpt+1
        sta rs_drpt+2
        lda rs_worldh+1              ; worldH <= 0 (degenerate / closed door) ->
        bmi ?fj                      ;   one texel per row, like tw_setup's ?flat
        ora rs_worldh
        bne ?wok
?fj     jmp ?flat
?wok    lda rs_worldh
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
        bpl ?dpos0
        jmp ?flat                    ; ceiling below floor
?dpos0
        ; ROUND (2026-08-27): dividend += worldH/2 before the divide. udiv24
        ; truncates, and now that paint_col takes the RECIPROCAL of rpt for
        ; rs_tpr (pt_recip), half an LSB low here is amplified into whole texels
        ; on a minified wall: over an E1M1 spawn frame this one add took the max
        ; |tpr error| from 32 to 18 and the mean from 2.54 to 1.41.
        ; The overflow guard moved BELOW it, so it sees the dividend actually
        ; divided -- rounding can push a quotient that was exactly 65535 over.
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
        lda m_prod+2
        adc #0
        sta m_prod+2
        bcs ?sat
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
?dpos   jsr udiv24
        lda m_quot
        sta rs_drpt
        lda m_quot+1
        sta rs_drpt+1
        lda #0
        sta rs_drpt+2
        rts
?flat   lda #0                       ; 1.0 screen row per texel
        sta rs_rpt
        lda #1
        sta rs_rpt+1
        rts
.endp


;--------------------------------------------------------------
; pt_step -- one column on: rpt += drpt (Q16). Called from the column loop's
;   ?cnext beside the plane accumulators, i.e. for EVERY column, drawn or
;   skipped -- an accumulator that only advanced on drawn columns would drift
;   away from the geometry over a seg. Clobbers A only.
;--------------------------------------------------------------
.proc pt_step
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
.endp
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
.proc pt_recip
        lda rs_rpt
        sta rc_m
        lda rs_rpt+1
        sta rc_m+1
        ora rc_m
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
        lda #0
        sta m_prod+1
        txa
        sec
        sbc #8
        beq ?done
        tax
?bits   lsr m_prod+1
        ror m_prod
        dex
        bne ?bits
?done   lda m_prod
        sta rs_tpr
        lda m_prod+1
        sta rs_tpr+1
        rts
?sat    lda #$FF                     ; the saturation tw_setup's ?tprmax used
        sta rs_tpr
        sta rs_tpr+1
        rts
.endp
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
.proc pt_dy
        ldy pc_w
yen     sec                          ; w * rpt_lo (yen: enter with w already in
m1a     lda SQ1L,y                   ;   Y -- the run loop's path)
m1b     sbc SQ2L+$FF,y               ; the +$FF operands ARE pt_mul's rpt=0 bake
        sta pc_dy                    ;   (255-0 mirrored index): ptm_last starts
m1c     lda SQ1H,y                   ;   at 0 (setup_chains), so the memo in
m1d     sbc SQ2H+$FF,y               ;   paint_col is consistent before the
        sta pc_dy+1                  ;   first real bake ever runs
        lda rs_rpt+1                 ; under one row per texel -- every wall at
        beq ?done                    ;   any distance -- the rest is zero, so
                                     ;   this is EXACT, not a shortcut. pc_dy+2
                                     ;   is already 0 on this path: rs_rpt is a
                                     ;   per-COLUMN constant, so pt_mul zeroes it
                                     ;   once instead of every run doing it.
        lda #0
        sta pc_dy+2
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
        clc
        lda pc_dy
        adc qs_p
        sta pc_dy
        lda pc_dy+1
        adc qs_p+1
        sta pc_dy+1
        bcc ?done
        inc pc_dy+2
?done   lda #0                       ; pc_f is the ANCHOR run's part-texel and the
        sta pc_f                     ;   m3 product above has just consumed it.
                                     ;   Every later run enters with it already 0,
                                     ;   so clearing it costs them nothing and saves
                                     ;   ?found a store after the call.
        jmp paint_col.pc_paint       ; TAIL JUMP into the column loop: both call
                                     ;   sites used to pay jsr + rts, and the run
                                     ;   loop a jmp on top -- 15 cycles on a path
                                     ;   taken 5332 times a frame.
.endp

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
.proc pt_mul
        lda #0                       ; pt_dy's third byte: only the rpt_hi branch
        sta pc_dy+2                  ;   ever sets it, and rpt is per column
        lda rs_rpt                   ; rpt_lo -> the first product
        sta pt_dy.m1a+1
        sta pt_dy.m1c+1
        eor #$FF                     ; 255 - b, for the mirrored table
        sta pt_dy.m1b+1
        sta pt_dy.m1d+1
        lda rs_rpt+1                 ; rpt_hi -> the other two
        sta pt_dy.m2a+1
        sta pt_dy.m2c+1
        sta pt_dy.m3a+1
        sta pt_dy.m3c+1
        eor #$FF
        sta pt_dy.m2b+1
        sta pt_dy.m2d+1
        sta pt_dy.m3b+1
        sta pt_dy.m3d+1
        rts
.endp
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
.proc pt_span
        stx zp_savex                 ; the caller's X, back at the rts
        tax                          ; top row -> the row-table index (X is
                                     ;   free the moment it is saved)
        dey                          ; BCB HEIGHT is rows-1
        tya
        ldy #BCB_HEIGHT
        sta (zp_pt),y
        lda zp_color
        ldy #BCB_XOR
        sta (zp_pt),y
        lda row_lo,x
        clc
        adc zp_col
        ldy #BCB_DST_ADDR
        sta (zp_pt),y
        lda row_hi,x
        adc #0
        iny
        sta (zp_pt),y
        lda zp_pt                    ; slot += 21
        clc
        adc #BCB_SIZE
        sta zp_pt
        bcc ?nc
        inc zp_pt+1
?nc     dec zp_links                 ; buffer full -> launch it and build on in
        beq ?full                    ;   the other one (order is preserved)
        ldx zp_savex
        rts
?full   jsr ptc_fire
        ldx zp_savex
        rts
.endp

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
.proc paint_col
        stx pc_x                     ; NOT zp_savex: draw_vspan owns that one,
                                     ;   and it is what carries the run index
                                     ;   across the fill below
        lda rs_texh_cur              ; texH 0 would divide by zero (and a flat
        bne ?texok                   ;   row has no runs at all)
        rts
?texok  lda rs_tsrc                  ; point both run readers at this column
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
        lda rs_tsrc+2
        sta ?rlen+3
        sta ?rlen2+3
        adc #0
        sta ?rcol+3
        lda rs_rpt                   ; rs_rpt baked into pt_dy's table addresses,
        cmp ptm_last                 ;   before the FIRST run uses them -- but
        bne ?bake                    ;   ONLY when it CHANGED since the last bake
        lda rs_rpt+1                 ;   (2026-08-11 pm): rpt steps by rs_drpt,
        cmp ptm_last+1               ;   under one LSB per column on most walls,
        beq ?baked                   ;   so whole runs of columns share one bake
?bake   lda rs_rpt                   ;   (~79 cyc each). pt_dy's operands
        sta ptm_last                 ;   ASSEMBLE to the rpt=0 bake and
        lda rs_rpt+1                 ;   setup_chains zeroes ptm_last, so the
        sta ptm_last+1               ;   memo is consistent from frame one.
        jsr pt_mul
        jsr pt_recip                 ; ... and rs_tpr = 65536/rpt on the SAME
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
        lda #0                       ; spa above the peg (clip slack) -> texel 0
        sta m_a
        sta m_a+1
?apos   lda m_a+1                    ; (spa-peg) is a BYTE unless the peg row is far
        beq ?byte                    ;   off-screen (a close wall): then, and only
        jmp ?wide                    ;   then, pay for the full 16x16. The byte
?byte   qsmul m_a, rs_tpr            ;   path is TWO quarter-squares against
        lda qs_p                     ;   umul16's four plus its carry chain --
        sta m_prod                   ;   ~200 cycles a column, and it is the
                                     ;   common case.
        lda qs_p+1
        sta m_prod+1
        lda #0
        sta m_prod+2
        sta m_prod+3
        qsmul m_a, rs_tpr+1          ; + (lo * tpr_hi) << 8
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
        jmp ?havep
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
        jmp ?havewt
?slowmod lda m_prod+3                ; cannot happen for real geometry, but a
        beq ?red0                    ;   32-bit product would break udiv24
        lda #0
        sta m_prod
        sta m_prod+1
        sta m_prod+2
?red0   lda #0                       ; m_den = texH*256 (one tile, Q8)
        sta m_den
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
?find   sec
?rlen   sbc.l $000000,x              ; run length, in texels (patched above).
        bcc ?found                   ;   A zero-length pad run cannot borrow, so
        inx                          ;   it is skipped for free.
        inx
        cpx #2*TEX_RUNK
        bcc ?find
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
        lda #0                       ; yacc = spa, Q8 -- set BEFORE the call now,
        sta pc_yacc                  ;   so pt_dy can tail-jump straight into the
        lda rs_spa                   ;   loop instead of returning here
        sta pc_yacc+1
        sta pc_y
        lda #PT_MAXRUN
        sta pc_g
        jmp pt_dy                    ; ... and pt_dy clears pc_f on its way out
        ; ---- paint: one span per run, top down, until spb ------------------
pc_paint
?rcol   lda.l $000001,x              ; the run's PLAYPAL index (patched above).
        tay                          ;   Read for EVERY run, even one too thin to
        lda [zp_cm],y                ;   draw, so ?tail below always has a colour
        sta zp_color                 ;   from THIS column. Through the sector's
                                     ;   colormap row -- which is the thing a
                                     ;   blitted wall cannot do (lights.asm).
        lda pc_dy+2                  ; a run 256+ rows tall cannot end inside a
        bne ?clamp                   ;   200-row span, so it ends it -- and that
                                     ;   takes the accumulator's third byte out
                                     ;   of the per-run path entirely
        clc                          ; yacc += this run's screen extent
        lda pc_yacc
        adc pc_dy
        sta pc_yacc
        lda pc_yacc+1
        adc pc_dy+1
        sta pc_yacc+1
        bcs ?clamp                   ; past row 255 -> this run ends the span
        ; y_next = CEIL(yacc), not floor. Row y shows texel
        ; floor((y-peg)*tpr), so it still belongs to a run whose boundary falls
        ; anywhere inside that row -- the first row PAST the run is the ceiling
        ; of the boundary. Flooring it here put every boundary up to one row
        ; early, which at 3x minification moved a fifth of the rows
        ; (tools/_verify_paint.py measures exactly that against the mapping).
        lda pc_yacc                  ; C = there is a fraction left
        cmp #1
        lda pc_yacc+1
        adc #0
        bcs ?clamp                   ; ... and it carried past row 255
        cmp rs_spb
        bcc ?ynok
        beq ?ynok
?clamp  iny                          ; transparent last run -> nothing to paint
        dey                          ;   (Y is still the raw index; see ?ynok)
        beq ?cend
        lda rs_spb                   ; this run ends the column: paint down to
        clc                          ;   spb and RETURN. pc_y/pc_yn are dead
        adc #1                       ;   past this point, so neither the pc_yn
        sec                          ;   store nor the old post-emit compare
        sbc pc_y                     ;   against rs_spb is paid any more
        beq ?cend
        tay                          ; height
        lda pc_y
        jsr pt_span
?cend   ldx pc_x
        rts
?ynok   sta pc_yn                    ; yn <= spb here ALWAYS (the ?clamp fork
        sec                          ;   above took every other case), so after
        sbc pc_y                     ;   the span the loop continues without
        beq ?adv                     ;   re-comparing against rs_spb
        bcc ?adv                     ; (defensive: yn behind y -> skip, no blit)
        iny                          ; TRANSPARENT? Y is still the run's RAW
        dey                          ;   PLAYPAL index (nothing between ?rcol
        beq ?adv                     ;   and here touches it) and index 0 means
                                     ;   "no patch covered this texel" -- the
                                     ;   see-through half of a two-sided middle
                                     ;   texture (midtex.asm). Advance y, draw
                                     ;   nothing, and what is behind stays.
                                     ;   iny/dey and not cpy, because the emit
                                     ;   below needs the C the sbc left. Six
                                     ;   cycles a run; texruns.py guarantees an
                                     ;   OPAQUE texture never carries a 0.
        ; ---- the emit, INLINE (2026-08-11 pm): pt_span's body minus the jsr/
        ;      rts and the X save/restore -- X (the run index) is simply never
        ;      touched, the row-table index rides Y instead (pc_y is zp). Same
        ;      four BCB fields, same values, same slot advance: ~20 cycles off
        ;      EVERY painted run. ?clamp/?tail still jsr pt_span (per column).
        sbc #1                       ; C=1 (bcc not taken): BCB HEIGHT = rows-1
        ldy #BCB_HEIGHT
        sta (zp_pt),y
        lda zp_color
        ldy #BCB_XOR
        sta (zp_pt),y
        ldy pc_y
        lda row_lo,y
        clc
        adc zp_col
        ldy #BCB_DST_ADDR
        sta (zp_pt),y
        ldy pc_y
        lda row_hi,y
        adc #0                       ; C from the low byte (ldy touches no flags)
        ldy #BCB_DST_ADDR+1
        sta (zp_pt),y
        lda zp_pt                    ; slot += 21
        clc
        adc #BCB_SIZE
        sta zp_pt
        bcc ?pnc
        inc zp_pt+1
?pnc    dec zp_links                 ; buffer full -> launch it and build on in
        bne ?adv                     ;   the other one (ptc_fire clobbers A only,
        jsr ptc_fire                 ;   X/Y survive -- ptc_put/ptc_tail too)
?adv    lda pc_yn
        sta pc_y
?next   inx
        inx
        cpx #2*TEX_RUNK              ; the texture TILES: past the last run is
        bcc ?nlen                    ;   the first one again
        ldx #0
?nlen
?rlen2  lda.l $000000,x
        beq ?next                    ; zero-length pad run: FREE -- only a REAL
        dec pc_g                     ;   run spends budget (2026-08-10). The
        bne ?nt                      ;   pads used to eat it too, so a 4-run
        jmp ?tail                    ;   (?tail is out of the block now, below)
?nt                                  ;
                                     ;   tile paid K-4 dead decrements per lap
                                     ;   and a far tiled wall went flat after
                                     ;   ~1.5 laps of a 24 budget. Safe: the
                                     ;   anchor walk only enters this loop on a
                                     ;   column with a nonzero run, so the pad
                                     ;   scan always terminates.
        tay                          ; w straight into the table index: pc_w is
        jmp pt_dy.yen                ;   the ANCHOR path's cell now (pc_f stays
                                     ;   third product is skipped either way)
        ; --- ?tail, RELOCATED (2026-08-15). The $0900 block had four spare
        ;     bytes and the transparency test wants eight, so the coldest thing
        ;     in it moves out: this fires only when a column crosses PT_MAXRUN
        ;     real runs, i.e. on a far, heavily minified tiled wall.
pc_resume = *
        org PTTAIL_BASE
?tail   lda rs_mpass                 ; the flat tail fill is a MINIFICATION
        bne ?tend                    ;   fallback -- on a masked column it would
                                     ;   paint the gaps shut, so a far strut
                                     ;   simply stops instead (midtex.asm)
        sec                          ; rows = spb - y + 1
        lda rs_spb
        sbc pc_y
        clc
        adc #1
        tay
        lda pc_y
        jsr pt_span                  ; zp_color is still the last run's shade
?tend   ldx pc_x
        rts
    .if * > PTTAIL_END+1
        ert 'paint_col ?tail outgrew PTTAIL_BASE..END (memory_map.inc)'
    .endif
        org pc_resume
.endp

    .if * > SGBSP_BASE
        ert 'paint.asm ran into sg_bsp at $0BFC -- the $0900 block ends there (cm_sscl left, memo+inline took its hole)'
    .endif
        org paint_resume
