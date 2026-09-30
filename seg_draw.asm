;--------------------------------------------------------------
; seg_draw.asm -- part of renderer.asm (icl in place): draws ONE seg --
;   load_vertex, plane_setup, draw_span, draw_clip, process_seg.
;--------------------------------------------------------------
; load_vertex -- zp_vidx -> zp_rx,zp_ry = vertex - player.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_vertex
        ; ONE 16-bit accumulator, whole proc (2026-08-31, _an_drac030): the old ...
        rep #$20
        .LONGA ON
        lda zp_vidx
        asl @
        asl @                        ; vertex index * 4 (4-byte records): the
        adc #MAP_VERTS               ;   index is < 16384 (the record must fit the
                                     ;   bank), so the shifts carry 0 -- no clc
                                     ;   (2026-09-15). MAP_VERTS = offset $0100
        sta zp_vptr                  ;   zp_vptr+2 = MAP_EXT_BANK, set once by
                                     ;   init_level (nothing else writes it)
        sec
        lda [zp_vptr]
        sbc zp_px
        sta zp_rx
        ldy #2
        sec
        lda [zp_vptr],y
        sbc zp_py
        sta zp_ry
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; vsh_mod / vsh_neg -- DOOM texture pegging, reduced to a texel shift.
;   IN : A = texture height (1..255), m_a = distance in world units (>= 0, 16b)
;   OUT: A = m_a mod texH   (vsh_mod)  /  (-m_a) mod texH  (vsh_neg)
;--------------------------------------------------------------
vsh_resume = *
        org VSH_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vsh_neg
        sta rs_vsht                  ; keep texH
        jsr vsh_mod
                                      ; A = 0 on beq (vsh_mod's last lda set Z): no
        beq ?zero                    ;   reload. texH - A in A: ~A + texH + 1, no
        eor #$FF                     ;   m_b temp (the callers only store A)
        sec
        adc rs_vsht
?zero   rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vsh_mod
        rep #$20                     ; m_b = texH << 7 (fits: 255<<7 = 32640) --
        .LONGA ON                    ;   in the accumulator, not the old ldx #7
        and #$FF                     ;   loop of asl/rol ON m_b (~98 cycles of
	xba
	lsr
	sta m_b
	lda m_a

	ldx #8
?l	cmp m_b
	bcc ?next
	sbc m_b
?next	lsr m_b
	dex
	bne ?l

	sta m_a
	sep #$20
	.LONGA OFF
        lda m_a+1                    ; only reachable if world > texH*256 (no real
        bne ?giveup                  ;   geometry does that) -- a truncated hi byte
        lda m_a                      ;   would NOT be congruent, so shift by nothing
        rts
?giveup lda #0
        rts
.endp
        .endseg
vsh_end = *
        .if vsh_end > VSH_LIMIT
                ert 'vsh_mod/vsh_neg overrun the $267F hole -- they would clobber the engine code at $2700'
        .endif
        org vsh_resume

;--------------------------------------------------------------
; seg_yoff -- DOOM's sidedef->rowoffset for this seg (r_segs.c:474/603/604 add it
;   to every texturemid). The port's anchor is a whole-texel shift, so the
;   rowoffset just adds into rs_vshw / rs_vshl and is folded back mod texH.
;   IN : rs_segi (seg index), rs_vshw/rs_vshl + rs_wtexid/rs_ltexid + the heights
;   OUT: rs_vshw/rs_vshl updated for the slots that have a texture
;--------------------------------------------------------------
    .if MAP_NSEGS > 4096
        ert 'MAP_NSEGS > 4096: MAP_YBITS spans >2 pages (seg_yoff page split)'
    .endif
    .if MAP_NYOFF > 128
        ert 'MAP_NYOFF > 128: the dey/bpl scan below cannot index the yoff table'
    .endif
segy_resume = *
        org SEGYOFF_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc seg_yoff
        rep #$20                     ; m_a = segi >> 3 -> byte index into
        .LONGA ON                    ;   MAP_YBITS. The old form copied segi to
        lda rs_segi                  ;   m_a in halves and shifted it IN MEMORY
        lsr @                        ;   three times (ldx #3 / lsr / ror / dex /
        lsr @                        ;   bne = ~45 cycles); the accumulator does
        lsr @                        ;   it in 6, bit-identically, and m_a/m_a+1
        sta m_a                      ;   hold the same two bytes for the page
        .LONGA OFF                   ;   test below (_an_drac030, 2026-08-31)
        sep #$20
        ldy m_a
        lda rs_segi                  ; bit (segi & 7) of that byte, through a mask
        and #7                       ;   table instead of a b+1-step lsr loop
        tax                          ;   (2026-09-15: ~25 cycles a seg)
        lda m_a+1                    ; MAP_YBITS outgrew one page with the E2/E3
        beq ?pg0                     ;   seg cap (2438 -> 305 B): page-split
        lda MAP_YBITS+256,y
	bra ?bit
?pg0    lda MAP_YBITS,y
?bit    and mv_bit,x                 ; (movers.asm: 1,2,4,..,128)
        bne ?have
        rts                          ; no rowoffset on this seg -- the common case
?have
        ldy MAP_HNYOFF               ; find the entry (this LEVEL's count -- the table
        beq ?nope                    ;   is padded to the build's cap, and the padding
        dey                          ;   is zeroes, which would match seg 0)
?scan   lda MAP_YIDXLO,y             ; the scan only runs for the segs the bitmap flagged
        cmp rs_segi
        bne ?nx
        lda MAP_YIDXHI,y
        cmp rs_segi+1
        beq ?found
?nx     dey
        bpl ?scan
?nope   rts                          ; bitmap and table disagree -> leave the peg

?found  lda MAP_YVAL,y
        sta rs_yoffv
        lda rs_wtexid                ; wall / upper slot ($FF = untextured, or 'T'
        cmp #$FF                     ;   flat mode -- rs_vshw is then unused)
        beq ?low
        lda rs_vshw
        ldy rs_wtexh
        jsr ?shift                   ; (vshw + rowoffset) mod texH
        sta rs_vshw
?low    lda rs_ltexid                ; lower step (solid segs park $FF here)
        cmp #$FF
        beq ?done
        lda rs_vshl
        ldy rs_ltexh
        jsr ?shift
        sta rs_vshl
?done   rts
?shift  clc                          ; A = (A + rowoffset) mod Y, via the peg helper
        adc rs_yoffv
        sta m_a
        lda #0
        adc #0
        sta m_a+1
        tya
        jmp vsh_mod
.endp
        .endseg
segy_end = *
        .if segy_end > SEGYOFF_END
                ert 'seg_yoff overran its under-ROM slot (see memory_map.inc)'
        .endif
        org segy_resume

;--------------------------------------------------------------
; u_guard -- rs_utL/rs_utR = rs_scL/rs_scR, each halved (together) until
;   max(scale) * span < 2^24. Once per SEG, before the u-track init.
;   Clobbers A/X, m_a, m_b, m_prod (m_prod is dead here: the caller's
;--------------------------------------------------------------
ug_resume = *
        org UGUARD_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc u_guard
	rep #$20
	.LONGA ON
ug_w16                               ; (2026-09-22: 16-bit callers enter here)
        lda rs_scR                   ; start from the real scales -- scL last,
        sta rs_utR                   ;   so A holds it for the compare
        lda rs_scL                   ;   (2026-09-15: one reload fewer)
        sta rs_utL
	cmp rs_scR
	bcc ?r_is_max
	sta m_b
	bra ?havesc
?r_is_max
	lda rs_scR
	sta m_b
?havesc
	lda rs_span		;rs_span = rs_sxR - rs_sxL
	sta m_a
	sep #$20
	.LONGA OFF
        jsr umul16                   ; m_prod(32) = max_scale * span

?sh     lda m_prod+3                 ; top byte set -> >= 2^24: halve and retry
        beq ?done
	rep #$20
	.LONGA ON
	lsr m_prod+2
	ror m_prod
        lsr rs_utR
        lsr rs_utL
	sep #$20
	.LONGA OFF
	bra ?sh
?done   rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_ncut -- THE CLIP THE SPRITE SNAPSHOT CANNOT SEE (r_things.c R_DrawSprite).
;   C=1 if screen column sp_col is now closed by geometry NEARER than sp_scale,
;   i.e. the sprite must not be drawn there. Clobbers A/X.
;--------------------------------------------------------------
    .if * > UGUARD_END+1
        ert 'u_guard outgrew UGUARD_BASE..END (memory_map.inc)'
    .endif

        org SEGSCL_BASE
; (seg_scl -- rs_sscl = min(scL, scR) -- is gone: sscl_col below gives the
;  sprite clip the wall's scale AT each column, 2026-09-30)

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_ncut
        ldx sp_col
        lda solid_arr,x
        beq ?open                    ; still open -> only the snapshot applies
        lda.l SSCL_LO,x              ; the scale of whatever closed this column
        cmp sp_scale
        lda.l SSCL_HI,x
        sbc sp_scale+1
        bcc ?open                    ; that wall is FARTHER -> the sprite covers it
        lda #255                     ; nearer -> the same "no window" the snapshot
        sta sp_t                     ;   writes, so spr_one's own test skips it
?open   rts
.endp

;--------------------------------------------------------------
; sscl_col (2026-09-30) -- a column this seg CLOSES: the wall's scale AT it
;   into SSCL and cm_nt/cm_nb (the defer copy). One scale for the whole wall
;   let a sprite behind an oblique wall through (E1M1 2063,-2658: armor bonus).
;   Scale is linear in screen x: a Q8 track, +step on the next column, else
;   anchored (sscl_anc). IN/OUT: 8-bit M, X = the column. Keeps X/Y.
;   Written 2026-09-30 by these rules (.claude/skills/<name>/SKILL.md):
;   - 65816-windows: "24-bit add/subtract: low word 16-bit, sep, top byte
;     8-bit" -- the track step below; one rep #$21 absorbs the clc.
;   - 65816-idioms: "txa / inc @" (C untouched) for the next column, not
;     inx / stx / dex; A is dead at all three callers.
;   - 6502-cycles-layout: "rare case out of line" -- the anchor (first close
;     of a seg, or a gap) is sscl_anc, the next column falls through.
;   - fable-skill-atari 1: the step is worked out only for a seg that
;     reaches a close (rs_sscx = $FF until then), not for every seg.
;   - rapidus-bus-timing: every cell here is fast RAM (D0 below $4000,
;     SSCL in bank $01): no chip-bus access added to the column loop.
;   Measured (_bench_frame.py --at 2063,-2658,8): +4,300 cycles a frame.
;--------------------------------------------------------------
.proc sscl_col
        cpx rs_sscx                  ; the column after the one closed last?
        bne ?anc
        rep #$21                     ; acc += step, 24 bits: the word, then the
        .LONGA ON                    ;   top byte with the sign byte and the carry
        lda rs_sscl
        adc rs_sstep
        sta rs_sscl
        .LONGA OFF
        sep #$20
        lda rs_sscl+2
        adc rs_ssgn
        sta rs_sscl+2
?st     sta.l SSCL_HI,x              ; the scale = bytes 1-2 of the Q8 track
        sta cm_nb
        lda rs_sscl+1
        sta.l SSCL_LO,x
        sta cm_nt
        txa
        inc @
        sta rs_sscx                  ; the next column continues the track
        rts
?anc    jsr sscl_anc
        bra ?st
.endp

;--------------------------------------------------------------
; sscl_anc -- rs_sscl = scale(X) * 256 = base*256 + (X-sxL)*step. The seg's
;   first call (rs_sscx = $FF) works the step out: (scR-scL)*256/span through
;   step_recip; a saturated one means step 0 on max(scL,scR) -- the wall wins.
;   IN: 8-bit M, X = the column. OUT: A = rs_sscl+2. Keeps X/Y.
;   2026-09-30 rules (.claude/skills/<name>/SKILL.md):
;   - 65816-idioms: "phx / phy" for the saved registers and "lda n,s" to
;     read the column back -- no RAM temp; "stz" for the zero word.
;   - 65816-windows: every word step in one rep/sep block, the byte input
;     widened with "and #$00FF"; "rep #$21" instead of rep + clc.
;   - 6502-idioms: flags tracked -- the sign comes from cmp #$8000 (ldy #0
;     would clear N), the C of rep #$21 feeds the add, no extra clc/sec.
;--------------------------------------------------------------
.proc sscl_anc
        phx
        phy
        lda rs_sscx
        inc @
        bne ?have                    ; not $FF: this seg's step is known
        rep #$20
        .LONGA ON
        stz m_a                      ; m_a:m_b = D << 8, 24 bits (D = scR-scL):
        sec                          ;   m_a lo 0, m_a hi D lo, m_b lo = the top
        lda rs_scR                   ;   byte (step_recip's A)
        sbc rs_scL
        sta m_a+1
        .LONGA OFF
        sep #$20
        lda m_b                      ; (N/Z for step_recip)
        jsr step_recip               ; 16-bit out: A = D*256/span, m_a = |A|
        .LONGA ON
        sta rs_sstep
        ldy #0                       ; the sign byte: $FF for a falling step
        cmp #$8000
        bcc ?sp
        dey
?sp     sty rs_ssgn
        lda m_a
        cmp #$7FFF
        lda rs_scL
        bcc ?base                    ; not saturated: the track starts on scL
        stz rs_sstep                 ; saturated: a flat track on the NEARER end
        ldy #0
        sty rs_ssgn
        cmp rs_scR
        bcs ?base
        lda rs_scR
?base   sta rs_ssbs
        .LONGA OFF
        sep #$20
?have   lda 2,s                      ; the column (pushed above)
        rep #$20
        .LONGA ON
        and #$00FF
        sec
        sbc rs_sxL                   ; d = x - sxL >= 0 (x >= xa >= sxL)
        sta m_a
        lda rs_sstep
        bpl ?ms
        eor #$FFFF
        inc @
?ms     sta m_b
        .LONGA OFF
        sep #$20
        jsr umul16                   ; m_prod = d * |step|: < 2^23, the track stays
        lda rs_ssgn                  ;   between scL and scR
        rep #$21
        .LONGA ON
        bpl ?add
        sec                          ; a falling step: base*256 - the product,
        lda #0                       ;   the product negated as 32 bits first
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+2
        sta m_prod+2
        clc
?add    lda m_prod
        sta rs_sscl                  ; byte 0 (byte 1 is rewritten below)
        lda m_prod+1
        adc rs_ssbs                  ; bytes 1-2: base + the product's
        sta rs_sscl+1
        .LONGA OFF
        sep #$20
        ply
        plx
        lda rs_sscl+2
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

        org ug_resume

;--------------------------------------------------------------
; plane_setup -- compute one height plane's per-column track.
;   IN : rs_wtmp (world height, signed16); rs_scL/scR, rs_span, zp_xa, rs_sxL.
;   OUT: rs_Stmp (step, signed16), rs_acctmp (accumulator at column xa, 24b).
;   track = 12800 - world*scale;  step = (R-L)/span;  acc = L + (xa-sxL)*step.
;--------------------------------------------------------------
; 16-BIT (2026-08-29): the arguments are 16-bit and the results 24-bit, so a
; copy is two OVERLAPPING 16-bit moves (bytes 0-1, then 1-2) and the 24-bit
; subtract is one 16-bit sbc plus its top byte. track_calc/step_recip are
; 8-bit code; M only, X/Y stay 8 (sound.asm:316).
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc plane_setup
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        lda rs_wtmp                  ; L = trk(world, scL) -> rs_Ltmp
plane_setup16                        ; ENTRY (2026-09-15): 16-bit A = rs_wtmp
        ; 2026-09-29: unsigned products |w| * sc, the sign of w picks subtract
        ; or add. Relies on 0 < sc < $8000 (scale_z with Z >= ZNEAR) and on
        ; byte 3 of rs_Ltmp / rs_acctmp being unread.
        cmp #$8000
        bcs ?wneg
        sta m_a                      ; ---- w >= 0: track = HHFP - w*sc
        lda rs_scL
        sta m_b
        jsr umul16w
        .LONGA ON
        sec
        lda #HHFP
        sbc m_prod
        sta rs_Ltmp
        lda #0
        sbc m_prod+2
        sta rs_Ltmp+2
        lda rs_scR                   ; (m_a is w still: umul16w only reads it)
        sta m_b
        jsr umul16w
        .LONGA ON
        sec                          ; keep R: it is the RIGHT-hand anchor below,
        lda #HHFP                    ;   and rs_acctmp is free until we write the
        sbc m_prod                   ;   answer into it
        sta rs_acctmp
        lda #0
        sbc m_prod+2
        bra ?haveR
?wneg   eor #$FFFF                   ; ---- w < 0: track = HHFP + |w|*sc
        inc @
        sta m_a
        lda rs_scL
        sta m_b
        jsr umul16w
        .LONGA ON
        clc
        lda #HHFP
        adc m_prod
        sta rs_Ltmp
        lda #0
        adc m_prod+2
        sta rs_Ltmp+2
        lda rs_scR
        sta m_b
        jsr umul16w
        .LONGA ON
        clc
        lda #HHFP
        adc m_prod
        sta rs_acctmp
        lda #0
        adc m_prod+2
?haveR  sta rs_acctmp+2
        lda rs_acctmp
        sec                          ; step = (R - L) / span: the low word into
        sbc rs_Ltmp                  ;   m_a, the top byte in A (step_recip's IN)
        sta m_a
        .LONGA OFF
        sep #$20
        lda rs_acctmp+2
        sbc rs_Ltmp+2
        jsr step_recip               ; 16-bit out: A = the step, m_a = |step|
        .LONGA ON
        sta rs_Stmp
        ; The anchor is the nearer end: rs_pdl / rs_pdr, per seg, both >= 0
        ; (sxL <= xa <= sxR). |step| * distance, the step's sign picks add or
        ; subtract. Returns 16-bit M, A = the accumulator's top word.
        lda rs_pdl
        beq ?dl0                     ; xa = sxL (the seg's left end is on screen):
        cmp rs_pdr                   ;   acc = L outright, no product (2026-09-25)
        bcc ?fromL
        lda rs_pdr
        beq ?dr0                     ; dR = 0: no product, acc = R as rs_acctmp is
        sta m_b
        jsr umul16w
        .LONGA ON
        ldy rs_Stmp+1
        bmi ?rneg
        sec                          ; acc = R - dR*step (rs_acctmp still holds R)
        lda rs_acctmp
        sbc m_prod
        sta rs_acctmp
        lda rs_acctmp+2
        sbc m_prod+2
        sta rs_acctmp+2
        rts
?rneg   clc
        lda rs_acctmp
        adc m_prod
        sta rs_acctmp
        lda rs_acctmp+2
        adc m_prod+2
        sta rs_acctmp+2
        rts

?dl0    lda rs_pdr                   ; dL = 0: dR = 0 too -> from R with a zero
        beq ?dr0                     ;   product = R, which rs_acctmp holds; else
        lda rs_Ltmp                  ;   from L with a zero product = L
        sta rs_acctmp
        lda rs_Ltmp+2
        sta rs_acctmp+2
        rts
?dr0    lda rs_acctmp+2              ; (A = the top word on every way out)
        rts

?fromL  sta m_b                      ; --- from the LEFT: acc = L + dL*step ---
        jsr umul16w
        .LONGA ON
        ldy rs_Stmp+1
        bmi ?lneg
        clc
        lda rs_Ltmp
        adc m_prod
        sta rs_acctmp
        lda rs_Ltmp+2
        adc m_prod+2
        sta rs_acctmp+2
        rts
?lneg   sec
        lda rs_Ltmp
        sbc m_prod
        sta rs_acctmp
        lda rs_Ltmp+2
        sbc m_prod+2
        sta rs_acctmp+2
        rts
        .LONGA OFF
.endp
        .endseg

; (draw_span had no caller left since draw_clip inlined it; it went on
;  2026-09-28 with draw_clip.dc_floor, inlined in process_seg -- both would
;  have handed pt_span the span's FIRST row.)

;--------------------------------------------------------------
; draw_clip -- span with RAW signed16 endpoints rs_ra (start) / rs_rb (end),
;   clipped to the window [rs_top,rs_bot]: a=max(rs_ra,top), b=min(rs_rb,bot);
;   draws if b>=a. Mirrors render_view's col(x, max(a,top), min(b,bot)).
;   IN: X = the column = zp_col, B = the colour. Keeps X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc draw_clip
        lda rs_ra+1                  ; a = max(rs_ra, top); >bot -> nothing
        bmi ?atop
        bne ?out
        lda rs_ra
        cmp rs_top
        bcc ?atop
        cmp rs_bot
        bcc ?aset                    ; cmp does not touch A, so A IS rs_ra here:
        bne ?out                     ;   the old ?ara reloaded what it had, and
        beq ?aset                    ;   the jmp round it went away with it
?atop   lda rs_top
?aset
dc_ceil sta rs_spa                   ; CEILING entry: A = rs_top, which is a = max(ra,
                                     ;   top) already (top <= bot at every caller)
        lda rs_rb+1                  ; b = min(rs_rb, bot); <top -> nothing
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot                   ; 2026-09-27 (6502-cycles-layout): rb < bot is
        bcs ?bbot                    ;   127 of 127 a frame -- it falls through; rb >= bot
                                      ;   goes out of line (rb == bot loads the same bot)
                                      ; draw_span INLINED: no bra, and no rs_spb store
?bset   tax                          ;   (only paint_col reads rs_spb, and its own
        sec                          ;   draw_twall_clip sets it). A = b here, and b
        sbc rs_spa                   ;   is pt_span's row (2026-09-28: bottom-up) --
        bcc ?outx                    ;   in X, where pt_span wants it
        tay                          ; Y = rows-1 (pt_span's HEIGHT contract)
        jmp pt_span.px               ; tail call; pt_span gives X = the column back
?outx   ldx zp_col                   ; (an empty span: X held the row)
?out    rts
?bbot   lda rs_bot                   ; (draw_clip's rare b >= bot, out of line)
        bra ?bset
.endp
        .endseg

;--------------------------------------------------------------
; sky_clip -- draw_clip for an F_SKY1 ceiling (2026-09-16, "v original doome je
;   tam nejake pozadie"). r_plane.c R_DrawPlanes (396) paints a sky ceiling with
;   a SCREEN-FIXED texture, not a flat: column (viewangle + xtoviewangle[x]) >> 22
;   of SKY1-3 (256 wide, four tiles a turn), row skytexturemid 100 +
;   IN/OUT as draw_clip: rs_ra/rs_rb raw rows, rs_top/rs_bot the window,
;   pc_colw the column (pt_span), X = the column and preserved. Clobbers A, Y and
;--------------------------------------------------------------
SKY_TABOFF equ 3*128*64               ; pack_sky.py TAB_OFF: the offsets follow
    .if <SKY_EXT
        ert 'sky_clip patches only the page and offset of SKY_EXT -- it must start a page'
    .endif
    .if [SKY_EXT&$FFFF]+SKY_TABOFF+160 > $10000
        ert 'the sky blob must fit the bank SKY_EXT starts in'
    .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sky_clip
        lda rs_ra+1                  ; a = max(rs_ra, top), b = min(rs_rb, bot):
        bmi ?atop                    ;   draw_clip's own clip, line for line
        bne ?out
        lda rs_ra
        cmp rs_top
        bcc ?atop
        cmp rs_bot
        bcc ?aset
        bne ?out
        beq ?aset
?atop   lda rs_top
?aset
sk_ceil sta rs_spa                   ; (the ceiling entry, as draw_clip.dc_ceil)
        lda rs_rb+1
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot
        bcc ?bset
        beq ?bset
?bbot   lda rs_bot
?bset   sec                          ; rows = b - a + 1
        sbc rs_spa
        bcs ?go
?out    rts
?go     inc @
        sta m_a                      ; rows left
        lda rs_spa
        sta m_a+1                    ; the row being painted
        txa                          ; x' = 80 + ((x - 80) << vw_sh): the window
        sec                          ;   is centred on 80 and at most 160 >> vw_sh
        sbc #SCREEN_HALF             ;   wide, so the shifted offset stays inside
        ldy vw_sh                    ;   -80..79 and x' inside 0..159
        beq ?xs0
?xs     asl @
        dey
        bne ?xs
?xs0    clc                          ; LOAD-BEARING: sbc/asl leave a sign bit in C
        adc #SCREEN_HALF
        phx                          ; the caller's column: X walks the record below
        tax
        lda zp_ang                   ; stored column = (ang*2 + off[x']) & 127
        asl @
        clc                          ; (C = ang bit 7 after the asl)
        adc.l SKY_EXT+SKY_TABOFF,x
        and #$7F
        sta m_b                      ; parked for its offset byte
        lsr @
        lsr @                        ; column >> 2 = the page within its sky
        sta m_b+1
        ldx current_level            ; 0..2: + sky * $20 pages. make_atr_doom.py
        lda.l B1CODE_BASE+sky_lvl,x  ;   writes the table in ATR level order (the
                                     ;   header has no free byte: +24 is the format
                                     ;   version bsp_main checks).
        asl @
        asl @
        asl @
        asl @
        asl @                        ; C = 0: MAP_HSKY <= 2
        adc m_b+1                    ; <= $40 + $1F: no carry
        adc #>SKY_EXT                ; + SKY_EXT's page: the ert above keeps it in bank
        sta.l B1CODE_BASE+?rlen+2    ; the record's page, into both readers
        sta.l B1CODE_BASE+?rcol+2
        lda m_b
        asl @
        asl @
        asl @
        asl @
        asl @
        asl @                        ; column << 6: its offset within that page
        sta.l B1CODE_BASE+?rlen+1
        sta.l B1CODE_BASE+?rcol+1
        lda rs_spa                   ; texel = (100 + ((row - 84) << vw_sh)) & 127
        sec                          ;   (mod 256 through the shifts is all the
        sbc #VIEW_HEIGHT/2           ;   & 127 needs)
        ldy vw_sh
        beq ?ts0
?ts     asl @
        dey
        bne ?ts
?ts0    clc                          ; (C = a shifted-out bit: load-bearing)
        adc #100                     ; skytexturemid (r_sky.c)
        and #$7F
        sta m_b                      ; the texel position
        ldx #0                       ; X = 2k, run k's pair
        stz m_b+1                    ; where run k ENDS, once its length is in
?run
?rlen   lda.l SKY_EXT,x              ; SMC: the record (page/offset patched above)
        inx
        clc
        adc m_b+1
        sta m_b+1
?rcol   lda.l SKY_EXT,x              ; SMC: the same record, the colour byte
        inx
        xba                          ; -> B: pt_span takes the colour there
        lda m_b+1                    ; texels this run still has past the texel
        sec
        sbc m_b
        beq ?skip                    ; it ends AT the texel...
        bcc ?skip                    ; ...or before it
        ldy vw_sh                    ; rows = ceil(texels / (1 << vw_sh))
        beq ?r0
        clc                          ; (C = 1 out of the sbc: no borrow)
        adc wp_msk,y                 ; + step-1 (0/1/3, draw_weapon's table)
?rs     lsr @
        dey
        bne ?rs
?r0     cmp m_a                      ; no more than the rows left
        bcc ?rk
        lda m_a
?rk     sta m_prod                   ; this run's rows
                                      ; 2026-09-22: pt_span takes rows-1 in Y now
        dec @
        tay                          ; Y = rows-1
        clc                          ; 2026-09-28: A = the run's LAST row (pt_span
        adc m_a+1                    ;   paints bottom-up)
        phx                          ; X = the run index here, but pt_span hands
        jsr pt_span                  ;   back X = the COLUMN (its pcx): save ours
        plx
        lda m_a
        sec
        sbc m_prod
        beq ?done                    ; the span is full
        sta m_a
        lda m_a+1                    ; row += rows
        clc
        adc m_prod
        sta m_a+1
        lda m_prod                   ; texel += rows << vw_sh. Unclamped, so rows
        ldy vw_sh                    ;   <= ceil(texels / step) and the texel ends
        beq ?t0                      ;   below the run end + step <= 131: a byte
?tl     asl @
        dey
        bne ?tl
?t0     clc
        adc m_b
        sta m_b
?skip   cpx #2*32
        bne ?run
        lda m_b+1                    ; the record's 128 texels are spent: wrap --
        beq ?done                    ;   unless they summed to 0 (no sky loaded)
        lda m_b
        sec
        sbc #128
        sta m_b
        ldx #0
        stz m_b+1
        bra ?run
?done   plx
        rts
.endp
sky_lvl                              ; the sky per level, 0..2 (make_atr_doom.py,
        ins 'build/assets/lvl_sky.bin' ;   ATR level order = current_level)
        .endseg

;--------------------------------------------------------------
; process_seg -- one seg (zp_sptr): transform, backface, near-clip,
;   project, then height/portal render with per-column occlusion.
;--------------------------------------------------------------
        .segment D0                  ; 2026-09-28: the near clip's cut (?uclip)
rs_clipt dta a(0)                    ; 0 = the seg was not clipped; else t8 (Q8 of
                                     ;   the seg) | $8000 v1's end, $4000 v2's
; ... and DOOM's wall light (lights.asm lt_seg / LT_ROW):
rs_lcon  dta 4                       ; 4 - the seg's fake contrast in colormap rows:
                                     ;   8 a vertical line, 0 a horizontal one
rs_wlit  dta a(0)                    ; the wall's light, 4*lightnum + rs_lcon: 0..68
pc_dim   dta a(0)                    ; the rows the BAKED rs_rpt takes off, 0..23
                                     ;   (paint_col's bake)
ps_shut  dta $FF                     ; what the column loop is patched for: 0 an
                                     ;   open portal, 2 / 4 a shut one (?shp);
                                     ;   $FF = not known, render_world's
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
;--------------------------------------------------------------
; VC_LOOK x, z, hit -- IN (16-bit A): a vertex index. When this frame already
;   transformed that vertex, its X/Z go STRAIGHT into the cells x/z and the
;   code goes on at `hit`; otherwise it falls through with vc_key set for
;   vc_store. Clobbers A, X. Enters and leaves in 16-bit A. A macro since
;   2026-09-26 (was the vc_look proc, 126 calls a frame): no jsr/rts, and a
;   hit no longer lands in zp_X/zp_Z to be copied into zp_X1/zp_X2.
;--------------------------------------------------------------
.macro VC_LOOK
        .LONGA ON
        sta vc_key                   ; (vc_store's key on a miss)
        tax                          ; slot = index & $FF (8-bit X takes the low byte)
        .LONGA OFF
        sep #$20
        xba                          ; A = the index's high byte = the tag
        cmp.l VCACHE_BASE+VC_TAGH,x
        bne ?miss
        lda.l VCACHE_BASE+VC_STAMP,x ; 2026-09-26 (fable-skill-atari 4): the frame
:4      cmp #0                       ;   stamp is PATCHED into this operand once a
        bne ?miss                    ;   frame (render_frame, after inc vc_frame)
        lda.l VCACHE_BASE+VC_XL,x
        sta :1
        lda.l VCACHE_BASE+VC_XH,x
        sta :1+1
        lda.l VCACHE_BASE+VC_ZL,x
        sta :2
        lda.l VCACHE_BASE+VC_ZH,x
        sta :2+1
        rep #$20
        .LONGA ON
        bra :3
?miss                                ; (8-bit: the callers' transform takes it so)
.endm
.proc vc_store
        .LONGA OFF
        sep #$20
        ldx vc_key
        lda vc_key+1
        sta.l VCACHE_BASE+VC_TAGH,x
        lda vc_frame
        sta.l VCACHE_BASE+VC_STAMP,x
        lda zp_X
        sta.l VCACHE_BASE+VC_XL,x
        lda zp_X+1
        sta.l VCACHE_BASE+VC_XH,x
        lda zp_Z
        sta.l VCACHE_BASE+VC_ZL,x
        lda zp_Z+1
        sta.l VCACHE_BASE+VC_ZH,x
        rep #$20
        .LONGA ON
        rts
.endp
.proc process_seg
        ; --- THE WHOLE PROLOGUE IS 16-BIT (2026-08-29).
        rep #$20                     ; ---- 16-bit A
        .LONGA ON                    ;   (and TELL MADS: an immediate is 3 B now)
ps_w16                               ; render_subsector's entry: it calls in 16-bit
        lda [zp_sptr]
        sta rs_v1w                   ; (high byte = rs_pegf, bit7 = DONTPEGTOP)
                                     ; load_vertex INLINED (2026-09-15), still
        asl @                        ;   16-bit: no sep/jsr/rep/rts and no reload
        asl @                        ;   of zp_vidx or zp_rx/zp_ry. Vertex index
        adc #MAP_VERTS               ;   * 4 (the asl's carry out is 0: the index
        sta zp_vptr                  ;   is < 16384) + MAP_VERTS; zp_vptr+2 =
        sec                          ;   MAP_EXT_BANK, set once by init_level
        lda [zp_vptr]
        sbc zp_px                    ; v1 stays in zp_rx/zp_ry: transform reads
        sta zp_rx                    ;   them in place (2026-09-26: no rx1/ry1
        ldy #2                       ;   copies)
        sec
        lda [zp_vptr],y
        sbc zp_py
        sta zp_ry
                                      ; 2026-09-22 idiom: Y already holds 2 -- the v1
        lda [zp_sptr],y              ;   block's `ldy #2` above, and nothing between
        sta rs_v2w                   ; (high byte = rs_pegl, bit7 = DONTPEGBOTTOM)
                                     ; load_vertex INLINED (2026-09-15), still
        asl @                        ;   16-bit: no sep/jsr/rep/rts and no reload
        asl @                        ;   of zp_vidx or zp_rx/zp_ry. Vertex index
        adc #MAP_VERTS               ;   * 4 (the asl's carry out is 0: the index
        sta zp_vptr                  ;   is < 16384) + MAP_VERTS; zp_vptr+2 =
        sec                          ;   MAP_EXT_BANK, set once by init_level
        lda [zp_vptr]
        sbc zp_px                    ; v2 -> zp_rx2/zp_ry2 only (transform2 reads
        sta zp_rx2                   ;   them in place, 2026-09-26)
                                      ; 2026-09-22 idiom: Y is still 2 (see v1)
        sec
        lda [zp_vptr],y
        sbc zp_py
        sta zp_ry2
        ; --- backface FIRST. cross = cx_a*cx_b - cx_c*cx_d with cx_a = rx2 - rx,
        ;     cx_b = -ry, cx_c = ry2 - ry, cx_d = -rx.
        ; 2026-09-29: the axis-aligned segs decide on the differences as they
        ;   come out of A; only ?bf_gen fills all four cells (for cross_pos).
        sec
        lda zp_rx2
        sbc zp_rx
        bne ?bf_tryc
        sec                          ; cx_a = 0 -> cross = -(cx_c*cx_d)
        lda zp_ry2
        sbc zp_ry
        beq ?bf_front                ;   a zero factor -> cross = 0 -> front
        sta cx_c
        sec
        lda #0
        sbc zp_rx                    ; cx_d
        beq ?bf_front
        eor cx_c                     ;   cross > 0 iff the signs DIFFER (bit 15 of
        bmi ?bf_far                  ;   the word eor)
        bpl ?bf_front                ; (always: the sign was just tested)
?bf_tryc
        sta cx_a
        sec
        lda zp_ry2
        sbc zp_ry
        bne ?bf_gen                  ; neither axis -> pay for the full cross
        sec                          ; cx_c = 0 -> cross = cx_a*cx_b (cx_a != 0)
        lda #0
        sbc zp_ry                    ; cx_b
        beq ?bf_front
        eor cx_a                     ;   cross > 0 iff the signs are the SAME
        bpl ?bf_far
        bmi ?bf_front                ; (always)
?bf_far .LONGA OFF
        sep #$20                     ; ---- every exit leaves 8-bit. ?bfout is an
                                      ;   rts and cross_pos is 8-bit code.
        rts                          ; 2026-09-22 idiom: a jmp to an rts IS an rts (-3,
        .LONGA ON
?bf_gen sta cx_c                     ; (A = cx_c, the bne's)
        sec
        lda #0
        sbc zp_ry
        sta cx_b
        sec
        lda #0
        sbc zp_rx
        sta cx_d
                                      ; 2026-09-22: cross_pos past its rep, still 16-bit
        .LONGA ON                    ;   (reached from the 16-bit cx_c test above;
        jsr cross_pos.cp_w16         ;   this sep and that rep were an empty pair);
        .LONGA OFF                   ;   it returns 8-bit as before
        beq ?bfin                    ; cross>0 -> backface: not a single multiply
        rts                          ;   (the rts ?bfout would do, here: no jmp)
?bfin
                                     ;   spent on the view transform below (jne:
                                     ;   the transform's zp_rx*/zp_X1 left zero page)
        rep #$20                     ; front-facing after all: back to 16 bits,
        .LONGA ON
                                     ;   which is how the axis-aligned exits ...
?bf_front
        ; --- front-facing: NOW pay for the view transform of both endpoints.
        lda rs_v1w                   ; v1's index (2026-09-29: from the cell)
        and #$7FFF                   ; (the cache tags by index: drop the peg bit)
        VC_LOOK zp_X1, zp_Z1, ps_v1hit, ps_v1stc  ; (2026-09-26) a hit lands in X1/Z1 itself
        .LONGA OFF                   ; (a miss leaves VC_LOOK 8-bit)
        jsr transform
                                     ; 2026-09-22: transform returns 16-bit now
        .LONGA ON                    ; 2026-09-29: ... with A = zp_Z -- stored first
        sta zp_Z1
        jsr vc_store
        lda zp_X                     ; (a miss: transform's result -> X1/Z1)
        sta zp_X1
ps_v1hit
        lda rs_v2w                   ; v2's index (2026-09-29: the word process_seg
        and #$7FFF                   ;   read at its top, not the seg record again)
        VC_LOOK zp_X2, zp_Z2, ps_v2hit, ps_v2stc  ; (zp_X/zp_Z: nobody reads them again
        .LONGA OFF                   ;   before ?z2ok's stores, checked 2026-09-26)
        jsr transform2               ; (reads zp_rx2/zp_ry2 itself, 2026-09-26)
                                     ; 2026-09-22: transform returns 16-bit now
        .LONGA ON                    ; (2026-09-29: A = zp_Z, as v1)
        sta zp_Z2
        jsr vc_store
        lda zp_X
        sta zp_X2
ps_v2hit                             ; 16-bit: Z < ZNEAR as ONE signed word test each
        stz rs_clipt                 ; (2026-09-28: not clipped, until ?clip1/2 say so)
        lda zp_Z1                    ;   (ZNEAR < 256: the same as the old hi-byte
        bmi ?n1                      ;   bmi/bne + lo-byte cmp)
        cmp #ZNEAR
        bcc ?n1
        lda zp_Z2                    ; Z1 in front: Z2 too?
        bmi ?cl2
        cmp #ZNEAR
        jcs ?z2ok                    ; both >= ZNEAR -> no clip (?z2ok opens with
?cl2    .LONGA OFF                   ;   its own rep #$21: fine from 16-bit)
        sep #$20                     ; only Z2 behind -> clip endpoint 2 (below)
        bra ?clip2
        .LONGA ON
?n1     lda zp_Z2                    ; Z1 behind: Z2 too -> drop the seg
        bmi ?bf16
        cmp #ZNEAR
        .LONGA OFF
        sep #$20                     ; (sep keeps C)
        bcs ?clip1                   ; only Z1 behind -> clip endpoint 1
?bfout  rts                          ; both behind near -> drop seg (and the
                                     ;   backface exit lands here too)
?bf16   sep #$20
        rts
?clip2
        ; --- clip endpoint 2 toward endpoint 1: X2 += (X1-X2)*t ; Z2=ZNEAR ---
	stz m_prod
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        sec                          ; t8 = (ZNEAR - Z2)<<8 / (Z1 - Z2)
        lda #ZNEAR
        sbc zp_Z2
        sta m_prod+1
        sec
        lda zp_Z1
        sbc zp_Z2
        sta m_den
        .LONGA OFF
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr udiv24.ud_w16        ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$20
        .LONGA ON
        UDQ                          ; A = m_quot (2026-09-26: no reload)
        sta m_a
        ora #$4000                   ; 2026-09-28: the cut, for the texture track
        sta rs_clipt                 ;   (?uclip): v2's end, t8 of the seg
        sec                          ; dX = X1 - X2
        lda zp_X1
        sbc zp_X2
        sta m_b                      ; 2026-09-29: A = m_b, N = the sbc's (sm_w16)
        jsr smul32.sm_w16            ; m_prod = dX * t8 (16-bit in and out)
        .LONGA ON
        clc                          ; X2 += m_prod>>8
        lda zp_X2
        adc m_prod+1
        sta zp_X2
        lda #ZNEAR
        sta zp_Z2
        .LONGA OFF
        sep #$20
        bra ?z2ok
?clip1  ; --- clip endpoint 1 toward endpoint 2: X1 += (X2-X1)*t ; Z1=ZNEAR ---
	stz m_prod
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        sec                          ; t8 = (ZNEAR - Z1)<<8 / (Z2 - Z1)
        lda #ZNEAR
        sbc zp_Z1
        sta m_prod+1
        sec
        lda zp_Z2
        sbc zp_Z1
        sta m_den
        .LONGA OFF
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr udiv24.ud_w16        ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$20
        .LONGA ON
        UDQ                          ; A = m_quot (2026-09-26: no reload)
        sta m_a
        ora #$8000                   ; (2026-09-28, as ?clip2: v1's end, bit 15)
        sta rs_clipt
        sec                          ; dX = X2 - X1
        lda zp_X2
        sbc zp_X1
        sta m_b                      ; (as ?clip2)
        jsr smul32.sm_w16            ; m_prod = dX * t8
        .LONGA ON
        clc
        lda zp_X1
        adc m_prod+1
        sta zp_X1
        lda #ZNEAR
        sta zp_Z1
        .LONGA OFF                   ; (no sep here: ?z2ok's rep #$21 is the
?z2ok                                ;  next instruction on this path, 2026-09-14)
        ; --- CHEAP FRUSTUM REJECT (SPEED-PLAN-2 P1, at SEG level) -------------
        ; FOCAL and SCREEN_HALF are both 80, so the view is exactly 90 degrees
        ; and a view-space point is on screen iff |X| <= Z.
	rep #$21		;absorb CLC
        .LONGA ON
        lda zp_X1                    ; both endpoints left of the screen?
        bpl ?fr_nl                   ; X1 + Z1 < 0 ?
;       lda zp_X1
        adc zp_Z1
        bpl ?fr_nl

        lda zp_X2
        bpl ?fr_nl
        clc                          ; X2 + Z2 < 0 ?
;       lda zp_X2
        adc zp_Z2
        bmi ?fr_out
        bpl ?fr_nl                   ; (always: the sign was just tested clear)
?fr_out .LONGA OFF
        sep #$20
        rts                          ; the seg covers no column -- drop it here,
                                     ;   exactly as ?skip would have below
        .LONGA ON                    ; (?fr_nl is reached in 16-bit, always)
?fr_nl  lda zp_X1                    ; both endpoints right of the screen?
        bmi ?fr_nr
	sec                          ; X1 - Z1 > 0 ?
;       lda zp_X1
        sbc zp_Z1
        bmi ?fr_nr
        beq ?fr_nr                   ; X1 == Z1 is the edge column: keep

        lda zp_X2
        bmi ?fr_nr
        sec                          ; X2 - Z2 > 0 ?
;       lda zp_X2
        sbc zp_Z2
        bmi ?fr_nr
        bne ?fr_out
?fr_nr
        ; ===== M2c: real wall heights + floor/ceiling (SOLID walls) =====
        ; Transcribes gui.py render_view (fixed).
        ; 2026-09-29: scale and column straight into the L / R cells (v1 is
        ;   the left end; the swap is the rare case), X/Z to the callees in A.
        lda zp_Z1                    ; (still 16-bit, straight out of the reject)
        jsr scale_z.sz_a16
        sta rs_scL
        lda zp_X1
        jsr screenx_signed.sx_a
        sta rs_sxL
        lda zp_Z2                    ; --- endpoint 2 ---
        jsr scale_z.sz_a16
        sta rs_scR
        lda zp_X2
        jsr screenx_signed.sx_a
        sta rs_sxR
        ; --- order left<=right by signed sx (d = sx1 - sx2) ---
        lda rs_sxL
        cmp rs_sxR
                                      ; DRAC_PLAN 5: no 8-bit window: the flags are the
        bmi ?one_l                   ;   16-bit cmp's (N/Z), exactly what sep kept
        beq ?one_l
        pha                          ; v2 is the LEFT endpoint (A = sx1): swap
        lda rs_sxR
        sta rs_sxL
        pla
        sta rs_sxR
        lda rs_scL
        pha
        lda rs_scR
        sta rs_scL
        pla
        sta rs_scR
        lda #1                       ; ... -> u runs L..0
        sta rs_uflip                 ;   (a 16-bit cell: 1, pad 0)
        bra ?ord16
?one_l  stz rs_uflip                 ; v1 is the LEFT endpoint -> u runs 0..L
?ord16
        .LONGA OFF
        sep #$20
?ordered
        ; --- xa = max(vw_x0, sxL) --- (the window's edge, not the screen's: the
        ;     border columns are solid, so scanning them would be pure waste)
        lda rs_sxL+1
        bmi ?xa0                     ; sxL < 0 -> vw_x0
        beq ?xalo                    ; hi==0 -> use low
        lda #SCREEN_WIDTH            ; sxL >= 256 -> off right (force skip)
        sta zp_xa
	bra ?xadone
?xalo   lda rs_sxL
        cmp vw_x0
        bcs ?xas
?xa0    lda vw_x0
?xas    sta zp_xa
?xadone
        ; --- xb = min(vw_x1, sxR) ---
        lda rs_sxR+1
        bmi ?skip                    ; sxR < 0 -> nothing visible
        bne ?xbhi                    ; hi>0 -> clamp to the window's right edge
        lda rs_sxR
        cmp vw_xend
        bcc ?xbset
?xbhi   lda vw_x1
?xbset  sta zp_xb
        ; --- skip if xa > xb ---
        lda zp_xa
        cmp zp_xb
        beq ?occl
        bcc ?occl
?skip   rts
        ; --- Doom8088's R_CheckBBox trick, at seg level: if EVERY column this ...
?occl   lda rs_mpass                 ; (mtx_occ, inline: 2026-09-15 -- the
        beq ?occ0                    ;   jsr/rts and its own test are gone)
        jsr mseg_prime               ; = ldx zp_xa, except in the MASKED pass,
                                     ;   which first REOPENS this seg's columns ...
?occ0   ldx zp_xa
?occ1   lda solid_arr,x
        beq ?go                      ; found an open column -> the seg is visible
        cpx zp_xb
        beq ?skip                    ; scanned the whole span, all solid -> drop
        inx
        bne ?occ1
?go
        ; --- span = sxR - sxL (>=1) ---
        sec
	rep #$20
	.LONGA ON
        lda rs_sxR
        sbc rs_sxL
	bne ?spok
	inc
?spok	sta rs_span
                                     ; the span straight into recip_norm's 16-bit entry
	RECIP_NORM                   ; (inlined 2026-09-26)   (no rc_m store, no sep/rep pair; returns 8-bit)
	.LONGA OFF

        lda.l RCX_INV_LO,x           ; bank $01 (memory_map.inc RECIP_EXT)
        sta rs_invm
        lda.l RCX_INV_HI,x
        sta rs_invm+1
        clc                          ; shift = RECIP_INV_K + e
        lda #RECIP_INV_K
        adc rc_e
        sta rs_invsh
        lda #$FF                     ; sscl_col's track: no step for this seg yet
        sta rs_sscx                  ;   (its first closed column works it out)
        ; --- horizontal texture coord: a WORLD-anchored track along the seg -----
        ;   u was (col - sxL): one texel per screen column, anchored to a screen
        ;   coordinate that moves as the player walks.
        rep #$30                     ; am_mark INLINED (2026-09-15): 16-bit A + X
        lda rs_segi                  ;   (native mode). A = seg index x2: AMSEG is
        asl                          ;   a u16 array
        tax
        lda.l SEGLEN_EXT,x           ; 2026-09-28: the seg's EXACT length (pack_map
        tay                          ;   _seglen), parked in Y while X turns into
                                     ;   the automap's slot
        lda.l AMSEG_EXT,x            ; A = &AMSEEN[this seg's linedef], bank $03
        tax
        sta.l AM_BANK0,x             ; ...and store it INTO that slot (ML_MAPPED)
        tya
        sep #$10                     ; X/Y back to 8 bits; A stays 16-bit
	.LONGA ON
        ldy #4                       ; 2026-09-28: its bits 15/14 are the fake
        asl @                        ;   contrast, rs_lcon for lt_seg. C = bit 15, a
        bpl ?nh                      ;   vertical line (brighter); N = bit 14, a
        ldy #0                       ;   horizontal one (darker). ldy keeps C
?nh     bcc ?nv
        ldy #8
?nv     sty rs_lcon
        and #$7FFE
        lsr @
        sta rs_seglen
	lda rs_segi
	asl
	sta m_a
;	clc
	adc #MAP_SEGOFF
	sta zp_ptr

        lda [zp_ptr]
        sta rs_segoff
        lda rs_clipt                 ; 2026-09-28: a seg the near plane cut shows
        bne ?uclip                   ;   only PART of its texture (out of line)
?uclipd
        ldy rs_uflip
	beq ?u01

        sec                          ; left end carries u = L, right end u = 0
        lda #0
        sbc rs_seglen
        sta m_prod+1
        bra ?ustep
        ; ---- ?clip1/?clip2 moved an endpoint to Z = ZNEAR, t8/256 of the way
        ; along the seg -- and the texture track still ran 0..L over what was
        ; left, so a wall the player stands against showed its WHOLE texture
        ; squeezed into the visible part (tools/tests/_verify_view.py: columns
        ; off by 16-24). The cut is L*t8 >> 8 texels: off the length, and on
        ; to the start when it is v1's end (u = segoff there) that went.
?uclip  and #$00FF
        sta m_b
        lda rs_seglen
        sta m_a
        .LONGA OFF
        sep #$20
        jsr umul16                   ; m_prod = L * t8
        rep #$21
        .LONGA ON
        lda rs_clipt
        bpl ?uc2                     ; v2's end: the start stays
        lda rs_segoff
        adc m_prod+1                 ; (C = 0)
        sta rs_segoff
?uc2    sec
        lda rs_seglen
        sbc m_prod+1
        bne ?uc3
        inc @                        ; (never 0: calc_u multiplies by it)
?uc3    sta rs_seglen
        bra ?uclipd

?u01    lda rs_seglen                ; left end u = 0, right end u = L
        sta m_prod+1
                                     ; 2026-09-22 (65816-windows): u_guard past its rep,
?ustep  jsr u_guard.ug_w16           ;   still 16-bit (this sep and that rep were an
        .LONGA OFF                   ;   empty pair)
                                     ; u_guard: rs_utL/utR = rs_scL/scR, halved until
                                     ;   max(scale)*span fits the 24-bit tracks
        sec                          ; t1 = scaleR * (xa - sxL)
	rep #$20
	.LONGA ON
        lda zp_xa
	and #$00ff
        sbc rs_sxL
        sta m_a
        sta rs_pdl                   ; 2026-09-29: plane_setup's left distance
        lda rs_utR
        sta m_b
	sep #$20
	.LONGA OFF
        jsr umul16
        rep #$20                     ; t1 = the product: rs_t1 is a 32-bit cell
        .LONGA ON                    ;   (bytes 0-1, then 2-3; byte 3 is padding
        lda m_prod                   ;   nobody reads -- DRAC_PLAN 5), so two
        sta rs_t1                    ;   word moves (drac030, 2026-09-14)
        lda m_prod+2
        sta rs_t1+2
        lda zp_xa                    ; t2 = scaleL * (sxR - xa): xa is a BYTE,
        and #$00FF                   ;   so mask its neighbour off, then
        eor #$FFFF                   ;   sxR + ~xa + 1 = sxR - xa in one add
        sec
        adc rs_sxR
        sta m_a
        sta rs_pdr                   ; 2026-09-29: plane_setup's right distance
        lda rs_utL
        sta m_b
        .LONGA OFF
        sep #$20
        jsr umul16
        rep #$20
        .LONGA ON
        lda m_prod
        sta rs_t2
        lda m_prod+2
        sta rs_t2+2
        ; (still 16-bit: the sep/rep pair that stood around the ldy below was ...
        ldy #SEG_FRONT               ; front_sec (u8) @ seg+4
        lda [zp_sptr],y
        and #$FF
        asl @
        asl @
        asl @                        ; front_sec*8 (8-byte sector records)
;       clc
        adc #MAP_SECTORS
        sta zp_ptr
        ; worldtop = ceil_h(@2) - pz ; worldbot = floor_h(@0) - pz
        ldy #2
        sec
        lda (zp_ptr),y
        sbc zp_pz
        sta rs_wtop
        sec
        lda (zp_ptr)
        sbc zp_pz
        sta rs_wbot
        sec                          ; worldH = f_ceil-f_floor = wtop-wbot (texel span)
        lda rs_wtop
        sbc rs_wbot
        sta rs_worldh
        .LONGA OFF
        sep #$20
ltsj    jsr lt_seg                   ; floor_base @5 / ceil_base @6 -> rs_*col,
                                     ;   both SHADED with this sector's light ...
                                      ; SKY (2026-09-16): an F_SKY1 ceiling is DOOM's
        ldy #7                       ;   screen-fixed sky, not a flat (sky_clip).
        lda (zp_ptr),y               ;   zp_ptr is still the FRONT sector: lt_seg
        lsr @                        ;   only reads it. C = bit0 = sky ceiling.
        lda #$30                     ; (2026-09-26) colmerge's `bmi ?cmno` for a flat...
        bcc ?skyk
        lda #$80                     ; ...BRA ?cmno for a sky: the test never runs,
?skyk   cmp.l B1CODE_BASE+?cmbr      ;   so no sky column is copied sideways.
        beq ?skyd                    ;   Nothing to patch while the ceiling kind
        sta.l B1CODE_BASE+?cmbr      ;   repeats.
        cmp #$80                     ; $80 (sky) -> C = 1, $30 -> C = 0
                                      ; (the ceiling ENTRIES: rs_ra is not clipped)
        lda #<draw_clip.dc_ceil      ; ...and the ceiling call's target with it
        ldy #>draw_clip.dc_ceil
        bcc ?skyj
        lda #<sky_clip.sk_ceil
        ldy #>sky_clip.sk_ceil
?skyj   sta.l B1CODE_BASE+?ceilj+1
        tya
        sta.l B1CODE_BASE+?ceilj+2
?skyd
        ldy #SEG_WALL                ; wall_tex @ seg+6: texid + bit7 impassable
        lda [zp_sptr],y              ;   (collision-only)
        sta rs_texw
        iny                          ; low_tex @ seg+7: texid + bit7 EXIT line
        lda [zp_sptr],y              ;   (the PEG bits are rs_pegf/rs_pegl bit7,
        sta rs_texl                  ;   latched with v1/v2 at the top)

        lda rs_mpass                 ;   use the peg bit (door tracks).
        beq ?pegw                    ; (mtx_pegf's test inline, 2026-09-15: the
        jsr mtx_pegf                 ;  wall pass skips the jsr/rts)
        bra ?pegd
?pegw   lda rs_texw
?pegd                                ; = lda rs_texw, except in the MASKED pass,
                                     ;   which draws the two-sided MIDDLE texture
                                     ;   and gets rs_midtex instead (midtex.asm).
        and #SEG_TEXM                ; texid = bits 0-6
        cmp MAP_HNTEX
        bcs ?wnone                   ; >= count (incl 0x3F sentinel) -> no texture
        tax
        stx rs_wtexid                ; B2: full texture handle (base/h/wmask) for the blit
                                     ; (2026-09-28: rs_wallcol is ?wflat's -- only
                                     ;   a FLAT wall reads it)
        lda MAP_TEXADDRLO,x
        sta rs_wtexad
        lda MAP_TEXADDRMID,x
        sta rs_wtexad+1
        lda MAP_TEXADDRHI,x
        sta rs_wtexad+2
        lda MAP_TEXWMASK,x
        sta rs_wtexwm

    .if TEX_RUNS
        ;clc                          ; tex_setix INLINED (2026-09-15): the address
        lda.l MAP_TEXIXLO,x            ;   goes straight into wall_src's operand --
        adc #<LVL_TEXSD_C            ;   no jsr/rts, no wt_ix* round trip, and X
        sta.l B1CODE_BASE+wall_src.wix+1   ; is still the texid (tex_setix never
        lda.l MAP_TEXIXHI,x            ;   touched X on this path), so the ldx
        adc #>LVL_TEXSD_C            ;   reload goes too
        sta.l B1CODE_BASE+wall_src.wix+2
        lda #[LVL_TEXSD_C>>16]
        adc #0
        sta.l B1CODE_BASE+wall_src.wix+3
    .else
        jsr tex_setix
        lda wt_ixl
        sta.l B1CODE_BASE+wall_src.wix+1
        lda wt_ixh
        sta.l B1CODE_BASE+wall_src.wix+2
        ldx rs_wtexid
    .endif
        lda MAP_TEXH,x               ; h = 0: this build does not SHIP the pixels
        sta rs_wtexh                 ;   (pack_textures.py SHIP_ALL_TEXTURES)...
        beq ?wflat
    .if TEX_RUNS
        dec @                        ; the tile's mask (texH-1) and pow2 flag (texH
        sta rs_texmask               ;   AND texH-1), slot 0: paint_col reads them
        and rs_wtexh                 ;   by tx_slot (2026-09-29: per SEG, they were
        sta rs_texpow2               ;   worked out per column)
    .endif
        lda rs_mpass                 ;   ...or the player pressed 'T' (runtime
        bne ?wtex                    ;   flat mode -- no fetch, no arena spend);
        lda tex_flat                 ;   mtx_flat inline (2026-09-15): a strut
        bne ?wflat                   ;   is never flattened
?wtex
                                     ;   = lda tex_flat, except for a two-sided
                                     ;   MIDDLE texture, which 'T' does not
                                     ;   flatten: see midtex.asm
	rep #$21
	.LONGA ON
	lda rs_wtexad
	adc tex_sdram
	sta rs_wtexad
	sep #$20
	.LONGA OFF
        lda rs_wtexad+2              ;   .else was deleted with tex_fget,
        adc tex_sdram+2              ;   2026-08-14.)
        sta rs_wtexad+2
	bra ?whave
?wflat  jsr lt_flat                  ; a flat wall in its dominant colour (X = the
        sta rs_wallcol               ;   texid), and no handle: the draw sites take
        lda #$FF                     ;   the flat path
        sta rs_wtexid
        bne ?whave                   ; (A = $FF)
?wnone  lda #$FF
        sta rs_wtexid
        stz rs_wallcol
?whave
        ; --- front planes (ceil + floor) via plane_setup.
                                      ; 2026-09-15: both front tracks in word moves,
        rep #$20                     ;   plane_setup16 takes wtmp straight out of A,
        .LONGA ON                    ;   and the two opcode patches come AFTER the
        lda rs_wtop                  ;   second call (they only rewrite ?cnext, so
        sta rs_wtmp                  ;   the order is free) -- ~30 cycles a seg
        jsr plane_setup.plane_setup16
        .LONGA ON                    ; (2026-09-29: 16-bit out, A = the top word:
        sta rs_ycacc+2               ;   bytes 2-3, byte 3 is the cell's padding)
        lda rs_acctmp
        sta rs_ycacc
        lda rs_Stmp
        sta rs_ycS
        lda rs_wbot
        sta rs_wtmp
        jsr plane_setup.plane_setup16
        .LONGA ON
        sta rs_yfacc+2
        lda rs_acctmp
        sta rs_yfacc
        lda rs_Stmp                  ; (the carry-step patches of all four tracks
        sta rs_yfS                   ;   are made once, at ?ststep)
        .LONGA OFF
        sep #$20
        ; --- portal? back_sec (@seg+SEG_BACK) != NO_SECTOR ---
        ldy #SEG_BACK
        lda [zp_sptr],y
        sta m_a
        ldy rs_mpass                 ; (mtx_back inline, 2026-09-15)
        beq ?real
        lda #NO_SECTOR
?real   cmp #NO_SECTOR               ; = cmp #NO_SECTOR, except in the MASKED
                                     ;   pass, which answers ONE-SIDED: a strut ...
        bne ?two_sided
                                      ; 2026-09-22: rs_isport had two readers, both
        lda #$89                     ;   in the column loop -- they are patched here
        sta.l B1CODE_BASE+?ispj      ;   instead: ?ispj falls through (BIT #), ?ispk
        lda #$80                     ;   skips the back accumulators (BRA)
        sta.l B1CODE_BASE+?ispk
        stz rs_vshl                  ; no lower step on a solid seg
        stz rs_vshw                  ; default: top-pegged at the front ceiling
        lda #$FF                     ; no lower step on a solid seg (stale id would
        sta rs_ltexid                ; defeat the "nothing textured" test per column)
        ; --- DOOM r_segs.c: a one-sided line with ML_DONTPEGBOTTOM puts the
        ;     BOTTOM of the texture at the front floor (door tracks use this so
        ;     they stand still while the door ceiling moves).
        bit rs_pegl                  ; bit7 = ML_DONTPEGBOTTOM
        bpl ?soldone
        lda rs_worldh
        sta m_a
        lda rs_worldh+1
        sta m_a+1
        bmi ?soldone                 ; degenerate (ceil below floor) -> leave 0
        lda rs_wtexh
        jsr vsh_neg
        sta rs_vshw
?soldone jmp ?have_planes

?two_sided
                                      ; 2026-09-22: a PORTAL -- ?ispj branches to
        lda #$80                     ;   ?portalw, ?ispk runs the back accumulators
        sta.l B1CODE_BASE+?ispj
        lda #$89
        sta.l B1CODE_BASE+?ispk
        lda rs_texl                  ; lower-step texid (bits 0-6; bit7 EXIT used to
        and #SEG_TEXM                ;   push the byte past TEX_COUNT and silently
        cmp MAP_HNTEX               ;   blank an exit line's lower step)
	jcs ?lnone
	tax
        stx rs_ltexid                ; B2: lower-step texture handle (rs_lowcol:
                                     ;   ?lflat's, as the wall's)
        lda MAP_TEXADDRLO,x
        sta rs_ltexad
        lda MAP_TEXADDRMID,x
        sta rs_ltexad+1
        lda MAP_TEXADDRHI,x
        sta rs_ltexad+2
        lda MAP_TEXWMASK,x
        sta rs_ltexwm
    .if TEX_RUNS
        ;clc                          ; tex_setix inlined, as the wall above
        lda.l MAP_TEXIXLO,x
        adc #<LVL_TEXSD_C
        sta.l B1CODE_BASE+low_src.lix+1
        lda.l MAP_TEXIXHI,x
        adc #>LVL_TEXSD_C
        sta.l B1CODE_BASE+low_src.lix+2
        lda #[LVL_TEXSD_C>>16]
        adc #0
        sta.l B1CODE_BASE+low_src.lix+3
    .else
        jsr tex_setix
        lda wt_ixl
        sta.l B1CODE_BASE+low_src.lix+1
        lda wt_ixh
        sta.l B1CODE_BASE+low_src.lix+2
        ldx rs_ltexid
    .endif
        lda MAP_TEXH,x               ; h = 0 -> pixels not in this build, flat step
        sta rs_ltexh                 ;   in its dominant colour (see ?wflat above)
        bne ?lgo
?lfj    bra ?lflat                   ; (the fetch block pushed ?lflat out of

?lgo
    .if TEX_RUNS
        dec @                        ; (A = rs_ltexh) the lower step's mask and
        sta rs_texmask+1             ;   pow2 flag, slot 1
        and rs_ltexh
        sta rs_texpow2+1
    .endif
        lda tex_flat                 ;   branch range)
        bne ?lfj                     ; 'T': runtime flat mode, lower step too

        rep #$21                     ; PAINTED: SDRAM address, no arena (see the
        .LONGA ON                    ;   wall slot above). Nothing can be evicted
	                             ;   any more, so the flush handshake and the
                                     ;   re-fetch that used to sit here under
        lda rs_ltexad                ;   .else went with tex_fget (2026-08-14).
        adc tex_sdram
        sta rs_ltexad
	sep #$20
	.LONGA OFF
        lda rs_ltexad+2
        adc tex_sdram+2
        sta rs_ltexad+2
        bra ?lhave

?lflat  jsr lt_flat                  ; (2026-09-28: X = the texid)
        sta rs_lowcol
        lda #$FF
        sta rs_ltexid
	bra ?lhave
                                     ; a SHUT portal (A = its back ceiling, Y = 2):
?shut   .LONGA ON                    ;   X = 2 where an upper step stands, below
        ldx #2                       ;   the front ceiling, else 4
        sec
        sbc zp_pz
        cmp rs_wtop
        bmi ?shu
        ldx #4
?shu    lda (zp_ptr),y
        bra ?shk
?shp    stx ps_shut                  ; the column loop's three patches, by X
        lda.l B1CODE_BASE+?pse,x
        sta.l B1CODE_BASE+?loeq
        sep #$20
        .LONGA OFF
        lda.l B1CODE_BASE+?psu,x
        sta.l B1CODE_BASE+?updec
        lda.l B1CODE_BASE+?psi,x
        sta.l B1CODE_BASE+?loinc
        rep #$20
        .LONGA ON
        lda (zp_ptr),y
        bra ?shd
        .LONGA OFF
?pse    dta a($F0+[[?nolo-?loeq-2]<<8])      ; ?loeq: beq ?nolo ...
        dta a($F0+[[?nolo-?loeq-2]<<8])
        dta a($00C2)                 ;   ... rep #0: the lower step takes the row
?psu    dta a($3A), a($EA), a($3A)   ; ?updec: dec / nop, the upper step takes it
?psi    dta a($1A), a($1A), a($EA)   ; ?loinc: inc / inc / nop
?lnone  lda #$FF
        sta rs_ltexid
        stz rs_lowcol
?lhave
        ldy #7                       ; SKY HACK, part 1 (2026-09-15): the FRONT
        lda (zp_ptr),y               ;   sector's flags (bit0 = F_SKY1 ceiling,
        pha                          ;   pack_map) -- zp_ptr moves to the back
                                     ;   D0 byte pushed a D0 block onto $9500 ...
	rep #$20
	.LONGA ON
	lda m_a
	and #$00ff
	asl
	asl
	asl
;	clc
	adc #MAP_SECTORS
	sta zp_ptr
        ldx #0                       ; a SHUT portal, back floor = back ceiling,
        ldy #2                       ;   leaves ONE row between its steps: the
        lda (zp_ptr),y               ;   upper step takes it (r_segs.c: mid is
        cmp (zp_ptr)                 ;   pixhigh's row), or the lower one
        beq ?shut
?shk    cpx ps_shut                  ; the column loop as the last seg left it?
        bne ?shp
?shd    sec                          ; back ceil plane: b_ceil(@2) - pz
        sbc zp_pz
        sta rs_wtmp
        ; 2026-09-29: one 16-bit window to ?have_planes; the byte cells go
        ; through the 8-bit Y, plane_setup16 takes rs_wtmp in A.
        ldy #0
        sty rs_vshw
        ldy rs_pegf                  ; bit7 = ML_DONTPEGTOP
	bmi ?uppeg
        sec                          ; D = front_ceil - back_ceil
        lda rs_wtop
        sbc rs_wtmp
        sta m_a
        bmi ?upneg                   ; back ceiling above front -> top-pegged
        .LONGA OFF
        sep #$20
        lda rs_wtexh
        jsr vsh_neg
        sta rs_vshw
        rep #$20
        .LONGA ON
?upneg  lda rs_wtmp
?uppeg  jsr plane_setup.plane_setup16
        .LONGA ON
        sta rs_ybcacc+2              ; (bytes 2-3: byte 3 is the cell's padding)
        lda rs_acctmp
        sta rs_ybcacc
        lda rs_Stmp
        sta rs_ybcS

        ; SKY HACK, part 2 -- BUG FIX 2026-09-15 (E3M1: "strop je ako keby nizsie").
        ply                          ; part 1's front flags (pushed 8-bit)
        tya
        lsr @
        bcc ?nosky                   ; front is not sky
        ldy #7
        lda (zp_ptr),y               ; zp_ptr = the BACK sector here (the flags
        lsr @                        ;   are the word's low byte)
        bcc ?nosky                   ; back is not sky
        lda rs_acctmp                ; ycacc = the back ceiling accumulator
        sta rs_ycacc
        lda rs_acctmp+2
        sta rs_ycacc+2
        lda rs_Stmp                  ; ycS = its slope (?ststep patches the carry
        sta rs_ycS                   ;   step from it)
?nosky  sec
        lda (zp_ptr)
        sbc zp_pz
        sta rs_wtmp
        ldy #0
        sty rs_vshl
        ldy rs_pegl                  ; bit7 = ML_DONTPEGBOTTOM
        bpl ?lowpeg
        sec                          ; L = front_ceil - back_floor
        lda rs_wtop
        sbc rs_wtmp
        sta m_a
        bmi ?loneg                   ; back floor above front ceiling
        .LONGA OFF
        sep #$20
        lda rs_ltexh
        jsr vsh_mod
        sta rs_vshl
        rep #$20
        .LONGA ON
?loneg  lda rs_wtmp
?lowpeg jsr plane_setup.plane_setup16
        .LONGA ON
        sta rs_ybfacc+2
        lda rs_acctmp
        sta rs_ybfacc
        lda rs_Stmp
        sta rs_ybfS
	sep #$20
	.LONGA OFF
?have_planes
                                      ; 2026-09-15: mtx_hook, cm_reset, cu_seg_init
                                     ;   and tw_seg_init INLINED (one caller each,
                                     ;   104 segs a frame: 4 x 12 cycles of jsr/rts)
        jsr seg_yoff                 ; sidedef->rowoffset: both peg shifts are final
        lda rs_mpass                 ; ...then the two-sided MIDDLE texture: the WALK
        bne ?mh_prime                ;   snapshots and DEFERS such a seg, the masked
        rep #$10                     ;   pass primes the window arrays from that
        ldx rs_segi                  ;   snapshot (midtex.asm). MAP_SEGMID[seg]: which
        lda.l SEGMID_EXT,x           ;   MIDTEX row this seg uses, $FF = none (and
        sep #$10                     ;   $FF for every one-sided seg too)
        sta rs_midtex
        cmp #$FF
        beq ?mh_prime
        jsr mseg_snap                ; (was mtx_hook's tail jump)
?mh_prime
        ; ===== per-column loop (portal-aware) =====
        stz cm_n                     ; cm_reset: no merge run pending yet
        lda #$FF
        sta cm_x                     ;   (no source column yet)
        stz cu_cnt                   ; cu_seg_init: 0 -> the first column is an
        sta cu_cx                    ;   anchor, and no look-ahead u carries over
        stz tws_cnt                  ; tw_seg_init: the texel-rate subdivision
        stz tws_exact                ;   (steep mode never leaks across segs)
                                      ; 2026-09-22: "nothing textured" is a per-SEG
        lda rs_wtexid                ;   fact -- ?txj becomes BRA ?notex ($80) when
        and rs_ltexid                ;   both ids are $FF, BIT # ($89) otherwise
        cmp #$FF                     ;   (C = 1 only for $FF)
        lda #$89
        bcc ?txs
        lda #$80
?txs    sta.l B1CODE_BASE+?txj
                                      ; 2026-09-27: the three per-column "textured?"
        ldy #$89                     ;   tests (ldy/cpy #$FF/beq, 7 cycles) are per-SEG
        lda rs_wtexid                ;   facts too: BIT # ($89) falls into the textured
        cmp #$FF                     ;   path, BRA ($80) takes the flat one
        bne ?twt
        ldy #$80
?twt    tya
        sta.l B1CODE_BASE+?twj
        sta.l B1CODE_BASE+?tuj
        ldy #$89
        lda rs_ltexid
        cmp #$FF
        bne ?tlt
        ldy #$80
?tlt    tya
        sta.l B1CODE_BASE+?tlj
    .if TEX_RUNS
        jsr pt_seg                   ; rows-per-texel for the seg's first column
                                     ;   + its per-column step (paint.asm).
    .endif
                                      ; 2026-09-22 (6502-idioms: a variable as the operand
        rep #$20                     ;   of adc #): the column loop's eight per-SEG steps
        .LONGA ON                    ;   go INTO its immediates here, once a seg (29 a
        lda rs_utR                   ;   frame), for 2 cycles a use on 602 columns a
        sta.l B1CODE_BASE+?sutr+1    ;   frame. Every step is final here (u_guard,
                                     ;   plane_setup, the back planes, pt_seg)
        ; 2026-09-27: the loop's six clc/sec are gone -- each add meets a KNOWN
        ; carry cin (the previous add's common-path carry) and its immediate is
        ; step-cin, so x + (S-cin) + cin = x + S exactly, carry out included.
        ; t2: cin = 0 -> sbc #utL-1 (utL = 0: `cmp #0`, t2 kept, C = 1).
        ldx #$C9                     ; `cmp #` -- its opcode goes in at the sep below
        lda rs_utL
        beq ?stl
        dec @
        ldx #$E9                     ; `sbc #`
?stl    sta.l B1CODE_BASE+?sutl+1
        ; The four 24-bit tracks: C holds NOT cin (sbc #0 = S - cin). A track
        ; whose S - cin < 0 (sign from N^V) takes BCC ?xxoo + DEY and leaves the
        ; common path with C = 1, else BCS + INY and C = 0; the stub's patched
        ; clc/sec gives the rare path the same C. ?ststep then sets C = NOT cout.
        clc                          ; yc: cin = 1 (t2's sbc/cmp does not borrow)
        lda rs_ycS
        sbc #0
        sta.l B1CODE_BASE+?syc+1
        bvs ?ycv
        bmi ?ycn
?ycp    lda #$B0|[[?ycoo-?ycadd-2]<<8]   ; bcs ?ycoo
        sta.l B1CODE_BASE+?ycadd
        lda #$18C8                   ; iny / clc
        sta.l B1CODE_BASE+?ycinc
        sec                          ; cout = 0
        bra ?yfst
?ycv    bmi ?ycp                     ; overflow: the true sign is NOT N
?ycn    lda #$90|[[?ycoo-?ycadd-2]<<8]   ; bcc ?ycoo
        sta.l B1CODE_BASE+?ycadd
        lda #$3888                   ; dey / sec
        sta.l B1CODE_BASE+?ycinc
        clc                          ; cout = 1
?yfst   lda rs_yfS
        sbc #0
        sta.l B1CODE_BASE+?syf+1
        bvs ?yfv
        bmi ?yfn
?yfp    lda #$B0|[[?yfoo-?yfadd-2]<<8]
        sta.l B1CODE_BASE+?yfadd
        lda #$18C8
        sta.l B1CODE_BASE+?yfinc
        sec
        bra ?bkst
?yfv    bmi ?yfp
?yfn    lda #$90|[[?yfoo-?yfadd-2]<<8]
        sta.l B1CODE_BASE+?yfadd
        lda #$3888
        sta.l B1CODE_BASE+?yfinc
        clc
?bkst   lda.l B1CODE_BASE+?ispk      ; $80 (bra: solid, no back tracks) or $89
        bit #$0001                   ;   (bit #: portal) -- Z only, C kept
        beq ?rpst
        lda rs_ybcS
        sbc #0
        sta.l B1CODE_BASE+?sybc+1
        bvs ?bcv
        bmi ?bcn
?bcp    lda #$B0|[[?bcoo-?bcadd-2]<<8]
        sta.l B1CODE_BASE+?bcadd
        lda #$18C8
        sta.l B1CODE_BASE+?bcinc
        sec
        bra ?bfst
?bcv    bmi ?bcp
?bcn    lda #$90|[[?bcoo-?bcadd-2]<<8]
        sta.l B1CODE_BASE+?bcadd
        lda #$3888
        sta.l B1CODE_BASE+?bcinc
        clc
?bfst   lda rs_ybfS
        sbc #0
        sta.l B1CODE_BASE+?sybf+1
        bvs ?bfv
        bmi ?bfn
?bfp    lda #$B0|[[?bfoo-?bfadd-2]<<8]
        sta.l B1CODE_BASE+?bfadd
        lda #$18C8
        sta.l B1CODE_BASE+?bfinc
        sec
        bra ?rpst
?bfv    bmi ?bfp
?bfn    lda #$90|[[?bfoo-?bfadd-2]<<8]
        sta.l B1CODE_BASE+?bfadd
        lda #$3888
        sta.l B1CODE_BASE+?bfinc
        clc
?rpst
    .if TEX_RUNS
        lda rs_drpt                  ; rptf += drpt as a 32-bit drpt-cin (the
        sbc #0                       ;   words copied whole, rs_drpt+2's padding
        sta.l B1CODE_BASE+?sdr0+1    ;   byte included: exact mod 2^32)
        lda rs_drpt+2
        sbc #0
        sta.l B1CODE_BASE+?sdr2+1
    .endif
        .LONGA OFF
        sep #$20
        txa                          ; t2's opcode (?stl above)
        sta.l B1CODE_BASE+?sutl
        lda zp_xb                    ; the loop's last column -> ?cxb's operand
        sta.l B1CODE_BASE+?cxb+1
        ldx zp_xa
        bra ?col                     ; once a seg: the column's rare exits sit here,
                                     ;   ahead of ?col, so its open-window test falls
                                     ;   through to ?winok (527 columns a frame)
?cskip  jsr cm_flush                 ; a skipped column breaks the run: copy now
        rep #$21                     ; (?cnx16 wants M = 16 and C = 0)
        jmp ?cnx16
?cu_far jsr cu_anchor                ; calc_u_sub's two rare cases, out of line:
        bra ?cu_done                 ;   the interpolating column falls through
?cu_ex  jsr calc_u                   ; exact u at THIS column (calc_u keeps X)
        stz cu_cnt                   ; leaving steep mode re-anchors immediately
        bra ?cu_done
                                      ; 2026-09-22: the MASKED pass, out of line --
msko    jsr mseg_win                 ;   mseg_draw patches mskj to `bra msko` for
        bcs ?cskip                   ;   the pass (rs_mpass was a per-column test)
        stx zp_col
        bra mskr
?col    lda solid_arr,x
	bne ?cskip
	lda ytopc_arr,x              ; window [top,bot]
        sta rs_top
        lda ybotc_arr,x
        sta rs_bot
        cmp rs_top                   ; bot < top -> closed
        bcc ?cskip
                                      ; 2026-09-22: rs_pyc16/rs_pyf16 ARE rs_ycacc+1 /
?winok                               ;   rs_yfacc+1 (memory_map.inc aliases) -- the
                                     ;   26-cycle copy per column is gone
mskj    stx zp_col                   ; SMC: `bra msko` in the MASKED pass (mseg_draw)
                                     ; (the column's DST-add patches moved down to
                                     ;  ?cf_done, 2026-09-26: a column cm_test
                                     ;  defers draws nothing and paid them anyway)
                                      ; 2026-09-22: patched per seg at ?mh_prime:
mskr
?txj    bit #?notex-?txj-2           ;   BRA ?notex when both texture ids are $FF,
                                      ; 2026-09-15: the four per-column leaves
                                     ;   (calc_u_sub, tw_setup_sub, cm_test, ...
        lda tws_exact                ; --- calc_u_sub: steep block -> u exact per
        bne ?cu_ex                   ;   column; else interpolate rs_uacc += step
        dec cu_cnt                   ;   (24-bit), re-anchoring every CU_SUB
        bmi ?cu_far
        rep #$21
        .LONGA ON
        lda rs_uacc
        adc cu_step
        sta rs_uacc
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        lda rs_uacc+2
        adc cu_sgn
        sta rs_uacc+2
?cu_done
        dec tws_cnt                  ; --- tw_setup_sub: the rate needs nothing per
        bpl ?notex                   ;   column now; this paces the steep re-test
        jsr tws_anchor
?notex                               ; --- cm_test: would this column draw exactly
        lda cm_x                     ;   what the last one drew? (magnified walls
?cmbr   bmi ?cmno                    ;   repeat 4-8 columns per texel). SMC: BRA
                                     ;   on a sky seg -- never merged (ltsj patch).
                                     ;   A run to test against is the COMMON case,
                                     ;   so it falls through (2026-09-26, was a
                                     ;   taken bpl); ?cmno joins ?cm_c0 below.
?cm_have
        rep #$20
        .LONGA ON
        lda rs_top                   ; rs_top/rs_bot and cm_top/cm_bot are pairs
        cmp cm_top
        bne ?cm_c0
        lda rs_ycacc+1
        cmp cm_sig
        bne ?cm_c1
        lda rs_yfacc+1
        cmp cm_sig+2
        bne ?cm_c2
        lda rs_ybcacc+1
        cmp cm_sig+4
        bne ?cm_c3
        lda rs_ybfacc+1
        cmp cm_sig+6
        bne ?cm_c4
        lda rs_rpt
        cmp cm_sig+8
        bne ?cm_c5
        .LONGA OFF
        sep #$20
        lda rs_uacc+1
        cmp cm_sig+10
        bne ?cm_c6
        inc cm_n                     ; --- cm_defer: the same column again -> skip
        lda cm_solid                 ;   it, one blit copies it later
        beq ?cm_do                   ; portal still open -> its new window
        sta solid_arr,x              ; closed: same early-out bookkeeping as the
        dec cols_open                ;   drawing paths do
        bne ?cm_sc
        sta frame_done
?cm_sc  jsr sscl_col                 ; the wall's scale at THIS column; the window
                                     ;   is the run source's, already in ytopc/ybotc
?cm_dd  rep #$21                     ; (as ?cskip)
        jmp ?cnx16
?cm_do  lda cm_nt
        sta ytopc_arr,x
        lda cm_nb
        sta ybotc_arr,x
        bra ?cm_dd
?cf_go  jsr cm_flush.cm_go           ; a deferred run is pending: copy it first
        bra ?cf_done                 ;   (out of line; cm_go sets C itself)
?cmno   rep #$20                     ; (2026-09-26) nothing drawn yet / run broken / a sky seg:
        .LONGA ON                    ;   no test, but the signature is (re)saved in
?cm_c0  lda rs_ycacc+1               ;   full -- ?cm_c0's own first step
?cm_c1  sta cm_sig
        lda rs_yfacc+1
?cm_c2  sta cm_sig+2
        lda rs_ybcacc+1
?cm_c3  sta cm_sig+4
        lda rs_ybfacc+1
?cm_c4  sta cm_sig+6
        lda rs_rpt
?cm_c5  sta cm_sig+8
        .LONGA OFF
        sep #$20
        lda rs_uacc+1
?cm_c6  sta cm_sig+10
?cmdraw lda cm_n                     ; no: close the previous run (cm_flush's
        bne ?cf_go                   ;   early-out inlined: with nothing pending
        lda #$FF                     ;   it is `cm_x = $FF` and nothing else --
        sta cm_x                     ;   ~400 columns a frame), then draw
?cf_done                             ; (2026-09-26: the patch moved here from mskr)
        txa                          ; this column DRAWS: it goes in as the
        sta.l B1CODE_BASE+pt_span.pcw+1      ;   immediate of the DST adds in pt_span
        sta.l B1CODE_BASE+paint_col.pcolw+1  ;   and paint_col (the words' high bytes
        sta.l B1CODE_BASE+pt_span.pcx+1      ;   are assembled 0 and stay) and
                                     ;   pt_span's X restore. cm_flush builds its
                                     ;   copy from cm_x and reads none of them.
        ; ceiling: top .. pyc-1
                                      ; a = rs_top needs no clip (top <= bot here): the
	rep #$20                     ;   callee's ceiling entry takes it in A, rs_ra
	.LONGA ON                    ;   is not written
        lda rs_pyc16
	dec
        sta rs_rb
	sep #$20
	.LONGA OFF
        lda rs_ceilcol
        xba                          ; colour -> B, A = the top row
        lda rs_top
?ceilj  jsr draw_clip.dc_ceil        ; SMC: sky_clip.sk_ceil for an F_SKY1 ceiling

                                      ; 2026-09-22: patched where the seg's kind is
?ispj   bit #?portalw-?ispj-2        ;   decided: BRA ?portalw for a portal, BIT #
	; --- SOLID: wall pyc..pyf, floor pyf+1..bot ---
	rep #$20
	.LONGA ON
        lda rs_pyf16
        sta rs_rb
        lda rs_pyc16                 ; ...and A keeps pyc16 for the peg row
        sta rs_ra                    ;   (2026-09-15: no reload)

?twj    bit #?txw_solid-?twj-2       ; B2: textured wall if a texture is set --
                                     ;   BRA ?txw_solid when not (patched at ?twt)

        sta rs_pegrow                ; top-peg at the ceiling
	sep #$20
	.LONGA OFF
                                     ; (the peg shift rs_vshw: paint_col reads it
        jsr wall_src                 ;   by tx_slot, 2026-09-29 -- no copy per column)
                                      ; wall_src tail-calls draw_twall_clip (2026-09-15)
	bra ?txw_done
?sfx    sep #$20                     ; (the floor's rare exits, out of line)
        bra ?sclose
?sft    sep #$20
?sft8   lda rs_top
        bra ?sfs
?txw_solid
	sep #$20
	.LONGA OFF
        lda rs_wallcol
        xba                          ; colour -> B for pt_span (2026-09-22)
        jsr draw_clip
?txw_done
                                      ; floor, draw_clip.dc_floor INLINED: a = pyf16+1
	rep #$20                     ;   clipped to [top, bot] on the word it is, b =
	.LONGA ON                    ;   bot; rs_ra/rs_spa are not written (no reader)
        lda rs_pyf16
	inc
        bmi ?sft                     ; a < 0 -> top
        cmp #$0100
        bcs ?sfx                     ; a >= 256: below every window
	sep #$20
	.LONGA OFF
        cmp rs_top
        bcc ?sft8
        cmp rs_bot
        beq ?sfs
        bcs ?sclose                  ; a > bot: no floor
?sfs    eor #$FF                     ; rows-1 = bot - a: ~a + bot + 1, a <= bot
        sec
        adc rs_bot
        tay
        lda rs_floorcol
        xba                          ; colour -> B
        ldx rs_bot                   ; 2026-09-28: the span's LAST row, in X already
        jsr pt_span.px               ;   (pt_span gives X = the column back)
?sclose lda #1                       ; the column closes (a shut portal joins here
        sta solid_arr,x              ;   from ?pclj). cm_save inlined: cm_solid/
        sta cm_solid                 ;   cm_nt/cm_nb take what the column now holds
        dec cols_open
        bne ?sclo
        sta frame_done
?sclo   jsr sscl_col                 ; a CLOSED column: the wall's scale AT it ->
        jmp ?psave                   ;   SSCL and cm_nt/cm_nb; ytopc/ybotc keep the
                                     ;   window it closed (sprites.asm ?snap, spr_ncut)

?portalw ; --- PORTAL: see-through window + upper/lower steps ---
	rep #$20
	.LONGA ON
                                      ; 2026-09-22: rs_pybc16/rs_pybf16 are aliases of
                                     ;   rs_ybcacc+1 / rs_ybfacc+1 now -- no copy
        lda rs_top                   ; nt16 = max(top, pyc16): a negative pyc16
        and #$00FF                   ;   (its high byte's bit 7, read into Y) loses
        ldy rs_pyc16+1               ;   to top; otherwise top wins iff top >= pyc16
        bmi ?ntset                   ;   (a pyc16 of 256+ beats every top). Y is
        cmp rs_pyc16                 ;   free: ldy rs_wtexid reloads it before use
        bcs ?ntset
        lda rs_pyc16
?ntset  sta rs_nt16
?ntk1   ; the upper step, pyc16 .. pybc16-1 (16-bit A from every path above)
	.LONGA ON
        lda rs_pybc16
?updec  dec                          ; SMC (?shp): nop on a shut portal, whose
        cmp rs_pyc16                 ;   row pybc16 is the step's last
	bmi ?noup                    ; not one row of it
        sta rs_rb
        lda rs_pyc16
        sta rs_ra

?tuj    bit #?txu_solid-?tuj-2       ; B2: upper step uses the wall texture --
                                     ;   BRA ?txu_solid when not (patched at ?twt)

        sta rs_pegrow                ; upper step measured from the ceiling row
	sep #$20                     ; (rs_dscr/rs_tpr stay the column's -- the texel
	.LONGA OFF
                                     ;  the linedef is not ML_DONTPEGTOP -- that is
                                     ;  the door face riding up with the door
        jsr wall_src
                                      ; (tail-calls draw_twall_clip)
	bra ?txu_done
?pft    sep #$20                     ; (the portal floor's a < top, out of line)
?pft8   lda rs_top
        bra ?pfs
?txu_solid
	sep #$20
	.LONGA OFF
        lda rs_wallcol
        xba                          ; colour -> B for pt_span (2026-09-22)
        jsr draw_clip
?txu_done
	rep #$20
	.LONGA ON
        lda rs_pybc16
        cmp rs_nt16
	bmi ?noup
	beq ?noup

        sta rs_nt16                  ; (A = pybc16 still)

                                     ; floor entry: b = rs_bot, rs_rb not written
?noup	lda rs_pyf16                 ; floor, dc_floor inlined as on the solid path
        inc
        bmi ?pft
        cmp #$0100
        bcs ?pfx
	sep #$20
	.LONGA OFF
        cmp rs_top
        bcc ?pft8
        cmp rs_bot
        beq ?pfs
        bcs ?pfx
?pfs    eor #$FF
        sec
        adc rs_bot
        tay
        lda rs_floorcol
        xba
        ldx rs_bot                   ; (2026-09-28, as ?sfs)
        jsr pt_span.px

        ; nb16 = min(bot, pyf16)
?pfx    rep #$20                     ; nb16 = min(bot, pyf16): a negative pyf16
        .LONGA ON                    ;   (sign via Y, which nothing below reads
        lda rs_bot                   ;   before reloading) is kept, otherwise bot
        and #$00FF                   ;   wins iff bot < pyf16
        ldy rs_pyf16+1
        bmi ?nbpf
        cmp rs_pyf16
        bcc ?nbset
?nbpf   lda rs_pyf16
?nbset  sta rs_nb16
?nbk1   ; the lower step, pybf16+1 .. pyf16 (still 16-bit: no rep)
	.LONGA ON
        lda rs_pyf16
        cmp rs_pybf16
	bmi ?nolo                    ; the back floor is below the front one
?loeq   beq ?nolo                    ; SMC (?shp): rep #0 on a shut portal with
        sta rs_rb                    ;   no upper step -- row pybf16 is this
        lda rs_pybf16                ;   step's first
        sta rs_pegrow                ; top-pegged at the back floor row
?loinc  inc                          ; SMC (?shp): nop there
        sta rs_ra

?tlj    bit #?txl_solid-?tlj-2       ; B2: textured lower step if a texture is set --
                                     ;   BRA ?txl_solid when not (patched at ?tlt)

	sep #$20                     ; (rs_dscr/rs_tpr stay the column's); rs_vshl
	.LONGA OFF
        jsr low_src
                                      ; low_src falls through into draw_twall_clip
	bra ?txl_done
?txl_solid
	sep #$20
	.LONGA OFF
        lda rs_lowcol
        xba                          ; colour -> B for pt_span (2026-09-22)
        jsr draw_clip
?txl_done
	rep #$20
	.LONGA ON
        lda rs_pybf16
        cmp rs_nb16
	bpl ?nolo

        sta rs_nb16                  ; (A = pybf16 still)
?nolo	lda rs_nb16                  ; nb16 - nt16 - 1 < 0  <=>  nb16 <= nt16 -> a
        clc                          ;   portal whose opening is EXACTLY zero --
        sbc rs_nt16                  ;   every shut door, back floor == back
	sep #$20                     ;   ceiling -- lands on nt16 == nb16, and the
	.LONGA OFF                   ;   strict test left it OPEN by one row (E1M4's
        bmi ?pclj                    ;   four tag-1 slits). sep keeps N.
                                      ; 2026-09-27: one word subtract, and the close
	lda rs_nt16                 ;   test BEFORE the window stores: ?sclose
        sta ytopc_arr,x              ;   rewrites all four cells anyway
        sta cm_nt                    ; (cm_save inlined, see ?psave)
        lda rs_nb16
        sta ybotc_arr,x
        sta cm_nb
        stz cm_solid                 ; open: solid_arr,x is still 0 (?col tested it)
?psave  stx cm_x                     ; cm_save inlined: this column is the run's
        rep #$21                     ;   source now (rs_top/rs_bot -> cm_top/cm_bot
        .LONGA ON                    ;   as one word); rep #$21 is ?cnext's own
        lda rs_top
        sta cm_top
?cnx16
                                      ; DRAC_PLAN 5: 32-bit cells, word arithmetic (memory_map.inc D0):
                                     ;   t1 += scaleR, t2 -= scaleL a word at a
                                     ;   time; bytes 0-2 as before, byte 3 is the
        lda rs_t1                    ;   cell's padding and nobody reads it
?sutr   adc #0                       ; + rs_utR (patched per seg, above ?col)
        sta rs_t1
        bcs ?t1c                     ; the top word takes the carry alone (16-bit
?t1nc   lda rs_t2                    ;   inc/dec out of line at ?t1c/?t2b: the
                                     ;   common no-carry case falls through)
?sutl   sbc #0                       ; 2026-09-27: C = 0 here, so `sbc #utL-1`
        sta rs_t2                    ;   (`cmp #0` for utL = 0), patched at ?ststep
        bcc ?t2b
?t2nb
        .LONGA OFF                   ; still 16-bit at run time: the accumulator

        ; advance front accumulators (24-bit += signed16 step)
;
; WARNING: self-modifying code
;
                                      ; 2026-09-27: no clc/sec in this chain -- each add
	.LONGA ON                    ;   meets a known carry and its immediate is
        lda rs_ycacc                 ;   step-cin (?ststep); the stubs' patched
?syc    adc #0                       ;   clc/sec keep the rare path's C the same
        sta rs_ycacc
                                      ; 2026-09-22 (drac030-review "control flow"): the
?ycadd	bcs ?ycoo                    ;   carry step is the RARE case, so it lives out
?ycdone
        lda rs_yfacc
?syf    adc #0                       ; + rs_yfS - cin (patched per seg)
        sta rs_yfacc
?yfadd	bcs ?yfoo                    ; (as ?ycadd)
?yfdone
                                      ; 2026-09-22: back accumulators only for portals,
?ispk   bit #?adv_done-?ispk-2       ;   patched per seg: BRA ?adv_done on a solid wall
        lda rs_ybcacc
?sybc   adc #0                       ; + rs_ybcS - cin (patched per seg)
        sta rs_ybcacc
?bcadd  bcs ?bcoo                    ; (as ?ycadd)
?bcdone
        lda rs_ybfacc
?sybf   adc #0                       ; + rs_ybfS - cin (patched per seg)
        sta rs_ybfacc
?bfadd  bcs ?bfoo                    ; (as ?ycadd)
?bfdone
?adv_done
    .if TEX_RUNS
        ; pt_step INLINED (2026-09-14): rpt += drpt for EVERY column, drawn or
        ; skipped -- it tracks the plane accumulators above, not the drawing.
        lda rs_rptf
?sdr0   adc #0                       ; + rs_drpt - cin (patched per seg)
        sta rs_rptf
        lda rs_rptf+2
?sdr2   adc #0                       ; + rs_drpt+2, the word (patched per seg)
        sta rs_rptf+2
    .endif
	sep #$20
	.LONGA OFF
?cxb    cpx #0                       ; zp_xb, PATCHED per seg (2026-09-27, ?ststep)
        beq ?done2
        inx
        jmp ?col
?pclj   jmp ?sclose                  ; a shut portal closes the column (rare)
?done2  jmp cm_flush                 ; tail-call: copy the last pending run
                                      ; 2026-09-22: ?cnext's carry steps, out of line.
        .LONGA ON                    ;   Reached in 16-bit M (no immediates here), 8-bit
?ycoo   ldy rs_ycacc+2               ;   Y. ?xxinc + the byte after it are ONE per-seg
?ycinc  iny                          ;   word patch (?ststep, 2026-09-27): iny/clc on a
        clc                          ;   positive step, dey/sec on a negative one --
        sty rs_ycacc+2               ;   the common path's carry out
        bra ?ycdone
?yfoo   ldy rs_yfacc+2
?yfinc  iny
        clc
        sty rs_yfacc+2
        bra ?yfdone
?bcoo   ldy rs_ybcacc+2
?bcinc  iny
        clc
        sty rs_ybcacc+2
        bra ?bcdone
?bfoo   ldy rs_ybfacc+2
?bfinc  iny
        clc
        sty rs_ybfacc+2
        bra ?bfdone
?t1c    inc rs_t1+2                  ; (16-bit M: the word inc IS adc #0 with C=1)
        clc                          ; 2026-09-27: ?t1nc's common path has C = 0
        bra ?t1nc
?t2b    dec rs_t2+2
        sec                          ; 2026-09-27: ?t2nb's common path has C = 1
        bra ?t2nb
        .LONGA OFF
.endp
        .endseg
