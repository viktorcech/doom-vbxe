;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): P_DamageMobj's kick -- en_thrust and the
;   corpse slide.
;--------------------------------------------------------------

;--------------------------------------------------------------
; en_thrust -- A = damage, Y = the victim, (thr_x, thr_y) = the inflictor's
;   position. The direction is the OCTANT of (victim - inflictor), the same
;   eight A_Chase walks in: 22 degrees of error on a 13-unit slide is a unit
;   and a half, and it costs a table read where DOOM's angle costs a divide.
;   Clobbers A/X/Y, the AI's step scratch and m_a/m_b/m_prod.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_thrust
        sty ai_t
        sta m_a                      ; damage, 16 bit for umul16
        stz m_a+1
        stz m_b+1
        lda #<TH_KIND                ; the mass rides in the kind (mk_thr)
        sta zp_ptr
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?out                     ; no kind -> no mass -> no kick
        tax
        lda mk_thr,x                 ; units of slide per damage point, Q4
        sta m_b
        phx                          ; umul16 no longer keeps X (2026-09-23)
        jsr umul16
        plx
        rep #$20                     ; ---- 16-bit A: -> whole units, rounded (the
        .LONGA ON                    ;   last bit out is the half: adc #0 adds it)
        lda m_prod
        lsr @
        lsr @
        lsr @
        lsr @
        adc #0
        sta thr_d
        beq ?out16                   ; under a unit: not worth a P_TryMove
        sep #$20
        .LONGA OFF
        lda ai_t                     ; the vector victim - inflictor, as two
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ;   words (the record's x,y at +0/+2, and
        .LONGA ON
        sec
        lda (sp_ptr)
        sbc thr_x
        sta swr_vx
        ldy #2
        sec
        lda (sp_ptr),y
        sbc thr_y
        sta swr_vx+2
                                      ; 2026-09-23: past b1_oct_of's rep, still 16-bit
        jsl B1CODE_BASE+b1_oct_of.oo_w16 ; (this sep and that rep were an empty pair)
        .LONGA OFF
        tax
        jmp thr_tail                 ; alive -> spend it now, dead -> en_slide
?out16  sep #$20
        .LONGA OFF
?out    rts
.endp
        .endseg

; thr_step lives in the SLIDE block with its other caller -- this one is full
; to the byte (memory_map.inc).
    .if ai_sy <= ai_sx || ai_sy - ai_sx > 127
        ert 'en_thrust indexes ai_sy off ai_sx -- the AI scratch moved'
    .endif


;--------------------------------------------------------------
; thr_comp -- one axis of the shove. A = that axis' byte out of the octant
;   table (bits 0-1: 0 = nothing, 1 = the whole slide, 2 = three quarters of it
;   -- the diagonal's 0.707, rounded the way mk_stepx rounds it; bit7 = the
;   other way round), Y = the offset into ai_sx. Writes the signed 16-bit step
;   P_TryMove takes. Clobbers A and m_a.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc thr_comp
        sta thr_s
        and #$03
        beq ?zero
        cmp #2
        beq ?q3
        rep #$20                     ; the whole slide, one word
        .LONGA ON
        lda thr_d
        sta ai_sx,y
        bra ?sign
?q3     rep #$20                     ; three quarters = half + quarter, in A
        .LONGA ON
        lda thr_d
        lsr @
        sta ai_sx,y                  ; d/2
        lsr @                        ; d/4
        clc
        adc ai_sx,y
        sta ai_sx,y
?sign   sep #$20
        .LONGA OFF
        lda thr_s
        bpl ?done
        rep #$20                     ; away from the inflictor, not towards it
        .LONGA ON
        sec
        lda #0
        sbc ai_sx,y
        sta ai_sx,y
        sep #$20
        .LONGA OFF
?done   rts
?zero   sta ai_sx,y                  ; A = 0 here
        sta ai_sx+1,y
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; ai_mcnt -- P_TryWalk's tail, evicted from the AI block (the ten bytes that
;   pushed it into pj_frameb): movecount = P_Random()&15 after a walk, and
;   nothing at all after a SHOVE -- en_thrust drops ai_walk, and DOOM's kick
;   never touches the movecount. Returns A = 1, P_Move's "it moved".
;--------------------------------------------------------------
thrc_resume = *
        .endseg
                                      ; 2026-09-22: the roll moved into ai_trywalk


;--------------------------------------------------------------
; en_thrust_bl -- the BLAST's caller wrapper (A_Explode, en_bthings): thing
;   en_bi just took m_prod damage from (en_bx, en_by). It no longer asks
;   whether the thing survived: p_inter.c kicks the dying too, and thr_tail is
;   what tells a step from a corpse's slide.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_thrust_bl
        rep #$20
        .LONGA ON
        lda en_bx
        sta thr_x
        lda en_by
        sta thr_y
        sep #$20
        .LONGA OFF
        ldy en_bi
        lda m_prod                   ; en_bhit parked the damage here
        jmp en_thrust
.endp
        .endseg


;--------------------------------------------------------------
; en_thrust_plr -- the PLAYER's caller wrapper (en_shoot): Y = the thing his
;   bullet just failed to kill, en_dmg = what it took off.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_thrust_plr
        rep #$20
        .LONGA ON
        lda zp_px
        sta thr_x
        lda zp_py
        sta thr_y
        sep #$20
        .LONGA OFF
        lda en_dmg
        jmp en_thrust
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
; The octant (oct_of: 0 = east, counting counter-clockwise) -> how much of the
; slide goes on each axis: 0 = none, 1 = all of it, 2 = three quarters (the
; diagonals), bit7 = negative.
thr_sx  dta 1,2,0,$82,$81,$82,0,2
thr_sy  dta 0,2,1,2,0,$82,$81,$82
thr_x   dta a(0)                     ; the inflictor (thr_y MUST follow it: the
thr_y   dta a(0)                     ;   vector loop indexes both off thr_x)
thr_d   dta a(0)                     ; the whole slide, in units
thr_s   dta 0                        ; thr_comp's selector, across the maths
                                      ; 2026-09-22: no reader left (ai_mcnt is gone)
sl_th   dta $FF                      ; the ONE corpse sliding ($FF = none)...
sl_d    dta 0                        ;   with this many units of slide left...
sl_oct  dta 0                        ;   along this octant (en_slide)
    .if thr_y != thr_x+2
        ert 'en_thrust indexes thr_y off thr_x'
    .endif
thrdat_resume = *

;--------------------------------------------------------------
; thr_tail -- en_thrust's last step, X = the octant, ai_t = the victim,
;   thr_d = the whole slide. p_inter.c:806 kicks the target whether or not the
;   damage killed it; the two cases just spend the kick differently here:
;     alive -> one P_TryMove, the whole slide, this tic (unchanged)
;--------------------------------------------------------------
        .endseg
;--------------------------------------------------------------
; thr_step -- X = the octant, thr_d = how far, ai_t = the thing: one P_TryMove
;   along it. Both en_thrust (a survivor's whole slide, at once) and en_slide
;   (a tic's worth of a corpse's) end here. Clobbers A/Y, m_a, the AI scratch.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc thr_step
        ldy #0
        lda thr_sx,x
        jsr thr_comp
        ldy #ai_sy-ai_sx             ; (ai_sdir sits between them -- see the
        lda thr_sy,x                 ;  guard by en_thrust)
        jsr thr_comp
                                      ; 2026-09-22: a shove is P_TryMove alone; ai_step
        jmp ai_move.ai_step          ;   no longer touches the movecount (no caller
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc thr_tail
        ldy ai_t
        lda #<TH_HPL
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        bne thr_step 
        ;bra thr_step                 ; a survivor: it steps, now
?arm    sty sl_th                    ; a corpse: en_slide walks it out. What is
        stx sl_oct                   ;   left rides in ONE byte -- the biggest
        ldx thr_d+1                  ;   slide DOOM can hand a thing here is a
        beq ?lo                      ;   128-damage blast on a mass-100 barrel,
        lda #255                     ;   170 units, and 255 is the only cap that
        bne ?put                     ;   ever bites (a berserk punch, 266)
?lo     lda thr_d
?put    sta sl_d
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_slide -- one TIC of the sliding corpse, off the same clock the death
;   frames run on (weapon.asm's tic loop). p_mobj.c P_XYMovement spends the
;   momentum at FRICTION 0xe800 = 0.90625 a tic and stops under STOPSPEED;
;   this spends an EIGHTH of what is left, which is three shifts instead of a
;   when a tic's worth no longer reaches a unit. Clobbers A/X/Y and the AI
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_slide
        ldy sl_th
        iny                          ; $FF = nothing sliding -> 0. NOT `bmi`: a
        beq ?out                     ;   thing index runs to 253, so bit 7 is
        dey                          ;   just "thing 128 or later" (pj_hit)
        sty ai_t
        stz thr_d+1
        lda sl_d                     ; thr_d = an eighth of what is left
        lsr
        lsr
        lsr
        beq ?stop                    ; under a unit a tic: STOPSPEED
        sta thr_d
        sec                          ; ...and take it off the remainder
        lda sl_d
        sbc thr_d
        sta sl_d
        ldx sl_oct
        bra thr_step
?stop   lda #$FF
        sta sl_th
?out    rts
.endp
        .endseg

