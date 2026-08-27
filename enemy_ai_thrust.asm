; Part of enemy_ai.asm -- AUTO-SPLIT out of it 2026-08-09 -- assembled in place via icl at the
; exact point the text was cut from, so every org and every block guard below is
; unchanged (verified: build/doom_bsp.xex is byte-identical).
;   P_DamageMobj's KICK: en_thrust and the corpse slide (THRUST_BASE ...)
;==============================================================
; P_DamageMobj's KICK (p_inter.c:806-831) -- what a hit does to where its
; victim STANDS. DOOM hands the target momentum,
;
;       thrust = damage*(FRACUNIT>>3)*100/target->info->mass
;
; away from the inflictor, and p_mobj.c P_XYMovement then spends it at FRICTION
; (0.90625) a tic until it drops under STOPSPEED. What you SEE is a slide of
; thrust/(1-FRICTION) = damage*133/mass units: a pistol hit slides a barrel or
; a zombieman (mass 100) about 13 units, a demon (400) three, a baron (1000)
; one. Nothing is exempt -- only MF_NOCLIP is, and no thing in E1 has it.
;
; NOT DOOM, and it is the whole reduction: things carry no momentum in this
; port (there is no P_XYMovement, no per-thing momx/momy, no tic sweep over
; them), so the entire slide is spent AT ONCE on the tic of the hit, through
; the same P_TryMove the AI walks with -- ai_move.ai_step, which brings the
; line probe, PIT_CheckThing, the 24-unit step rules, the re-floor and the
; draw-table entry with it. At this port's frame rate DOOM's slide is three or
; four drawn frames long, so one step and a slide read much the same.
;
; A SURVIVOR is kicked that way. The DYING are kicked too since 2026-08-05 --
; p_inter.c:806 runs the kick BEFORE the `health <= 0` test, so a rocketed
; barrel slides while it bursts -- but not at once: 128 damage is 170 units and
; spending that in one step would teleport the barrel across the room before
; the first BEXP frame. A corpse gets the slide en_slide spends the way
; P_XYMovement does, an eighth of what is left per TIC, so it travels over the
; same three or four drawn frames DOOM's friction takes. ONE corpse slides at a
; time (the port's usual single-slot reduction): a blast that kills three
; barrels at once slides the last of them.
;==============================================================
        org THRUST_BASE

;--------------------------------------------------------------
; en_thrust -- A = damage, Y = the victim, (thr_x, thr_y) = the inflictor's
;   position. The direction is the OCTANT of (victim - inflictor), the same
;   eight A_Chase walks in: 22 degrees of error on a 13-unit slide is a unit
;   and a half, and it costs a table read where DOOM's angle costs a divide.
;   Clobbers A/X/Y, the AI's step scratch and m_a/m_b/m_prod.
;--------------------------------------------------------------
.proc en_thrust
        sty ai_t
        sta m_a                      ; damage, 16 bit for umul16
        lda #0
        sta m_a+1
        sta m_b+1
        lda #<TH_KIND                ; the mass rides in the kind (mk_thr)
        sta zp_ptr
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?out                     ; no kind -> no mass -> no kick
        tax
        lda mk_thr,x                 ; units of slide per damage point, Q4
        sta m_b
        jsr umul16
        ldx #4
?sh     lsr m_prod+1                 ; -> whole units, rounded: the last bit out
        ror m_prod                   ;   is the half, and a unit is all the
        dex                          ;   resolution a thing coordinate has
        bne ?sh
        bcc ?nr
        inc m_prod
        bne ?nr
        inc m_prod+1
?nr     lda m_prod                   ; (en_th2 below reuses m_prod)
        sta thr_d
        lda m_prod+1
        sta thr_d+1
        ora thr_d
        beq ?out                     ; under a unit: not worth a P_TryMove
        lda ai_t                     ; the vector victim - inflictor, both
        jsr en_thing.en_th2          ;   halves in one loop: the record's x,y
        ldy #0                       ;   and thr_x,thr_y are both 4 byte pairs
        ldx #0
?vec    sec
        lda (sp_ptr),y
        sbc thr_x,x
        sta swr_vx,x
        iny
        lda (sp_ptr),y
        sbc thr_x+1,x
        sta swr_vx+1,x
        iny
        inx
        inx
        cpx #4
        bne ?vec
        jsr oct_of                   ; A = the octant to shove along
        tax
        jmp thr_tail                 ; alive -> spend it now, dead -> en_slide
?out    rts
.endp

; thr_step lives in the SLIDE block with its other caller -- this one is full
; to the byte (memory_map.inc).
    .if ai_sy <= ai_sx || ai_sy - ai_sx > 127
        ert 'en_thrust indexes ai_sy off ai_sx -- the AI scratch moved'
    .endif
    .if * > THRUST_END+1
        ert 'en_thrust outgrew THRUST_BASE..THRUST_END (memory_map.inc)'
    .endif

        org THRC_BASE

;--------------------------------------------------------------
; thr_comp -- one axis of the shove. A = that axis' byte out of the octant
;   table (bits 0-1: 0 = nothing, 1 = the whole slide, 2 = three quarters of it
;   -- the diagonal's 0.707, rounded the way mk_stepx rounds it; bit7 = the
;   other way round), Y = the offset into ai_sx. Writes the signed 16-bit step
;   P_TryMove takes. Clobbers A and m_a.
;--------------------------------------------------------------
.proc thr_comp
        sta thr_s
        and #$03
        beq ?zero
        cmp #2
        beq ?q3
        lda thr_d                    ; the whole slide
        sta ai_sx,y
        lda thr_d+1
        sta ai_sx+1,y
        jmp ?sign
?q3     lda thr_d+1                  ; three quarters = half + quarter
        lsr
        sta m_a+1
        lda thr_d
        ror
        sta m_a                      ; m_a = d/2
        sta ai_sx,y
        lda m_a+1
        sta ai_sx+1,y
        lsr m_a+1
        ror m_a                      ; m_a = d/4
        clc
        lda ai_sx,y
        adc m_a
        sta ai_sx,y
        lda ai_sx+1,y
        adc m_a+1
        sta ai_sx+1,y
?sign   lda thr_s
        bpl ?done
        sec                          ; away from the inflictor, not towards it
        lda #0
        sbc ai_sx,y
        sta ai_sx,y
        lda #0
        sbc ai_sx+1,y
        sta ai_sx+1,y
?done   rts
?zero   sta ai_sx,y                  ; A = 0 here
        sta ai_sx+1,y
        rts
.endp

;--------------------------------------------------------------
; ai_mcnt -- P_TryWalk's tail, evicted from the AI block (the ten bytes that
;   pushed it into pj_frameb): movecount = P_Random()&15 after a walk, and
;   nothing at all after a SHOVE -- en_thrust drops ai_walk, and DOOM's kick
;   never touches the movecount. Returns A = 1, P_Move's "it moved".
;--------------------------------------------------------------
thrc_resume = *
        org THRMC_BASE
.proc ai_mcnt
        lda ai_walk
        beq ?out
        lda RANDOM
        and #15
        ldx #>TH_MCNT
        jsr ai_put
?out    lda #1
        rts
.endp
    .if * > THRMC_END+1
        ert 'ai_mcnt outgrew THRMC_BASE..THRMC_END (memory_map.inc)'
    .endif
        org thrc_resume
    .if * > THRC_END+1
        ert 'thr_comp outgrew THRC_BASE..THRC_END (memory_map.inc)'
    .endif

        org THRBL_BASE

;--------------------------------------------------------------
; en_thrust_bl -- the BLAST's caller wrapper (A_Explode, en_bthings): thing
;   en_bi just took m_prod damage from (en_bx, en_by). It no longer asks
;   whether the thing survived: p_inter.c kicks the dying too, and thr_tail is
;   what tells a step from a corpse's slide.
;--------------------------------------------------------------
.proc en_thrust_bl
        lda en_bx
        sta thr_x
        lda en_bx+1
        sta thr_x+1
        lda en_by
        sta thr_y
        lda en_by+1
        sta thr_y+1
        ldy en_bi
        lda m_prod                   ; en_bhit parked the damage here
        jmp en_thrust
.endp
    .if * > THRBL_END+1
        ert 'en_thrust_bl outgrew THRBL_BASE..THRBL_END (memory_map.inc)'
    .endif

        org THRDAT_BASE

;--------------------------------------------------------------
; en_thrust_plr -- the PLAYER's caller wrapper (en_shoot): Y = the thing his
;   bullet just failed to kill, en_dmg = what it took off.
;--------------------------------------------------------------
.proc en_thrust_plr
        lda zp_px
        sta thr_x
        lda zp_px+1
        sta thr_x+1
        lda zp_py
        sta thr_y
        lda zp_py+1
        sta thr_y+1
        lda en_dmg
        jmp en_thrust
.endp
; The octant (oct_of: 0 = east, counting counter-clockwise) -> how much of the
; slide goes on each axis: 0 = none, 1 = all of it, 2 = three quarters (the
; diagonals), bit7 = negative.
thr_sx  dta 1,2,0,$82,$81,$82,0,2
thr_sy  dta 0,2,1,2,0,$82,$81,$82
thr_x   dta a(0)                     ; the inflictor (thr_y MUST follow it: the
thr_y   dta a(0)                     ;   vector loop indexes both off thr_x)
thr_d   dta a(0)                     ; the whole slide, in units
thr_s   dta 0                        ; thr_comp's selector, across the maths
ai_walk dta 1                        ; 0 = ai_step is a shove, not P_TryWalk
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
;     dead  -> hand it to en_slide, which spends it over the tics the way
;              P_XYMovement's FRICTION does
;   The health test reads the LOW byte only. A thing sitting on an exact
;   multiple of 256 health (a baron at 256 of its 1000) therefore reads as a
;   corpse and gets the SLIDE instead of the step -- which is what DOOM gives
;   it anyway, so the shortcut costs nothing.
;--------------------------------------------------------------
        org SLIDE_BASE
;--------------------------------------------------------------
; thr_step -- X = the octant, thr_d = how far, ai_t = the thing: one P_TryMove
;   along it. Both en_thrust (a survivor's whole slide, at once) and en_slide
;   (a tic's worth of a corpse's) end here. Clobbers A/Y, m_a, the AI scratch.
;--------------------------------------------------------------
.proc thr_step
        ldy #0
        lda thr_sx,x
        jsr thr_comp
        ldy #ai_sy-ai_sx             ; (ai_sdir sits between them -- see the
        lda thr_sy,x                 ;  guard by en_thrust)
        jsr thr_comp
        dec ai_walk                  ; a shove, not P_TryWalk: the movecount is
        jsr ai_move.ai_step          ;   A_Chase's and stays A_Chase's
        inc ai_walk
        rts
.endp

.proc thr_tail
        ldy ai_t
        lda #<TH_HPL
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?arm
        jmp thr_step                 ; a survivor: it steps, now
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

;--------------------------------------------------------------
; en_slide -- one TIC of the sliding corpse, off the same clock the death
;   frames run on (weapon.asm's tic loop). p_mobj.c P_XYMovement spends the
;   momentum at FRICTION 0xe800 = 0.90625 a tic and stops under STOPSPEED;
;   this spends an EIGHTH of what is left, which is three shifts instead of a
;   multiply and lands within a unit of DOOM over the whole slide, and stops
;   when a tic's worth no longer reaches a unit. Clobbers A/X/Y and the AI
;   step scratch -- it runs beside en_tick, which owns none of that.
;--------------------------------------------------------------
.proc en_slide
        ldy sl_th
        bmi ?out                     ; nothing sliding
        sty ai_t
        lda #0
        sta thr_d+1
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
        jmp thr_step
?stop   lda #$FF
        sta sl_th
?out    rts
.endp
    .if * > SLIDE_END+1
        ert 'thr_tail/en_slide outgrew SLIDE_BASE..SLIDE_END (memory_map.inc)'
    .endif
        org thrdat_resume
    .if * > THRDAT_END+1
        ert 'the thrust data outgrew THRDAT_BASE..THRDAT_END (memory_map.inc)'
    .endif

