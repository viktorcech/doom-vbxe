;--------------------------------------------------------------
; math.asm -- fixed-point helpers for the renderer (signed 16-bit unless noted).
;--------------------------------------------------------------
; qsmul -- INLINED 8x8 -> 16 quarter-square.  :3(2) = (:1) * (:2)
;   a*b = QSqr[a+b] - QSqr[|a-b|], QSqr[x]=floor(x^2/4) (qs_tables.inc).
;   tips2 #3: a macro inlined 4x into umul16 -> no jsr/rts, reads the
;--------------------------------------------------------------
.macro qsmul
 .ifdef ANTONIA2
        ; ANTONIA II (drac030: "wykorzystujac na szersza skale sprzetowe ...
        rep #$20
        .LONGA ON
        lda :1
        and #$00FF
        sta.l ANT_MUL
        lda :2
        and #$00FF
        sta.l ANT_MUL+2
        lda.l ANT_MUL
        sta :3
        sep #$20
        .LONGA OFF
 .else
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
	inc
?dok    tay                        ;   that stood here was dead (2 cyc, 83 %)
        sec                        ; :3 -= QSqr[|x-y|]
        lda :3
        sbc QSqrLoBase,y
        sta :3
        lda :3+1
        sbc QSqrHiBase,y
        sta :3+1
 .endif
.endm

;--------------------------------------------------------------
; RECIP_NORM -- normalize the 16-bit A (> 0) to a 9-bit mantissa + exponent
;   for the reciprocal tables: X = the mantissa's low byte (the table index;
;   m in [256,511]), rc_e = e (signed, value ~= m << e). IN 16-bit M, OUT
;   8-bit M. INLINED at its four callers (2026-09-26): 20 instructions, 407
;   calls a frame, and the jsr/rts pair was 12 of each call's ~39 cycles
;   (6502-cycles-layout: inline what is smaller than its call).
;--------------------------------------------------------------
.macro RECIP_NORM
	.LONGA ON
	ldx #0                       ; e = 0, X counts it
	cmp #2*256                   ; the tests once, then the shift loops carry
	bcc ?dn0                     ;   their own compare: 10 cycles a step
?up	lsr                          ; m >= 512 -> halve until it is not; a halved
	inx                          ;   512+ is 256+, so the doubling test below
	cmp #2*256                   ;   is skipped outright
	bcs ?up
	bra ?done
?dn0	cmp #256
	bcs ?done
?dn	asl                          ; m < 256 -> double until it is not
	dex
	cmp #256
	bcc ?dn
?done	stx rc_e
	sep #$20
	.LONGA OFF
	tax                          ; the mantissa's low byte -> X
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
  .if :0 < 4                       ; (a 4th argument: A ALREADY holds :1 -- the
        lda :1                     ;   caller's last store, 2026-09-26)
  .endif
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
; qsmulxa -- qsmulx with the product LEFT IN A:B (A = lo, B = hi, M 8-bit), not
;   stored: umul16's partial products are added straight in, no qs_p round trip.
;   xba keeps C, so the hi subtract takes the lo subtract's borrow as before.
;--------------------------------------------------------------
.macro qsmulxa
        sec                        ; |x-y| into X (0..255 -> Base table)
        lda :1
        sbc :2
        bcs ?dok
        eor #$FF
        inc
?dok    tax
        clc
        lda :1
        adc :2                     ; x+y (9-bit: Y=low8, carry=bit8)
        tay
        bcc ?base
        lda QSqrLoExt,y            ; C = 1: the adc's carry IS the sec
        sbc QSqrLoBase,x
        xba
        lda QSqrHiExt,y
        bra ?have
?base   sec
        lda QSqrLoBase,y
        sbc QSqrLoBase,x
        xba                        ; lo -> B
        lda QSqrHiBase,y
?have   sbc QSqrHiBase,x
        xba                        ; A = lo, B = hi
.endm

;--------------------------------------------------------------
; qsmulxa_ld -- qsmulxa for a caller whose A ALREADY holds :1 (2026-09-26,
;   drac_flow RELOAD: umul16's p11 test `lda m_a+1 / jeq ?end` leaves it
;   there, and qsmulxa's first `lda :1` reloaded it). Otherwise identical.
;--------------------------------------------------------------
.macro qsmulxa_ld
        sec                        ; |x-y| into X, A = :1 on the way in
        sbc :2
        bcs ?dok
        eor #$FF
        inc
?dok    tax
        clc
        lda :1
        adc :2                     ; x+y (9-bit: Y=low8, carry=bit8)
        tay
        bcc ?base
        lda QSqrLoExt,y            ; C = 1: the adc's carry IS the sec
        sbc QSqrLoBase,x
        xba
        lda QSqrHiExt,y
        bra ?have
?base   sec
        lda QSqrLoBase,y
        sbc QSqrLoBase,x
        xba                        ; lo -> B
        lda QSqrHiBase,y
?have   sbc QSqrHiBase,x
        xba                        ; A = lo, B = hi
.endm

;--------------------------------------------------------------
; umul16 -- UNSIGNED 16x16 -> 32.  m_a(2) * m_b(2) -> m_prod(4)
;   tips #2/#3: four 8x8 quarter-square products (inlined qsmul) instead
;   of the 16-iteration shift/add loop.  Bit-identical, much faster.
;     P = p00 + (p01+p10)<<8 + p11<<16
;     p00=aL*bL  p01=aL*bH  p10=aH*bL  p11=aH*bH   (aL=m_a, aH=m_a+1, ...)
;--------------------------------------------------------------
;   UMUL16I is the BODY, a macro since 2026-09-26: the hottest callers
;   (smul32 272/frame, screenx_signed 189, calc_u 136) expand it in place
;   and drop the 12-cycle jsr/rts per call; the rest `jsr umul16`. Clobbers
;   A/X/Y (umul16 no longer saves X -- 2026-09-23, drac_xlive). ANTONIA2
;   keeps the call: the hardware multiplier lives in umul16a.asm.
;--------------------------------------------------------------
.macro UMUL16I
 .ifdef ANTONIA2
        jsr umul16
 .else
  .if :0 = 2                       ; (2026-09-26) UMUL16I 0, 1: A holds m_a's low
   .if :2 = 1                      ;   byte on entry; UMUL16I 0, 2: m_b's. The
        qsmulx m_a, m_b, m_prod, ld ;  product is symmetric (|x-y|, x+y), so the
   .else                           ;   held one goes first and is not reloaded
        qsmulx m_b, m_a, m_prod, ld
   .endif
  .else
        qsmulx m_a, m_b, m_prod    ; p00 = aL*bL, written STRAIGHT into bytes 0,1
  .endif
        stz m_prod+2               ; bytes 2,3 start at zero and the products that
        stz m_prod+3               ;   would land there are ADDED, not stored,
        lda m_a+1                  ;   which is what lets any of them be skipped
        ora m_b+1
  .if :0 <> 1
        jeq ?end                   ; both high bytes 0: p00 is the product
  .else                            ; (the umul16 PROC passes an argument: its
        bne ?nz1                   ;   early exits are a straight rts, not a
        rts                        ;   jmp to the rts at ?end -- drac_flow
?nz1                               ;   JMPRTS, 2026-09-26)
  .endif
        lda m_b+1
	jeq ?p10
                                      ; p01 = aL*bH IN A:B (qsmulxa) -> add at byte 1
        qsmulxa m_a, m_b+1
	rep #$21		;absorb CLC
	.LONGA ON
        adc m_prod+1                 ; byte 2 is still 0 here: p00_hi + p01 <=
        sta m_prod+1                 ;   $FE + $FE01 = $FEFF never carries, so
	sep #$20                     ;   byte 3 needs no carry step (2026-09-26:
	.LONGA OFF                   ;   the bcc/inc was always taken)
        lda m_a+1
  .if :0 <> 1
        jeq ?end                   ; aH = 0 -> p10 = p11 = 0 (another 32 %)
  .else
        bne ?nz2
        rts
?nz2
  .endif
                                      ; p11 = aH*bH IN A:B -> add at byte 2; A IS
        qsmulxa_ld m_a+1, m_b+1      ;   m_a+1 already (2026-09-26, drac_flow RELOAD)
	rep #$21		;absorb CLC
	.LONGA ON
        adc m_prod+2
        sta m_prod+2
	sep #$20
	.LONGA OFF
?p10
                                      ; p10 = aH*bL IN A:B -> add at byte 1
        qsmulxa m_a+1, m_b
	rep #$21		;absorb CLC
	.LONGA ON
        adc m_prod+1
        sta m_prod+1
	sep #$20
	.LONGA OFF
        bcc ?end
        inc m_prod+3
?end
 .endif
.endm

;--------------------------------------------------------------
; UDQ -- after udiv24 (any entry) the software divider returns with the whole
;   16-bit accumulator = the quotient (its tail is `lda m_prod / sta m_quot`),
;   so a caller that goes on 16-bit uses A instead of reloading m_quot
;   (2026-09-26). drac030's ANTONIA2 divider leaves the remainder in A: there
;   the macro is the reload. Use it right after the caller's `rep #$20`.
;
;   ANTONIA2 IS NOT TESTED: Altirra does not emulate the Antonia II
;   multiplier/divider, so the sim and the emulator cannot run that build.
;   Keep the .ifdef ANTONIA2 paths correct by reading, do not try to test them.
;--------------------------------------------------------------
.macro UDQ
 .ifdef ANTONIA2
        lda m_quot
 .endif
.endm

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc umul16
 .ifdef ANTONIA2
        ; ---- ANTONIA II HARDWARE MULTIPLIER (drac030, 2026-09-10) ----------- ...
        icl 'umul16a.asm'
 .else
        UMUL16I rts                  ; (2026-09-26) the body, with rts early exits
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
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc smul_14
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
        phx                          ; umul16 no longer keeps X (2026-09-23)
        UMUL16I 0, 2                 ; (inlined 2026-09-26; A = |m_b| lo already)
        plx

        ; m_prod >>= 14 via (m_prod << 2) >> 16: shift the 32-bit product LEFT
        ; twice, then the result is bytes [2],[3]. 8 shifts instead of the
        ; 14-iteration (56-shift) loop.
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
		                     ;   axis in move_player, bending the walk ...
        ldy m_sign
	bpl ?done

	eor #$ffff
	inc

?done   sta m_res

                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit
	.LONGA OFF
	rts

.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
        ; ANTONIA II: |a| * |b| on the multiplier, the sign put back after -- ...
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
	UMUL16I 0, 2                 ; (inlined 2026-09-26; A = m_b lo already: no reload) (no phx/plx: NO caller keeps X across smul32 --
                                     ;   cross_pos clobbers it itself, track_calc's and
                                     ;   process_seg's callers reload it, spr_proj's
                                     ;   main path clobbers it; checked 2026-09-23)
        lda m_sign
        bpl ?done
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
?done   rts
 .endif
.endp
        .endseg

;--------------------------------------------------------------
; cross_pos -- A = 1 if (cx_a*cx_b - cx_c*cx_d) > 0, else 0  (all signed16).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cross_pos
	rep #$20
	.LONGA ON
cp_w16                               ; (16-bit callers enter here: seg_draw, use_side)
        lda cx_a
        sta m_a
        lda cx_b
        sta m_b
	sep #$20
	.LONGA OFF
        jsr smul32                   ; m_prod = a*b
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
        jsr smul32                   ; m_prod = c*d
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
ANT_CONF1 equ $FFF001                ; CONF1: b0 VBENA, b1 VBADR (underrom.asm sets them)
 .endif
; FMUL_BODY -- the table product of the 16-bit magnitude in :4 (X = its hi byte
;   on entry), sign applied from :5 (0 = keep): 8-bit in, 16-bit A out.
.macro FMUL_BODY
        clc                        ; X = hi byte index, phase 1
        lda.l FRAC_EXT+:2,x        ; Tmi[hi] -> byte2's other half
        sta qs_p
        lda.l FRAC_EXT+:3,x        ; Thi[hi] -> byte3, parked in Y (tay/tya is
        tay                        ;   2 cycles cheaper than a qs_p+1 roundtrip
        lda.l FRAC_EXT+:1,x        ;   and neither touches the carry)
        ldx :4                     ; lo byte index, phase 2 (ldx keeps carry)
        adc.l FRAC_EXT+:2,x        ; byte1 = Tlo[hi] + Tmi[lo]  (carry only)
        lda qs_p
        adc.l FRAC_EXT+:3,x        ; byte2 = Tmi[hi] + Thi[lo] + carry
                                      ; the WORD is built in A, m_res is not written:
        xba                        ;   byte2 parks in B (xba keeps C), byte3 comes
        tya                        ;   in, xba again -> A = byte2, B = byte3. The
        adc #0                     ;   RESULT IS IN A (16-bit) on exit: every user
        xba                        ;   takes it from there (transform, cb_corners)
.endm

; FMUL :1=Tlo :2=Tmi :3=Thi :4=const sign (0/1) :5=the signed16 variable.
;   2026-09-26: the variable is read IN PLACE -- no copy into m_a first, no
;   m_sign: a positive variable indexes the tables straight from :5 and its
;   sign is :4 alone; a negative one gets |var| in m_a and its own body copy,
;   where the sign is :4 inverted. Same tables, same sums: bit-identical.
;   2026-09-27: :4 is a per-FRAME sign, so the `ldx :4 / beq|bne` of both
;   tails is gone -- fmp/fmn are patched by build_frac_tables (fm_patch):
;   $80 `bra ?done` keeps the product, $B0 `bcs ?done` falls into the negate
;   (C = 0 after FMUL_BODY: its sum is <= 2^31, the top byte's adc #0 cannot
;   carry). Assembled: the sign-0 form. :6/:7 name the two slots (global
;   labels: a macro's own labels are local to it), :8 = the negated form.
;   Entered 8-bit, LEAVES 16-bit. Clobbers A/X/Y, qs_p (and m_a if var < 0).
.macro FMUL
        .LONGA OFF
        ldx :5+1                   ; the hi byte is phase 1's index, N = the sign
        bpl ?pos
        rep #$20                   ; m_a = |var| (two's complement in A)
        .LONGA ON
        lda :5
        eor #$FFFF
        inc
        sta m_a
        .LONGA OFF
        sep #$20
        ldx m_a+1
        FMUL_BODY :1, :2, :3, m_a
        rep #$20                   ; var < 0: negate when the const is positive
        .LONGA ON
        .def :%%6 = *              ; fmn (2026-09-27: named by the caller, :6)
  .if :0 > 7
        bra ?done                  ; (:8 given: the NEGATED product, 2026-09-26)
  .else
        bcs ?done
  .endif
        eor #$FFFF
        inc
        bra ?done
        .LONGA OFF
?pos    FMUL_BODY :1, :2, :3, :5
        rep #$20
        .LONGA ON
        .def :%%7 = *              ; fmp (named by the caller, :7)
  .if :0 > 7
        bcs ?done
  .else
        bra ?done
  .endif
        eor #$FFFF
        inc
?done
.endm

;--------------------------------------------------------------
; XFORM rx, ry -- (rx, ry) signed16, player-relative -> zp_X, zp_Z:
;     X = (rx*sin - ry*cos) >> 14 ;  Z = (rx*cos + ry*sin) >> 14
;   A macro since 2026-09-26 so each vertex slot has a body that reads its own
;   cells in place (transform: zp_rx/zp_ry, transform2: zp_rx2/zp_ry2) -- no
;   copies. X - p is formed as (-p) + X: the second FMUL returns -p itself.
;   Enters 8-bit, leaves 16-bit with A = zp_Z.
;--------------------------------------------------------------
.macro XFORM
        .local tf1
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, :1, fmn_%%3a, fmp_%%3a
        .endl
        sta zp_X
        .LONGA OFF
        sep #$20
        .local tf2
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, :2, fmn_%%3b, fmp_%%3b, neg
        .endl
        clc
        adc zp_X
        sta zp_X
        .LONGA OFF                   ; Z = rx*cos + ry*sin
        sep #$20
        .local tf3
        FMUL TCOS_LO, TCOS_MI, TCOS_HI, cos_sgn, :1, fmn_%%3c, fmp_%%3c
        .endl
        sta zp_Z
        .LONGA OFF
        sep #$20
        .local tf4
        FMUL TSIN_LO, TSIN_MI, TSIN_HI, sin_sgn, :2, fmn_%%3d, fmp_%%3d
        .endl
        clc
        adc zp_Z
        sta zp_Z
.endm

;--------------------------------------------------------------
; The FRACTAB block ($1920-$1A10): build_frac_tables' body moved to bank $01
; (b1_build_frac, bank01.asm -- it writes the six table pages, and those live
; in bank $01 now, so the builder follows them and its 1,536 stores stop
; paying win2's x11.2 on every rotation frame).
;--------------------------------------------------------------
bft_resume = *
        org FRACTAB_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc build_frac_tables
        jsl B1CODE_BASE+b1_build_frac
                                      ; --- fm_patch (2026-09-27): the FMUL tails' sign
        ldx #$80                     ;   branches follow sin_sgn/cos_sgn (see FMUL).
        ldy #$B0                     ;   X = the plain tail's opcode (fmp of a var >= 0,
        lda sin_sgn                  ;   fmn of the :6 form), Y = the inverse one.
        beq ?s0                      ;   Sign 1 negates the plain product
        ldx #$B0
        ldy #$80
?s0     txa                          ; unchanged since the last patch -> nothing
        cmp.l B1CODE_BASE+fmp_cb1   ;   (6502-loops-tables-smc)
        beq ?cos
        sta.l B1CODE_BASE+fmp_cb1
        sta.l B1CODE_BASE+fmp_cb2
        sta.l B1CODE_BASE+fmp_cb3
        sta.l B1CODE_BASE+fmp_cb4
        sta.l B1CODE_BASE+fmp_ta
        sta.l B1CODE_BASE+fmp_td
        sta.l B1CODE_BASE+fmp_ua
        sta.l B1CODE_BASE+fmp_ud
        tya
        sta.l B1CODE_BASE+fmn_cb1
        sta.l B1CODE_BASE+fmn_cb2
        sta.l B1CODE_BASE+fmn_cb3
        sta.l B1CODE_BASE+fmn_cb4
        sta.l B1CODE_BASE+fmn_ta
        sta.l B1CODE_BASE+fmn_td
        sta.l B1CODE_BASE+fmn_ua
        sta.l B1CODE_BASE+fmn_ud
?cos    ldx #$80
        ldy #$B0
        lda cos_sgn
        beq ?c0
        ldx #$B0
        ldy #$80
?c0     txa
        cmp.l B1CODE_BASE+fmp_cb5
        beq ?done
        sta.l B1CODE_BASE+fmp_cb5
        sta.l B1CODE_BASE+fmp_cb6
        sta.l B1CODE_BASE+fmp_cb7
        sta.l B1CODE_BASE+fmp_cb8
        sta.l B1CODE_BASE+fmp_tc
        sta.l B1CODE_BASE+fmp_uc
        sta.l B1CODE_BASE+fmn_tb    ; tf2 is the :6 (negated) form
        sta.l B1CODE_BASE+fmn_ub
        tya
        sta.l B1CODE_BASE+fmn_cb5
        sta.l B1CODE_BASE+fmn_cb6
        sta.l B1CODE_BASE+fmn_cb7
        sta.l B1CODE_BASE+fmn_cb8
        sta.l B1CODE_BASE+fmn_tc
        sta.l B1CODE_BASE+fmn_uc
        sta.l B1CODE_BASE+fmp_tb
        sta.l B1CODE_BASE+fmp_ub
?done   rts
.endp
        .endseg

; (fmul_sin / fmul_cos had no callers left -- every FMUL is inlined; removed
;  2026-09-26.)

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
                                     ;   to normal: wp_init has just parked the ...
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
        XFORM zp_rx, zp_ry, t       ; (FMUL inlined x4 since 2026-09-14)
        rts                          ; 16-bit out
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; transform2 -- transform for process_seg's v2: reads zp_rx2/zp_ry2 in place
;   (2026-09-26; v1 lives in zp_rx/zp_ry, so neither needs a copy).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc transform2
        XFORM zp_rx2, zp_ry2, u
        rts                          ; 16-bit out
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; udiv24 -- UNSIGNED (m_num: 24-bit in m_prod[0..2]) / (m_den 16) ->
;   quotient m_quot(2), remainder m_rem(2).  Restoring division.
;   Returns 8-bit M with the 16-bit accumulator = the quotient: callers rely on
;   it through UDQ (2026-09-26) -- keep `lda m_prod` the last load of each tail.
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
        ; hand back quotient and remainder.
ud_w16  sep #$20                     ; (the 16-bit entry: the card's code is 8-bit)
        .LONGA OFF
                                      ; 2026-09-23 FIX (drac030: VBXE palette 0 trashed on
        phb                          ;   Antonia II only). The icl'd code keeps ?q_hi/?q_lo
        phk                          ;   IN its own bytes -- bank $01 here -- and reaches
        plb                          ;   them absolute, i.e. through DBR = 0: every divide
        jsr udiv24_antonia2          ;   wrote 4 B of BANK-0 RAM at whatever address the
        plb                          ;   bank-$01 layout gave them (pld_psel once, it seems).
        rts                          ;   DBR = PBR for the call; m_* are zero page, the card
        icl 'udiv24a_v2.asm'
 .else
                                      ; 2026-09-23: the 16- and 8-step loops had the same
	rep #$20                     ;   body and the same tail: ONE unrolled chain, the
	.LONGA ON                    ;   8-step paths enter at ?u8. No ldx/dex/bne:
ud_w16                               ;   ~5 cycles a quotient bit. Bit-identical.
	lda m_prod+1
	cmp m_den
	bcs ?tst16
?pre16	ldx m_prod                   ; the dividend's low byte -> the word's HIGH
	stz m_prod                   ;   half: [0, byte0]; A = the top 16 bits is
	stx m_prod+1                 ;   the remainder already
	bra ?u8                      ; (C = 0: bcs not taken)
udiv24_q8                            ; ENTRY for calc_u: 16-bit A = the dividend's
	cmp m_den                    ;   top 16 bits, m_prod = [0, byte1, byte2]
	bcs ?tst16
	stz m_prod
	bra ?u8                      ; (C = 0: bcs not taken)
?tst16	lda m_prod+2                 ; (udiv24_q8's fallback lands here)
	and #$00ff
	cmp m_den
	jcs ?full
	.rept 8                      ; quotient bits 15..8: the remainder in A, the
	rol m_prod                   ;   dividend's next bit out of m_prod and the
	rol @                        ;   quotient bit (C of cmp/sbc) in. Entry C = 0
	cmp m_den                    ;   (jcs not taken, bcc taken), so the first
	scc                          ;   bit in leaves again at the 17th rol
	sbc m_den
	.endr
?u8	.rept 8                      ; quotient bits 7..0
	rol m_prod
	rol @
	cmp m_den
	scc
	sbc m_den
	.endr
	rol m_prod                   ; the last quotient bit
	sta m_rem
	lda m_prod
	sta m_quot
	sep #$20
	.LONGA OFF
	rts
	.LONGA ON
?full	lda m_prod+1
	sta m_prod+2
	lda m_prod
	and #$00ff
	xba
	sta m_prod
	lda #$0000
	ldx #24
	clc                          ; C = 0 first so the 25th rol leaves bits 24-31 0
?l24	rol m_prod
	rol m_prod+2
	rol
	cmp m_den
	bcc ?s24
	sbc m_den
?s24	dex
	bne ?l24
	rol m_prod
	rol m_prod+2
	sta m_rem
	lda m_prod
	sta m_quot
	sep #$20
	.LONGA OFF
	rts
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
        ; loop's own answer, quotient $FFFF and the dividend as remainder.
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
        rts
 .endif
.endp
        .endseg

; (recip_norm -- the 9-bit mantissa + exponent normalize -- is the RECIP_NORM
;  macro at the top of this file since 2026-09-26, inlined at its callers.)

;--------------------------------------------------------------
; shr_prod32 -- shift m_prod (32-bit) right by X bits (X in 0..31). Drops whole
;   low bytes first (X>>3), then the residual X&7 bit-shifts. Applies the
;   reciprocal shift (RECIP_SCALE_K / RECIP_SX_K + e).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc shr_prod32
                                      ; 2026-09-22 idiom: A already holds the count --
                                     ;   both callers (scale_z, screenx_signed) do
                                     ;   `tax / jsr shr_prod32`. IN: A = X = count.
        lsr
        lsr
        lsr                        ; whole bytes to drop (X>>3)
        beq ?bits
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
?bits   txa
        and #7
        beq ?done
        tax
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
        stz m_sign
        lda m_prod+2               ; sign + |R-L| -> rs_mag
        bpl ?pos

        inc m_sign

        sec
        lda #0
        sbc m_prod
        sta rs_mag
	rep #$20
	.LONGA ON
	lda #0
        sbc m_prod+1
        sta rs_mag+1
	bra ?mul
?pos    rep #$20                   ; ---- 16-bit A: a 24-bit copy is two OVERLAPPING
        .LONGA ON                  ;   16-bit moves (bytes 0-1 then 1-2), which
        lda m_prod                 ;   never touches byte 3 and costs four
        sta rs_mag                 ;   instructions instead of six
        lda m_prod+1
        sta rs_mag+1
	;nothing
?mul
	;nothing
        lda rs_mag
        sta m_a
        lda rs_invm
        sta m_b
        .LONGA OFF
        sep #$20
        UMUL16I    ; (inlined 2026-09-26)
        rep #$20                   ; ...and a 32-bit copy is two 16-bit moves
        .LONGA ON
        lda m_prod
        sta rs_acc
        lda m_prod+2
        sta rs_acc+2
	lda rs_invm
        sta m_b
        .LONGA OFF
        sep #$20
        stz rs_acc+4
        lda rs_mag+2               ; hi8 * invm -> add at byte offset 2
        beq ?nohi                  ; hi8 = 0 (|R-L| < 65536, the usual case):
                                   ;   the product is 0 and the two adds below ...
        sta m_a
        stz m_a+1
	;nothing, inss below moved up to 16-bit section
        jsr umul16                 ; m_prod[0..2] = hi8*invm (m_prod+3=0)
	rep #$21	;absorb CLC
	.LONGA ON
        lda rs_acc+2
        adc m_prod
        sta rs_acc+2
	sep #$20
	.LONGA OFF
        lda rs_acc+4
        adc m_prod+2
        sta rs_acc+4

                                      ; shr_acc40 INLINED (its only call): no jsr/rts,
?nohi   lda rs_invsh                 ;   and the count is re-read instead of parked
        lsr                          ;   in X (phx/plx). rs_acc >>= rs_invsh (15..27):
        lsr                          ;   whole bytes first ...
        lsr
        beq ?bits
        dec @                        ; rs_acc >>= 8*n, n = 1..3 (invsh 15..27),
        rep #$20                     ;   each n straight-line (2026-09-26: the
        .LONGA ON                    ;   byte loop was 29 cycles a pass, ~2 a
        beq ?by1                     ;   call). n-1 sorted in 8 bits (B holds
        bit #$0001                   ;   junk): Z from the dec (rep keeps it),
        bne ?by2                     ;   then bit 0 alone -- 1 = n 2, 0 = n 3
        lda rs_acc+3                 ; n = 3: b3:b4 -> b0:b1, the rest 0
        sta rs_acc
        stz rs_acc+2
        bra ?byz
?by2    lda rs_acc+2                 ; n = 2: b2:b3 -> b0:b1, b4 -> b2
        sta rs_acc
        lda rs_acc+4
        and #$00FF
        sta rs_acc+2
        bra ?byz
?by1    lda rs_acc+1                 ; n = 1: b1:b2 -> b0:b1, b3:b4 -> b2:b3
        sta rs_acc
        lda rs_acc+3
        sta rs_acc+2
?byz    sep #$20
        .LONGA OFF
        stz rs_acc+4                 ; the top byte shifts in 0 in every case
?bits   lda rs_invsh                 ; ... then the residual k = invsh & 7 bits, in
        and #7                       ;   A: R = V' >> k (V' = b4..b0) saturates at
        tax                          ;   32767 iff b4:b3 != 0 or (b2:b1 >> k) >= $80,
        rep #$20                     ;   else R = (b2:b1 >> k) << 8 | (b1:b0 >> k)
        .LONGA ON                    ;   & $FF. X = k, and 0 on the way out as before
        lda rs_acc+3
        bne ?sat
        lda rs_acc+1                 ; H = b2:b1
        txy
        beq ?k0
?hsh    lsr @
        dey
        bne ?hsh
        cmp #$0080
        bcs ?sat
        xba                          ; (H >> k) << 8: its high byte is 0 here
        sta m_quot                   ; (scratch until ?sav)
        lda rs_acc                   ; L = b1:b0
?lsh    lsr @
        dex
        bne ?lsh
        and #$00FF
        ora m_quot
?ok	ldy m_sign
	beq ?sav

	eor #$ffff
	inc

?sav	sta m_quot
                                     ; 2026-09-22: step_recip returns 16-bit -- its one
	rts                          ; (16-bit out on the .if 1 side)
?k0     cmp #$0080                   ; k = 0: R = b1:b0, saturated iff b2:b1 >= $80
        bcs ?sat
        lda rs_acc
        bra ?ok
?sat	lda #$7fff
        bra ?ok
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; scale_z -- m_quot(2) = (VFOCAL<<SF) / zp_Z via SCALE_TAB reciprocal (no
;   division -- the per-seg bottleneck). zp_Z must be > 0 (post near-clip).
;   scale = SCALE_TAB[m] >> (RECIP_SCALE_K + e). Bit-identical to gui.scale_recip.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc scale_z
                                      ; Z as one word straight into recip_norm's 16-bit
        rep #$20                     ;   entry: no byte copies into rc_m, no reload
        .LONGA ON
        lda zp_Z
sz_a16                               ; 16-bit ENTRY with A = Z (process_seg, sprites)
        RECIP_NORM                   ; (inlined 2026-09-26) X = mantissa idx, rc_e = e (returns 8-bit)
        .LONGA OFF

                                      ; 2026-09-23: the table value is 16-bit, so the
        lda rc_e                     ;   >> is done on the WORD in A (built in A:B), not
        clc                          ;   by shr_prod32's 32-bit memory shift. Shift =
sz_k    adc #RECIP_SCALE_K           ;   e + (K + vw_sh), the sum baked in by vw_apply
        cmp #8                       ;   (byte adds mod 256: rc_e is signed)
        bcs ?ge8
        tay                          ; Y = shift 0..7
        lda.l RCX_SCALE_HI,x         ; bank $01 (memory_map.inc RECIP_EXT)
        xba
        lda.l RCX_SCALE_LO,x
        rep #$20
        .LONGA ON
?sh     cpy #0
        beq ?st
?b      lsr @
        dey
        bne ?b
?st     sta m_prod                   ; (m_prod as shr_prod32 left it: the word,
        stz m_prod+2                 ;   bytes 2-3 zero -- one 16-bit stz)
        ldy vw_q34                   ; *3/4 for the in-between view sizes
        bne ?q34
        sta m_quot                   ; returns 16-bit with A = m_quot
        rts
?q34    .LONGA OFF
        sep #$20
        jsr vw_q34x
        rep #$20
        .LONGA ON
        lda m_prod
        sta m_quot
        rts
        .LONGA OFF
?ge8    sbc #8                       ; C = 1 (bcs): Y = shift - 8, the word >> 8 is
        tay                          ;   the table's high byte (>= 16: it shifts to 0)
        lda.l RCX_SCALE_HI,x
        rep #$20
        .LONGA ON
        and #$00FF
        bra ?sh
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; screenx_signed -- UNCLAMPED signed screen-X for (zp_X signed16, zp_Z>0).
;   m_xs(2,signed) = SCREEN_HALF + (FOCAL*X)/Z. Used as the interpolation
;   anchors (the clamped 0..W-1 column range is derived separately).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc screenx_signed
                                      ; 2026-09-23: 16-bit entry sx_w16, the sign via Y
	rep #$20                     ;   (no 8-bit stz before the window)
	.LONGA ON
sx_w16
        ldy #0
        lda zp_X
	bpl ?xp
        iny                          ; m_sign = 1: X was negative
	eor #$ffff
	inc
?xp     sty m_sign
	sta m_a
        lda zp_Z
        RECIP_NORM                   ; (inlined 2026-09-26) (returns 8-bit; X = mantissa idx, rc_e = e)
	.LONGA OFF

        lda.l RCX_SX_LO,x          ; m_b = SX_TAB[m] (FOCAL baked in), bank $01
        sta m_b
        lda.l RCX_SX_HI,x
        sta m_b+1
        UMUL16I                    ; (inlined 2026-09-26) m_prod(4) = |X| * SX_TAB[m]

                                      ; 2026-09-23: >> c and the clamp in 16-bit A, no
        lda rc_e                     ;   shr_prod32. c = 17 + e + vw_sh = 9..26 (e is
        clc                          ;   -8..7: recip_norm of a 16-bit Z), so c >= 9;
sx_k    adc #RECIP_SX_K              ;   K + vw_sh is baked in by vw_apply
        cmp #16
        bcc ?w1                      ;   it falls through, c < 16 is out of line
        sbc #16                      ; C = 1: Y = c - 16 = 0..10 bits of the high word
        beq ?w2z                     ;   (c = 16, no shift: out of line)
        tay
        rep #$20
        .LONGA ON
        lda m_prod+2
?l2     lsr @
        dey
        bne ?l2
?w2d    cmp #$4000                   ; the clamp is the rare side: out of line
        bcs ?sat16
?off16                               ; view size: *3/4 (after the clamp); v - v>>2.
                                      ; 2026-09-27 (65816-modes-banks: patch the
sx_q34  sta m_prod                   ;   INSTRUCTION in): vw_apply writes this slot --
                                      ;   `sta m_prod` itself in the 3/4 view, `bra
                                      ;   sx_q0` otherwise; the ldy vw_q34 / beq test
                                      ;   is gone from both modes.
                                      ; 2026-09-26: every way into ?off16 has C = 0
                                      ;   (a not-taken bcs, ?sat16 clears it), and
        lsr @                        ;   v - v>>2 cannot borrow: C = 1 below. Each
        lsr @                        ;   side gets its own tail with the carry
        eor #$FFFF                   ;   folded into the immediate -- same sums
        sec
        adc m_prod
        ldy m_sign
        bne ?n16c
        adc #SCREEN_HALF-1           ; C = 1
        sta m_xs
        rts
?n16c   eor #$FFFF                   ; C = 1: SCREEN_HALF + ~v + 1
        adc #SCREEN_HALF
        sta m_xs
        rts
sx_q0   ldy m_sign                   ; returns 16-BIT with A = m_xs; C = 0 here
        bne ?n16
        adc #SCREEN_HALF
        sta m_xs
        rts
?n16    eor #$FFFF                   ; C = 0: SCREEN_HALF + ~v + 1
        adc #SCREEN_HALF+1
        sta m_xs
        rts
        .LONGA OFF
?w1     sbc #7                       ; C = 0 (the bcc): Y = c - 8 = 1..7 bits
        tay
        rep #$20
        .LONGA ON
        lda m_prod+2                 ; A = bytes 3:2, the word at +1 takes the bits
?l1     lsr @                        ;   (its byte 2 goes stale: rewritten below)
        ror m_prod+1
        dey
        bne ?l1
        cmp #$0040                   ; bits 16+ of the result, or it >= $4000?
        bcs ?sat16
        sta m_prod+2
        lda m_prod+1                 ; the result = bytes 2:1
        bra ?off16
?sat16  lda #$4000
        clc                          ; (2026-09-26) ?off16 relies on C = 0
        bra ?off16
        .LONGA OFF
?w2z    rep #$20
        .LONGA ON
        lda m_prod+2
        bra ?w2d
        .LONGA OFF
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
        rep #$20                   ; m_prod[0..2] = HHFP - m_prod (horizon - world*
        .LONGA ON                  ;   scale) as two words. Returns 16-BIT (every
        sec                        ;   caller goes on 16-bit); byte 3 becomes junk,
        lda #HHFP                  ;   and no caller reads it
        sbc m_prod
        sta m_prod
        lda #0
        sbc m_prod+2
        sta m_prod+2
        rts
        .LONGA OFF
.endp
        .endseg

; NOTE 2026-07-25: sdiv_prod, clamp_tb and screenx used to live here (180 B).
; All three were dead -- nothing jsr'd them since inv_span replaced the per-column
; divide (rs_invm), draw_clip took over the clamping and screenx_signed the
; projection. Removed to make room in the full $2000 segment; git history has them.
