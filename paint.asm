;--------------------------------------------------------------
; paint.asm -- walls the engine PAINTS from texture runs read out of SDRAM
;   (TEX_RUNS) instead of blitting pixels from VRAM.
;--------------------------------------------------------------
PT_MAXRUN   equ 128                  ; REAL runs painted per column before the
                                     ;   tail is filled flat
PT_XB       equ 256-2*TEX_RUNK       ; 2026-09-28: the run index X starts HERE, so
                                     ;   the slot after the 32nd is its wrap to 0
                                     ;   (inx/inx/beq, no cpx); rs_tsrc arrives
                                     ;   lower by PT_XB (arena_init's tex_sdram)
    .if PT_MAXRUN+TEX_RUNK > 255 || PT_MAXRUN < TEX_RUNK
        ert 'paint_col ?lap keeps the run budget + a slot index in a byte, and never counts the first lap'
    .endif

paint_resume = *
        org TWRUNS_BASE              ; the $0900 fast page tw_runs vacates. It is
                                     ; the same Rapidus window the blit path's ...

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
        stz rs_rptf
        stz rs_drpt
        stz rs_drpt+1
        stz rs_drpt+2
        lda rs_worldh+1              ; worldH <= 0 (degenerate / closed door) ->
        bmi ?fj                      ;   one texel per row, like tw_setup's ?flat
        ora rs_worldh
        bne ?wok
?fj     jmp ?flat
?wok
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
	jmi ?flat
        ; ROUND (2026-08-27): dividend += worldH/2 before the divide. udiv24 ...
	rep #$20
	.LONGA ON
        lda rs_worldh
        lsr
        clc
        adc m_prod
        sta m_prod
	sep #$20
	.LONGA OFF
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

	stz m_prod
	rep #$20
	.LONGA ON
        UDQ                          ; A = m_quot (2026-09-26: no reload)
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
                                     ; past udiv24's rep, still 16-bit (65816-windows:
	jsr udiv24.ud_w16            ;   this sep and that rep were an empty pair)
	.LONGA OFF

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
	.LONGA ON
	sta m_prod+1
	jsr udiv24.ud_w16            ; past udiv24's rep, still 16-bit (no sep/rep pair)
	.LONGA OFF

        lda m_quot
        sta rs_drpt
        lda m_quot+1
        sta rs_drpt+1
        stz rs_drpt+2
        rts

?flat
        stz rs_rpt
        lda #1
        sta rs_rpt+1
        rts
.endp
        .endseg
    .if * > PTSEG_END+1
        ert 'pt_seg outgrew PTSEG_BASE..PTSEG_END (memory_map.inc)'
    .endif
        org pts_resume
; pt_step (rpt += drpt per column) is INLINED in process_seg's ?cnext since
; 2026-09-14; pt_recip and pt_mul are inlined in paint_col's bake. Their
; standalone copies had no caller left and went on 2026-09-25.

;--------------------------------------------------------------
; pt_dy -- pc_dy (Q8 screen rows) = (pc_w + pc_f/256 texels) * rs_rpt.
;   Clobbers A/Y and qs_p.
;--------------------------------------------------------------
    .if [<SQ1L]|[<SQ1H]|[<SQ2L]|[<SQ2H]
        ert 'SQ1L/SQ1H/SQ2L/SQ2H must all be page aligned -- the bake patches only the LOW byte of each base'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_dy
        ; THE rpt_hi != 0 PATH ONLY (2026-09-14). paint_col's inline ?dyen ...
        stz pc_dy+2
        sec
m2a     lda SQ1L,y                   ; + (w * rpt_hi) << 8
m2b     sbc SQ2L+$FF,y
        sta qs_p
m2c     lda SQ1H,y
m2d     sbc SQ2H+$FF,y
        sta qs_p+1
                                      ; 2026-09-22 idiom: the 16-bit add in one window
        rep #$21                     ;   (absorbs the clc), as umul16 does: -2 a run on
        .LONGA ON                    ;   the near-wall path
        lda pc_dy+1
        adc qs_p
        sta pc_dy+1
        sep #$20
        .LONGA OFF
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
; pt_span -- EVERY span the frame draws lands here: the painter's runs AND the
;   ceiling/floor flats. A = the span's LAST row (2026-09-28: the links paint
;   BOTTOM-UP, DST_STEPY = -160, see paint_col's loop), Y = rows-1, B = the
;   shade. OUT: X = the column. Entry px: the row is in X already.
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
pc_y16   = zp_mvsec                  ; (y << 8) | $FF as ONE word: what the run
                                     ;   loop subtracts from yacc (2026-09-25,
                                     ;   see ?acc); its high byte ...
pc_y     = zp_mvsec+1                ; ... IS the row being painted
pc_a0    = pc_cum                    ; the anchor's slot (X), 0 once the first lap
                                     ;   is counted (2026-09-28; pc_cum was free)
    .if zp_savex <> zp_pt+2
        ert 'zp_pt+2 must be zp_savex: the bank byte of [zp_pt],y, kept 0 (ptc_open)'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pt_span
        tax                          ; the row -> the row-table index. OUT: X = the
                                     ;   COLUMN (pcx), whatever X was: every caller
                                     ;   but sky_clip has X = the column anyway, and
                                     ;   sky_clip saves its run index itself
px                                    ; 2026-09-22 idiom: Y ARRIVES as rows-1 (BCB HEIGHT)
                                     ;   -- "a constant added on every pass belongs in
                                     ;   the start value": draw_span/sky_clip/paint_col
                                     ;   hand it over that way, the dey went
        tya                          ; A = height-1 -- and B is the COLOUR: every
                                      ;   caller `xba`s it there where it used to
                                     ;   `sta zp_color` (2026-09-22, 6502-idioms: a
                                     ;   temp that is only parked lives in a
                                     ;   register; the store and the reload go)
        rep #$21                     ;   fills HEIGHT (14) and AND (15) -- the
        .LONGA ON                    ;   colour is the AND byte, see paint_col's
                                      ;   emit (2026-09-14)
        ldy #BCB_HEIGHT-BCB_DST_ADDR ; 2026-09-22: zp_pt -> the slot's DST field
                                      ; 2026-09-22 (alt-src cpu65c816.cpp): a (dp),y STORE
        sta [zp_pt],y                ;   always dummy-reads its target first, and in the
                                      ; HEIGHT -> DST is 22 fast cycles, two chip cycles
        lda row_hi-1,x               ;   exactly (rapidus-bus-timing): row_hi[x] into B
        .LONGA OFF                   ;   by a word read (row_hi-1+199 stays in page),
        sep #$20                     ;   the column as an immediate, `sta (zp_pt)` (no
        lda row_lo,x                 ;   bank byte: DBR = 0 = zp_savex, alt-src
        rep #$21                     ;   cpu65c816.cpp DpInd)
        .LONGA ON
pcw     adc #0                       ; + the column, PATCHED per column (process_seg
        sta (zp_pt)                  ;   mskr; the high byte stays 0). DST, as paint_col
pcx     ldx #0                       ; X = the column again (patched with pcw; keeps
        lda zp_pt                    ;   C: row*160+col < $8000 did not carry). +21
        adc #BCB_SIZE
        sta zp_pt
                                      ; 2026-09-22: as paint_col's pc_cend -- the END
ps_cend cmp #BCB_SIZE*TW_MAXLINKS+BCB_DST_ADDR   ;   slot (its DST field) as the
        .LONGA OFF                   ;   ptc_open; sep keeps Z (-2 a span)
        sep #$20
        beq ?full
        rts
?full   jmp ptc_fire                 ; tail call (both in bank $01, both rts)
.endp
        .endseg

;--------------------------------------------------------------
; paint_col -- draw ONE wall column as painted runs. draw_twall_clip tail-calls
;   it with A = rs_spa and Y = the height, exactly as it called draw_twall_col;
;   the span itself is read back out of rs_spa/rs_spb. Preserves X.
;   IN: rs_tsrc  this stored column's 2*TEX_RUNK run bytes, in SDRAM: per run
;                (2*texels, PLAYPAL index). pack_textures stores the length
;                DOUBLED (2026-09-25): read as one word it is the word tables'
;                index as it comes, and a 128-texel run is shipped as 64 + 64,
;                so w <= 127 everywhere (2w in a byte, SQ1W/NSQ2W in range).
;       rs_texh_cur / rs_texmask / rs_texpow2   the tile (wall_src set them)
;       rs_tpr   texels per screen row (the bake below)
;       rs_rpt   screen rows per texel        (pt_seg / process_seg ?cnext)
;       rs_pegrow / rs_vsh                    DOOM's peg (r_segs.c)
;       zp_cm    the sector's COLORMAP row    (lights.asm lt_seg)
;       zp_col   the screen column            (draw_vspan reads it)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
pc_bkj  jmp paint_col.bake           ; the far reach for paint_col's memo test
.proc paint_col
        ; 2026-09-28: the column's three rare exits sit AHEAD of the entry
        ; (pc_in, draw_twall_clip's jmp), in the reach of their branches --
        ; the setup below has no unconditional branch left to hide them behind
        .LONGA ON
?bkp    pha                          ; (16-bit A = the address: kept)
        .LONGA OFF
        sep #$20
        tya
        sta.l B1CODE_BASE+?rlen+3    ; the bank byte into all five run readers --
        sta.l B1CODE_BASE+?rlenb+3   ;   the address is 64-aligned (a 128-aligned
        sta.l B1CODE_BASE+?rlen2+3   ;   payload + column*64 - PT_XB), so the
        sta.l B1CODE_BASE+?rcol+3    ;   +1/+2 the low-word patches add never
        sta.l B1CODE_BASE+?ccol+3    ;   carry into it
        sta.l B1CODE_BASE+pc_bk+1    ; ... and into the memo's own operand
        rep #$20
        .LONGA ON
        pla
        bra ?bkok
        .LONGA OFF
 .ifdef ANTONIA2
?aneg   stz m_a                      ; spa < pegrow (rare): m_a = 0 -> the byte
        stz m_a+1                    ;   path
        bra pc_abyte
?wj     jmp pc_widem                 ; |spa-peg| >= 256: the wide multiply (rare, 2026-09-26)
 .else
?ahi    lda #0                       ; 2026-09-29: the HIGH byte, only when it can
        sbc rs_pegrow+1              ;   be other than 0 (C is the low subtract's:
        bmi ?aneg                    ;   ldy keeps it)
        bne ?wj
        lda m_a                      ; 0 after all: the byte path, A = m_a, C = 1
        sec
        bra pc_abyte
?aneg   stz m_a+1                    ; spa < pegrow (rare): m_a = 0 -> the byte
        lda #0                       ;   path (a written 0: A = m_a for it)
        sta m_a
        sec
        bra pc_abyte
?wj     sta m_a+1                    ; |spa-peg| >= 256: the wide multiply (rare)
        jmp pc_widem
 .endif
        ; pc_in (2026-09-29) -- IN: 16-bit M, A = the run bytes' address (low
        ; word), Y = its bank byte, X = the column = zp_col, tx_slot = the tile.
                                     ; texH is never 0 here: a texid is only kept
                                     ;   (not $FF) when MAP_TEXH != 0 (seg_draw
                                     ;   ?wflat/?lflat), so no divide-by-zero test
        .LONGA ON
pc_in
pc_bk   cpy #0                       ; the bank byte, patched only when it changed
        bne ?bkp                     ;   (6502-loops-tables-smc: the memo IS this
?bkok                                ;   operand), out of line
        sta.l B1CODE_BASE+?rlen+1    ; point the run readers at this column
        sta.l B1CODE_BASE+?rlen2+1
        inc @
        sta.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?ccol+1
        inc @                        ; tsrc+2: ?find's second run of a pass (2026-09-26)
        sta.l B1CODE_BASE+?rlenb+1
                                     ; (the loop's DST add, pcolw, gets the column
                                     ;   from process_seg mskr, once a column)
        ; 2026-09-28: NO 2n here any more (a patch, a read and a bound per
        ; column, ~40 cycles x 350). The loop finds the column's end itself: a
        ; PAD (2w = 0) multiplies to dy-1 = -1 with C = 0, the add carries out
        ; and ?clamp sorts it from a real clamp by Y = 0; a full 32-run column
        ; ends on X's wrap. n is read at ?lap, 55 times a frame.
                                     ; rs_rpt baked into the table addresses,
                                     ;   before the FIRST run uses them -- but
        lda rs_rpt                   ;   ONLY when it CHANGED since the last bake
        cmp ptm_last                 ;   (2026-08-11 pm): ONE word compare. The
        .LONGA OFF                   ;   bake stores the memo itself (2026-09-25:
        sep #$20                     ;   it reads the OLD one first, for rpt_hi).
        bne pc_bkj                   ;   setup_chains zeroes ptm_last; the operands
                                     ;   ASSEMBLE to the rpt=0 bake (pc_wsel's word
                                     ;   form is safe there too, see the bake). The
                                     ;   memo holds for ~70 % through here, the
                                     ;   bake is out of line
?baked
        ; ---- wt = (spa - pegrow)*tpr + vsh*256, reduced mod texH*256 -------- ...
        sec
        lda rs_spa
        sbc rs_pegrow
        sta m_a
 .ifndef ANTONIA2
        bcc ?ahi                     ; 2026-09-29: no borrow, pegrow < 256 (common):
        ldy rs_pegrow+1              ;   the high byte is 0 without working it out,
        bne ?ahi                     ;   and A is still m_a for the multiply
 .else
        lda #0
        sbc rs_pegrow+1
        sta m_a+1
        bmi ?aneg                    ; m_a < 0: out of line (?aneg, below ?nok)
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
                                      ; 2026-09-22 idiom: flags are values you track --
  .ifdef ANTONIA2                     ;   Z is still `sbc rs_pegrow+1`'s (sta/bpl keep
        lda m_a+1                    ;   it), so the byte/wide fork needs no reload.
	bne ?wj                      ;   (ANTONIA2's block above clobbers it: reload)
pc_abyte
	qsmulx m_a, rs_tpr, m_prod
  .else
pc_abyte                             ; A = m_a and C = 1 on every way in: the low
                                     ;   subtract did not borrow (bcc ?ahi not taken)
                                      ; X is dead here (?havewt loads it): qsmulx fuses
	qsmulx m_a, rs_tpr, m_prod, ld, c1 ;   each table read with its subtract -- no
                                     ;   store/reload of :3 (6502-idioms)
  .endif
        qsmulxa m_a, rs_tpr+1              ; + (lo * tpr_hi) << 8, IN A:B (math.asm)
	rep #$21		;absorb CLC
	.LONGA ON
        stz m_prod+2                 ; bytes 2-3 = 0 as ONE word (qsmulxa keeps them:
        adc m_prod+1                 ;   A:B, X, Y only); the add reads byte 2
        sta m_prod+1
	sep #$20
	.LONGA OFF
                                     ; (the wide path, pc_widem, is out of line below)
?havep  ldy tx_slot                  ; the tile's three facts, by slot (0 the wall's,
        lda rs_vshw,y                ;   1 the lower step's: per SEG, process_seg).
        beq ?novsh                   ;   DOOM's peg shift: whole texels
        clc
        adc m_prod+1
        sta m_prod+1
        bcc ?novsh
        inc m_prod+2

?novsh  lda rs_texpow2,y             ; power-of-two texH -> the modulo is an AND
        bne ?slowmod
        lda m_prod
        sta tw_wt
        lda m_prod+1
        and rs_texmask,y             ; A = wt's high byte, kept in A (only ?havewt
?havewt                              ;   reads it; ?slowmod arrives the same way)
        ; ---- walk to the run holding texel wt>>8 ---------------------------
        ; COUNT DOWN, don't sum up: A = 2 * (the texels still ahead of the
        ; anchor), the run bytes being 2w (2026-09-25).
        asl                          ; wt_hi <= texH-1 <= 127: no carry out
        ldx #PT_XB                   ; slot 0 (2026-09-28: X is biased, see ?next)
	sec			;get SEC outside the loop
                                     ; TWO runs a pass, no counter (2026-09-26):
?find                                ;   the packer makes the runs SUM to texH
?rlen	sbc.l $000000,x              ;   (texruns.py) and wt_hi <= texH-1, so the
	bcc ?found                   ;   walk always borrows inside the column --
?rlenb	sbc.l $000002,x              ;   the dey/bne guard never fired. ~2,600
	bcc ?found2                  ;   runs a frame walk here: -3.5 cycles each
	inx
	inx
	inx
	inx
	bra ?find
                                     ; the two rare paths, out of line:
?slowmod lda m_prod+3                ; cannot happen for real geometry, but a
        beq ?red0                    ;   32-bit product would break udiv24
        stz m_prod
        stz m_prod+1
        stz m_prod+2
?red0
	                              ; m_den = texH*256 (one tile, Q8)
        stz m_den
        lda rs_wtexh                 ; the tile's height, by slot (Y = tx_slot)
        cpy #0
        beq ?smh
        lda rs_ltexh
?smh    sta m_den+1
        jsr udiv24

        lda m_rem
        sta tw_wt
        lda m_rem+1                  ; wt's high byte in A, as the pow2 path
        bra ?havewt
pc_widem lda rs_tpr                  ; |spa-peg| >= 256
        sta m_b
        lda rs_tpr+1
        sta m_b+1
        jsr umul16                   ; m_prod(32) = (spa-peg) * tpr_q8
        jmp ?havep
?found2 inx                          ; (2026-09-26) the borrow came from the pass's SECOND run
        inx
?found  tay                          ; 2026-09-29 (no php/plp, no pc_w): A = -2*(the leftover),
        sec                          ;   parked in Y. rem_q8 = (cum << 8) - wt: what
        lda #0                       ;   is LEFT of the run below the anchor
        sbc tw_wt
        sta pc_f                     ; C = 1 iff wt's fraction is 0 (b = 0)
        tya                          ; (tya / eor / dec / inc keep C)
        eor #$FF                     ; 2*leftover - 1 (leftover >= 1: the sbc.l
        dec @                        ;   borrowed), - 1 = 2*(leftover - 1): the
        bcc ?fs                      ;   fraction takes a texel off the anchor run,
        inc @                        ;   the common case; b = 0 puts it back
        inc @
?fs     tay                          ; the run's WHOLE texels, as 2w: in Y up to
                                     ;   pc_wsel (nothing below touches Y)
                                      ; 2026-09-21: pc_yacc is kept BIASED BY +255.
        lda #$FF                     ; yacc = spa.FF, Q8, biased: the high byte
        sta pc_yacc                  ;   is the ceiling
        sta pc_y16                   ; ... and the compare cell's low byte: y.FF
        ; ---- the PT_MAXRUN budget (2026-09-28): the tail fires on the 129th
        ; REAL run, and ?lap does ALL the counting -- the anchor only leaves
        ; its slot (X, never 0) for the first lap to count from.
        stx pc_a0
        ; 2026-09-27: the rows run BIASED by kh = 255-spb (yacc, pc_y, pc_y16 all
        ; carry +kh<<8), so yn > spb is exactly the carry out of the yacc add:
        ; the per-run `cmp #(spb+1)<<8 / bcs` went (5 cycles x ~5,300 runs a
        ; frame). y <= spb always, so y+kh <= 255 never wraps; the row tables
        ; are read through bases moved down by kh (patched here).
        lda rs_spb
        eor #$FF                     ; kh = 255 - spb
        clc
        adc rs_spa                   ; spa + kh <= 255 (spa <= spb: draw_twall_clip)
        sta pc_yacc+1
        sta pc_y
        rep #$21
        .LONGA ON
        lda rs_spb                   ; 2026-09-28: a run is painted UP from its last
        and #$00FF                   ;   row yn-1, and the tables are read at yn:
        adc #row_hi-$101             ;   row_hi-1-1-kh = row_hi-257+spb (no carry out)
        sta.l B1CODE_BASE+?rhi+1
        adc #row_lo-row_hi+1         ; row_lo-1-kh
        sta.l B1CODE_BASE+?rlo+1
        tya                          ; the anchor run's 2w -> the multiply (8-bit
                                     ;   Y: the high byte comes 0). w = 0
                                     ;   (only a part texel left in the anchor
        beq ?next                    ;   run: pc_f) paints nothing: on to the next
        bra pc_wsel                  ;   run. C = 0: the word path adds it in
        .LONGA OFF
        ; ---- paint: one span per run, until spb -----------------------------
        ; 2026-09-25 -- THE LOOP RUNS 16-BIT (M = 0) end to end; only the
        ; colour lookup and the row tables drop to 8 bits. A run is two 16-bit
        ; bus stores (HEIGHT+AND, DST).
        ; 2026-09-28 -- 15 CHIP CYCLES A RUN (16 before; rapidus-bus-timing,
        ; _probe_phase): DST round to the next HEIGHT is 88 fast cycles = 8
        ; (96 = 9), HEIGHT to DST 31 = 3 (28 = 3). What paid for it:
        ;   * the links paint BOTTOM-UP (the slots' DST_STEPY is -160), so DST
        ;     is the row yn-1 and ONE `ldy pc_yacc+1` is both the table index
        ;     and the next run's pc_y -- the `ldy pc_y` went (-3), and the
        ;     pc_y update sits in the short stretch, where it is free;
        ;   * X runs PT_XB..254 and its wrap to 0 is the 33rd slot: inx/inx/
        ;     beq, no cpx (-2). A shorter column ends on its first PAD, which
        ;     the word path turns into a carry (see pc_in).
        ; Both stretches are full: +1 cycle in either costs 11.
        ; The rare exits sit above the loop, in branch reach:
?adv    lda pc_yacc+1                ; a transparent run (midtex.asm): advance y,
        sta pc_y                     ;   draw nothing, what is behind stays
        rep #$21
        .LONGA ON
        bra ?next
        .LONGA OFF
?clamp  cpy #0                       ; C = 1 out (cpy #0 never borrows). Y = 2w on
        beq ?padlap                  ;   the word path: 0 is a PAD, the column's
                                     ;   runs are spent, not its rows (pc_paint_mem
                                     ;   brings Y = 1)
        sep #$20                     ; yn > spb, or yacc past row 255: this run
        .LONGA OFF                   ;   ENDS the column.
?ccol   lda.l $000001,x              ;   The run's PLAYPAL index (patched
        beq ?cend                    ;   above): transparent -> nothing to paint
        tay
        lda [zp_cm],y                ; its shade through the sector's colormap
                                      ;   row (lights.asm) -- pt_span takes it in B
        xba                          ;   (2026-09-22; the 8-bit code below keeps B)
        lda #$FF                     ; paint y..spb and RETURN: rows-1 = spb-y
        sbc pc_y                     ;   = 255 - (y+kh) (2026-09-27 bias; C = 1,
        tay                          ;   and y <= spb: no borrow)
                                      ; jsr X / rts -> jmp X: pt_span hands back X =
        lda rs_spb                   ;   the column (= pc_x) itself, so no ldx here.
        jmp pt_span                  ;   Its row is the LAST one (2026-09-28)
?cend   ldx zp_col
        rts
        .LONGA ON
?padlap inc pc_yacc                  ; the pad's dy-1 = -1 went into yacc: put it
?lapj   jmp ?lap                     ;   back (16-bit), then the lap
        ; ---- the loop proper: 16-bit M, C = 0 on every way to pc_wsel -------
?next   inx
        inx
        beq ?lapj                    ; the 33rd slot: a full column's lap
?rlen2  lda.l $000000,x              ; A = colour<<8 | 2w -- ONE 16-bit read
pc_wsel tay                          ; Y = 2w. THESE TWO BYTES ARE PATCHED by the
                                     ;   bake: `tay` + m1w's own opcode ($B9) on
                                     ;   the word path (rpt_hi = 0, rpt_lo != 0),
                                     ;   `bra pc_wide` otherwise. Assembled = the
                                     ;   word form; the rpt=0 memo hit that could
                                     ;   meet it (setup_chains' ptm_last = 0) ends
                                     ;   the column on its first run (dy-1 = -1)
m1w     lda SQ1W,y                   ; f(rpt+w)         (operand = SQ1W + 2 rpt)
m1n     adc NSQ2W+510,y              ; + ~f(|w-rpt|) = dy - 1, and C = 1: f(rpt+w)
                                     ;   > f(|w-rpt|) strictly for w, rpt >= 1
                                     ;   (operand = NSQ2W + 510 - 2 rpt). w = 0,
                                     ;   a pad: -1 and C = 0
?acc    adc pc_yacc                  ; yacc += dy (the word path's +1 rides in on
        sta pc_yacc                  ;   C; pc_paint_mem arrives with C = 0 and dy
        bcs ?clamp                   ;   exact). Carry = yn > spb (the kh bias)
        sbc pc_y16                   ; yacc - (y<<8|$FF) - 1 = (yn-y-1)<<8 | frac:
        bcc ?next                    ;   a borrow is yn == y, no row (yacc never
                                     ;   goes DOWN: dy >= 0), on to the next run
        .LONGA OFF
        sep #$20                     ; A = frac (dead), B = HEIGHT-1 already parked
?rcol   lda.l $000001,x              ; the run's PLAYPAL index (patched above).
        beq ?adv                     ;   0 = "no patch covered this texel", the
                                     ;   see-through half of a two-sided middle
                                     ;   texture (midtex.asm)
        tay
        lda [zp_cm],y                ; through the sector's colormap row -- which
                                     ;   is the thing a blitted wall cannot do ...
        xba                          ; A = height-1, B = colour
        rep #$21
        .LONGA ON
        ldy #BCB_HEIGHT-BCB_DST_ADDR ; zp_pt -> the slot's DST field (ptc_open)
        sta [zp_pt],y                ; [14] = HEIGHT, [15] = AND (the colour)
        ldy pc_yacc+1                ; yn: the run's rows end at yn-1, the next
        sty pc_y                     ;   run's start at yn
?rhi    lda row_hi-2,y               ; DST = (yn-1)*160 + col: row_hi[yn-1] into B
        .LONGA OFF                   ;   by a 16-bit read (its low byte is replaced
        sep #$20                     ;   below)
?rlo    lda row_lo-1,y               ; A = row_lo[yn-1] (both bases moved down by
                                     ;   kh per column)
        rep #$21
        .LONGA ON
pcolw   adc #0                       ; + the column, PATCHED per column (process_seg mskr)
        sta [zp_pt]                  ; DST: zp_pt points at it
        lda zp_pt                    ; slot += 21 -- no clc: the DST sum above is
        adc #BCB_SIZE                ;   row*160+col < $8000 (row_hi <= $7C), so
        sta zp_pt                    ;   its add cannot carry out
pc_cend cmp #BCB_SIZE*TW_MAXLINKS+BCB_DST_ADDR  ; the END slot's DST field; the
        bne ?next                    ;   high byte is ptc_open's patch (tw_chn + 3)
        sep #$20                     ; buffer full: falls out of the loop (a taken
        .LONGA OFF                   ;   bne on the common path, not beq + bra)
        jsr ptc_fire
        rep #$21
        .LONGA ON
        bra ?next
        .LONGA OFF
pc_paint_mem                         ; from pt_dy: dy in pc_dy (3 B), 8-bit M
        ldy #1                       ; (not a pad, should this run clamp)
        sec                          ; ?clamp's subtract relies on C = 1
        lda pc_dy+2                  ; a run 256+ rows tall cannot end inside a
        bne ?clamp                   ;   200-row span, so it ends it
        rep #$21
        .LONGA ON
        lda pc_dy
        bra ?acc
        .LONGA OFF
?wpad   jmp ?lap                     ; (pc_wide's pad, out of line)
pc_wide                              ; A = 2w in the low byte (16-bit M, B junk):
        .LONGA ON                    ;   rpt_hi != 0, or rpt = 0 -- the byte tables
        sep #$20                     ;   for the rpt_lo product, pt_dy for the rest
        .LONGA OFF
        lsr @                        ; w (2w is even: C = 0 out)
        beq ?wpad                    ; 2026-09-28: w = 0 is a PAD -- the column's
                                     ;   runs are spent (pt_dy would hand it the
                                     ;   anchor's part texel, pc_f)
        tay
        sec
m1a     lda SQ1L,y                   ; dy_lo = w * rpt_lo via SQ1L/SQ1H/SQ2L/SQ2H
m1b     sbc SQ2L+$FF,y               ;   (the operands are the bake's; the +$FF
        xba                          ;   operands ARE the rpt=0 bake ptm_last
m1c     lda SQ1H,y                   ;   starts at, see setup_chains)
m1d     sbc SQ2H+$FF,y
        xba                          ; A = dy lo, B = dy hi
        sta pc_dy                    ; the rpt_lo product to memory: pt_dy adds
        xba                          ;   the two rpt_hi products (Y = w still)
        sta pc_dy+1                  ;   and comes back through pc_paint_mem above
        jmp pt_dy
    .if [paint_col.pc_wide-paint_col.pc_wsel-2] > 127
        ert 'pc_wide is out of the reach of the bra the bake patches into pc_wsel'
    .endif
    .if paint_col.pc_wsel+1 <> paint_col.m1w
        ert 'the bake patches pc_wsel as `tay` + m1w opcode: m1w must follow pc_wsel directly'
    .endif
        ; ---- a lap ended: X = 0 (the wrap) or a pad's slot. The PT_MAXRUN
        ; budget is settled HERE, per lap (2026-09-14), all of it since
        ; 2026-09-28: pc_g = the runs the column may still paint once the lap
        ; that starts now is over; pc_a0 != 0 marks the first lap.
?lap    sep #$20
        .LONGA OFF
        txa                          ; n, the column's real runs, is WHERE THE LAP
        beq ?l32                     ;   ENDED: the first pad's slot, or 32 on the
        sec                          ;   wrap. (Not the pad's colour byte: texruns.py
        sbc #PT_XB                   ;   pads with the last run's colour, and the
        lsr @                        ;   2n the 2026-09-25 loop read there was never
        bra ?ln                      ;   shipped -- short textures did not tile.)
?l32    lda #TEX_RUNK
?ln     sta pc_n
        lda pc_a0
        beq ?l2
        stz pc_a0                    ; the first lap painted slots k0..n-1:
        sec
        sbc #PT_XB                   ; 2*k0
        lsr @                        ; k0, C = 0
        adc #PT_MAXRUN               ; PT_MAXRUN - (n - k0) are left (>= 96)
        sec
        sbc pc_n
        bra ?l3
?l2     lda pc_g
?l3     beq ?tail                    ; none: the tail, from where X stands
        cmp pc_n
        bcc ?lastlap
        sbc pc_n                     ; a whole lap fits (C = 1)
        sta pc_g
        ldx #PT_XB
?lapgo  rep #$21                     ; C = 0 for the word path
        .LONGA ON
        jmp ?rlen2
        .LONGA OFF
?lastlap                             ; A = m, 1..n-1 runs and then the tail: the
        stz pc_g                     ;   readers move so that X wraps after the
        asl @                        ;   m-th (rare: a column past 96 runs a lap)
        pha
        clc                          ; m_prod(24) = the column's address + 2m -
        adc.l B1CODE_BASE+?rlen+1    ;   2*TEX_RUNK. The address is ?rlen's operand
        sta m_prod                   ;   (pc_in; lower by PT_XB already)
        lda.l B1CODE_BASE+?rlen+2
        adc #0
        sta m_prod+1
        lda.l B1CODE_BASE+?rlen+3
        adc #0
        sta m_prod+2
        sec
        lda m_prod
        sbc #2*TEX_RUNK
        sta m_prod
        lda m_prod+1
        sbc #0
        sta m_prod+1
        lda m_prod+2
        sbc #0
        sta.l B1CODE_BASE+?rlen2+3
        sta.l B1CODE_BASE+?rcol+3
        sta.l B1CODE_BASE+?ccol+3
        lda #$FF                     ; ... and the bank memo forgets: the next
        sta.l B1CODE_BASE+pc_bk+1    ;   column patches all five again
        rep #$20
        .LONGA ON
        lda m_prod
        sta.l B1CODE_BASE+?rlen2+1
        inc @                        ; (even: no carry into the bank)
        sta.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?ccol+1
        .LONGA OFF
        sep #$20
        pla                          ; X = 256 - 2m
        eor #$FF
        inc @
        tax
        bra ?lapgo
        ; --- ?tail: fires only when a column crosses PT_MAXRUN real runs, i.e.
?tail   lda rs_mpass                 ; the flat tail fill is a MINIFICATION
        bne ?tend                    ;   fallback -- on a masked column it would
                                     ;   paint the gaps shut, so a far strut
                                     ;   simply stops instead (midtex.asm)
        rep #$20
        .LONGA ON
        lda.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?tcol+1
        sep #$20
        .LONGA OFF
        lda.l B1CODE_BASE+?rcol+3
        sta.l B1CODE_BASE+?tcol+3
        dex                          ; the run BEFORE the 129th: X = 0 or a pad's
        dex                          ;   slot came in, so X-2 is a run (2026-09-28)
?tcol   lda.l $000001,x
        tay
        lda [zp_cm],y
        xba                          ; colour -> B for pt_span (2026-09-22)
        sec                          ; rows-1 = spb - y = 255 - (y+kh) (2026-09-27
        lda #$FF                     ;   bias, as ?ccol)
        sbc pc_y
        tay
                                      ; jsr X / rts -> jmp X (as ?ccol, no ldx)
        lda rs_spb                   ; the span's LAST row (2026-09-28)
        jmp pt_span
?tend   ldx zp_col
        rts
        ; 2026-09-28: the bake's rare half, out of line: rpt >> 5 moved since
        ; the last bake. A = the bits that did (16-bit)
        .LONGA ON
?chg    cmp #$0100
        bcc ?dimnew                  ; rpt_hi is as it was: the light alone
        .LONGA OFF
        sep #$20
        lda rs_rpt+1                 ; rpt_hi -> pt_dy's operands
        sta.l B1CODE_BASE+pt_dy.m2a+1
        sta.l B1CODE_BASE+pt_dy.m2c+1
        sta.l B1CODE_BASE+pt_dy.m3a+1
        sta.l B1CODE_BASE+pt_dy.m3c+1
        eor #$FF
        sta.l B1CODE_BASE+pt_dy.m2b+1
        sta.l B1CODE_BASE+pt_dy.m2d+1
        sta.l B1CODE_BASE+pt_dy.m3b+1
        sta.l B1CODE_BASE+pt_dy.m3d+1
        rep #$20
        .LONGA ON
?dimnew lda rs_rpt                   ; DOOM's scalelight: the scale takes min(rw_scale
        cmp #24<<5                   ;   >> 12, 47)/2 rows off a wall, rs_rpt being
        bcc ?dim1                    ;   rw_scale >> 8
        lda #23<<5
?dim1   lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        sta pc_dim
        clc
        adc rs_wlit                  ; (a word: its high byte is 0)
        tay
        .LONGA OFF
        sep #$20
        lda LT_ROW,y                 ; the wall's colormap row at this scale
        sta zp_cm+1
        rep #$20
        .LONGA ON
        bra ?hiok
        .LONGA OFF
bake                                 ; --- the bake (rs_rpt changed), out of line:
                                     ;   pc_bkj brings the memo test's bne here
        stz pc_dy+2                  ; --- pt_dy's third byte
        rep #$20                     ; 2026-09-28: ONE test for rpt_hi (pt_dy's
        .LONGA ON                    ;   operands) and rpt >> 5 (the light's rows):
        lda rs_rpt                   ;   the memo is still the OLD rpt here
        eor ptm_last
        and #$FFE0
        bne ?chg
?hiok   lda rs_rpt                   ; the WORD tables' operands (see ?acc) and the
                                     ;   routing of pc_wsel
        sta ptm_last                 ; the memo, now that its old value is read
        and #$00FF
        asl @                        ; 2 rpt_lo (< 512: the asl cannot carry out)
        sta qs_p                     ; (scratch: no quarter-square product is live)
        adc #SQ1W                    ; C = 0 from the asl
        sta.l B1CODE_BASE+paint_col.m1w+1
        lda #NSQ2W+510
        sec
        sbc qs_p
        sta.l B1CODE_BASE+paint_col.m1n+1
        ldy rs_rpt+1                 ; the word path needs rpt_hi = 0 AND rpt_lo
        bne ?pm_wd                   ;   != 0 (rpt = 0: dy is 0 and the carry trick
        ldy rs_rpt                   ;   wants f(rpt+w) > f(|w-rpt|) -- the byte
        beq ?pm_wd                   ;   path through pc_wide computes 0 exactly)
        lda #$B9A8                   ; `tay` ($A8) + m1w's opcode ($B9, lda abs,y)
        bra ?pm_w
?pm_wd  .LONGA OFF                   ; the BYTE path: it alone reads m1a-m1d, so
        sep #$20                     ;   their rpt_lo bake lives here (2026-09-25)
        lda rs_rpt
        sta.l B1CODE_BASE+paint_col.m1a+1
        sta.l B1CODE_BASE+paint_col.m1c+1
        eor #$FF                     ; 255 - b, for the mirrored table
        sta.l B1CODE_BASE+paint_col.m1b+1
        sta.l B1CODE_BASE+paint_col.m1d+1
        rep #$20
        .LONGA ON
        lda #$80|[[paint_col.pc_wide-paint_col.pc_wsel-2]<<8]  ; `bra pc_wide`
?pm_w   sta.l B1CODE_BASE+paint_col.pc_wsel
                                     ; (stays 16-bit: recip_norm's entry below is
                                     ;   16-bit anyway -- no empty sep/rep pair)
        lda rs_rpt
                                      ; 2026-09-23: rpt straight into recip_norm's 16-bit
        beq ?pr_sat16                ;   entry; the shift count in Y, INV_TAB's word
        RECIP_NORM                   ; (inlined 2026-09-26)   built in A:B and shifted there -- no m_prod
        .LONGA OFF                   ; (recip_norm RETURNS 8-bit)
        clc                          ;   round trip, rs_tpr stored once
        lda #RECIP_INV_K-16
        adc rc_e                     ; rc_e is signed
        bmi ?pr_sat                  ; shift < 0 -> tpr >= 65536
        cmp #8
        bcs ?pr_ge8
        tay                          ; Y = shift 0..7
        lda.l RCX_INV_HI,x           ; INV_TAB[m] = round(2^23/m), bank $01
        xba
        lda.l RCX_INV_LO,x
        rep #$20
        .LONGA ON
?pr_sh  cpy #0
        beq ?pr_st
?pr_b   lsr @
        dey
        bne ?pr_b
?pr_st  sta rs_tpr
        .LONGA OFF
        sep #$20
        jmp ?baked
?pr_ge8 sbc #8                       ; C = 1 (bcs): Y = shift - 8, and the word >> 8
        tay                          ;   is INV_TAB's high byte alone
        lda.l RCX_INV_HI,x
        rep #$20
        .LONGA ON
        and #$00FF
        bra ?pr_sh
?pr_sat16
        sep #$20                     ; rpt = 0 (from the 16-bit test above)
        .LONGA OFF
?pr_sat lda #$FF                     ; the saturation tw_setup's ?tprmax used
        sta rs_tpr
        sta rs_tpr+1
                                     ;   memo (2026-08-27): tpr is rpt's exact ...
        jmp ?baked
.endp
        .endseg

    .if * > SGBSP_BASE
        ert 'paint.asm ran into sg_bsp at $0BFC -- the $0900 block ends there (cm_sscl left, memo+inline took its hole)'
    .endif
        org paint_resume
