;--------------------------------------------------------------
; checkbbox.asm -- R_CheckBBox subtree culling, the BODY: icl'd INSIDE
;   render_node (renderer.asm ?have) since 2026-10-05 -- 6502-cycles-layout
;   "inline what is smaller than its 12-cycle call": one caller, 43-53 calls
;   a frame, and the 0/1 answer + rep + bne it handed back are the exits'
;   own jumps now (-16 a call). Until then the proc check_bbox, parked at
;   CHECKBBOX_BASE.
;--------------------------------------------------------------
; IN: cb_off = byte offset of a child's bbox within the node at (zp_nodeptr),
;   8-bit M. OUT: ?push (16-bit: the far child is walked) or ?skipfar (16-bit:
;   the subtree is WHOLLY invisible). CONSERVATIVE: only culls provably-
;   invisible boxes. Every label here is render_node's.
;--------------------------------------------------------------
        ; NOTE the LONG indirect [zp_nodeptr],y: NODES live in the Rapidus EXT
        ; bank (bank $01), not in bank 0 (2026-07-29, rozblite.png: the plain
        ; form read garbage bboxes and culled whole visible subtrees).
        ldy cb_off
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        sec
        lda [zp_nodeptr],y           ; top
        sbc zp_py
        sta cb_top                   ; (cb_corners' FMULs read cb_* in place, 2026-09-26)
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
        ; ---- cb_corners, INLINE (2026-10-05): the four bbox corners in view
        ; space, cb_X[i]/cb_Z[i], and cb_cnt = how many sit behind the near
        ; plane. Skills applied: 6502-idioms "jsr X / rts" -> the one caller
        ; falls into the body (-12); 6502-cycles-layout "inline a routine
        ; smaller than its 12-cycle call" -- the two emit subroutines are
        ; written out per corner, the corner's offset in the operand (no ldx,
        ; abs for abs,x: 65816-style), and "rare case out of line" -- the
        ; behind-the-near count sits beside each pair with a not-taken branch
        ; on the common path. Same stores, same tests, same count: bit-identical.
        ; 2026-09-09 (drac030 style): the four coordinates arrive PLAYER-
        ; relative; every FMUL reads its cb_* word in place (2026-09-26).
        ; --- top: cos, then sin ---
        .local cbf5
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_top, fmn_cb5, fmp_cb5
        .endl
        .LONGA ON                    ; FMUL leaves the product IN A, 16-bit (math.asm)
        sta m_prod
 .ifndef ANTONIA2                    ; (2026-10-15: ANTONIA2's FMUL takes either
        .LONGA OFF                   ;   width -- no sep before it, 65816-windows)
        sep #$20
 .endif
        .local cbf1
        FMUL16 TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_top, fmn_cb1, fmp_cb1
        .endl
        .LONGA ON
        sta m_prod+2
 .ifndef ANTONIA2
        .LONGA OFF                   ; --- bottom: cos, then sin ---
        sep #$20
 .endif
        .local cbf6
        FMUL16 TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_bottom, fmn_cb6, fmp_cb6
        .endl
        .LONGA ON
        sta m_ma
 .ifndef ANTONIA2
        .LONGA OFF
        sep #$20
 .endif
        .local cbf2
        FMUL16 TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_bottom, fmn_cb2, fmp_cb2
        .endl
        .LONGA ON
        sta m_ma+2
        .LONGA OFF                   ; --- left: sin, then cos -> corners 0, 2 ---
        sep #$20
        stz cb_cnt
        .local cbf3
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_left, fmn_cb3, fmp_cb3
        .endl
        .LONGA ON
        sta cb_lo
 .ifndef ANTONIA2
        .LONGA OFF
        sep #$20
 .endif
        .local cbf7
        FMUL16 TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_left, fmn_cb7, fmp_cb7
        .endl
        .LONGA ON                    ; ---- 16-bit A from here to the sweeps
        sta cb_hi
        ; corner 0 = (left, top): X = sx - cos(y), Z = cx + sin(y)
        sec
        lda cb_lo
        sbc m_prod
        sta cb_X
        clc
        lda cb_hi
        adc m_prod+2
        sta cb_Z
        bmi ?bh0                     ; Z < 0, or 0 <= Z < ZNEAR (unsigned is
        cmp #ZNEAR                   ;   right here) -> behind the near plane
        bcc ?bh0
?ok0    ; corner 2 = (left, bottom)
        sec
        lda cb_lo
        sbc m_ma
        sta cb_X+4
        clc
        lda cb_hi
        adc m_ma+2
        sta cb_Z+4
        bmi ?bh2
        cmp #ZNEAR
        bcs ?ok2
?bh2    inc cb_cnt                   ; a word inc: cb_cnt <= 3 here, so cb_cnt+1
        bra ?ok2                     ;   (cb_xa) is written back unchanged
?bh0    inc cb_cnt
        bra ?ok0
 .ifdef ANTONIA2
?ok2                                 ; --- right: sin, then cos -> corners 1, 3 ---
 .else
?ok2    .LONGA OFF                   ; --- right: sin, then cos -> corners 1, 3 ---
        sep #$20
 .endif
        .local cbf4
        FMUL16 TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_right, fmn_cb4, fmp_cb4
        .endl
        .LONGA ON
        sta cb_lo
 .ifndef ANTONIA2
        .LONGA OFF
        sep #$20
 .endif
        .local cbf8
        FMUL16 TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_right, fmn_cb8, fmp_cb8
        .endl
        .LONGA ON
        sta cb_hi
        ; corner 1 = (right, top)
        sec
        lda cb_lo
        sbc m_prod
        sta cb_X+2
        clc
        lda cb_hi
        adc m_prod+2
        sta cb_Z+2
        bmi ?bh1
        cmp #ZNEAR
        bcc ?bh1
?ok1    ; corner 3 = (right, bottom)
        sec
        lda cb_lo
        sbc m_ma
        sta cb_X+6
        clc
        lda cb_hi
        adc m_ma+2
        sta cb_Z+6
        bmi ?bh3
        cmp #ZNEAR
        bcs ?sweep
?bh3    inc cb_cnt
        bra ?sweep
?bh1    inc cb_cnt
        bra ?ok1
?sweep                               ; ---- 16-bit A: the corners are in
        ; (2026-09-15: running these sweeps corner 3 -> 0 with dex/dex/bpl was
        ;  MEASURED +7.8k cyc/frame -- same verdicts, but the order decides how
        ;  soon the early exits fire.
                                      ; 2026-09-22 (6502-idioms: the index counts UP to
        ldx #$F8                     ;   zero, corner 0 -> 3 as before): cb_X/cb_Z end
?sdl    clc                          ;   their pages, so base+X never crosses one and
        lda cb_X+8-256,x             ;   the wrap to 0 is the exit (memory_map.inc)
        adc cb_Z+8-256,x             ; X + Z, signed (V fixes the sign)
        bvc ?sdl1
        eor #$8000
?sdl1   bpl ?sdr                     ; >= 0: this corner is not outside left,
        inx                          ;   so the left plane cannot cull
        inx
        bne ?sdl
        jmp ?skipfar                 ; all four corners outside the left wall: cull
?sdr    ldx #$F8
?sdr1   sec                          ; X - Z
        lda cb_X+8-256,x
        sbc cb_Z+8-256,x
        beq ?count16                 ; == 0 is the edge: not outside. (Tested on
                                     ;   the RAW result, before the sign fix: a ...
        bvc ?sdr2
        eor #$8000
?sdr2   bmi ?count16                 ; < 0: not outside right
        inx
        inx
        bne ?sdr1                    ; (X wraps to 0 after corner 3)
        jmp ?skipfar                 ; all four outside the right wall: cull
?count16 lda cb_cnt                  ; 0 behind -> all in front: the screen span;
        and #$00FF                   ;   (a byte: cb_xa behind it) 2026-10-16,
        beq ?allfront                ;   drac030 -- no sep/rep round the byte
        cmp #4                       ;   4 behind -> wholly behind the near
        bcc ?cnt_k                   ;   plane -> cull; 1..3 -> straddles -> keep
        jmp ?skipfar
?cnt_k  jmp ?push
?allfront
        ; --- all corners in front: screen-X span ---
                                     ; ---- 16-bit A, in and out around each
                                     ;   screenx_signed (8-bit code)
        lda #$7FFF                   ; cb_lo = +32767, cb_hi = -32768
        sta cb_lo
        lda #$8000
        sta cb_hi
                                      ; 2026-09-22: Y = corner*2 - 8 ($F8..$FE), counting
        ldy #$F8                     ;   up to zero as the two sweeps above
?sl     lda cb_X+8-256,y
        sta zp_X
        lda cb_Z+8-256,y
        sta zp_Z
                                      ; 2026-09-23: screenx_signed in and out 16-bit, A = m_xs;
        phy                          ;   one unsigned compare is "hi != 0 or lo >= 160"
        jsr screenx_signed.sx_w16    ; m_xs = unclamped signed column (clobbers X)
        ply
        cmp #SCREEN_WIDTH            ; EARLY KEEP: an ON-screen corner column that is
        bcs ?slm                     ;   still open means KEEP (see below); off-screen:
        tax                          ;   A = m_xs, 16-bit and C = 1 already -> ?slm
        lda solid_arr,x
        and #$00FF                   ; (a byte array; 2026-10-16: no sep/rep)
        beq ?keep
        lda m_xs                     ; cb_lo = min(cb_lo, m_xs)  (signed16)
        sec
?slm    sbc cb_lo
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
        bne ?sl                      ; (Y wraps to 0 after corner 3)
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
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
        rep #$20                     ;   TWO columns a read. In [0,159] solid_arr holds
        .LONGA ON                    ;   only 0/1 (stz, #1, cm_solid = a copy of it;
?sc     lda solid_arr,x              ;   vw_apply re-marks it after every overlay), so
        cmp #$0101                   ;   $0101 = both closed. X leaves exactly as the
        bne ?sc1                     ;   byte loop's did: the open column, or xb+1
        inx
        cpx cb_xb                    ; C = (x+1 >= xb)
        inx
        bcc ?sc
        ldx cb_xb                    ; all solid (x may have been xb): X = xb+1
        inx
?sccl   bra ?skipfar                 ; = cull (16-bit)
?sc1    bit #$00FF
        beq ?push                    ; x open -> keep, X = x (16-bit)
        cpx cb_xb                    ; x closed, x+1 open: inside only if x < xb
        inx
        bcs ?sccl                    ;   (x = xb: X = xb+1, cull)
        bra ?push                    ; = keep
        .LONGA OFF
?cull   rep #$20                     ; (8-bit exits -> the 16-bit walk)
        .LONGA ON
        bra ?skipfar
        .LONGA OFF
        .LONGA ON
?keep                                ; (16-bit A) ... and falls into ?push
