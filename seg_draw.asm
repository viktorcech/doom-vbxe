; AUTO-SPLIT from renderer.asm 2026-07-24 -- assembled in place via icl (verified
; byte-identical). renderer.asm keeps the BSP walk; this file draws ONE seg:
;   load_vertex / plane_setup / draw_span / draw_clip / process_seg
; process_seg is the big one (per-seg setup, then the per-column loop with the
; ceiling, wall, upper/lower step and floor draw sites).
;--------------------------------------------------------------
; load_vertex -- zp_vidx -> zp_rx,zp_ry = vertex - player.
;--------------------------------------------------------------
.proc load_vertex
        lda zp_vidx
        asl
        sta zp_vptr
        lda zp_vidx+1
        rol
        sta zp_vptr+1
        asl zp_vptr
        rol zp_vptr+1
        clc
        lda zp_vptr
        adc #<MAP_VERTS              ; MAP_VERTS = offset 0 in the EXT bank;
        sta zp_vptr                  ;   zp_vptr+2 = MAP_EXT_BANK, set once by
        lda zp_vptr+1                ;   init_level (nothing else writes it)
        adc #>MAP_VERTS
        sta zp_vptr+1
        ldy #0
        sec
        lda [zp_vptr],y
        sbc zp_px
        sta zp_rx
        iny
        lda [zp_vptr],y
        sbc zp_px+1
        sta zp_rx+1
        iny
        sec
        lda [zp_vptr],y
        sbc zp_py
        sta zp_ry
        iny
        lda [zp_vptr],y
        sbc zp_py+1
        sta zp_ry+1
        rts
.endp

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

.proc vsh_mod
        sta m_b                      ; m_b = texH << 7  (fits: 255<<7 = 32640)
        lda #0
        sta m_b+1
        ldx #7
?sh     asl m_b
        rol m_b+1
        dex
        bne ?sh
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
        lda m_a+1                    ; only reachable if world > texH*256 (no real
        bne ?giveup                  ;   geometry does that) -- a truncated hi byte
        lda m_a                      ;   would NOT be congruent, so shift by nothing
        rts
?giveup lda #0
        rts
.endp
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
.proc seg_yoff
        lda rs_segi                  ; m_a = segi >> 3 -> byte index into MAP_YBITS
        sta m_a
        lda rs_segi+1
        sta m_a+1
        ldx #3
?sh     lsr m_a+1
        ror m_a
        dex
        bne ?sh
        ldy m_a
        lda rs_segi                  ; C = bit (segi & 7) of that byte
        and #7
        tax
        inx                          ; shift it out: b+1 lsr's land bit b in C
        lda m_a+1                    ; MAP_YBITS outgrew one page with the E2/E3
        beq ?pg0                     ;   seg cap (2438 -> 305 B): page-split
        lda MAP_YBITS+256,y
        jmp ?bit
?pg0    lda MAP_YBITS,y
?bit    lsr
        dex
        bne ?bit
        bcs ?have
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
.proc u_guard
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
        jsr umul16                   ; m_prod(32) = max_scale * span
?sh     lda m_prod+3                 ; top byte set -> >= 2^24: halve and retry
        beq ?done
        lsr m_prod+3
        ror m_prod+2
        ror m_prod+1
        ror m_prod
        lsr rs_utR+1
        ror rs_utR
        lsr rs_utL+1
        ror rs_utL
        jmp ?sh
?done   rts
.endp

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
.proc seg_scl
        ldy #0                       ; y = 0 -> scL is the nearer end
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
        rts
.endp
    .if * > SEGSCL_END+1
        ert 'seg_scl outgrew SEGSCL_BASE..END (memory_map.inc)'
    .endif

        org SPRNCUT_BASE
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
    .if * > SPRNCUT_END+1
        ert 'spr_ncut outgrew SPRNCUT_BASE..END (memory_map.inc)'
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
.proc plane_setup
        lda rs_wtmp                  ; L = trk(world, scL) -> rs_Ltmp
        sta m_a
        lda rs_wtmp+1
        sta m_a+1
        lda rs_scL
        sta m_b
        lda rs_scL+1
        sta m_b+1
        jsr track_calc
        lda m_prod
        sta rs_Ltmp
        lda m_prod+1
        sta rs_Ltmp+1
        lda m_prod+2
        sta rs_Ltmp+2
        lda rs_wtmp                  ; R = trk(world, scR) (left in m_prod)
        sta m_a
        lda rs_wtmp+1
        sta m_a+1
        lda rs_scR
        sta m_b
        lda rs_scR+1
        sta m_b+1
        jsr track_calc
        lda m_prod                   ; keep R: it is the RIGHT-hand anchor below,
        sta rs_acctmp                ;   and rs_acctmp is free until we write the
        lda m_prod+1                 ;   answer into it
        sta rs_acctmp+1
        lda m_prod+2
        sta rs_acctmp+2
        sec                          ; step = (R - L) / span
        lda rs_acctmp
        sbc rs_Ltmp
        sta m_prod
        lda rs_acctmp+1
        sbc rs_Ltmp+1
        sta m_prod+1
        lda rs_acctmp+2
        sbc rs_Ltmp+2
        sta m_prod+2
        jsr step_recip               ; step = (R-L)/span via inv_span reciprocal
        lda m_quot
        sta rs_Stmp
        lda m_quot+1
        sta rs_Stmp+1
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
        jsr ?mulstep
        sec
        lda rs_acctmp                ; (rs_acctmp still holds R)
        sbc m_prod
        sta rs_acctmp
        lda rs_acctmp+1
        sbc m_prod+1
        sta rs_acctmp+1
        lda rs_acctmp+2
        sbc m_prod+2
        sta rs_acctmp+2
        rts
?fromL  jsr ?mulstep                 ; --- from the LEFT: acc = L + dL*step ---
        clc
        lda rs_Ltmp
        adc m_prod
        sta rs_acctmp
        lda rs_Ltmp+1
        adc m_prod+1
        sta rs_acctmp+1
        lda rs_Ltmp+2
        adc m_prod+2
        sta rs_acctmp+2
        rts
?mulstep lda rs_Stmp                 ; m_prod = m_a * step (signed)
        sta m_b
        lda rs_Stmp+1
        sta m_b+1
        jmp smul32
.endp

;--------------------------------------------------------------
; draw_span -- vertical span rows rs_spa..rs_spb, colour zp_color, column
;   zp_col. Draws via draw_vspan only if rs_spb >= rs_spa. Preserves X.
;   Parked in the row_lo/TWCHAIN hole: this segment ends at $3FFB, four bytes
;   below the streamed map, and the view-size code needed those bytes back. The
;   hole is fast RAM like the segment it came from, so it costs nothing.
;--------------------------------------------------------------
ds_resume = *
        org DRAWSPAN_BASE
.proc draw_span
        lda rs_spb
        cmp rs_spa
        bcc ?no
        sec
        sbc rs_spa
        clc
        adc #1
        tay
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
    .if * > DRAWSPAN_END+1
        ert 'draw_span outgrew DRAWSPAN_BASE..END (memory_map.inc)'
    .endif
        org ds_resume

;--------------------------------------------------------------
; draw_clip -- span with RAW signed16 endpoints rs_ra (start) / rs_rb (end),
;   clipped to the window [rs_top,rs_bot]: a=max(rs_ra,top), b=min(rs_rb,bot);
;   draws if b>=a. Mirrors render_view's col(x, max(a,top), min(b,bot)).
;--------------------------------------------------------------
.proc draw_clip
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
        jmp draw_span                ; tail-call (draws if spb>=spa, preserves X)
?out    rts
.endp

;--------------------------------------------------------------
; process_seg -- one seg (zp_sptr): transform, backface, near-clip,
;   project, then height/portal render with per-column occlusion.
;--------------------------------------------------------------
.proc process_seg
        ldy #0                       ; v1
        lda [zp_sptr],y
        sta zp_vidx
        iny
        lda [zp_sptr],y
        sta zp_vidx+1
        jsr load_vertex
        lda zp_rx
        sta zp_rx1
        lda zp_rx+1
        sta zp_rx1+1
        lda zp_ry
        sta zp_ry1
        lda zp_ry+1
        sta zp_ry1+1
        ldy #2                       ; v2
        lda [zp_sptr],y
        sta zp_vidx
        iny
        lda [zp_sptr],y
        sta zp_vidx+1
        jsr load_vertex
        lda zp_rx
        sta zp_rx2
        lda zp_rx+1
        sta zp_rx2+1
        lda zp_ry
        sta zp_ry2
        lda zp_ry+1
        sta zp_ry2+1
        ; --- backface FIRST. It only needs the PLAYER-RELATIVE coords, never the
        ;     rotated ones, so testing it here skips the two transforms (~700 cyc)
        ;     for every backfaced seg -- and on E1M1 that is 46% of every frame's
        ;     segs (tools/_speed_model.py: 783 transforms -> 391).
        ; --- backface: cx_a=rx2-rx1, cx_b=-ry1, cx_c=ry2-ry1, cx_d=-rx1 ---
        sec
        lda zp_rx2
        sbc zp_rx1
        sta cx_a
        lda zp_rx2+1
        sbc zp_rx1+1
        sta cx_a+1
        sec
        lda #0
        sbc zp_ry1
        sta cx_b
        lda #0
        sbc zp_ry1+1
        sta cx_b+1
        sec
        lda zp_ry2
        sbc zp_ry1
        sta cx_c
        lda zp_ry2+1
        sbc zp_ry1+1
        sta cx_c+1
        sec
        lda #0
        sbc zp_rx1
        sta cx_d
        lda #0
        sbc zp_rx1+1
        sta cx_d+1
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
        lda cx_a
        ora cx_a+1
        bne ?bf_tryc
        lda cx_c                     ; cx_a = 0 -> cross = -(cx_c*cx_d)
        ora cx_c+1
        beq ?bf_front                ;   a zero factor -> cross = 0 -> front
        lda cx_d
        ora cx_d+1
        beq ?bf_front
        lda cx_c+1                   ;   cross > 0 iff the signs DIFFER
        eor cx_d+1
        bmi ?bf_far
        bpl ?bf_front                ; (always: bit 7 was just tested)
?bf_tryc
        lda cx_c
        ora cx_c+1
        bne ?bf_gen                  ; neither axis -> pay for the full cross
        lda cx_b                     ; cx_c = 0 -> cross = cx_a*cx_b (cx_a != 0)
        ora cx_b+1
        beq ?bf_front
        lda cx_a+1                   ;   cross > 0 iff the signs are the SAME
        eor cx_b+1
        bpl ?bf_far
        bmi ?bf_front                ; (always)
?bf_far jmp ?bfout                   ; ?bfout is already at the edge of a relative
                                     ;   branch from the old test site, so the two
                                     ;   fast exits above go through here. Only
                                     ;   ever REACHED by branch -- the bmi over it
                                     ;   is unconditional in effect.
?bf_gen
        jsr cross_pos
        bne ?bfout                   ; cross>0 -> backface: not a single multiply
                                     ;   spent on the view transform below
?bf_front
        ; --- front-facing: NOW pay for the view transform of both endpoints ---
        lda zp_rx1
        sta zp_rx
        lda zp_rx1+1
        sta zp_rx+1
        lda zp_ry1
        sta zp_ry
        lda zp_ry1+1
        sta zp_ry+1
        jsr transform
        lda zp_X
        sta zp_X1
        lda zp_X+1
        sta zp_X1+1
        lda zp_Z
        sta zp_Z1
        lda zp_Z+1
        sta zp_Z1+1
        lda zp_rx2
        sta zp_rx
        lda zp_rx2+1
        sta zp_rx+1
        lda zp_ry2
        sta zp_ry
        lda zp_ry2+1
        sta zp_ry+1
        jsr transform
        lda zp_X
        sta zp_X2
        lda zp_X+1
        sta zp_X2+1
        lda zp_Z
        sta zp_Z2
        lda zp_Z+1
        sta zp_Z2+1
?front
        ; --- near-plane clip (match render_view): clip a behind-near endpoint
        ;     to Z=ZNEAR (keep the seg); drop ONLY if both endpoints are behind.
        ;     near1/near2 flags in zp_tmp/zp_tmp+1 (free until draw_vspan). ---
        lda #0
        sta zp_tmp
        sta zp_tmp+1
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
        sec                          ; t8 = (ZNEAR - Z2)<<8 / (Z1 - Z2)
        lda #ZNEAR
        sbc zp_Z2
        sta m_prod+1
        lda #0
        sbc zp_Z2+1
        sta m_prod+2
        lda #0
        sta m_prod
        sec
        lda zp_Z1
        sbc zp_Z2
        sta m_den
        lda zp_Z1+1
        sbc zp_Z2+1
        sta m_den+1
        jsr udiv24
        sec                          ; dX = X1 - X2
        lda zp_X1
        sbc zp_X2
        sta m_a
        lda zp_X1+1
        sbc zp_X2+1
        sta m_a+1
        lda m_quot
        sta m_b
        lda m_quot+1
        sta m_b+1
        jsr smul32                   ; m_prod = dX * t8
        clc                          ; X2 += m_prod>>8
        lda zp_X2
        adc m_prod+1
        sta zp_X2
        lda zp_X2+1
        adc m_prod+2
        sta zp_X2+1
        lda #ZNEAR
        sta zp_Z2
        lda #0
        sta zp_Z2+1
        jmp ?z2ok
?clip1  ; --- clip endpoint 1 toward endpoint 2: X1 += (X2-X1)*t ; Z1=ZNEAR ---
        sec                          ; t8 = (ZNEAR - Z1)<<8 / (Z2 - Z1)
        lda #ZNEAR
        sbc zp_Z1
        sta m_prod+1
        lda #0
        sbc zp_Z1+1
        sta m_prod+2
        lda #0
        sta m_prod
        sec
        lda zp_Z2
        sbc zp_Z1
        sta m_den
        lda zp_Z2+1
        sbc zp_Z1+1
        sta m_den+1
        jsr udiv24
        sec                          ; dX = X2 - X1
        lda zp_X2
        sbc zp_X1
        sta m_a
        lda zp_X2+1
        sbc zp_X1+1
        sta m_a+1
        lda m_quot
        sta m_b
        lda m_quot+1
        sta m_b+1
        jsr smul32                   ; m_prod = dX * t8
        clc                          ; X1 += m_prod>>8
        lda zp_X1
        adc m_prod+1
        sta zp_X1
        lda zp_X1+1
        adc m_prod+2
        sta zp_X1+1
        lda #ZNEAR
        sta zp_Z1
        lda #0
        sta zp_Z1+1
?z2ok
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
        lda zp_X1+1                  ; both endpoints left of the screen?
        bpl ?fr_nl
        clc                          ; X1 + Z1 < 0 ?
        lda zp_X1
        adc zp_Z1
        lda zp_X1+1
        adc zp_Z1+1
        bpl ?fr_nl
        lda zp_X2+1
        bpl ?fr_nl
        clc                          ; X2 + Z2 < 0 ?
        lda zp_X2
        adc zp_Z2
        lda zp_X2+1
        adc zp_Z2+1
        bmi ?fr_out
        bpl ?fr_nl                   ; (always: bit 7 was just tested clear)
?fr_out rts                          ; the seg covers no column -- drop it here,
                                     ;   exactly as ?skip would have below
?fr_nl  lda zp_X1+1                  ; both endpoints right of the screen?
        bmi ?fr_nr
        sec                          ; X1 - Z1 > 0 ?
        lda zp_X1
        sbc zp_Z1
        sta m_a
        lda zp_X1+1
        sbc zp_Z1+1
        bmi ?fr_nr
        ora m_a
        beq ?fr_nr                   ; X1 == Z1 is the edge column: keep
        lda zp_X2+1
        bmi ?fr_nr
        sec                          ; X2 - Z2 > 0 ?
        lda zp_X2
        sbc zp_Z2
        sta m_a
        lda zp_X2+1
        sbc zp_Z2+1
        bmi ?fr_nr
        ora m_a
        bne ?fr_out
?fr_nr
        ; ===== M2c: real wall heights + floor/ceiling (SOLID walls) =====
        ; Transcribes gui.py render_view (fixed). Portals (two-sided) come next;
        ; for now every seg is drawn as a solid floor->ceiling wall.
        ; --- endpoint 1: scale (1/Z) + unclamped screen-X ---
        lda zp_X1
        sta zp_X
        lda zp_X1+1
        sta zp_X+1
        lda zp_Z1
        sta zp_Z
        lda zp_Z1+1
        sta zp_Z+1
        jsr scale_z                  ; m_quot = sc1
        lda m_quot
        sta rs_sc1
        lda m_quot+1
        sta rs_sc1+1
        jsr screenx_signed           ; m_xs = sx1 (signed, unclamped)
        lda m_xs
        sta rs_sx1
        lda m_xs+1
        sta rs_sx1+1
        ; --- endpoint 2 ---
        lda zp_X2
        sta zp_X
        lda zp_X2+1
        sta zp_X+1
        lda zp_Z2
        sta zp_Z
        lda zp_Z2+1
        sta zp_Z+1
        jsr scale_z
        lda m_quot
        sta rs_sc2
        lda m_quot+1
        sta rs_sc2+1
        jsr screenx_signed
        lda m_xs
        sta rs_sx2
        lda m_xs+1
        sta rs_sx2+1
        ; --- order left<=right by signed sx (d = sx1 - sx2) ---
        sec
        lda rs_sx1
        sbc rs_sx2
        sta m_a
        lda rs_sx1+1
        sbc rs_sx2+1
        sta m_a+1
        bmi ?one_l                   ; d<0 -> sx1 is left
        ora m_a
        beq ?one_l                   ; d==0 -> treat 1 as left
        ; d>0 -> sx2 is left
        lda rs_sx2
        sta rs_sxL
        lda rs_sx2+1
        sta rs_sxL+1
        lda rs_sc2
        sta rs_scL
        lda rs_sc2+1
        sta rs_scL+1
        lda rs_sx1
        sta rs_sxR
        lda rs_sx1+1
        sta rs_sxR+1
        lda rs_sc1
        sta rs_scR
        lda rs_sc1+1
        sta rs_scR+1
        lda #1                       ; v2 is the LEFT endpoint -> u runs L..0
        sta rs_uflip
        jmp ?ordered
?one_l  lda #0                       ; v1 is the LEFT endpoint -> u runs 0..L
        sta rs_uflip
        lda rs_sx1
        sta rs_sxL
        lda rs_sx1+1
        sta rs_sxL+1
        lda rs_sc1
        sta rs_scL
        lda rs_sc1+1
        sta rs_scL+1
        lda rs_sx2
        sta rs_sxR
        lda rs_sx2+1
        sta rs_sxR+1
        lda rs_sc2
        sta rs_scR
        lda rs_sc2+1
        sta rs_scR+1
?ordered
        ; --- xa = max(vw_x0, sxL) --- (the window's edge, not the screen's: the
        ;     border columns are solid, so scanning them would be pure waste)
        lda rs_sxL+1
        bmi ?xa0                     ; sxL < 0 -> vw_x0
        beq ?xalo                    ; hi==0 -> use low
        lda #SCREEN_WIDTH            ; sxL >= 256 -> off right (force skip)
        sta zp_xa
        jmp ?xadone
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
?occl   jsr mtx_occ                  ; = ldx zp_xa, except in the MASKED pass,
                                     ;   which first REOPENS this seg's columns
                                     ;   from its snapshot (mseg_prime) -- the
                                     ;   walk left them all closed, so the scan
                                     ;   below would drop every strut
?occ1   lda solid_arr,x
        beq ?go                      ; found an open column -> the seg is visible
        cpx zp_xb
        beq ?skip                    ; scanned the whole span, all solid -> drop
        inx
        bne ?occ1
?go
        ; --- span = sxR - sxL (>=1) ---
        sec
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
        jsr am_mark                  ; r_segs.c:398 ML_MAPPED -- the automap
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
?ustep  jsr u_guard                  ; rs_utL/utR = rs_scL/scR, halved until
                                     ;   max(scale)*span fits the 24-bit tracks
        sec                          ; t1 = scaleR * (xa - sxL)
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
        jsr umul16
        lda m_prod
        sta rs_t1
        lda m_prod+1
        sta rs_t1+1
        lda m_prod+2
        sta rs_t1+2
        sec                          ; t2 = scaleL * (sxR - xa)
        lda rs_sxR
        sbc zp_xa
        sta m_a
        lda rs_sxR+1
        sbc #0
        sta m_a+1
        lda rs_utL
        sta m_b
        lda rs_utL+1
        sta m_b+1
        jsr umul16
        lda m_prod
        sta rs_t2
        lda m_prod+1
        sta rs_t2+1
        lda m_prod+2
        sta rs_t2+2
        ; --- front sector -> zp_ptr; load heights/colours ---
        ldy #SEG_FRONT               ; front_sec (u8) @ seg+4
        lda [zp_sptr],y
        sta m_prod
        lda #0
        sta m_prod+1
        asl m_prod                   ; m_prod = front_sec*8 via shifts (tips #3)
        rol m_prod+1
        asl m_prod
        rol m_prod+1
        asl m_prod
        rol m_prod+1                 ; front_sec*8
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        ; worldtop = ceil_h(@2) - pz ; worldbot = floor_h(@0) - pz
        ldy #2
        sec
        lda (zp_ptr),y
        sbc zp_pz
        sta rs_wtop
        iny
        lda (zp_ptr),y
        sbc zp_pz+1
        sta rs_wtop+1
        ldy #0
        sec
        lda (zp_ptr),y
        sbc zp_pz
        sta rs_wbot
        iny
        lda (zp_ptr),y
        sbc zp_pz+1
        sta rs_wbot+1
        sec                          ; worldH = f_ceil-f_floor = wtop-wbot (texel span)
        lda rs_wtop
        sbc rs_wbot
        sta rs_worldh
        lda rs_wtop+1
        sbc rs_wbot+1
        sta rs_worldh+1
        jsr lt_seg                   ; floor_base @5 / ceil_base @6 -> rs_*col,
                                     ;   both SHADED with this sector's light
                                     ;   (lights.asm; it also parks the colormap
                                     ;   row in zp_cm for the two wall colours
                                     ;   below). X is preserved.
        ldy #SEG_WALL                ; wall_tex @ seg+6: texid + bit6 ML_DONTPEGTOP
        lda [zp_sptr],y              ;   + bit7 impassable (collision-only)
        sta rs_pegf                  ; keep the raw byte -- the peg bit is read below
        iny                          ; low_tex @ seg+7: texid + bit6 ML_DONTPEGBOTTOM
        lda [zp_sptr],y              ;   + bit7 EXIT line. Read for EVERY seg: a
        sta rs_pegl                  ;   one-sided wall has no lower step but DOES
        jsr mtx_pegf                 ;   use the peg bit (door tracks).
                                     ; = lda rs_pegf, except in the MASKED pass,
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
        jsr tex_setix                ; -> wall_src.wix: this texture's column index
        lda wt_ixl                   ;   array (pack_textures.dedup_columns)
        sta wall_src.wix+1
        lda wt_ixh
        sta wall_src.wix+2
    .if TEX_RUNS
        lda wt_ixb                   ; ... and its SDRAM bank: the index is read
        sta wall_src.wix+3           ;   with absolute LONG now (texcol.asm)
    .endif
        ldx rs_wtexid                ; tex_setix walked the blob with X
        lda MAP_TEXH,x               ; h = 0: this build does not SHIP the pixels
        sta rs_wtexh                 ;   (pack_textures.py SHIP_ALL_TEXTURES)...
        beq ?wflat
        jsr mtx_flat                 ;   ...or the player pressed 'T' (runtime
        bne ?wflat                   ;   flat mode -- no fetch, no arena spend).
                                     ;   = lda tex_flat, except for a two-sided
                                     ;   MIDDLE texture, which 'T' does not
                                     ;   flatten: see midtex.asm
        clc                          ; PAINTED: the runs are read by the CPU out
        lda rs_wtexad                ;   of SDRAM, so the address is simply
        adc tex_sdram                ;   tex_sdram + the file offset. No arena,
        sta rs_wtexad                ;   no fetch, no VRAM copy of the texture at
        lda rs_wtexad+1              ;   all -- which is the whole point of the
        adc tex_sdram+1              ;   run format (paint.asm). (The B2 arena
        sta rs_wtexad+1              ;   branch that used to sit here under
        lda rs_wtexad+2              ;   .else was deleted with tex_fget,
        adc tex_sdram+2              ;   2026-08-14.)
        sta rs_wtexad+2
        jmp ?whave
?wflat  lda #$FF                     ; keep rs_wallcol, drop the handle: a flat
        sta rs_wtexid                ;   wall in its dominant colour, so the draw
        bne ?whave                   ;   sites take the flat path. (A = $FF)
?wnone  lda #$FF
        sta rs_wtexid
        lda #0
        sta rs_wallcol
?whave
        ; --- front planes (ceil + floor) via plane_setup. In the MASKED pass
        ;     mtx_pegf above has already swapped rs_wtop/rs_wbot for the mid
        ;     texture's own top and bottom, so these two tracks draw the strut
        ;     as if it were a solid wall (midtex.asm). ---
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
        ldx #$B0                     ;   step's sign (see the block at ?ycadd):
        ldy #$CE                     ;   negative -> BCS + DEC  (acc+2 += $FF + C)
        bne ?ycput                   ;   ($CE != 0, so this is always taken)
?ycpos  ldx #$90                     ;   positive -> BCC + INC  (acc+2 += $00 + C)
        ldy #$EE
?ycput  stx ?ycadd
        sty ?ycadd+2
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
        jsr plane_setup
        lda rs_Stmp
        sta rs_yfS
        lda rs_Stmp+1
        sta rs_yfS+1
        bpl ?yfpos                   ; same patch for the front-floor track
        ldx #$B0
        ldy #$CE
        bne ?yfput
?yfpos  ldx #$90
        ldy #$EE
?yfput  stx ?yfadd
        sty ?yfadd+2
        lda rs_acctmp
        sta rs_yfacc
        lda rs_acctmp+1
        sta rs_yfacc+1
        lda rs_acctmp+2
        sta rs_yfacc+2
        ; --- portal? back_sec (@seg+SEG_BACK) != NO_SECTOR ---
        ldy #SEG_BACK
        lda [zp_sptr],y
        sta m_a
        jsr mtx_back                 ; = cmp #NO_SECTOR, except in the MASKED
                                     ;   pass, which answers ONE-SIDED: a strut
                                     ;   is drawn as a solid span with no upper
                                     ;   or lower step, and the solid branch's
                                     ;   ML_DONTPEGBOTTOM rule below happens to
                                     ;   BE the mid texture's peg (midtex.asm)
        bne ?two_sided
        lda #0
        sta rs_isport
        sta rs_vshl                  ; no lower step on a solid seg
        sta rs_vshw                  ; default: top-pegged at the front ceiling
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
        bcc ?lok
        jmp ?lnone                   ; (the B2 fetch block pushed it out of range)
?lok    tax
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
        jsr tex_setix                ; -> low_src.lix, same as the wall above
        lda wt_ixl
        sta low_src.lix+1
        lda wt_ixh
        sta low_src.lix+2
    .if TEX_RUNS
        lda wt_ixb
        sta low_src.lix+3
    .endif
        ldx rs_ltexid
        lda MAP_TEXH,x               ; h = 0 -> pixels not in this build, flat step
        sta rs_ltexh                 ;   in its dominant colour (see ?wflat above)
        bne ?lgo
?lfj    jmp ?lflat                   ; (the fetch block pushed ?lflat out of
?lgo    lda tex_flat                 ;   branch range)
        bne ?lfj                     ; 'T': runtime flat mode, lower step too
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
?lflat  lda #$FF
        sta rs_ltexid
        bne ?lhave                   ; (A = $FF)
?lnone  lda #$FF
        sta rs_ltexid
        lda #0
        sta rs_lowcol
?lhave
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
        sec                          ; D = front_ceil - back_ceil (world units)
        lda rs_wtop
        sbc rs_wtmp
        sta m_a
        lda rs_wtop+1
        sbc rs_wtmp+1
        sta m_a+1
        bmi ?uppeg                   ; back ceiling above front -> no upper span
        lda rs_wtexh
        jsr vsh_neg
        sta rs_vshw
?uppeg  jsr plane_setup
        lda rs_Stmp
        sta rs_ybcS
        lda rs_Stmp+1
        sta rs_ybcS+1
        bpl ?bcpos                   ; ... and for the back-ceiling track (portals
        ldx #$B0                     ;   only -- ?cnext skips it when rs_isport = 0,
        ldy #$CE                     ;   so a stale patch here is never executed)
        bne ?bcput
?bcpos  ldx #$90
        ldy #$EE
?bcput  stx ?bcadd
        sty ?bcadd+2
        lda rs_acctmp
        sta rs_ybcacc
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
        sec                          ; L = front_ceil - back_floor (world units)
        lda rs_wtop
        sbc rs_wtmp
        sta m_a
        lda rs_wtop+1
        sbc rs_wtmp+1
        sta m_a+1
        bmi ?lowpeg                  ; back floor above front ceiling -> no step
        lda rs_ltexh
        jsr vsh_mod
        sta rs_vshl
?lowpeg jsr plane_setup
        lda rs_Stmp
        sta rs_ybfS
        lda rs_Stmp+1
        sta rs_ybfS+1
        bpl ?bfpos                   ; ... and the back-floor track (portals only)
        ldx #$B0
        ldy #$CE
        bne ?bfput
?bfpos  ldx #$90
        ldy #$EE
?bfput  stx ?bfadd
        sty ?bfadd+2
        lda rs_acctmp
        sta rs_ybfacc
        lda rs_acctmp+1
        sta rs_ybfacc+1
        lda rs_acctmp+2
        sta rs_ybfacc+2
?have_planes
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
    .if TEX_RUNS
        jsr pt_seg                   ; rows-per-texel for the seg's first column
                                     ;   + its per-column step (paint.asm). Both
                                     ;   divisions happen HERE, once, because rpt
                                     ;   is exactly linear in x -- unlike tpr.
    .endif
        ldx zp_xa
?col    lda solid_arr,x
        beq ?open
        jmp ?cskip                   ; column already closed
?open   lda ytopc_arr,x              ; window [top,bot]
        sta rs_top
        lda ybotc_arr,x
        sta rs_bot
        cmp rs_top                   ; bot < top -> closed
        bcs ?winok
?cskip  jsr cm_flush                 ; a skipped column breaks the run: copy now
        jmp ?cnext
?winok  lda rs_ycacc+1               ; raw front rows (signed16 = acc>>8)
        sta rs_pyc16
        lda rs_ycacc+2
        sta rs_pyc16+1
        lda rs_yfacc+1
        sta rs_pyf16
        lda rs_yfacc+2
        sta rs_pyf16+1
        lda rs_mpass                 ; MASKED pass: narrow the window to the mid
        beq ?nmsk                    ;   texture's own span, which is what makes
        jsr mseg_win                 ;   the ceiling and floor fills below empty
        bcs ?cskip                   ;   ranges -- see midtex.asm
?nmsk   stx zp_col
        lda rs_wtexid                ; both texture ids $FF -> nothing textured here
        and rs_ltexid
        cmp #$FF
        beq ?notex
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
?cmdraw jsr cm_flush                 ; no: close the previous run, then draw
        ; ceiling: top .. pyc-1
        lda rs_top
        sta rs_ra
        lda #0
        sta rs_ra+1
        sec
        lda rs_pyc16
        sbc #1
        sta rs_rb
        lda rs_pyc16+1
        sbc #0
        sta rs_rb+1
        lda rs_ceilcol
        sta zp_color
        jsr draw_clip
        lda rs_isport
        beq ?solidw
        jmp ?portalw
?solidw ; --- SOLID: wall pyc..pyf, floor pyf+1..bot ---
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
        jsr wall_src
        jsr draw_twall_clip
        jmp ?txw_done
?txw_solid
        lda rs_wallcol
        sta zp_color
        jsr draw_clip
?txw_done
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
        lda rs_floorcol
        sta zp_color
        jsr draw_clip
        lda #1
        sta solid_arr,x
        dec cols_open
        bne ?sclo
        sta frame_done
?sclo   jsr cm_sscl.cm_sscl2         ; the scale for spr_ncut, then cm_save (this
                                     ;   column is now the run's source)
        jmp ?cnext
?portalw ; --- PORTAL: see-through window + upper/lower steps ---
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
        lda #0
        sta rs_nt16+1
?ntk1   ; upper step if pybc16 > pyc16
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
        lda rs_vshw                  ;  the linedef is not ML_DONTPEGTOP -- that is
        sta rs_vsh                   ;  the door face riding up with the door
        jsr wall_src
        jsr draw_twall_clip
        jmp ?txu_done
?txu_solid
        lda rs_wallcol
        sta zp_color
        jsr draw_clip
?txu_done
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
        lda rs_floorcol
        sta zp_color
        jsr draw_clip
        ; nb16 = min(bot, pyf16)
        lda rs_pyf16
        sta rs_nb16
        lda rs_pyf16+1
        sta rs_nb16+1
        lda rs_pyf16+1
        bmi ?nbk1
        bne ?nbbot
        lda rs_pyf16
        cmp rs_bot
        bcc ?nbk1
        beq ?nbk1
?nbbot  lda rs_bot
        sta rs_nb16
        lda #0
        sta rs_nb16+1
?nbk1   ; lower step if pybf16 < pyf16
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
        lda rs_vshl
        sta rs_vsh
        jsr low_src
        jsr draw_twall_clip
        jmp ?txl_done
?txl_solid
        lda rs_lowcol
        sta zp_color
        jsr draw_clip
?txl_done
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
?nolo   lda rs_nt16                 ; store window (low byte) + close if nt16>nb16
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
?cnext  clc                          ; perspective weights: t1 += scaleR, t2 -= scaleL
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
        ; advance front accumulators (24-bit += signed16 step)
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
?ycadd  bcc ?ycdone
        inc rs_ycacc+2
?ycdone
        clc
        lda rs_yfacc
        adc rs_yfS
        sta rs_yfacc
        lda rs_yfacc+1
        adc rs_yfS+1
        sta rs_yfacc+1
?yfadd  bcc ?yfdone                  ; opcodes patched per seg -- see ?ycadd
        inc rs_yfacc+2
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
        inc rs_ybcacc+2
?bcdone
        clc
        lda rs_ybfacc
        adc rs_ybfS
        sta rs_ybfacc
        lda rs_ybfacc+1
        adc rs_ybfS+1
        sta rs_ybfacc+1
?bfadd  bcc ?bfdone                  ; opcodes patched per seg -- see ?ycadd
        inc rs_ybfacc+2
?bfdone
?adv_done
    .if TEX_RUNS
        jsr pt_step                  ; rpt += drpt -- for EVERY column, drawn or
                                     ;   skipped: it tracks the plane
                                     ;   accumulators above, not the drawing
    .endif
        cpx zp_xb
        beq ?done2
        inx
        jmp ?col
?done2  jmp cm_flush                 ; tail-call: copy the last pending run
.endp
