;--------------------------------------------------------------
; collision.asm -- part of renderer.asm (icl in place): wall collision. A BSP range
;   query gathers the cells near the player; each blocking seg is distance-tested.
;--------------------------------------------------------------
coll_cx   = zp_rx                    ; candidate point (tested position)   [in]
coll_cy   = zp_ry
coll_ax   = zp_X1                    ; seg endpoint A  (walk: node dxp/dyp)
coll_ay   = zp_Z1
coll_bx   = zp_X2                    ; seg endpoint B  (seg_blocks: max-floor/min-ceil acc)
coll_by   = zp_Z2
coll_dx   = zp_rx1                   ; b-a   (walk: node dx)
coll_dy   = zp_ry1                   ;       (walk: node dy)
coll_px   = zp_rx2                   ; cand-a  (reused cand-b in the endpoint-B case)
coll_py   = zp_ry2
coll_t    = cx_p1                    ; 32-bit dot product t  (reused as r2*dd / r2*nn)
coll_dd   = m_ma                     ; 32-bit dd = dx^2+dy^2  (umul16/smul32 leave it)
coll_cr   = cx_a                     ; 32-bit cross product (spans cx_a..cx_b)

;--------------------------------------------------------------
; coll_sq -- m_prod(4,unsigned) = (m_a signed16)^2.  Tail-calls umul16.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_sq
        rep #$20                     ; ---- 16-bit A: |m_a| in the accumulator
        .LONGA ON                    ;   (m_neg was the same two's complement)
csq_w16                              ; (2026-09-22: 16-bit callers enter here)
        lda m_a
        bpl ?p
        eor #$FFFF
        inc @
        sta m_a
?p      sta m_b
        sep #$20
        .LONGA OFF
        phx                          ; the tail call kept X: umul16 no longer does
        jsr umul16
        plx
        rts
.endp
        .endseg

;--------------------------------------------------------------
; coll_d2lt -- A=1 if coll_px^2 + coll_py^2 < PLAYER_R2 (=256), else 0.
;   (< 256  <=>  the squared distance's high 3 bytes are all zero.)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_d2lt
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
cdl_w16                              ; (2026-09-22: 16-bit callers enter here)
        lda coll_px
        sta m_a
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_sq.csq_w16      ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$20
        .LONGA ON
        lda m_prod                   ; -> coll_t, two words
        sta coll_t
        lda m_prod+2
        sta coll_t+2
        lda coll_py
        sta m_a
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_sq.csq_w16      ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$21                     ; ---- 16-bit A, C=0: the 32-bit sum as two
        .LONGA ON                    ;   word adds
        lda coll_t
        adc m_prod
        sta coll_t
        lda coll_t+2
        adc m_prod+2
        sta coll_t+2
        sep #$20
        .LONGA OFF
        lda coll_k                   ; 2026-09-26: the player's k is 0 -- skip the
        beq ?k0                      ;   call (phx/ldx/beq/plx/rts, ~25 cycles) then
        jsr coll_shr2k               ; ...and "< 256" now means "< 256 << 2k"
?k0     lda coll_t+1
        ora coll_t+2
        ora coll_t+3
        bne ?no
        lda #1
        rts
?no     lda #0
        rts
.endp
        .endseg

;--------------------------------------------------------------
; coll_dist_hit -- A=1 if candidate (coll_cx,coll_cy) is within PLAYER_R of
;   segment [A=(coll_ax,coll_ay), B=(coll_bx,coll_by)].  No division (mirrors
;   gui.py seg_hit): endpoint regions use true squared distance, the interior
;   uses the perpendicular distance cross^2 < r2*dd.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_dist_hit
        rep #$20                     ; ---- 16-bit A: the four deltas
        .LONGA ON
cdh_w16                              ; (coll_seg jumps in here already 16-bit)
        sec                          ; dx = bx-ax
        lda coll_bx
        sbc coll_ax
        sta coll_dx
        sec                          ; dy = by-ay
        lda coll_by
        sbc coll_ay
        sta coll_dy
        sec                          ; px = cx-ax
        lda coll_cx
        sbc coll_ax
        sta coll_px
        sec                          ; py = cy-ay
        lda coll_cy
        sbc coll_ay
        sta coll_py
        ; t = px*dx + py*dy  (signed 32) -> coll_t.
        lda coll_dx
        bne ?tx
        stz coll_t                   ; dx = 0 -> px*dx = 0 (two word stz's)
        stz coll_t+2
        bra ?ty
?tx     sta m_b                      ; (A = dx, just tested)
        lda coll_px
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul32
        rep #$20
        .LONGA ON
        lda m_prod
        sta coll_t
        lda m_prod+2
        sta coll_t+2
?ty     lda coll_dy
        beq ?tdone                   ; dy = 0 -> py*dy = 0, nothing to add
        sta m_b                      ; (A = dy)
        lda coll_py
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul32
        rep #$21                     ; C=0
        .LONGA ON
        lda coll_t
        adc m_prod
        sta coll_t
        lda coll_t+2
        adc m_prod+2
        sta coll_t+2
?tdone  lda coll_t+2                 ; t <= 0 ? -> nearest is endpoint A
        bmi ?endA                    ; t < 0  (px,py already = cand-A)
        ora coll_t
        beq ?endA                    ; t == 0
        lda coll_dx                  ; dd = dx^2 + dy^2 -> coll_dd (same zero
        bne ?ddx                     ;   skip as t above)
        stz coll_dd
        stz coll_dd+2
        bra ?ddy
?ddx    sta m_a                      ; (dx is in A)
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_sq.csq_w16      ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$20
        .LONGA ON
        lda m_prod
        sta coll_dd
        lda m_prod+2
        sta coll_dd+2
?ddy    lda coll_dy
        beq ?ddone
        sta m_a
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_sq.csq_w16      ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$21
        .LONGA ON
        lda coll_dd
        adc m_prod
        sta coll_dd
        lda coll_dd+2
        adc m_prod+2
        sta coll_dd+2
?ddone  lda coll_t                   ; t >= dd ? (both > 0) -> nearest is endpoint B
        cmp coll_dd                  ;   (a 32-bit unsigned compare: low word sets
        lda coll_t+2                 ;    the borrow, the high word's sbc reads it)
        sbc coll_dd+2
        bcc ?perp                    ; t < dd -> interior (C = 1 past it: no sec)
        lda coll_cx                  ; px = cx-bx ; py = cy-by
        sbc coll_bx
        sta coll_px
        sec
        lda coll_cy
        sbc coll_by
        sta coll_py
?endA
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jmp coll_d2lt.cdl_w16    ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
?perp   lda coll_dy                  ; cross = px*dy - py*dx -> coll_cr (third
        bne ?crx                     ;   and last zero skip in this routine)
        stz coll_cr
        stz coll_cr+2
        bra ?cry
?crx    sta m_b                      ; (A = dy, the bne's)
        lda coll_px
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul32
        rep #$20
        .LONGA ON
        lda m_prod
        sta coll_cr
        lda m_prod+2
        sta coll_cr+2
?cry    lda coll_dx
        beq ?crdone
        sta m_b                      ; (A = dx)
        lda coll_py
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul32
        rep #$20
        .LONGA ON
        sec
        lda coll_cr
        sbc m_prod
        sta coll_cr
        lda coll_cr+2
        sbc m_prod+2
        sta coll_cr+2
?crdone lda coll_cr+2                ; |cross| >= 65536 -> too far. THE SIGN CASE
                                     ;   IS THE SAME EXIT: the byte code negated ...
        bne ?no
        lda coll_dd+2                ; dd >= 2^24 -> r2*dd >= 2^32 > cross^2 -> within
        cmp #256
        bcs ?yes
        lda coll_cr                  ; csq = |cross|_lo16 ^2  (umul16)
        sta m_a
        sta m_b
        sep #$20
        .LONGA OFF
        jsr umul16                   ; m_prod = cross^2
        stz coll_t                   ; r2dd = dd << 8  (r2 = 256) -> coll_t
        lda coll_dd
        sta coll_t+1
        lda coll_dd+1
        sta coll_t+2
        lda coll_dd+2
        sta coll_t+3
        lda coll_k                   ; (2026-09-26: k = 0 -> no call, as coll_d2lt)
        beq ?k0
        jsr coll_shl2k               ; r2 = 256 << 2k, not 256
?k0     rep #$20                     ; blocked iff cross^2 < r2*dd (32-bit)
        .LONGA ON
        lda m_prod
        cmp coll_t
        lda m_prod+2
        sbc coll_t+2
        bcc ?yes
?no     sep #$20
        .LONGA OFF
        lda #0
        rts
?yes    sep #$20
        .LONGA OFF
        lda #1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; coll_vptr / coll_secptr -- zp_ptr = table base + index(m_a)*stride.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_vptr                      ; MAP_VERTS + idx*4 (EXT bank offset)
        rep #$20                     ; ---- 16-bit A: MAP_VERTS + idx*4 in the
        .LONGA ON                    ;   accumulator (m_x4 + a byte add before).
        lda m_a                      ;   idx < 16384, so the asl's shift out 0s
        asl @                        ;   and the adc rides on that C=0
        asl @
        adc #MAP_VERTS
        sta zp_ptr
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; coll_secheights -- sector index m_a -> coll_ax = floor_h, coll_ay = ceil_h.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_secheights
        rep #$20                     ; ---- 16-bit A: MAP_SECTORS + idx*8, then
        .LONGA ON                    ;   floor_h and ceil_h as words
csh_w16                              ; (2026-09-22: 16-bit callers enter here)
        lda m_a                      ;   (idx < 8192: the asl's carry out 0)
csh_a16                              ; (16-bit, the index already in A)
        asl @
        asl @
        asl @
        adc #MAP_SECTORS
        sta zp_ptr
        lda (zp_ptr)
        sta coll_ax
        ldy #2
        lda (zp_ptr),y
        sta coll_ay
                                     ; 2026-09-22: returns 16-bit -- every caller went
        rts                          ;   on with a rep (65816-windows: no empty pair)
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; coll_seg -- zp_sptr -> seg record. A=1 if this seg BLOCKS the candidate:
;   one-sided wall, or 2-sided with opening < PLAYER_H, AND within radius.
;   seg layout: see the SEG_* equs in memory_map.inc.
;--------------------------------------------------------------
; coll_seg + collide_leaf are parked at COLLFAST_BASE (tail of the tw_runs
; page): collision.asm swapped places with tw_runs (2026-07-28, see
; memory_map.inc) and its new $AAF0 slot is 304 B too small for the whole file.
; Cold code sitting in fast RAM costs nothing -- it is parking, not placement.
;--------------------------------------------------------------
; PER-KIND WALL RADIUS (p_map.c P_CheckPosition builds tmbbox from the MOVING
;   thing's radius; this port had the constant PLAYER_R2 = 256 for every kind).
;   coll_k = log2(R/16) -- 0, 1 or 3 -- and coll_rp1 = R+1 for the axis test.
;--------------------------------------------------------------
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
coll_k    dta 0                      ; 0 = R16, 1 = R32, 3 = R128
coll_rp1  dta a(17)                  ; R+1, the axis fast path's compare. A
                                     ;   WORD: collide_blocked compares 16-bit; ...
coll_rtab dta 17,33,0,129            ; ...indexed by coll_k (2 is unused)
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_shl2k                     ; coll_t <<= 2*coll_k
        phx
        ldx coll_k
        beq ?done
        rep #$20                     ; ---- 16-bit A: the LOW word shifts in A and
        .LONGA ON                    ;   is stored once, only the high word stays
        lda coll_t                   ;   an RMW (every caller reloads A after)
?a      asl @
        rol coll_t+2
        asl @
        rol coll_t+2
        dex
        bne ?a
        sta coll_t
        sep #$20
        .LONGA OFF
?done   plx
        rts
.endp
        .endseg

collf_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_seg
        ldy #SEG_BACK                ; back_sec
        lda [zp_sptr],y
        cmp #NO_SECTOR               ; one-sided?
        jeq ?wall                    ; (Jcc: the step rule pushed ?wall past the
        ldy #SEG_WALL                ;   short-branch window, 2026-09-15)
        lda [zp_sptr],y              ; ML_BLOCKING? col_a bit7 -> impassable 2-sided line
        jmi ?wall
        rep #$20                     ; front sector heights -> acc in coll_bx/coll_by
        .LONGA ON                    ;   (the index straight in A: csh_a16)
        ldy #SEG_FRONT
        lda [zp_sptr],y
        and #$00FF
        jsr coll_secheights.csh_a16  ; (returns 16-bit)
        lda coll_ax                  ; max-floor acc = ffloor
        sta coll_bx
        sta coll_cr                  ; ...and the FRONT floor kept for the step rule
        lda coll_ay                  ; min-ceil acc = fceil
        sta coll_by
        ldy #SEG_BACK                ; back sector heights -> coll_ax/coll_ay
        lda [zp_sptr],y
        and #$00FF
        jsr coll_secheights.csh_a16  ; (returns 16-bit: no rep)
        sec                          ; max-floor = max(ffloor, bfloor) (signed16)
        lda coll_ax
        sbc coll_bx
        bvc ?mf
        eor #$8000
?mf     bmi ?keepf                   ; bfloor < acc -> keep
        lda coll_ax
        sta coll_bx
?keepf  sec                          ; min-ceil = min(fceil, bceil) (signed16)
        lda coll_ay
        sbc coll_by
        bvc ?mc
        eor #$8000
?mc     bpl ?keepc                   ; bceil >= acc -> keep
        lda coll_ay
        sta coll_by
?keepc
        ; BUG FIX 2026-09-15 (E2M1 1510,-497: "cez toto okno mozem niekedy prejst ...
        lda coll_stepchk             ; (a byte: mask the neighbour)
        and #$00FF
        beq ?nostep
        ; hned vlavo").
        sec                          ; lo = min(front floor, back floor):
        lda coll_ax                  ;   coll_cr = front (saved at the load),
        sbc coll_cr                  ;   coll_ax = back
        bvc ?sv1
        eor #$8000
?sv1    bmi ?blo
        lda coll_cr
        bra ?hlo
?blo    lda coll_ax
?hlo    sta coll_cr+2                ; ref = max(lo, cur_floor)
        sec
        sbc cur_floor
        bvc ?sv2
        eor #$8000
?sv2    bpl ?ref
        lda cur_floor
        sta coll_cr+2
?ref    sec
        lda coll_bx                  ; the higher floor of the two sides
        sbc coll_cr+2                ;   minus the reference
        bvc ?sv
        eor #$8000
?sv     bmi ?nostep                  ; level or a drop: no climb
        cmp #MAXSTEP+1
        bcs ?wall                    ; too big a step up
?nostep
        sec                          ; opening = min-ceil - max-floor = coll_by - coll_bx
        lda coll_by
        sbc coll_bx
        bmi ?wall                    ; opening < 0 (overlap/closed) -> blocks
        cmp #256
        bcs ?notblock                ; opening >= 256 -> open
                                      ; DRAC_PLAN 5: no 8-bit window: A < 256 here (the bcs
cs_hmin = *+1                        ;   above), so the 16-bit cmp is the byte
        cmp #PLAYER_H                ;   compare; cs_hmin still names the LOW
        bcs ?notblock                ;   byte bl_wall patches (?notblock seps)
        tay                          ; Z from the low byte, as before
        bne ?wall
        inc coll_solid               ; a 16-bit cell now (bsp_main_player.asm)
?wall   rep #$20                     ; ---- 16-bit A (reached in either mode: rep
                                     ;   is idempotent): v1 -> endpoint A, v2 -> B,
        .LONGA ON                    ;   each a word index and two word reads
                                      ; 2026-09-22: coll_vptr inlined (6502-idioms: its
        lda [zp_sptr]                ;   body is smaller than the call) -- the index is
        asl @                        ;   already in A: *4 + MAP_VERTS. idx < 16384, so
        asl @                        ;   the asl's shift out 0s and the adc rides on C=0
        adc #MAP_VERTS
        sta zp_ptr
        lda [zp_ptr]
        sta coll_ax
        ldy #2
        lda [zp_ptr],y
        sta coll_ay
        lda [zp_sptr],y              ; (Y = 2: v2)
        asl @
        asl @
        adc #MAP_VERTS
        sta zp_ptr
        lda [zp_ptr]
        sta coll_bx
                                      ; 2026-09-22 (drac030 RELOAD): Y is still 2 (v2's read above)
        lda [zp_ptr],y
        sta coll_by
        jmp coll_dist_hit.cdh_w16    ; still 16-bit: past its rep (A=1 if within radius)
?notblock
        sep #$20                     ; (reached in either mode)
        .LONGA OFF
        lda #0
        rts
.endp
        .endseg

;--------------------------------------------------------------
; collide_leaf -- test every seg of the subsector (zp_nid leaf). A=1 if any
;   blocking seg is within radius of the candidate. (Same seg indexing as
;   render_subsector, but calls coll_seg.)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc collide_leaf
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
clf_w16                              ; (2026-09-22: 16-bit callers enter here)
        lda zp_nid                   ; ssptr = MAP_SSECT + (nid&$7FFF)*4
        and #$7FFF
        asl @                        ; (a subsector index is far below 16384: the
        asl @                        ;  asl's shift out 0s, C=0 for the adc)
        adc #MAP_SSECT
        sta zp_ptr
        lda [zp_ptr]                 ; first seg
        asl @                        ; zp_sptr = MAP_SEGS + first*SEG_SIZE (8)
        asl @
        asl @
        adc #MAP_SEGS
        sta zp_sptr
        ldy #2                       ; count
        lda [zp_ptr],y
        sta zp_segcnt
        sep #$20
        .LONGA OFF
        beq ?clear                   ; (Z from the lda: no segs at all)
?loop   jsr coll_seg
        bne ?blocked
        rep #$21                     ; ---- 16-bit A, C=0: next seg, count down
        .LONGA ON
        lda zp_sptr
        adc #SEG_SIZE
        sta zp_sptr
        dec zp_segcnt                ; (one 16-bit RMW, 2026-09-15)
        sep #$20                     ; (sep keeps Z: the count's)
        .LONGA OFF
        bne ?loop
?clear  lda #0
        rts
?blocked
        lda #1
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_shr2k                     ; coll_t >>= 2*coll_k, so coll_d2lt's
        phx                          ;   "< 256" means "< 256 << 2k"
        ldx coll_k
        beq ?done
        rep #$20                     ; the low word shifts in A, stored once
        .LONGA ON                    ;   (as coll_shl2k)
        lda coll_t
?a      lsr coll_t+2
        ror @
        lsr coll_t+2
        ror @
        dex
        bne ?a
        sta coll_t
        sep #$20
        .LONGA OFF
?done   plx
        rts
.endp
        .endseg

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org collf_resume

;--------------------------------------------------------------
; collide_blocked -- IN: coll_cx,coll_cy (candidate). OUT: A=1 if the player
;   (radius PLAYER_R) would overlap a blocking wall there.
;--------------------------------------------------------------
cbsp_resume = *
        org COLLBSP_BASE             ; the axis fast path pushed the $AB00 block
                                     ; past HUDCODE_BASE.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc collide_blocked
        stz bsp_sp
        rep #$20                     ; ---- 16-bit A for the whole walk; the mode
        .LONGA ON                    ;   drops to 8 around each jsr and comes back
        lda MAP_HROOT                 ; root node index (map header, per level)
        sta zp_nid
?walk   lda zp_nid
?walka  jmi ?leaf                    ; bit 15 = leaf (MADS Jcc: long when far)
                                      ; 2026-09-26: calc_nodeptr INLINED (no jsr/rts a
        asl @                        ;   node); ?walka: the descents arrive with A =
        asl @                        ;   the node just stored and N from its lda
        sta m_ma
        asl @
        asl @
        asl @                        ; nid*32 (the leaf bit and bit 14 fall out)
        sec
        sbc m_ma                     ; nid*28 = NODE_SIZE
        adc #MAP_NODES-1             ; C=1 here
        sta zp_nodeptr
        sec                          ; dxp = cx - node.x -> coll_ax
        lda coll_cx
        sbc [zp_nodeptr]
        sta coll_ax
        ldy #2                       ; dyp = cy - node.y -> coll_ay
        sec
        lda coll_cy
        sbc [zp_nodeptr],y
        sta coll_ay
        ldy #4                       ; ndx -> coll_dx
        lda [zp_nodeptr],y
        sta coll_dx
        ldy #6                       ; ndy -> coll_dy
        lda [zp_nodeptr],y
        sta coll_dy
        ldy #8                       ; near = child_r, far = child_l. Read HERE:
        lda [zp_nodeptr],y           ;   both the axis paths below and the
        sta zp_near                  ;   general one need them
        ldy #10
        lda [zp_nodeptr],y
        sta zp_far
        ; ===== AXIS-ALIGNED NODE (74 % of DOOM's): the range test collapses to
        ;       |d| <= R -- the .else side proves it is the SAME decision =====
        lda coll_dx
        beq ?axisv
        lda coll_dy
        jne ?general                 ; (jne: coll_* left zero page 2026-09-23, the
        ;bra ?general                ;   span grew past a short branch)
?axish  ; ---- ndy = 0: horizontal split, cross = -ndx*dyp -------------------
        lda coll_dx                  ; sign(cross) = NOT(sign(ndx) XOR sign(dyp)),
        eor coll_ay                  ;   in bit 15 of a word (coll_t's low word)
        eor #$8000
        sta coll_t
        lda coll_dx                  ; m_a = |ndx|
        bpl ?ha
        eor #$FFFF
        inc @
?ha     sta m_a
        lda coll_ay                  ; m_b = |dyp|
        bpl ?hb
        eor #$FFFF
        inc @
?hb     sta m_b                      ; Z = (|dyp| == 0) on both ways in; |ndx| != 0
        bne ?axsgn                   ;   here (dx != 0 got us here)
        bra ?axswap
?axisv  ; ---- ndx = 0: vertical split, cross = ndy*dxp ----------------------
        lda coll_dy                  ; sign(cross) = sign(ndy) XOR sign(dxp)
        eor coll_ax
        sta coll_t
        lda coll_dy                  ; m_a = |ndy|
        bpl ?va
        eor #$FFFF
        inc @
?va     sta m_a
        lda coll_ax                  ; m_b = |dxp|
        bpl ?vb
        eor #$FFFF
        inc @
?vb     sta m_b                      ; a zero factor -> cross = 0 -> side1, and
        beq ?axswap                  ;   the far cell is certainly within R (Z of
        lda m_a                      ;   |dxp| from the lda or the inc)
        beq ?axswap
?axsgn  lda coll_t                   ; cross > 0 -> side0 -> keep near = child_r
        bpl ?axside
?axswap lda zp_near                  ; cross <= 0 -> point on side1 -> swap
        pha
        lda zp_far
        sta zp_near
        pla
        sta zp_far
?axside sep #$20
        .LONGA OFF
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16                   ; |cross| = |n| * |d|
        plx
        rep #$20
        .LONGA ON
        lda m_prod+2                 ; |cross| >= 65536 -> far cell out of range
        jne ?descend
        lda m_a                      ; nn = n^2 >= 2^24  <=>  |n| >= 4096, and
        cmp #4096                    ;   then the original pushes unconditionally
        jcs ?pushfar
        lda m_b                      ; |d| <= R ? (coll_rp1 = R+1, a word whose
        cmp coll_rp1                 ;   high byte is a permanent 0)
        jcs ?descend
        jmp ?pushfar
?general
        lda coll_dy                  ; cross = ndy*dxp - ndx*dyp -> coll_cr
        sta m_a
        lda coll_ax
        sta m_b
        sep #$20
        .LONGA OFF
        jsr smul32
        rep #$20
        .LONGA ON
        lda m_prod
        sta coll_cr
        lda m_prod+2
        sta coll_cr+2
        lda coll_dx
        sta m_a
        lda coll_ay
        sta m_b
        sep #$20
        .LONGA OFF
        jsr smul32
        rep #$20
        .LONGA ON
        sec
        lda coll_cr
        sbc m_prod
        sta coll_cr
        lda coll_cr+2
        sbc m_prod+2
        sta coll_cr+2                ; cross <= 0 -> point on side1 -> swap near/far
        bmi ?swap                    ;   (sta leaves sbc's N alone)
        ora coll_cr
        bne ?noswap
?swap   lda zp_near
        pha
        lda zp_far
        sta zp_near
        pla
        sta zp_far
?noswap lda coll_cr+2                ; abs(cross), all 32 bits
        bpl ?crp
        sec
        lda #0
        sbc coll_cr
        sta coll_cr
        lda #0
        sbc coll_cr+2
        sta coll_cr+2
?crp    lda coll_cr+2                ; |cross| >= 65536 -> far cell is out of range
        jne ?descend
        lda coll_dx                  ; nn = ndx^2 + ndy^2 -> coll_dd
        sta m_a
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_sq.csq_w16      ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$20
        .LONGA ON
        lda m_prod
        sta coll_dd
        lda m_prod+2
        sta coll_dd+2
        lda coll_dy
        sta m_a
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr coll_sq.csq_w16      ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        rep #$21                     ; C=0
        .LONGA ON
        lda coll_dd
        adc m_prod
        sta coll_dd
        lda coll_dd+2
        adc m_prod+2
        sta coll_dd+2                ; nn >= 2^24 -> r2*nn huge -> always within
        cmp #256
        jcs ?pushfar
        sep #$20
        .LONGA OFF
        stz coll_t                   ; r2nn = nn << 8 -> coll_t
        lda coll_dd
        sta coll_t+1
        lda coll_dd+1
        sta coll_t+2
        lda coll_dd+2
        sta coll_t+3
        lda coll_k                   ; (2026-09-26: k = 0 -> no call, as coll_d2lt)
        beq ?k0
        jsr coll_shl2k               ; the DESCENT has to widen too, or the walk
?k0     lda coll_cr                  ; csq = |cross|_lo16 ^2
        sta m_a
        sta m_b
        lda coll_cr+1
        sta m_a+1
        sta m_b+1
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16
        plx
        rep #$20
        .LONGA ON
        lda coll_t                   ; within iff cross^2 <= r2*nn (32-bit)
        cmp m_prod
        lda coll_t+2
        sbc m_prod+2
        bcc ?descend                 ; r2nn < cross^2 -> far cell out of range
?pushfar
        ldx bsp_sp                   ; push the far child (one word)
        lda zp_far
        sta bsp_stack,x
        inx
        inx
        stx bsp_sp
?descend
        lda zp_near
        sta zp_nid
        jmp ?walka                   ; (A, N = the new node: no reload, 2026-09-26)
?leaf
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr collide_leaf.clf_w16 ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
        bne ?yes
        ldx bsp_sp
        beq ?no
        dex
        dex
        stx bsp_sp
        rep #$20
        .LONGA ON
        lda bsp_stack,x
        sta zp_nid
        jmp ?walka                   ; (as ?descend, 2026-09-26)
        .LONGA OFF
?no     lda #0
        rts
?yes    lda #1
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_plr                       ; ...and the PLAYER's probe (and ball.asm's
        stz coll_k                   ;   -- MT_TROOPSHOT's radius is 6, so 16 is
        ldy #17                      ;   what it always meant). Naming the radius
        sty coll_rp1                 ;   at the call site beats trusting whoever
        jmp collide_blocked          ;   ran last to have put it back.
.endp
        .endseg
;   coll_plrs -- move_player's probe: coll_plr WITH the step-up rule (coll_seg,
;   BUG FIX 2026-09-15). stz sets no flag, so the caller's `bne` still reads
;   collide_blocked's answer.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_plrs
        lda #1
        sta coll_stepchk
        jsr coll_plr
        stz coll_stepchk
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a
coll_stepchk dta 0                   ; 1 = coll_seg applies P_TryMove's step-up rule
        .endseg

    .if * > COLLBSP_END+1
        ert 'collide_blocked outgrew COLLBSP_BASE..END (memory_map.inc)'
    .endif
        org cbsp_resume

;--------------------------------------------------------------
; coll_step_ok -- step-up gate (DOOM P_TryMove). A=1 if moving to the candidate
;   (coll_cx,coll_cy) would climb MORE than MAXSTEP onto the destination floor
;   (must take the stairs instead), else A=0. Probes the candidate's sector floor
;   via locate_floor by briefly borrowing zp_px/zp_py, then restores them.
;   cur_floor (floor under the player pre-move) is set once by move_player.
;--------------------------------------------------------------
coll_svx  = zp_X1                    ; saved player pos across the floor probe
coll_svy  = zp_Z1                    ;   (dead render scratch; coll_step_ok runs
                                     ;    before collide_blocked, no overlap)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_step_ok
        pei (zp_px)                  ; the real player pos, parked on the stack
        pei (zp_py)                  ;   (pei is M-blind; pla below is 16-bit)
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        lda coll_cx                  ; pos := candidate
        sta zp_px
        lda coll_cy
        sta zp_py
        sep #$20
        .LONGA OFF
        jsr locate_floor             ; loc_floor = destination sector floor
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        .LONGA ON
        pla                          ; restore real player pos (py was pushed last)
        sta zp_py
        pla
        sta zp_px
        sec                          ; step = dest - current
        lda loc_floor
        sbc cur_floor                ; step > MAXSTEP ? (signed: step < 0 -> ok;
        bmi ?ok                      ;   else one unsigned compare covers both
        cmp #MAXSTEP+1               ;   "step >= 256" and "step >= 25")
        bcs ?block
?ok     sep #$20
        .LONGA OFF
        lda #0
        rts
?block  sep #$20
        lda #1
        rts
.endp
        .endseg

