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
;==============================================================
; math.asm -- fixed-point helpers for the BSP renderer.
;   Correctness-first: plain shift/add multiply + shift/sub divide
;   (easy to verify by reading). The fast wolf3d quarter-square mul
;   replaces these once the geometry is proven correct.
;
; All signed 16-bit unless noted. ZP scratch defined in bsp_main.asm.
;==============================================================

;--------------------------------------------------------------
; qsmul -- INLINED 8x8 -> 16 quarter-square.  :3(2) = (:1) * (:2)
;   a*b = QSqr[a+b] - QSqr[|a-b|], QSqr[x]=floor(x^2/4) (qs_tables.inc).
;   tips2 #3: a macro inlined 4x into umul16 -> no jsr/rts, reads the
;   operand bytes directly (no qs_x/qs_y staging). Clobbers A,Y.
;   :3 is the 16-bit DESTINATION -- qs_p for every caller but umul16's first
;   product, which lands straight in m_prod and saves the copy that followed.
;--------------------------------------------------------------


.macro qsmul
        clc
        lda :1
        adc :2                     ; x+y (9-bit: Y=low8, carry=bit8)
        tay
        bcc ?base                  ; THE COMMON HALF FALLS THROUGH (2026-08-30).
        lda QSqrLoExt,y            ;   x+y < 256 is 83 % of the executions
        sta :3                     ;   (_peep_pc: 861 of 1040 a frame), and it
        lda QSqrHiExt,y            ;   used to pay `bcs` + a 3-cycle `jmp` to
        bcs ?have                  ;   skip this block. Now it pays one taken
?base   lda QSqrLoBase,y           ;   branch and the RARE half carries the
        sta :3                     ;   jump back -- `bcs` is unconditional
        lda QSqrHiBase,y           ;   here, the adc's carry is still set
?have   sta :3+1
        sec                        ; |x-y| (0..255 -> Base table)
        lda :1
        sbc :2
        bcs ?dok
        eor #$FF                   ; the carry is ALREADY clear -- that is what
 .if 1
	inc
 .else
        adc #1                     ;   the bcs above just tested -- so the `clc`
 .endif
?dok    tay                        ;   that stood here was dead (2 cyc, 83 %)
        sec                        ; :3 -= QSqr[|x-y|]
        lda :3
        sbc QSqrLoBase,y
        sta :3
        lda :3+1
        sbc QSqrHiBase,y
        sta :3+1
.endm

;--------------------------------------------------------------
; qsmulx -- the same product with |x-y| in X (2026-09-15, umul16 only).
;   With BOTH indices in registers the two table reads are FUSED with the
;   subtraction: QSqr[x+y] never goes through :3 and back (four dp accesses,
;   12 cycles per product). Clobbers A, X, Y -- umul16 saves X for its callers
;   (movers.asm keeps the texture index in X across the call).
;--------------------------------------------------------------
.macro qsmulx
        sec                        ; |x-y| FIRST, into X (0..255 -> Base table)
        lda :1
        sbc :2
        bcs ?dok
        eor #$FF                   ; the carry is clear: that is what the bcs
        inc                        ;   just tested, so inc IS the +1
?dok    tax
        clc
        lda :1
        adc :2                     ; x+y (9-bit: Y=low8, carry=bit8)
        tay
        bcc ?base                  ; THE COMMON HALF (83 %) takes one branch;
        lda QSqrLoExt,y            ;   the rare half carries the jump back.
        sbc QSqrLoBase,x           ;   C = 1 here: the adc's carry IS the sec
        sta :3
        lda QSqrHiExt,y
        sbc QSqrHiBase,x
        bra ?have
?base   sec
        lda QSqrLoBase,y           ; :3 = QSqr[x+y] - QSqr[|x-y|], one pass
        sbc QSqrLoBase,x
        sta :3
        lda QSqrHiBase,y
        sbc QSqrHiBase,x
?have   sta :3+1
.endm

;--------------------------------------------------------------
; umul16 -- UNSIGNED 16x16 -> 32.  m_a(2) * m_b(2) -> m_prod(4)
;   tips #2/#3: four 8x8 quarter-square products (inlined qsmul) instead
;   of the 16-iteration shift/add loop.  Bit-identical, much faster.
;     P = p00 + (p01+p10)<<8 + p11<<16
;     p00=aL*bL  p01=aL*bH  p10=aH*bL  p11=aH*bH   (aL=m_a, aH=m_a+1, ...)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc umul16
 .ifdef ANTONIA2
        ; ---- ANTONIA II HARDWARE MULTIPLIER (drac030, 2026-09-10) -----------
        ; $FFF00C/$FFF00E take the two 16-bit factors, $FFF00C..$FFF00F hands
        ; back the 32-bit product: CONSTANT 46 cycles, against 80..360+ for the
        ; four quarter-squares below. Bit-identical -- the same unsigned product
        ; -- so every caller (smul32 included) inherits it unchanged.
        ; drac030's file, dropped in verbatim so a newer one can replace it
        ; without re-editing math.asm. NOT Rapidus-compatible; build it with
        ;   .\build_atr.ps1 -Antonia2
        icl 'umul16a.asm'
 .else
        ; --- THE OPERANDS ARE SMALL. Measured on a real frame
        ;     (tools/_dbg_mathargs.py, 1307 calls): m_a < 256 in 76 % of them and
        ;     BOTH < 256 in 44 %. A zero high byte makes p10 and p11 zero and
        ;     p01 zero as well, i.e. three of the four quarter-squares are
        ;     multiplying by nothing. Testing for it costs 5 cycles and skips up
        ;     to 260 -- and it is not an approximation: the products it drops
        ;     ARE zero, so the 32-bit result is the same.
        phx                        ; qsmulx eats X (2026-09-15); 7 cycles a call
                                   ;   against 12 saved per product, ~1.8 of them
        qsmulx m_a, m_b, m_prod    ; p00 = aL*bL, written STRAIGHT into bytes 0,1
                                   ;   (2026-08-30). It used to land in qs_p and
                                   ;   then be copied here -- 12 cycles on every
                                   ;   one of the 1040 calls a frame, for nothing:
                                   ;   only the OTHER three products need qs_p,
                                   ;   because they are ADDED to m_prod. p00 has
                                   ;   nothing to add to, so it can just land.
        stz m_prod+2               ; bytes 2,3 start at zero and the products that
        stz m_prod+3               ;   would land there are now ADDED, not stored,
                                   ;   which is what lets any of them be skipped.
                                   ;   stz, not lda #0/sta: A dies on the next
                                   ;   line, 1,023 calls/frame (_an_drac030)
        lda m_a+1
        ora m_b+1
        bne ?more
        plx
        rts
 .if 0                             ; both high bytes 0 -> p00 IS the product (44 %)
?far10  jmp ?p10                   ; TRAMPOLINE (2026-08-30). ?p10 sits past two
 .endif                            ;   qsmul expansions, out of branch reach, so
                                   ;   the test used to be `bne ?p01 / jmp ?p10`
                                   ;   -- a TAKEN branch on the 99 % path. Now
                                   ;   that path falls through and the 1 % path
                                   ;   pays the hop. Unreachable by fallthrough:
                                   ;   the rts above ends the block.
?more   lda m_b+1
 .if 1
	jeq ?p10
 .else
        beq ?far10                 ; bH = 0, aH != 0 -> only p10 is left (1 %)
 .endif
?p01    qsmulx m_a, m_b+1, qs_p    ; p01 = aL*bH -> add at byte 1
 .if 1
	rep #$21		;absorb CLC
	.LONGA ON
        lda m_prod+1
        adc qs_p
        sta m_prod+1
	sep #$20
	.LONGA OFF	
 .else
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
 .endif
        bcc ?p11
        inc m_prod+3
?p11    lda m_a+1
        bne ?p11go
        plx
        rts                        ; aH = 0 -> p10 = p11 = 0 (another 32 %)

?p11go  qsmulx m_a+1, m_b+1, qs_p        ; p11 = aH*bH -> add at byte 2
 .if 1
	rep #$21		;absorb CLC
	.LONGA ON
        lda m_prod+2
        adc qs_p
        sta m_prod+2
	sep #$20
	.LONGA OFF
 .else
        clc
        lda m_prod+2
        adc qs_p
        sta m_prod+2
        lda m_prod+3
        adc qs_p+1
        sta m_prod+3
 .endif
?p10    qsmulx m_a+1, m_b, qs_p          ; p10 = aH*bL -> add at byte 1
 .if 1
	rep #$21		;absorb CLC
	.LONGA ON
        lda m_prod+1
        adc qs_p
        sta m_prod+1
	sep #$20
	.LONGA OFF
 .else
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
 .endif
        bcc ?done
        inc m_prod+3
?done   plx
        rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; smul_14 -- SIGNED 16x16, result >> 14, -> m_res(2, signed)
;   inputs m_a, m_b (signed 16). Used by the view transform.
;   sign tracked separately; magnitudes via umul16; then >>14.
;   PARKED in win2 (SMUL14_BASE): see memory_map.inc -- it is the coldest .proc
;   in the $2000 engine segment, and step_recip below needed the bytes.
;--------------------------------------------------------------
sm14_resume = *
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
        org SMUL14_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc smul_14
 .if 1
        lda m_a+1
	eor m_b+1
	sta m_sign

	rep #$20
	.LONGA ON
        ; abs(m_a)
        lda m_a
        bpl ?a_pos
        eor #$ffff
	inc
	sta m_a
?a_pos
        ; abs(m_b)
        lda m_b
        bpl ?b_pos
        eor #$ffff
	inc
	sta m_b
?b_pos
	sep #$20
	.LONGA OFF
 .else
  .if 1
	stz m_sign
  .else
        lda #0
        sta m_sign
  .endif
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
 .endif
        jsr umul16

        ; m_prod >>= 14 via (m_prod << 2) >> 16: shift the 32-bit product LEFT
        ; twice, then the result is bytes [2],[3]. 8 shifts instead of the
        ; 14-iteration (56-shift) loop. Bit-identical (Gemini tip, tips #4b).
 .if 1
	rep #$20
	.LONGA ON
	lda m_prod
	asl
	rol m_prod+2
	asl
	rol m_prod+2
	sta m_prod

        ldy m_prod+1                 ; C = the dropped fraction's MSB: ROUND the
	cpy #$80
        lda m_prod+2                 ;   >>14 instead of truncating. Truncation
        adc #0                       ;   lost up to a whole unit per frame per
		                     ;   axis in move_player, bending the walk
                                     ;   heading up to 2 deg toward the nearest
                                     ;   axis ("pulls sideways", 2026-07-28 --
                                     ;   DOOM's fixed_t positions lose nothing)
        ; apply sign
        ldy m_sign
	bpl ?done

	eor #$ffff
	inc

?done   sta m_res

	sep #$20
	.LONGA OFF
	rts
 .else
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
 .endif

.endp
        .endseg
 .if 1                                ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
 .else
    .if * > SMUL14_END+1
        ert 'smul_14 outgrew SMUL14_BASE..END (memory_map.inc)'
    .endif
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc smul32
 .ifdef ANTONIA2
        ; ANTONIA II: |a| * |b| on the multiplier, the sign put back after --
        ; the software's own shape, minus the jsr and the write-back of |a|/|b|
        ; into m_a/m_b (every caller -- collision, cross_pos, seg_draw, sprites,
        ; the projection -- reads m_prod and reloads m_a/m_b). The factors stay
        ; at or below $8000, the range drac030's umul16 has been proven with on
        ; the card: how it treats bit 15 is not written down anywhere here, and
        ; the first version (the unsigned-wrap correction, factors up to $FFFF)
        ; drew a stray band at the E1M1 start on the real machine (draco.jpg).
        lda m_a+1
        eor m_b+1
        sta m_sign                   ; bit 7 = the product's sign
        rep #$20
        .LONGA ON
        lda m_a
        bpl ?ap
        eor #$FFFF
        inc @
?ap     sta.l ANT_MUL
        lda m_b
        bpl ?bp
        eor #$FFFF
        inc @
?bp     sta.l ANT_MUL+2
        lda.l ANT_MUL
        sta m_prod
        lda.l ANT_MUL+2
        sta m_prod+2
        sep #$20
        .LONGA OFF
        lda m_sign
        bpl ?pos
        rep #$20                     ; -m_prod, 32 bits in two word subtracts
        .LONGA ON
        sec
        lda #0
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+2
        sta m_prod+2
        sep #$20
        .LONGA OFF
?pos    rts
 .else
 .if 1
	lda m_a+1
	eor m_b+1
	sta m_sign

	rep #$20
	.LONGA ON
	lda m_a
	bpl ?ap
	eor #$ffff
	inc
	sta m_a
?ap
	lda m_b
	bpl ?bp
	eor #$ffff
	inc
	sta m_b
?bp
	sep #$20
	.LONGA OFF
 .else
  .if 1
	stz m_sign
  .else
        lda #0
        sta m_sign
  .endif
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
?bp
 .endif
	jsr umul16

        lda m_sign
        bpl ?done
 .if 1
	rep #$20
	.LONGA ON
	sec
        lda #0
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+2
        sta m_prod+2
	sep #$20
	.LONGA OFF
 .else
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
 .endif
?done   rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; cross_pos -- A = 1 if (cx_a*cx_b - cx_c*cx_d) > 0, else 0  (all signed16).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cross_pos
 .if 1
	rep #$20
	.LONGA ON
        lda cx_a
        sta m_a
        lda cx_b
        sta m_b
	sep #$20
	.LONGA OFF
 .else
        lda cx_a
        sta m_a
        lda cx_a+1
        sta m_a+1
        lda cx_b
        sta m_b
        lda cx_b+1
        sta m_b+1
 .endif
        jsr smul32                   ; m_prod = a*b
 .if 1
	rep #$20		;20 bytes
	.LONGA ON
	lda m_prod
	sta cx_p1
	lda m_prod+2
	sta cx_p1+2

        lda cx_c
        sta m_a
        lda cx_d
        sta m_b
	sep #$20
	.LONGA OFF
 .else
        ldx #3			;25 bytes
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
 .endif
        jsr smul32                   ; m_prod = c*d
 .if 1
	rep #$20
	.LONGA ON
	sec
        lda cx_p1
        sbc m_prod
        sta cx_p1
        lda cx_p1+2
        sbc m_prod+2
        sta cx_p1+2
	bmi ?zero
	ora cx_p1
	beq ?zero
	
	sep #$20
	.LONGA OFF
	lda #1
	rts

?zero	sep #$20
	.LONGA OFF
	lda #0
	rts
 .else
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
 .endif
.endp
        .endseg

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
;   2026-08-31: the tables moved to bank $01 (FRAC_EXT, memory_map.inc) -- the
;   win2 pages cost 2.9 ms/frame at x11.2 and bank $01 is full speed. There is
;   no long,y on the 65816, so the mixed ,x/,y read order became TWO X phases:
;   the hi-index reads first, parked in qs_p, then the lo-index reads join the
;   same sums in the same carry order (addition commutes; byte1 is kept for its
;   carry alone either way). Y is no longer touched at all.
 .ifdef ANTONIA2
;   ---- ANTONIA II, the wider use (drac030 2026-09-15: "wykorzystując na szerszą
;   skalę sprzętowe mnożenie ... i dzielenie"). The registers umul16a.asm and
;   udiv24a_v2.asm drive, named once for the macro and procs below. Unsigned,
;   16x16 -> 32 and 16/16 -> 16 r 16 (docs/ANTONIA2.md). Every user sits in a
;   16-bit window it opens anyway; none runs in an interrupt, so nothing can
;   land between a write and its read. FMUL keeps its tables on both builds.
ANT_MUL equ $FFF00C                  ; w: factor, factor   r: the 32-bit product
ANT_DIV equ $FFF008                  ; w: dividend, divisor  r: quotient, remainder
 .endif
.macro FMUL
        lda :4                     ; total sign = sign(var) XOR sign(const):
        ldx m_a+1                  ;   the hi byte is phase 1's index anyway, and
        bpl ?abs                   ;   ldx sets N from it (2026-09-15: the common
        eor #1                     ;   path stores the sign once, 15 cycles for 18)
        sta m_sign
        rep #$20                   ; m_a = |var|, the two's complement in the
        .LONGA ON                  ;   accumulator (m_neg's jsr/rts + six 8-bit
        lda m_a                    ;   instructions were 34 cycles; this is 19)
        eor #$FFFF
        inc
        sta m_a
        .LONGA OFF
        sep #$20
        ldx m_a+1
        bra ?go
?abs    sta m_sign
        ; --- THE TABLE CARRIES THE >>14. build_frac_tables stores 4*|const|*b,
        ;     so this sum IS (|var|*|const|) << 2 and its top two bytes ARE the
        ;     >>14 the transform wants: the eight-shift chain is gone, and with
        ;     it bytes 0 and 1 -- byte 0 is a plain copy that cannot carry, and
        ;     byte 1 is read only for ITS carry. 98 cycles -> 36, on the routine
        ;     the view transform calls four times per vertex. Same number, not a
        ;     cheaper approximation of it: 4*T[b] is exact (< 2^24) and the sum
        ;     still fits 32 bits, so <<2 never loses a bit here either.
?go     clc                        ; X = hi byte index, phase 1
        lda.l FRAC_EXT+:2,x        ; Tmi[hi] -> byte2's other half
        sta qs_p
        lda.l FRAC_EXT+:3,x        ; Thi[hi] -> byte3, parked in Y (tay/tya is
        tay                        ;   2 cycles cheaper than a qs_p+1 roundtrip
        lda.l FRAC_EXT+:1,x        ;   and neither touches the carry)
        ldx m_a                    ; lo byte index, phase 2 (ldx keeps carry)
        adc.l FRAC_EXT+:2,x        ; byte1 = Tlo[hi] + Tmi[lo]  (carry only)
        lda qs_p
        adc.l FRAC_EXT+:3,x        ; byte2 = Tmi[hi] + Thi[lo] + carry
        sta m_res
        tya                        ; byte3 = Thi[hi] + carry
        adc #0
        sta m_res+1
        lda m_sign                 ; apply sign
        beq ?done
        rep #$20                   ; -m_res, the word in A (2026-09-15)
        .LONGA ON
        lda m_res
        eor #$FFFF
        inc
        sta m_res
        .LONGA OFF
        sep #$20
?done
.endm

;--------------------------------------------------------------
; The FRACTAB block ($1920-$1A10): build_frac_tables' body moved to bank $01
; (b1_build_frac, bank01.asm -- it writes the six table pages, and those live
; in bank $01 now, so the builder follows them and its 1,536 stores stop
; paying win2's x11.2 on every rotation frame). What stays here is its thunk
; -- frame_setup TAIL-JUMPS in, so the rts hands control back to
; frame_setup's caller -- and the two fmul procs, which grew 17 bytes each on
; the long,x restructure and no longer fit the byteless $2000 segment.
;--------------------------------------------------------------
bft_resume = *
        org FRACTAB_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc build_frac_tables
        jsl B1CODE_BASE+b1_build_frac
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fmul_sin
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc fmul_cos
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn
        rts
.endp
        .endseg

;--------------------------------------------------------------
; sq2_lt_init -- mv_reset's per-level tail chain, rerouted through here so the
;   SQ2 homes get repainted from the bank $01 masters after EVERY level load
;   (load_things streams the THINGS blob straight over $C900-$CCFE). The ROM
;   is out for the whole init chain, so the restore's stores land in RAM.
;   Skip this and every wall is garbage from frame one (paint.asm pt_dy).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sq2_lt_init                    ; (name kept: mv_reset's tail jmp points
                                     ;   here; the SQ2 restore it was born for
                                     ;   died with the $C900 home, 2026-08-31)
        jsr wp_flight                ; extralight off + lt_seg call retargeted
                                     ;   to normal: wp_init has just parked the
                                     ;   flash state at WS_NULL, so an exit or
                                     ;   death MID-FLASH cannot carry a lit
                                     ;   view into the new level (g_game.c:788
                                     ;   "cancel gun flashes")
        jmp lt_init
.endp
        .endseg
    .if * > PLKICK2_BASE
        ert 'the FRACTAB block ran into PL_KICK2 -- $19CB is the REAL ceiling here, not FRACTAB_END (pl_kick2/trig_light took the old slack)'
    .endif
        org bft_resume

;--------------------------------------------------------------
; transform -- world (zp_rx,zp_ry signed16, relative to player) -> view
;   (zp_X, zp_Z signed16) via the frac-table muls (frame sin/cos).
;     X = (rx*sin - ry*cos) >> 14 ;  Z = (rx*cos + ry*sin) >> 14
;--------------------------------------------------------------
; 16-BIT (2026-08-29): everything here is a 16-bit coordinate, so the halves
; go. The engine is in 65816 NATIVE mode already (underrom.asm), so a block
; costs rep/sep = 6 cycles and no clc/xce; M only, X/Y stay 8-bit because the
; digi IRQ inherits them (sound.asm:316). fmul_sin/fmul_cos are 8-bit code.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc transform
        ; FMUL INLINED x4 (2026-09-14): the four `jsr fmul_sin/fmul_cos` were
        ; 12 cycles of jsr/rts each on ~200 transforms a frame (bench 09-14:
        ; fmul_sin+fmul_cos 83k cyk/f, all from here and cb_corners). Same
        ; macro, same tables, same order -> bit-identical. fmul_sin/fmul_cos
        ; stay as procs for cb_corners (a fixed block, no room to inline).
 .if 1
        lda zp_rx                  ; X = rx*sin - ry*cos (dp/dp: two byte
        sta m_a                    ;   copies, 12 cycles, beat the lone
        lda zp_rx+1                ;   rep/sep window at 14)
        sta m_a+1
 .else
        rep #$20                   ; ---- 16-bit A
        .LONGA ON
        lda zp_rx                  ; X = rx*sin - ry*cos
        sta m_a
        .LONGA OFF
        sep #$20
 .endif
        .local tf1
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn
        .endl
        rep #$20
        .LONGA ON
        lda m_res
        sta zp_X
        lda zp_ry
        sta m_a
        .LONGA OFF
        sep #$20
        .local tf2
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn
        .endl
        rep #$20
        .LONGA ON
        sec
        lda zp_X
        sbc m_res
        sta zp_X
        lda zp_rx                  ; Z = rx*cos + ry*sin
        sta m_a
        .LONGA OFF
        sep #$20
        .local tf3
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn
        .endl
        rep #$20
        .LONGA ON
        lda m_res
        sta zp_Z
        lda zp_ry
        sta m_a
        .LONGA OFF
        sep #$20
        .local tf4
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn
        .endl
 .if 1
        rep #$21		;absorb CLC
        .LONGA ON	
 .else
        rep #$20
        .LONGA ON
        clc
 .endif
        lda zp_Z
        adc m_res
        sta zp_Z
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg

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
 .ifndef ANTONIA2                    ; ANTONIA2: no Rapidus window to move into
udiv_resume = *
        org FASTDIV_BASE
 .endif
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc udiv24
 .ifdef ANTONIA2
        ; ---- ANTONIA II HARDWARE DIVIDER (drac030, 2026-09-10) --------------
        ; $FFF008/$FFF00A take a 16-bit dividend and divisor, $FFF008/$FFF00A
        ; hand back quotient and remainder. A 24-bit dividend needs TWO of
        ; those: top 16 / den, then (rem<<8 | low byte) / den -- and that second
        ; one only fits the 16-bit port while rem < 256, so the routine keeps an
        ; 8-step software tail for the rest -- v2 keeps that tail entirely in
        ; A (16-bit) with the quotient riding in ?q_lo's vacated bits, so the
        ; 32-bit memory shift ladder v1 used is gone. 60..770 cycles vs 230..940.
        ; NOTE v2 dropped v1's `.LONGI OFF`, so its `ldx #$08` is only 8-bit
        ; because MADS defaults that way and spr_draw.asm's `.LONGI ON` pair
        ; (the only one in the tree) is icl'd AFTER math.asm. Order-dependent.
        ; NO `org FASTDIV_BASE` on this path. v1 could not fit (202 B vs the
        ; window's 160); v2 is 154 B and WOULD fit, but the point of that window
        ; is RAPIDUS-fast fetches and an Antonia machine has none, so moving it
        ; there buys nothing. It assembles where it stands.
        icl 'udiv24a_v2.asm'
 .else
 .if 1
	rep #$20
	.LONGA ON
	lda m_prod+1
	cmp m_den
	bcc ?pre16

?tst16	lda m_prod+2                 ; (udiv24_q8's fallback lands here)
	and #$00ff
	cmp m_den
	bcs ?full
 .else
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
 .endif
?pre8
;  .if 1
;	rep #$20
;	.LONGA ON
;	lda m_prod+2		;put m_rem into accumulator
;	and #$00ff
; .else
;	lda m_prod+2                 ; ---- 16 steps: remainder = the top byte ----
;        sta m_rem
;   .if 1
;	stz m_rem+1
;   .else
;        lda #0
;        sta m_rem+1
;   .endif
;  .endif

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
 .if 1
	ldx #16			;16-bit Acc. continued
?l16    asl m_prod                   ; dividend MSB -> carry (16-bit)
        rol                          ; ... into the remainder (16-bit)
	cmp m_den
	bcc ?s16
	sbc m_den
	inc m_prod
?s16	dex
	bne ?l16

	sta m_rem
	lda m_prod
	sta m_quot
 .else
        rep #$20                     ; 16-bit A (native: the frame loop's mode)
	.LONGA ON
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
 .endif
        sep #$20                     ; back to 8-bit A -- and STAY native, see
	.LONGA OFF
        rts                          ;   the block comment above

?pre16
 .if 1
	.LONGA ON
	ldx m_prod                   ; the dividend's low byte -> the word's HIGH
	stz m_prod                   ;   half: [0, byte0]. X is 8-bit, so this is
	stx m_prod+1                 ;   10 cycles where pha/lda/and/xba/sta/pla
	bra ?q8go                    ;   were 23 (2026-09-15); A is untouched
udiv24_q8                            ; ENTRY for calc_u (2026-09-15): 16-bit A =
	cmp m_den                    ;   the dividend's top 16 bits, m_prod bytes
	bcs ?tst16                   ;   0-2 = [0, byte1, byte2] -- the caller KNOWS
	stz m_prod                   ;   its low byte is 0, so the word below the
?q8go	ldx #8                       ;   remainder is simply 0 and A IS the
?l8	asl m_prod                   ;   remainder already
	rol
	cmp m_den
	bcc ?s8
	sbc m_den
	inc m_prod
?s8	dex
	bne ?l8

	sta m_rem
	lda m_prod
	and #$00ff
	sta m_quot
	sep #$20
	.LONGA OFF
 .else
	lda m_prod+1                 ; ---- 8 steps: remainder = the top 16 bits,
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
  .if 1
        stz m_quot+1
  .else
        lda #0
        sta m_quot+1
  .endif
 .endif
        rts

?full
 .if 1
	.LONGA ON
	lda m_prod+1
	sta m_prod+2
	lda m_prod
	and #$00ff
	xba
	sta m_prod

	lda #$0000
	ldx #24
?l24	asl m_prod
	rol m_prod+2
	rol
	cmp m_den
	bcc ?s24
	sbc m_den
	inc m_prod
?s24	dex
	bne ?l24

	sta m_rem
	lda m_prod
	sta m_quot
	sep #$20
	.LONGA OFF
	rts
 .else
   .if 1
        stz m_rem
        stz m_rem+1
   .else
        lda #0                       ; ---- the original 24 steps ----
        sta m_rem
        sta m_rem+1
   .endif
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
 .endif
 .endif
.endp
        .endseg
 .ifndef ANTONIA2
    .if * > FASTDIV_END+1
        ert 'udiv24 outgrew FASTDIV_BASE..FASTDIV_END (memory_map.inc)'
    .endif
        org udiv_resume
 .endif

;--------------------------------------------------------------
; udiv16 -- UNSIGNED (16-bit dividend m_prod[0..1]) / (m_den 16) -> m_quot(2).
;   tips #5b (examples/math): when the dividend fits 16 bits the top 8 of the
;   24 iterations only shift in leading zeros -> skip them. 16 iterations give
;   the IDENTICAL quotient (verified vs udiv24 over the full Z range, 0 diffs).
;   Caller guarantees m_prod[0..1] holds the dividend (m_prod+2 ignored).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc udiv16
 .ifdef ANTONIA2
        ; ANTONIA II: one hardware divide. m_den = 0 never reaches the divider
        ; (what it answers is written down nowhere): it gets the software
        ; loop's own answer, quotient $FFFF and the dividend as remainder. The
        ; loop's side effects stay as well -- m_prod's low word shifted out to 0
        ; and X = 0, with the Z/N that ldx leaves exactly as dex left them.
        rep #$20
        .LONGA ON
        lda m_prod
        sta.l ANT_DIV
        lda m_den
        beq ?zero
        sta.l ANT_DIV+2
        lda.l ANT_DIV
        sta m_quot
        lda.l ANT_DIV+2
        sta m_rem
        bra ?out
?zero   lda m_prod
        sta m_rem
        lda #$FFFF
        sta m_quot
?out    stz m_prod
        sep #$20
        .LONGA OFF
        ldx #0
        rts
 .else
 .if 1
	rep #$20
	.LONGA ON
	lda #$0000	;m_rem in acc.
	stz m_quot

	ldx #16
?l	asl m_prod
	rol
	cmp m_den
	bcc ?skip
	sbc m_den
?skip	rol m_quot
	dex
	bne ?l
	sta m_rem
	sep #$20
	.LONGA OFF
 .else
  .if 1
        stz m_rem
        stz m_rem+1
        stz m_quot
        stz m_quot+1
  .else
        lda #0
        sta m_rem
        sta m_rem+1
        sta m_quot
        sta m_quot+1
  .endif
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
 .endif
        rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; recip_norm -- normalize zp_Z (16-bit, >0) to a 9-bit mantissa + exponent for
;   the reciprocal tables. out: Y = table index (mantissa low byte; m in
;   [256,511] -> hi byte is 1), rc_e = exponent e (signed; Z ~= m << e).
;   Mirrors gui.py _norm(). Z-range-independent (survives ATR level streaming).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc recip_norm
        ; caller preloads rc_m (16-bit value to normalize: Z or span).
 .if 1
	ldx #0		;rc_e
	rep #$20
	.LONGA ON
	lda rc_m
	cmp #2*256                   ; the tests once, then the shift loops carry
	bcc ?dn0                     ;   their own compare: 10 cycles a step, not
?up	lsr                          ;   13 (2026-09-15). m >= 512 -> halve until
	inx                          ;   it is not; a halved 512+ is 256+, so the
	cmp #2*256                   ;   doubling test below is skipped outright
	bcs ?up
	bra ?done
?dn0	cmp #256
	bcs ?done
?dn	asl                          ; m < 256 -> double until it is not
	dex
	cmp #256
	bcc ?dn
?done	stx rc_e
;	sta rc_m	;not necessary?
	sep #$20
	.LONGA OFF
	tax		;copy LSB to X
	rts
 .else
  .if 1
        stz rc_e
  .else
        lda #0
        sta rc_e
  .endif
?up     lda rc_m+1                 ; while m >= 512 (hi >= 2): m >>= 1, e++
        cmp #2
        bcc ?dn
        lsr rc_m+1
        ror rc_m
        inc rc_e
  .if 1
	bra ?up
  .else	
        jmp ?up
  .endif
?dn     lda rc_m+1                 ; while m < 256 (hi == 0): m <<= 1, e--
        bne ?done
        asl rc_m
        rol rc_m+1
        dec rc_e
  .if 1
	bra ?dn
  .else
        jmp ?dn
  .endif
?done	ldx rc_m                   ; index = mantissa low byte (hi == 1)
        rts                        ; X, not Y: the tables live in Rapidus bank
 .endif
.endp                              ;   $01 now and `lda.l tab,y` does not exist
        .endseg
                                   ;   on the 65816 -- only absolute-long,X.
                                   ;   No caller had X live across this call.

;--------------------------------------------------------------
; shr_prod32 -- shift m_prod (32-bit) right by X bits (X in 0..31). Drops whole
;   low bytes first (X>>3), then the residual X&7 bit-shifts. Applies the
;   reciprocal shift (RECIP_SCALE_K / RECIP_SX_K + e).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc shr_prod32
        txa
        lsr
        lsr
        lsr                        ; whole bytes to drop (X>>3)
        beq ?bits
 .if 1
	dec                        ; 1, 2 or 3 whole bytes (X <= 31): three
	beq ?b1                    ;   straight-line word moves instead of the
	dec                        ;   loop's 24 cycles a byte (2026-09-15)
	beq ?b2
	rep #$20                   ; 3: byte 3 -> byte 0, the rest 0
	.LONGA ON
	lda m_prod+3
	and #$00ff
	sta m_prod
	stz m_prod+2
	bra ?bdone
	.LONGA OFF
?b2	rep #$20                   ; 2: the high word down, the top word 0
	.LONGA ON
	lda m_prod+2
	sta m_prod
	stz m_prod+2
	bra ?bdone
	.LONGA OFF
?b1	rep #$20                   ; 1: bytes 1-2 -> 0-1, byte 3 -> 2, 0 -> 3
	.LONGA ON
	lda m_prod+1
	sta m_prod
	lda m_prod+3
	and #$00ff
	sta m_prod+2
?bdone	sep #$20
	.LONGA OFF
 .else
?byte   lda m_prod+1               ; prod >>= 8
        sta m_prod
        lda m_prod+2
        sta m_prod+1
        lda m_prod+3
        sta m_prod+2
  .if 1
        stz m_prod+3
  .else
        lda #0
        sta m_prod+3
  .endif
        dey
        bne ?byte
 .endif
?bits   txa
        and #7
        beq ?done
        tax
 .if 1
	rep #$20                   ; the high word rides in A: lsr A is 2 cycles
	.LONGA ON                  ;   against the 8 of a 16-bit `lsr m_prod+2`
	lda m_prod+2               ;   RMW, on every one of the 1..7 bit steps
?bit	lsr                        ;   (2026-09-14; same bits, same order)
	ror m_prod
	dex
	bne ?bit
	sta m_prod+2
	sep #$20
	.LONGA OFF
 .else
?bit    lsr m_prod+3
        ror m_prod+2
        ror m_prod+1
        ror m_prod
        dex
        bne ?bit
 .endif
?done   rts
.endp
        .endseg

;--------------------------------------------------------------
; shr_acc40 -- shift rs_acc (40-bit, 5 bytes) right by X bits (X in 0..39).
;   Whole low bytes (X>>3) then residual X&7. For the inv_span step shift.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc shr_acc40
        txa
        lsr
        lsr
        lsr                        ; whole bytes to drop
        beq ?bits
        tay
 .if 1
	phx
	ldx #$00
	rep #$20
	.LONGA ON
?byte   lda rs_acc+1               ; rs_acc >>= 8
	sta rs_acc
	lda rs_acc+3
	sta rs_acc+2
	stx rs_acc+4
	dey
	bne ?byte
	sep #$20
	.LONGA OFF
	plx
 .else
?byte   lda rs_acc+1               ; rs_acc >>= 8
        sta rs_acc
        lda rs_acc+2
        sta rs_acc+1
        lda rs_acc+3
        sta rs_acc+2
        lda rs_acc+4
        sta rs_acc+3
  .if 1
        stz rs_acc+4
  .else
        lda #0
        sta rs_acc+4
  .endif
        dey
        bne ?byte
 .endif
?bits   txa
        and #7
        beq ?done
        tax
 .if 1
	lda rs_acc+4
	rep #$20
	.LONGA ON
	and #$00ff
?bit	lsr
	ror rs_acc+2
	ror rs_acc
	dex
	bne ?bit
	sep #$20
	.LONGA OFF
	sta rs_acc+4
 .else
?bit    lsr rs_acc+4
        ror rs_acc+3
        ror rs_acc+2
        ror rs_acc+1
        ror rs_acc
        dex
        bne ?bit
 .endif
?done   rts
.endp
        .endseg

;--------------------------------------------------------------
; step_recip -- track step = (R-L) / span via the inv_span reciprocal (replaces
;   sdiv_prod). IN: m_prod[0..2] = (R-L) signed 24-bit; rs_invm (16-bit 1/span),
;   rs_invsh (shift). OUT: m_quot = step (signed 16-bit). Sign-magnitude 24x16
;   (lo16*invm + (hi8*invm)<<16) >> rs_invsh. Bit-identical to gui.INVSPAN
;   (tools/_verify_invspan.py). Computes inv_span once/seg; this is per plane.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc step_recip
  .if 1
        stz m_sign
  .else
        lda #0
        sta m_sign
  .endif
        lda m_prod+2               ; sign + |R-L| -> rs_mag
        bpl ?pos

        inc m_sign

        sec
        lda #0
        sbc m_prod
        sta rs_mag
 .if 1
	rep #$20
	.LONGA ON
	lda #0
        sbc m_prod+1
        sta rs_mag+1
 .else
	lda #0
        sbc m_prod+1
        sta rs_mag+1
        lda #0
        sbc m_prod+2
        sta rs_mag+2
 .endif
 .if 1
	bra ?mul
 .else
        jmp ?mul
 .endif
?pos    rep #$20                   ; ---- 16-bit A: a 24-bit copy is two OVERLAPPING
        .LONGA ON                  ;   16-bit moves (bytes 0-1 then 1-2), which
        lda m_prod                 ;   never touches byte 3 and costs four
        sta rs_mag                 ;   instructions instead of six
        lda m_prod+1
        sta rs_mag+1
 .if 1
	;nothing
 .else
        .LONGA OFF
        sep #$20
 .endif
?mul
 .if 1
	;nothing
 .else
	rep #$20                   ; lo16 * invm -> rs_acc[0..3], acc[4]=0
        .LONGA ON
 .endif
        lda rs_mag
        sta m_a
        lda rs_invm
        sta m_b
        .LONGA OFF
        sep #$20
        jsr umul16
        rep #$20                   ; ...and a 32-bit copy is two 16-bit moves
        .LONGA ON
        lda m_prod
        sta rs_acc
        lda m_prod+2
        sta rs_acc+2
  .if 1
	lda rs_invm
        sta m_b
  .else
	; nothing
  .endif
        .LONGA OFF
        sep #$20
  .if 1
        stz rs_acc+4
  .else
        lda #0
        sta rs_acc+4
  .endif
        lda rs_mag+2               ; hi8 * invm -> add at byte offset 2
        beq ?nohi                  ; hi8 = 0 (|R-L| < 65536, the usual case):
                                   ;   the product is 0 and the two adds below
                                   ;   leave rs_acc[2..4] as they are, so the
                                   ;   umul16 + adds are skipped (2026-09-14)
        sta m_a
  .if 1
        stz m_a+1
  .else
        lda #0
        sta m_a+1
  .endif
 .if 1
	;nothing, inss below moved up to 16-bit section
 .else
	lda rs_invm
        sta m_b
        lda rs_invm+1
        sta m_b+1
 .endif
        jsr umul16                 ; m_prod[0..2] = hi8*invm (m_prod+3=0)
 .if 1
	rep #$21	;absorb CLC
	.LONGA ON
        lda rs_acc+2
        adc m_prod
        sta rs_acc+2
	sep #$20
	.LONGA OFF
 .else
        clc
        lda rs_acc+2
        adc m_prod
        sta rs_acc+2
        lda rs_acc+3
        adc m_prod+1
        sta rs_acc+3
 .endif
        lda rs_acc+4
        adc m_prod+2
        sta rs_acc+4

?nohi   ldx rs_invsh               ; >> rs_invsh (15..27)
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

 .if 1
	rep #$20
	.LONGA ON
	lda rs_acc+2
	ora rs_acc+3		;overlaps, but doesn't exceed the range
	bne ?sat

	lda rs_acc
	bpl ?ok

?sat	lda #$7fff

?ok	ldy m_sign
	beq ?sav

	eor #$ffff
	inc

?sav	sta m_quot
	sep #$20
	.LONGA OFF
 .else
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
  .if 1
	bra ?sgn
  .else
        jmp ?sgn
  .endif
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
?done
 .endif
	rts
.endp
        .endseg

;--------------------------------------------------------------
; scale_z -- m_quot(2) = (VFOCAL<<SF) / zp_Z via SCALE_TAB reciprocal (no
;   division -- the per-seg bottleneck). zp_Z must be > 0 (post near-clip).
;   scale = SCALE_TAB[m] >> (RECIP_SCALE_K + e). Bit-identical to gui.scale_recip.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
  .if 1
        stz m_prod+2
        stz m_prod+3
  .else
        lda #0
        sta m_prod+2
        sta m_prod+3
  .endif
        clc                        ; shift = RECIP_SCALE_K + e (signed e; = 2..13)
        lda #RECIP_SCALE_K
        adc rc_e
        clc                        ; + vw_sh: the view-size divider, free here
        adc vw_sh                  ;   (rc_e is signed, so that adc CAN carry --
        tax                        ;   hence the second clc)
        jsr shr_prod32
        lda vw_q34                 ; ... and *3/4 for the in-between sizes:
        beq ?q34a                  ;   the full view (0) skips the call
        jsr vw_q34x
?q34a

        lda m_prod
        sta m_quot
        lda m_prod+1
        sta m_quot+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; screenx_signed -- UNCLAMPED signed screen-X for (zp_X signed16, zp_Z>0).
;   m_xs(2,signed) = SCREEN_HALF + (FOCAL*X)/Z. Used as the interpolation
;   anchors (the clamped 0..W-1 column range is derived separately).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc screenx_signed
  .if 1
        stz m_sign
  .else
        lda #0
        sta m_sign
  .endif
 .if 1
	rep #$20
	.LONGA ON
        lda zp_X
	bpl ?xp

	ldy #$01
        sty m_sign                 ; m_a = |X| (16-bit inc, but LSB=0, so no carry to MSB and this is harmless)
	eor #$ffff
	inc

?xp	sta m_a
        lda zp_Z
        sta rc_m
	sep #$20
	.LONGA OFF
 .else
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
 .endif
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
?sat
  .if 1
        stz m_prod
  .else
	lda #0
        sta m_prod
  .endif
        lda #$40
        sta m_prod+1

?off_ok lda vw_q34                 ; view size: *3/4 (AFTER the clamp -- the
        beq ?q34b                  ;   saturated value stays far off-screen);
        jsr vw_q34x                ;   the full view (0) skips the call
?q34b
        lda m_sign
        bne ?neg
 .if 1
	rep #$21	;absorb CLC
	.LONGA ON
        lda #SCREEN_HALF
        adc m_prod
        sta m_xs
	sep #$20
	.LONGA OFF
 .else
        clc                        ; +X: SCREEN_HALF + offset
        lda #SCREEN_HALF
        adc m_prod
        sta m_xs
        lda #0
        adc m_prod+1
        sta m_xs+1
 .endif
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
        .endseg

;--------------------------------------------------------------
; track_calc -- m_prod[0..2] = (HH<<SF) - m_a*m_b   (24-bit signed).
;   m_a = world height (signed16), m_b = scale (signed16). HH<<SF = 50*256
;   = 12800 = $3200. This is the DOOM screen-Y for one height plane (Q8).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

; NOTE 2026-07-25: sdiv_prod, clamp_tb and screenx used to live here (180 B).
; All three were dead -- nothing jsr'd them since inv_span replaced the per-column
; divide (rs_invm), draw_clip took over the clamping and screenx_signed the
; projection. Removed to make room in the full $2000 segment; git history has them.
