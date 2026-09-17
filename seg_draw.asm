; AUTO-SPLIT from renderer.asm 2026-07-24 -- assembled in place via icl (verified
; byte-identical). renderer.asm keeps the BSP walk; this file draws ONE seg:
;   load_vertex / plane_setup / draw_span / draw_clip / process_seg
; process_seg is the big one (per-seg setup, then the per-column loop with the
; ceiling, wall, upper/lower step and floor draw sites).
;--------------------------------------------------------------
; load_vertex -- zp_vidx -> zp_rx,zp_ry = vertex - player.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc load_vertex
        ; ONE 16-bit accumulator, whole proc (2026-08-31, _an_drac030): the old
        ; body shifted the pointer half in A and half IN MEMORY (asl zp_vptr /
        ; rol zp_vptr+1), added in bytes and read the vertex in four 8-bit
        ; halves -- ~110 cycles at 199 calls/frame. Bit-identical: <<2, the
        ; add and both subtracts wrap the same 16 bits, and a 16-bit
        ; [zp_vptr],y at y=0/2 reads the same little-endian pairs. Internal
        ; rep/sep because the automap's two call sites are 8-bit code
        ; (process_seg's two are 16-bit either side and just pay the toggle).
        ; Y exits 2, not 3 -- no caller reads Y after (am_draw reloads X,
        ; process_seg reloads Y).
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
 .if 1
        sec
        lda [zp_vptr]
 .else
        ldy #0
        sec
        lda [zp_vptr],y
 .endif
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
;   Shift-and-subtract, 8 fixed steps -- no divide, and it runs once per seg,
;   not per column. Vertical texels are 1:1 with world units in DOOM, so the
;   whole peg difference IS this distance.
;   Parked at VSH_BASE ($267F): the $2000 engine segment is full to $3FFF, so a
;   new proc there pushes the tail into the streamed map slot at $4000.
;--------------------------------------------------------------
vsh_resume = *
        org VSH_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vsh_neg
        sta rs_vsht                  ; keep texH
        jsr vsh_mod
        beq ?zero                    ; already aligned -> no shift
        sta m_b
        sec
        lda rs_vsht
        sbc m_b
        rts
?zero   lda #0
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc vsh_mod
        rep #$20                     ; m_b = texH << 7 (fits: 255<<7 = 32640) --
        .LONGA ON                    ;   in the accumulator, not the old ldx #7
        and #$FF                     ;   loop of asl/rol ON m_b (~98 cycles of
 .if 1
	xba
	lsr
 .else
        asl @                        ;   memory RMW for what seven 2-cycle
        asl @                        ;   shifts do; _an_drac030 2026-08-31).
        asl @                        ;   `and #$FF`: rep exposes whatever the
        asl @                        ;   8-bit caller left in B.
        asl @
        asl @
        asl @
 .endif
	sta m_b
 .if 1
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
 .else
        .LONGA OFF
        sep #$20

        ldx #8                       ; subtract texH<<7 .. texH<<0 where it fits
?l      sec
        lda m_a
        sbc m_b
        tay
        lda m_a+1
        sbc m_b+1
        bcc ?next
        sty m_a
        sta m_a+1
?next   lsr m_b+1
        ror m_b
        dex
        bne ?l
 .endif
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
;   Only ~6 % of E1M1's segs carry a rowoffset, and a byte per seg does not fit
;   the map slot, so the .bin has a BITMAP (one bit per seg) plus a side table:
;   the common answer costs a shift chain and one AND, the rest a short scan.
;   Parked at SEGYOFF_BASE ($0F58) -- the $2000 engine segment is full.
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
 .if 1
	bra ?bit
 .else
        jmp ?bit
 .endif
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
;
;   WHY: rs_t1/rs_t2 are 24-bit and their init keeps only m_prod[0..2] -- the
;   top byte of the 32-bit product is dropped. The product is max(scale)*span,
;   and both factors peak in the same situation: the player standing IN a wall
;   corner. Z collapses to ZNEAR, so the scale is at its maximum, and the two
;   endpoints saturate to opposite sides, so the span is the whole screen.
;   Measured at 312 % of 2^24 there (tools/_verify_corner.py, 67 overflows;
;   13 of them at the stair corners behind the first door in E1M1). The wrap
;   makes the texture u nonsense for the whole seg -- the flat-looking slab of
;   wall that flashes in for a frame.
;
;   It survived every earlier audit because they all sweep THING positions,
;   which are never jammed against a wall: _verify_ovf.py peaks at 39 % there
;   and reports zero overflows. Its own docstring called this hazard "never
;   measured" and left the guard out.
;
;   Halving BOTH scales is EXACT for u: calc_u wants t1/(t1+t2), a ratio, and
;   these two values are also its per-column steps. The y-tracks (wall heights)
;   deliberately keep the unshifted rs_scL/rs_scR -- they are built by
;   plane_setup below and need the precision.
;   Clobbers A/X, m_a, m_b, m_prod (m_prod is dead here: the caller's
;   m_prod+1/+2 setup is overwritten by the very next umul16).
;--------------------------------------------------------------
ug_resume = *
        org UGUARD_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc u_guard
 .if 1
	rep #$20
	.LONGA ON
        lda rs_scR                   ; start from the real scales -- scL last,
        sta rs_utR                   ;   so A holds it for the compare
        lda rs_scL                   ;   (2026-09-15: one reload fewer)
        sta rs_utL
	cmp rs_scR
	bcc ?r_is_max
	sta m_b
	lda rs_scR
	sta rs_sscl
	bra ?havesc
?r_is_max
	sta rs_sscl
	lda rs_scR
	sta m_b
?havesc
	lda rs_span		;rs_span = rs_sxR - rs_sxL
	sta m_a
	sep #$20
	.LONGA OFF
 .else
        lda rs_scL                   ; start from the real scales
        sta rs_utL
        lda rs_scL+1
        sta rs_utL+1
        lda rs_scR
        sta rs_utR
        lda rs_scR+1
        sta rs_utR+1

        lda rs_scL                   ; m_b = max(scL, scR)
        ldx rs_scL+1
        cpx rs_scR+1
        bcc ?big
        bne ?have
        cmp rs_scR
        bcs ?have
?big    lda rs_scR
        ldx rs_scR+1
?have   sta m_b
        stx m_b+1
        jsr seg_scl                  ; ...and while both scales are to hand, the
                                     ;   sprite clip's copy (clobbers Y)
        sec                          ; m_a = span = sxR - sxL (>= 0 by order)
        lda rs_sxR
        sbc rs_sxL
        sta m_a
        lda rs_sxR+1
        sbc rs_sxL+1
        sta m_a+1
 .endif
        jsr umul16                   ; m_prod(32) = max_scale * span

?sh     lda m_prod+3                 ; top byte set -> >= 2^24: halve and retry
        beq ?done
 .if 1
	rep #$20
	.LONGA ON
	lsr m_prod+2
	ror m_prod
        lsr rs_utR
        lsr rs_utL
	sep #$20
	.LONGA OFF
	bra ?sh
 .else
        lsr m_prod+3
        ror m_prod+2
        ror m_prod+1
        ror m_prod
        lsr rs_utR+1
        ror rs_utR
        lsr rs_utL+1
        ror rs_utL
        jmp ?sh
 .endif
?done   rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_ncut -- THE CLIP THE SPRITE SNAPSHOT CANNOT SEE (r_things.c R_DrawSprite).
;   C=1 if screen column sp_col is now closed by geometry NEARER than sp_scale,
;   i.e. the sprite must not be drawn there. Clobbers A/X.
;
; spr_add snapshots the occlusion the walk had built when the sprite's SUBSECTOR
; was reached, and the header of sprites.asm argues that is enough because the
; walk is front-to-back. It is enough for anything INSIDE that subsector -- but a
; billboard is not. It stands across the partition planes, so a wall whose
; subsector the walk reaches LATER can still be in front of part of it. E1M5,
; from the corridor at (187,358): the walk goes ss173 -> ss180 -> ss179 -> ss153,
; ss173's ld13 closes columns 0..55, and the secret closet's shotgun (ss180,
; columns 20..73) keeps 56..73 open -- the columns ld12 covers, and ld12 belongs
; to ss153, which is walked four subsectors later because it sits on the far side
; of the y=352 partition while the THING sits on the near side.
;
; DOOM answers this with drawsegs: R_DrawSprite walks every drawseg and clips
; where `max(ds->scale1, ds->scale2) > spr->scale`. There is no RAM here for a
; drawseg list and none is needed -- a CLOSED column needs neither ytopc nor
; ybotc any more (every reader tests solid_arr first), so u_guard's max-scale
; rides in those two bytes and the same test is one 16-bit compare, per COLUMN
; rather than per drawseg.
;--------------------------------------------------------------
    .if * > UGUARD_END+1
        ert 'u_guard outgrew UGUARD_BASE..END (memory_map.inc)'
    .endif

        org SEGSCL_BASE
;--------------------------------------------------------------
; seg_scl -- rs_sscl = min(rs_scL, rs_scR), for the sprite clip. Clobbers A/Y.
;
; WHY THE MINIMUM and not DOOM's `scale = max(scale1, scale2)`. R_DrawSprite
; takes the max, but it then has a second clause this port cannot afford:
;   if (scale < spr->scale || (lowscale < spr->scale && !R_PointOnSegSide(...)))
;       continue;                      // seg is behind sprite
; -- when the seg STRADDLES the sprite in depth, DOOM decides by which side of
; the seg's line the sprite is on. Without that side test, the max alone
; over-clips: a seg running away from the viewer (E1M5's ld315 seen from inside
; the closet, 65 units at one end and 150 at the other) would cut a sprite at
; 122 units across its whole span, including the half where the wall is further
; away than the sprite. Taking the minimum is DOOM's condition MINUS the side
; test, i.e. strictly more conservative: it never clips a sprite the original
; would draw, and it still clips every case where the whole seg is in front --
; which is the one this exists for.
;--------------------------------------------------------------
 .if 1
	;nothing
 .else
.proc seg_scl
        ldy #0                       ; y = 0 -> scL is the nearer end
 .if 1
	rep #$20
	.LONGA ON
        lda rs_scL
        cmp rs_scR
	bcc ?have
	ldy #2
?have	lda rs_scL,y
        sta rs_sscl
	sep #$20
	.LONGA OFF
 .else
        lda rs_scL
        cmp rs_scR
        lda rs_scL+1
        sbc rs_scR+1
        bcc ?have                    ; scL < scR -> scL IS the minimum
        ldy #2
?have   lda rs_scL,y                 ; (rs_scR = rs_scL+2)
        sta rs_sscl
        lda rs_scL+1,y
        sta rs_sscl+1
 .endif
        rts
.endp
    .if * > SEGSCL_END+1
        ert 'seg_scl outgrew SEGSCL_BASE..END (memory_map.inc)'
    .endif
 .endif

 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SPRNCUT_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_ncut
        ldx sp_col
        lda solid_arr,x
        beq ?open                    ; still open -> only the snapshot applies
        lda ytopc_arr,x              ; the scale of whatever closed this column
        cmp sp_scale
        lda ybotc_arr,x
        sbc sp_scale+1
        bcc ?open                    ; that wall is FARTHER -> the sprite covers it
        lda #255                     ; nearer -> the same "no window" the snapshot
        sta sp_t                     ;   writes, so spr_one's own test skips it
?open   rts
.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SPRNCUT_END+1
        ert 'spr_ncut outgrew SPRNCUT_BASE..END (memory_map.inc)'
    .endif
 .endif

;--------------------------------------------------------------
; cm_sscl -- the seg side of the same test: hand a column this seg's scale as it
;   closes. Two entries: cm_sscl2 for the SOLID path (the column is closed by
;   definition), cm_sscl for the PORTAL path (it closes only when the opening
;   collapsed). Both then fall into cm_save, which they replace at the call
;   site -- so process_seg's segment does not grow by a single byte, and there
;   is none to give.
;--------------------------------------------------------------
        org CMSSCL_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cm_sscl
        lda solid_arr,x
        beq ?done
cm_sscl2
        lda rs_sscl                  ; a CLOSED column needs neither ytopc nor
        sta ytopc_arr,x              ;   ybotc again (every reader tests
        lda rs_sscl+1                ;   solid_arr first), so they carry the
        sta ybotc_arr,x              ;   scale for spr_ncut
?done   jmp cm_save
.endp
        .endseg
    .if * > CMSSCL_END+1
        ert 'cm_sscl outgrew CMSSCL_BASE..END (memory_map.inc)'
    .endif
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
plane_setup16                        ; ENTRY (2026-09-15): 16-bit A = rs_wtmp, the
        sta m_a                      ;   caller having just stored it
        lda rs_scL
        sta m_b
        .LONGA OFF
        sep #$20
        jsr track_calc
        rep #$20
        .LONGA ON
        lda m_prod
        sta rs_Ltmp
        lda m_prod+1
        sta rs_Ltmp+1
        lda rs_wtmp                  ; R = trk(world, scR) (left in m_prod)
        sta m_a
        lda rs_scR
        sta m_b
        .LONGA OFF
        sep #$20
        jsr track_calc
        rep #$20
        .LONGA ON
 .if 1
        lda m_prod+1                 ; keep R: it is the RIGHT-hand anchor below,
        sta rs_acctmp+1              ;   and rs_acctmp is free until we write the
        lda m_prod                   ;   answer into it
        sta rs_acctmp
        sec                          ; step = (R - L) / span
        sbc rs_Ltmp
        sta m_prod
 .else
        lda m_prod                   ; keep R: it is the RIGHT-hand anchor below,
        sta rs_acctmp                ;   and rs_acctmp is free until we write the
        lda m_prod+1                 ;   answer into it
        sta rs_acctmp+1
        sec                          ; step = (R - L) / span
        lda rs_acctmp
        sbc rs_Ltmp
        sta m_prod
 .endif
        .LONGA OFF
        sep #$20
        lda rs_acctmp+2              ; ...and the 24-bit borrow's top byte
        sbc rs_Ltmp+2
        sta m_prod+2
        jsr step_recip               ; step = (R-L)/span via inv_span reciprocal
        rep #$20
        .LONGA ON
        lda m_quot
        sta rs_Stmp
 .if 1                                ; DRAC_PLAN 5: no 8-bit window: dR = sxR - xa as
        lda zp_xa                    ;   sxR + ~xa + 1 (sec). xa is one zero-page
        and #$00FF                   ;   byte, so it is masked, not widened; the
        eor #$FFFF                   ;   carry out is sbc's "no borrow" and the
        sec                          ;   next line reloads everything anyway
        adc rs_sxR
        sta rs_mag                   ; (rs_mag+2 is not written, as before)
 .else
        .LONGA OFF
        sep #$20
        ; --- acc at xa, anchored on whichever END IS NEARER ------------------
        ; step is truncated to 1/256 px, so the anchor's error is multiplied by
        ; the distance to it. Anchoring always on the left cost up to 21 px on a
        ; seg that runs past the player (its sxL is thousands of columns off the
        ; screen) -- the "left wall shoots out into the room" artefact. From the
        ; nearer end the multiplier is at most the seg's on-screen width, so the
        ; worst case drops to half a pixel (tools/_verify_planeacc.py).
        sec                          ; dR = sxR - xa, into step_recip's own
        lda rs_sxR                   ;   scratch (dead the moment it returned)
        sbc zp_xa
        sta rs_mag
        lda rs_sxR+1
        sbc #0
        sta rs_mag+1
 .endif
 .if 1
	lda zp_xa                    ; (still 16-bit from the block above: the rep
	.LONGA ON                    ;  that stood here was a second one, 2026-09-15)
        sec                          ; dL = xa - sxL
	and #$00ff
	sbc rs_sxL
	sta m_a
	cmp rs_mag
	bmi ?fromL

	lda rs_mag
	sta m_a
 .else
        sec                          ; dL = xa - sxL
        lda zp_xa
        sbc rs_sxL
        sta m_a
        lda #0
        sbc rs_sxL+1
        sta m_a+1

        sec                          ; dL < dR -> the left end is nearer
        lda m_a
        sbc rs_mag
        lda m_a+1
        sbc rs_mag+1
        bmi ?fromL

        lda rs_mag                   ; --- from the RIGHT: acc = R - dR*step ---
        sta m_a
        lda rs_mag+1
        sta m_a+1
 .endif
        jsr ?mulstep		;this switches off 16-bit accumulator
	.LONGA OFF

        rep #$20                     ; rs_acctmp -= m_prod, 24-bit: the low word
        .LONGA ON                    ;   in one subtract (drac030, 2026-09-14)
        sec
        lda rs_acctmp                ; (rs_acctmp still holds R)
        sbc m_prod
        sta rs_acctmp
        .LONGA OFF
        sep #$20
        lda rs_acctmp+2
        sbc m_prod+2
        sta rs_acctmp+2

        rts

?fromL  jsr ?mulstep                 ; --- from the LEFT: acc = L + dL*step ---
 .if 1
	rep #$21
	.LONGA ON
        lda rs_Ltmp
        adc m_prod
        sta rs_acctmp
	sep #$20
	.LONGA OFF
 .else
        clc
        lda rs_Ltmp
        adc m_prod
        sta rs_acctmp
        lda rs_Ltmp+1
        adc m_prod+1
        sta rs_acctmp+1
 .endif
        lda rs_Ltmp+2
        adc m_prod+2
        sta rs_acctmp+2

        rts

 .if 1
	.LONGA ON
?mulstep
	lda rs_Stmp
	sta m_b
	sep #$20
	.LONGA OFF
 .else 
?mulstep lda rs_Stmp                 ; m_prod = m_a * step (signed)
        sta m_b
        lda rs_Stmp+1
        sta m_b+1
 .endif
        jmp smul32
.endp
        .endseg

;--------------------------------------------------------------
; draw_span -- vertical span rows rs_spa..rs_spb, colour zp_color, column
;   zp_col. Draws via draw_vspan only if rs_spb >= rs_spa. Preserves X.
;   Parked in the row_lo/TWCHAIN hole: this segment ends at $3FFB, four bytes
;   below the streamed map, and the view-size code needed those bytes back. The
;   hole is fast RAM like the segment it came from, so it costs nothing.
;--------------------------------------------------------------
ds_resume = *
        org DRAWSPAN_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc draw_span
        sec                          ; A = rs_spb already: draw_clip's ?bset
        sbc rs_spa                   ;   store is the ONLY way in, and sbc's
        bcc ?no                      ;   carry is the cmp's carry (A dies at ?no)
        tay
        iny                          ; height = spb-spa+1 (no inc a on 6502)
        lda rs_spa
    .if TEX_RUNS
        jmp pt_span                  ; tail-call: the flat span becomes a chain
                                     ;   link like every painted run (paint.asm)
    .else
        jmp draw_vspan               ; tail-call: draw_vspan's own rts returns to
                                     ;   draw_span's caller (draw_clip already
                                     ;   tail-calls into here). 12 cycles a span.
    .endif
?no     rts
.endp
        .endseg
    .if * > DRAWSPAN_END+1
        ert 'draw_span outgrew DRAWSPAN_BASE..END (memory_map.inc)'
    .endif
        org ds_resume

;--------------------------------------------------------------
; draw_clip -- span with RAW signed16 endpoints rs_ra (start) / rs_rb (end),
;   clipped to the window [rs_top,rs_bot]: a=max(rs_ra,top), b=min(rs_rb,bot);
;   draws if b>=a. Mirrors render_view's col(x, max(a,top), min(b,bot)).
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
?aset   sta rs_spa
        lda rs_rb+1                  ; b = min(rs_rb, bot); <top -> nothing
        bmi ?out
        bne ?bbot
        lda rs_rb
        cmp rs_top
        bcc ?out
        cmp rs_bot
        bcc ?bset                    ; same as above -- A is still rs_rb, and
        beq ?bset                    ;   ?bbot now FALLS THROUGH to ?bset
?bbot   lda rs_bot
?bset   sta rs_spb
        jmp draw_span                ; tail-call (draws if spb>=spa, preserves
                                     ;   X) -- and hands it rs_spb IN A
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; sky_clip -- draw_clip for an F_SKY1 ceiling (2026-09-16, "v original doome je
;   tam nejake pozadie"). r_plane.c R_DrawPlanes (396) paints a sky ceiling with
;   a SCREEN-FIXED texture, not a flat: column (viewangle + xtoviewangle[x]) >> 22
;   of SKY1-3 (256 wide, four tiles a turn), row skytexturemid 100 +
;   (y - centery) * pspriteiscale, full bright. Here:
;     stored column = (zp_ang*2 + off[x']) & 127   pack_sky.py keeps every other
;       source column and zp_ang is the 8-bit BAM, so viewangle>>22 = zp_ang*4
;     x' = 80 + ((x - 80) << vw_sh)   the full-view column this window column is
;     texel = (100 + ((row - 84) << vw_sh)) & 127   84 is the horizon (HHFP) of
;       every vw_tab window; the shift is pspriteiscale at the /2 and /4 sizes
;       (the 3/4 and 3/8 sizes take the next size up, as draw_weapon does)
;   The column is the wall painter's 64-byte run record (pack_sky.py), walked
;   from the run that holds the first texel; each run's rows go out through
;   pt_span as one chain link in the raw palette index -- the sky is not shaded.
;   IN/OUT as draw_clip: rs_ra/rs_rb raw rows, rs_top/rs_bot the window,
;   pc_colw the column (pt_span), X = the column and preserved. Clobbers A, Y and
;   m_a/m_b/m_prod: pt_span and ptc_fire touch none of them, and nothing in the
;   column loop carries them past the ceiling (wall_src and paint_col start
;   from rs_*).
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
?aset   sta rs_spa
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
                                     ;   version bsp_main checks). X is free until
                                     ;   the run walk's ldx #0.
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
        sta zp_color
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
        tay
        lda m_a+1                    ; A = top row, Y = rows
        jsr pt_span                  ; one chain link; keeps X
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
;--------------------------------------------------------------
; vc_look -- IN (16-bit A): a vertex index. OUT: C=1 and zp_X/zp_Z loaded when
;   this frame already transformed that vertex, C=0 otherwise (vc_key set for
;   vc_store). Clobbers A, X. Enters and leaves in 16-bit A. memory_map.inc
;   VCACHE_*: 256 direct-mapped slots (index & $FF), tag = index high byte,
;   valid while STAMP == vc_frame (render_world bumps it; a wrap clears them).
; vc_store -- after transform: zp_X/zp_Z -> the slot vc_key names, stamped.
;--------------------------------------------------------------
.proc vc_look
        .LONGA ON
        sta vc_key
        .LONGA OFF
        sep #$20
        ldx vc_key                   ; slot = index & $FF (the tag's low byte)
        lda.l VCACHE_BASE+VC_TAGH,x
        cmp vc_key+1
        bne ?miss
        lda.l VCACHE_BASE+VC_STAMP,x
        cmp vc_frame
        bne ?miss
        lda.l VCACHE_BASE+VC_XL,x
        sta zp_X
        lda.l VCACHE_BASE+VC_XH,x
        sta zp_X+1
        lda.l VCACHE_BASE+VC_ZL,x
        sta zp_Z
        lda.l VCACHE_BASE+VC_ZH,x
        sta zp_Z+1
        rep #$20
        .LONGA ON
        sec
        rts
?miss   rep #$20
        .LONGA ON
        clc
        rts
.endp
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
        ; --- THE WHOLE PROLOGUE IS 16-BIT (2026-08-29). Every quantity here is
        ;     a 16-bit coordinate, and the engine already runs in 65816 NATIVE
        ;     mode (underrom.asm's ROM-OUT <=> native invariant), so a block of
        ;     them costs `rep #$20`/`sep #$20` = 6 cycles and no clc/xce. That
        ;     turns a vertex index into ONE [zp_sptr],y, a coordinate save into
        ;     ONE lda/sta, and a 16-bit subtract into one sec/lda/sbc/sta --
        ;     204 cycles and 337 bytes a call over the whole .proc, at 102
        ;     calls a frame (_bench_subsys, tools/tests/_probe_16bit.py).
        ;     M ONLY. X and Y stay 8-bit for the reason sound.asm:316 records:
        ;     the 3958 Hz digi IRQ inherits M/X, and `sep #$10` zeroes the high
        ;     halves of X/Y while the RTI restores only the width bits.
        ;     load_vertex, cross_pos and transform are 8-bit code, so the mode
        ;     goes back before every call.
        rep #$20                     ; ---- 16-bit A
        .LONGA ON                    ;   (and TELL MADS: an immediate is 3 B now)
 .if 1
        lda [zp_sptr]
 .else
        ldy #0                       ; v1
        lda [zp_sptr],y
 .endif
 .if 1
        sta zp_vidx                  ; load_vertex INLINED (2026-09-15), still
        asl @                        ;   16-bit: no sep/jsr/rep/rts and no reload
        asl @                        ;   of zp_vidx or zp_rx/zp_ry. Vertex index
        adc #MAP_VERTS               ;   * 4 (the asl's carry out is 0: the index
        sta zp_vptr                  ;   is < 16384) + MAP_VERTS; zp_vptr+2 =
        sec                          ;   MAP_EXT_BANK, set once by init_level
        lda [zp_vptr]
        sbc zp_px
        sta zp_rx
        sta zp_rx1
        ldy #2
        sec
        lda [zp_vptr],y
        sbc zp_py
        sta zp_ry
        sta zp_ry1
 .else
        sta zp_vidx
        .LONGA OFF
        sep #$20
        jsr load_vertex
        rep #$20
        .LONGA ON
        lda zp_rx
        sta zp_rx1
        lda zp_ry
        sta zp_ry1
 .endif
        ldy #2                       ; v2
        lda [zp_sptr],y
 .if 1
        sta zp_vidx                  ; load_vertex INLINED (2026-09-15), still
        asl @                        ;   16-bit: no sep/jsr/rep/rts and no reload
        asl @                        ;   of zp_vidx or zp_rx/zp_ry. Vertex index
        adc #MAP_VERTS               ;   * 4 (the asl's carry out is 0: the index
        sta zp_vptr                  ;   is < 16384) + MAP_VERTS; zp_vptr+2 =
        sec                          ;   MAP_EXT_BANK, set once by init_level
        lda [zp_vptr]
        sbc zp_px
        sta zp_rx
        sta zp_rx2
        ldy #2
        sec
        lda [zp_vptr],y
        sbc zp_py
        sta zp_ry
        sta zp_ry2
 .else
        sta zp_vidx
        .LONGA OFF
        sep #$20
        jsr load_vertex
        rep #$20
        .LONGA ON
        lda zp_rx
        sta zp_rx2
        lda zp_ry
        sta zp_ry2
 .endif
        ; --- backface FIRST. It only needs the PLAYER-RELATIVE coords, never the
        ;     rotated ones, so testing it here skips the two transforms (~700 cyc)
        ;     for every backfaced seg -- and on E1M1 that is 46% of every frame's
        ;     segs (tools/_speed_model.py: 783 transforms -> 391).
        ; --- backface: cx_a=rx2-rx1, cx_b=-ry1, cx_c=ry2-ry1, cx_d=-rx1 ---
        sec
        lda zp_rx2
        sbc zp_rx1
        sta cx_a
        sec
        lda #0
        sbc zp_ry1
        sta cx_b
        sec
        lda zp_ry2
        sbc zp_ry1
        sta cx_c
        sec
        lda #0
        sbc zp_rx1
        sta cx_d
        ; --- tips #2, now for SEGS: axis-aligned fast path. When the seg is axis
        ;     aligned one cross term is ZERO, so the sign of the cross is a
        ;     sign-bit XOR and BOTH smul32 calls vanish. point_on_side has had
        ;     this since tips #2 ("74% of DOOM nodes -> no smul32",
        ;     renderer.asm); this test never got it and paid 2 smul32 for EVERY
        ;     seg the walk visits, EVERY frame -- turning or not.
        ;     cx_a = v2.x-v1.x and cx_c = v2.y-v1.y (the player cancels), so
        ;     "axis aligned" is a property of the seg, and 75.4% of episode 1
        ;     qualifies -- measured off the WAD, per map, by tools/_verify_bfaxis.py.
        ;     That tool also proves the path bit-identical to cross_pos on every
        ;     case it fires for: 410K synthetic (the $8000/0/+-1/quadrant
        ;     corners) + 429,640 real seg x pose cases, 0 mismatches. It compares
        ;     against cross_pos AS IMPLEMENTED, not against ideal math -- read the
        ;     tool header for why that distinction is the whole point.
        lda cx_a                     ; (16-bit: the ora of the two halves the
        bne ?bf_tryc                 ;   8-bit version needed IS the load now)
        lda cx_c                     ; cx_a = 0 -> cross = -(cx_c*cx_d)
        beq ?bf_front                ;   a zero factor -> cross = 0 -> front
        lda cx_d
        beq ?bf_front
        lda cx_c                     ;   cross > 0 iff the signs DIFFER -- and
        eor cx_d                     ;   bit 15 of a 16-bit eor is the same
        bmi ?bf_far                  ;   answer bit 7 of the high bytes gave
        bpl ?bf_front                ; (always: the sign was just tested)
?bf_tryc
        lda cx_c
        bne ?bf_gen                  ; neither axis -> pay for the full cross
        lda cx_b                     ; cx_c = 0 -> cross = cx_a*cx_b (cx_a != 0)
        beq ?bf_front
        lda cx_a                     ;   cross > 0 iff the signs are the SAME
        eor cx_b
        bpl ?bf_far
        bmi ?bf_front                ; (always)
?bf_far .LONGA OFF
        sep #$20                     ; ---- every exit leaves 8-bit. ?bfout is an
        jmp ?bfout                   ;   rts and cross_pos is 8-bit code.
?bf_gen
        sep #$20
        jsr cross_pos
        bne ?bfout                   ; cross>0 -> backface: not a single multiply
                                     ;   spent on the view transform below
        rep #$20                     ; front-facing after all: back to 16 bits,
        .LONGA ON
                                     ;   which is how the axis-aligned exits
                                     ;   above arrive (rep/sep touch only M --
                                     ;   the Z the bne just read survives)
?bf_front
        ; --- front-facing: NOW pay for the view transform of both endpoints.
        ;     Eight 16-bit copies, so eight `rep #$20` moves instead of sixteen
        ;     lda/sta pairs -- 48 bytes and 32 cycles a call, and process_seg
        ;     runs 102 times a frame. transform is 8-bit code, so the mode goes
        ;     back before each call; M only, never X/Y (see cm_save's note).
        ;     Entered ALREADY 16-bit -- see the backface exits above.
        ; VERTEX CACHE (2026-09-14): the same vertex transforms to the same
        ; (X,Z) all frame long and segs share vertices -- vc_look answers out
        ; of the per-frame cache, vc_store fills it (see the procs above).
        lda [zp_sptr]                ; v1's index
        jsr vc_look
        bcs ?v1hit
        lda zp_rx1
        sta zp_rx
        lda zp_ry1
        sta zp_ry
        .LONGA OFF
        sep #$20
        jsr transform
        rep #$20
        .LONGA ON
        jsr vc_store
?v1hit  lda zp_X
        sta zp_X1
        lda zp_Z
        sta zp_Z1
        ldy #2
        lda [zp_sptr],y              ; v2's index
        jsr vc_look
        bcs ?v2hit
        lda zp_rx2
        sta zp_rx
        lda zp_ry2
        sta zp_ry
        .LONGA OFF
        sep #$20
        jsr transform
        rep #$20
        .LONGA ON
        jsr vc_store
?v2hit  lda zp_X
        sta zp_X2
        lda zp_Z
        sta zp_Z2
 .if 1
	stz zp_tmp
        .LONGA OFF
        sep #$20                     ; ---- 8-bit again
 .else
        .LONGA OFF
        sep #$20                     ; ---- 8-bit again
;?front
        ; --- near-plane clip (match render_view): clip a behind-near endpoint
        ;     to Z=ZNEAR (keep the seg); drop ONLY if both endpoints are behind.
        ;     near1/near2 flags in zp_tmp/zp_tmp+1 (free until draw_vspan). ---
        lda #0
        sta zp_tmp
        sta zp_tmp+1
 .endif
        lda zp_Z1+1                  ; Z1 < ZNEAR ?
        bmi ?n1
        bne ?c1
        lda zp_Z1
        cmp #ZNEAR
        bcs ?c1
?n1     lda #1
        sta zp_tmp
?c1     lda zp_Z2+1                  ; Z2 < ZNEAR ?
        bmi ?n2
        bne ?c2
        lda zp_Z2
        cmp #ZNEAR
        bcs ?c2
?n2     lda #1
        sta zp_tmp+1
?c2     lda zp_tmp
        ora zp_tmp+1
        bne ?someclip
        jmp ?z2ok                    ; both >= ZNEAR -> no clip
?someclip
        lda zp_tmp
        and zp_tmp+1
        beq ?oneclip
?bfout  rts                          ; both behind near -> drop seg (and the
                                     ; backface exit lands here too)
?oneclip
        lda zp_tmp
        bne ?clip1                   ; only Z1 behind -> clip endpoint 1
        ; --- clip endpoint 2 toward endpoint 1: X2 += (X1-X2)*t ; Z2=ZNEAR ---
 .if 1
	stz m_prod
 .else
        lda #0                       ; m_prod byte 0 -- 8-bit, it is one byte
        sta m_prod
 .endif
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
        sep #$20
        jsr udiv24
        rep #$20
        .LONGA ON
        sec                          ; dX = X1 - X2
        lda zp_X1
        sbc zp_X2
        sta m_a
        lda m_quot
        sta m_b
        .LONGA OFF
        sep #$20
        jsr smul32                   ; m_prod = dX * t8
        rep #$20
        .LONGA ON
        clc                          ; X2 += m_prod>>8
        lda zp_X2
        adc m_prod+1
        sta zp_X2
        lda #ZNEAR
        sta zp_Z2
        .LONGA OFF
        sep #$20
        jmp ?z2ok
?clip1  ; --- clip endpoint 1 toward endpoint 2: X1 += (X2-X1)*t ; Z1=ZNEAR ---
 .if 1
	stz m_prod
 .else
        lda #0                       ; m_prod byte 0 -- 8-bit, it is one byte
        sta m_prod
 .endif
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
        sep #$20
        jsr udiv24
        rep #$20
        .LONGA ON
        sec                          ; dX = X2 - X1
        lda zp_X2
        sbc zp_X1
        sta m_a
        lda m_quot
        sta m_b
        .LONGA OFF
        sep #$20
        jsr smul32                   ; m_prod = dX * t8
 .if 1
	rep #$21		;absorb CLC
	.LONGA ON
 .else
        rep #$20
        .LONGA ON
        clc                          ; X1 += m_prod>>8
 .endif
        lda zp_X1
        adc m_prod+1
        sta zp_X1
        lda #ZNEAR
        sta zp_Z1
        .LONGA OFF                   ; (no sep here: ?z2ok's rep #$21 is the
?z2ok                                ;  next instruction on this path, 2026-09-14)
        ; --- CHEAP FRUSTUM REJECT (SPEED-PLAN-2 P1, at SEG level) -------------
        ; FOCAL and SCREEN_HALF are both 80, so the view is exactly 90 degrees
        ; and a view-space point is on screen iff |X| <= Z. A seg with BOTH
        ; endpoints outside the SAME frustum plane cannot touch one column --
        ; and the xa > xb test below finds that out only after two scale_z and
        ; two screenx_signed, i.e. ~2100 cycles of reciprocal lookup, 16x16
        ; multiply and 32-bit shifting. A handful of adds decides it here.
        ; STRICTLY CONSERVATIVE, so the picture cannot move: it drops only segs
        ; whose sx is < 0 (resp. >= SCREEN_WIDTH) at BOTH ends, which xa > xb
        ; drops for any view size -- vw_apply keeps [vw_x0,vw_x1] inside the
        ; screen. The sign pre-tests are not decoration either: they are what
        ; keeps X+Z / X-Z inside signed 16 bits. Z >= ZNEAR > 0 here (the near
        ; clip ran), so X >= 0 can never be left of view and X < 0 can never be
        ; right of it, and the surviving sums cannot overflow.
        ; 16-BIT (2026-08-29): the sums are the only thing this block wants and
        ; every one of them is 16 bits, so the halves, the m_a scratch and the
        ; `ora` that re-joined them all go -- a 16-bit lda sets N from bit 15
        ; and Z from all sixteen, which is exactly what the tests ask.
 .if 1
	rep #$21		;absorb CLC
        .LONGA ON
        lda zp_X1                    ; both endpoints left of the screen?
        bpl ?fr_nl                   ; X1 + Z1 < 0 ?
 .else
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        lda zp_X1                    ; both endpoints left of the screen?
        bpl ?fr_nl
        clc                          ; X1 + Z1 < 0 ?
 .endif
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
        ; Transcribes gui.py render_view (fixed). Portals (two-sided) come next;
        ; for now every seg is drawn as a solid floor->ceiling wall.
        ; --- endpoint 1: scale (1/Z) + unclamped screen-X ---
        lda zp_X1                    ; (still 16-bit, straight out of the reject)
        sta zp_X
        lda zp_Z1
        sta zp_Z
        .LONGA OFF
        sep #$20
        jsr scale_z                  ; m_quot = sc1
 .if 1
        lda m_quot                   ; (dp -> abs as bytes: 14 cycles, the lone
        sta rs_sc1                   ;   rep/sep window was 15)
        lda m_quot+1
        sta rs_sc1+1
 .else
        rep #$20
        .LONGA ON
        lda m_quot
        sta rs_sc1
        .LONGA OFF
        sep #$20
 .endif
        jsr screenx_signed           ; m_xs = sx1 (signed, unclamped)
        rep #$20
        .LONGA ON
        lda m_xs
        sta rs_sx1
        ; --- endpoint 2 --- (no sep/rep here: nothing 8-bit stood between
        ;     them, so the pair was 6 dead cycles x 102 calls -- the class
        ;     drac030 hunts by eye, 2026-08-31)
        lda zp_X2
        sta zp_X
        lda zp_Z2
        sta zp_Z
        .LONGA OFF
        sep #$20
        jsr scale_z
 .if 1
        lda m_quot                   ; (dp -> abs as bytes: 14 cycles, the lone
        sta rs_sc2                   ;   rep/sep window was 15)
        lda m_quot+1
        sta rs_sc2+1
 .else
        rep #$20
        .LONGA ON
        lda m_quot
        sta rs_sc2
        .LONGA OFF
        sep #$20
 .endif
        jsr screenx_signed
        rep #$20
        .LONGA ON
        lda m_xs
        sta rs_sx2
        ; --- order left<=right by signed sx (d = sx1 - sx2) ---
 .if 1
        lda rs_sx1
        cmp rs_sx2
 .else
        sec
        lda rs_sx1
        sbc rs_sx2
 .endif
 .if 1                                ; DRAC_PLAN 5: no 8-bit window: the flags are the
        bmi ?one_l                   ;   16-bit cmp's (N/Z), exactly what sep kept
        beq ?one_l
        lda #1                       ; v2 is the LEFT endpoint -> u runs L..0
        sta rs_uflip                 ;   (a 16-bit cell: 1, pad 0)
        lda rs_sx2
        sta rs_sxL
        lda rs_sc2
        sta rs_scL
        lda rs_sx1
        sta rs_sxR
        lda rs_sc1
        sta rs_scR
        bra ?ord16
?one_l  stz rs_uflip                 ; v1 is the LEFT endpoint -> u runs 0..L
        lda rs_sx1
        sta rs_sxL
        lda rs_sc1
        sta rs_scL
        lda rs_sx2
        sta rs_sxR
        lda rs_sc2
        sta rs_scR
?ord16
        .LONGA OFF
        sep #$20
 .else
        .LONGA OFF
        sep #$20                     ; (sep touches M only -- N and Z survive it)
        bmi ?one_l                   ; d<0 -> sx1 is left
        beq ?one_l                   ; d==0 -> treat 1 as left
        ; d>0 -> sx2 is left. Four 16-bit copies each way (2026-08-29).
        lda #1                       ; v2 is the LEFT endpoint -> u runs L..0
        sta rs_uflip
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        lda rs_sx2
        sta rs_sxL
        lda rs_sc2
        sta rs_scL
        lda rs_sx1
        sta rs_sxR
        lda rs_sc1
        sta rs_scR
        .LONGA OFF
        sep #$20
 .if 1
	bra ?ordered
 .else
        jmp ?ordered
 .endif
?one_l
 .if 1
        stz rs_uflip
 .else
	lda #0                       ; v1 is the LEFT endpoint -> u runs 0..L
        sta rs_uflip
 .endif
        rep #$20
        .LONGA ON
        lda rs_sx1
        sta rs_sxL
        lda rs_sc1
        sta rs_scL
        lda rs_sx2
        sta rs_sxR
        lda rs_sc2
        sta rs_scR
        .LONGA OFF
        sep #$20
 .endif
?ordered
        ; --- xa = max(vw_x0, sxL) --- (the window's edge, not the screen's: the
        ;     border columns are solid, so scanning them would be pure waste)
        lda rs_sxL+1
        bmi ?xa0                     ; sxL < 0 -> vw_x0
        beq ?xalo                    ; hi==0 -> use low
        lda #SCREEN_WIDTH            ; sxL >= 256 -> off right (force skip)
        sta zp_xa
 .if 1
	bra ?xadone
 .else
        jmp ?xadone
 .endif
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
        ; --- Doom8088's R_CheckBBox trick, at seg level: if EVERY column this
        ;     seg covers is already solid, nothing it draws can be seen, so drop
        ;     it before paying for inv_span, seg_len, the sector heights, two to
        ;     four plane_setups and the whole column loop. Doom8088 spells it
        ;     `if (!memchr(solidcol+sx1, 0, sx2-sx1)) return false;` -- we have
        ;     the same per-column array (solid_arr), so it is one scan.
        ;     (tools/_speed_model.py prices this at ~85 dropped segs/frame.)
?occl   lda rs_mpass                 ; (mtx_occ, inline: 2026-09-15 -- the
        beq ?occ0                    ;   jsr/rts and its own test are gone)
        jsr mseg_prime               ; = ldx zp_xa, except in the MASKED pass,
                                     ;   which first REOPENS this seg's columns
                                     ;   from its snapshot (mseg_prime) -- the
                                     ;   walk left them all closed, so the scan
                                     ;   below would drop every strut
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
 .if 1
	rep #$20
	.LONGA ON
        lda rs_sxR
        sbc rs_sxL
	bne ?spok
	inc
?spok	sta rs_span
	sta rc_m
	sep #$20
	.LONGA OFF
 .else
        lda rs_sxR
        sbc rs_sxL
        sta rs_span
        lda rs_sxR+1
        sbc rs_sxL+1
        sta rs_span+1
        lda rs_span
        ora rs_span+1
        bne ?spok
        lda #1
        sta rs_span
?spok
        ; --- inv_span = 1/span ONCE per seg (reused by step_recip per plane) ---
        lda rs_span
        sta rc_m
        lda rs_span+1
        sta rc_m+1
 .endif
        jsr recip_norm               ; X = mantissa idx, rc_e = e

        lda.l RCX_INV_LO,x           ; bank $01 (memory_map.inc RECIP_EXT)
        sta rs_invm
        lda.l RCX_INV_HI,x
        sta rs_invm+1
        clc                          ; shift = RECIP_INV_K + e
        lda #RECIP_INV_K
        adc rc_e
        sta rs_invsh
        ; --- horizontal texture coord: a WORLD-anchored track along the seg -----
        ;   u was (col - sxL): one texel per screen column, anchored to a screen
        ;   coordinate that moves as the player walks. The texture therefore never
        ;   scaled with distance and crawled sideways on every step. Instead run u
        ;   from 0 at one end of the seg to its world LENGTH at the other, so both
        ;   ends are pinned to the world. (Affine across the seg, not perspective
        ;   -- DOOM's BSP segs are short, so the error inside one is small.)
 .if 1
        rep #$30                     ; am_mark INLINED (2026-09-15): 16-bit A + X
        lda rs_segi                  ;   (native mode). A = seg index x2: AMSEG is
        asl                          ;   a u16 array
        tax
        lda.l AMSEG_EXT,x            ; A = &AMSEEN[this seg's linedef], bank $03
        tax
        sta.l AM_BANK0,x             ; ...and store it INTO that slot (ML_MAPPED)
        sep #$10                     ; X back to 8 bits; A stays 16-bit, which is
        jsr seg_len.seg_len16        ;   what seg_len opens with
 .else
        jsr am_mark                  ; r_segs.c:398 ML_MAPPED -- the automap
 .endif
                                     ;   remembers this line -- and then TAIL
                                     ;   JUMPS into seg_len, the call that used
                                     ;   to be here. Retargeting it instead of
                                     ;   adding one costs this segment zero
                                     ;   bytes, and it has none (automap.asm).
                                     ; rs_seglen = |v2-v1| (approx, no sqrt)
        ; --- rs_segoff = MAP_SEGOFF[segi]: how far along the LINEDEF this seg
        ;     starts (DOOM's seg->offset). calc_u adds it, so a wall split by
        ;     the BSP carries its texture across the cut instead of restarting
        ;     at column 0 -- 9 % of E1's segs have a non-zero offset and showed
        ;     a visible seam mid-wall. The table is a u16 array in the Rapidus
        ;     EXT bank (pack_map.py). zp_ptr+2 already holds MAP_EXT_BANK, and
        ;     the sector reads further down use plain (zp_ptr),y, which ignores
        ;     the bank byte. Loaded BEFORE the uflip branch so both paths get it.
 .if 1
	rep #$20
	.LONGA ON
	lda rs_segi
	asl
	sta m_a
;	clc
	adc #MAP_SEGOFF
	sta zp_ptr

        lda [zp_ptr]
        sta rs_segoff

        ldy rs_uflip
	beq ?u01

        sec                          ; left end carries u = L, right end u = 0
        lda #0
        sbc rs_seglen
        sta m_prod+1
        bra ?ustep

?u01    lda rs_seglen                ; left end u = 0, right end u = L
        sta m_prod+1
?ustep	sep #$20
	.LONGA OFF
 .else
        lda rs_segi
        asl
        sta m_a
        lda rs_segi+1
        rol
        sta m_a+1
        clc
        lda m_a
        adc #<MAP_SEGOFF
        sta zp_ptr
        lda m_a+1
        adc #>MAP_SEGOFF
        sta zp_ptr+1

        ldy #0
        lda [zp_ptr],y
        sta rs_segoff
        iny
        lda [zp_ptr],y
        sta rs_segoff+1

        lda rs_uflip
        beq ?u01

        sec                          ; left end carries u = L, right end u = 0
        lda #0
        sbc rs_seglen
        sta m_prod+1
        lda #0
        sbc rs_seglen+1
        sta m_prod+2
        jmp ?ustep

?u01    lda rs_seglen                ; left end u = 0, right end u = L
        sta m_prod+1
        lda rs_seglen+1
        sta m_prod+2
?ustep
 .endif
	jsr u_guard                  ; rs_utL/utR = rs_scL/scR, halved until
                                     ;   max(scale)*span fits the 24-bit tracks
        sec                          ; t1 = scaleR * (xa - sxL)
 .if 1
	rep #$20
	.LONGA ON
        lda zp_xa
	and #$00ff
        sbc rs_sxL
        sta m_a
        lda rs_utR
        sta m_b
	sep #$20
	.LONGA OFF
 .else
        lda zp_xa
        sbc rs_sxL
        sta m_a
        lda #0
        sbc rs_sxL+1
        sta m_a+1
        lda rs_utR
        sta m_b
        lda rs_utR+1
        sta m_b+1
 .endif
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
        ; (still 16-bit: the sep/rep pair that stood around the ldy below was
        ;  empty -- 6 cycles a seg, 2026-09-15)
        ; --- front sector -> zp_ptr; load heights/colours ---
        ; ONE 16-bit window for the whole block (2026-08-31, _an_drac030): the
        ; sector*8 used to shift IN m_prod (store-then-shift, ~40 cycles), the
        ; pointer add went in bytes and the three height subtracts in halves --
        ; ~139 cycles a seg against ~82 here, 99 segs a frame. Bit-identical:
        ; the 16-bit [zp_sptr],y drags seg byte @5 into the high half and the
        ; `and #$FF` drops it; (zp_ptr),y at 2/0 reads the same little-endian
        ; height pairs; every sum and difference wraps the same 16 bits.
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
 .if 1
        sec
        lda (zp_ptr)
 .else
        ldy #0
        sec
        lda (zp_ptr),y
 .endif
        sbc zp_pz
        sta rs_wbot
        sec                          ; worldH = f_ceil-f_floor = wtop-wbot (texel span)
        lda rs_wtop
        sbc rs_wbot
        sta rs_worldh
        .LONGA OFF
        sep #$20
ltsj    jsr lt_seg                   ; floor_base @5 / ceil_base @6 -> rs_*col,
                                     ;   both SHADED with this sector's light
                                     ;   (lights.asm; it also parks the colormap
                                     ;   row in zp_cm for the two wall colours
                                     ;   below). X is preserved.
                                     ; LABELLED: wp_flight retargets the operand
                                     ;   to lt_seg_flash while a muzzle flash is
                                     ;   up (extralight), and back -- so the
                                     ;   normal frame pays NOTHING for the
                                     ;   feature (lights.asm, 2026-08-31)
 .if 1                                ; SKY (2026-09-16): an F_SKY1 ceiling is DOOM's
        ldy #7                       ;   screen-fixed sky, not a flat (sky_clip).
        lda (zp_ptr),y               ;   zp_ptr is still the FRONT sector: lt_seg
        lsr @                        ;   only reads it. C = bit0 = sky ceiling.
        lda #$10                     ; colmerge's `bpl ?cm_have` for a flat...
        bcc ?skyk
        lda #$89                     ; ...BIT #imm for a sky: its operand swallows
?skyk   cmp.l B1CODE_BASE+?cmbr      ;   the offset and the test never runs, so no
        beq ?skyd                    ;   sky column is copied sideways. Nothing to
        sta.l B1CODE_BASE+?cmbr      ;   patch while the ceiling kind repeats.
        lsr @                        ; $89 -> C = 1, $10 -> C = 0
        lda #<draw_clip              ; ...and the ceiling call's target with it
        ldy #>draw_clip
        bcc ?skyj
        lda #<sky_clip
        ldy #>sky_clip
?skyj   sta.l B1CODE_BASE+?ceilj+1
        tya
        sta.l B1CODE_BASE+?ceilj+2
?skyd
 .else
        ;nothing
 .endif
        ldy #SEG_WALL                ; wall_tex @ seg+6: texid + bit6 ML_DONTPEGTOP
        lda [zp_sptr],y              ;   + bit7 impassable (collision-only)
        sta rs_pegf                  ; keep the raw byte -- the peg bit is read below
        iny                          ; low_tex @ seg+7: texid + bit6 ML_DONTPEGBOTTOM
        lda [zp_sptr],y              ;   + bit7 EXIT line. Read for EVERY seg: a
        sta rs_pegl                  ;   one-sided wall has no lower step but DOES

        lda rs_mpass                 ;   use the peg bit (door tracks).
        beq ?pegw                    ; (mtx_pegf's test inline, 2026-09-15: the
        jsr mtx_pegf                 ;  wall pass skips the jsr/rts)
        bra ?pegd
?pegw   lda rs_pegf
?pegd                                ; = lda rs_pegf, except in the MASKED pass,
                                     ;   which draws the two-sided MIDDLE texture
                                     ;   and gets rs_midtex instead (midtex.asm).
                                     ;   A CALL and not a test because this
                                     ;   segment ends 14 bytes below load_dtab
        and #$3F                     ; texid = bits 0-5
        cmp MAP_HNTEX
        bcs ?wnone                   ; >= count (incl 0x3F sentinel) -> no texture
        tax
        stx rs_wtexid                ; B2: full texture handle (base/h/wmask) for the blit
        ldy MAP_TEXDOM,x             ; + dominant colour as the untextured fallback,
        lda [zp_cm],y                ;   through the sector's colormap row: this is
        sta rs_wallcol               ;   the colour a FLAT wall is painted in ('T'
                                     ;   mode / no pixels shipped), so it is shaded
                                     ;   like the floor and ceiling. A TEXTURED wall
                                     ;   cannot be -- see the header of lights.asm.
        lda MAP_TEXADDRLO,x
        sta rs_wtexad
        lda MAP_TEXADDRMID,x
        sta rs_wtexad+1
        lda MAP_TEXADDRHI,x
        sta rs_wtexad+2
        lda MAP_TEXWMASK,x
        sta rs_wtexwm

 .if 1
    .if TEX_RUNS
        clc                          ; tex_setix INLINED (2026-09-15): the address
        lda MAP_TEXIXLO,x            ;   goes straight into wall_src's operand --
        adc #<LVL_TEXSD_C            ;   no jsr/rts, no wt_ix* round trip, and X
        sta.l B1CODE_BASE+wall_src.wix+1   ; is still the texid (tex_setix never
        lda MAP_TEXIXHI,x            ;   touched X on this path), so the ldx
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
 .else
        jsr tex_setix                ; -> wall_src.wix: this texture's column index

        lda wt_ixl                   ;   array (pack_textures.dedup_columns)
        sta.l B1CODE_BASE+wall_src.wix+1
        lda wt_ixh
        sta.l B1CODE_BASE+wall_src.wix+2
    .if TEX_RUNS
        lda wt_ixb                   ; ... and its SDRAM bank: the index is read
        sta.l B1CODE_BASE+wall_src.wix+3           ;   with absolute LONG now (texcol.asm)
    .endif
        ldx rs_wtexid                ; tex_setix walked the blob with X
 .endif
        lda MAP_TEXH,x               ; h = 0: this build does not SHIP the pixels
        sta rs_wtexh                 ;   (pack_textures.py SHIP_ALL_TEXTURES)...
        beq ?wflat
        lda rs_mpass                 ;   ...or the player pressed 'T' (runtime
        bne ?wtex                    ;   flat mode -- no fetch, no arena spend);
        lda tex_flat                 ;   mtx_flat inline (2026-09-15): a strut
        bne ?wflat                   ;   is never flattened
?wtex
                                     ;   = lda tex_flat, except for a two-sided
                                     ;   MIDDLE texture, which 'T' does not
 .if 1                               ;   flatten: see midtex.asm
	rep #$21
	.LONGA ON
	lda rs_wtexad
	adc tex_sdram
	sta rs_wtexad
	sep #$20
	.LONGA OFF
 .else
        clc                          ; PAINTED: the runs are read by the CPU out
        lda rs_wtexad                ;   of SDRAM, so the address is simply
        adc tex_sdram                ;   tex_sdram + the file offset. No arena,
        sta rs_wtexad                ;   no fetch, no VRAM copy of the texture at
        lda rs_wtexad+1              ;   all -- which is the whole point of the
        adc tex_sdram+1              ;   run format (paint.asm). (The B2 arena
        sta rs_wtexad+1              ;   branch that used to sit here under
 .endif
        lda rs_wtexad+2              ;   .else was deleted with tex_fget,
        adc tex_sdram+2              ;   2026-08-14.)
        sta rs_wtexad+2
 .if 1
	bra ?whave
 .else
        jmp ?whave
 .endif
?wflat  lda #$FF                     ; keep rs_wallcol, drop the handle: a flat
        sta rs_wtexid                ;   wall in its dominant colour, so the draw
        bne ?whave                   ;   sites take the flat path. (A = $FF)
?wnone  lda #$FF
        sta rs_wtexid
 .if 1
        stz rs_wallcol
 .else
        lda #0
        sta rs_wallcol
 .endif
?whave
        ; --- front planes (ceil + floor) via plane_setup. In the MASKED pass
        ;     mtx_pegf above has already swapped rs_wtop/rs_wbot for the mid
        ;     texture's own top and bottom, so these two tracks draw the strut
        ;     as if it were a solid wall (midtex.asm). ---
 .if 1                                ; 2026-09-15: both front tracks in word moves,
        rep #$20                     ;   plane_setup16 takes wtmp straight out of A,
        .LONGA ON                    ;   and the two opcode patches come AFTER the
        lda rs_wtop                  ;   second call (they only rewrite ?cnext, so
        sta rs_wtmp                  ;   the order is free) -- ~30 cycles a seg
        jsr plane_setup.plane_setup16
        rep #$20
        .LONGA ON
        lda rs_acctmp
        sta rs_ycacc
        ldy rs_acctmp+2
        sty rs_ycacc+2
        lda rs_Stmp
        sta rs_ycS
        lda rs_wbot
        sta rs_wtmp
        jsr plane_setup.plane_setup16
        rep #$20
        .LONGA ON
        lda rs_acctmp
        sta rs_yfacc
        ldy rs_acctmp+2
        sty rs_yfacc+2
        lda rs_Stmp                  ; N = the floor step's sign (sep keeps it)
        sta rs_yfS
        .LONGA OFF
        sep #$20
        bpl ?yfpos                   ; patch ?cnext's 24-bit carry step for the
        ldx #$B0                     ;   FLOOR track: negative -> BCS + DEY
        ldy #$88                     ;   (acc+2 += $FF + C)
        bra ?yfput
?yfpos  ldx #$90                     ;   positive -> BCC + INY  (acc+2 += $00 + C)
        ldy #$C8
?yfput  txa                          ; (DRAC_PLAN 2b) the patch must land in bank $01,
        sta.l B1CODE_BASE+?yfadd     ;   where this code runs; stx/sty have no long
        tya                          ;   form and A is dead here
        sta.l B1CODE_BASE+?yfinc
        lda rs_ycS+1                 ; ...and the CEILING track's, off its sign byte
        bpl ?ycpos
        ldx #$B0
        ldy #$88
        bra ?ycput
?ycpos  ldx #$90
        ldy #$C8
?ycput  txa
        sta.l B1CODE_BASE+?ycadd
        tya
        sta.l B1CODE_BASE+?ycinc
 .else
        lda rs_wtop
        sta rs_wtmp
        lda rs_wtop+1
        sta rs_wtmp+1

        jsr plane_setup

        lda rs_Stmp
        sta rs_ycS
        lda rs_Stmp+1
        sta rs_ycS+1
        bpl ?ycpos                   ; patch ?cnext's 24-bit carry step for THIS

 .if 1
        ldx #$B0                     ;   step's sign (see the block at ?ycadd):
        ldy #$88                     ;   negative -> BCS + DEY  (acc+2 += $FF + C)
	bra ?ycput
?ycpos  ldx #$90                     ;   positive -> BCC + INY  (acc+2 += $00 + C)
        ldy #$C8
?ycput  txa                          ; (DRAC_PLAN 2b) the patch must land in bank $01,
        sta.l B1CODE_BASE+?ycadd     ;   where this code runs; stx/sty have no long
        tya                          ;   form and A is dead here (the block below
        sta.l B1CODE_BASE+?ycinc     ;   reloads it before any use)
 .else
        ldx #$B0                     ;   step's sign (see the block at ?ycadd):
        ldy #$CE                     ;   negative -> BCS + DEC  (acc+2 += $FF + C)
  .if 1
	bra ?ycput
  .else
        bne ?ycput                   ;   ($CE != 0, so this is always taken)
  .endif
?ycpos  ldx #$90                     ;   positive -> BCC + INC  (acc+2 += $00 + C)
        ldy #$EE
?ycput  stx ?ycadd
        sty ?ycinc
 .endif

 .if 1
	rep #$20
	.LONGA ON
        lda rs_acctmp
        sta rs_ycacc
        ldy rs_acctmp+2
        sty rs_ycacc+2
        lda rs_wbot
        sta rs_wtmp
	sep #$20
	.LONGA OFF
 .else
        lda rs_acctmp
        sta rs_ycacc
        lda rs_acctmp+1
        sta rs_ycacc+1
        lda rs_acctmp+2
        sta rs_ycacc+2
        lda rs_wbot
        sta rs_wtmp
        lda rs_wbot+1
        sta rs_wtmp+1
 .endif
        jsr plane_setup

        lda rs_Stmp
        sta rs_yfS
        lda rs_Stmp+1
        sta rs_yfS+1
        bpl ?yfpos                   ; same patch for the front-floor track

 .if 1
        ldx #$B0
        ldy #$88
        bra ?yfput
?yfpos  ldx #$90
        ldy #$c8
?yfput  txa                          ; (DRAC_PLAN 2b) the patch must land in bank $01,
        sta.l B1CODE_BASE+?yfadd     ;   where this code runs; stx/sty have no long
        tya                          ;   form and A is dead here (the block below
        sta.l B1CODE_BASE+?yfinc     ;   reloads it before any use)
 .else
        ldx #$B0
        ldy #$CE
  .if 1
        bra ?yfput
  .else
        bne ?yfput
  .endif
?yfpos  ldx #$90
        ldy #$EE
?yfput  stx ?yfadd
        sty ?yfinc
 .endif

 .if 1
	rep #$20
	.LONGA ON
        lda rs_acctmp
        sta rs_yfacc
	sep #$20
	.LONGA OFF
 .else
        lda rs_acctmp
        sta rs_yfacc
        lda rs_acctmp+1
        sta rs_yfacc+1
 .endif
        lda rs_acctmp+2
        sta rs_yfacc+2
 .endif                               ; (the 2026-09-15 window above)
        ; --- portal? back_sec (@seg+SEG_BACK) != NO_SECTOR ---
        ldy #SEG_BACK
        lda [zp_sptr],y
        sta m_a
        ldy rs_mpass                 ; (mtx_back inline, 2026-09-15)
        beq ?real
        lda #NO_SECTOR
?real   cmp #NO_SECTOR               ; = cmp #NO_SECTOR, except in the MASKED
                                     ;   pass, which answers ONE-SIDED: a strut
                                     ;   is drawn as a solid span with no upper
                                     ;   or lower step, and the solid branch's
                                     ;   ML_DONTPEGBOTTOM rule below happens to
                                     ;   BE the mid texture's peg (midtex.asm)
        bne ?two_sided
 .if 1
        stz rs_isport
        stz rs_vshl                  ; no lower step on a solid seg
        stz rs_vshw                  ; default: top-pegged at the front ceiling
 .else
        lda #0
        sta rs_isport
        sta rs_vshl                  ; no lower step on a solid seg
        sta rs_vshw                  ; default: top-pegged at the front ceiling
 .endif
        lda #$FF                     ; no lower step on a solid seg (stale id would
        sta rs_ltexid                ; defeat the "nothing textured" test per column)
        ; --- DOOM r_segs.c: a one-sided line with ML_DONTPEGBOTTOM puts the
        ;     BOTTOM of the texture at the front floor (door tracks use this so
        ;     they stand still while the door ceiling moves). That is the
        ;     top-pegged texel minus worldH, modulo the texture height. ---
        lda rs_pegl
        and #$40
        beq ?soldone
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
        lda #1
        sta rs_isport
        lda rs_pegl                  ; lower-step texid (bits 0-5; bit7 EXIT used to
        and #$3F                     ;   push the byte past TEX_COUNT and silently
        cmp MAP_HNTEX               ;   blank an exit line's lower step)
 .if 1
	jcs ?lnone
 .else
        bcc ?lok
        jmp ?lnone                   ; (the B2 fetch block pushed it out of range)
?lok
 .endif
	tax
        stx rs_ltexid                ; B2: lower-step texture handle
        ldy MAP_TEXDOM,x             ; ... same shade for the lower step's flat
        lda [zp_cm],y                ;     fallback colour (lt_seg set zp_cm)
        sta rs_lowcol
        lda MAP_TEXADDRLO,x
        sta rs_ltexad
        lda MAP_TEXADDRMID,x
        sta rs_ltexad+1
        lda MAP_TEXADDRHI,x
        sta rs_ltexad+2
        lda MAP_TEXWMASK,x
        sta rs_ltexwm
 .if 1
    .if TEX_RUNS
        clc                          ; tex_setix inlined, as the wall above
        lda MAP_TEXIXLO,x
        adc #<LVL_TEXSD_C
        sta.l B1CODE_BASE+low_src.lix+1
        lda MAP_TEXIXHI,x
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
 .else
        jsr tex_setix                ; -> low_src.lix, same as the wall above
        lda wt_ixl
        sta.l B1CODE_BASE+low_src.lix+1
        lda wt_ixh
        sta.l B1CODE_BASE+low_src.lix+2
    .if TEX_RUNS
        lda wt_ixb
        sta.l B1CODE_BASE+low_src.lix+3
    .endif
        ldx rs_ltexid
 .endif
        lda MAP_TEXH,x               ; h = 0 -> pixels not in this build, flat step
        sta rs_ltexh                 ;   in its dominant colour (see ?wflat above)
        bne ?lgo
?lfj    jmp ?lflat                   ; (the fetch block pushed ?lflat out of

?lgo    lda tex_flat                 ;   branch range)
        bne ?lfj                     ; 'T': runtime flat mode, lower step too

 .if 1
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
 .else
        clc                          ; PAINTED: SDRAM address, no arena (see the
        lda rs_ltexad                ;   wall slot above). Nothing can be evicted
        adc tex_sdram                ;   any more, so the flush handshake and the
        sta rs_ltexad                ;   re-fetch that used to sit here under
        lda rs_ltexad+1              ;   .else went with tex_fget (2026-08-14).
        adc tex_sdram+1
        sta rs_ltexad+1
        lda rs_ltexad+2
        adc tex_sdram+2
        sta rs_ltexad+2
        jmp ?lhave
 .endif

?lflat  lda #$FF
        sta rs_ltexid
 .if 1
	bra ?lhave
 .else
        bne ?lhave                   ; (A = $FF)
 .endif
?lnone  lda #$FF
        sta rs_ltexid
 .if 1
        stz rs_lowcol
 .else
        lda #0
        sta rs_lowcol
 .endif
?lhave
 .if 1
        ldy #7                       ; SKY HACK, part 1 (2026-09-15): the FRONT
        lda (zp_ptr),y               ;   sector's flags (bit0 = F_SKY1 ceiling,
        pha                          ;   pack_map) -- zp_ptr moves to the back
 .endif                               ;   sector right below. ON THE STACK: a new
                                     ;   D0 byte pushed a D0 block onto $9500
                                     ;   (split_menu_ovl), and every path from
                                     ;   here reaches part 2's pla (no exits,
                                     ;   the branches all meet at ?uppeg)
 .if 1
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
        ldy #2                       ; back ceil plane: b_ceil(@2) - pz
        sec
        lda (zp_ptr),y
        sbc zp_pz
        sta rs_wtmp
	sep #$20
	.LONGA OFF
        stz rs_vshw
        bit rs_pegf
	bvs ?uppeg
 .else
        lda m_a                      ; m_prod = back_sec*8 via shifts (tips #3)
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1                 ; back_sec*8
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        ldy #2                       ; back ceil plane: b_ceil(@2) - pz
        sec
        lda (zp_ptr),y
        sbc zp_pz
        sta rs_wtmp
        iny
        lda (zp_ptr),y
        sbc zp_pz+1
        sta rs_wtmp+1
        ; --- DOOM r_segs.c: WITHOUT ML_DONTPEGTOP the upper texture hangs from
        ;     the BACK ceiling ("bottom of texture at backsector->ceilingheight
        ;     + textureheight"), so a door face rides UP with the door instead of
        ;     standing still. vs. the port's top-peg that is -(f_ceil - b_ceil)
        ;     texels, mod texH (the +textureheight vanishes in the modulo). ---
        lda #0
        sta rs_vshw
        lda rs_pegf
        and #$40
        bne ?uppeg                   ; ML_DONTPEGTOP -> top-pegged, nothing to add
 .endif
        rep #$20                     ; D = front_ceil - back_ceil, one word
        .LONGA ON                    ;   subtract; N from it (drac030, 2026-09-14)
        sec
        lda rs_wtop
        sbc rs_wtmp
        sta m_a
        .LONGA OFF
        sep #$20                     ; (sep leaves N alone)
        bmi ?uppeg                   ; back ceiling above front -> top-pegged

        lda rs_wtexh
        jsr vsh_neg
        sta rs_vshw

?uppeg  jsr plane_setup

        lda rs_Stmp
        sta rs_ybcS
        lda rs_Stmp+1
        sta rs_ybcS+1
        bpl ?bcpos                   ; ... and for the back-ceiling track (portals

 .if 1
        ldx #$B0                     ;   only -- ?cnext skips it when rs_isport = 0,
        ldy #$88                     ;   so a stale patch here is never executed)
	bra ?bcput
?bcpos  ldx #$90
        ldy #$C8
?bcput  txa                          ; (DRAC_PLAN 2b) the patch must land in bank $01,
        sta.l B1CODE_BASE+?bcadd     ;   where this code runs; stx/sty have no long
        tya                          ;   form and A is dead here (the block below
        sta.l B1CODE_BASE+?bcinc     ;   reloads it before any use)
 .else
        ldx #$B0                     ;   only -- ?cnext skips it when rs_isport = 0,
        ldy #$CE                     ;   so a stale patch here is never executed)
  .if 1
	bra ?bcput
  .else
        bne ?bcput
  .endif
?bcpos  ldx #$90
        ldy #$EE
?bcput  stx ?bcadd
        sty ?bcinc
 .endif

 .if 1
        ; SKY HACK, part 2 -- BUG FIX 2026-09-15 (E3M1: "strop je ako keby nizsie").
        ; r_segs.c:530, "hack to allow height changes in outdoor areas":
        ;     if (frontsector->ceilingpic == skyflatnum
        ;         && backsector->ceilingpic == skyflatnum)  worldtop = worldhigh;
        ; Between two sky sectors of different ceiling heights DOOM draws NO upper
        ; wall: the sky just goes on. This renderer drew the step, so E3M1's
        ; courtyard skies (56/64/128/192) came out as a low band cutting the view.
        ; worldtop = worldhigh here is: the FRONT ceiling track becomes the BACK
        ; ceiling track (accumulator, slope and the carry-step opcodes), so every
        ; column's pyc16 equals pybc16 -- no upper step, and the ceiling paint and
        ; the window top follow the back ceiling, exactly as DOOM's do.
        pla                          ; part 1's front flags
        lsr @
        bcc ?nosky                   ; front is not sky
        ldy #7
        lda (zp_ptr),y               ; zp_ptr = the BACK sector here
        lsr @
        bcc ?nosky                   ; back is not sky
        rep #$20
        .LONGA ON
        lda rs_acctmp                ; ycacc = the back ceiling accumulator (3 B)
        sta rs_ycacc
        lda rs_acctmp+1
        sta rs_ycacc+1
        lda rs_ybcS                  ; ycS = its slope
        sta rs_ycS
        sep #$20
        .LONGA OFF
        lda.l B1CODE_BASE+?bcadd     ; ...and its carry-step opcodes (?bcput just
        sta.l B1CODE_BASE+?ycadd     ;   patched them for this seg's back slope)
        lda.l B1CODE_BASE+?bcinc
        sta.l B1CODE_BASE+?ycinc
?nosky
 .endif
        lda rs_acctmp
        sta rs_ybcacc
 .if 1
	rep #$20
	.LONGA ON
        lda rs_acctmp+1
        sta rs_ybcacc+1
        sec
        lda (zp_ptr)
        sbc zp_pz
        sta rs_wtmp
	sep #$20
	.LONGA OFF
        stz rs_vshl
        bit rs_pegl
        bvc ?lowpeg
 .else
        lda rs_acctmp+1
        sta rs_ybcacc+1
        lda rs_acctmp+2
        sta rs_ybcacc+2

        ldy #0                       ; back floor plane: b_floor(@0) - pz
        sec
        lda (zp_ptr),y
        sbc zp_pz
        sta rs_wtmp
        iny
        lda (zp_ptr),y
        sbc zp_pz+1
        sta rs_wtmp+1
        ; --- DOOM r_segs.c: the lower step is normally anchored at the BACK
        ;     floor (what the port already does); WITH ML_DONTPEGBOTTOM it is
        ;     anchored at the front ceiling instead, i.e. +(f_ceil - b_floor). ---
        lda #0
        sta rs_vshl
        lda rs_pegl
        and #$40
        beq ?lowpeg
 .endif
        rep #$20                     ; L = front_ceil - back_floor, one word
        .LONGA ON                    ;   subtract; N from it (drac030, 2026-09-14)
        sec
        lda rs_wtop
        sbc rs_wtmp
        sta m_a
        .LONGA OFF
        sep #$20                     ; (sep leaves N alone)
        bmi ?lowpeg                  ; back floor above front ceiling

        lda rs_ltexh
        jsr vsh_mod
        sta rs_vshl

?lowpeg jsr plane_setup

        lda rs_Stmp
        sta rs_ybfS
        lda rs_Stmp+1
        sta rs_ybfS+1
        bpl ?bfpos                   ; ... and the back-floor track (portals only)

 .if 1
        ldx #$B0
        ldy #$88
	bra ?bfput
?bfpos  ldx #$90
        ldy #$C8
?bfput  txa                          ; (DRAC_PLAN 2b) the patch must land in bank $01,
        sta.l B1CODE_BASE+?bfadd     ;   where this code runs; stx/sty have no long
        tya                          ;   form and A is dead here (the block below
        sta.l B1CODE_BASE+?bfinc     ;   reloads it before any use)
 .else
        ldx #$B0
        ldy #$CE
  .if 1
	bra ?bfput
  .else
        bne ?bfput
  .endif
?bfpos  ldx #$90
        ldy #$EE
?bfput  stx ?bfadd
        sty ?bfinc
 .endif
 .if 1
	rep #$20
	.LONGA ON
        lda rs_acctmp
        sta rs_ybfacc
	sep #$20
	.LONGA OFF
 .else
        lda rs_acctmp
        sta rs_ybfacc
        lda rs_acctmp+1
        sta rs_ybfacc+1
 .endif
        lda rs_acctmp+2
        sta rs_ybfacc+2
?have_planes
 .if 1                                ; 2026-09-15: mtx_hook, cm_reset, cu_seg_init
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
 .else
        jsr mtx_hook                 ; = jsr seg_yoff (sidedef->rowoffset: both
                                     ;   peg shifts are final), and then the
                                     ;   two-sided MIDDLE texture: the WALK
                                     ;   snapshots and DEFERS such a seg, the
                                     ;   masked pass primes the window arrays
                                     ;   from that snapshot (midtex.asm)
        ; ===== per-column loop (portal-aware) =====
        jsr cm_reset                 ; no merge run pending yet (colmerge.asm)
        jsr cu_seg_init              ; perspective-u subdivision starts fresh
        jsr tw_seg_init              ; ... and the texel-rate subdivision
 .endif
    .if TEX_RUNS
        jsr pt_seg                   ; rows-per-texel for the seg's first column
                                     ;   + its per-column step (paint.asm). Both
                                     ;   divisions happen HERE, once, because rpt
                                     ;   is exactly linear in x -- unlike tpr.
    .endif
        ldx zp_xa
?col    lda solid_arr,x
 .if 1
	bne ?cskip
 .else
        beq ?open
        jmp ?cskip                   ; column already closed
?open
 .endif
	lda ytopc_arr,x              ; window [top,bot]
        sta rs_top
        lda ybotc_arr,x
        sta rs_bot
        cmp rs_top                   ; bot < top -> closed
        bcs ?winok
?cskip  jsr cm_flush                 ; a skipped column breaks the run: copy now
        jmp ?cnext

?winok  rep #$20                     ; raw front rows (signed16 = acc>>8): two
        .LONGA ON                    ;   word moves, not four byte ones
        lda rs_ycacc+1               ;   (2026-09-15, 527 columns a frame)
        sta rs_pyc16
        lda rs_yfacc+1
        sta rs_pyf16
        .LONGA OFF
        sep #$20
        lda rs_mpass                 ; MASKED pass: narrow the window to the mid
        beq ?nmsk                    ;   texture's own span, which is what makes
        jsr mseg_win                 ;   the ceiling and floor fills below empty
        bcs ?cskip                   ;   ranges -- see midtex.asm
?nmsk   stx zp_col
        stx pc_colw                  ; ... and as the word pt_span/paint_col add
        stz pc_colw+1                ;   (the high byte every column: a level
                                     ;    stream can pass over the D0 cells)
        lda rs_wtexid                ; both texture ids $FF -> nothing textured here
        and rs_ltexid
        cmp #$FF
        beq ?notex
 .if 1                                ; 2026-09-15: the four per-column leaves
                                     ;   (calc_u_sub, tw_setup_sub, cm_test,
                                     ;   cm_defer -- colmerge.asm, each with THIS
                                     ;   one caller) INLINED: 12 cycles of jsr/rts
                                     ;   each, ~1300 calls a frame. The procs stay
                                     ;   in colmerge.asm as the reference text.
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
        bra ?cu_done
?cu_far jsr cu_anchor                ; (was calc_u_sub's `jmp cu_anchor`)
        bra ?cu_done
?cu_ex  jsr calc_u                   ; exact u at THIS column (calc_u keeps X)
        stz cu_cnt                   ; leaving steep mode re-anchors immediately
?cu_done
        dec tws_cnt                  ; --- tw_setup_sub: the rate needs nothing per
        bpl ?notex                   ;   column now; this paces the steep re-test
        jsr tws_anchor
?notex                               ; --- cm_test: would this column draw exactly
        lda cm_x                     ;   what the last one drew? (magnified walls
?cmbr   bpl ?cm_have                 ;   repeat 4-8 columns per texel). SMC: BIT #
                                     ;   on a sky seg -- never merged (ltsj patch)
        rep #$20                     ; nothing drawn yet / run broken: no test,
        .LONGA ON                    ;   but the signature is (re)saved in full
        lda rs_ycacc+1
        bra ?cm_c1
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
        lda cm_nt                    ;   it, one blit copies it later
        sta ytopc_arr,x
        lda cm_nb
        sta ybotc_arr,x
        lda cm_solid
        beq ?cm_dd                   ; portal still open -> nothing else to do
        sta solid_arr,x              ; closed: same early-out bookkeeping as the
        dec cols_open                ;   drawing paths do
        bne ?cm_dd
        sta frame_done
?cm_dd  jmp ?cnext
        .LONGA ON
?cm_c0  lda rs_ycacc+1
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
        clc                          ; (cm_test's `clc / rts`: C = 0 into cm_flush)
 .else
        jsr calc_u_sub               ; perspective u: exact every CU_SUB columns,
                                     ;   interpolated in between (colmerge.asm)
        jsr tw_setup_sub             ; texels-per-screen-row for THIS column. It is
?notex                               ; 1/scale, so it holds for every span of the
                                     ; column (middle / upper / lower) -- only the
                                     ; peg row differs. tw_setup reads the front
                                     ; wall's plane accumulators directly.
        ; --- colmerge: would this column draw exactly what the last one drew?
        ;     (magnified walls repeat 4-8 columns per texel -- see colmerge.asm)
        jsr cm_test
        bcc ?cmdraw
        jsr cm_defer                 ; yes: skip it, one blit copies it later
        jmp ?cnext

 .endif
 .if 1
?cmdraw lda cm_n                     ; no: close the previous run (cm_flush's
        bne ?cf_go                   ;   early-out inlined: with nothing pending
        lda #$FF                     ;   it is `cm_x = $FF` and nothing else --
        sta cm_x                     ;   ~400 columns a frame), then draw
        bra ?cf_done
?cf_go  jsr cm_flush.cm_go
?cf_done
 .else
?cmdraw jsr cm_flush                 ; no: close the previous run, then draw
 .endif
        ; ceiling: top .. pyc-1
 .if 1
	rep #$20
	.LONGA ON
	lda rs_top
	and #$00ff
	sta rs_ra
        lda rs_pyc16
	dec
        sta rs_rb
	sep #$20
	.LONGA OFF
 .else
        lda rs_top
        sta rs_ra
  .if 1
        stz rs_ra+1
  .else
        lda #0
        sta rs_ra+1
  .endif
        sec
        lda rs_pyc16
        sbc #1
        sta rs_rb
        lda rs_pyc16+1
        sbc #0
        sta rs_rb+1
 .endif
        lda rs_ceilcol
        sta zp_color
?ceilj  jsr draw_clip                ; SMC: sky_clip for an F_SKY1 ceiling (the
                                     ;   per-seg patch after ltsj)

        lda rs_isport
 .if 1
	jne ?portalw
 .else
        beq ?solidw
        jmp ?portalw
?solidw
 .endif
	; --- SOLID: wall pyc..pyf, floor pyf+1..bot ---
 .if 1
	rep #$20
	.LONGA ON
        lda rs_pyf16
        sta rs_rb
        lda rs_pyc16                 ; ...and A keeps pyc16 for the peg row
        sta rs_ra                    ;   (2026-09-15: no reload)

        ldy rs_wtexid                ; B2: textured wall if a texture is set
        cpy #$FF
        beq ?txw_solid

        sta rs_pegrow                ; top-peg at the ceiling
	sep #$20
	.LONGA OFF
        lda rs_vshw                  ; + DOOM's peg shift for this seg
        sta rs_vsh
 .else
        lda rs_pyc16
        sta rs_ra
        lda rs_pyc16+1
        sta rs_ra+1
        lda rs_pyf16
        sta rs_rb
        lda rs_pyf16+1
        sta rs_rb+1

        lda rs_wtexid                ; B2: textured wall if a texture is set
        cmp #$FF
        beq ?txw_solid

        lda rs_pyc16                 ; top-peg at the ceiling
        sta rs_pegrow
        lda rs_pyc16+1
        sta rs_pegrow+1
        lda rs_vshw                  ; + DOOM's peg shift for this seg
        sta rs_vsh
 .endif
        jsr wall_src
 .if 1                                ; wall_src tail-calls draw_twall_clip (2026-09-15)
 .else
        jsr draw_twall_clip
 .endif
 .if 1
	bra ?txw_done
 .else
        jmp ?txw_done
 .endif
?txw_solid
 .if 1
	sep #$20
	.LONGA OFF
 .else
	;nothing
 .endif
        lda rs_wallcol
        sta zp_color
        jsr draw_clip
?txw_done
 .if 1
	rep #$20
	.LONGA ON
        lda rs_pyf16
	inc
        sta rs_ra
	lda rs_bot
	and #$00ff
	sta rs_rb
	sep #$20
	.LONGA OFF
 .else
        clc                          ; floor: pyf+1 .. bot
        lda rs_pyf16
        adc #1
        sta rs_ra
        lda rs_pyf16+1
        adc #0
        sta rs_ra+1
        lda rs_bot
        sta rs_rb
        lda #0
        sta rs_rb+1
 .endif
        lda rs_floorcol
        sta zp_color
        jsr draw_clip

        lda #1
        sta solid_arr,x
        dec cols_open
        bne ?sclo
        sta frame_done
 .if 1
?sclo   lda rs_sscl                  ; the scale for spr_ncut (cm_sscl2 inlined:
        sta ytopc_arr,x              ;   a CLOSED column carries it in ytopc/
        lda rs_sscl+1                ;   ybotc), then cm_save (this column is
        sta ybotc_arr,x              ;   now the run's source)
        jsr cm_save
 .else
?sclo   jsr cm_sscl.cm_sscl2         ; the scale for spr_ncut, then cm_save (this
                                     ;   column is now the run's source)
 .endif
        jmp ?cnext

?portalw ; --- PORTAL: see-through window + upper/lower steps ---
 .if 1
	rep #$20
	.LONGA ON
        lda rs_ybcacc+1             ; raw back rows
        sta rs_pybc16
        lda rs_ybfacc+1
        sta rs_pybf16
        lda rs_pyc16                 ; nt16 = max(top, pyc16): ONE word compare
        sta rs_nt16                  ;   (2026-09-15). A negative pyc16 loses to
        bmi ?nttop                   ;   top; otherwise top wins iff top >= pyc16
        lda rs_top                   ;   -- the byte tests' verdict (a pyc16 of
        and #$00FF                   ;   256+ beats every top), and the equal
        cmp rs_nt16                  ;   case stores the same number either way
        bcc ?ntk1
        bra ?ntset
?nttop  lda rs_top
        and #$00FF
?ntset  sta rs_nt16
 .else
	rep #$20
	.LONGA ON
        lda rs_ybcacc+1             ; raw back rows
        sta rs_pybc16
        lda rs_ybfacc+1
        sta rs_pybf16
        lda rs_pyc16
        sta rs_nt16
	sep #$20
	.LONGA OFF
	xba			;set NZ acc. to MSB (rs_pyc16+1)
 .endif
 .if 0
        lda rs_ybcacc+1             ; raw back rows
        sta rs_pybc16
        lda rs_ybcacc+2
        sta rs_pybc16+1
        lda rs_ybfacc+1
        sta rs_pybf16
        lda rs_ybfacc+2
        sta rs_pybf16+1
        ; nt16 = max(top, pyc16)
        lda rs_pyc16
        sta rs_nt16
        lda rs_pyc16+1
        sta rs_nt16+1
        lda rs_pyc16+1
        bmi ?nttop
        bne ?ntk1
        lda rs_pyc16
        cmp rs_top
        bcs ?ntk1
?nttop  lda rs_top
        sta rs_nt16
        stz rs_nt16+1
 .endif
?ntk1   ; upper step if pybc16 > pyc16 (16-bit A from every path above)
 .if 1
	.LONGA ON
        lda rs_pybc16
        cmp rs_pyc16
	bmi ?noup
	beq ?noup

        dec                          ; draw upper: pyc16 .. pybc16-1 (A = pybc16;
        sta rs_rb                    ;   no reloads, 2026-09-15)
        lda rs_pyc16
        sta rs_ra

        ldy rs_wtexid                ; B2: upper step uses the wall texture
        cpy #$FF
        beq ?txu_solid

        sta rs_pegrow                ; upper step measured from the ceiling row
	sep #$20                     ; (rs_dscr/rs_tpr stay the column's -- the texel
	.LONGA OFF
 .else
        sec
        lda rs_pybc16
        sbc rs_pyc16
        sta m_a
        lda rs_pybc16+1
        sbc rs_pyc16+1
        bmi ?noup
        ora m_a
        beq ?noup

        lda rs_pyc16                 ; draw upper: pyc16 .. pybc16-1
        sta rs_ra
        lda rs_pyc16+1
        sta rs_ra+1
        sec
        lda rs_pybc16
        sbc #1
        sta rs_rb
        lda rs_pybc16+1
        sbc #0
        sta rs_rb+1

        lda rs_wtexid                ; B2: upper step uses the wall texture
        cmp #$FF
        beq ?txu_solid

        lda rs_pyc16                 ; upper step measured from the ceiling row
        sta rs_pegrow                ; (rs_dscr/rs_tpr stay the column's -- the texel
        lda rs_pyc16+1               ;  rate does not depend on the span); rs_vshw
        sta rs_pegrow+1              ;  then re-anchors it to the BACK ceiling when
 .endif
        lda rs_vshw                  ;  the linedef is not ML_DONTPEGTOP -- that is
        sta rs_vsh                   ;  the door face riding up with the door
        jsr wall_src
 .if 1                                ; (tail-calls draw_twall_clip)
 .else
        jsr draw_twall_clip
 .endif
 .if 1
	bra ?txu_done
 .else
        jmp ?txu_done
 .endif
?txu_solid
 .if 1
	sep #$20
	.LONGA OFF
 .else
	;nothing
 .endif
        lda rs_wallcol
        sta zp_color
        jsr draw_clip
?txu_done
 .if 1
	rep #$20
	.LONGA ON
        lda rs_pybc16
        cmp rs_nt16
	bmi ?noup
	beq ?noup

        sta rs_nt16                  ; (A = pybc16 still)

?noup	lda rs_pyf16
        inc
        sta rs_ra
        lda rs_bot
	and #$00ff
        sta rs_rb
	sep #$20
	.LONGA OFF
 .else
        sec                          ; nt16 = max(nt16, pybc16)
        lda rs_pybc16
        sbc rs_nt16
        sta m_a
        lda rs_pybc16+1
        sbc rs_nt16+1
        bmi ?noup
        ora m_a
        beq ?noup

        lda rs_pybc16
        sta rs_nt16
        lda rs_pybc16+1
        sta rs_nt16+1

?noup   clc                          ; floor: pyf+1 .. bot
        lda rs_pyf16
        adc #1
        sta rs_ra
        lda rs_pyf16+1
        adc #0
        sta rs_ra+1
        lda rs_bot
        sta rs_rb
        lda #0
        sta rs_rb+1
 .endif
        lda rs_floorcol
        sta zp_color
        jsr draw_clip

        ; nb16 = min(bot, pyf16)
        rep #$20                     ; nb16 = min(bot, pyf16), a negative pyf16
        .LONGA ON                    ;   kept -- one word compare (drac030,
        lda rs_pyf16                 ;   2026-09-14: was two byte copies and
        bmi ?nbset                   ;   three 8-bit tests). The rep at ?nbk1
        lda rs_bot                   ;   below is then redundant (3 cycles), but
        and #$00FF                   ;   it keeps that block's own shape
        cmp rs_pyf16                 ; bot < pyf16 -> bot
        bcc ?nbset
        lda rs_pyf16
?nbset  sta rs_nb16
?nbk1   ; lower step if pybf16 < pyf16 (still 16-bit: no rep, 2026-09-15)
 .if 1
	.LONGA ON
        lda rs_pybf16
        cmp rs_pyf16
	bpl ?nolo

        sta rs_pegrow                ; lower step top-pegged at the back floor row
	inc                          ;   (written before the flat/textured fork:
        sta rs_ra                    ;   draw_clip never reads it, and A IS pybf16)
        lda rs_pyf16
        sta rs_rb

        ldy rs_ltexid                ; B2: textured lower step if a texture is set
        cpy #$FF
        beq ?txl_solid

	sep #$20                     ; (rs_dscr/rs_tpr stay the column's); rs_vshl
	.LONGA OFF
 .else
        sec
        lda rs_pybf16
        sbc rs_pyf16
        lda rs_pybf16+1
        sbc rs_pyf16+1
        bpl ?nolo

        clc                          ; draw lower: pybf16+1 .. pyf16
        lda rs_pybf16
        adc #1
        sta rs_ra
        lda rs_pybf16+1
        adc #0
        sta rs_ra+1
        lda rs_pyf16
        sta rs_rb
        lda rs_pyf16+1
        sta rs_rb+1

        lda rs_ltexid                ; B2: textured lower step if a texture is set
        cmp #$FF
        beq ?txl_solid

        lda rs_pybf16                ; lower step top-pegged at the back floor row
        sta rs_pegrow                ; (rs_dscr/rs_tpr stay the column's); rs_vshl
        lda rs_pybf16+1              ; moves it to the front ceiling for a
        sta rs_pegrow+1              ; ML_DONTPEGBOTTOM linedef
 .endif
        lda rs_vshl
        sta rs_vsh
        jsr low_src
 .if 1                                ; low_src falls through into draw_twall_clip
 .else
        jsr draw_twall_clip
 .endif
 .if 1
	bra ?txl_done
 .else
        jmp ?txl_done
 .endif
?txl_solid
 .if 1
	sep #$20
	.LONGA OFF
 .else
	;nothing
 .endif
        lda rs_lowcol
        sta zp_color
        jsr draw_clip
?txl_done
 .if 1
	rep #$20
	.LONGA ON
        lda rs_pybf16
        cmp rs_nb16
	bpl ?nolo

        sta rs_nb16                  ; (A = pybf16 still)
?nolo	sep #$20
	.LONGA OFF
 .else
        sec                          ; nb16 = min(nb16, pybf16)
        lda rs_pybf16
        sbc rs_nb16
        lda rs_pybf16+1
        sbc rs_nb16+1
        bpl ?nolo

        lda rs_pybf16
        sta rs_nb16
        lda rs_pybf16+1
        sta rs_nb16+1
?nolo
 .endif
	lda rs_nt16                 ; store window (low byte) + close if nt16>nb16
        sta ytopc_arr,x
        lda rs_nb16
        sta ybotc_arr,x

        clc                          ; nb16 - nt16 - 1 < 0  <=>  nb16 <= nt16 ->
        lda rs_nb16                  ;   close. NOT `sec` (i.e. nb16 < nt16): a
        sbc rs_nt16                  ;   portal whose opening is EXACTLY zero --
        lda rs_nb16+1                ;   every shut door, back floor == back
        sbc rs_nt16+1                ;   ceiling -- lands on nt16 == nb16, and the
        bpl ?pdone                   ;   strict test left it OPEN by one row. That
                                     ;   row is the slit under E1M4's four tag-1
                                     ;   doors (2026-08-07, "dvere nie su uplne
                                     ;   zatvorene"), and ytopc_arr/ybotc_arr kept
                                     ;   it as a window, so spr_add could put a
                                     ;   monster through it -- and ai_wake wakes
                                     ;   anything DRAWN, which is why fixing
                                     ;   use_shut alone did not stop them seeing
                                     ;   you. DOOM collapses the same window:
                                     ;   R_RenderSegLoop's ceilingclip/floorclip
                                     ;   meet when bceil == bfloor.
        lda #1
        sta solid_arr,x
        dec cols_open
        bne ?pdone
        sta frame_done
?pdone  jsr cm_sscl                  ; the scale IF this column just closed, then
                                     ;   cm_save (the run's source column)
?cnext
 .if 1                                ; DRAC_PLAN 5: 32-bit cells, word arithmetic (memory_map.inc D0):
        rep #$21                     ;   t1 += scaleR, t2 -= scaleL a word at a
        .LONGA ON                    ;   time; bytes 0-2 as before, byte 3 is the
        lda rs_t1                    ;   cell's padding and nobody reads it
        adc rs_utR
        sta rs_t1
        bcc ?t1nc                    ; the top word takes the carry alone: a
        inc rs_t1+2                  ;   16-bit inc IS `adc #0` with C=1, and the
?t1nc   sec                          ;   common no-carry case skips the RMW
        lda rs_t2                    ;   (2026-09-15, 602 columns a frame)
        sbc rs_utL
        sta rs_t2
        bcs ?t2nb
        dec rs_t2+2
?t2nb
        .LONGA OFF                   ; still 16-bit at run time: the accumulator
 .else                                ;   block below opens with rep #$21 (= clc)
	clc                          ; perspective weights: t1 += scaleR, t2 -= scaleL
        lda rs_t1
        adc rs_utR
        sta rs_t1
        lda rs_t1+1
        adc rs_utR+1
        sta rs_t1+1
        lda rs_t1+2
        adc #0
        sta rs_t1+2

        sec
        lda rs_t2
        sbc rs_utL
        sta rs_t2
        lda rs_t2+1
        sbc rs_utL+1
        sta rs_t2+1
        lda rs_t2+2
        sbc #0
        sta rs_t2+2
 .endif

        ; advance front accumulators (24-bit += signed16 step)
;
; WARNING: self-modifying code
;
 .if 1
	rep #$21
	.LONGA ON
        lda rs_ycacc
        adc rs_ycS
        sta rs_ycacc
?ycadd	bcc ?ycdone                  ; opcodes patched per seg -- see ?ycadd
	ldy rs_ycacc+2
?ycinc	iny			;ditto
	sty rs_ycacc+2
?ycdone
	clc
        lda rs_yfacc
        adc rs_yfS
        sta rs_yfacc
?yfadd	bcc ?yfdone                  ; opcodes patched per seg -- see ?ycadd
	ldy rs_yfacc+2
?yfinc	iny 			;ditto
	sty rs_yfacc+2
?yfdone
	ldy rs_isport               ; back accumulators only for portals
        beq ?adv_done
        clc
        lda rs_ybcacc
        adc rs_ybcS
        sta rs_ybcacc
?bcadd  bcc ?bcdone                  ; opcodes patched per seg -- see ?ycadd
	ldy rs_ybcacc+2
?bcinc	iny			;ditto
	sty rs_ybcacc+2
?bcdone
        clc
        lda rs_ybfacc
        adc rs_ybfS
        sta rs_ybfacc
?bfadd  bcc ?bfdone                  ; opcodes patched per seg -- see ?ycadd
	ldy rs_ybfacc+2
?bfinc	iny			;ditto
	sty rs_ybfacc+2
?bfdone
?adv_done
    .if TEX_RUNS
        ; pt_step INLINED (2026-09-14): rpt += drpt for EVERY column, drawn or
        ; skipped -- it tracks the plane accumulators above, not the drawing.
        ; It was `jsr pt_step` after the sep below: jsr/rts + its own rep/sep
        ; = 18 cycles on ~5,400 column steps a frame (bench: 229k cyk/f in a
        ; 40-cycle proc). Same two word adds, same carry order, so the
        ; [rptf, rpt, pad] cell is bit-identical (VRAM hash unchanged).
        clc
        lda rs_rptf
        adc rs_drpt
        sta rs_rptf
        lda rs_rptf+2
        adc rs_drpt+2
        sta rs_rptf+2
    .endif
	sep #$20
	.LONGA OFF
 .else
        clc
        lda rs_ycacc
        adc rs_ycS
        sta rs_ycacc
        lda rs_ycacc+1
        adc rs_ycS+1
        sta rs_ycacc+1
        ; 3rd byte = sign-extend + carry. The step's sign is fixed for the whole
        ; seg, so the two opcode bytes below are patched once per plane in the
        ; setup above instead of being re-derived by a branch every column:
        ;   positive step: acc+2 += $00 + C  ==  BCC over / INC acc+2
        ;   negative step: acc+2 += $FF + C  ==  BCS over / DEC acc+2
        ; Exactly equivalent, and the taken branch is the common case (acc+1 is a
        ; screen row, so a carry out of it is rare going up and near-certain going
        ; down) -- 3 cycles instead of 17-19.
?ycadd  bcc ?ycdone		;self-mod code
?ycinc	inc rs_ycacc+2		;ditto
?ycdone
        clc
        lda rs_yfacc
        adc rs_yfS
        sta rs_yfacc
        lda rs_yfacc+1
        adc rs_yfS+1
        sta rs_yfacc+1
?yfadd  bcc ?yfdone                  ; opcodes patched per seg -- see ?ycadd
?yfinc	inc rs_yfacc+2		;ditto
?yfdone
        lda rs_isport               ; back accumulators only for portals
        beq ?adv_done
        clc
        lda rs_ybcacc
        adc rs_ybcS
        sta rs_ybcacc
        lda rs_ybcacc+1
        adc rs_ybcS+1
        sta rs_ybcacc+1
?bcadd  bcc ?bcdone                  ; opcodes patched per seg -- see ?ycadd
?bcinc	inc rs_ybcacc+2		;ditto
?bcdone
        clc
        lda rs_ybfacc
        adc rs_ybfS
        sta rs_ybfacc
        lda rs_ybfacc+1
        adc rs_ybfS+1
        sta rs_ybfacc+1
?bfadd  bcc ?bfdone                  ; opcodes patched per seg -- see ?ycadd
?bfinc	inc rs_ybfacc+2		;ditto
?bfdone
?adv_done
    .if TEX_RUNS
        jsr pt_step                  ; (the 8-bit .else side only: the live block
    .endif                           ;   above has the adds inline)
 .endif
        cpx zp_xb
        beq ?done2
        inx
        jmp ?col
?done2  jmp cm_flush                 ; tail-call: copy the last pending run
.endp
        .endseg
