;--------------------------------------------------------------
; Part of proj.asm (icl in place): bullet puffs + blood -- sh_refine, pf_shot, pf_gore, pf_leaf, pf_frameb, spr_chased.
;--------------------------------------------------------------

;==============================================================
; PUFF (2026-08-05) -- P_SpawnPuff, "ked strelim do steny, nic nevidno".
;==============================================================
PF_TICS  equ 6                       ; one PUFF frame: DOOM's 4 tics at 35 Hz is
                                     ;   5.7 VBLANKs at 50 -- the same tic->VB
                                     ;   conversion pj_rspawn's 8/6/4 -> 11/9/6 uses

PF_MAX   equ 7                       ; A_FireShotgun's pellet count -- SEVEN puffs
                                     ;   is what the spread LOOKS like; one can
                                     ;   only ever show a single hole
PF_TBLD  equ 11                      ; BLUD's 8 tics at 35 Hz -> VBLANKs at 50

pfv_resume = *
        org PFVAR_BASE               ; the state, out of the code block: seven
                                     ;   pellets and two chains filled it
pf_on   dta 0                        ; 0 = idle, else the frame number, 1-based
pf_lst  dta 5                        ; the frame number it dies ON: a puff is
                                     ;   1..4 so 5, blood from BLUD C is 1..3
pf_lvl  dta $FF                      ; the level the two ids below belong to
pf_id   dta $FF                      ; PUFF A's sprtab id (things header +24)
pf_bid  dta $FF                      ; BLUD C's, first of C/B/A (+25)
pf_mel  dta 0                        ; 1 = the shot was a punch or a saw
pf_ttl  dta 0                        ; VBLANKs left on the current frame
pf_tic  dta PF_TICS                  ; ...and how many each frame gets
pf_n    dta 0                        ; how many of the seven are live
pf_i    dta 0                        ; the spawn/draw cursor
pf_lat  dta a(0)                     ; one pellet's lateral offset at the wall
pf_ss   dta a(0)                     ; ONE leaf for all of them: they land within
                                     ;   ~50 units of each other on the same wall, ...
pf_rec  dta a(0), a(0), a(0), 0, 0   ; pseudo thing record: x, y, z(anchor),
                                     ;   sprite id, flags 0 (not a pickup)
    .if * > PFVAR_END+1
        ert 'the puff state outgrew PFVAR_BASE..PFVAR_END (memory_map.inc)'
    .endif
        org pfv_resume

;--------------------------------------------------------------
; sh_refine -- sh_trace's tail: the walk found the leaf that stops the bullet
;   and sh_leaf left zp_sptr on the seg, so bisect the RAY LENGTH for where it
;   crosses. Out of the ROCKW block, which sh_trace fills to two bytes.
;--------------------------------------------------------------
pf_resume = *
        org SHREF_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sh_refine
        stz sh_lo                    ; the wall is somewhere in [0, sh_hi], and
        stz sh_lo+1                  ;   sh_hi is still the full ray
        stz USE_K
        ldx #8                       ; side(v1 -> v2, the ray START). Constant --
        ldy #12                      ;   A never moves, so it comes out here
        jsr use_side
        sta sh_sa
        lda #SH_REF                  ; the count lives in MEMORY: smul_14 (under
        sta sh_n                     ;   sh_setb) eats X
?ref    rep #$21                     ; ---- 16-bit A, C=0: mid = (lo + hi) / 2 in
        .LONGA ON                    ;   the accumulator (was a byte add and a
        lda sh_lo                    ;   lsr/ror pair in memory)
        adc sh_hi
        lsr @
        sta sh_d
        sep #$20
        .LONGA OFF
        jsr sh_setb                  ; shorten the ray to mid...
        lda #4
        sta USE_K
        ldx #8
        ldy #12
        jsr use_side                 ; ...and ask which side of the seg it ends
        cmp sh_sa
        beq ?rlo                     ; same side as A -> it has not reached it
        lda sh_d                     ; crossed -> the wall is at or before mid
        sta sh_hi
        lda sh_d+1
        sta sh_hi+1
        bra ?rnx
?rlo    lda sh_d                     ; clear -> it is beyond mid
        sta sh_lo
        lda sh_d+1
        sta sh_lo+1
?rnx    dec sh_n
        bne ?ref
        lda sh_lo                    ; the last CLEAR length: just in FRONT of
        sta sh_d                     ;   the wall, where a sprite is still drawn
        lda sh_lo+1
        sta sh_d+1
        jsr sh_dist
                                    ; sh_end takes 16-bit (its rep is idempotent)
        sec
        jmp sh_end                   ; C=1: a wall was found
.endp
        .endseg
; the seven pellets' impact points, parked with sh_refine: the puff block itself
; went full the moment one puff became seven.
pf_px   dta a(0),a(0),a(0),a(0),a(0),a(0),a(0)
pf_py   dta a(0),a(0),a(0),a(0),a(0),a(0),a(0)
    .if * > SHREF_END+1
        ert 'sh_refine + the pellet points outgrew SHREF_BASE..END'
    .endif
        org PFTAB_BASE
; tan(the pellet's angle) in Q14, one entry per aim column 72..88. SCREEN_HALF
; IS the focal length (90 deg FOV), so a shot landing Dx columns off centre has
; tangent Dx/80 -- in Q14 that is Dx * 16384/80 = Dx * 205. A table, not a
; multiply: the index is signed and there are only seventeen of them.
pf_tan  dta a(-1640),a(-1435),a(-1230),a(-1025),a(-820),a(-615),a(-410),a(-205)
        dta a(0)
        dta a(205),a(410),a(615),a(820),a(1025),a(1230),a(1435),a(1640)
    .if * > PFTAB_END+1
        ert 'pf_tan outgrew PFTAB_BASE..PFTAB_END (memory_map.inc)'
    .endif
        org pf_resume

;--------------------------------------------------------------
; pf_shot -- one call per trigger pull, from en_gunshot's hitscan tails.
;   A shot that CONNECTED leaves en_hit set and DOOM would spawn blood, not a
;   puff, so there is nothing to do. A shot that hit nothing gets the wall
;   traced and the puff put there.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pf_shot
        lda pf_on
        bne ?out                     ; one already showing: let it finish (ONE
                                     ;   instance -- see the .else side)
        lda en_hit
        beq ?wall
        jmp pf_gore                  ; it hit a THING: blood, or a puff if that
                                     ;   thing does not bleed (p_map.c:1005)
?wall   lda pf_id
        bmi ?out                     ; the level packed no PUFF frames
        lda #SH_NBULL
        ldx pf_mel
        beq ?rng                     ; a punch or a saw only reaches MELEERANGE
        lda #SH_NMELEE
?rng    jsr sh_trace                 ; en_bx/en_by = where the bullet stopped
        bcs ?hitwall                 ; C=0: nothing in reach
?out    rts
?hitwall
        jsr gun_match                ; P_ShootSpecialLine: the wall this bullet
                                     ;   stopped on may be a 46 (E1M2's secret door) ...
?go     ldx #1
        lda wp_cur
        cmp #WP_SHOTGUN
        bne ?n1
        ldx #PF_MAX
?n1     stx pf_n
        stx pf_i
?pel    jsr en_aimcol                ; the same roll the pellet itself took
        lda en_col
        sec
        sbc #SCREEN_HALF-8           ; 0..16
        asl
        tay
        rep #$20
        .LONGA ON
        lda pf_tan,y                 ; m_b = tan(this pellet's angle), Q14
        sta m_b
        lda sh_d                     ; m_a = the wall distance sh_trace settled on
        sta m_a
        sep #$20
        .LONGA OFF
        jsr smul_14                  ; m_res = how far off the impact it lands
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit
        .LONGA ON
;       lda m_res                    ; smul_14 leaves m_res IN A
                                      ; 2026-09-22 (65816-style): the lateral offset
        pha                          ;   rides the stack (16-bit) to its reload below
        sta m_a                      ; slide along the PERPENDICULAR (-sin, cos)
        lda zp_sin
        sta m_b
        sep #$20
        .LONGA OFF
        jsr smul_14
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit
        sep #$20
        ldx pf_i
        dex
        txa
        asl
        tax                          ; X = the pellet's slot * 2
        rep #$20
        .LONGA ON
        sec                          ; px = impact_x - lat*sin
        lda en_bx
        sbc m_res
        sta pf_px,x
        pla                          ; (16-bit, as it was pushed; pla keeps C)
        sta m_a
        lda zp_cos
        sta m_b
        sep #$20
        .LONGA OFF
        phx                          ; (smul_14 eats X)
        jsr smul_14
        plx
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit,
        clc                          ;   and that rep also cleared C
        .LONGA ON
        lda en_by                    ; py = impact_y + lat*cos
        adc m_res
        sta pf_py,x
        sep #$20
        .LONGA OFF
        dec pf_i
        bne ?pel 
        ;jmp ?pel                     ; (out of branch range)
?allset rep #$20
        .LONGA ON
        sec                          ; they hang at eye - 9, level: the height the
        lda zp_pz                    ;   missiles fly at, and the shot is level too
        sbc #9
        sta pf_rec+4
        lda en_bx                    ; the LEAF comes off the traced impact point
        sta pf_rec
        lda en_by
        sta pf_rec+2
        sep #$20
        .LONGA OFF
        ldx #5                       ; PUFF A/B/C/D, so it dies on frame 5
        lda pf_id
        ldy pf_mel
        beq ?st
        inc @                        ; "don't make punches spark on the wall"
        inc @                        ;   (p_mobj.c): a melee puff starts at
        ldx #3                       ;   S_PUFF3, i.e. PUFF C, and shows two
?st     sta pf_rec+6
        stx pf_lst
        lda #PF_TICS
        sta pf_tic
        sta pf_ttl
        lda #1
        sta pf_on
        bra pf_leaf
.endp
        .endseg

;--------------------------------------------------------------
; pf_gore -- PTR_ShootTraverse's THING branch (p_map.c:1000-1010): the shot
;   reached something, so it leaves BLOOD there -- or a puff, if the thing has
;   MF_NOBLOOD.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pf_gore
        lda en_kind                  ; MF_NOBLOOD -> a puff: kind 0 (a shootable
        beq ?puff                    ;   this port names no kind for) and the
        cmp #MK_BEXP                 ;   BARREL, which does have one
        bne ?blood
?puff   lda pf_id
        bmi ?out
        ldx #5                       ; PUFF A/B/C/D
        ldy #PF_TICS
        bne ?arm                     ; (always: PF_TICS is 6)
?blood  lda pf_bid
        bmi ?out
        ldy en_dmg                   ; P_SpawnBlood's damage gate
        cpy #13
        bcs ?bset                    ; >= 13: BLUD C, three frames
        ldx #3
        cpy #9
        bcs ?b2                      ; 9..12: BLUD B, two
        ldx #2
        inc @                        ; < 9: BLUD A, one (id + 2)
?b2     inc @                        ; (+1 -- an id is never 0, and inc sets Z
        bne ?bt                      ;  like the adc did: always taken)
?bset   ldx #4                       ; BLUD C/B/A -> frames 1..3, dies on 4
?bt     ldy #PF_TBLD
?arm    sta pf_rec+6
        stx pf_lst
        sty pf_tic
        sty pf_ttl
        lda en_last                  ; the thing the shot connected with
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ;   -> sp_ptr = its record (x, y at 0..3)
        .LONGA ON                    ;   anchor
        lda (sp_ptr)
        sta pf_px
        sta pf_rec
        ldy #2
        lda (sp_ptr),y
        sta pf_py
        sta pf_rec+2
        sec                          ; eye - 9, level, like the wall puff
        lda zp_pz
        sbc #9
        sta pf_rec+4
        sep #$20
        .LONGA OFF
        lda #1
        sta pf_n                     ; ONE gore sprite, never seven
        sta pf_on
        bra pf_leaf
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; pf_leaf -- which subsector the puff hangs in, so spr_chased knows when to
;   project it. locate_floor reads zp_px/zp_py, so borrow them (pj_leaf's dance).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pf_leaf
        pei (zp_px)                  ; locate_floor reads zp_px/zp_py: park both
        pei (zp_py)                  ;   words (pj_leaf's dance, 16-bit)
        rep #$20
        .LONGA ON
        lda pf_rec
        sta zp_px
        lda pf_rec+2
        sta zp_py
        sep #$20
        .LONGA OFF
        jsr locate_floor             ; zp_nid = the leaf
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        .LONGA ON
        lda zp_nid
        and #$7FFF
        sta pf_ss
        pla
        sta zp_py
        pla
        sta zp_px
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pf_frameb -- the frame loop's projectile call, retargeted once more: the
;   missile's chain first (which starts with the movers), then the puff clock.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pf_frameb
        jsr pj_frameb
        lda current_level            ; a new level: forget the puff and learn
        cmp pf_lvl                   ;   this level's PUFF id
        beq ?same
        sta pf_lvl
        lda #0
        sta pf_on
        sta.l EXT_BASE+TH_HPL+TH_NOTHING     ; sentinel 253: health 0 so en_shoot skips
        sta.l EXT_BASE+TH_HPL+$100+TH_NOTHING ;  it, state 0 so spr_dyn draws it live,
        sta.l EXT_BASE+TH_STATE+TH_NOTHING   ;   kind 0 so wrot_idle does not send it
        sta.l EXT_BASE+TH_KIND+TH_NOTHING    ;   down the monster path (proj.asm's note)
        lda THINGS_BASE+24
        sta pf_id
        lda THINGS_BASE+25
        sta pf_bid
?same   lda pf_on
        beq ?out
        sec                          ; this drawn frame ate dt_vbl VBLANKs
        lda pf_ttl
        sbc dt_vbl
        sta pf_ttl
        bcc ?adv                     ; ran past, or out exactly -> next frame
        beq ?adv
        lda dt_vbl                    ; ...and one image per DRAWN frame once the
        cmp #4                       ;   frames get long (the .else side's note)
        bcc ?out
?adv    inc pf_on
        lda pf_on
        cmp pf_lst
        bcs ?gone                    ; the last frame ran out: S_NULL
        inc pf_rec+6                 ; every chain here is packed CONSECUTIVE
        lda pf_tic
        sta pf_ttl
?out    rts
?gone   stz pf_on
        rts
.endp
        .endseg

;--------------------------------------------------------------
; spr_chased -- spr_add's chase hook, retargeted a third time (sprites.asm
;   calls this one): the ball and the missile first, then the puff.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_chased
        jsr spr_chase                ; the monsters (enemy_ai.asm) ...
        lda bl_on                    ; --- spr_chaseb (ball.asm) INLINED: the
        beq ?cb_out                  ;   imp's fireball, when it is in this leaf
        lda zp_nid
        cmp bl_ss
        bne ?cb_out
        lda zp_nid+1
        and #$7F
        cmp bl_ss+1
        bne ?cb_out
        lda sp_n
        cmp #VIS_MAX
        bcs ?cb_out
        lda #TH_NOTHING              ; vs_th: not a thing
        sta sp_i
        lda #<bl_rec
        sta sp_ptr
        lda #>bl_rec
        sta sp_ptr+1
        jsr spr_proj
?cb_out lda pj_any                   ; --- spr_chasec INLINED: nothing flying
        beq ?cc_out                  ;   anywhere (the usual frame): one load
        ldx #PJ_NSLOT-1              ;   instead of an 8-slot scan
?cc_lp  lda pj_ons,x
        beq ?cc_nx
        lda zp_nid
        cmp pj_ssl,x
        bne ?cc_nx
        lda zp_nid+1
        and #$7F
        cmp pj_ssh,x
        bne ?cc_nx
        lda sp_n
        cmp #VIS_MAX
        bcs ?cc_nx
        jsr pj_draw1
        ldx pj_cur                   ; (pj_draw1 goes through spr_proj)
?cc_nx  dex
        bpl ?cc_lp
?cc_out                              ; --- and the puffs (2026-09-15: the chain
        lda pf_on                    ;   spr_chased/c/b was three nested jsr/rts
        beq ?out                     ;   per subsector; spr_chasec/spr_chaseb
                                     ;   stay in their files as reference text)
        lda zp_nid
        cmp pf_ss
        bne ?out
        lda zp_nid+1
        and #$7F
        cmp pf_ss+1
        bne ?out
        lda pf_n                     ; every live pellet's puff, one at a time
        sta pf_i                     ;   through the shared record
?one    lda sp_n
        cmp #VIS_MAX
        bcs ?out
        ldx pf_i
        dex
        txa
        asl
        tax
        rep #$20                     ; ---- 16-bit A: the pellet's x, y into the
        .LONGA ON                    ;   record and the record's address into
        lda pf_px,x                  ;   sp_ptr, all words
        sta pf_rec
        lda pf_py,x
        sta pf_rec+2
        lda #pf_rec
        sta sp_ptr
        sep #$20
        .LONGA OFF
        lda #TH_NOTHING              ; vs_th: the puff's "not a thing"
        sta sp_i
        jsr spr_proj
        dec pf_i
        bne ?one
?out    rts
.endp
        .endseg

