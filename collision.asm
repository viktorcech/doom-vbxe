;--------------------------------------------------------------
; RAM BUDGET: 1116 B free, biggest contiguous block 253 B.
;   Full map: the generated RAM-BUDGET block at the top of memory_map.inc.
;   Print it any time with:  python tools/ram_map.py
;
; BEFORE YOU ADD CODE ANYWHERE, read this: some RAM looks free to MADS and is
; NOT. It carries no XEX segment, so the assembler places code there happily --
; and then something overwrites it at runtime, before the first frame:
;     $1000-$13FF  TEX_STAGE   -- the SIO staging buffer, every loader streams here
;     $4000-$4BFF  map slot    -- load_level streams the level here
;                              ($4C00-$85FF was the seg table until
;                               2026-07-31; it is ordinary RAM now)
;     $9000-$9FFF  MEMAC window-- writes go to VBXE, not to RAM
;     $1400-$14FF  bsp_stack   -- rebuilt every frame ($1500+ is CODE now)
;     $0700-$08FF  ATR boot loader, alive WHILE the XEX loads
; There is no error message. The symptom is a flat pink screen at boot. It has
; already cost one debugging session ($A800 blit segment crept past $B000).
;
; When a segment runs out of room, move a whole .proc out with `org` + absolute
; jsr -- that is why collision sits at $0900, check_bbox at $1B00 and tw_setup at
; $8D00 -- instead of letting the segment creep into the next thing.
;
; Guards, all three wired into build.ps1 / build_atr.ps1:
;   * the RESERVED list in tools/ram_map.py (check_xex.py enforces it)
;   * tools/check_xex.py                    (fails the build on any overlap)
;   * tools/ram_map.py --update             (regenerates these figures)
;--------------------------------------------------------------
; AUTO-SPLIT from renderer.asm -- assembled in place via icl (org wrap stays in renderer.asm).

;==============================================================
; COLLISION (M5) -- "can't walk through walls". Faithful port of gui.py's
;   verified spec (pos_ok / collide_cells / seg_hit): a BSP range query gathers
;   the few cells within the player radius of the candidate point, then each
;   blocking seg of those cells is distance-tested. Solid (one-sided) walls and
;   two-sided lines with a <PLAYER_H opening block; step-up is NOT checked (the
;   floor follow update_pz already lets you walk up stairs). X-then-Y slide in
;   move_player (bsp_main.asm) makes the player slide along walls.
;
; RAM: no new zero page (page 0 is ~full). All scratch ALIASES the per-seg
;   RENDER working set, which is dead during movement (move_player runs in the
;   game loop BEFORE render_world). The math uses umul16/smul32 (-> m_a/m_b/
;   m_prod/m_sign) which never touch the alias slots below; calc_nodeptr clobbers
;   m_ma, but coll_dd(=m_ma) is only built AFTER the per-node calc_nodeptr.
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
.proc coll_sq
        lda m_a+1
        bpl ?p
        jsr m_neg                    ; abs(m_a)
?p      lda m_a
        sta m_b
        lda m_a+1
        sta m_b+1
        jmp umul16
.endp

;--------------------------------------------------------------
; coll_d2lt -- A=1 if coll_px^2 + coll_py^2 < PLAYER_R2 (=256), else 0.
;   (< 256  <=>  the squared distance's high 3 bytes are all zero.)
;--------------------------------------------------------------
.proc coll_d2lt
        lda coll_px
        sta m_a
        lda coll_px+1
        sta m_a+1
        jsr coll_sq                  ; m_prod = px^2
        ldx #3
?cp     lda m_prod,x
        sta coll_t,x
        dex
        bpl ?cp
        lda coll_py
        sta m_a
        lda coll_py+1
        sta m_a+1
        jsr coll_sq                  ; m_prod = py^2
        clc
        lda coll_t
        adc m_prod
        sta coll_t
        lda coll_t+1
        adc m_prod+1
        sta coll_t+1
        lda coll_t+2
        adc m_prod+2
        sta coll_t+2
        lda coll_t+3
        adc m_prod+3
        sta coll_t+3
        jsr coll_shr2k               ; ...and "< 256" now means "< 256 << 2k"
        lda coll_t+1
        ora coll_t+2
        ora coll_t+3
        bne ?no
        lda #1
        rts
?no     lda #0
        rts
.endp

;--------------------------------------------------------------
; coll_dist_hit -- A=1 if candidate (coll_cx,coll_cy) is within PLAYER_R of
;   segment [A=(coll_ax,coll_ay), B=(coll_bx,coll_by)].  No division (mirrors
;   gui.py seg_hit): endpoint regions use true squared distance, the interior
;   uses the perpendicular distance cross^2 < r2*dd.
;--------------------------------------------------------------
.proc coll_dist_hit
        sec                          ; dx = bx-ax
        lda coll_bx
        sbc coll_ax
        sta coll_dx
        lda coll_bx+1
        sbc coll_ax+1
        sta coll_dx+1
        sec                          ; dy = by-ay
        lda coll_by
        sbc coll_ay
        sta coll_dy
        lda coll_by+1
        sbc coll_ay+1
        sta coll_dy+1
        sec                          ; px = cx-ax
        lda coll_cx
        sbc coll_ax
        sta coll_px
        lda coll_cx+1
        sbc coll_ax+1
        sta coll_px+1
        sec                          ; py = cy-ay
        lda coll_cy
        sbc coll_ay
        sta coll_py
        lda coll_cy+1
        sbc coll_ay+1
        sta coll_py+1
        ; t = px*dx + py*dy  (signed 32) -> coll_t
        ; MOST DOOM WALLS ARE AXIS ALIGNED, i.e. dx or dy is exactly 0, and
        ; then the matching product is 0 and adding it changes nothing. Every
        ; multiply below is skipped on that test -- ~300 cycles each, three
        ; times over in this routine, inside collide_leaf's per-seg loop (4505
        ; cycles a leaf, tools/_dbg_aicost.py). Skipping a multiply by zero is
        ; not an approximation, so no distance test moves by a bit.
        lda coll_dx
        ora coll_dx+1
        bne ?tx
        lda #0                       ; dx = 0 -> px*dx = 0
        sta coll_t
        sta coll_t+1
        sta coll_t+2
        sta coll_t+3
        beq ?ty                      ; always
?tx     lda coll_px
        sta m_a
        lda coll_px+1
        sta m_a+1
        lda coll_dx
        sta m_b
        lda coll_dx+1
        sta m_b+1
        jsr smul32
        ldx #3
?c1     lda m_prod,x
        sta coll_t,x
        dex
        bpl ?c1
?ty     lda coll_dy
        ora coll_dy+1
        beq ?tdone                   ; dy = 0 -> py*dy = 0, nothing to add
        lda coll_py
        sta m_a
        lda coll_py+1
        sta m_a+1
        lda coll_dy
        sta m_b
        lda coll_dy+1
        sta m_b+1
        jsr smul32
        clc
        lda coll_t
        adc m_prod
        sta coll_t
        lda coll_t+1
        adc m_prod+1
        sta coll_t+1
        lda coll_t+2
        adc m_prod+2
        sta coll_t+2
        lda coll_t+3
        adc m_prod+3
        sta coll_t+3
?tdone
        lda coll_t+3                 ; t <= 0 ? -> nearest is endpoint A
        bpl ?tpos
        jmp coll_d2lt                ; t<0  (px,py already = cand-A)
?tpos   lda coll_t
        ora coll_t+1
        ora coll_t+2
        ora coll_t+3
        bne ?inseg
        jmp coll_d2lt                ; t==0
?inseg  lda coll_dx                  ; dd = dx^2 + dy^2 -> coll_dd (same zero
        ora coll_dx+1                ;   skip as t above: an axis wall squares
        bne ?ddx                     ;   only one of its two components)
        lda #0
        sta coll_dd
        sta coll_dd+1
        sta coll_dd+2
        sta coll_dd+3
        beq ?ddy                     ; always
?ddx    lda coll_dx
        sta m_a
        lda coll_dx+1
        sta m_a+1
        jsr coll_sq
        ldx #3
?c2     lda m_prod,x
        sta coll_dd,x
        dex
        bpl ?c2
?ddy    lda coll_dy
        ora coll_dy+1
        beq ?ddone
        lda coll_dy
        sta m_a
        lda coll_dy+1
        sta m_a+1
        jsr coll_sq
        clc
        lda coll_dd
        adc m_prod
        sta coll_dd
        lda coll_dd+1
        adc m_prod+1
        sta coll_dd+1
        lda coll_dd+2
        adc m_prod+2
        sta coll_dd+2
        lda coll_dd+3
        adc m_prod+3
        sta coll_dd+3
?ddone
        lda coll_t                   ; t >= dd ? (both >0) -> nearest is endpoint B
        cmp coll_dd
        lda coll_t+1
        sbc coll_dd+1
        lda coll_t+2
        sbc coll_dd+2
        lda coll_t+3
        sbc coll_dd+3
        bcc ?perp                    ; t < dd -> interior
        sec                          ; px = cx-bx ; py = cy-by
        lda coll_cx
        sbc coll_bx
        sta coll_px
        lda coll_cx+1
        sbc coll_bx+1
        sta coll_px+1
        sec
        lda coll_cy
        sbc coll_by
        sta coll_py
        lda coll_cy+1
        sbc coll_by+1
        sta coll_py+1
        jmp coll_d2lt
?perp   lda coll_dy                  ; cross = px*dy - py*dx -> coll_cr (third
        ora coll_dy+1                ;   and last zero skip in this routine)
        bne ?crx
        lda #0
        sta coll_cr
        sta coll_cr+1
        sta coll_cr+2
        sta coll_cr+3
        beq ?cry                     ; always
?crx    lda coll_px
        sta m_a
        lda coll_px+1
        sta m_a+1
        lda coll_dy
        sta m_b
        lda coll_dy+1
        sta m_b+1
        jsr smul32
        ldx #3
?c3     lda m_prod,x
        sta coll_cr,x
        dex
        bpl ?c3
?cry    lda coll_dx
        ora coll_dx+1
        beq ?crdone
        lda coll_py
        sta m_a
        lda coll_py+1
        sta m_a+1
        lda coll_dx
        sta m_b
        lda coll_dx+1
        sta m_b+1
        jsr smul32
        sec
        lda coll_cr
        sbc m_prod
        sta coll_cr
        lda coll_cr+1
        sbc m_prod+1
        sta coll_cr+1
        lda coll_cr+2
        sbc m_prod+2
        sta coll_cr+2
        lda coll_cr+3
        sbc m_prod+3
        sta coll_cr+3
?crdone
        lda coll_cr+3                ; abs(cross)
        bpl ?cpos
        sec
        lda #0
        sbc coll_cr
        sta coll_cr
        lda #0
        sbc coll_cr+1
        sta coll_cr+1
        lda #0
        sbc coll_cr+2
        sta coll_cr+2
?cpos   lda coll_cr+2               ; |cross| >= 65536 -> too far (cross^2 > any r2*dd)
        ora coll_cr+3
        bne ?no
        lda coll_dd+3              ; dd >= 2^24 -> r2*dd >= 2^32 > cross^2 -> within
        bne ?yes
        lda coll_cr                 ; csq = |cross|_lo16 ^2  (umul16)
        sta m_a
        sta m_b
        lda coll_cr+1
        sta m_a+1
        sta m_b+1
        jsr umul16                  ; m_prod = cross^2
        stz coll_t                   ; r2dd = dd << 8  (r2 = 256) -> coll_t
        lda coll_dd
        sta coll_t+1
        lda coll_dd+1
        sta coll_t+2
        lda coll_dd+2
        sta coll_t+3
        jsr coll_shl2k               ; r2 = 256 << 2k, not 256
        lda m_prod                  ; blocked iff cross^2 < r2*dd
        cmp coll_t
        lda m_prod+1
        sbc coll_t+1
        lda m_prod+2
        sbc coll_t+2
        lda m_prod+3
        sbc coll_t+3
        bcc ?yes
?no     lda #0
        rts
?yes    lda #1
        rts
.endp

;--------------------------------------------------------------
; coll_vptr / coll_secptr -- zp_ptr = table base + index(m_a)*stride.
;--------------------------------------------------------------
.proc coll_vptr                      ; MAP_VERTS + idx*4 (EXT bank offset)
        jsr m_x4
        clc
        lda m_prod
        adc #<MAP_VERTS              ; readers use [zp_ptr],y; zp_ptr+2 is parked
        sta zp_ptr                   ;   on MAP_EXT_BANK by init_level (read_ext
        lda m_prod+1                 ;   re-sets the same value during loads)
        adc #>MAP_VERTS
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; coll_secheights -- sector index m_a -> coll_ax = floor_h, coll_ay = ceil_h.
;--------------------------------------------------------------
.proc coll_secheights
        jsr m_x8                     ; MAP_SECTORS + idx*8
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        ldy #0
        lda (zp_ptr),y
        sta coll_ax
        iny
        lda (zp_ptr),y
        sta coll_ax+1
        ldy #2
        lda (zp_ptr),y
        sta coll_ay
        iny
        lda (zp_ptr),y
        sta coll_ay+1
        rts
.endp

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
;   r2 = 256 << 2k, so the three places that bake in 256 shift by 2k more and
;   nothing else in the collision code changes. k = 0 is the player and the
;   narrow monsters, and then every loop here spins zero times and the path is
;   bit-identical to what it was.
;     spider 128 -> 128 EXACT, caco 31 -> 32, demon 30 -> 32, baron 24 -> 32,
;     cyberdemon 40 -> 32, imp/zombie 20 -> 16, lost soul 16 -> 16, PLAYER 16.
;   Powers of two because 256 is not a parameter but an optimisation: it turns
;   `cross^2 < r2*dd` into a byte shift. A general r2 needs a 16x32 multiply in
;   the hottest routine in the engine; a power of two keeps it a shift.
;--------------------------------------------------------------
coll_k    dta 0                      ; 0 = R16, 1 = R32, 3 = R128
coll_rp1  dta 17                     ; R+1, the axis fast path's compare
coll_rtab dta 17,33,0,129            ; ...indexed by coll_k (2 is unused)

.proc coll_shl2k                     ; coll_t <<= 2*coll_k
        phx
        ldx coll_k
        beq ?done
?a      asl coll_t
        rol coll_t+1
        rol coll_t+2
        rol coll_t+3
        asl coll_t
        rol coll_t+1
        rol coll_t+2
        rol coll_t+3
        dex
        bne ?a
?done   plx
        rts
.endp

collf_resume = *
        org COLLFAST_BASE
.proc coll_seg
        ldy #SEG_BACK                ; back_sec
        lda [zp_sptr],y
        cmp #NO_SECTOR               ; one-sided?
        beq ?wall
        ldy #SEG_WALL                ; ML_BLOCKING? col_a bit7 -> impassable 2-sided line
        lda [zp_sptr],y
        bmi ?wall
        ldy #SEG_FRONT               ; front sector heights -> acc in coll_bx/coll_by
        lda [zp_sptr],y
        sta m_a
        lda #0
        sta m_a+1
        jsr coll_secheights
        lda coll_ax                  ; max-floor acc = ffloor
        sta coll_bx
        lda coll_ax+1
        sta coll_bx+1
        lda coll_ay                  ; min-ceil acc = fceil
        sta coll_by
        lda coll_ay+1
        sta coll_by+1
        ldy #SEG_BACK                ; back sector heights -> coll_ax/coll_ay
        lda [zp_sptr],y
        sta m_a
        lda #0
        sta m_a+1
        jsr coll_secheights
        lda coll_ax                  ; max-floor = max(ffloor, bfloor) (signed16)
        cmp coll_bx
        lda coll_ax+1
        sbc coll_bx+1
        bvc ?mf
        eor #$80
?mf     bmi ?keepf                   ; bfloor < acc -> keep
        lda coll_ax
        sta coll_bx
        lda coll_ax+1
        sta coll_bx+1
?keepf  lda coll_ay                  ; min-ceil = min(fceil, bceil) (signed16)
        cmp coll_by
        lda coll_ay+1
        sbc coll_by+1
        bvc ?mc
        eor #$80
?mc     bpl ?keepc                   ; bceil >= acc -> keep
        lda coll_ay
        sta coll_by
        lda coll_ay+1
        sta coll_by+1
?keepc  sec                          ; opening = min-ceil - max-floor = coll_by - coll_bx
        lda coll_by
        sbc coll_bx
        sta m_a
        lda coll_by+1
        sbc coll_bx+1
        sta m_a+1
        bmi ?wall                    ; opening < 0 (overlap/closed) -> blocks
        bne ?notblock                ; opening >= 256 -> open
        lda m_a
cs_hmin = *+1                        ; ...and the THRESHOLD is a patchable byte:
        cmp #PLAYER_H                ;   ball.asm's bl_wall drops it to 0 around
        bcs ?notblock                ;   its own call, because 56 is the PLAYER's
                                     ;   clearance and a fireball is 8 tall. It
                                     ;   is always PLAYER_H outside that call --
                                     ;   bl_wall puts it back before it returns.
        tay                          ; OPENING EXACTLY 0 = a SHUT DOOR, and that is
        bne ?wall                    ;   the one barrier the PICKUP must not reach
        inc coll_solid               ;   through. (`tay` and not `cmp #1`: it sets Z
                                     ;   from A in ONE byte and ?wall reloads Y
                                     ;   immediately.) 1..55 is a gap he cannot FIT in
                                     ;   but CAN see through, and p_map.c hands an
                                     ;   item over at the destination of a refused
                                     ;   move (things are checked before lines) --
                                     ;   E1M2's green armour behind its 40-unit
                                     ;   window is exactly that, and must keep
                                     ;   working. DOOM never notices the door case
                                     ;   because its destination is at most
                                     ;   MAXMOVE/2 past the player (p_mobj.c halves
                                     ;   the step); this port steps 24 and reached
                                     ;   through. E2M9's three key skulls sit 32
                                     ;   behind their keyed doors. mp_clamp acts on
                                     ;   this and clears it.
?wall   ldy #0                       ; v1 -> endpoint A
        lda [zp_sptr],y
        sta m_a
        iny
        lda [zp_sptr],y
        sta m_a+1
        jsr coll_vptr
        ldy #0
        lda [zp_ptr],y
        sta coll_ax
        iny
        lda [zp_ptr],y
        sta coll_ax+1
        ldy #2
        lda [zp_ptr],y
        sta coll_ay
        iny
        lda [zp_ptr],y
        sta coll_ay+1
        ldy #2                       ; v2 -> endpoint B
        lda [zp_sptr],y
        sta m_a
        iny
        lda [zp_sptr],y
        sta m_a+1
        jsr coll_vptr
        ldy #0
        lda [zp_ptr],y
        sta coll_bx
        iny
        lda [zp_ptr],y
        sta coll_bx+1
        ldy #2
        lda [zp_ptr],y
        sta coll_by
        iny
        lda [zp_ptr],y
        sta coll_by+1
        jmp coll_dist_hit            ; A=1 if within radius (tail)
?notblock
        lda #0
        rts
.endp

;--------------------------------------------------------------
; collide_leaf -- test every seg of the subsector (zp_nid leaf). A=1 if any
;   blocking seg is within radius of the candidate. (Same seg indexing as
;   render_subsector, but calls coll_seg.)
;--------------------------------------------------------------
.proc collide_leaf
        lda zp_nid                   ; ssptr = MAP_SSECT + (nid&$7FFF)*4
        sta m_a
        lda zp_nid+1
        and #$7F
        sta m_a+1
        jsr m_x4
        clc
        lda m_prod
        adc #<MAP_SSECT
        sta zp_ptr
        lda m_prod+1
        adc #>MAP_SSECT
        sta zp_ptr+1
        ldy #0                       ; first seg
        lda [zp_ptr],y
        sta m_a
        iny
        lda [zp_ptr],y
        sta m_a+1
        ldy #2                       ; count
        lda [zp_ptr],y
        sta zp_segcnt
        iny
        lda [zp_ptr],y
        sta zp_segcnt+1
        jsr m_x8                     ; zp_sptr = MAP_SEGS + first*SEG_SIZE
        clc
        lda m_prod
        adc #<MAP_SEGS
        sta zp_sptr
        lda m_prod+1
        adc #>MAP_SEGS
        sta zp_sptr+1
?loop   lda zp_segcnt
        ora zp_segcnt+1
        beq ?clear
        jsr coll_seg
        bne ?blocked
        clc
        lda zp_sptr
        adc #SEG_SIZE
        sta zp_sptr
        lda zp_sptr+1
        adc #0
        sta zp_sptr+1
        lda zp_segcnt
        bne ?dec
        dec zp_segcnt+1
?dec    dec zp_segcnt
        jmp ?loop
?clear  lda #0
        rts
?blocked
        lda #1
        rts
.endp
.proc coll_shr2k                     ; coll_t >>= 2*coll_k, so coll_d2lt's
        phx                          ;   "< 256" means "< 256 << 2k"
        ldx coll_k
        beq ?done
?a      lsr coll_t+3
        ror coll_t+2
        ror coll_t+1
        ror coll_t
        lsr coll_t+3
        ror coll_t+2
        ror coll_t+1
        ror coll_t
        dex
        bne ?a
?done   plx
        rts
.endp

    .if * > COLLFAST_END+1
        ert 'coll_seg/collide_leaf outgrew COLLFAST_BASE..END (memory_map.inc)'
    .endif
        org collf_resume

;--------------------------------------------------------------
; collide_blocked -- IN: coll_cx,coll_cy (candidate). OUT: A=1 if the player
;   (radius PLAYER_R) would overlap a blocking wall there. BSP range query: walk
;   from the root, always descend the near side, and ALSO visit the far side
;   only when the candidate is within R of the split plane
;   (cross^2 <= R2*(ndx^2+ndy^2), no divide). Reuses the render bsp_stack.
;   This visits exactly the cells a wall-within-R can live in == gui collide_cells.
;--------------------------------------------------------------
cbsp_resume = *
        org COLLBSP_BASE             ; the axis fast path pushed the $AB00 block
                                     ; past HUDCODE_BASE. This is the biggest
                                     ; free run left AND it is below $8000, i.e.
                                     ; inside the accelerator's fast window --
                                     ; the right home for the routine every
                                     ; monster step and every player step runs.
.proc collide_blocked
        stz bsp_sp
        lda MAP_HROOT                 ; root node index (map header, per level)
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
?walk   lda zp_nid+1
        and #$80
        beq ?node
        jmp ?leaf
?node   jsr calc_nodeptr
        ldy #0                       ; dxp = cx - node.x -> coll_ax
        sec
        lda coll_cx
        sbc [zp_nodeptr],y
        sta coll_ax
        iny
        lda coll_cx+1
        sbc [zp_nodeptr],y
        sta coll_ax+1
        ldy #2                       ; dyp = cy - node.y -> coll_ay
        sec
        lda coll_cy
        sbc [zp_nodeptr],y
        sta coll_ay
        iny
        lda coll_cy+1
        sbc [zp_nodeptr],y
        sta coll_ay+1
        ldy #4                       ; ndx -> coll_dx
        lda [zp_nodeptr],y
        sta coll_dx
        iny
        lda [zp_nodeptr],y
        sta coll_dx+1
        ldy #6                       ; ndy -> coll_dy
        lda [zp_nodeptr],y
        sta coll_dy
        iny
        lda [zp_nodeptr],y
        sta coll_dy+1
        ldy #8                       ; near = child_r, far = child_l. Read HERE
        lda [zp_nodeptr],y           ;   now: both the axis paths below and the
        sta zp_near                  ;   general one need them, and the axis
        iny                          ;   paths decide the swap without ever
        lda [zp_nodeptr],y           ;   building a 32-bit cross product.
        sta zp_near+1
        ldy #10
        lda [zp_nodeptr],y
        sta zp_far
        iny
        lda [zp_nodeptr],y
        sta zp_far+1
        ; ===== AXIS-ALIGNED NODE (74 % of DOOM's; the renderer's point_on_side
        ;       and process_seg's backface test already take this road) =======
        ; With ndx = 0 the cross is ndy*dxp and nn = ndy^2, so the range test
        ;   cross^2 <= R2*nn   becomes   (ndy*dxp)^2 <= 256*ndy^2   i.e.
        ;   dxp^2 <= 256, i.e. |dxp| <= 16.
        ; Both sides are exact integers, so that is the SAME DECISION, not a
        ; cheaper approximation of it -- the two smul32 and the two squarings
        ; drop out. One umul16 has to stay: the original gives up at
        ; |cross| >= 65536 BEFORE it looks at nn, and that early-out has to be
        ; reproduced or a monster would start walking through different walls.
        ; ~1800 cycles a node -> ~400, on the routine every monster step and
        ; every player step runs (21552 cycles a call, tools/_dbg_aicost.py).
        lda coll_dx
        ora coll_dx+1
        beq ?axisv
        lda coll_dy
        ora coll_dy+1
        beq ?axish
        jmp ?general                 ; (the axis bodies below are past the
                                     ;  branch window)
?axish  ; ---- ndy = 0: horizontal split, cross = -ndx*dyp -------------------
        lda coll_dx+1                ; sign(cross) = NOT(sign(ndx) XOR sign(dyp))
        eor coll_ay+1
        eor #$80
        sta coll_t
        lda coll_dx                  ; m_a = |ndx|
        sta m_a
        lda coll_dx+1
        sta m_a+1
        jsr ?absa
        lda coll_ay                  ; m_b = |dyp|
        sta m_b
        lda coll_ay+1
        sta m_b+1
        jsr ?absb
        jmp ?axtest
?axisv  ; ---- ndx = 0: vertical split, cross = ndy*dxp ----------------------
        lda coll_dy+1                ; sign(cross) = sign(ndy) XOR sign(dxp)
        eor coll_ax+1
        sta coll_t
        lda coll_dy                  ; m_a = |ndy|
        sta m_a
        lda coll_dy+1
        sta m_a+1
        jsr ?absa
        lda coll_ax                  ; m_b = |dxp|
        sta m_b
        lda coll_ax+1
        sta m_b+1
        jsr ?absb
?axtest lda m_a                      ; a zero factor -> cross = 0 -> side1, and
        ora m_a+1                    ;   the far cell is certainly within R
        beq ?axswap
        lda m_b
        ora m_b+1
        beq ?axswap
        lda coll_t                   ; cross > 0 -> side0 -> keep near = child_r
        bpl ?axside
?axswap lda zp_near                  ; cross <= 0 -> point on side1 -> swap
        ldx zp_far
        sta zp_far
        stx zp_near
        lda zp_near+1
        ldx zp_far+1
        sta zp_far+1
        stx zp_near+1
?axside jsr umul16                   ; |cross| = |n| * |d|
        lda m_prod+2                 ; |cross| >= 65536 -> far cell out of range
        ora m_prod+3
        bne ?axdesc
        lda m_a+1                    ; nn = n^2 >= 2^24  <=>  |n| >= 4096, and
        cmp #16                      ;   then the original pushes unconditionally
        bcs ?axpush
        lda m_b+1                    ; |d| <= 16 = sqrt(PLAYER_R2) ?
        bne ?axdesc
        lda m_b
        cmp coll_rp1                 ; |d| <= R, not the constant 16
        bcs ?axdesc
?axpush jmp ?pushfar
?axdesc jmp ?descend
?absa   lda m_a+1                    ; m_a = |m_a| (signed 16)
        bpl ?absa9
        jsr m_neg
?absa9  rts
?absb   lda m_b+1                    ; m_b = |m_b|
        bpl ?absb9
        jsr m_negb
?absb9  rts
?general
        lda coll_dy                  ; cross = ndy*dxp - ndx*dyp -> coll_cr
        sta m_a
        lda coll_dy+1
        sta m_a+1
        lda coll_ax
        sta m_b
        lda coll_ax+1
        sta m_b+1
        jsr smul32
        ldx #3
?k1     lda m_prod,x
        sta coll_cr,x
        dex
        bpl ?k1
        lda coll_dx
        sta m_a
        lda coll_dx+1
        sta m_a+1
        lda coll_ay
        sta m_b
        lda coll_ay+1
        sta m_b+1
        jsr smul32
        sec
        lda coll_cr
        sbc m_prod
        sta coll_cr
        lda coll_cr+1
        sbc m_prod+1
        sta coll_cr+1
        lda coll_cr+2
        sbc m_prod+2
        sta coll_cr+2
        lda coll_cr+3
        sbc m_prod+3
        sta coll_cr+3                ; cross <= 0 -> point on side1 -> swap near/far
        bmi ?swap                    ;   (sta leaves sbc's N alone -- no reload)
        lda coll_cr
        ora coll_cr+1
        ora coll_cr+2
        ora coll_cr+3
        bne ?noswap
?swap   lda zp_near
        ldx zp_far
        sta zp_far
        stx zp_near
        lda zp_near+1
        ldx zp_far+1
        sta zp_far+1
        stx zp_near+1
?noswap lda coll_cr+3               ; abs(cross)
        bpl ?crp
        sec
        lda #0
        sbc coll_cr
        sta coll_cr
        lda #0
        sbc coll_cr+1
        sta coll_cr+1
        lda #0
        sbc coll_cr+2
        sta coll_cr+2
        lda #0
        sbc coll_cr+3
        sta coll_cr+3
?crp    lda coll_cr+2              ; |cross| >= 65536 -> far cell is out of range
        ora coll_cr+3
        bne ?descend
        lda coll_dx                 ; nn = ndx^2 + ndy^2 -> coll_dd
        sta m_a
        lda coll_dx+1
        sta m_a+1
        jsr coll_sq
        ldx #3
?k2     lda m_prod,x
        sta coll_dd,x
        dex
        bpl ?k2
        lda coll_dy
        sta m_a
        lda coll_dy+1
        sta m_a+1
        jsr coll_sq
        clc
        lda coll_dd
        adc m_prod
        sta coll_dd
        lda coll_dd+1
        adc m_prod+1
        sta coll_dd+1
        lda coll_dd+2
        adc m_prod+2
        sta coll_dd+2
        lda coll_dd+3
        adc m_prod+3
        sta coll_dd+3               ; nn >= 2^24 -> r2*nn huge -> always within
        bne ?pushfar                ;   (sta leaves adc's Z alone -- no reload)
        stz coll_t                   ; r2nn = nn << 8 -> coll_t
        lda coll_dd
        sta coll_t+1
        lda coll_dd+1
        sta coll_t+2
        lda coll_dd+2
        sta coll_t+3
        jsr coll_shl2k               ; the DESCENT has to widen too, or the walk
        lda coll_cr                 ; csq = |cross|_lo16 ^2
        sta m_a
        sta m_b
        lda coll_cr+1
        sta m_a+1
        sta m_b+1
        jsr umul16
        lda coll_t                  ; within iff cross^2 <= r2*nn
        cmp m_prod
        lda coll_t+1
        sbc m_prod+1
        lda coll_t+2
        sbc m_prod+2
        lda coll_t+3
        sbc m_prod+3
        bcc ?descend                ; r2nn < cross^2 -> far cell out of range
?pushfar
        ldx bsp_sp
        lda zp_far
        sta bsp_stack,x
        lda zp_far+1
        sta bsp_stack+1,x
        inx
        inx
        stx bsp_sp
?descend
        lda zp_near
        sta zp_nid
        lda zp_near+1
        sta zp_nid+1
        jmp ?walk
?leaf   jsr collide_leaf
        bne ?yes
        ldx bsp_sp
        beq ?no
        dex
        dex
        stx bsp_sp
        lda bsp_stack,x
        sta zp_nid
        lda bsp_stack+1,x
        sta zp_nid+1
        jmp ?walk
?no     lda #0
        rts
?yes    lda #1
        rts
.endp
.proc coll_plr                       ; ...and the PLAYER's probe (and ball.asm's
        stz coll_k                   ;   -- MT_TROOPSHOT's radius is 6, so 16 is
        ldy #17                      ;   what it always meant). Naming the radius
        sty coll_rp1                 ;   at the call site beats trusting whoever
        jmp collide_blocked          ;   ran last to have put it back.
.endp

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
.proc coll_step_ok
        lda zp_px
        sta coll_svx
        lda zp_px+1
        sta coll_svx+1
        lda zp_py
        sta coll_svy
        lda zp_py+1
        sta coll_svy+1
        lda coll_cx                  ; pos := candidate
        sta zp_px
        lda coll_cx+1
        sta zp_px+1
        lda coll_cy
        sta zp_py
        lda coll_cy+1
        sta zp_py+1
        jsr locate_floor             ; loc_floor = destination sector floor
        lda coll_svx                 ; restore real player pos
        sta zp_px
        lda coll_svx+1
        sta zp_px+1
        lda coll_svy
        sta zp_py
        lda coll_svy+1
        sta zp_py+1
        sec                          ; step = dest - current
        lda loc_floor
        sbc cur_floor
        sta m_a
        lda loc_floor+1
        sbc cur_floor+1
        sta m_a+1                    ; step > MAXSTEP ?  (signed; sta leaves sbc's
        bmi ?ok                      ;   N/Z alone, so no reload) step < 0 -> ok
        bne ?block                   ; step >= 256 -> too high
        lda m_a
        cmp #MAXSTEP+1
        bcs ?block                   ; step >= 25 -> too high
?ok     lda #0
        rts
?block  lda #1
        rts
.endp

