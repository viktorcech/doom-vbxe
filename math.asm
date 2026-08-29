;--------------------------------------------------------------
; RAM BUDGET: 0 B free, biggest contiguous block 0 B.
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
;==============================================================
; math.asm -- fixed-point helpers for the BSP renderer.
;   Correctness-first: plain shift/add multiply + shift/sub divide
;   (easy to verify by reading). The fast wolf3d quarter-square mul
;   replaces these once the geometry is proven correct.
;
; All signed 16-bit unless noted. ZP scratch defined in bsp_main.asm.
;==============================================================

;--------------------------------------------------------------
; qsmul -- INLINED 8x8 -> 16 quarter-square.  qs_p(2) = (:1) * (:2)
;   a*b = QSqr[a+b] - QSqr[|a-b|], QSqr[x]=floor(x^2/4) (qs_tables.inc).
;   tips2 #3: a macro inlined 4x into umul16 -> no jsr/rts, reads the
;   operand bytes directly (no qs_x/qs_y staging). Clobbers A,Y.
;--------------------------------------------------------------


.macro qsmul
        clc
        lda :1
        adc :2                     ; x+y (9-bit: Y=low8, carry=bit8)
        tay
        bcs ?ext
        lda QSqrLoBase,y
        sta qs_p
        lda QSqrHiBase,y
        sta qs_p+1
        jmp ?diff
?ext    lda QSqrLoExt,y
        sta qs_p
        lda QSqrHiExt,y
        sta qs_p+1
?diff   sec                        ; |x-y| (0..255 -> Base table)
        lda :1
        sbc :2
        bcs ?dok
        eor #$FF
        clc
        adc #1
?dok    tay
        sec                        ; qs_p -= QSqr[|x-y|]
        lda qs_p
        sbc QSqrLoBase,y
        sta qs_p
        lda qs_p+1
        sbc QSqrHiBase,y
        sta qs_p+1
.endm

;--------------------------------------------------------------
; umul16 -- UNSIGNED 16x16 -> 32.  m_a(2) * m_b(2) -> m_prod(4)
;   tips #2/#3: four 8x8 quarter-square products (inlined qsmul) instead
;   of the 16-iteration shift/add loop.  Bit-identical, much faster.
;     P = p00 + (p01+p10)<<8 + p11<<16
;     p00=aL*bL  p01=aL*bH  p10=aH*bL  p11=aH*bH   (aL=m_a, aH=m_a+1, ...)
;--------------------------------------------------------------
.proc umul16
        ; --- THE OPERANDS ARE SMALL. Measured on a real frame
        ;     (tools/_dbg_mathargs.py, 1307 calls): m_a < 256 in 76 % of them and
        ;     BOTH < 256 in 44 %. A zero high byte makes p10 and p11 zero and
        ;     p01 zero as well, i.e. three of the four quarter-squares are
        ;     multiplying by nothing. Testing for it costs 5 cycles and skips up
        ;     to 260 -- and it is not an approximation: the products it drops
        ;     ARE zero, so the 32-bit result is the same.
        qsmul m_a, m_b             ; p00 = aL*bL -> bytes 0,1. Every path needs it,
        lda qs_p                   ;   so it stays inline exactly once -- the
        sta m_prod                 ;   skipping below is about the OTHER three.
        lda qs_p+1
        sta m_prod+1
        lda #0                     ; bytes 2,3 start at zero and the products that
        sta m_prod+2               ;   would land there are now ADDED, not stored,
        sta m_prod+3               ;   which is what lets any of them be skipped
        lda m_a+1
        ora m_b+1
        bne ?more
        rts                        ; both high bytes 0 -> p00 IS the product (44 %)
?more   lda m_b+1
        bne ?p01
        jmp ?p10                   ; bH = 0, aH != 0 -> only p10 is left (1 %)
?p01    qsmul m_a, m_b+1           ; p01 = aL*bH -> add at byte 1
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
        bcc ?p11
        inc m_prod+3
?p11    lda m_a+1
        bne ?p11go
        rts                        ; aH = 0 -> p10 = p11 = 0 (another 32 %)
?p11go  qsmul m_a+1, m_b+1         ; p11 = aH*bH -> add at byte 2
        clc
        lda m_prod+2
        adc qs_p
        sta m_prod+2
        lda m_prod+3
        adc qs_p+1
        sta m_prod+3
?p10    qsmul m_a+1, m_b           ; p10 = aH*bL -> add at byte 1
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
        bcc ?done
        inc m_prod+3
?done   rts
.endp

;--------------------------------------------------------------
; smul_14 -- SIGNED 16x16, result >> 14, -> m_res(2, signed)
;   inputs m_a, m_b (signed 16). Used by the view transform.
;   sign tracked separately; magnitudes via umul16; then >>14.
;   PARKED in win2 (SMUL14_BASE): see memory_map.inc -- it is the coldest .proc
;   in the $2000 engine segment, and step_recip below needed the bytes.
;--------------------------------------------------------------
sm14_resume = *
        org SMUL14_BASE
.proc smul_14
        lda #0
        sta m_sign
        ; abs(m_a)
        lda m_a+1
        bpl ?a_pos
        inc m_sign
        jsr m_neg
?a_pos
        ; abs(m_b)
        lda m_b+1
        bpl ?b_pos
        lda m_sign
        eor #1
        sta m_sign
        jsr m_negb
?b_pos
        jsr umul16
        ; m_prod >>= 14 via (m_prod << 2) >> 16: shift the 32-bit product LEFT
        ; twice, then the result is bytes [2],[3]. 8 shifts instead of the
        ; 14-iteration (56-shift) loop. Bit-identical (Gemini tip, tips #4b).
        asl m_prod
        rol m_prod+1
        rol m_prod+2
        rol m_prod+3
        asl m_prod
        rol m_prod+1
        rol m_prod+2
        rol m_prod+3
        asl m_prod+1                 ; C = the dropped fraction's MSB: ROUND the
        lda m_prod+2                 ;   >>14 instead of truncating. Truncation
        adc #0                       ;   lost up to a whole unit per frame per
        sta m_res                    ;   axis in move_player, bending the walk
        lda m_prod+3                 ;   heading up to 2 deg toward the nearest
        adc #0                       ;   axis ("pulls sideways", 2026-07-28 --
        sta m_res+1                  ;   DOOM's fixed_t positions lose nothing)
        ; apply sign
        lda m_sign
        beq ?done
        sec
        lda #0
        sbc m_res
        sta m_res
        lda #0
        sbc m_res+1
        sta m_res+1
?done   rts
.endp
    .if * > SMUL14_END+1
        ert 'smul_14 outgrew SMUL14_BASE..END (memory_map.inc)'
    .endif
        org sm14_resume

;--------------------------------------------------------------
; smul32 -- SIGNED 16x16 -> 32 (full product). m_a*m_b -> m_prod(4).
;--------------------------------------------------------------
; m_neg / m_negb -- (m_a, m_a+1) = -(m_a, m_a+1), the 16-bit two's complement,
;   and the same for m_b. Seven instructions that were written out TWENTY-ONE
;   times across the port (collision, colmerge, doors, enemy, math, powerups,
;   proj, tw_setup) -- 273 B of identical code where 3 B of `jsr` does.
;
;   It is an EXACT substitution, which is why every one of those sites could
;   take it: the body is unchanged and `rts` alters neither A nor the flags, so
;   a caller still gets the high byte in A and the N/V/Z/C of the final `sbc`.
;   Nearly every call site is `lda m_a+1 / bpl skip / jsr m_neg` -- abs() -- and
;   that test stays with the caller: some of them want the sign afterwards.
;--------------------------------------------------------------
.proc m_neg
        sec
        lda #0
        sbc m_a
        sta m_a
        lda #0
        sbc m_a+1
        sta m_a+1
        rts
.endp

.proc m_negb
        sec
        lda #0
        sbc m_b
        sta m_b
        lda #0
        sbc m_b+1
        sta m_b+1
        rts
.endp

;--------------------------------------------------------------
.proc smul32
        lda #0
        sta m_sign
        lda m_a+1
        bpl ?ap
        inc m_sign
        jsr m_neg
?ap     lda m_b+1
        bpl ?bp
        lda m_sign
        eor #1
        sta m_sign
        jsr m_negb
?bp     jsr umul16
        lda m_sign
        beq ?done
        sec                          ; negate m_prod (4 bytes)
        lda #0
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+1
        sta m_prod+1
        lda #0
        sbc m_prod+2
        sta m_prod+2
        lda #0
        sbc m_prod+3
        sta m_prod+3
?done   rts
.endp

;--------------------------------------------------------------
; cross_pos -- A = 1 if (cx_a*cx_b - cx_c*cx_d) > 0, else 0  (all signed16).
;--------------------------------------------------------------
.proc cross_pos
        lda cx_a
        sta m_a
        lda cx_a+1
        sta m_a+1
        lda cx_b
        sta m_b
        lda cx_b+1
        sta m_b+1
        jsr smul32                   ; m_prod = a*b
        ldx #3
?s1     lda m_prod,x
        sta cx_p1,x
        dex
        bpl ?s1
        lda cx_c
        sta m_a
        lda cx_c+1
        sta m_a+1
        lda cx_d
        sta m_b
        lda cx_d+1
        sta m_b+1
        jsr smul32                   ; m_prod = c*d
        sec                          ; cx_p1 -= m_prod  (P1 - P2)
        lda cx_p1
        sbc m_prod
        sta cx_p1
        lda cx_p1+1
        sbc m_prod+1
        sta cx_p1+1
        lda cx_p1+2
        sbc m_prod+2
        sta cx_p1+2
        lda cx_p1+3
        sbc m_prod+3
        sta cx_p1+3                  ; sign test (sta leaves sbc's N alone)
        bmi ?zero                    ; negative -> not > 0
        lda cx_p1
        ora cx_p1+1
        ora cx_p1+2
        ora cx_p1+3
        beq ?zero                    ; zero -> not > 0
        lda #1
        rts
?zero   lda #0
        rts
.endp

;--------------------------------------------------------------
; transform -- world (zp_rx,zp_ry signed16, relative to player) ->
;   view (zp_X, zp_Z signed16).  Uses frame zp_sin, zp_cos (Q14).
;     X = (rx*sin - ry*cos) >> 14
;     Z = (rx*cos + ry*sin) >> 14
;--------------------------------------------------------------
; --- frac-table transform multiply (frame-constant sin/cos) ------------------
;   Replaces 4 umul16/endpoint with table lookups. T[b] = |const|*b (3-byte,
;   built per frame by build_frac_tables). (var16 * const)>>14 sign-magnitude,
;   BIT-IDENTICAL to smul_14 (tools/_verify_fractab.py, 0 mismatches/256 angles).
;     |var|*|const| = T[var_lo] + (T[var_hi] << 8)   (2 lookups + shifted add)
;   FMUL :1=Tlo :2=Tmi :3=Thi :4=const_sign_var.  in m_a(signed16) -> m_res.
.macro FMUL
        lda :4                     ; total sign = sign(var) XOR sign(const)
        sta m_sign
        lda m_a+1
        bpl ?abs
        lda m_sign
        eor #1
        sta m_sign
        jsr m_neg                    ; m_a = |var|
        ; --- THE TABLE CARRIES THE >>14. build_frac_tables stores 4*|const|*b,
        ;     so this sum IS (|var|*|const|) << 2 and its top two bytes ARE the
        ;     >>14 the transform wants: the eight-shift chain is gone, and with
        ;     it bytes 0 and 1 -- byte 0 is a plain copy that cannot carry, and
        ;     byte 1 is read only for ITS carry. 98 cycles -> 36, on the routine
        ;     the view transform calls four times per vertex. Same number, not a
        ;     cheaper approximation of it: 4*T[b] is exact (< 2^24) and the sum
        ;     still fits 32 bits, so <<2 never loses a bit here either.
?abs    ldx m_a                    ; lo byte index
        ldy m_a+1                  ; hi byte index
        clc
        lda :2,x                   ; byte1 = Tmi[lo] + Tlo[hi]  (carry only)
        adc :1,y
        lda :3,x                   ; byte2 = Thi[lo] + Tmi[hi] + carry
        adc :2,y
        sta m_res
        lda :3,y                   ; byte3 = Thi[hi] + carry
        adc #0
        sta m_res+1
        lda m_sign                 ; apply sign
        beq ?done
        sec
        lda #0
        sbc m_res
        sta m_res
        lda #0
        sbc m_res+1
        sta m_res+1
?done
.endm

.proc fmul_sin
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn
        rts
.endp

.proc fmul_cos
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn
        rts
.endp

;--------------------------------------------------------------
; build_frac_tables -- (re)build TSIN/TCOS so T[b] = 4*|sin|*b, 4*|cos|*b
;   (b=0..255) via running sum (no multiplies). Also latches sin_sgn/cos_sgn.
;   Called from frame_setup ONLY when the angle changed since the last build
;   (frame_ang gate, renderer.asm) -- walking straight costs nothing.
;   Relocated to FRACTAB_BASE: it runs at most ONCE a frame, so the $2000
;   segment (which the seg-level frustum reject pushed against its $3C73
;   ceiling) is the wrong home for 150 bytes of it. Still Rapidus-fast RAM,
;   because the 24576 cycles it does spend are one tight loop.
;--------------------------------------------------------------
bft_resume = *
        org FRACTAB_BASE
.proc build_frac_tables
        ; --- |sin| + sign -> TSIN ---
        lda #0
        sta sin_sgn
        lda zp_sin
        sta m_a
        lda zp_sin+1
        sta m_a+1
        bpl ?sp
        inc sin_sgn
        jsr m_neg
?sp     jsr ?step4                 ; m_ma = |sin| << 2 -- the >>14 FMUL used to
        lda #0                     ;   pay eight shifts for, folded into the
        sta m_prod                 ;   table once per rotation frame instead
        sta m_prod+1
        sta m_prod+2
        sta TSIN_LO
        sta TSIN_MI
        sta TSIN_HI
        ldx #1
?sl     clc                        ; acc += 4*|sin|; store T[x]
        lda m_prod
        adc m_ma
        sta m_prod
        sta TSIN_LO,x
        lda m_prod+1
        adc m_ma+1
        sta m_prod+1
        sta TSIN_MI,x
        lda m_prod+2
        adc m_ma+2
        sta m_prod+2
        sta TSIN_HI,x
        inx
        bne ?sl
        ; --- |cos| + sign -> TCOS ---
        lda #0
        sta cos_sgn
        lda zp_cos
        sta m_a
        lda zp_cos+1
        sta m_a+1
        bpl ?cp
        inc cos_sgn
        jsr m_neg
?cp     jsr ?step4
        lda #0
        sta m_prod
        sta m_prod+1
        sta m_prod+2
        sta TCOS_LO
        sta TCOS_MI
        sta TCOS_HI
        ldx #1
?cl     clc
        lda m_prod
        adc m_ma
        sta m_prod
        sta TCOS_LO,x
        lda m_prod+1
        adc m_ma+1
        sta m_prod+1
        sta TCOS_MI,x
        lda m_prod+2
        adc m_ma+2
        sta m_prod+2
        sta TCOS_HI,x
        inx
        bne ?cl
        rts
?step4  lda m_a                    ; m_ma(24b) = m_a << 2. |sin| reaches 16384
        asl                        ;   (Q14 1.0), so 4*|sin| needs 17 bits and
        sta m_ma                   ;   the running sum needs a 3-byte step.
        lda m_a+1
        rol
        sta m_ma+1
        lda #0
        rol
        sta m_ma+2
        asl m_ma
        rol m_ma+1
        rol m_ma+2
        rts
.endp
    .if * > FRACTAB_END+1
        ert 'build_frac_tables outgrew FRACTAB_BASE..END (memory_map.inc)'
    .endif
        org bft_resume

;--------------------------------------------------------------
; transform -- world (zp_rx,zp_ry signed16, relative to player) -> view
;   (zp_X, zp_Z signed16) via the frac-table muls (frame sin/cos).
;     X = (rx*sin - ry*cos) >> 14 ;  Z = (rx*cos + ry*sin) >> 14
;--------------------------------------------------------------
.proc transform
        lda zp_rx                  ; X = rx*sin - ry*cos
        sta m_a
        lda zp_rx+1
        sta m_a+1
        jsr fmul_sin
        lda m_res
        sta zp_X
        lda m_res+1
        sta zp_X+1
        lda zp_ry
        sta m_a
        lda zp_ry+1
        sta m_a+1
        jsr fmul_cos
        sec
        lda zp_X
        sbc m_res
        sta zp_X
        lda zp_X+1
        sbc m_res+1
        sta zp_X+1
        lda zp_rx                  ; Z = rx*cos + ry*sin
        sta m_a
        lda zp_rx+1
        sta m_a+1
        jsr fmul_cos
        lda m_res
        sta zp_Z
        lda m_res+1
        sta zp_Z+1
        lda zp_ry
        sta m_a
        lda zp_ry+1
        sta m_a+1
        jsr fmul_sin
        clc
        lda zp_Z
        adc m_res
        sta zp_Z
        lda zp_Z+1
        adc m_res+1
        sta zp_Z+1
        rts
.endp

;--------------------------------------------------------------
; udiv24 -- UNSIGNED (m_num: 24-bit in m_prod[0..2]) / (m_den 16) ->
;   quotient m_quot(2), remainder m_rem(2).  Restoring division.
;
; THE ONE ROUTINE THAT COSTS THE MOST. 543 calls in a rendered E1M1 frame at
; 1476 cycles each = 15 % of the whole frame (tools/_prof_procs.py) -- more than
; the wall painter's own body. Two bit-exact changes buy most of it back:
;
; 1. SKIP THE LEADING ZERO QUOTIENT BITS. Restoring division walks the dividend
;    MSB-first and emits a quotient bit per step. While the prefix shifted in so
;    far is < den that bit is 0 and the remainder is simply the prefix itself --
;    so any prefix known to be < den can be LOADED into the remainder and its
;    steps skipped outright. Two 16-bit compares pick the longest such prefix:
;      top 16 bits < den -> remainder = them, 8 steps left  (calc_u: always)
;      top  8 bits < den -> remainder = them, 16 steps left (tw_setup: always)
;      neither           -> the full 24 (den = 0 lands here, unchanged)
;    Every skipped step would have produced a 0 into the quotient's low end, so
;    the result is the same number, not an approximation of it.
; 2. THE QUOTIENT RIDES IN THE DIVIDEND. asl m_prod vacates bit 0 exactly as it
;    consumes a dividend bit, so the quotient bit goes there (inc m_prod, only
;    when it is 1) instead of into a second 16-bit rol pair. 10 cycles a step.
;
; Relocated to FASTDIV_BASE: three loop bodies do not fit the $2000 segment, and
; this is per-column code that wants the Rapidus-fast window anyway.
; Bit-identical to the old single 24-step loop over every input the renderer
; produces -- tools/_verify_udiv.py checks all three paths against it.
;--------------------------------------------------------------
udiv_resume = *
        org FASTDIV_BASE
.proc udiv24
        lda m_prod+2                 ; top 16 bits of the dividend vs den
        cmp m_den+1
        bcc ?pre16
        bne ?hi8
        lda m_prod+1
        cmp m_den
        bcc ?pre16
?hi8    lda m_den+1                  ; top 8 bits vs den: den >= 256 always wins
        bne ?pre8
        lda m_prod+2
        cmp m_den
        bcs ?full                    ; ... and den = 0 falls here, as before
?pre8   lda m_prod+2                 ; ---- 16 steps: remainder = the top byte ----
        sta m_rem
        lda #0
        sta m_rem+1
        ; ---- 65816 NATIVE, 16-BIT ACCUMULATOR (2026-08-11 pm) ---------------
        ; This is the path tw_setup takes on EVERY column, so it is where the
        ; port's first 16-bit block goes. Each step was four 8-bit shifts + a
        ; two-byte subtract done as lda/sbc/tay/lda/sbc/sta/sty; with M=0 it is
        ; one 16-bit shift pair and ONE subtract -- the same bits, half the
        ; instructions. m_prod/m_rem/m_den are all zero page, so a 16-bit
        ; access costs one extra cycle and replaces two whole instructions.
        ; Only M is switched (rep #$20): X stays 8-bit, so `ldx #16` keeps its
        ; one-byte immediate and no assembler width directive is needed.
        ; Interrupts are SAFE here -- urom_init installs the native vectors
        ; $FFEA/$FFEE and both handlers pin A 8-bit before they push (rom_nmi
        ; with sep #$20, snd_irq with sep #$30 over a full-width phx/phy) --
        ; and an NMI taken mid-block returns through RTI, which restores M
        ; from the pushed P.
        ;
        ; NO clc/xce PAIR (2026-08-14). It used to bracket this block, and the
        ; `sec/xce` on the way out left the CPU in EMULATION mode -- every caller
        ; is in the frame loop, where underrom.asm's invariant (ROM OUT <=>
        ; NATIVE) says it is already native, so the entry half was a no-op and
        ; the exit half silently broke the invariant for everything downstream.
        ; udiv24 runs on every column, so from the first wall of the first frame
        ; the whole engine ran as a 6502 -- and rep/sep of the M/X bits is
        ; IGNORED in emulation mode. Nothing 8-bit noticed; the two routines that
        ; do rely on the width bits did. It cost the automap every 16-bit index
        ; it takes (am_mark's mark went into the $03:00xx slack page instead of
        ; AMSEEN, and am_walls' `ldx am_i8` wrapped every 32 segs, which is
        ; exactly the corner of the map it drew -- tools/tests/_verify_automap.py).
        ; Dropping the pair is also what the invariant was FOR: 4 bytes and ~10
        ; cycles a call, and udiv24 is called ~13 times per seg.
        rep #$20                     ; 16-bit A (native: the frame loop's mode)
        ldx #16
?l16    asl m_prod                   ; dividend MSB -> carry (16-bit)
        rol m_rem                    ; ... into the remainder (16-bit)
        sec
        lda m_rem
        sbc m_den                    ; ONE subtract, both bytes
        bcc ?s16
        sta m_rem                    ; rem >= den -> commit
        inc m_prod                   ; quotient bit 1 -> the bit asl just vacated
?s16    dex
        bne ?l16
        lda m_prod                   ; the dividend register IS the quotient now
        sta m_quot                   ;   (16-bit: both bytes in one move)
        sep #$20                     ; back to 8-bit A -- and STAY native, see
        rts                          ;   the block comment above

?pre16  lda m_prod+1                 ; ---- 8 steps: remainder = the top 16 bits,
        sta m_rem                    ;      so the quotient cannot exceed 255 ----
        lda m_prod+2
        sta m_rem+1
        ldx #8
?l8     asl m_prod
        rol m_rem
        rol m_rem+1
        sec
        lda m_rem
        sbc m_den
        tay
        lda m_rem+1
        sbc m_den+1
        bcc ?s8
        sta m_rem+1
        sty m_rem
        inc m_prod
?s8     dex
        bne ?l8
        lda m_prod
        sta m_quot
        lda #0
        sta m_quot+1
        rts
?full   lda #0                       ; ---- the original 24 steps ----
        sta m_rem
        sta m_rem+1
        ldx #24
?l24    asl m_prod                   ; shift dividend MSB into remainder
        rol m_prod+1
        rol m_prod+2
        rol m_rem
        rol m_rem+1
        sec                          ; tentative rem - den
        lda m_rem
        sbc m_den
        tay
        lda m_rem+1
        sbc m_den+1
        bcc ?s24                     ; rem < den -> carry clear -> quotient bit 0
        sta m_rem+1                  ; rem >= den -> commit
        sty m_rem
        inc m_prod
?s24    dex
        bne ?l24
        lda m_prod                   ; the 24-step tail, still 8-bit: this path
        sta m_quot                   ;   FALLS THROUGH into it instead of the
        lda m_prod+1                 ;   old `jmp ?q16` -- the 16-step path took
        sta m_quot+1                 ;   ?q16 into its native block, and those
        rts                          ;   three bytes are what pays for it
.endp
    .if * > FASTDIV_END+1
        ert 'udiv24 outgrew FASTDIV_BASE..FASTDIV_END (memory_map.inc)'
    .endif
        org udiv_resume

;--------------------------------------------------------------
; udiv16 -- UNSIGNED (16-bit dividend m_prod[0..1]) / (m_den 16) -> m_quot(2).
;   tips #5b (examples/math): when the dividend fits 16 bits the top 8 of the
;   24 iterations only shift in leading zeros -> skip them. 16 iterations give
;   the IDENTICAL quotient (verified vs udiv24 over the full Z range, 0 diffs).
;   Caller guarantees m_prod[0..1] holds the dividend (m_prod+2 ignored).
;--------------------------------------------------------------
.proc udiv16
        lda #0
        sta m_rem
        sta m_rem+1
        sta m_quot
        sta m_quot+1
        ldx #16
?l      asl m_prod                 ; shift 16-bit dividend MSB into remainder
        rol m_prod+1
        rol m_rem
        rol m_rem+1
        sec                        ; tentative rem - den
        lda m_rem
        sbc m_den
        tay
        lda m_rem+1
        sbc m_den+1
        bcc ?skip
        sta m_rem+1
        sty m_rem
?skip   rol m_quot
        rol m_quot+1
        dex
        bne ?l
        rts
.endp

;--------------------------------------------------------------
; recip_norm -- normalize zp_Z (16-bit, >0) to a 9-bit mantissa + exponent for
;   the reciprocal tables. out: Y = table index (mantissa low byte; m in
;   [256,511] -> hi byte is 1), rc_e = exponent e (signed; Z ~= m << e).
;   Mirrors gui.py _norm(). Z-range-independent (survives ATR level streaming).
;--------------------------------------------------------------
.proc recip_norm
        ; caller preloads rc_m (16-bit value to normalize: Z or span).
        lda #0
        sta rc_e
?up     lda rc_m+1                 ; while m >= 512 (hi >= 2): m >>= 1, e++
        cmp #2
        bcc ?dn
        lsr rc_m+1
        ror rc_m
        inc rc_e
        jmp ?up
?dn     lda rc_m+1                 ; while m < 256 (hi == 0): m <<= 1, e--
        bne ?done
        asl rc_m
        rol rc_m+1
        dec rc_e
        jmp ?dn
?done   ldx rc_m                   ; index = mantissa low byte (hi == 1)
        rts                        ; X, not Y: the tables live in Rapidus bank
.endp                              ;   $01 now and `lda.l tab,y` does not exist
                                   ;   on the 65816 -- only absolute-long,X.
                                   ;   No caller had X live across this call.

;--------------------------------------------------------------
; shr_prod32 -- shift m_prod (32-bit) right by X bits (X in 0..31). Drops whole
;   low bytes first (X>>3), then the residual X&7 bit-shifts. Applies the
;   reciprocal shift (RECIP_SCALE_K / RECIP_SX_K + e).
;--------------------------------------------------------------
.proc shr_prod32
        txa
        lsr
        lsr
        lsr                        ; whole bytes to drop (X>>3)
        beq ?bits
        tay
?byte   lda m_prod+1               ; prod >>= 8
        sta m_prod
        lda m_prod+2
        sta m_prod+1
        lda m_prod+3
        sta m_prod+2
        lda #0
        sta m_prod+3
        dey
        bne ?byte
?bits   txa
        and #7
        beq ?done
        tax
?bit    lsr m_prod+3
        ror m_prod+2
        ror m_prod+1
        ror m_prod
        dex
        bne ?bit
?done   rts
.endp

;--------------------------------------------------------------
; shr_acc40 -- shift rs_acc (40-bit, 5 bytes) right by X bits (X in 0..39).
;   Whole low bytes (X>>3) then residual X&7. For the inv_span step shift.
;--------------------------------------------------------------
.proc shr_acc40
        txa
        lsr
        lsr
        lsr                        ; whole bytes to drop
        beq ?bits
        tay
?byte   lda rs_acc+1               ; rs_acc >>= 8
        sta rs_acc
        lda rs_acc+2
        sta rs_acc+1
        lda rs_acc+3
        sta rs_acc+2
        lda rs_acc+4
        sta rs_acc+3
        lda #0
        sta rs_acc+4
        dey
        bne ?byte
?bits   txa
        and #7
        beq ?done
        tax
?bit    lsr rs_acc+4
        ror rs_acc+3
        ror rs_acc+2
        ror rs_acc+1
        ror rs_acc
        dex
        bne ?bit
?done   rts
.endp

;--------------------------------------------------------------
; step_recip -- track step = (R-L) / span via the inv_span reciprocal (replaces
;   sdiv_prod). IN: m_prod[0..2] = (R-L) signed 24-bit; rs_invm (16-bit 1/span),
;   rs_invsh (shift). OUT: m_quot = step (signed 16-bit). Sign-magnitude 24x16
;   (lo16*invm + (hi8*invm)<<16) >> rs_invsh. Bit-identical to gui.INVSPAN
;   (tools/_verify_invspan.py). Computes inv_span once/seg; this is per plane.
;--------------------------------------------------------------
.proc step_recip
        lda #0
        sta m_sign
        lda m_prod+2               ; sign + |R-L| -> rs_mag
        bpl ?pos
        inc m_sign
        sec
        lda #0
        sbc m_prod
        sta rs_mag
        lda #0
        sbc m_prod+1
        sta rs_mag+1
        lda #0
        sbc m_prod+2
        sta rs_mag+2
        jmp ?mul
?pos    lda m_prod
        sta rs_mag
        lda m_prod+1
        sta rs_mag+1
        lda m_prod+2
        sta rs_mag+2
?mul    lda rs_mag                 ; lo16 * invm -> rs_acc[0..3], acc[4]=0
        sta m_a
        lda rs_mag+1
        sta m_a+1
        lda rs_invm
        sta m_b
        lda rs_invm+1
        sta m_b+1
        jsr umul16
        lda m_prod
        sta rs_acc
        lda m_prod+1
        sta rs_acc+1
        lda m_prod+2
        sta rs_acc+2
        lda m_prod+3
        sta rs_acc+3
        lda #0
        sta rs_acc+4
        lda rs_mag+2               ; hi8 * invm -> add at byte offset 2
        sta m_a
        lda #0
        sta m_a+1
        lda rs_invm
        sta m_b
        lda rs_invm+1
        sta m_b+1
        jsr umul16                 ; m_prod[0..2] = hi8*invm (m_prod+3=0)
        clc
        lda rs_acc+2
        adc m_prod
        sta rs_acc+2
        lda rs_acc+3
        adc m_prod+1
        sta rs_acc+3
        lda rs_acc+4
        adc m_prod+2
        sta rs_acc+4
        ldx rs_invsh               ; >> rs_invsh (15..27)
        jsr shr_acc40
        ; --- SATURATE |step| at 32767 -----------------------------------------
        ; m_quot is 16 bits and the caller adds it to a 24-bit plane accumulator
        ; once per column, so a step that does not fit used to WRAP -- and a wrap
        ; past $8000 FLIPS THE SIGN (m_sign is applied below), so the plane ran
        ; BACKWARDS across the seg: the front ceiling walked DOWN through the
        ; view instead of up out of it, and draw_clip then filled the seg's whole
        ; span with the ceiling colour. That is the grey slab that blinks in when
        ; the player stands ON a two-sided line -- E1M1 (1858,-2558) is 2 units
        ; off ld416, the edge of the lower ceiling (sector 8 ceil 224 -> sector 9
        ; ceil 96): seg 87 near-clips to Z=4 at one end, so wh=183 runs from
        ; scale 435 to 10240 over 50 columns and |step| = 35887 -> -29649 ->
        ; +29649. Same trigger as u_guard's ("the flat-looking slab of wall that
        ; flashes in for a frame"), one track further along.
        ; Clamping is invisible: |step| >= 2^15 is >= 128 rows per column, so the
        ; plane crosses all 100 rows inside a single column -- off screen on both
        ; sides of the crossing whichever of the two slopes it uses. Verified
        ; pixel-identical to unlimited-precision math over all 256 angles at that
        ; spot (63772 wrong pixels -> 0).
        lda rs_acc+2               ; any bit above 15 set -> saturate
        ora rs_acc+3
        ora rs_acc+4
        bne ?sat
        lda rs_acc+1
        bmi ?sat                   ; bit 15 set -> >= 32768
        lda rs_acc                 ; result low 16 -> m_quot, apply sign
        sta m_quot
        lda rs_acc+1
        sta m_quot+1
        jmp ?sgn
?sat    lda #$FF
        sta m_quot
        lda #$7F
        sta m_quot+1
?sgn    lda m_sign
        beq ?done
        sec
        lda #0
        sbc m_quot
        sta m_quot
        lda #0
        sbc m_quot+1
        sta m_quot+1
?done   rts
.endp

;--------------------------------------------------------------
; scale_z -- m_quot(2) = (VFOCAL<<SF) / zp_Z via SCALE_TAB reciprocal (no
;   division -- the per-seg bottleneck). zp_Z must be > 0 (post near-clip).
;   scale = SCALE_TAB[m] >> (RECIP_SCALE_K + e). Bit-identical to gui.scale_recip.
;--------------------------------------------------------------
.proc scale_z
        lda zp_Z                   ; normalize Z
        sta rc_m
        lda zp_Z+1
        sta rc_m+1
        jsr recip_norm             ; X = mantissa idx, rc_e = e
        lda.l RCX_SCALE_LO,x       ; the table is in bank $01 (memory_map.inc
        sta m_prod                 ;   RECIP_EXT): +1 cycle per read, and the
        lda.l RCX_SCALE_HI,x       ;   1536 B it vacated at $8700 is where the
        sta m_prod+1               ;   monster AI lives
        lda #0
        sta m_prod+2
        sta m_prod+3
        clc                        ; shift = RECIP_SCALE_K + e (signed e; = 2..13)
        lda #RECIP_SCALE_K
        adc rc_e
        clc                        ; + vw_sh: the view-size divider, free here
        adc vw_sh                  ;   (rc_e is signed, so that adc CAN carry --
        tax                        ;   hence the second clc)
        jsr shr_prod32
        jsr vw_q34x                ; ... and *3/4 for the in-between sizes
        lda m_prod
        sta m_quot
        lda m_prod+1
        sta m_quot+1
        rts
.endp

;--------------------------------------------------------------
; screenx_signed -- UNCLAMPED signed screen-X for (zp_X signed16, zp_Z>0).
;   m_xs(2,signed) = SCREEN_HALF + (FOCAL*X)/Z. Used as the interpolation
;   anchors (the clamped 0..W-1 column range is derived separately).
;--------------------------------------------------------------
.proc screenx_signed
        lda #0
        sta m_sign
        lda zp_X
        sta m_a
        lda zp_X+1
        sta m_a+1
        bpl ?xp
        inc m_sign                 ; m_a = |X|
        jsr m_neg
?xp     lda zp_Z                   ; normalize Z
        sta rc_m
        lda zp_Z+1
        sta rc_m+1
        jsr recip_norm             ; X = mantissa idx, rc_e = e
        lda.l RCX_SX_LO,x          ; m_b = SX_TAB[m] (FOCAL baked in), bank $01
        sta m_b
        lda.l RCX_SX_HI,x
        sta m_b+1
        jsr umul16                 ; m_prod(4) = |X| * SX_TAB[m]
        clc                        ; shift = RECIP_SX_K + e (signed e; = 11..22)
        lda #RECIP_SX_K
        adc rc_e
        clc                        ; + vw_sh: the view-size divider (see scale_z;
        adc vw_sh                  ;   the SAME factor, or the picture stops
        tax                        ;   being square)
        jsr shr_prod32             ; m_prod[0..1] = |offset| px
        ; --- saturate |offset| at 16384. The true offset reaches 80*32767/4 =
        ; ~655k px on a long wall walked past at close range; reading only
        ; m_prod[0..1] wrapped it mod 65536, and the wrapped m_xs mis-ordered /
        ; mis-spanned the seg in process_seg -- a far one-sided wall then painted
        ; every still-open column: the transient "brown wall in the window"
        ; (1..4.png, tools/_verify_segdrop.py). Any real |sx| >= 256 behaves
        ; identically downstream, so clamping at 16384 changes no visible frame.
        lda m_prod+2
        ora m_prod+3
        bne ?sat                   ; bits 16+ set -> way past the clamp
        lda m_prod+1
        cmp #$40                   ; |offset| >= $4000?
        bcc ?off_ok
?sat    lda #0
        sta m_prod
        lda #$40
        sta m_prod+1
?off_ok jsr vw_q34x                ; view size: *3/4 (AFTER the clamp -- the
                                   ;   saturated value stays far off-screen)
        lda m_sign
        bne ?neg
        clc                        ; +X: SCREEN_HALF + offset
        lda #SCREEN_HALF
        adc m_prod
        sta m_xs
        lda #0
        adc m_prod+1
        sta m_xs+1
        rts
?neg    sec                        ; -X: SCREEN_HALF - offset
        lda #SCREEN_HALF
        sbc m_prod
        sta m_xs
        lda #0
        sbc m_prod+1
        sta m_xs+1
        rts
.endp

;--------------------------------------------------------------
; track_calc -- m_prod[0..2] = (HH<<SF) - m_a*m_b   (24-bit signed).
;   m_a = world height (signed16), m_b = scale (signed16). HH<<SF = 50*256
;   = 12800 = $3200. This is the DOOM screen-Y for one height plane (Q8).
;--------------------------------------------------------------
.proc track_calc
        jsr smul32                 ; m_prod(4) = world*scale (signed)
        sec                        ; m_prod[0..2] = HHFP - m_prod  (horizon - world*scale)
        lda #<HHFP
        sbc m_prod
        sta m_prod
        lda #>HHFP
        sbc m_prod+1
        sta m_prod+1
        lda #0
        sbc m_prod+2
        sta m_prod+2
        rts
.endp

; NOTE 2026-07-25: sdiv_prod, clamp_tb and screenx used to live here (180 B).
; All three were dead -- nothing jsr'd them since inv_span replaced the per-column
; divide (rs_invm), draw_clip took over the clamping and screenx_signed the
; projection. Removed to make room in the full $2000 segment; git history has them.