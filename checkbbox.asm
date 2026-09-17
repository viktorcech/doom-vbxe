;--------------------------------------------------------------
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

;--------------------------------------------------------------
; check_bbox -- R_CheckBBox. IN: cb_off = byte offset of a child's bbox within
;   the node at (zp_nodeptr). OUT: A=1 if the subtree is WHOLLY invisible (skip),
;   A=0 if it must be walked. CONSERVATIVE: only culls provably-invisible boxes
;   (image stays pixel-identical -- no wall drop). Mirrors gui.py cull():
;   transform the 4 bbox corners -> view (X,Z); all behind near plane -> cull;
;   any behind (straddles) -> keep; all in front -> screen-X of the corners,
;   wholly left/right of screen -> cull, else span already all-solid -> cull.
;   bbox layout: top@+0 bottom@+2 left@+4 right@+6 (world i16). Corners:
;   (left,top)(right,top)(left,bottom)(right,bottom). Uses transform/screenx_signed
;   (the SAME projection the renderer uses -> bit-exact -> safe). Clobbers A/X/Y,
;   m_*, rc_*, zp_rx/ry/X/Z, cb_*. Preserves zp_nid/zp_nodeptr/zp_near/zp_far.
;--------------------------------------------------------------


        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc check_bbox
 .if 1
        ; NOTE the LONG indirect [zp_nodeptr],y: NODES live in the Rapidus EXT
        ; bank (bank $01), not in bank 0 (2026-07-29, rozblite.png: the plain
        ; form read garbage bboxes and culled whole visible subtrees).
        ; 2026-09-09 (drac030 style): the four bbox words are read WHOLE and
        ; made player-relative right here -- cb_corners used to redo the same
        ; sec/sbc twice per coordinate because FMUL eats m_a. Same subtraction,
        ; same bits; cb_top..cb_right now hold (edge - player).
        ldy cb_off
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        sec
        lda [zp_nodeptr],y           ; top
        sbc zp_py
        sta cb_top
 .if 1
        sta m_a                      ; ... and cb_corners' first FMUL argument while
 .endif                               ;   A is 16-bit anyway (2026-09-15, -10/call)
        iny
        iny
        sec
        lda [zp_nodeptr],y           ; bottom
        sbc zp_py
        sta cb_bottom
        iny
        iny
        sec
        lda [zp_nodeptr],y           ; left
        sbc zp_px
        sta cb_left
        iny
        iny
        sec
        lda [zp_nodeptr],y           ; right
        sbc zp_px
        sta cb_right
        sep #$20
        .LONGA OFF
        jsr cb_corners               ; -> cb_X/cb_Z for the four corners, and
                                     ;    cb_cnt = how many are behind the near
                                     ;    plane (eight frac-table multiplies for
                                     ;    the four corners: see cb_corners)
        ; --- THE TWO SIDE PLANES, before anything else. FOCAL = SCREEN_HALF, so
        ;     the view volume is exactly { Z >= ZNEAR, -Z <= X <= Z } and its
        ;     left/right walls are planes THROUGH THE EYE. X+Z and X-Z are
        ;     linear, and a linear function over a convex hull peaks at a
        ;     corner -- so if all four corners have X+Z < 0 the whole box is
        ;     outside the left wall, and nothing in that subtree can be seen.
        ;     Provably conservative, hence pixel-identical.
        ;     WHY IT IS WORTH ITS BYTES: the near-plane branch below gives up
        ;     ("some corners behind -> keep") without ever asking WHERE the box
        ;     is, so a subtree straight out to the side survived just because it
        ;     reached past the eye. And when the box IS wholly in front, this
        ;     culls before the four screenx_signed (~2200 cycles) rather than
        ;     after them.
        ;     TWO PASSES, no flags: "all four X+Z < 0" is one loop that quits on
        ;     the first corner that is not, then "all four X-Z > 0" likewise.
        ;     The old single loop carried cb_xa/cb_xb as flags and quit when
        ;     both died -- the same verdict, and the same number of corner
        ;     tests in the worst case, but every test is now one 16-bit add.
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        ; (2026-09-15: running these sweeps corner 3 -> 0 with dex/dex/bpl was
        ;  MEASURED +7.8k cyc/frame -- same verdicts, but the order decides how
        ;  soon the early exits fire. Keep 0 -> 3.)
        ldx #0
?sdl    clc                          ; X + Z, signed (V fixes the sign)
        lda cb_X,x
        adc cb_Z,x
        bvc ?sdl1
        eor #$8000
?sdl1   bpl ?sdr                     ; >= 0: this corner is not outside left,
        inx                          ;   so the left plane cannot cull
        inx
        cpx #8
        bne ?sdl
        bra ?cull16                  ; all four corners outside the left wall
?sdr    ldx #0
?sdr1   sec                          ; X - Z
        lda cb_X,x
        sbc cb_Z,x
        beq ?count16                 ; == 0 is the edge: not outside. (Tested on
                                     ;   the RAW result, before the sign fix: a
                                     ;   zero difference cannot have overflowed,
                                     ;   and the fixed-up value of a $8000
                                     ;   overflow WOULD read as zero.)
        bvc ?sdr2
        eor #$8000
?sdr2   bmi ?count16                 ; < 0: not outside right
        inx
        inx
        cpx #8
        bne ?sdr1
?cull16 sep #$20                     ; all four outside the right wall
        .LONGA OFF
        lda #1
        rts
?count16 sep #$20
        .LONGA OFF
        lda cb_cnt                   ; 0 behind -> all in front: the screen span;
        beq ?allfront                ;   4 behind -> wholly behind the near
        cmp #4                       ;   plane -> cull; some -> straddles -> keep
        jeq ?cull                    ; (MADS Jcc: a branch when in range)
        jmp ?keep
?allfront
        ; --- all corners in front: screen-X span ---
        rep #$20                     ; ---- 16-bit A, in and out around each
        .LONGA ON                    ;   screenx_signed (8-bit code)
        lda #$7FFF                   ; cb_lo = +32767, cb_hi = -32768
        sta cb_lo
        lda #$8000
        sta cb_hi
        ldy #0                       ; Y = corner*2, the index into cb_X/cb_Z
?sl     lda cb_X,y
        sta zp_X
        lda cb_Z,y
        sta zp_Z
        sep #$20
        .LONGA OFF
        phy
        jsr screenx_signed           ; m_xs = unclamped signed column (clobbers X)
        ply
        lda m_xs+1                   ; EARLY KEEP (2026-09-14): this corner's column
        bne ?sl16                    ;   lies inside [lo,hi], so if it is ON screen
        ldx m_xs                     ;   and still open, the all-solid test below
        cpx #SCREEN_WIDTH            ;   cannot pass -- the answer is KEEP without
        bcs ?sl16                    ;   projecting the remaining corners (each
        lda solid_arr,x              ;   ~600 cycles). Off-screen corners say
        beq ?keep                    ;   nothing, so they fall through as before.
?sl16   rep #$20
        .LONGA ON
        sec                          ; cb_lo = min(cb_lo, m_xs)  (signed16)
        lda m_xs
        sbc cb_lo
        bvc ?mn
        eor #$8000
?mn     bpl ?nomin
        lda m_xs
        sta cb_lo
?nomin  sec                          ; cb_hi = max(cb_hi, m_xs)
        lda m_xs
        sbc cb_hi
        bvc ?mx
        eor #$8000
?mx     bmi ?nomax
        lda m_xs
        sta cb_hi
?nomax  iny
        iny
        cpy #8
        bne ?sl
        sep #$20
        .LONGA OFF
        lda cb_hi+1                  ; hi < 0 -> wholly left of screen -> cull
        bmi ?cull
        ldx #0                       ; xa = max(0, lo), kept in X: nothing but
        lda cb_lo+1                  ;   the occlusion walk below reads it
        bmi ?xbset                   ; lo negative -> not off-right, xa = 0
        bne ?cull                    ; lo >= 256 -> off-right
        ldx cb_lo
        cpx #SCREEN_WIDTH            ; lo >= 160 (> 159) -> off-right
        bcs ?cull
?xbset  lda cb_hi+1                  ; xb = min(W-1, hi)   (hi >= 0 here)
        bne ?xbmax
        lda cb_hi
        cmp #SCREEN_WIDTH
        bcc ?xbok
?xbmax  lda #SCREEN_WIDTH-1
?xbok   sta cb_xb
 .if 1
?sc     lda solid_arr,x              ; occlusion: every column in [xa,xb] already solid?
        beq ?keep                    ; an open column -> visible -> keep
        cpx cb_xb                    ; C = (x >= xb), and inx leaves C alone. xa <= xb
        inx                          ;   (lo <= hi, both clamped into the screen), so
        bcc ?sc                      ;   the first x with C=1 IS xb: same exit, -2/col
 .else
?sc     lda solid_arr,x              ; occlusion: every column in [xa,xb] already solid?
        beq ?keep                    ; an open column -> visible -> keep
        cpx cb_xb
        beq ?cull                    ; spanned [xa,xb] all solid -> occluded -> cull
        inx
        bra ?sc
 .endif
?cull   lda #1
        rts
?keep   lda #0
        rts
 .else
        ; NOTE the LONG indirect [zp_nodeptr],y: NODES live in the Rapidus EXT
        ; bank (bank $01), not in bank 0. This routine was written before that
        ; move and still used plain (zp_nodeptr),y, so when the cull was
        ; re-enabled on 2026-07-29 it read whatever sat at the same offset in
        ; bank 0 -- garbage bboxes, and whole visible subtrees culled away
        ; (pink gaps + stray texture, rozblite.png). Every other node reader in
        ; renderer.asm already uses the long form.
        ldy cb_off                   ; read the 4 bbox words into cb_top..cb_right
        lda [zp_nodeptr],y
        sta cb_top
        iny
        lda [zp_nodeptr],y
        sta cb_top+1
        iny
        lda [zp_nodeptr],y
        sta cb_bottom
        iny
        lda [zp_nodeptr],y
        sta cb_bottom+1
        iny
        lda [zp_nodeptr],y
        sta cb_left
        iny
        lda [zp_nodeptr],y
        sta cb_left+1
        iny
        lda [zp_nodeptr],y
        sta cb_right
        iny
        lda [zp_nodeptr],y
        sta cb_right+1
        jsr cb_corners               ; -> cb_X/cb_Z for the four corners, and
                                     ;    cb_cnt = how many are behind the near
                                     ;    plane. Four `jsr transform` used to
                                     ;    live here; see cb_corners for why the
                                     ;    sixteen frac-table multiplies they did
                                     ;    are eight.
        ; --- THE TWO SIDE PLANES, before anything else. FOCAL = SCREEN_HALF, so
        ;     the view volume is exactly { Z >= ZNEAR, -Z <= X <= Z } and its
        ;     left/right walls are planes THROUGH THE EYE. X+Z and X-Z are
        ;     linear, and a linear function over a convex hull peaks at a
        ;     corner -- so if all four corners have X+Z < 0 the whole box is
        ;     outside the left wall, and nothing in that subtree can be seen.
        ;     Provably conservative, hence pixel-identical.
        ;     WHY IT IS WORTH ITS BYTES: the near-plane branch below gives up
        ;     ("some corners behind -> keep") without ever asking WHERE the box
        ;     is, so a subtree straight out to the side survived just because it
        ;     reached past the eye. And when the box IS wholly in front, this
        ;     culls before the four screenx_signed (~2200 cycles) rather than
        ;     after them. Costs ~30 cycles a corner, and quits as soon as both
        ;     candidates are dead.
        ;     cb_xa/cb_xb are the flags and cb_lo the scratch: none of the three
        ;     is live until ?allfront/?occl further down.
        ldx #0
        lda #1
        sta cb_xa                    ; still "wholly left of the view"?
        sta cb_xb                    ; still "wholly right of it"?
?sd     clc                          ; X + Z, signed 17-bit (V fixes the sign)
        lda cb_X,x
        adc cb_Z,x
        lda cb_X+1,x
        adc cb_Z+1,x
        bvc ?sd1
        eor #$80
?sd1    bmi ?sd2                     ; X+Z < 0 -> this corner IS outside left
        lda #0
        sta cb_xa
?sd2    sec                          ; X - Z
        lda cb_X,x
        sbc cb_Z,x
        sta cb_lo
        lda cb_X+1,x
        sbc cb_Z+1,x
        sta cb_lo+1
        bvc ?sd3
        eor #$80
?sd3    bmi ?sdno                    ; X-Z < 0 -> not outside right
        lda cb_lo
        ora cb_lo+1
        bne ?sd4                     ; X-Z > 0 -> outside right (== is the edge)
?sdno   lda #0
        sta cb_xb
?sd4    lda cb_xa
        ora cb_xb
        beq ?counted                 ; neither plane can cull -- stop testing
        inx
        inx
        cpx #8
        bne ?sd
        jmp ?cull                    ; all four corners outside the SAME plane
?counted lda cb_cnt                  ; all 4 behind -> wholly behind near plane -> cull
        cmp #4
        bne ?notall4
        jmp ?cull
?notall4 lda cb_cnt                  ; some (not all) behind -> straddles near -> keep
        beq ?allfront
        jmp ?keep
?allfront
        ; --- all corners in front: screen-X span ---
        lda #$FF                     ; cb_lo = +32767, cb_hi = -32768
        sta cb_lo
        lda #$7F
        sta cb_lo+1
        lda #$00
        sta cb_hi
        lda #$80
        sta cb_hi+1
        ldx #0
?sl     txa
        asl
        tay
        lda cb_X,y
        sta zp_X
        lda cb_X+1,y
        sta zp_X+1
        lda cb_Z,y
        sta zp_Z
        lda cb_Z+1,y
        sta zp_Z+1
        txa
        pha
        jsr screenx_signed           ; m_xs = unclamped signed column (clobbers X)
        pla
        tax
        lda m_xs                     ; cb_lo = min(cb_lo, m_xs)  (signed16)
        cmp cb_lo
        lda m_xs+1
        sbc cb_lo+1
        bvc ?mn
        eor #$80
?mn     bpl ?nomin
        lda m_xs
        sta cb_lo
        lda m_xs+1
        sta cb_lo+1
?nomin  lda m_xs                     ; cb_hi = max(cb_hi, m_xs)
        cmp cb_hi
        lda m_xs+1
        sbc cb_hi+1
        bvc ?mx
        eor #$80
?mx     bmi ?nomax
        lda m_xs
        sta cb_hi
        lda m_xs+1
        sta cb_hi+1
?nomax  inx
        cpx #4
        bne ?sl
        lda cb_hi+1                  ; hi < 0 -> wholly left of screen -> cull
        bmi ?cull
        lda cb_lo+1                  ; lo > W-1 -> wholly right of screen -> cull
        bmi ?occl                    ; lo negative -> not off-right
        bne ?cull                    ; lo >= 256 -> off-right
        lda cb_lo
        cmp #SCREEN_WIDTH            ; lo >= 160 (> 159) -> off-right
        bcs ?cull
?occl   lda cb_lo+1                  ; xa = max(0, lo)
        bmi ?xa0
        lda cb_lo
        sta cb_xa
        jmp ?xbset
?xa0    lda #0
        sta cb_xa
?xbset  lda cb_hi+1                  ; xb = min(W-1, hi)   (hi >= 0 here)
        bne ?xbmax
        lda cb_hi
        cmp #SCREEN_WIDTH
        bcc ?xbok
?xbmax  lda #SCREEN_WIDTH-1
?xbok   sta cb_xb
        ldx cb_xa                    ; occlusion: every column in [xa,xb] already solid?
?sc     lda solid_arr,x
        beq ?keep                    ; an open column -> visible -> keep
        cpx cb_xb
        beq ?cull                    ; spanned [xa,xb] all solid -> occluded -> cull
        inx
        jmp ?sc
?cull   lda #1
        rts
?keep   lda #0
        rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; cb_corners -- the four bbox corners in view space: cb_X[i]/cb_Z[i], plus
;   cb_cnt = how many sit behind the near plane.
;
;   THE CORNERS SHARE THEIR COORDINATES. There are four of them but only two x
;   values (left, right) and two y values (top, bottom), and the transform is
;   separable -- transform() is
;       X = (rx*sin)>>14 - (ry*cos)>>14 ;  Z = (rx*cos)>>14 + (ry*sin)>>14
;   with each term rounded on its own. So sin/cos of each of the four distinct
;   coordinates is EIGHT frac-table multiplies, and every corner is then two
;   adds. Four `jsr transform` did sixteen. Same terms, same order, same
;   truncation -> the same cb_X/cb_Z to the bit, which matters: this routine
;   decides whether a whole BSP subtree gets drawn.
;
;   Scratch, without asking the full $13xx render block for twelve more bytes:
;   m_prod and m_ma hold the y half (FMUL stopped writing m_prod when the >>14
;   moved into the table, and m_ma belongs to calc_nodeptr, which has long
;   returned), cb_lo/cb_hi the x half -- check_bbox only initialises those at
;   ?allfront, which is after this returns. The four relative coordinates are
;   NOT stored: FMUL takes |m_a| in place, so m_a has to be rebuilt between the
;   sin and the cos anyway, and rebuilding is 8 cycles cheaper than a slot.
;   Parked in the tail collide_blocked vacated (it wants ~330 B and check_bbox's
;   own block had three spare).
;--------------------------------------------------------------
cbc_resume = *
        ; PINNED FAST (2026-08-11): ~50 runs a frame; win2 cost it 6.1% of the
        ; frame -- never move it back to $8000-$BFFF.
        org CBCORN_BASE
; 16-BIT (2026-08-29): four (bbox edge - player) subtractions and four 16-bit
; results, all of them halves before. fmul_cos/fmul_sin are 8-bit code, so the
; mode goes back for each call and comes straight out again into the next
; argument. M only; X/Y stay 8-bit (sound.asm:316).
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cb_corners
 .if 1
        ; 2026-09-09 (drac030 style): the four coordinates arrive PLAYER-
        ; RELATIVE from check_bbox, so every "rebuild m_a" is a plain 16-bit
        ; copy -- done as two bytes, because a copy wrapped in its own rep/sep
        ; costs more than the two 8-bit moves (12 vs 14 cycles). The 16-bit
        ; work is the corner emit: two adds and the near test on the adc's own
        ; flags.
  .if 1                               ; --- top: cos, then sin --- (m_a = cb_top was
  .else                               ;   stored by check_bbox in its 16-bit window)
        lda cb_top                   ; --- top: cos, then sin ---
        sta m_a
        lda cb_top+1
        sta m_a+1
  .endif
        jsr fmul_cos
        ; (2026-09-15: where a result copy and the next "rebuild m_a" copy sit
        ;  side by side they share ONE 16-bit window -- 23 cycles for the pair,
        ;  the lone copies stay 8-bit at their 14)
        rep #$20
        .LONGA ON
        lda m_res
        sta m_prod
        lda cb_top
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_sin
        rep #$20
        .LONGA ON
        lda m_res
        sta m_prod+2
        lda cb_bottom                ; --- bottom: cos, then sin ---
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_cos
        rep #$20
        .LONGA ON
        lda m_res
        sta m_ma
        lda cb_bottom
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_sin
        rep #$20
        .LONGA ON
        lda m_res
        sta m_ma+2
        lda cb_left                  ; --- left: sin, then cos -> corners 0, 2 ---
        sta m_a
        .LONGA OFF
        sep #$20
        stz cb_cnt
        jsr fmul_sin
        rep #$20
        .LONGA ON
        lda m_res
        sta cb_lo
        lda cb_left
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_cos
  .if 1
        rep #$20                     ; the copy goes 16-bit straight INTO ?emitT's
        .LONGA ON                    ;   window (?emitT16 skips its rep): -5/call
        lda m_res
        sta cb_hi
        ldx #0                       ; corner 0 = (left, top)
        jsr ?emitT16
        .LONGA OFF                   ; (?emitT returns 8-bit on both exits)
  .else
        lda m_res
        sta cb_hi
        lda m_res+1
        sta cb_hi+1
        ldx #0                       ; corner 0 = (left, top)
        jsr ?emitT
  .endif
        ldx #4                       ; corner 2 = (left, bottom)
        jsr ?emitB
        lda cb_right                 ; --- right: sin, then cos -> corners 1, 3 ---
        sta m_a
        lda cb_right+1
        sta m_a+1
        jsr fmul_sin
        rep #$20
        .LONGA ON
        lda m_res
        sta cb_lo
        lda cb_right
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_cos
  .if 1
        rep #$20                     ; (as corner 0 above)
        .LONGA ON
        lda m_res
        sta cb_hi
        ldx #2                       ; corner 1 = (right, top)
        jsr ?emitT16
        .LONGA OFF
  .else
        lda m_res
        sta cb_hi
        lda m_res+1
        sta cb_hi+1
        ldx #2                       ; corner 1 = (right, top)
        jsr ?emitT
  .endif
        ldx #6                       ; corner 3 = (right, bottom)
        ; falls into ?emitB
?emitB  rep #$20                     ; ---- 16-bit A: X = sx - cos(y), Z = cx + sin(y),
        .LONGA ON                    ;   y = bottom
        sec
        lda cb_lo
        sbc m_ma
        sta cb_X,x
        clc
        lda cb_hi
        adc m_ma+2
        sta cb_Z,x
        bra ?zt                      ; (a branch keeps the adc's N)
?emitT  rep #$20                     ; ... same with the TOP row's pair
?emitT16                             ; (entered here already 16-bit)
        sec
        lda cb_lo
        sbc m_prod
        sta cb_X,x
        clc
        lda cb_hi
        adc m_prod+2
        sta cb_Z,x
?zt     bmi ?behind                  ; Z < 0, or
        cmp #ZNEAR                   ;   0 <= Z < ZNEAR (unsigned is right here)
        bcc ?behind                  ;   -> behind the near plane
        sep #$20
        .LONGA OFF
        rts
?behind sep #$20
        inc cb_cnt
        rts
 .else
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        sec                          ; --- top: cos, then sin ---
        lda cb_top
        sbc zp_py
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_cos
        rep #$20
        .LONGA ON
        lda m_res
        sta m_prod
        sec
        lda cb_top
        sbc zp_py
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_sin
        rep #$20
        .LONGA ON
        lda m_res
        sta m_prod+2
        sec                          ; --- bottom: cos, then sin ---
        lda cb_bottom
        sbc zp_py
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_cos
        rep #$20
        .LONGA ON
        lda m_res
        sta m_ma
        sec
        lda cb_bottom
        sbc zp_py
        sta m_a
        .LONGA OFF
        sep #$20
        jsr fmul_sin
        rep #$20
        .LONGA ON
        lda m_res
        sta m_ma+2
        .LONGA OFF
        sep #$20
        lda #0
        sta cb_cnt
        sec                          ; --- left: sin, then cos -> corners 0, 2 ---
        lda cb_left
        sbc zp_px
        sta m_a
        lda cb_left+1
        sbc zp_px+1
        sta m_a+1
        jsr fmul_sin
        lda m_res
        sta cb_lo
        lda m_res+1
        sta cb_lo+1
        sec
        lda cb_left
        sbc zp_px
        sta m_a
        lda cb_left+1
        sbc zp_px+1
        sta m_a+1
        jsr fmul_cos
        lda m_res
        sta cb_hi
        lda m_res+1
        sta cb_hi+1
        ldx #0                       ; corner 0 = (left, top)
        jsr ?emitT
        ldx #4                       ; corner 2 = (left, bottom)
        jsr ?emitB
        sec                          ; --- right: sin, then cos -> corners 1, 3 ---
        lda cb_right
        sbc zp_px
        sta m_a
        lda cb_right+1
        sbc zp_px+1
        sta m_a+1
        jsr fmul_sin
        lda m_res
        sta cb_lo
        lda m_res+1
        sta cb_lo+1
        sec
        lda cb_right
        sbc zp_px
        sta m_a
        lda cb_right+1
        sbc zp_px+1
        sta m_a+1
        jsr fmul_cos
        lda m_res
        sta cb_hi
        lda m_res+1
        sta cb_hi+1
        ldx #2                       ; corner 1 = (right, top)
        jsr ?emitT
        ldx #6                       ; corner 3 = (right, bottom)
        ; falls into ?emitB
?emitB  sec                          ; X = sx - cos(y) ; Z = cx + sin(y), y = bottom
        lda cb_lo
        sbc m_ma
        sta cb_X,x
        lda cb_lo+1
        sbc m_ma+1
        sta cb_X+1,x
        clc
        lda cb_hi
        adc m_ma+2
        sta cb_Z,x
        lda cb_hi+1
        adc m_ma+3
        jmp ?zt
?emitT  sec                          ; ... same with the TOP row's pair
        lda cb_lo
        sbc m_prod
        sta cb_X,x
        lda cb_lo+1
        sbc m_prod+1
        sta cb_X+1,x
        clc
        lda cb_hi
        adc m_prod+2
        sta cb_Z,x
        lda cb_hi+1
        adc m_prod+3
?zt     sta cb_Z+1,x                 ; A = Z high byte; Z < ZNEAR -> behind
        bmi ?behind
        bne ?done
        lda cb_Z,x
        cmp #ZNEAR
        bcs ?done
?behind inc cb_cnt
?done   rts
 .endif
.endp
        .endseg
    .if * > CBCORN_END+1
        ert 'cb_corners outgrew CBCORN_BASE..END (memory_map.inc)'
    .endif
        org cbc_resume
