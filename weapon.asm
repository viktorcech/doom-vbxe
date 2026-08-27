;==============================================================
; weapon.asm -- the player's weapon: DOOM's psprite state machine (p_pspr.c)
;--------------------------------------------------------------
; What it is, and what it is not
;   DOOM does not put the gun in the world. It keeps two "player sprites" --
;   ps_weapon and ps_flash -- each with its own state, tic counter and screen
;   offset (psp->sx/sy), and R_DrawPSprite paints them over the finished 3D view.
;   This file is that machine: the SAME states from info.c, the SAME tic
;   durations, the SAME raise/lower/bob arithmetic. What it does NOT do is the
;   hitscan (A_GunShot -> P_LineAttack): there is nothing to shoot at yet, so
;   firing spends ammo, animates, flashes and sounds, and no bullet travels.
;
; Timing -- why the machine is ticked, not stepped once per frame
;   DOOM runs psprites at 35 Hz. This port's frame rate is 3-10 fps, so stepping
;   one state per frame would stretch a 4-tic muzzle flash over a second. Instead
;   wp_think turns the frame's VBLANKs (fps_n, from frame_dt) into DOOM TICS
;   (TIC_Q8 = 35/50 in Q8, remainder carried in wp_tacc) and runs the machine that
;   many times -- so every duration in the table below is DOOM's own number and
;   the animation is right on a stock 800XL and on a Rapidus alike. Same model
;   the doors and the lifts already use.
;
; ENTERING a state is what runs its action -- P_SetPsprite, not the tic countdown:
;   states with 0 tics fall straight through to the next one, and an action that
;   sets a new state (A_WeaponReady -> downstate, A_Raise -> readystate,
;   P_FireWeapon -> atkstate) enters it in the SAME tic. That is why the chaingun
;   fires the moment its atkstate is reached and why the trigger has DOOM's 4-tic
;   delay and not a state's worth of extra lag. wp_enter is that do-while loop;
;   it is re-entrant (the hop guard and the state id ride the stack), because an
;   action legitimately calls it again.
;
; Drawing
;   Every frame's screen position is precomputed by tools/pack_weap.py, so
;   draw_weapon only adds the live offsets (the raise/lower slide sy-WEAPONTOP,
;   and the sway if WP_SWAY is on), scales the frame with the view window and
;   clips it to that window -- one BLT_BSTENCIL rectangle, index 0 transparent.
;   The flash goes down after the gun, exactly like R_DrawPlayerSprites' psprite
;   order. See the block comment above draw_weapon for the scale and the clip.
;==============================================================

; ---- state table indices (mirrors info.c; see WS_FRM/DUR/ACT/NXT below) ------
WS_NULL       equ 0                  ; S_NULL: nothing drawn (the idle flash)
WS_PUNCH      equ 1                  ; fist
WS_PUNCHDOWN  equ 2
WS_PUNCHUP    equ 3
WS_PUNCH1     equ 4
WS_PUNCH2     equ 5
WS_PUNCH3     equ 6
WS_PUNCH4     equ 7
WS_PUNCH5     equ 8
WS_PISTOL     equ 9                  ; pistol
WS_PISTOLDOWN equ 10
WS_PISTOLUP   equ 11
WS_PISTOL1    equ 12
WS_PISTOL2    equ 13
WS_PISTOL3    equ 14
WS_PISTOL4    equ 15
WS_PISFLASH   equ 16
WS_SGUN       equ 17                 ; shotgun
WS_SGUNDOWN   equ 18
WS_SGUNUP     equ 19
WS_SGUN1      equ 20
WS_SGUN2      equ 21
WS_SGUN3      equ 22
WS_SGUN4      equ 23
WS_SGUN5      equ 24
WS_SGUN6      equ 25
WS_SGUN7      equ 26
WS_SGUN8      equ 27
WS_SGUN9      equ 28
WS_SGFLASH1   equ 29
WS_SGFLASH2   equ 30
WS_CHAIN      equ 31                 ; chaingun
WS_CHAINDOWN  equ 32
WS_CHAINUP    equ 33
WS_CHAIN1     equ 34
WS_CHAIN2     equ 35
WS_CHAIN3     equ 36
WS_CHFLASH1   equ 37
WS_CHFLASH2   equ 38
; 2026-07-30 -- the chainsaw and the rocket launcher. Straight out of info.c
; (tools/doomstates.py prints the chains): same frames, same tics, same actions.
WS_SAW        equ 39                 ; chainsaw. S_SAW/S_SAWB are the IDLE PAIR:
WS_SAWB       equ 40                 ;   A_WeaponReady alternates SAWG C and D at
WS_SAWDOWN    equ 41                 ;   4 tics, which is the saw idling in DOOM
WS_SAWUP      equ 42                 ;   (every other weapon idles on one frame)
WS_SAW1       equ 43
WS_SAW2       equ 44
WS_SAW3       equ 45
WS_MISSILE    equ 46                 ; rocket launcher
WS_MISSILEDOWN equ 47
WS_MISSILEUP  equ 48
WS_MISSILE1   equ 49                 ; MISG B 8 A_GunFlash -- the flash comes up
WS_MISSILE2   equ 50                 ;   BEFORE the shot, unlike every other gun
WS_MISSILE3   equ 51
WS_MISFLASH1  equ 52
WS_MISFLASH2  equ 53
WS_MISFLASH3  equ 54
WS_MISFLASH4  equ 55
WS_PLASMA     equ 56                 ; plasma rifle
WS_PLASMADOWN equ 57
WS_PLASMAUP   equ 58
WS_PLASMA1    equ 59
WS_PLASMA2    equ 60
WS_PLSFLASH1  equ 61                 ; A_FirePlasma picks between the two AT
WS_PLSFLASH2  equ 62                 ;   RANDOM (p_pspr.c), unlike the chaingun

; ---- action codes (the {A_*} column of info.c) -------------------------------
WA_NONE       equ 0
WA_READY      equ 1                  ; A_WeaponReady
WA_LOWER      equ 2                  ; A_Lower
WA_RAISE      equ 3                  ; A_Raise
WA_FIRE       equ 4                  ; A_FirePistol / A_FireShotgun / A_FireCGun
WA_PUNCH      equ 5                  ; A_Punch (melee: needs monsters, so silent)
WA_REFIRE     equ 6                  ; A_ReFire
WA_GUNFLASH   equ 7                  ; A_GunFlash: light the flash psprite WITHOUT
                                     ;   firing (S_MISSILE1, and S_BFG2 later)
WP_HOPS       equ 8                  ; zero-tic states chained in one go, cap

        org WEAPON_BASE

;--------------------------------------------------------------
; wp_init -- P_SetupLevel's weapon half: the READY weapon, already up (a level
;   start is not a weapon change, so no raise animation). From init_level.
;   DOOM's P_SetupPsprites brings up player->readyweapon, and readyweapon SURVIVES
;   the exit: G_PlayerFinishLevel drops the powers and the cards and nothing else.
;   So this does not re-arm the pistol -- it keeps wp_cur and just looks up that
;   weapon's readystate. load_things seeds wp_cur = WP_PISTOL at BOOT (once), which
;   is what makes the very first level start with DOOM's kit.
;   2026-08-03: MOVED to the WPWLOAD block ($8500) with wp_wload -- it is cold
;   (once per level) and the packed $F280 block needed the bytes for the
;   weapon-switch copy hook in wp_lower.
;--------------------------------------------------------------
wpi_resume = *
        org WPWLOAD_BASE
.proc wp_init
        lda wp_cur                   ; the ready weapon's frames must be IN the
        jsr wp_wload                 ;   VRAM slot before its first draw -- at
                                     ;   boot the slot is empty (the master goes
                                     ;   to Rapidus SRAM, WEAP_EXT)
        ldx wp_cur
        lda wi_rdy,x
        sta wp_state
        lda #WP_NONE
        sta wp_pending
        lda #1
        sta wp_stic
        lda #WEAPONTOP
        sta wp_sy
        lda #WS_NULL
        sta wp_fstate
        sta wp_ftic
        sta wp_bob
        sta wp_phase
        sta wp_bx
        sta wp_by
        sta wp_down
        sta wp_refire
        sta wp_tacc
        sta wp_flip
        rts
.endp

;--------------------------------------------------------------
; wp_wload -- A = weapon id (WP_*): make that weapon's psprite frames resident
;   in the VRAM slot (WEAP_SLOT), copying its whole run (gun + flash frames,
;   contiguous by pack_weap.py) from the Rapidus SRAM master (WEAP_EXT) through
;   the MEMAC-A window. Worst case is the shotgun: 83 pages ~= 21 KB ~= 15 ms
;   on the slow VBXE bus -- hidden inside the raise animation (16 tics), and
;   the one tic that runs it draws nothing anyway: every rest frame is fully
;   clipped at WEAPONBOTTOM (fully lowered = invisible, like DOOM).
;   SAFE HERE because wp_think runs before render_world and the previous
;   frame's last blit was waited out by swap_buffers -- the blitter is idle,
;   so the MEMAC bank can be borrowed and handed back. The sound IRQ reads
;   samples with lda.l (no MEMW), so it may interrupt the copy freely.
;   Uses zp_ptr as the 24-bit source (read_ext's pattern: [zp],y works in
;   emulation mode) and zp_tsrc as the window cursor -- both are loader/frame
;   scratch, nothing holds them live across wp_think.
;--------------------------------------------------------------
.proc wp_wload
        cmp wp_wldd
        bne ?go
        rts                          ; already resident
?go     sta wp_wldd
        tax
        lda wpl_sl,x                 ; 24-bit source = this weapon's SRAM run
        sta zp_ptr
        lda wpl_sm,x
        sta zp_ptr+1
        lda wpl_sb,x
        sta zp_ptr+2
        lda wpl_np,x                 ; 256-byte pages to move
        sta wp_wn
        lda #<MEMW
        sta zp_tsrc
        lda #>MEMW
        sta zp_tsrc+1
        lda #BANK_EN | WEAP_SLOT_BK0
        sta wp_wbk
        sta VBXE_BANK_SEL
?page   ldy #0
?b      lda [zp_ptr],y
        sta (zp_tsrc),y
        iny
        bne ?b
        inc zp_ptr+1
        bne ?ns
        inc zp_ptr+2                 ; the run crossed a 64 KB SRAM bank
?ns     inc zp_tsrc+1
        lda zp_tsrc+1
        cmp #>(MEMW+$1000)
        bne ?nw
        lda #>MEMW                   ; window filled: next VBXE 4 KB bank
        sta zp_tsrc+1
        inc wp_wbk
        lda wp_wbk
        sta VBXE_BANK_SEL
?nw     dec wp_wn
        bne ?page
        lda #BANK_EN | BANK_OVERHEAD ; hand the window back to the XDL/BCB bank
        sta VBXE_BANK_SEL
        lda #MAP_EXT_BANK            ; and PARK zp_ptr+2 back on bank $01: the
        sta zp_ptr+2                 ;   whole engine treats it as a constant
                                     ;   (init_level seeds it ONCE -- seg_draw,
                                     ;   enemy*, infight, collision all read
                                     ;   [zp_ptr],y assuming it). Leaving $04/$05
                                     ;   here made the AI chew weapon pixels as
                                     ;   monster state from the first weapon
                                     ;   switch on: random grunts + a stuttering
                                     ;   frame loop, picture mostly intact.
        rts
.endp
wp_wldd dta $FF                      ; weapon resident in the slot ($FF = none;
                                     ;   survives level loads -- nothing else
                                     ;   writes $071000-$076FFF)
wp_wn   dta 0
wp_wbk  dta 0
wpl_sl  dta <WPL_SRC0,<WPL_SRC1,<WPL_SRC2,<WPL_SRC3
        dta <WPL_SRC4,<WPL_SRC5,<WPL_SRC6,<WPL_SRC7
wpl_sm  dta >WPL_SRC0,>WPL_SRC1,>WPL_SRC2,>WPL_SRC3
        dta >WPL_SRC4,>WPL_SRC5,>WPL_SRC6,>WPL_SRC7
wpl_sb  dta [WPL_SRC0>>16],[WPL_SRC1>>16],[WPL_SRC2>>16],[WPL_SRC3>>16]
        dta [WPL_SRC4>>16],[WPL_SRC5>>16],[WPL_SRC6>>16],[WPL_SRC7>>16]
wpl_np  dta WPL_NPG0,WPL_NPG1,WPL_NPG2,WPL_NPG3
        dta WPL_NPG4,WPL_NPG5,WPL_NPG6,WPL_NPG7
    .if * > WPWLOAD_END+1
        ert 'wp_init/wp_wload outgrew WPWLOAD_BASE..END (memory_map.inc)'
    .endif
        org wpi_resume

;--------------------------------------------------------------
; wp_think -- once per frame, from the main loop after move_player + frame_dt.
;   Converts this frame's VBLANKs into DOOM tics and runs the machine that often.
;--------------------------------------------------------------
.proc wp_think
        lda fps_n
        beq ?none                    ; same VBLANK as the last frame: no tic
        sta m_a                      ; m_b:m_a = fps_n * TIC_Q8 -- the canonical
        lda #0                       ;   shift-add (see the note in wp_scale:
        sta m_b                      ;   ONE shift of the multiplier per pass,
        lsr m_a                      ;   the `ror m_a` at the bottom, so the
        ldx #8                       ;   first bit is shifted out up here)
?mul    bcc ?nadd
        clc
        lda m_b
        adc #TIC_Q8
        sta m_b
?nadd   ror m_b
        ror m_a
        dex
        bne ?mul
        clc                          ; carry the Q8 fraction to the next frame
        lda m_a
        adc wp_tacc
        sta wp_tacc
        lda m_b
        adc #0
        cmp #TIC_MAX+1               ; a level-load hitch must not spin the machine
        bcc ?ok
        lda #TIC_MAX
?ok     sta wp_tics
        cmp #0                       ; STA sets no flags: without this the Z here
        beq ?none                    ;   came from the CMP above (never equal, by
                                     ;   construction), so a frame that earned
                                     ;   ZERO tics fell into ?tic and the dec/bne
                                     ;   ran it 256 times. Invisible until now
                                     ;   because the old test probed wp_phase,
                                     ;   which 256 tics advance by 256*4 = 0 mod
                                     ;   256. It needs fps_n = 1, i.e. a frame
                                     ;   that took a single VBLANK -- reachable on
                                     ;   a Rapidus with the view window small.
?tic    jsr wp_tic
        jsr en_tick                  ; the same DOOM tic drives the death frames
        jsr en_slide                 ;   (enemy.asm), P_XYMovement's friction on
        jsr ai_tick                  ;   a corpse a blast pushed (enemy_ai.asm),
        jsr pl_dthink                ;   the monsters' RUN states, and the dead
        dec wp_tics                  ;   view falling -- one clock, one rate
        bne ?tic
?none   rts
.endp

;--------------------------------------------------------------
; wp_tic -- ONE DOOM tic: P_MovePsprites over both psprites, plus the bob ramp.
;--------------------------------------------------------------
.proc wp_tic
        jsr pw_tic                   ; P_PlayerThink's tail: the POWERS count down
                                     ;   one per tic and pw_tic passes the call on
                                     ;   to fl_tic (the palette-flash counters) --
                                     ;   this is the port's only 35 Hz clock, and
                                     ;   the flash block has no byte left for a
                                     ;   second jsr of its own
    .if WP_SWAY
        jsr wp_bobcalc               ; the bob ramp only feeds the sway
    .endif
        lda wp_state                 ; --- ps_weapon ---
        beq ?flash                   ; WS_NULL: nothing in hand (never, in play)
        lda wp_stic
        beq ?expire                  ; a 0-tic state that ran out of hops
        dec wp_stic
        bne ?flash
?expire ldy wp_state
        lda WS_NXT,y
        jsr wp_enter
?flash  lda wp_ftic                  ; --- ps_flash (no actions, only links) ---
        beq ?done
        dec wp_ftic
        bne ?done
        ldy wp_fstate
        lda WS_NXT,y
        jmp wp_fenter
?done   rts
.endp

;--------------------------------------------------------------
; wp_fenter -- P_SetPsprite for ps_flash. Flash states carry no actions and no
;   zero-tic links, so it is just "set state, take its tics" (WS_NULL -> 0 tics,
;   which parks it: wp_tic's `beq` above then leaves it alone).
;--------------------------------------------------------------
wpf_resume = *
        org WPFEN_BASE
.proc wp_fenter
        sta wp_fstate
        tay
        lda WS_DUR,y
        sta wp_ftic
        rts
.endp

;--------------------------------------------------------------
; wp_firewep -- P_FireWeapon: ammo, then the weapon's atkstate. (The mobj state
;   change waits for the monsters; P_NoiseAlert is one block down in wp_fire_a,
;   which is the only place with the bytes for it -- same shot either way.)
;   Parked out here with wp_fenter: the plasma rifle's states needed the block
;   back.
;--------------------------------------------------------------
.proc wp_firewep
        jsr wp_checkammo
        bcc ?no                      ; dry -> wp_checkammo queued a switch
        ldx wp_cur
        lda wi_atk,x
        jmp wp_enter
?no     rts
.endp
    .if * > WPFEN_END+1
        ert 'wp_fenter/wp_firewep outgrew WPFEN_BASE..END (memory_map.inc)'
    .endif
        org wpf_resume

;--------------------------------------------------------------
; wp_enter -- P_SetPsprite for ps_weapon: enter state A, take its tics, run its
;   action, and keep going while the state has 0 tics. Re-entrant: an action may
;   call it again (A_WeaponReady -> downstate etc.), so the hop counter and the
;   state we entered ride the stack instead of a register or a scratch byte.
;--------------------------------------------------------------
.proc wp_enter
        ldx #WP_HOPS
?hop    cmp #WS_NULL
        beq ?null
        sta wp_state
        tay
        lda WS_DUR,y
        sta wp_stic
        lda WS_ACT,y
        beq ?tics                    ; WA_NONE
        txa                          ; [hops]
        pha
        tya                          ; [hops][state]
        pha
        jsr wp_action                ; Y = the state entered; may re-enter
        pla
        tay
        pla
        tax
        cpy wp_state
        bne ?out                     ; the action moved on: it set the tics
?tics   lda wp_stic
        bne ?out
        ldy wp_state                 ; 0 tics -> fall straight through
        lda WS_NXT,y
        dex
        bne ?hop
?out    rts
?null   sta wp_state
        sta wp_stic
        rts
.endp

;--------------------------------------------------------------
; wp_action -- run state Y's action. Y is the state id; the caller re-reads it
;   from the stack afterwards, so nothing here has to preserve it.
;--------------------------------------------------------------
.proc wp_action
        lda WS_ACT,y
        cmp #WA_READY
        bne ?l1
        jmp wp_ready
?l1     cmp #WA_LOWER
        bne ?l2
        jmp wp_lower
?l2     cmp #WA_RAISE
        bne ?l3
        jmp wp_raise
?l3     cmp #WA_REFIRE
        bne ?l4
        jmp wp_refire_a
?l4     cmp #WA_FIRE
        beq ?fire
        cmp #WA_PUNCH                ; A_Punch rides the same skeleton as a
        beq ?fire                    ;   trigger pull: en_gunshot's WP_FIST
                                     ;   branch rolls 2*(P_Random()%10+1) with
                                     ;   the berserk x10, en_shoot gates it on
                                     ;   MELEERANGE (en_melee), no ammo, no
                                     ;   flash -- wp_fire_a already does all
        cmp #WA_GUNFLASH             ;   of that off the WP_FIST row.
        bne ?out                     ; A_GunFlash: the flash psprite only. The
        ldx wp_cur                   ;   rocket lights it a state BEFORE it fires
        lda wi_flash,x
        beq ?out
        jmp wp_fenter
?fire   jmp wp_fire_a
?out    rts
.endp

;--------------------------------------------------------------
; wp_ready -- A_WeaponReady: a queued weapon change first (it always wins), then
;   the fire button, then the bob. attackdown is what stops the pistol from
;   auto-firing: after the first shot the re-fire comes from A_ReFire.
;--------------------------------------------------------------
.proc wp_ready
        jsr wp_sawidl                ; the saw's idle putter (the annex: this
        lda wp_pending               ;   run ends 9 B short of ENLFIND_BASE)
        cmp #WP_NONE
        beq ?fire
        ldx wp_cur                   ; put the current weapon away
        lda wi_down,x
        jmp wp_enter
?fire   lda TRIG0
        and #1
        bne ?up
        lda wp_down
        bne ?bob                     ; still held from the last shot
        lda #1
        sta wp_down
        jmp wp_firewep
?up     lda #0
        sta wp_down
?bob                                 ; psp->sx/sy: only A_WeaponReady writes them
    .if WP_SWAY
        jmp wp_bobapply
    .else
        rts                          ; the sway is off in this build (WP_SWAY)
    .endif
.endp

;--------------------------------------------------------------
; wp_refire_a -- A_ReFire: the button still down and no switch queued fires again
;   without lowering the gun; otherwise re-check the ammo. Relocated with the
;   two above -- same reason, and it is one call per shot.
;--------------------------------------------------------------
wpr2_resume = *
        org WPREFIRE_BASE
.proc wp_refire_a
        lda TRIG0
        and #1
        bne ?stop
        lda wp_pending
        cmp #WP_NONE
        bne ?stop
        inc wp_refire
        jmp wp_firewep
?stop   lda #0
        sta wp_refire
        jmp wp_checkammo
.endp
    .if * > WPREFIRE_END+1
        ert 'wp_refire_a outgrew WPREFIRE_BASE..END (memory_map.inc)'
    .endif
        org wpr2_resume

;--------------------------------------------------------------
; wp_lower / wp_raise -- A_Lower / A_Raise: slide psp->sy by WEAPONSPEED px per
;   tic between WEAPONTOP and WEAPONBOTTOM, then hand over (P_BringUpWeapon at
;   the bottom, readystate at the top).
;--------------------------------------------------------------
.proc wp_lower
        lda wp_sy
        clc
        adc #WEAPONSPEED
        cmp #WEAPONBOTTOM
        bcs ?bottom
        sta wp_sy
        rts
?bottom lda #WEAPONBOTTOM
        sta wp_sy
        lda pl_dead                  ; A_Lower: "Player is dead ... don't bring
        bne ?stay                    ;   weapon back up" -- it stays at the bottom
        lda wp_pending               ;   (p_pspr.c, and P_DropWeapon started it)
        cmp #WP_NONE
        beq ?same                    ; nothing queued -> the same one comes back
        sta wp_cur
        jsr wp_wload                 ; copy the NEW weapon's frames SRAM -> slot
                                     ;   (A = its id; nothing shows this tic --
                                     ;   the gun is fully lowered = fully clipped)
        lda wp_cur                   ; P_BringUpWeapon: the saw REVS as it comes
        cmp #WP_CHAINSAW             ;   up (sfx_sawup) -- the one weapon with an
        bne ?nosup                   ;   arrival sound
        lda #SFX_SAWUP
        sta snd_pending
?nosup  lda #WP_NONE
        sta wp_pending
        lda #1                       ; the HUD's ammo type changed with it
        sta hud_dirty
?stay   rts                          ; dead: parked at WEAPONBOTTOM, off screen
?same   ldx wp_cur
        lda wi_up,x
        jmp wp_enter
.endp

wpr_resume = *
        org WPRAISE_BASE
.proc wp_raise
        lda wp_sy
        sec
        sbc #WEAPONSPEED
        cmp #WEAPONTOP+1
        bcc ?top
        sta wp_sy
        rts
?top    lda #WEAPONTOP
        sta wp_sy
        ldx wp_cur
        lda wi_rdy,x
        jmp wp_enter
.endp
    .if * > WPRAISE_END+1
        ert 'wp_raise outgrew WPRAISE_BASE..END (memory_map.inc)'
    .endif
        org wpr_resume

;--------------------------------------------------------------
; wp_fire_a -- A_FirePistol / A_FireShotgun / A_FireCGun, the parts that exist
;   without monsters: spend one round, queue the shot's SFX, light the muzzle
;   flash. A_FireCGun alternates its two flash frames (DOOM picks them from the
;   psprite's own state; a flip bit gives the same result).
;--------------------------------------------------------------
.proc wp_fire_a
        jsr en_gunshot               ; A_GunShot -> P_LineAttack (enemy.asm). FIRST:
                                     ;   it clobbers A/X/Y and nothing is live yet
                                     ;   (and it raises ai_noise for every weapon
                                     ;   -- P_NoiseAlert, see enemy.asm)
        ldx wp_cur
        lda wi_ammo,x
        bmi ?nospend                 ; am_noammo
        stx m_a                      ; DEC has no abs,Y form, so the ammo index
        tax                          ;   has to go through X -- park the weapon
        dec PSTATE,x
        ldx m_a
?nospend
        lda wi_sfx,x
        cpx #WP_FIST                 ; A_Punch is silent unless it CONNECTS --
        beq ?fist                    ;   then it is the thump (en_hit, enemy.asm)
        cpx #WP_CHAINSAW
        bne ?q
        ldy en_hit                   ; A_Saw: the buzz turns into sfx_sawhit
        beq ?q                       ;   when the blade bites (p_pspr.c)
        lda #SFX_SAWHIT
?q      jsr ai_noisealert            ; snd_dispatch starts it after the frame --
        jmp ?cry                     ;   and it IS P_NoiseAlert (enemy_ai.asm)
?fist   ldy en_hit
        beq ?cry                     ; whiff: queue nothing, and leave whatever
        jsr ai_noisealert            ;   the frame already queued alone
?cry                                 ; (the cry rides VOICE B now -- snd_dispatch
                                     ;  starts it on its own POKEY channel, so it
                                     ;  no longer displaces the weapon's sound)
        lda #1                       ; the ammo counter changed
        sta hud_dirty
        lda wi_flash,x
        beq ?none                    ; the fist and the saw have none (S_NULL)
        cpx #WP_MISSILE
        beq ?none                    ; A_FireMissile lights nothing: the rocket's
                                     ;   own A_GunFlash state ran one state ago
        cpx #WP_PLASMA
        bne ?nopl
        lda RANDOM                   ; A_FirePlasma: flashstate + (P_Random()&1),
        and #1                       ;   a COIN TOSS, where the chaingun's two
        clc                          ;   flash frames strictly alternate
        adc #WS_PLSFLASH1
        bne ?set                     ; always (WS_PLSFLASH1 is 61)
?nopl   cpx #WP_CHAINGUN
        bne ?set
        lda wp_flip                  ; CHAINFLASH1 / CHAINFLASH2, alternating
        eor #1
        sta wp_flip
        clc
        adc #WS_CHFLASH1
?set    jmp wp_fenter
?none   rts
.endp

;--------------------------------------------------------------
; wp_checkammo -- P_CheckAmmo: C=1 if the ready weapon can fire. If it cannot,
;   queue the best weapon that can (DOOM's priority list, cut to the weapons this
;   build has art for) -- the gun then lowers and the new one comes up.
;--------------------------------------------------------------
.proc wp_checkammo
        ldx wp_cur
        lda wi_ammo,x
        bmi ?ok                      ; am_noammo always fires
        tax
        lda PSTATE,x
        bne ?ok
        ldx #0
?scan   ldy wi_prio,x                ; best weapon first
        bmi ?fist
        lda wp_bit,y
        and PSTATE+PS_WEAPONS
        beq ?nx                      ; not owned
        lda wi_ammo,y
        bmi ?take
        tay                          ; ... and stocked?
        lda PSTATE,y
        beq ?nx
        ldy wi_prio,x
?take   cpy wp_cur
        beq ?nx                      ; that is the empty one we came from
        sty wp_pending
        clc
        rts
?nx     inx
        cpx #WI_NPRIO
        bcc ?scan
?fist   lda #WP_FIST
        sta wp_pending
        clc
        rts
?ok     sec
        rts
.endp

;--------------------------------------------------------------
; wp_select -- read_keys' '1'..'4': queue weapon A if the player owns it and it
;   is not already in hand (DOOM's weapon change in G_BuildTiccmd).
;--------------------------------------------------------------
.proc wp_select
        cmp #WP_FIST                 ; '1' is the CHAINSAW when it is owned:
        bne ?have                    ;   G_BuildTiccmd substitutes it unless the
        ldx #WP_CHAINSAW             ;   player is already sawing WITH berserk --
        lda wp_bit,x                 ;   then '1' hands the fist back, and since
        and PSTATE+PS_WEAPONS        ;   2026-08-01 there IS a pw_strength to test
        beq ?fist                    ;   (powerups.asm), so the rule is complete
        lda wp_cur
        cmp #WP_CHAINSAW
        bne ?saw
        lda PW_FLAGS
        and #PWF_BERSERK
        bne ?fist
?saw    txa
        bne ?have                    ; always: WP_CHAINSAW is 7
?fist   lda #WP_FIST
?have   tax
        lda wp_bit,x
        and #WP_ART
        beq ?no                      ; plasma / BFG: owned or not, this build has
        lda wp_bit,x                 ;   no psprite for them (VRAM), so the key
        and PSTATE+PS_WEAPONS        ;   does nothing and wp_checkammo never
        beq ?no                      ;   falls back to them either
        cpx wp_cur
        beq ?no
        stx wp_pending
?no     rts
.endp

;--------------------------------------------------------------
; wp_give -- P_GiveWeapon: a found weapon comes with TWO clips of its ammo
;   (p_inter.c: one if dropped by an enemy, two if it was placed in the map --
;   clipammo[] = 10 bullets / 4 shells / 20 cells / 1 rocket, so 20/8/40/2) and
;   becomes the pending weapon, so the gun in hand goes down and the new one
;   comes up. A = bonus id (16..21, see BN_* in sprites.asm). Weapons with no art
;   still bank their ammo -- they are simply never switched to.
;   Called from pickup_bonus.
;--------------------------------------------------------------
;   MOVED to the DROP block (enemy_ai.asm, DROP_BASE) 2026-07-31: the dropped-
;   weapon half-ammo test pushed this segment past WEAPON_END, and wp_give runs
;   once per weapon pickup -- the coldest thing in the file.
; wp_give's three tables, parked at WPGTAB_BASE: pure data read with ,x once per
; weapon pickup, and the block itself is full to the byte again.
wpg_resume = *
        org WPGTAB_BASE
wi_ofbonus dta WP_SHOTGUN, WP_CHAINGUN, WP_MISSILE, WP_PLASMA, WP_BFG, WP_CHAINSAW
wi_give dta 0, 20, 8, 20, 2, 40, 40, 0               ; 2 clips of wi_ammo
wi_amax dta 0, 200, 50, 200, 50, 255, 255, 0         ; DOOM maxammo (cells 300
                                                     ;   clipped: PSTATE is a byte)
    .if * > WPGTAB_END+1
        ert 'wp_give tables outgrew WPGTAB_BASE..END (memory_map.inc)'
    .endif
        org wpg_resume

;--------------------------------------------------------------
; wp_bobcalc -- player->bob (P_CalcHeight) + the bob phase, once per tic.
;   DOOM derives bob from momx/momy, which this port does not track (the step is
;   a fixed SPD per frame), so it ramps toward MAXBOB while the player actually
;   moves -- mv_ox/mv_oy hold the pre-move position, so walking into a wall
;   correctly kills the bob, exactly as losing momentum would.
;--------------------------------------------------------------
; The three sway procs below are assembled ONLY when WP_SWAY is on. They are
; ~180 B, they are the whole reason the $F280 block was full, and with the sway
; off every byte of them is dead: wp_bobapply is the only caller of wp_scale,
; wp_ready is the only caller of wp_bobapply (already behind .if WP_SWAY), and
; wp_bobcalc's wp_bob feeds nothing else. That is the room the chainsaw and the
; rocket launcher's states are built in -- turn WP_SWAY back on and they come
; back, so keep an eye on the block's ert guard if you do.
    .if WP_SWAY
.proc wp_bobcalc
        clc
        lda wp_phase
        adc #BOBPHASE
        sta wp_phase
        lda zp_px
        cmp mv_ox
        bne ?moving
        lda zp_px+1
        cmp mv_ox+1
        bne ?moving
        lda zp_py
        cmp mv_oy
        bne ?moving
        lda zp_py+1
        cmp mv_oy+1
        beq ?still
?moving lda wp_bob
        cmp #MAXBOB
        bcs ?done
        clc
        adc #BOBRAMP
        cmp #MAXBOB
        bcc ?put
        lda #MAXBOB
?put    sta wp_bob
?done   rts
?still  lda wp_bob
        beq ?done
        sec
        sbc #BOBRAMP
        bcs ?put
        lda #0
        sta wp_bob
        rts
.endp

;--------------------------------------------------------------
; wp_bobapply -- A_WeaponReady's tail: psp->sx = FRACUNIT + bob*cos(phase),
;   psp->sy = WEAPONTOP + bob*sin(phase & FINEANGLES/2-1). The half-fold is what
;   makes the gun dip TWICE per horizontal sweep instead of ever rising above its
;   rest row -- in BAM, indices 0..127 of the 256-entry table are exactly the
;   half-circle where sin is positive.
;--------------------------------------------------------------
.proc wp_bobapply
        ldy wp_phase
        lda COS_HI,y                 ; Q14 cos -> px
        jsr wp_scale
        lda m_b                      ; px -> BYTES (our byte = 2 DOOM px),
        cmp #$80                     ;   arithmetic shift so the sign survives
        ror
        sta wp_bx
        lda wp_phase
        and #$7F                     ; fold: |sin| over the first half-circle
        tay
        lda SIN_HI,y
        jsr wp_scale
        lda m_b
        sta wp_by
        rts
.endp

;--------------------------------------------------------------
; wp_scale -- A = the HIGH byte of a Q14 sin/cos ($40 = 1.0, signed);
;   m_b = bob * A / 64 = the offset in DOOM pixels, sign preserved. The table's
;   low byte is dropped on purpose: one pixel is already two hardware pixels
;   wide and MAXBOB is 16, so a 1/64 px refinement buys nothing.
;--------------------------------------------------------------
.proc wp_scale
        sta m_b+1                    ; keep the sign
        bpl ?abs
        eor #$FF
        clc
        adc #1
?abs    sta m_a                      ; |A|, 0..64
        lda #0
        sta m_b
        lsr m_a                      ; m_b:m_a = |A| * bob -- the canonical
        ldx #8                       ;   shift-add: m_a doubles as the multiplier
?mul    bcc ?nadd                    ;   AND the product's low byte, so exactly
        clc                          ;   ONE shift of it per pass (the `ror m_a`
        lda m_b                      ;   below both takes the product bit in and
        adc wp_bob                   ;   pushes the next multiplier bit out).
        sta m_b                      ;   An extra `lsr m_a` at the top ate every
?nadd   ror m_b                      ;   second partial product -- the bob came
        ror m_a                      ;   out 8x too small, i.e. always 0 px.
        dex
        bne ?mul
        asl m_a                      ; product >> 6 = /64 for the Q14 high byte:
        rol m_b                      ;   shift the 16-bit product LEFT twice and
        asl m_a                      ;   keep the high byte (max 64*16 = 1024 -> 16)
        rol m_b
        bit m_b+1
        bpl ?done
        sec                          ; negate
        lda #0
        sbc m_b
        sta m_b
?done   rts
.endp
    .endif                           ; WP_SWAY

;==============================================================
; THE STATE TABLE -- info.c's psprite states, one row per WS_*: sprite frame
; (WEAP_TAB index, $FF = draw nothing), duration in DOOM TICS, action, next.
; Parallel arrays; the machine indexes all four by the state id.
; (WPF_* comes from weap_tables.inc, icl'd up with atr_layout.inc in bsp_main.asm
;  -- load_weapons needs the region equs before this file is assembled.)
;==============================================================
WS_FRM                               ; ---- sprite frame -------------------
        dta $FF                                           ; NULL
        dta WPF_PUNGA,WPF_PUNGA,WPF_PUNGA                  ; PUNCH/DOWN/UP
        dta WPF_PUNGB,WPF_PUNGC,WPF_PUNGD,WPF_PUNGC,WPF_PUNGB
        dta WPF_PISGA,WPF_PISGA,WPF_PISGA                  ; PISTOL/DOWN/UP
        dta WPF_PISGA,WPF_PISGB,WPF_PISGC,WPF_PISGB
        dta WPF_PISFA                                      ; PISFLASH
        dta WPF_SHTGA,WPF_SHTGA,WPF_SHTGA                  ; SGUN/DOWN/UP
        dta WPF_SHTGA,WPF_SHTGA,WPF_SHTGB,WPF_SHTGC,WPF_SHTGD
        dta WPF_SHTGC,WPF_SHTGB,WPF_SHTGA,WPF_SHTGA
        dta WPF_SHTFA,WPF_SHTFB                            ; SGFLASH1/2
        dta WPF_CHGGA,WPF_CHGGA,WPF_CHGGA                  ; CHAIN/DOWN/UP
        dta WPF_CHGGA,WPF_CHGGB,WPF_CHGGB
        dta WPF_CHGFA,WPF_CHGFB                            ; CHFLASH1/2
        dta WPF_SAWGC,WPF_SAWGD,WPF_SAWGC,WPF_SAWGC        ; SAW/SAWB/DOWN/UP
        dta WPF_SAWGA,WPF_SAWGB,WPF_SAWGB                  ; SAW1/2/3
        dta WPF_MISGA,WPF_MISGA,WPF_MISGA                  ; MISSILE/DOWN/UP
        dta WPF_MISGB,WPF_MISGB,WPF_MISGB
        dta WPF_MISFA,WPF_MISFB,WPF_MISFC,WPF_MISFD        ; MISFLASH1..4
        dta WPF_PLSGA,WPF_PLSGA,WPF_PLSGA                  ; PLASMA/DOWN/UP
        dta WPF_PLSGA,WPF_PLSGB
        dta WPF_PLSFA,WPF_PLSFB                            ; PLSFLASH1/2

WS_DUR                               ; ---- duration, DOOM tics ------------
        dta 0
        dta 1,1,1, 4,4,5,4,5                               ; fist
        dta 1,1,1, 4,6,4,5, 7                              ; pistol (flash 7)
        dta 1,1,1, 3,7,5,5,4,5,5,3,7, 4,3                  ; shotgun (flash 4,3)
        dta 1,1,1, 4,4,0, 5,5                              ; chaingun (CHAIN3 = 0)
        dta 4,4,1,1, 4,4,0                                 ; chainsaw (SAW3 = 0)
        dta 1,1,1, 8,12,0, 3,4,4,4                         ; rocket launcher
        dta 1,1,1, 3,20, 4,4                               ; plasma rifle

WS_ACT                               ; ---- action -------------------------
        dta WA_NONE
        dta WA_READY,WA_LOWER,WA_RAISE
        dta WA_NONE,WA_PUNCH,WA_NONE,WA_NONE,WA_REFIRE
        dta WA_READY,WA_LOWER,WA_RAISE
        dta WA_NONE,WA_FIRE,WA_NONE,WA_REFIRE
        dta WA_NONE
        dta WA_READY,WA_LOWER,WA_RAISE
        dta WA_NONE,WA_FIRE,WA_NONE,WA_NONE,WA_NONE
        dta WA_NONE,WA_NONE,WA_NONE,WA_REFIRE
        dta WA_NONE,WA_NONE
        dta WA_READY,WA_LOWER,WA_RAISE
        dta WA_FIRE,WA_FIRE,WA_REFIRE
        dta WA_NONE,WA_NONE
        dta WA_READY,WA_READY,WA_LOWER,WA_RAISE            ; chainsaw: BOTH idle
        dta WA_FIRE,WA_FIRE,WA_REFIRE                      ;   frames are ready
        dta WA_READY,WA_LOWER,WA_RAISE                     ; rocket launcher
        dta WA_GUNFLASH,WA_FIRE,WA_REFIRE
        dta WA_NONE,WA_NONE,WA_NONE,WA_NONE                ; (A_Light1/2: no
                                                           ;  light amp here)
        dta WA_READY,WA_LOWER,WA_RAISE                     ; plasma rifle
        dta WA_FIRE,WA_REFIRE
        dta WA_NONE,WA_NONE

WS_NXT                               ; ---- next state ---------------------
        dta WS_NULL
        dta WS_PUNCH,WS_PUNCHDOWN,WS_PUNCHUP               ; the 1-tic states
        dta WS_PUNCH2,WS_PUNCH3,WS_PUNCH4,WS_PUNCH5,WS_PUNCH   ;   loop on
        dta WS_PISTOL,WS_PISTOLDOWN,WS_PISTOLUP            ;   themselves
        dta WS_PISTOL2,WS_PISTOL3,WS_PISTOL4,WS_PISTOL
        dta WS_NULL
        dta WS_SGUN,WS_SGUNDOWN,WS_SGUNUP
        dta WS_SGUN2,WS_SGUN3,WS_SGUN4,WS_SGUN5,WS_SGUN6
        dta WS_SGUN7,WS_SGUN8,WS_SGUN9,WS_SGUN
        dta WS_SGFLASH2,WS_NULL
        dta WS_CHAIN,WS_CHAINDOWN,WS_CHAINUP
        dta WS_CHAIN2,WS_CHAIN3,WS_CHAIN
        dta WS_NULL,WS_NULL
        dta WS_SAWB,WS_SAW,WS_SAWDOWN,WS_SAWUP             ; the idle pair swaps
        dta WS_SAW2,WS_SAW3,WS_SAW                         ;   back and forth
        dta WS_MISSILE,WS_MISSILEDOWN,WS_MISSILEUP
        dta WS_MISSILE2,WS_MISSILE3,WS_MISSILE
        dta WS_MISFLASH2,WS_MISFLASH3,WS_MISFLASH4,WS_NULL
        dta WS_PLASMA,WS_PLASMADOWN,WS_PLASMAUP
        dta WS_PLASMA2,WS_PLASMA
        dta WS_NULL,WS_NULL

;==============================================================
; PER-WEAPON TABLE -- d_items.c weaponinfo[], indexed by WP_*. Only the four
; weapons with art are reachable; rows 4..7 keep every array a full 8 long so a
; stray index cannot walk off the end (they mirror the pistol).
;==============================================================
wp_bit  dta 1,2,4,8,16,32,64,128     ; 1<<wp: PS_WEAPONS is DOOM's wp_* bitfield
wi_ammo dta $FF, PS_BULLETS, PS_SHELLS, PS_BULLETS   ; weaponinfo[].ammo, and
        dta PS_ROCKETS, PS_CELLS, PS_CELLS, $FF      ;   $FF = am_noammo
wi_up   dta WS_PUNCHUP,   WS_PISTOLUP,   WS_SGUNUP,    WS_CHAINUP
        dta WS_MISSILEUP, WS_PLASMAUP,   WS_PISTOLUP,  WS_SAWUP
wi_down dta WS_PUNCHDOWN, WS_PISTOLDOWN, WS_SGUNDOWN,  WS_CHAINDOWN
        dta WS_MISSILEDOWN,WS_PLASMADOWN,WS_PISTOLDOWN,WS_SAWDOWN
wi_rdy  dta WS_PUNCH,     WS_PISTOL,     WS_SGUN,      WS_CHAIN
        dta WS_MISSILE,   WS_PLASMA,     WS_PISTOL,    WS_SAW
wi_atk  dta WS_PUNCH1,    WS_PISTOL1,    WS_SGUN1,     WS_CHAIN1
        dta WS_MISSILE1,  WS_PLASMA1,    WS_PISTOL1,   WS_SAW1
wi_flash dta 0, WS_PISFLASH, WS_SGFLASH1, WS_CHFLASH1
        dta WS_MISFLASH1, WS_PLSFLASH1, 0, 0   ; the saw has none (S_NULL)
wi_sfx  dta SFX_PUNCH,  SFX_PISTOL, SFX_SHOTGN, SFX_PISTOL
        dta SFX_RLAUNC, SFX_PLASMA, SFX_PISTOL, SFX_SAWFUL
        ; The rocket fires sfx_rlaunc now, the original's launch (info.c
        ; seesound): since the missile flies visibly (proj.asm) the impact
        ; half -- sfx_barexp, MT_ROCKET's deathsound -- plays when the sprite
        ; ARRIVES, from pj_burst. The fist row is the CONNECT thump: wp_fire_a
        ; only queues it when en_hit says the swing landed (a whiff is silent,
        ; like A_Punch), and the saw row flips to SFX_SAWHIT on contact.
wi_prio dta WP_PLASMA, WP_CHAINGUN, WP_SHOTGUN, WP_PISTOL, WP_CHAINSAW
        dta WP_MISSILE, $FF
                                     ; P_CheckAmmo's fallback order, p_pspr.c:
                                     ;   plasma, chaingun, shotgun, pistol,
                                     ;   chainsaw, missile, bfg, fist -- minus
                                     ;   the two weapons this build has no art for
WI_NPRIO equ * - wi_prio

WEAP_TAB                             ; 7 B per frame: u24 vram, w, h, ax, ay
        ins 'build/assets/weap/weap.tab'

    .if * > WEAPON_END+1
        ert 'weapon.asm outgrew WEAPON_BASE..END (memory_map.inc)'
    .endif


;==============================================================
; draw_weapon -- R_DrawPlayerSprites: the gun, then the muzzle flash. Called from
; draw_hud_gate after render_world (the view is finished) and before the status
; bar, with the OS ROM already banked out. Parked in its own hole -- the state
; machine above is most of a KB with its tables.
;--------------------------------------------------------------
; SCALING WITH THE VIEW. DOOM's psprites scale with the window (r_things.c:
; pspritescale = viewwidth/SCREENWIDTH), and this port's view-size keys are its
; one real speed knob, so the gun follows them. The VBXE blitter can only step
; the source by whole bytes, so the scale is the window's power-of-two shift --
; vw_sh, the same 0/1/2 the reciprocal tables use (1, 1/2, 1/4): SRC_STEPX =
; 1<<k and SRC_STEPY = width<<k skip every other source pixel and row. The two
; in-between sizes (3/4 and 3/8, vw_q34) get the next size UP and are simply
; clipped -- a gun a third too big, not a missing one.
;
; ANCHORING + CLIPPING. Every window in vw_tab is centred on column 80, so the
; horizontal anchor is (ax-80)>>k around that centre; vertically the gun hangs
; from the window's BOTTOM row (vw_y1) exactly as it hangs from row 167 at full
; size. Then all four edges are clipped to [vw_x0..vw_x1] x [vw_y0..vw_y1], with
; the source address advanced by the skipped columns/rows -- clipping matters:
; the border outside the window is painted ONCE (vw_dirty) and nothing repaints
; it, so a pixel put there would smear for the rest of the level.
;==============================================================
WE_VRAM equ 0                        ; the weap.tab record, as copied to wp_ent
WE_W    equ 3
WE_H    equ 4
WE_AX   equ 5
WE_AY   equ 6

        org WEAPDRAW_BASE
.proc draw_weapon
        ldy wp_state
        lda WS_FRM,y
        bmi ?flash                   ; $FF = S_NULL: nothing in hand
        jsr wp_one
?flash  ldy wp_fstate
        lda WS_FRM,y
        bmi ?out
        jmp wp_one
?out    rts
.endp

;--------------------------------------------------------------
; wp_one -- A = WEAP_TAB frame index: place it, scale it, clip it, blit it.
;--------------------------------------------------------------
.proc wp_one
        sta m_a                      ; index*7 = *8 - *1
        asl
        asl
        asl
        sec
        sbc m_a
        clc
        adc #<WEAP_TAB
        sta zp_ptr
        lda #0
        adc #>WEAP_TAB
        sta zp_ptr+1
        ldy #6                       ; vram24, w, h, ax, ay
?cp     lda (zp_ptr),y
        sta wp_ent,y
        dey
        bpl ?cp
        ; ---- source steps: skip 2^k pixels across and 2^k rows down ---------
        lda wp_ent+WE_W
        sta wp_sty
        lda #0
        sta wp_sty+1
        lda #1
        sta wp_stx
        ldx vw_sh
        beq ?nok
?ksh    asl wp_sty
        rol wp_sty+1
        asl wp_stx
        dex
        bne ?ksh
?nok
        ; ---- X: every vw_tab window is centred on column 80 -----------------
        clc
        lda wp_ent+WE_AX
        adc wp_bx                    ; psp->sx: the sway, 0 unless WP_SWAY
        sec
        sbc #SCREEN_HALF
        jsr wp_asr                   ; (ax - 80 + bob) >> k, sign kept
        clc
        adc #SCREEN_HALF
        sta wp_x
        lda wp_ent+WE_W
        jsr wp_ceil
        sta wp_w
        lda vw_x0                    ; left clip
        sec
        sbc wp_x
        bcc ?xr
        beq ?xr
        cmp wp_w
        bcc ?lok
        jmp wp_no                    ; entirely left of the window
?lok    sta m_a
        lda wp_w
        sec
        sbc m_a
        sta wp_w
        lda vw_x0
        sta wp_x
        lda m_a                      ; src += skipped columns * SRC_STEPX
        ldx vw_sh
        beq ?cs1
?csh    asl
        dex
        bne ?csh
?cs1    sta m_a
        lda #0
        sta m_a+1
        jsr wp_srcadd
?xr     clc                          ; right clip
        lda wp_x
        adc wp_w
        sbc #0                       ; C=1 unless the add wrapped: last column
        cmp vw_x1
        bcc ?yy
        beq ?yy
        lda vw_x1
        sec
        sbc wp_x
        bcs ?rok
        jmp wp_no
?rok    clc
        adc #1
        sta wp_w
        ; ---- Y: hang the gun from the window's bottom row -------------------
?yy     lda wp_sy                    ; the raise/lower slide, 0 when up,
        sec                          ;   plus the vertical sway (also 0 unless
        sbc #WEAPONTOP               ;   WP_SWAY) -- both move the gun DOWN
        clc
        adc wp_by
        sta m_a
        sec
        lda #VIEW_HEIGHT             ; rows from the frame's top row to the
        sbc wp_ent+WE_AY             ;   bottom of the FULL-SIZE view
        sec
        sbc m_a                      ;   ... minus the slide
        bcs ?vis
        jmp wp_no                    ; slid out of sight
?vis    bne ?vok
        jmp wp_no
?vok    jsr wp_shr
        sta m_a
        lda vw_y1                    ; y = vw_y1 + 1 - that, scaled
        sec
        sbc m_a
        bcs ?yok
        jmp wp_no
?yok    clc
        adc #1
        sta wp_y
        lda wp_ent+WE_H
        jsr wp_ceil
        sta wp_h
        lda vw_y0                    ; top clip
        sec
        sbc wp_y
        bcc ?yb
        beq ?yb
        cmp wp_h
        bcc ?tok
        jmp wp_no                    ; entirely above the window
?tok    sta m_a
        lda wp_h
        sec
        sbc m_a
        sta wp_h
        lda vw_y0
        sta wp_y
        jsr wp_rowskip               ; src += skipped rows * SRC_STEPY
?yb     clc                          ; bottom clip -- the ceil above can overshoot
        lda wp_y                     ;   by a row, and a LOWERED tall frame (the
        adc wp_h                     ;   shotgun pump is 135 rows) runs off the
        bcs ?cut                     ;   screen entirely, so the carry counts
        sbc #0                       ; last row
        cmp vw_y1
        bcc ?go
        beq ?go
?cut    lda vw_y1
        sec
        sbc wp_y
        bcs ?bok
        jmp wp_no
?bok    clc
        adc #1
        sta wp_h
?go     jmp wp_blit
.endp

;--------------------------------------------------------------
; wp_no -- the shared "nothing to draw" exit. wp_one is well over 127 bytes, so
;   its six clip rejections cannot branch to a tail rts; they jmp here.
;--------------------------------------------------------------
.proc wp_no
        rts
.endp

;--------------------------------------------------------------
; wp_blit -- fire the clipped rectangle through the HUD's BCB. It leaves
;   SRC_STEPX / SRC_STEPY's high byte scaled, which hud_blit resets: the two
;   share the block and the status bar is always 1:1.
;--------------------------------------------------------------
.proc wp_blit
        lda wp_ent+WE_VRAM
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda wp_ent+WE_VRAM+1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1
        lda wp_ent+WE_VRAM+2
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda wp_sty
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda wp_sty+1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        lda wp_stx
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda wp_w
        sec
        sbc #1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda #0
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH+1
        lda wp_h
        sec
        sbc #1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        ldx wp_y                     ; DST = row(y) + x, into the back buffer
        lda row_lo,x
        clc
        adc wp_x
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        lda zback_hi
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #BLT_BSTENCIL            ; index 0 = transparent
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsr blitter_wait
        lda #<VRAM_BCB_HUD
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_HUD
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_HUD>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START
        rts
.endp

;--------------------------------------------------------------
; The three view-scale helpers + the source-address arithmetic.
;--------------------------------------------------------------
.proc wp_shr                         ; A >>= vw_sh (logical)
        ldx vw_sh
        beq ?d
?l      lsr
        dex
        bne ?l
?d      rts
.endp

.proc wp_asr                         ; A >>= vw_sh (arithmetic: ax-80 is signed)
        ldx vw_sh
        beq ?d
?l      cmp #$80
        ror
        dex
        bne ?l
?d      rts
.endp

.proc wp_ceil                        ; A = ceil(A / 2^vw_sh) -- a 1-pixel sliver
        ldx vw_sh                    ;   of the gun must not round away
        beq ?d
        clc
        adc wp_msk,x
        jmp wp_shr
?d      rts
.endp
wp_msk  dta 0,1,3

.proc wp_srcadd                      ; wp_ent's 24-bit VRAM address += m_a (16b)
        clc
        lda wp_ent+WE_VRAM
        adc m_a
        sta wp_ent+WE_VRAM
        lda wp_ent+WE_VRAM+1
        adc m_a+1
        sta wp_ent+WE_VRAM+1
        lda wp_ent+WE_VRAM+2
        adc #0
        sta wp_ent+WE_VRAM+2
        rts
.endp

.proc wp_rowskip                     ; src += m_a (dest rows) * SRC_STEPY
        lda wp_sty                   ; shift a COPY: the blit still needs the step
        sta wp_t
        lda wp_sty+1
        sta wp_t+1
        lda #0
        sta m_b
        sta m_b+1
        ldx #8
?l      lsr m_a
        bcc ?n
        clc
        lda m_b
        adc wp_t
        sta m_b
        lda m_b+1
        adc wp_t+1
        sta m_b+1
?n      asl wp_t
        rol wp_t+1
        dex
        bne ?l
        lda m_b
        sta m_a
        lda m_b+1
        sta m_a+1
        jmp wp_srcadd
.endp

wp_x    dta 0                        ; the blit's resolved screen column / row
wp_y    dta 0
wp_w    dta 0                        ; ... and its size in DEST bytes / rows
wp_h    dta 0
wp_stx  dta 1                        ; SRC_STEPX / SRC_STEPY for this scale
wp_sty  dta a(0)
wp_t    dta a(0)                     ; wp_rowskip's shifting copy of SRC_STEPY

    .if * > WEAPDRAW_END+1
        ert 'draw_weapon outgrew WEAPDRAW_BASE..END (memory_map.inc)'
    .endif

;==============================================================
; THE PALETTE FLASH -- st_stuff.c ST_doPaletteStuff, 1:1 (see the PALETTE FLASH
; block in memory_map.inc for the whole design and for what is deliberately left
; out). Two counters, DOOM's own formula, DOOM's own PLAYPAL bytes; the swap is
; one byte into the XDL because the four slots are already resident in VBXE's
; four palettes -- an I_SetPalette here would be 768 register writes.
;==============================================================
        org FLASH_BASE

;--------------------------------------------------------------
; fl_tic -- P_PlayerThink's tail: both counters decay ONE per DOOM tic. Called
;   from wp_tic, which is already the port's 35 Hz clock.
;--------------------------------------------------------------
.proc fl_tic
        lda fl_dmg
        beq ?bon
        dec fl_dmg
?bon    lda fl_bonus
        beq ?out
        dec fl_bonus
?out    rts
.endp

;--------------------------------------------------------------
; fl_damage -- P_DamageMobj: damagecount += damage, capped at DMG_MAX.
;   A = the damage that actually got through to the player.
;   Both callers reach it through pl_hurtfx (hud.asm) now, which wraps it with
;   the grunt and the HUD face -- one event, one place. This block is full to the
;   byte, which is why the wrapper is the one on the outside.
;--------------------------------------------------------------
.proc fl_damage
        clc
        adc fl_dmg
        bcs ?cap                     ; wrapped a byte
        cmp #DMG_MAX+1
        bcc ?set
?cap    lda #DMG_MAX
?set    sta fl_dmg
        rts
.endp

;--------------------------------------------------------------
; fl_bonusadd -- P_TouchSpecialThing: bonuscount += BONUSADD. DOOM never caps
;   this (the count decays a tic at a time), so only the byte does.
;--------------------------------------------------------------
.proc fl_bonusadd
        lda fl_bonus
        clc
        adc #BONUSADD
        bcc ?set
        lda #$FF
?set    sta fl_bonus
        rts
.endp

;--------------------------------------------------------------
; update_flash -- ST_doPaletteStuff, once per frame (from draw_hud_gate). Red
;   wins over gold, exactly like DOOM's if/else-if chain, and the XDL is written
;   only when the chosen palette CHANGES (DOOM's st_palette test).
;--------------------------------------------------------------
.proc update_flash
        lda fl_dmg
        beq ?bon
        clc                          ; palette = (cnt+7)>>3, DOOM's 1..7
        adc #7
        lsr                          ;   (cnt <= 100, so this cannot carry)
        lsr
        lsr
        cmp #FL_REDSPLIT             ; our two red slots stand in for its eight
        bcc ?redlo
        lda #XDL_ATT_BASE | FL_PAL_REDHI
        jmp ?put
?redlo  lda #XDL_ATT_BASE | FL_PAL_REDLO
        jmp ?put
?bon    lda fl_bonus
        beq ?norm
        lda #XDL_ATT_BASE | FL_PAL_GOLD
        jmp ?put
?norm   lda #XDL_ATT_BASE | FL_PAL_NORM
?put    cmp fl_shown
        beq ?same
        sta fl_shown
        jsr xdl_att                  ; the XDL's overlay mode|palette byte, into
                                     ;   BOTH lists (xdl.asm). Safe mid-frame:
                                     ;   the XDL is re-fetched from VRAM every
                                     ;   frame, which is the same reason
                                     ;   swap_buffers may repoint it whenever.
?same   rts
.endp

;--------------------------------------------------------------
; fl_init -- per level: no flash, and force the first update_flash to commit
;   (fl_shown = an impossible byte, so the normal palette is written once).
;--------------------------------------------------------------
.proc fl_init
        lda #0
        sta fl_dmg
        sta fl_bonus
        lda #$FF
        sta fl_shown
        rts
.endp

    .if * > FLASH_END+1
        ert 'the palette flash outgrew FLASH_BASE..END (memory_map.inc)'
    .endif
