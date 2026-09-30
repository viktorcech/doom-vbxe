;--------------------------------------------------------------
; proj.asm -- the player's visible missiles, MT_ROCKET and MT_PLASMA: flight,
;   impact, and the damage spent at the hit.
;--------------------------------------------------------------

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_plasma2
        pha                          ; the roll, while pj_pick eats A
        jsr pj_pick                  ; which bolt is this shot?
        beq ?busy
        pla                          ; A FREE SLOT: it gets its own, the way
?new    jsr pj_aim                   ;   P_SpawnPlayerMissile makes one mobj per
        jsr pj_pspawn                ;   A_FirePlasma -- victim and roll ride it
?sv     ldx pj_cur                   ;   and are spent in pj_hit when it lands
        jmp pj_save
?busy   inc pj_hold                  ; EVERY SLOT IS BUSY (the trigger refires
        pla                          ;   every 3 tics against a ~7 VBLANK frame,
        jsr pj_aim3                  ;   (the same three rays pj_aim casts)
        dec pj_hold                  ;   who this shot would hit, hurting nobody
        lda #$FF
        ldx en_best
        bmi ?cmp                     ; nothing under the crosshair -> a wall
        lda vs_th,x
?cmp    cmp pj_vic
        bne ?land                    ; somebody else: that bolt has to go now
        clc                          ; the SAME victim: this roll rides with the
        lda pj_dmg                   ;   bolt instead of landing early, which is
        adc en_dmg                   ;   what used to kill before the plasma
        bcs ?land                    ;   arrived -- the damage per second is the
        sta pj_dmg                   ;   weapon's either way
        bra ?sv
?land   lda en_dmg                   ; the aim moved, or the sum ran past 255:
        pha                          ;   land that bolt on its own victim (pj_hit
        jsr pj_hit                   ;   eats en_dmg through en_bhit, hence the
        dec pj_on                    ;   stack) and give this shot the slot
        pla
        bra ?new
.endp
        .endseg

;--------------------------------------------------------------
; pj_rspawn / pj_pspawn -- arm the shared missile for this shot's look.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_rspawn
        lda #SFX_BAREXP              ; MT_ROCKET deathsound (info.c:1981) -- and
        sta pj_bsnd                  ;   the flag that says there IS an A_Explode
        lda pj_rid
        bmi ?now                     ; $FF: the level packed no MISL -> land it
        sta pj_fid                   ;   at once rather than lose the shot
        lda pj_rxid
        sta pj_xid
        lda #11                      ; S_EXPLODE1..3: 8/6/4 tics -> 11/9/6 VB
        sta pj_bt0
        lda #9
        sta pj_bt1
        lda #6
        sta pj_bt2
        bra pj_go
?now    rep #$20                     ; pj_go never ran, so hand pj_hit the impact
        .LONGA ON                    ;   point itself (pj_tx/pj_ty is where it
        lda en_bx                    ;   looks for the blast)
        sta pj_tx
        lda en_by
        sta pj_ty
        sep #$20
        .LONGA OFF
        jmp pj_hit
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_pspawn
        lda #SFX_FIRXPL              ; MT_PLASMA deathsound (info.c:2007), and
        sta pj_bsnd                  ;   the flag that keeps pj_hit's A_Explode
                                     ;   half off a bolt (info.c gives MT_PLASMA
                                     ;   none).
        lda pj_pid
        bpl ?arm
        jmp pj_hit                   ; $FF: no PLSS packed, so there is no flight
                                     ;   to carry the roll -- spend it at once
                                     ;   rather than lose the shot entirely
?arm    sta pj_fid
        lda pj_pxid
        sta pj_xid
        lda #6                       ; S_PLASEXP: 4 tics -> 6 VB, all three
        sta pj_bt0
        sta pj_bt1
        sta pj_bt2
        ert *<>pj_go                ;   next byte of this segment -- fall through
.endp
        .endseg

;--------------------------------------------------------------
; pj_go (part A) -- position, target, deltas, the ball's shrink loop.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_go
        rep #$20                     ; ---- 16-bit A: launch point, target and the
        .LONGA ON                    ;   aim vector are word moves; the target is
        lda zp_px                    ;   still in A when its delta is taken
        sta pj_x                     ; the missile leaves the player...
        lda zp_py
        sta pj_y
        sec                          ; ...at z + 32 over the feet: the eye is
        lda zp_pz                    ;   feet + 41, so eye - 9 (p_mobj.c:971)
        sbc #9
        sta pj_z
        lda en_bx                    ; the flight target: what the shot hit...
        sta pj_tx
        sec                          ; ...and the aim vector, target - player,
        sbc pj_x                     ;   with the target still in A
        sta pj_dx
        lda en_by
        sta pj_ty
        sec
        sbc pj_y
        sta pj_dy
        ldx #0                       ; the shrink count, in X: an `inc pj_sh` in
                                     ;   16-bit mode would write its neighbour too
?red    clc                          ; shrink until BOTH fit [-127,127]: d + 127
        lda pj_dx                    ;   must land in [0,254] -- ONE unsigned
        adc #127                     ;   16-bit compare each (the byte version
        cmp #255                     ;   tested "high byte 0 and low byte < $FF",
        bcs ?shr                     ;   which is the same set)
        lda pj_dy                    ; (C=0 here: the bcs was not taken)
        adc #127
        cmp #255
        bcs ?shr
        sep #$20
        .LONGA OFF
        stx pj_sh                    ; the count IS the distance's magnitude:
        stz pj_xf                    ;   pj_go2 paces the flight off it (pj_ctab)
        stz pj_yf
        jmp pj_go2                   ; part B: k7 aim + arm (its own island)
?shr    inx
        .LONGA ON                    ; (the mode never changed on this path)
        lda pj_dx                    ; arithmetic >> 1: cmp #$8000 puts the sign
        cmp #$8000                   ;   bit in C, ror brings it back in on top
        ror @
        sta pj_dx
        lda pj_dy
        cmp #$8000
        ror @
        sta pj_dy
        bra ?red
.endp
        .endseg

; m_prod = A * pj_f (umul16, high half 0)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_mul
        sta m_a
        stz m_a+1
        stz m_b+1
        lda pj_f
        sta m_b
        phx                          ; the tail call kept X: umul16 no longer does
        jsr umul16
        plx
        rts
.endp
        .endseg

; m_prod = -m_prod (16-bit)

; IN: A = |d| (byte), Y = the delta's high byte (its sign).
; OUT: m_prod = that axis' step, x2 k7 (Q8), re-signed.
;   The sign is STASHED before the multiply: pj_mul tail-jumps into umul16,
;   whose qsmul macro does `tay` four times, so Y is long gone by the time the
;   product is ready. Reading it back with `tya` tested whatever the quarter-
;   square tables left behind, so a NEGATIVE leg kept its positive step while
;   pj_sxe/pj_sye still said "negative" -- the two together make a 24-bit step
;   of $FF0DC0, i.e. -242 units per VBLANK instead of -13.75. The missile then
;   left the map on its first frame, was in no leaf the BSP walk visits, and
;   was never drawn again. Which shots broke depended on the FIRING DIRECTION
;   (only negative legs are affected) and on the operands -- exactly the "some
;   times you see the rocket, sometimes not, and I cannot tell you when".
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_leg
                                      ; 2026-09-22 (65816-style): Y rides the stack
        phy
        jsr pj_mul
        rep #$20                     ; ---- 16-bit A: the x2 and the re-sign in the
        .LONGA ON                    ;   accumulator, one store at the end (the
        lda m_prod                   ;   asl/rol pair in memory and pj_neg's
        asl @                        ;   two-byte subtract are gone)
                                      ; the sign, back (umul16 ate Y); ply sets N as
        ply                          ;   ldy did and leaves C alone
        bpl ?p
        eor #$FFFF                   ; -m_prod
        inc @
?p      sta m_prod
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

; A = |A| (the deltas fit a byte once pj_go's shrink loop is done)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_abs
        bpl ?pos
        eor #$FF
        inc @                        ; (C is dead in every caller: sta / cmp / ldy)
?pos    rts
.endp
        .endseg

; |m_a(16)| with A = the high byte on entry; Z=1 iff the result is < 256.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (callers are bank-$01 code)
.proc pj_a16
        sta m_a+1
        bpl ?p
        jsr m_neg
?p      lda m_a+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pj_thit -- p_map.c PIT_CheckThing, the MF_MISSILE half, for the rocket where
;   it is RIGHT NOW. C=1 (and pj_vic = the thing) if it is inside something
;   shootable; C=0 to keep flying.
;--------------------------------------------------------------
PJ_ROCKR equ 11                      ; info.c MT_ROCKET radius
; 2026-08-10: the sweep reads TH_HPL/HPH/STATE/RAD straight out of bank $01
;   with lda.l tab,x -- the tables are page arrays indexed by THING, so the
;   old form re-aimed [zp_ptr] at every page of every thing (four pointer
;   stores and 7-cycle reads where one 5-cycle read does). X is the cursor
;   now (the 65816 has long,X and no long,Y); the caller's sub-step count
;   parks in pj_ti and comes back on BOTH exits. en_th2 still builds the
;   record pointer, but only for the few candidates the health byte lets
;   through -- the sweep runs once per SUB-STEP, up to five a frame per
;   bolt, and the old form was most of a flying frame's budget.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_thit
        stx pj_ti                    ; the caller's counter; X = the cursor
        ldx #$FF
?nx     inx
?lp     cpx THINGS_BASE              ; the level's thing count
        bcc ?try
        ldx pj_ti                    ; swept them all: nothing in the way
        clc
        rts
?try    lda.l EXT_BASE+TH_HPL,x       ; shootable at all? (a decoration has no
        bne ?alv                     ;   health, and PIT_CheckThing lets a
        lda.l EXT_BASE+TH_HPH,x       ;   non-shootable thing through)
        beq ?nx
?alv    lda.l EXT_BASE+TH_STATE,x     ; already dying -> its chain owns it
        bne ?nx
        lda.l EXT_BASE+TH_RAD,x       ; blockdist = its radius + the rocket's
        clc
        adc #PJ_ROCKR
        sta pj_bd                    ; (pj_bd+1 is a permanent 0: the 16-bit
        bcs ?nx                      ;  compares below read the word)
        txa
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = its record: x at +0, y at +2
        .LONGA ON                    ;   |dy| < blockdist, each one subtract, one
        sec                          ;   negate in A and one compare (the byte
        lda pj_x                     ;   version went through pj_a16 / m_neg and
        sbc (sp_ptr)                 ;   a high-byte test: same set, |d| >= 256
        bpl ?ax                      ;   fails the compare here just as it
        eor #$FFFF                   ;   failed the high-byte test there)
        inc @
?ax     cmp pj_bd
        bcs ?nx16
        ldy #2
        sec
        lda pj_y
        sbc (sp_ptr),y
        bpl ?ay
        eor #$FFFF
        inc @
?ay     cmp pj_bd
        bcs ?nx16
        lda pj_x                     ; HIT: the burst happens HERE, not at the
        sta pj_tx                    ;   point the crosshair picked
        lda pj_y
        sta pj_ty
        sep #$20
        .LONGA OFF
        stx pj_vic                   ; ...and this is who the blast damages first
        ldx pj_ti                    ; the sub-step counter back
        sec
        rts
?nx16   sep #$20
        .LONGA OFF
        bra ?nx
.endp
        .endseg
; pj_orup -- pj_any = OR of the eight pj_ons: pj_mirr's tail, so it is fresh
;   the moment any slot's mirror changes, and spr_chasec's one-load "is
;   ANYTHING flying" gate. The ldx pj_cur puts back the X every pj_save
;   caller holds (pj_save promises X preserved, and X is always pj_cur there).
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_orup
        ldx #PJ_NSLOT-1
        lda #0
?o      ora pj_ons,x
        dex
        bpl ?o
        sta pj_any
        ldx pj_cur
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pj_go2 -- k7 row, the x2 speed scale, sign, arm the flight.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_go2
                                      ; 2026-09-22 idiom: pj_abs inlined (-12 each; C is
        lda pj_dx                    ;   dead at every use: sta / cmp / ldy)
        bpl ?ax1
        eor #$FF
        inc @
?ax1    sta pj_ax
        lda pj_dy
        bpl ?ax2
        eor #$FF
        inc @
?ax2    cmp pj_ax                    ; max(|dx|,|dy|) -> the k7 row
        bcs ?ymax
        lda pj_ax
?ymax   cmp #8
        bcs ?mok                     ; clamp: k7-8,x never reads below the table
        lda #8
?mok    tax
        lda k7-8,x
        sta pj_f
        ldy pj_sh                    ; pace the FLIGHT, not just the speed: the
        lda pj_ctab,y                ;   shrink count is the distance's magnitude
        jsr pj_capdbl                ;   (the loop stops with the larger leg in
                                     ;   [64,127], so dist ~ 96 << sh), and
                                     ;   pj_ctab turns it into "sub-steps per
                                     ;   drawn frame".
        lda pj_vic                   ; a WALL shot flies along the facing, as its
        cmp #$FF                     ;   aim ray did (sh_dist): out of line
        beq ?wall
        lda pj_ax                    ; step X = |dx| * k7 * 2 (Q8), re-signed:
        ldy pj_dx+1                  ;   k7 normalises the larger leg to 7 u/VB
        jsr pj_leg                   ;   and the doubling makes it 14 -- the
        lda m_prod                   ;   rocket's exact PAL rate (20/tic * 0.7)
        sta pj_sx
        lda m_prod+1
        sta pj_sx+1
        ldx #0
        lda pj_dx+1
        bpl ?px
        dex
?px     stx pj_sxe
                                      ; 2026-09-22 idiom: pj_abs inlined (-12)
        lda pj_dy                    ; step Y likewise
        bpl ?ax3
        eor #$FF
        inc @
?ax3    ldy pj_dy+1
        jsr pj_leg
        lda m_prod
        sta pj_sy
        lda m_prod+1
        sta pj_sy+1
        ldx #0
        lda pj_dy+1
        bpl ?py
        dex
?py     stx pj_sye
?arm    lda #<PJ_GUARD               ; the guard; arrival ends it long before
        sta pj_ttl
        lda #>PJ_GUARD
        sta pj_ttl+1
        lda pj_fid
        sta pj_frm                   ; the CONTEXT's frame, not pj_rec+6: that
                                     ;  record is shared scratch and pj_draw1 ...
        lda #1
        sta pj_on
        jmp pj_zaim                  ; the z leg (its own island), and it ends
                                     ;   `jmp pj_leaf` -- seeding pj_ss + the
                                     ;   record NOW, because the draw hook runs
                                     ;   before the first pj_frame.
?wall   rep #$20                     ; PJ_SPD along the facing, per axis: Q8 and
        .LONGA ON                    ;   the sign's byte above it
        lda #PJ_SPD
        sta m_a
        lda zp_cos
        sta m_b
        .LONGA OFF
        sep #$20
        jsr smul_14                  ; (keeps X; returns 16-bit)
        .LONGA ON
        sta pj_sx
        ldx #0
        asl @                        ; C = the sign
        bcc ?wx
        dex
?wx     stx pj_sxe
        lda #PJ_SPD
        sta m_a
        lda zp_sin
        sta m_b
        .LONGA OFF
        sep #$20
        jsr smul_14
        .LONGA ON
        sta pj_sy
        ldx #0
        asl @
        bcc ?wy
        dex
?wy     stx pj_sye
        .LONGA OFF
        sep #$20
        bra ?arm
.endp
        .endseg
PJ_SPD  equ 3594                     ; info.c MT_ROCKET speed 20 a tic = 14.04
                                     ;   units a PAL VBLANK, Q8
PJ_GUARD equ 600                     ; sub-steps: past the aim ray's reach
    .if PJ_GUARD*14 < SH_NROCK*SH_STEP
        ert 'PJ_GUARD: the flight guard must outlast a shot at the end of the aim ray'
    .endif

;--------------------------------------------------------------
; pj_frameb -- the frame loop's mv_frameb call, retargeted once more
;   (movers, the imp's ball, then this missile) -- and the once-per-level
;   id fetch, both out of the packed flight island.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_frameb
        jsr mv_frameb
        jmp pj_frameN
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_relvl
        sta pj_lvl                   ; new level: forget every bolt (pj_clr at
        lda #0                       ;   the tail), learn the sprite ids, park
                                     ;   sentinel 254 as "not a thing" (255 is
                                     ;   the ball's)
        sta.l EXT_BASE+TH_HPL+TH_NOTHING
        sta.l EXT_BASE+TH_HPL+$100+TH_NOTHING
        sta.l EXT_BASE+TH_STATE+TH_NOTHING
        sta.l EXT_BASE+TH_KIND+TH_NOTHING    ; en_kfill stops at the thing count, so
                                     ;   254 is uninitialised SRAM on the metal ...
                                      ; 2026-09-22 idiom: two word copies -> one 16-bit
        rep #$20                     ;   window (bank $01 code = native; pj_rxid is
        .LONGA ON                    ;   pj_rid+1, pj_pxid is pj_pid+1)
        lda THINGS_BASE+20           ; pack_things header: MISL A id, MISL B
        sta pj_rid
        lda THINGS_BASE+22           ; ...PLSS A, PLSE A
        sta pj_pid
        sep #$20
        .LONGA OFF
        jmp pj_clr                   ;   A) are NOT copied: these four are read
                                     ;   in the missile's per-frame path and want ...
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; pj_capdbl -- pj_go2's tail on pj_cap (A = pj_ctab's entry for this shot's
;   distance): the PLASMA gets twice the sub-steps per drawn frame. info.c
;   gives MT_PLASMA speed 25 against MT_ROCKET's 20 and it refires every 3 tics
;   where the rocket takes twenty-odd, so pacing the two the same was wrong
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_capdbl
        ldx pj_bsnd                  ; the deathsound is what says "rocket"
        cpx #SFX_BAREXP              ;   (MT_PLASMA has no A_Explode -- pj_hit)
        beq ?put
        asl
?put    sta pj_cap
        rts
.endp
        .endseg

PJ_MAXSUB equ 24                     ; sub-steps (VBLANKs) per drawn frame, max.
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_frame                       ; ONE bolt, the one pj_load just swapped in
        lda pj_on                    ;   (the level check moved to pj_frameN --
        bne ?run                     ;   pj_relvl has to run with no bolt up too)
?out    rts
?run    cmp #2
        bcc ?fly0                    ; 2..4 = the burst frames (their own clock)
        jmp pj_btick
?fly0   ldx dt_vbl                    ; one sub-step per VBLANK, like the ball...
        cpx pj_cap                   ; ...but never more than pj_cap of them in
        bcc ?step                    ;   one DRAWN frame (see the .else side's
        ldx pj_cap                   ;   note on pj_cap and PJ_MAXSUB)
?step   clc                          ; x += sx (24-bit: xf, x, x+1 are not in
        lda pj_xf                    ;   little-endian order, so this stays
        adc pj_sx                    ;   three byte adds -- a 16-bit form would
        sta pj_xf                    ;   need sep/rep around the third byte and
        lda pj_x                     ;   costs the same)
        adc pj_sx+1
        sta pj_x
        lda pj_x+1
        adc pj_sxe
        sta pj_x+1
        clc
        lda pj_yf
        adc pj_sy
        sta pj_yf
        lda pj_y
        adc pj_sy+1
        sta pj_y
        lda pj_y+1
        adc pj_sye
        sta pj_y+1
        jsr pj_zstep                 ; ...and the z leg (p_mobj.c gives the
                                     ;   missile a momz, so it CLIMBS to a
                                     ;   monster on a ledge)
        rep #$20                     ; ---- 16-bit A. The guard (a word), then:
        .LONGA ON                    ;   arrived? |x - tx| < 16 AND |y - ty| < 16
        dec pj_ttl                   ;   (a step is 14 at most: none jumps it)
        beq ?g16
        sec
        lda pj_x
        sbc pj_tx
        bpl ?a1
        eor #$FFFF
        inc @
?a1     cmp #16
        bcs ?m16                     ; C=1: not there yet (falls through below
        sec                          ;   with C=1 as well)
        lda pj_y
        sbc pj_ty
        bpl ?a2
        eor #$FFFF
        inc @
?a2     cmp #16
?m16    sep #$20                     ; (sep keeps C: it is the verdict)
        .LONGA OFF
        bcc ?burst
?miss   jsr pj_thit                  ; p_map.c PIT_CheckThing: did this sub-step
        bcs ?burst                   ;   put the rocket INSIDE something? then it
                                     ;   bursts HERE (pj_thit moved pj_tx/pj_ty)
        dex
        bne ?step 
        ;bra ?step
?done   bra pj_leaf                  ; track the leaf + refresh the record
        .LONGA ON
?g16    sep #$20                     ; the guard ran out mid-air: burst where it
        .LONGA OFF                   ;   is, so the shot still LANDS
?burst  jsr pj_hit                   ; P_ExplodeMissile: NOW it hurts
        ert *<>pj_burst             ;   next byte of this segment -- fall through
.endp
        .endseg

;--------------------------------------------------------------
; pj_burst / pj_btick -- the impact: park, play the deathsound, walk the
;   burst frames on their own clocks (pj_bt0/1/2, VBLANKS).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_burst
        lda pj_bsnd
        jsr snd_qp_pj                ; barexp / firxpl AT the impact (STEREO:
                                     ;   from pj_x/pj_y, where it burst)
        lda pj_xid
        bmi pj_gone                  ; no burst frames packed: just vanish
        sta pj_frm                   ; S_EXPLODE1 (info.c: MISL B, A_Explode)
        lda #2
        sta pj_on
        lda pj_bt0
        sta pj_ttl
        bra pj_leaf                  ; the record parks WHERE it burst
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_gone                        ; the missile is done (both tails)
        stz pj_on
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_btick
        sec                          ; this frame ate dt_vbl VBLANKs of the frame
        lda pj_ttl                   ;   clock -- C=0 (it ran past) or Z=1 (it
        sbc dt_vbl                    ;   ran out exactly) both mean: next frame
        sta pj_ttl
        bcc ?adv
        bne ?out
?adv    inc pj_on
        lda pj_on
        cmp #5
        bcs pj_gone                  ; the third frame ran out: gone
        inc pj_frm                   ; next burst frame (consecutive ids)
        cmp #4
        beq ?b2
        lda pj_bt1
        bne ?set                     ; always (bt1 is 9 or 6, never 0)
?b2     lda pj_bt2
?set    sta pj_ttl
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; pj_leaf -- which leaf is the missile in (spr_chasec projects it from
;   there), plus the pseudo-record refresh. locate_floor reads zp_px/py,
;   so borrow them, ball-style.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_leaf
        pei (zp_px)                  ; locate_floor reads the player's zp_px/py:
        pei (zp_py)                  ;   both words onto the stack (pei is M-blind)
        rep #$20                     ; ---- 16-bit A
        .LONGA ON
        lda pj_x
        sta zp_px
        lda pj_y
        sta zp_py
        sep #$20
        .LONGA OFF
        jsr locate_floor             ; zp_nid = the leaf
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        .LONGA ON
        lda zp_nid
        and #$7FFF
        sta pj_ss
        pla                          ; zp_py was pushed last
        sta zp_py
        pla
        sta zp_px
        .LONGA OFF                   ; (still 16-bit: pj_rec_up's rep below is a
                                     ;  no-op on this path and the mode switch ...
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_rec_up
        rep #$20                     ; ---- 16-bit A (idempotent from pj_leaf)
        .LONGA ON
        lda pj_x
        sta pj_rec
        lda pj_y
        sta pj_rec+2
        lda pj_z                     ; r_things.c: the picture's top is the
        sta pj_rec+4                 ;   thing's z + its topoffset (spr_proj)
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg


; ---- split out 2026-09-21 (see each file's header): included HERE, in the original
;      order, so the assembler emits the same bytes.
        icl 'proj_aim.asm'
        icl 'proj_slots.asm'

;--------------------------------------------------------------
; pj_hit -- p_mobj.c P_ExplodeMissile, at the moment the rocket ARRIVES: the
;   direct damage on the thing pj_aim picked, then A_Explode at the impact
;   point.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_hit
        lda pj_vic
        cmp #$FF                     ; $FF = it was flying at a wall. NOT `bmi`
        beq ?blast                   ;   (2026-09-09, "strielam plazmou a nic"):
                                     ;   a THING INDEX runs 0..253, and bit 7 set
                                     ;   is every thing from 128 up -- half of
                                     ;   E1M4's 240.
        sta en_bi
        tax
        lda.l EXT_BASE+TH_HPL,x       ; still alive? Two lda.l, as pj_thit reads
        bne ?alv                     ;   them: the health word is two page arrays
        lda.l EXT_BASE+TH_HPH,x       ;   in bank $01 (no [zp_ptr] re-aiming --
        beq ?blast                   ;   en_bhit and en_bthings aim their own)
?alv    lda pj_dmg                   ; already dead -> no second death chain
        jsr en_bhit                  ; P_DamageMobj + the voice + the chain
?blast  lda pj_bsnd                  ; THE DEATHSOUND SAYS WHAT LANDED: bit 0 --
        lsr                          ;   see the .else side for why one lsr sorts
        bcs ?spray                   ;   BAREXP / RXPLOD / FIRXPL, and the ert
        cmp #SFX_BAREXP/2
        bne ?out
        rep #$20                     ; ---- 16-bit A: the impact point -> en_bx/by
        .LONGA ON
        lda pj_tx
        sta en_bx
        lda pj_ty
        sta en_by
        sep #$20
        .LONGA OFF
        lda #$FF
        sta pj_vic                   ; spent: a re-arm must not land it twice
        jmp en_boomat                ; A_Explode(..., 128) where it went off
?spray  jmp wp_bfgspray              ; forty rays across the whole 90 degree view
?out    rts
.endp
        .endseg

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
    .if [SFX_RXPLOD&1]=0 .or [SFX_BAREXP&1]<>0 .or [SFX_FIRXPL&1]<>0
        ert 'pj_hit dispatches on bit0: SFX_RXPLOD must be the ONLY odd id of the three'
    .endif
        .endseg

        icl 'puff.asm'
