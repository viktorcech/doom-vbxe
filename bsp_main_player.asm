; Part of bsp_main.asm -- AUTO-SPLIT out of it 2026-08-09, assembled in place via
; icl at the exact point the text was cut from, so every org and every block
; guard below is unchanged (verified: build/doom_bsp.xex is byte-identical).
;   the frame's player half: swap_buffers, read_input, move_player and the FALL block (pl_zfloor/pl_tele/pl_zmove/pl_airmove/pl_latch)
;==============================================================
; Input + movement (free movement; collision is a later milestone)
;==============================================================
; Read the HARDWARE joystick (PIA PORTA) directly, not the $0278 OS shadow: the
; shadow is refreshed by the deferred VBI, which the OS skips while we run under
; SEI -> the shadow would never update. PORTA low nibble = stick 0, same bit
; layout (active low: b0=up b1=down b2=left b3=right). (2026-06-03)
STICK0   equ $D300            ; PIA PORTA (joystick 0 in low nibble)
; TURN/SPD are the fixed per-frame amounts again (memory_map.inc, stored into
; PLR_STEP/TRN_STEP by plr_steps): the 2026-07-28 dt_vbl time scaling was
; reverted the same day -- several times too fast in play, and the halfway
; collision probe in move_player assumes a step <= 24.

;--------------------------------------------------------------
; swap_buffers -- wait VBLANK, display the just-rendered buffer, flip back.
;   (OS VBI ticks RTCLOK3; main enables NMIEN=$40 before the loop.)
;--------------------------------------------------------------
.proc swap_buffers
        jsr blitter_wait             ; async blitter: ensure the frame's LAST blit
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
xdt_resume = *
        org XDLTAB_BASE              ; the two 8-entry flip maps, indexed by
xdl_hi  dta >VRAM_XDL_A, >VRAM_XDL_B, 0, 0, 0, 0, 0, >VRAM_XDL_C
znext   dta $01, $07, 0, 0, 0, 0, 0, $00     ; zback_hi: $00 -> $01 -> $07 -> $00
        org xdt_resume

;--------------------------------------------------------------
; read_input -- snapshot STICK0; apply rotation to zp_ang.
;--------------------------------------------------------------
.proc read_input
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
.endp

;--------------------------------------------------------------
; move_player -- forward/back along facing (uses zp_sin/zp_cos), with wall
;   collision. DOOM-style X-then-Y slide: each axis commits only if the
;   candidate stays clear of walls (collide_blocked), so the player slides along
;   a wall instead of passing through it. coll_cx/coll_cy (= zp_rx/zp_ry) carry
;   the tested point into collide_blocked.
;--------------------------------------------------------------
.proc move_player
        lda pl_dead                  ; a corpse does not walk (P_DeathThink runs
        bne ?dead                    ;   instead of P_MovePlayer)
        jsr pl_airmove               ; airborne? then the keys do nothing and the
        bcs ?slide                   ;   momentum carries (P_MovePlayer/onground)
        lda stick_save
        and #$03                     ; up or down pressed? (both 1 = neither)
        cmp #$03
        bne ?go
?dead   jmp pl_idle                  ; a shove may still be running                  ; (3 B, exactly the `jmp ?done` that was here:
                                     ;  the pk_x tail below must NOT grow this
                                     ;  path, ?slide is a bcs away at line 79)
?go     lda PLR_STEP                 ; dx = step*cos>>14 (step = SPD, fixed per
        sta m_a                      ;   frame -- see plr_steps)
        lda #0
        sta m_a+1
        lda zp_cos
        sta m_b
        lda zp_cos+1
        sta m_b+1
        jsr smul_14
        lda m_res
        sta mv_dx
        lda m_res+1
        sta mv_dx+1
        lda PLR_STEP                 ; dy = step*sin>>14 (m_a+1 stayed 0: the
        sta m_a                      ;   magnitude never overflows a byte)
        lda zp_sin
        sta m_b
        lda zp_sin+1
        sta m_b+1
        jsr smul_14
        lda m_res
        sta mv_dy
        lda m_res+1
        sta mv_dy+1
        jsr locate_floor             ; cur_floor = floor under the player NOW -- compute
        lda loc_floor                ;   BEFORE the fwd/back branch so BOTH paths set it.
        sta cur_floor                ;   (forward used to skip it -> stale ref -> stuck on
        lda loc_floor+1              ;    stairs ~step 3-4 once dest-stale exceeded MAXSTEP)
        sta cur_floor+1
        lda stick_save
        and #$01                     ; forward? (bit0 clear = pressed)
        beq ?slide
        ; NO "back?" test here, and none is needed: ?go is only reached when
        ; (stick_save & 3) != 3, so once the forward bit is SET the back bit is
        ; necessarily CLEAR and this path is always the backward one. What stood
        ; here was `lda stick_save / and #$02 / beq ?neg / jmp ?nomove` -- the jmp
        ; unreachable (the author's own comment said so) and the branch therefore
        ; always taken, i.e. 9 bytes that could only fall through to ?neg.
        ; IF THE (stick & 3) != 3 GATE ABOVE EVER CHANGES, the test comes back.
?neg    ldx #2                       ; back: negate the move delta -- both axes in
?ngl    sec                          ;   ONE loop over the two adjacent words
        lda #0                       ;   (mv_dx, mv_dy). 19 B against 26 straight
        sbc mv_dx,x                  ;   line, and the 7 B are what buys the
        sta mv_dx,x                  ;   pk_x/pk_y latch below -- this segment
        lda #0                       ;   ends flush at MNKEY_BASE ($25A1).
        sbc mv_dx+1,x
        sta mv_dx+1,x
        dex
        dex
        bpl ?ngl
        ; SPD (24) is larger than PLAYER_R (16), so one step can clear a wall in a
        ; single jump: both the start and the destination end up further than R
        ; from every seg and nothing blocks. Test the HALFWAY point first -- that
        ; caps the largest untested gap at 12 < R, which makes stepping through a
        ; wall geometrically impossible. It bites at corners, where the player can
        ; round a vertex diagonally and land outside both segs' radius.
mp_slide                             ; pl_idle enters HERE (pl_kick.asm)
?slide  jsr pl_kick                  ; the shove joins the walk, then pl_latch                 ; ...and this is the momentum he would leave
                                     ;   the next ledge with
        ldx #2                       ; AND THIS IS THE POINT THE PICKUP IS TESTED
?pkl    clc                          ;   AT: pk = pos + delta, the destination --
        lda zp_px,x                  ;   NOT wherever the gates below let him
        adc mv_dx,x                  ;   stop. p_map.c takes items inside
        sta pk_x,x                   ;   P_CheckPosition(x,y), the FIRST thing
        lda zp_px+1,x                ;   P_TryMove does; its step-up and fit
        adc mv_dx+1,x                ;   rejections all come after, so a REFUSED
        sta pk_x+1,x                 ;   move still picks up (see spr_pickup).
        dex                          ;   zp_px is still the pre-move position
        dex                          ;   here -- the X commit is at ?xfull below
        bpl ?pkl                     ;   -- and zp_px..zp_py / mv_dx..mv_dy /
                                     ;   pk_x..pk_y are three pairs of adjacent
                                     ;   words, so X = 2 then 0 does both axes.
        lda mv_dx+1                  ; half = dx >> 1 (arithmetic, keeps the sign)
        cmp #$80                     ; C = sign bit of the high byte
        ror                          ; ... into A, NOT into m_a+1: rotating the
        sta m_a+1                    ; MEMORY shifted whatever was left there and
        lda mv_dx                    ; fed its bit0 into the low byte. It only ever
        ror                          ; looked right because locate_floor happened to
        sta m_a                      ; leave m_a+1 = 0 (it read a u16 sector id whose
                                     ; high byte is always 0). The packed v3 seg
                                     ; record made that id a BYTE, locate_floor stopped
                                     ; writing m_a+1, and the halfway probe point went
                                     ; wild -> collide_blocked said "blocked" in open
                                     ; space = the invisible wall.
        clc
        lda zp_px
        adc m_a
        sta coll_cx
        lda zp_px+1
        adc m_a+1
        sta coll_cx+1
        lda zp_py
        sta coll_cy
        lda zp_py+1
        sta coll_cy+1
        jsr coll_plr                 ; midpoint blocked -> the whole X step is out
        beq ?xfull
        jmp ?skipx
?xfull  lda pk_x                     ; --- X axis: candidate = (px+dx, py) --- and
        sta coll_cx                  ;   px+dx is pk_x, already added above
        lda pk_x+1
        sta coll_cx+1
        lda zp_py
        sta coll_cy
        lda zp_py+1
        sta coll_cy+1
        jsr coll_step_ok             ; step up > MAXSTEP? (must use stairs)
        bne ?skipx
        jsr coll_plr                 ; wall within radius?
        bne ?skipx                   ; blocked -> don't commit X
        lda #$FF                     ; ...and P_TryMove's other half: a monster or
        sta sol_self                 ;   a barrel standing there blocks the player
        jsr en_solid                 ;   just as a wall does (p_map.c PIT_CheckThing)
        bne ?skipx
        lda coll_cx
        sta zp_px
        lda coll_cx+1
        sta zp_px+1
?skipx  jsr skipx_ref                ; refresh cur_floor from the new stand point
                                     ;   (stairs) -- but NOT while airborne, where
                                     ;   the reference is his FEET (pl_airmove) and
                                     ;   a horizontal step never moves them
        lda mv_dy+1                  ; --- Y axis: halfway point first (see above)
        cmp #$80                     ; (same arithmetic-shift fix as the X axis)
        ror
        sta m_a+1
        lda mv_dy
        ror
        sta m_a
        lda zp_px
        sta coll_cx
        lda zp_px+1
        sta coll_cx+1
        clc
        lda zp_py
        adc m_a
        sta coll_cy
        lda zp_py+1
        adc m_a+1
        sta coll_cy+1
        jsr coll_plr       
        beq ?yfull
        jmp ?done
?yfull  lda zp_px                    ; --- Y axis: candidate = (px, py+dy) ---
        sta coll_cx                  ;   ...and py+dy is pk_y (the X commit does
        lda zp_px+1                  ;   not touch it)
        sta coll_cx+1
        lda pk_y
        sta coll_cy
        lda pk_y+1
        sta coll_cy+1
        jsr coll_step_ok
        bne ?done
        jsr coll_plr       
        bne ?done                    ; blocked -> don't commit Y
        lda #$FF                     ; ...and the things, as on the X axis
        sta sol_self
        jsr en_solid
        bne ?done
        lda coll_cy
        sta zp_py
        lda coll_cy+1
        sta zp_py+1
?done   jmp mp_clamp                 ; a SHUT DOOR in the way? then pk collapses to
                                     ;   where he STANDS. Without it the 24-unit
                                     ;   step reached 24 units past the door and
                                     ;   E2M9's key skulls -- 32 behind theirs --
                                     ;   came off the far side. A window or a ledge
                                     ;   does NOT clamp: that reach is the whole
                                     ;   point of the pk latch below.
mp_nomove                            ; pl_idle falls back here
?nomove jmp mp_pkhere                ; NOT moving this frame: P_XYMovement never
.endp                                ;   runs, so the only point to test is where
                                     ;   he stands. The loop that did it moved to
                                     ;   PKCLAMP_BASE beside mp_clamp -- those nine
                                     ;   bytes are what pay for the jmp above.

pkc_resume = *
        org PKCLAMP_BASE
;--------------------------------------------------------------
; mp_clamp / mp_pkhere -- move_player's tail. mp_pkhere: pk = where he stands.
;   mp_clamp: the same, but only when coll_seg saw a SHUT DOOR this move; else pk
;   keeps the destination it was latched with, which is what leaves an item
;   behind a window or up on a ledge reachable (spr_pickup's header: 118 of them
;   in episode 1). Both clear the flag -- one move, one answer.
;--------------------------------------------------------------
coll_solid dta 0                     ; set by coll_seg on an opening of exactly 0
.proc mp_clamp
        lda coll_solid
        bne mp_pkhere
        rts
.endp
.proc mp_pkhere
        stz coll_solid
        ldx #3
?l      lda zp_px,x
        sta pk_x,x
        dex
        bpl ?l
        rts
.endp
    .if * > PKCLAMP_END+1
        ert 'mp_clamp/mp_pkhere outgrew PKCLAMP_BASE..END (memory_map.inc)'
    .endif
        org pkc_resume

;==============================================================
; FALLING (2026-08-05) -- p_mobj.c P_ZMovement's player half, plus the two
; rules in P_XYMovement / P_MovePlayer that turn a drop into an ARC.
;
; What was here before: update_pz did `zp_pz = floor(px,py) + EYE_H` every
; frame. The eye was NAILED to the floor, so walking off a ledge teleported it
; down the moment the foot crossed the edge -- no flight, no acceleration.
;
; DOOM does three things, and it needs all three:
;   p_mobj.c  P_ZMovement   if (mo->momz == 0) mo->momz = -GRAVITY*2;
;                           else               mo->momz -= GRAVITY;
;                           -- the first step off is already -2, then -3, -4.
;                           The port starts at -FALL_G/2, NOT the literal *2:
;                           a frame is ~3.5 tics, vanilla adds z BEFORE the
;                           gravity update (tic one drops nothing), so DOOM's
;                           wall-clock drop after n frames is ~6n^2+5n -- and
;                           the half-step start -6,-18,-30.. integrates to
;                           exactly that (leapfrog). The literal -2*FALL_G
;                           overshot the first frame 3x and cut every run-jump
;                           one ledge short (2026-08-10).
;   p_mobj.c  P_XYMovement  if (mo->z > mo->floorz) return;
;                           -- "no friction when airborne": the horizontal
;                              speed you left with is the speed you keep
;   p_user.c  P_MovePlayer  onground = (mo->z <= mo->floorz);
;                           -- and no thrust while airborne, so the keys do
;                              nothing until you land
; Together: constant horizontal speed, accelerating downward = a parabola.
;
; The player's FEET live in pl_z now; zp_pz is pl_z + pl_vh, so the view height
; (and P_DeathThink's sink) still ride on top of it unchanged.
;
; NOT DOOM yet, both cheap, both said out loud rather than smuggled:
;   * no landing squat. P_ZMovement sets deltaviewheight = momz>>3 on a hard
;     landing and P_CalcHeight walks it back; pl_vh is already shared with the
;     death camera, so that wants state of its own.
;   * no sfx_oof: this build's sound table has no such id (tools/wadsound.py).
;==============================================================
fall_resume = *
        org FALL_BASE

pl_z    dta a(0)                     ; the player's FEET, world units (signed 16)
pl_mz   dta 0                        ; momz, units per frame (signed 8: walks
                                     ;   -6,-18,-30.. capped at -FALL_TERM;
                                     ;   E1's deepest ~200-unit drop = 6 frames)
pl_air  dta 0                        ; 1 = off the ground -- P_MovePlayer's
                                     ;   `onground`, inverted
pl_snap dta 1                        ; 1 = put the feet ON the floor this frame
                                     ;   and do not fall: a level start or a
                                     ;   teleport, where DOOM assigns
                                     ;   thing->z = thing->floorz outright
pl_adx  dta a(0)                     ; the momentum the ledge was left with --
pl_ady  dta a(0)                     ;   world space, so turning in mid-air does
                                     ;   not steer it (DOOM's momx/momy)

;--------------------------------------------------------------
; pl_zfloor -- update_pz's whole head, moved here because that block is 32 B
;   and not the 48 its END claims (USE_PT starts at $E740). locate_floor, then
;   P_ZMovement, then the eye. locate_floor's zp_ptr is left alone: update_pz
;   reads the player's sector out of it for the nukage damage.
;--------------------------------------------------------------
.proc pl_zfloor
        jsr locate_floor
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

;--------------------------------------------------------------
; pl_tele -- the teleport's tail (movers.asm trig_walk, which had no room):
;   the sound, and P_Teleport's `thing->z = thing->floorz` -- he arrives
;   STANDING on the destination floor, not falling onto it.
;--------------------------------------------------------------
.proc pl_tele
        lda #SFX_TELEPT              ; DOOM plays it at BOTH ends -- the player
        sta snd_pending              ;   is at one of them, so never remote
        lda #1
        sta pl_snap
        rts
.endp

;--------------------------------------------------------------
; pl_zmove -- P_ZMovement for the player. IN: loc_floor = the floor under him.
;   Clobbers A/X and m_a.
;--------------------------------------------------------------
.proc pl_zmove
        lda pl_snap
        beq ?fly
        lda #0                       ; a spawn or a teleport: stand him on it
        sta pl_snap
        beq ?land                    ; (always)
?fly    sec                          ; d = pl_z - floor, signed 16
        lda pl_z
        sbc loc_floor
        sta m_a
        lda pl_z+1
        sbc loc_floor+1
        bmi ?land                    ; below it -> he has arrived
        ora m_a
        beq ?land                    ; exactly on it -> still standing
        lda pl_mz                    ; --- airborne
        bne ?acc
        lda #-FALL_G/2               ; momz == 0: the first frame off the edge is
        bne ?put                     ;   a HALF step -- see the header. (always
                                     ;   taken: FALL_G/2 is not 0)
?acc    sec
        sbc #FALL_G
        cmp #-FALL_TERM              ; terminal velocity -- and the guard that
        bcs ?put                     ;   keeps a signed byte from wrapping
        lda #-FALL_TERM              ;   positive on a very deep shaft
?put    sta pl_mz
        ldx #0                       ; pl_z += momz, sign-extended. The sign test
        cmp #$80                     ;   is a CMP and not the BPL it started as:
        bcc ?pos                     ;   `ldx #0` sets N itself, so the BPL was
        dex                          ;   reading the LDX and always taking the
?pos    clc                          ;   positive arm -- feet += 254 a frame.
        adc pl_z
        sta pl_z
        txa
        adc pl_z+1
        sta pl_z+1
        lda #1
        sta pl_air
        rts
?land   lda loc_floor                ; z = floorz
        sta pl_z
        lda loc_floor+1
        sta pl_z+1
        lda #0
        sta pl_mz
        sta pl_air
        sta pl_adx                   ; ...and the momentum goes with it. Standing
        sta pl_adx+1                 ;   still runs THIS branch every frame, so a
        sta pl_ady                   ;   floor that sinks away under a motionless
        sta pl_ady+1                 ;   player drops him straight down instead of
        rts                          ;   sideways on whatever he last walked at.
.endp                                ;   move_player latches the live delta again
                                     ;   BEFORE update_pz runs, so the frame he
                                     ;   actually steps off a ledge keeps its own.

;--------------------------------------------------------------
; pl_airmove -- move_player's first question. C=1 = he is airborne, and mv_dx/
;   mv_dy + cur_floor are already filled in for the commit path: the keys are
;   ignored (P_MovePlayer) and the momentum is unchanged (no air friction).
;   C=0 = on the ground, carry on reading the stick.
;--------------------------------------------------------------
.proc pl_airmove
        lda pl_air
        beq ?ground
        lda pl_adx
        sta mv_dx
        lda pl_adx+1
        sta mv_dx+1
        lda pl_ady
        sta mv_dy
        lda pl_ady+1
        sta mv_dy+1
        lda pl_z                     ; the step-up reference is his FEET, not the
        sta cur_floor                ;   floor below him: P_TryMove measures
        lda pl_z+1                   ;   tmfloorz - mo->z. Referencing the pit
        sta cur_floor+1              ;   bottom made every far-side ledge a step
        sec                          ;   >MAXSTEP and no run-jump could ever land
        rts                          ;   (2026-08-10).
?ground clc
        rts
.endp

;--------------------------------------------------------------
; pl_latch -- remember this frame's ground momentum, so the frame he steps off
;   the edge carries it into the air. Called with mv_dx/mv_dy final.
;--------------------------------------------------------------
.proc pl_latch
        lda mv_dx
        sta pl_adx
        lda mv_dx+1
        sta pl_adx+1
        lda mv_dy
        sta pl_ady
        lda mv_dy+1
        sta pl_ady+1
        rts
.endp

; (skipx_ref used to sit here and pushed the block past FALL_END -- it is
;  parked in plr_steps' PSTEP block now, doors.asm.)
    .if * > FALL_END+1
        ert 'the fall code outgrew FALL_BASE..FALL_END (memory_map.inc)'
    .endif
        org fall_resume

