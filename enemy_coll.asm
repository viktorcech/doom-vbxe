;--------------------------------------------------------------
; Part of enemy.asm (icl in place): PIT_CheckThing -- en_solid, the radius pages (en_radfill, rad_of), en_thing, coll_mon.
;--------------------------------------------------------------
        org THCOLL_BASE
;--------------------------------------------------------------
; en_solid -- p_map.c PIT_CheckThing, reduced to the half this port can hit:
;   the MF_SOLID block test. Monsters used to walk through the player and
;   through each other because nothing ever ran it.
;   IN : coll_cx/coll_cy = the candidate position, sol_self = the thing that is
;        moving ($FF = the player)
;   OUT: A/Z nonzero = something solid is already there
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_solid
        lda #<TH_RAD                 ; every per-thing page is 256 B aligned, so
        sta zp_ptr                   ;   the low byte is 0 for all of them and
        lda #>TH_RAD                 ;   only zp_ptr+1 moves below
        sta zp_ptr+1                 ;   (zp_ptr+2 = MAP_EXT_BANK, set by init_level)
                                      ; 2026-09-23: sol_self tested ONCE; the player's
        ldy sol_self                 ;   own case: its radius, and it is not its
        cpy #$FF                     ;   own blocker
        bne ?mrad
        lda #MK_PLRAD
        sta sol_rad
        bra ?things
?mrad   lda [zp_ptr],y
        sta sol_rad
        lda #MK_PLRAD
        jsr ?bdist
        rep #$20                     ; sol_ox/oy = the point, two word moves
        .LONGA ON                    ;   (drac030, 2026-09-14)
        lda zp_px
        sta sol_ox
        lda zp_py
        sta sol_oy
        .LONGA OFF
                                      ; 2026-09-22 (65816-windows): past the callee's rep,
        jsr ?hit16               ;   still 16-bit (this sep and that rep were an empty pair)
        .LONGA OFF
                                      ; 2026-09-23: Jcc pseudo-op, ?things falls through
        jne ?yes
        ; --- p_maputl.c P_BlockThingsIterator: the 3x3 cells around the target
        ;     and nothing else.
?things jsr blk_tgt                  ; which cell is the target in?
                                      ; 2026-09-23: the nine cells counted DOWN in X (the
        ldx #8                       ;   answer is only yes/no, so the order is free),
        lda #>BLK_HEAD               ; the cell heads' page, set ONCE: an empty
        sta zp_ptr+1                 ;   cell leaves it, a full one puts it back
?cell   stx sol_n                    ;   sol_cy/blk_oy are rows * 8 (blk_tgt)
        lda sol_cx
        clc
        adc blk_ox,x
        and #7
        sta sol_c
        lda sol_cy
        clc
        adc blk_oy,x
        and #$38
        ora sol_c
        tay
        lda [zp_ptr],y               ; the first thing filed in that cell
        cmp #$FF
        beq ?ncell
?item   sta sol_i
        cmp sol_self                 ; p_map.c: "don't clip against self"
        beq ?nitem
                                      ; 2026-09-26: the per-thing pages read long,x --
        tax                          ;   no zp_ptr+1 switch per page (the cell heads
        lda.l MAP_EXT_BANK*$10000+TH_RAD,x    ;   keep it; it goes back to them at
        beq ?nitem                   ; radius 0 -> not MF_SOLID     the list's end)
        sta sol_or
        lda.l MAP_EXT_BANK*$10000+TH_STATE,x
        bne ?nitem                   ; dying / a corpse -> MF_SOLID is gone
        txy                          ; (?alive takes the thing in Y)
        jsr ?alive
        beq ?nitem                   ; removed from the level
        lda sol_or
        jsr ?bdist
        lda sol_i
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = its record (x @ +0, y @ +2)
	.LONGA ON
	lda (sp_ptr)
	sta sol_ox
	ldy #2
        lda (sp_ptr),y
        sta sol_oy
                                      ; 2026-09-22 (65816-windows): ?hit past its rep,
        jsr ?hit16                   ;   still 16-bit (this sep and that rep were an
        .LONGA OFF                   ;   empty pair)
	jne ?yes
?nitem  ldx sol_i                    ; ...next thing in the same cell
        lda.l MAP_EXT_BANK*$10000+TH_BNEXT,x  ; (long,x, 2026-09-26)
        cmp #$FF
        bne ?item
        lda #>BLK_HEAD               ; the list is over: the heads' page back
        sta zp_ptr+1
?ncell  ldx sol_n
        dex
        jpl ?cell
?no     lda #0
        rts
?yes    lda #1
        rts
;   A = the other radius -> sol_bd = blockdist (16-bit: 128+128 overflows a byte)
?bdist  clc
        adc sol_rad
        sta sol_bd
        lda #0
        adc #0
        sta sol_bd+1
        rts
;   sol_ox/sol_oy vs coll_cx/coll_cy against sol_bd. A nonzero = blocked.
?hit    rep #$20                     ; |ox - cx| < blockdist AND |oy - cy| <
        .LONGA ON                    ;   blockdist, each ONE subtract, the abs
?hit16  sec                          ;   in A and one word compare (2026-09-15:
        lda sol_ox                   ;   no m_a round trip, no ?absa/m_neg)
        sbc coll_cx
        bpl ?ax
        eor #$FFFF
        inc
?ax     cmp sol_bd
        bcs ?miss16
        sec
        lda sol_oy
        sbc coll_cy
        bpl ?ay
        eor #$FFFF
        inc
?ay     cmp sol_bd
        .LONGA OFF
        sep #$20
        bcs ?miss
        lda #1
        rts
?miss16 sep #$20
?miss   lda #0
        rts
                                      ; 2026-09-23: Y = thing index (the caller has it
?alive  tya                          ;   there already)
        lsr
        lsr
        lsr
        tax
        tya
        and #7
        tay
        lda THING_ALIVE,x
        and mv_bit,y
        rts
.endp
        .endseg


; (sol_self .. sol_c moved to memory_map.inc's D0 block, 2026-09-26: here they
;  sat at $6A00, in the $4000-$7FFF write-through window -- every store a chip-
;  bus write, ~131 a gameplay frame from en_solid's cell/item sweep.)
;--------------------------------------------------------------
; en_radfill -- from en_init: TH_RAD[thing] = its PIT_CheckThing radius, for
;   every thing on the level. The rule rad_of applies is checked at BUILD time
;   by tools/pack_things.py _check_radius_rule.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_radfill
	rep #$20
	.LONGA ON
        lda th_things
        sta sp_ptr
        lda #TH_RAD
        sta zp_ptr
	sep #$20
	.LONGA OFF
	stz sol_i
?l      lda sol_i
        cmp THINGS_BASE
        bcs ?done
        jsr rad_of
        ldy sol_i
        ldx #>TH_RAD
        stx zp_ptr+1
        sta [zp_ptr],y
        clc
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inc sol_i
        bne ?l
?done   jmp snd_thnode               ; ...and each thing's sound NODE (enemy_ai.asm):
.endp                                ;   en_init has no room for a jsr of its own
        .endseg

;--------------------------------------------------------------
; rad_of -- sp_ptr = a thing record -> A = its PIT_CheckThing radius. The
;   classification half of en_radfill (see there); it lives out here because
;   the THCOLL block is full to the byte. Clobbers A/X/Y and en_kind/en_k2.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc rad_of
        ldy #7                       ; record +7 = flags
        lda (sp_ptr),y
	lsr
	bcs ?zero
        ldy #6                       ; record +6 = sprite id
        lda (sp_ptr),y
        jsr en_kind_of               ; en_kind = 0 for anything not a monster
        ldy en_kind
        beq ?obs
        lda mk_rad,y
        rts                          ; (no real kind has radius 0)
?obs    ldy #7
        lda (sp_ptr),y
        and #2
        beq ?zero                    ; not an obstacle either
        lda #MK_OBSTR
        rts
?zero   lda #0
        rts
.endp
        .endseg

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
blk_ox  dta $FF,0,1,$FF,0,1,$FF,0,1  ; en_solid's 3x3 neighbourhood (wrapped)
                                      ; 2026-09-23: rows * 8 (sol_cy is row * 8)
blk_oy  dta $F8,$F8,$F8,0,0,0,8,8,8
        .endseg


    .if * > THCOLL_END+1
        ert 'en_solid outgrew THCOLL_BASE..THCOLL_END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; en_thing -- the exploding thing (en_k2) -> sp_ptr = its 8-byte record;
;   en_th2 is the same from an index already in A.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_thing
        lda en_k2
en_th2
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
;	clc
        sta m_prod		;not sure if necessary
        adc th_things
        sta sp_ptr
	sep #$20
	.LONGA OFF
        rts
                                      ; 2026-09-22 (65816-windows): the same, but it
en_th2w rep #$20                     ;   RETURNS 16-bit -- for the callers that went
        .LONGA ON                    ;   on with a rep (their sep/rep pair is gone)
        and #$00ff
        asl
        asl
        asl
        sta m_prod                   ; C = 0: 8*i <= $7F8 shifted no bit out,
        adc th_things                ;   and th_things + $7F8 < $CF00 (the things
        sta sp_ptr                   ;   slot) -- so C = 0 out too; rep #$21
        rts                          ;   callers need no clc
        .LONGA OFF
.endp
        .endseg


;--------------------------------------------------------------
; coll_mon -- the AI's wall probe: collide_blocked at the KIND's radius.
;   ai_step calls this where it called collide_blocked, same three bytes.
;   Parked in this block because collision.asm's own two are full; it is one
;   absolute jsr either way.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc coll_mon
        ldx ai_k                     ; info.c radius -> the power-of-two bucket
        lda mk_rad,x
        ldy #0
        cmp #32                      ; ROUND DOWN, never up: at R32 a demon is
        bcc ?set                     ;   64 wide and DOOM's 64-unit doorways
        ldy #1                       ;   would stop letting it through, which is
        cmp #128                     ;   a fault DOOM has not got. Rounding down
        bcc ?set                     ;   can only ever be MORE permissive than
        ldy #3                       ;   DOOM, the direction this port was
                                     ;   already wrong in -- so nothing that
                                     ;   moves today stops moving.
?set    sty coll_k
        lda coll_rtab,y
        sta coll_rp1
        jmp collide_blocked
.endp
        .endseg
