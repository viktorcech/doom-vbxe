;--------------------------------------------------------------
; checkbbox.asm -- part of renderer.asm (icl in place): R_CheckBBox subtree culling.
;--------------------------------------------------------------
; check_bbox -- R_CheckBBox. IN: cb_off = byte offset of a child's bbox within
;   the node at (zp_nodeptr). OUT: A=1 if the subtree is WHOLLY invisible (skip),
;   A=0 if it must be walked. CONSERVATIVE: only culls provably-invisible boxes
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc check_bbox
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
        jsr cb_corners               ; -> cb_X/cb_Z for the four corners, and
                                     ;    cb_cnt = how many are behind the near ...
        .LONGA ON                    ; ---- 16-bit A: cb_corners returns that way
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
        bra ?cull16                  ; all four corners outside the left wall
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
?cull16 sep #$20                     ; all four outside the right wall
        .LONGA OFF
        lda #1
        rts
?count16 sep #$20
        .LONGA OFF
        lda cb_cnt                   ; 0 behind -> all in front: the screen span;
        beq ?allfront                ;   4 behind -> wholly behind the near
        cmp #4                       ;   plane -> cull; some -> straddles -> keep:
        lda #0                       ;   1..4 here, so C = (cnt == 4) IS the
        rol @                        ;   answer (A = 0/1, Z from it: what the
        rts                          ;   caller's bne reads)
?allfront
        ; --- all corners in front: screen-X span ---
        rep #$20                     ; ---- 16-bit A, in and out around each
        .LONGA ON                    ;   screenx_signed (8-bit code)
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
        sep #$20
        .LONGA OFF
        lda solid_arr,x
        beq ?keep
?sl16   rep #$20
        .LONGA ON
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
?sccl   sep #$20
        .LONGA OFF
        lda #1                       ; = ?cull
        rts
        .LONGA ON
?sc1    bit #$00FF
        beq ?sck                     ; x open -> keep, X = x
        cpx cb_xb                    ; x closed, x+1 open: inside only if x < xb
        inx
        bcs ?sccl                    ;   (x = xb: X = xb+1, cull)
?sck    sep #$20
        .LONGA OFF
        lda #0                       ; = ?keep
        rts
?cull   lda #1
        rts
?keep   lda #0
        rts
.endp
        .endseg

;--------------------------------------------------------------
; cb_corners -- the four bbox corners in view space: cb_X[i]/cb_Z[i], plus
;   cb_cnt = how many sit behind the near plane.
;--------------------------------------------------------------
        ; (was PINNED at CBCORN_BASE; since 2026-09-26 it rides the B1 segment
        ;  flow -- bank $01 is full speed everywhere, and the 8 FMULs inlined
        ;  below outgrew the 320-byte block: -12 cycles x 424 calls a frame)
; 16-BIT (2026-08-29): four (bbox edge - player) subtractions and four 16-bit
; results, all of them halves before. fmul_cos/fmul_sin are 8-bit code, so the
; mode goes back for each call and comes straight out again into the next
; argument. M only; X/Y stay 8-bit (sound.asm:316).
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cb_corners
        ; 2026-09-09 (drac030 style): the four coordinates arrive PLAYER- ...
                                      ; --- top: cos, then sin --- (2026-09-26: every
                                      ;   FMUL reads its cb_* word in place: no m_a copies)
        .local cbf5
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_top, fmn_cb5, fmp_cb5
        .endl
        .LONGA ON                    ; FMUL leaves the product IN A, 16-bit (math.asm)
        sta m_prod
        .LONGA OFF
        sep #$20
        .local cbf1
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_top, fmn_cb1, fmp_cb1
        .endl
        .LONGA ON
        sta m_prod+2
        .LONGA OFF                   ; --- bottom: cos, then sin ---
        sep #$20
        .local cbf6
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_bottom, fmn_cb6, fmp_cb6
        .endl
        .LONGA ON
        sta m_ma
        .LONGA OFF
        sep #$20
        .local cbf2
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_bottom, fmn_cb2, fmp_cb2
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
        .LONGA OFF
        sep #$20
        .local cbf7
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_left, fmn_cb7, fmp_cb7
        .endl
        .LONGA ON                    ; (?emitT16 skips its rep: 16-bit here)
        sta cb_hi
        ldx #0                       ; corner 0 = (left, top)
        jsr ?emitT16                 ; (the emits return 16-bit on both exits)
        ldx #4                       ; corner 2 = (left, bottom)
        jsr ?emitB
        .LONGA OFF                   ; --- right: sin, then cos -> corners 1, 3 ---
        sep #$20
        .local cbf4
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, cb_right, fmn_cb4, fmp_cb4
        .endl
        .LONGA ON
        sta cb_lo
        .LONGA OFF
        sep #$20
        .local cbf8
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, cb_right, fmn_cb8, fmp_cb8
        .endl
        .LONGA ON
        sta cb_hi
        ldx #2                       ; corner 1 = (right, top)
        jsr ?emitT16
        ldx #6                       ; corner 3 = (right, bottom)
        ; falls into ?emitB
?emitB                               ; ---- 16-bit A (every way in): X = sx - cos(y),
                                     ;   Z = cx + sin(y), y = bottom
        sec
        lda cb_lo
        sbc m_ma
        sta cb_X,x
        clc
        lda cb_hi
        adc m_ma+2
        sta cb_Z,x
        bra ?zt                      ; (a branch keeps the adc's N)
?emitT16                             ; ... same with the TOP row's pair (16-bit)
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
        rts                          ; 16-bit out: the next emit / check_bbox go on
?behind inc cb_cnt                   ;   16-bit. A word inc: cb_cnt <= 3 here, so
        rts                          ;   cb_cnt+1 (cb_xa) is written back unchanged
        .LONGA OFF
.endp
        .endseg
