;--------------------------------------------------------------
; Part of bsp_main.asm (icl in place): swap_buffers, read_input, move_player and
;   the fall block. The stick is read from PIA PORTA, not the OS shadow.
;--------------------------------------------------------------
STICK0   equ $D300            ; PIA PORTA (joystick 0 in low nibble)

;--------------------------------------------------------------
; swap_buffers -- wait VBLANK, display the just-rendered buffer, flip back.
;   (OS VBI ticks RTCLOK3; main enables NMIEN=$40 before the loop.)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc swap_buffers
        jsr blitw_hard               ; async blitter: ensure the frame's LAST blit
                                     ; finished before we publish the buffer
        ldx zback_hi                 ; show the LIST that reads the buffer we
        lda xdl_hi,x                 ;   just drew -- and DO NOT WAIT (2026-08-11
        sta XDLA_PEND                ;   triple buffer): the VBI publishes this
        stx ZFRONT                   ;   at the next blank (rom_nmi -- the real
        lda znext,x                  ;   FX core switches mid-frame otherwise),
        sta zback_hi                 ;   and with three buffers the next back
        lda FRM_PAR                  ;   buffer is never the one being scanned,
        eor #$01                     ;   so the old ~11 ms VBLANK spin is gone.
        sta FRM_PAR                  ;   ZFRONT = what the screen shows/will
        rts                          ;   show (mn_key gates the menu on it).
.endp
        .endseg
xdt_resume = *
        org XDLTAB_BASE              ; the two 8-entry flip maps, indexed by
xdl_hi  dta >VRAM_XDL_A, >VRAM_XDL_B, 0, 0, 0, 0, 0, >VRAM_XDL_C
znext   dta $01, $07, 0, 0, 0, 0, 0, $00     ; zback_hi: $00 -> $01 -> $07 -> $00
        org xdt_resume

;--------------------------------------------------------------
; read_input -- snapshot STICK0; apply rotation to zp_ang.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc read_input
        lda pl_rt                    ; P_PlayerThink: `if (reactiontime)
        bne ?frz                     ;   reactiontime-- else P_MovePlayer`
        lda STICK0
        sta stick_save
        ldx pl_dead                  ; p_user.c P_PlayerThink: PST_DEAD goes to
        bne ?nr                      ;   P_DeathThink and RETURNS -- P_MovePlayer
                                     ;   never runs, so a corpse neither walks
                                     ;   (move_player already knew) nor TURNS
        and #$04                     ; left pressed? -> turn left (ang += step)
        bne ?nl
        lda zp_ang
        clc
        adc TRN_STEP                 ; = TURN (fixed per frame, see plr_steps)
        sta zp_ang
?nl     lda stick_save
        and #$08                     ; right pressed? -> turn right (ang -= step)
        bne ?nr
        lda zp_ang
        sec
        sbc TRN_STEP
        sta zp_ang
?nr     rts
?frz    sec                          ; after a teleport: no walk, no turn (the
        sbc dt_vbl                   ;   trigger is not P_MovePlayer's, so the
        bcs ?rt                      ;   gun still fires) -- last frame's
        lda #0                       ;   dt_vbl, saturating at 0
?rt     sta pl_rt
        lda #$0F                     ; the stick centred for move_player
        sta stick_save
        rts
.endp
        .endseg

;--------------------------------------------------------------
; move_player -- ONE call's walk, pl_step along the heading plr_steps latched
;   (pl_acos/pl_asin), with wall collision. DOOM-style X-then-Y slide: each
;   axis commits only if the candidate stays clear of walls (collide_blocked),
;   so the player slides along a wall instead of passing through it.
;   coll_cx/coll_cy (= zp_rx/zp_ry) carry the tested point into collide_blocked.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc move_player
        lda pl_dead                  ; a corpse does not walk (P_DeathThink runs
        bne ?dead                    ;   instead of P_MovePlayer)
        lda pl_air                   ; in the air the keys are not read
        bne ?go                      ;   (P_MovePlayer): pl_step is what he left
        lda stick_save               ;   the ground with
        and #$03                     ; up or down pressed? (both 1 = neither)
        cmp #$03
        bne ?go
?dead   jmp pl_idle                  ; a shove may still be running
?feet   rep #$20                     ; in the air P_TryMove measures the step up
        .LONGA ON                    ;   from the FEET (tmfloorz - mo->z)
        lda pl_z
        bra ?cf
        .LONGA OFF
?go     rep #$20                     ; ---- 16-bit A
        .LONGA ON
        lda pl_step                  ; this call's distance, Q8, negative walking
        sta m_a                      ;   back (plr_steps)
        lda pl_acos
        sta m_b
        sep #$20
        .LONGA OFF
        jsr smul_14                  ; dx = d*cos >> 14, Q8, in a 16-bit A
        .LONGA ON
        clc                          ; + x below the unit and the cell's $8000:
        adc pl_fx                    ;   $80 + the whole units in the high byte
        tay                          ;   (|d| <= PSTEP_MAX), the new fraction in
        sty pl_fx                    ;   the low one -- Y is 8-bit
        xba
        and #$00FF
        sec
        sbc #$0080
        sta mv_dx
        lda pl_step
        sta m_a
        lda pl_asin
        sta m_b
        sep #$20
        .LONGA OFF
        jsr smul_14                  ; dy = d*sin >> 14
        .LONGA ON
        clc
        adc pl_fy
        tay
        sty pl_fy
        xba
        and #$00FF
        sec
        sbc #$0080
        sta mv_dy
        sep #$20
        .LONGA OFF
        lda pl_air
        bne ?feet
        jsr locate_floor             ; cur_floor = floor under the player NOW, in
        .LONGA ON                    ;   a 16-bit A
?cf     sta cur_floor
        sep #$20
        .LONGA OFF
        ; PSTEP_MAX (24) > PLAYER_R (16): test the HALFWAY point first, which
        ; caps the largest untested gap at 12 < R
mp_slide                             ; pl_idle enters HERE (pl_kick.asm)
?slide  jsr pl_kick                  ; the shove joins the walk
        rep #$21                     ; ---- 16-bit A, C=0. THE PICKUP IS TESTED AT
        .LONGA ON                    ;   pk = pos + delta, the destination (see
        lda zp_px                    ;   the .else side and spr_pickup)
        adc mv_dx
        sta pk_x
        clc
        lda zp_py
        adc mv_dy
        sta pk_y
        lda mv_dx                    ; half = dx >> 1 (arithmetic, in A: the
        cmp #$8000                   ;   cmp puts the sign in C for the ror)
        ror @
        clc
        adc zp_px                    ; the X midpoint: (px + half, py)
        sta coll_cx
        lda zp_py
        sta coll_cy
        sep #$20
        .LONGA OFF
        jsr coll_plrs                ; midpoint blocked -> the whole X step is out
        jne ?skipx
        rep #$20                     ; --- X axis: candidate = (px+dx, py) -- px+dx
        .LONGA ON                    ;   is pk_x, and coll_cy is still py
        lda pk_x
        sta coll_cx
        sep #$20
        .LONGA OFF
        jsr coll_step_ok             ; step up > MAXSTEP? (must use stairs)
        bne ?skipx
        jsr coll_plrs                ; wall (or a too-high ledge) within radius?
        bne ?skipx                   ; blocked -> don't commit X
        lda #$FF                     ; ...and P_TryMove's other half: a monster or
        sta sol_self                 ;   a barrel standing there blocks the player
        jsr en_solid                 ;   just as a wall does (p_map.c PIT_CheckThing)
        bne ?skipx
        rep #$20
        .LONGA ON
        lda coll_cx
        sta zp_px
        sep #$20
        .LONGA OFF
?skipx  jsr skipx_ref                ; refresh cur_floor from the new stand point
        rep #$20                     ; --- Y axis: halfway point first (see above)
        .LONGA ON
        lda mv_dy
        cmp #$8000
        ror @
        clc
        adc zp_py
        sta coll_cy
        lda zp_px
        sta coll_cx
        sep #$20
        .LONGA OFF
        jsr coll_plrs
        jne ?done
        rep #$20                     ; --- Y axis: candidate = (px, py+dy) -- py+dy
        .LONGA ON                    ;   is pk_y, and coll_cx is still px
        lda pk_y
        sta coll_cy
        sep #$20
        .LONGA OFF
        jsr coll_step_ok
        bne ?done
        jsr coll_plrs
        bne ?done                    ; blocked -> don't commit Y
        lda #$FF                     ; ...and the things, as on the X axis
        sta sol_self
        jsr en_solid
        bne ?done
        rep #$20
        .LONGA ON
        lda coll_cy
        sta zp_py
        sep #$20
        .LONGA OFF
                                      ; 2026-09-22 (drac030 inline): mp_clamp
?done   lda coll_solid               ; a SHUT DOOR in the way? then pk collapses to
        jne mp_pkhere
        rts
                                     ;   where he STANDS (the .else side)
mp_nomove                            ; pl_idle falls back here
?nomove bra mp_pkhere                ; NOT moving this frame: the only point to
                                     ;   test is where he stands
.endp                                ;   runs, so the only point to test is where
        .endseg
                                     ;   he stands.

        .segment D0
pl_step dta a(0)                     ; one move_player call's distance, Q8, signed
pl_fx   dta 0, $80                   ; the player's x and y below the unit, Q8.
pl_fy   dta 0, $80                   ;   The byte above is move_player's bias
pl_acos dta a(0)                     ; the heading and the keys he last had on the
pl_asin dta a(0)                     ;   ground (plr_steps): the air keeps them --
pl_akey dta 3                        ;   DOOM's momx/momy, no thrust off the ground
pl_n    dta 0                        ; plr_steps: the calls still to make
        .endseg

pkc_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; mp_clamp / mp_pkhere -- move_player's tail. mp_pkhere: pk = where he stands.
;   mp_clamp: the same, but only when coll_seg saw a SHUT DOOR this move; else pk
;   keeps the destination it was latched with, which is what leaves an item
;   behind a window or up on a ledge reachable (spr_pickup's header: 118 of them
;   in episode 1). Both clear the flag -- one move, one answer.
;--------------------------------------------------------------
                                      ; DRAC_PLAN 5: no 8-bit window
coll_solid dta 0,0                   ; (coll_seg incs it 16-bit; readers use the low byte)
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mp_clamp
        lda coll_solid
        bne mp_pkhere
        rts
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mp_pkhere
        stz coll_solid
        rep #$20                     ; pk = where he stands: two word moves
        .LONGA ON
        lda zp_px
        sta pk_x
        lda zp_py
        sta pk_y
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org pkc_resume

;==============================================================
; FALLING (2026-08-05) -- p_mobj.c P_ZMovement's player half, plus the two
; rules in P_XYMovement / P_MovePlayer that turn a drop into an ARC.
;==============================================================
fall_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

pl_z    dta a(0)                     ; the player's FEET, world units (signed 16)
pl_mz   dta 0                        ; momz, units per frame (signed 8: walks
                                     ;   -6,-18,-30.. capped at -FALL_TERM;
                                     ;   E1's deepest ~200-unit drop = 6 frames)
pl_air  dta 0                        ; 1 = off the ground -- P_MovePlayer's
                                     ;   `onground`, inverted
pl_snap dta 1                        ; 1 = put the feet ON the floor this frame
                                     ;   and do not fall: a level start or a ...

;--------------------------------------------------------------
; pl_zfloor -- update_pz's whole head, moved here because that block is 32 B
;   and not the 48 its END claims (USE_PT starts at $E740). locate_floor, then
;   P_ZMovement, then the eye. locate_floor's zp_ptr is left alone: update_pz
;   reads the player's sector out of it for the nukage damage.
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_zfloor
        jsr locate_floor
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        sep #$20
        jsr pl_zmove
        clc
        lda pl_vh                    ; EYE_H normally; while dead P_DeathThink
        adc pl_z                     ;   walks it down to DEAD_EYE_H, which is
        sta zp_pz                    ;   the camera sinking to the floor
        lda pl_z+1
        adc #0
        sta zp_pz+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; pl_tele -- the teleport's tail (movers.asm trig_walk, which had no room):
;   the sound, and EV_Teleport's `thing->z = thing->floorz` -- he arrives
;   STANDING on the destination floor, not falling onto it -- its
;   `reactiontime = 18`, and P_TeleportMove's PIT_StompThing: every
;   shootable thing standing on the spot takes 10000 (p_map.c:105).
;   IN: zp_px/zp_py = the destination (trig_walk just put him there).
;--------------------------------------------------------------
PL_RTVB equ 26                       ; 18 tics = 25.7 VBLANKs (PAL 50 Hz)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pl_tele
        lda #SFX_TELEPT              ; DOOM plays it at BOTH ends -- the player
        sta snd_pending              ;   is at one of them, so never remote
        lda #1
        sta pl_snap
        lda #PL_RTVB                 ; "don't move for a bit" (read_input)
        sta pl_rt
?tf     lda #$FF                     ; the player's box (MK_PLRAD) at the spot:
        sta sol_self                 ;   en_solid = PIT_StompThing's overlap test
        rep #$20
        .LONGA ON
        lda zp_px
        sta coll_cx
        lda zp_py
        sta coll_cy
        .LONGA OFF
        sep #$20
        jsr en_solid
        beq ?out                     ; nothing (left) on the spot
        ldx sol_i
        lda.l MAP_EXT_BANK*$10000+TH_HPL,x
        ora.l MAP_EXT_BANK*$10000+TH_HPH,x
        beq ?out                     ; solid but not MF_SHOOTABLE (a pillar):
                                     ;   DOOM stomps nothing there either
        stx en_bi
        sec                          ; health -= 10000 here, so en_bhit's
        lda.l MAP_EXT_BANK*$10000+TH_HPL,x   ;   byte-wide damage can be 0 and
        sbc #<10000                  ;   the overkill (en_ovkill: the gib
        sta.l MAP_EXT_BANK*$10000+TH_HPL,x   ;   test) still comes out DOOM's
        lda.l MAP_EXT_BANK*$10000+TH_HPH,x
        sbc #>10000
        sta.l MAP_EXT_BANK*$10000+TH_HPH,x
        lda #0
        jsr en_bhit                  ; the death chain + the voice; a dead thing
        bra ?tf                      ;   is no longer solid, so the next pass
?out    rts                          ;   finds the one behind it, if any
.endp
        .endseg
        .segment D0
pl_rt   dta 0                        ; reactiontime, VBLANKs left (pl_tele)
        .endseg

;--------------------------------------------------------------
; pl_zmove -- P_ZMovement for the player. IN: loc_floor = the floor under him.
;   Clobbers A/X and m_a.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
OOF_MZ  equ 28                       ; P_ZMovement's "momz < -GRAVITY*8": 8 units
                                     ;   a TIC is 28 a FRAME on FALL_G's 3.5 tics
.proc pl_zmove
        lda pl_snap
        beq ?fly
        stz pl_snap                  ; a spawn or a teleport: stand him on it
        bra ?land                    ;   (past ?hit: P_Teleport zeroes momz)
?fly    rep #$20                     ; ---- 16-bit A: d = pl_z - floor, signed --
        .LONGA ON                    ;   the sbc's N and Z ARE the two tests
        sec                          ;   (sep keeps them)
        lda pl_z
        sbc loc_floor
        sep #$20
        .LONGA OFF
                                      ; the hard landing's grunt (2026-09-15)
        bmi ?hit                     ; below it -> he has arrived
        beq ?hit                     ; exactly on it -> still standing
        lda pl_mz                    ; --- airborne
        bne ?acc
        lda #-FALL_G/2               ; momz == 0: the first frame off the edge is
        bne ?put                     ;   a HALF step -- see the header (always
                                     ;   taken: FALL_G/2 is not 0)
?acc    sec
        sbc #FALL_G
        cmp #-FALL_TERM              ; terminal velocity -- and the guard that
        bcs ?put                     ;   keeps a signed byte from wrapping
        lda #-FALL_TERM              ;   positive on a very deep shaft
?put    sta pl_mz
        ldx #0                       ; pl_z += momz, sign-extended (the .else
        cmp #$80                     ;   side says why this is a CMP)
        bcc ?pos
        dex
?pos    clc
        adc pl_z
        sta pl_z
        txa
        adc pl_z+1
        sta pl_z+1
        lda #1
        sta pl_air
        rts
?hit    lda pl_mz                    ; the momentum he lands with: 0 standing,
        beq ?land                    ;   else -6..-120 ($FA..$88) -- never
        cmp #-OOF_MZ                 ;   positive, ?put only ever subtracts
        bcs ?land                    ; C=1: -28..-6, a soft landing (-18 = 24 u)
        lda #SFX_NOWAY               ; sfx_oof. DSOOF is not in the sound table
        sta snd_pending              ;   (tools/wadsound.py); the USE grunt it is
?land   rep #$20                     ; z = floorz, and the momentum goes with it
        .LONGA ON                    ;   (the .else side says why, every frame)
        lda loc_floor
        sta pl_z
        stz pl_mz                    ; ...pl_mz AND pl_air: adjacent bytes, one
        sep #$20                     ;   word stz (ert below)
        .LONGA OFF
        rts
    .if pl_air != pl_mz+1
        ert 'pl_zmove zeroes pl_mz/pl_air with one word stz -- keep them adjacent'
    .endif
.endp
        .endseg

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org fall_resume

