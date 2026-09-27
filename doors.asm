;--------------------------------------------------------------
; doors.asm -- part of renderer.asm (icl in place): DR doors, USE and switches.
;   MAP_DOORS = 4 B {u8 sector, u8 deny, i16 open_ceil}; MAP_DSND, MAP_DOORLOCK parallel.
;--------------------------------------------------------------
; m_x4 / m_x8 -- m_prod = m_a * 4 (* 8): the index scale in front of the MAP_*
;   table lookups. A and the flags come back as the last shift left them.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc m_x4
	rep #$20
	.LONGA ON
	lda m_a
	asl
	asl
	sta m_prod
	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc m_x8
	rep #$20
	.LONGA ON
	lda m_a
	asl
	asl
	asl
	sta m_prod
	sep #$20
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------

; The tables are sized by MAP_NDOORS (the CAP over the levels in this build); the
; runtime arrays are DOORS_NMAX entries wide in Rapidus bank $01 at DOOR_EXT --
; see memory_map.inc. Nothing reports an overrun at runtime, so assert both here:
; the cap has to fit the arrays, and the arrays have to fit the kilobyte DOOR_EXT
; reserves below TH_HPL.
; NOTE the loops below all run to the LEVEL's own door count (MAP_HNDOOR, from the
; map header), not to the cap: the padding records are zeroes, and walking them
; would register phantom doors on sector 0 and flatten it.
        .if MAP_NDOORS > DOORS_NMAX
                ert 'MAP_NDOORS > DOORS_NMAX -- widen the DOOR_EXT block (memory_map.inc)'
        .endif
        .if DOORSTAY+DOORS_NMAX > DOOR_BASE+$400
                ert 'the DOOR_* arrays outgrew DOOR_EXT and would reach TH_HPL'
        .endif


; door_index_of + door_toggle sit at DOORIDX_BASE ($06B7, the hole behind
; give_bonus): the $1B00 block is full, and these two are small and cold (one
; runs per crossed seg on a USE press, the other once per press).
di_resume = *
        org DOORIDX_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_index_of                  ; m_a = sector id -> A = door index, or $FF
        ldx MAP_HNDOOR               ; this LEVEL's door count (0 -> straight out)
        beq ?no
        dex                          ; a compare per door -- no record maths at all
?l      lda.l DOOR_SIDL,x            ; ONE byte: a sector id is one (250 is the
        cmp m_a                      ;   biggest map in episode 1), so the high
        beq ?yes                     ;   half never said anything -- and the byte
?nx     dex                          ;   it used to live in is DOOR_DENY now
        bpl ?l
?no     lda #$FF
        rts
?yes    txa
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_toggle                    ; A = door index -> DR toggle its state
        tax
        lda.l DOOR_STATE,x
        beq ?wake                    ; closed (idle) -> opening: one more live door
        cmp #3
        beq ?open                    ; closing -> opening (reverse); already counted
        lda #3                       ; opening / open -> closing
        sta.l DOOR_STATE,x
        rts
?wake   inc DOOR_NACT
?open   lda #1
        sta.l DOOR_STATE,x
        rts
.endp
        .endseg
    .if * > CLIP_BASE
        ert 'door_index_of/door_toggle overran $06B7-$06FF and would clobber CLIP_BASE'
    .endif
        org di_resume                ; back to the $1B00 block

;--------------------------------------------------------------
; init_doors -- all doors closed (cur = ceil = floor) AND build the per-level
;   tables the frame loop reads: sector pointer, open_ceil, sector id.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc init_doors
        stz DOOR_TRIGPREV
        stz DOOR_NACT                ; nothing animating yet
        stz btn_timer                ; no SR button mid-flip from the old level
        stz face_t                   ; face picks on the first frame
        lda #1                       ; paint the shared bar once
        sta hud_dirty                ;   (w3d hud_dirty model -- see hud.asm)
        lda #HUD_FACE
        sta face_cur                 ; doomguy starts looking straight ahead
        lda RTCLOK3                  ; prime the VBLANK clock: the first frame must
        sta fps_last                 ;   see a small delta, not "since power-on"
        ldx MAP_HNDOOR               ; this LEVEL's door count (see the note above)
        beq ?nodoors
        dex
?l      txa                          ; door record @ MAP_DOORS + X*4
        asl                          ;   (u8 sector, u8 deny, i16 open_ceil).
        asl                          ;   The soundorg pair is MAP_DSND's own
        tay                          ;   4 B record -- see snd_q_door_at.
        lda MAP_DOORS,y              ; sector id -> DOOR_SIDL (+ m_a for the maths)
        sta.l DOOR_SIDL,x
        sta m_a
        stz m_a+1
        lda MAP_DOORS+1,y            ; the byte the sector id's high half left:
        sta.l DOOR_DENY,x            ;   the face USE is refused from (use_leaf)
        lda MAP_DOORS+2,y            ; open_ceil -> DOOR_OPNL/H
        sta.l DOOR_OPNL,x
        lda MAP_DOORS+3,y
        sta.l DOOR_OPNH,x
        jsr m_x8                     ; zp_ptr = MAP_SECTORS + sec*8  (once per level)
        clc
        lda m_prod
        adc #<MAP_SECTORS
        sta zp_ptr
        sta.l DOOR_SECL,x
        lda m_prod+1
        adc #>MAP_SECTORS
        sta zp_ptr+1
        sta.l DOOR_SECH,x
        lda #0
        sta.l DOOR_STATE,x
        sta.l DOOR_WAIT,x
        sta.l DOOR_FRAC,x            ; no Q8 leftover yet
        sta.l DOORSTAY,x             ; no switch parked it open yet (trig_fire)
        ldy #2                       ; cur = the ceiling the MAP ships. A normal
        lda (zp_ptr),y               ;   DOOM door has ceilingheight ==
        sta.l DOOR_CURLO,x           ;   floorheight, i.e. shut, so this is the
        iny                          ;   old "cur = ceil = floor" for every one
        lda (zp_ptr),y               ;   of them -- but a close-30 door (16/76,
        sta.l DOOR_CURHI,x           ;   E1M6) starts OPEN, and forcing it shut
                                     ;   would wall the level off.
        dex
        bpl ?l
?nodoors
        rts
.endp
        .endseg

;--------------------------------------------------------------
; update_doors -- advance every door by the TIME the last frame took.
;--------------------------------------------------------------
;--------------------------------------------------------------
; frame_dt -- dt_vbl = VBLANKs the previous frame took (1..DOOR_DTMAX). Called once
;   per frame from the main loop, BEFORE anything that animates: doors and lifts
;   both scale their motion by it, so DOOM's 35 Hz tic rate survives any frame
;   rate (5 fps on a stock 800XL, far more on a Rapidus).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc frame_dt
                                      ; 2026-09-22: THE FPS CAP. A frame may not start
?wt     lda RTCLOK3                  ;   before FPS_MINVB VBLANKs have passed since the
        sec                          ;   last one: 2 on PAL (312 lines, 49.86 Hz --
        sbc fps_last                 ;   alt-src antic.cpp) = 25 fps at most. Flat
        cmp #FPS_MINVB               ;   walls ('T') ran past 50 and everything the
        bcc ?wt                      ;   frame paces ran with it. RTCLOK3 is rom_nmi's
                                     ;   (underrom.asm), zero page: a fast-RAM spin
?dt     cmp #DOOR_DTMAX+1            ; a load hitch must not fling a door open
        bcc ?ok
        lda #DOOR_DTMAX
?ok     sta dt_vbl
        tax                          ; DOOR_STEP/DOOR_FADD = SPEED_Q8 * dvb, once per
        lda RTCLOK3                  ;   frame: update_movers doubles it (PLATSPEED*4)
        sta fps_last                 ;   and update_doors uses it as it is. A TABLE
        lda dsq_hi,x                 ;   (dt_vbl <= DOOR_DTMAX: 65 words, segment
        sta DOOR_STEP                ;   D0 below) for the product umul16 computed
        lda dsq_lo,x                 ;   at ~90 cycles a frame
        sta DOOR_FADD
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>plr_steps            ;   next byte of this segment -- fall through
.endp
        .endseg
FPS_MINVB   equ 2                    ; frame_dt's cap: VBLANKs per frame at least
        .segment D0                  ; frame_dt's dt_vbl * DOOR_SPEED_Q8 table
dsq_lo  .rept DOOR_DTMAX+1, #
        dta <[#*DOOR_SPEED_Q8]
        .endr
dsq_hi  .rept DOOR_DTMAX+1, #
        dta >[#*DOOR_SPEED_Q8]
        .endr
    .if DOOR_DTMAX*DOOR_SPEED_Q8 > 65535
        ert 'frame_dt: dt_vbl*DOOR_SPEED_Q8 no longer fits the dsq table words'
    .endif
        .endseg

;--------------------------------------------------------------
; plr_steps -- PLR_STEP/TRN_STEP for this frame: the ORIGINAL fixed per-frame
;   amounts (SPD=24 units, TURN=3 BAM).
;--------------------------------------------------------------
plrs_resume = *
        org PSTEP_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc plr_steps
        lda #SPD
        sta PLR_STEP
        ; --- THE SLOW TURN (g_game.c G_BuildTiccmd).
        ldx #0                       ; the turnheld to store back
        lda stick_save               ; bit 2 = left, bit 3 = right, 0 = pressed;
        and #$0C                     ;   $0C = neither -> turnheld = 0, exactly
        cmp #$0C                     ;   like G_BuildTiccmd's else branch
        beq ?arm
        ldx trn_held                 ; 0 = the press started THIS frame, i.e. it
        bne ?full                    ;   has already turned its one slow BAM
        inx                          ; turnheld = 1 -> full speed from here on
        ; --- TURN = TURN + TURN_FADD/256 BAM per frame, carried as a Q8 fraction
        ;     so the sub-BAM part is not lost (the DOOR_STEP/DOOR_FADD pattern
        ;     right above).
?full   stx trn_held
        lda trn_acc
        clc
        adc #TURN_FADD
        sta trn_acc                  ; (sta keeps the carry)
        lda #TURN
        adc #0                       ; the fraction's carry -> a 4-BAM frame
        sta TRN_STEP
	bra ?run
?arm    stx trn_held                 ; nothing held -> turnheld = 0 (X is 0) and
        lda #TURN_SLOW               ;   the next press starts with ONE BAM
        sta TRN_STEP                 ; (trn_acc is left alone: a whole-BAM step
?run                                 ;  has no fraction to carry)
        lda SKSTAT                   ; DOOM's run key: SHIFT doubles forwardmove
        and #SK_SHIFT                ;   (0x19 -> 0x32). The port takes a SECOND
        bne ?out                     ;   24-unit step rather than one 48-unit
        jmp move_player              ;   step, because move_player's halfway
?out    rts                          ;   collision probe only holds for step<=24
.endp                                ;   (gap 12 < PLAYER_R). frame_dt tail-calls
        .endseg
                                     ;   us AFTER the frame's first move_player
                                     ;   and BEFORE check_triggers, so a crossing
                                     ;   still sees the whole frame's travel.
;--------------------------------------------------------------
; skipx_ref -- move_player's between-axes cur_floor refresh. Grounded: a
;   committed X step may have raised the player (stairs), so the Y step-up is
;   measured from where he ACTUALLY stands now (matches gui pos_ok, which
;   probes floor_at(px,py) live).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc skipx_ref
        lda pl_air
        bne ?out
        jsr locate_floor
                                    ; 2026-09-22 (65816-windows): locate_floor returns 16-bit
        sep #$20
        lda loc_floor
        sta cur_floor
        lda loc_floor+1
        sta cur_floor+1
?out    rts
.endp
        .endseg
    .if * > PSTEP_END+1
        ert 'plr_steps/skipx_ref outgrew PSTEP_BASE..END (memory_map.inc)'
    .endif
        org plrs_resume

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_doors
        lda DOOR_NACT                ; nothing is moving -> the whole scan is skippable
        bne ?go
        rts
?go     jsr door_at_point            ; which door sector is the player in? (crush test;
        sta DOOR_PLR                 ;   one BSP descent per frame, doors moving only)
        ldx MAP_HNDOOR               ; loop control sits AHEAD of the body so the
        beq ?ret                     ;   idle path is all short branches
        dex
?l      lda.l DOOR_STATE,x
        bne ?act
?next   dex
        bpl ?l
?ret    rts
?act    lda.l DOOR_SECL,x            ; zp_ptr = &sector (built by init_doors)
        sta zp_ptr
        lda.l DOOR_SECH,x
        sta zp_ptr+1
        clc                          ; this door's move = STEP + the Q8 carry
        lda.l DOOR_FRAC,x
        adc DOOR_FADD
        sta.l DOOR_FRAC,x
        lda DOOR_STEP
        adc #0
        jsr crush_pre                ; stores DOOR_DELTA, halves it for a SLOW
                                     ;   crusher (CEILSPEED is half VDOORSPEED)
                                     ;   and comes back with DOOR_STATE in A
        cmp #1
        beq ?opening
        cmp #2
	jeq ?dwell
        ; --- closing: new = cur - delta; floor clamp, then the crush test ---
        sec
        lda.l DOOR_CURLO,x
        sbc DOOR_DELTA
        sta m_ma                     ; m_ma = the ceiling this frame WOULD reach
        lda.l DOOR_CURHI,x
        sbc #0
        sta m_ma+1
	rep #$20
	.LONGA ON
	sec
	lda m_ma
	sbc (zp_ptr)
	sta m_a
	sep #$20
	.LONGA OFF
	bmi ?shut
        beq ?shut

        lda m_a+1                    ; opening >= 256 -> everything under this
        bne ?move                    ;   ceiling still fits (P_ThingHeightClip)
        lda m_a
        cmp #PLAYER_H
        bcs ?move
        cpx DOOR_PLR                 ; ...it does not. The player under it?
        bne ?crmon
        jsr door_crush               ; a normal door goes back up and stops here;
        bcs ?crmon                   ;   a CRUSHER hurts him instead and keeps
        jsr crush_things             ;   coming down (at CEILSPEED/8 if slow)
        bra ?next                    ; (cur untouched -> nothing to write)

?crmon  jsr crush_things             ; P_ChangeSector: the MONSTERS under it too
?move   lda m_ma
        sta.l DOOR_CURLO,x
        lda m_ma+1
        sta.l DOOR_CURHI,x
        jmp ?writ

?shut
	lda (zp_ptr)
        sta.l DOOR_CURLO,x
	ldy #1	
        lda (zp_ptr),y
        sta.l DOOR_CURHI,x
;       ldy #1                       ; a CRUSHER turns straight round and rises
        lda #0                       ; a door PARKS shut: one less to scan next
        jsr door_end                 ;   frame (door_end gives DOOR_NACT back)
        jmp ?writ                    ; (other doors may still be live -- no branch trick)

?opening ; cur += delta, clamp to open, then state=open + dwell timer
        clc
        lda.l DOOR_CURLO,x
        adc DOOR_DELTA
        sta.l DOOR_CURLO,x
        lda.l DOOR_CURHI,x
        adc #0
        sta.l DOOR_CURHI,x
        lda.l DOOR_CURLO,x
        cmp.l DOOR_OPNL,x
        lda.l DOOR_CURHI,x
        sbc.l DOOR_OPNH,x
        bmi ?writ                    ; cur < open -> keep rising
        lda.l DOOR_OPNL,x            ; cur >= open -> clamp open, dwell
        sta.l DOOR_CURLO,x
        lda.l DOOR_OPNH,x
        sta.l DOOR_CURHI,x
        ldy #3                       ; a CRUSHER reverses at the top instead --
        lda #2                       ;   no dwell, and DOOR_WAIT keeps its speed
        jsr door_end                 ;   class (p_ceilng.c T_MoveCeiling case 1)
        bra ?writ

?dwell  lda.l DOORSTAY,x             ; a switch parked this door OPEN (103/2 --
        bne ?writ                    ;   p_doors.c case open: thinker removed)
        lda.l DOOR_WAIT,x            ; the dwell counts VBLANKs, not frames
        sec
        sbc dt_vbl
        sta.l DOOR_WAIT,x
        bcc ?dwend                   ; underflowed -> time is up
        bne ?writ
?dwend  lda #3                       ; dwell over -> closing
        sta.l DOOR_STATE,x
        lda #SFX_DORCLS              ; positional: a far door closes quietly or
        jsr snd_q_door_at            ;   not at all (X survives)
?writ   ldy #2                       ; write cur -> sector ceil (@ +2)
        lda.l DOOR_CURLO,x
        sta (zp_ptr),y
        iny
        lda.l DOOR_CURHI,x
        sta (zp_ptr),y
        jmp ?next
.endp
        .endseg

;--------------------------------------------------------------
; door_at_point -- descend to the subsector at (zp_px,zp_py); return A = index of
;   the door whose sector CONTAINS the point (the subsector's own front sector is in
;   MAP_DOORS), or $FF if none.
;--------------------------------------------------------------
;--------------------------------------------------------------
; use_locate -- descend the BSP from the root to the leaf containing
;   (zp_px, zp_py); OUT: zp_nid = that subsector id (bit15 set).
;   Shared by door_at_point and try_use's subsector walk. Parked at USELOC_BASE:
;   the doors block is full to the byte at $FBC0 (plr_steps), and this is cold.
;--------------------------------------------------------------
ul_resume = *
        org USELOC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_locate
                                      ; 2026-09-26: 16-bit descent through node_side
        rep #$20                     ;   (renderer.asm: calc_nodeptr + point_on_side
        .LONGA ON                    ;   fused, Y = the child's offset)
        lda MAP_HROOT                ; root node index (map header, per level)
        sta zp_nid
?w      bmi ?leaf
        jsr node_side
        lda [zp_nodeptr],y
        sta zp_nid
        bra ?w
?leaf   rts                          ; returns 16-BIT with A = zp_nid: every caller
        .LONGA OFF                   ;   went `rep #$20 / lda zp_nid` next (2026-09-26)
.endp
        .endseg
    .if * > USELOC_END+1
        ert 'use_locate outgrew USELOC_BASE..END (memory_map.inc)'
    .endif
        org ul_resume

; --- the USE-press quartet (door_at_point / use_leaf / use_sample / try_use)
;     ran here in the ambient stream, which happened to be $FA00-$FBB7 --
;     exactly where SQ2H_UROM wanted to live. All four fire once per USE
;     press, so win2 prices them at nothing (DAPUSE_BASE, 2026-08-31).
dap_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_at_point
        jsr use_locate
	.LONGA ON                    ; (2026-09-26: use_locate returns 16-bit, A = zp_nid)
	asl
	asl
;	clc
	adc #MAP_SSECT
	sta zp_ptr

	ldy #2
	lda [zp_ptr],y
	beq ?none

	lda [zp_ptr]
	asl
	asl
	asl
;	clc
	adc #MAP_SEGS
	sta zp_sptr
        ldy #SEG_FRONT               ; front_sec: the sector this subsector IS
        lda [zp_sptr],y
	and #$00ff
        sta m_a
	sep #$20
	.LONGA OFF
        jmp door_index_of            ; tail call -> A = door index, or $FF
?none	sep #$20
	.LONGA OFF
	lda #$ff
	rts
.endp
        .endseg



;--------------------------------------------------------------
; use_leaf -- test every seg of the subsector in zp_nid against the USE ray.
;   OUT: A = door index if a crossed seg is a door line ($FF = none),
;        USE_BLK = 1 if a crossed seg blocks the ray.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_leaf
        jsr leaf_segs                ; zp_sptr / zp_segcnt = this leaf's segs
                                     ;   (the body is parked in the POWER block: ...
?loop   lda zp_segcnt
        ora zp_segcnt+1
        beq ?none
        jsr use_seg_hit
        beq ?next                    ; ray does not cross this seg
        ldy #SEG_LOW                 ; bit7 = EXIT line (pack_map.py EXIT_SPECIALS:
        lda [zp_sptr],y              ;   DOOM specials 11/51/52/124, the S1 switch at
        bpl ?noexit                  ;   the end of a level). The switch sits on a
        ldy #SEG_FRONT               ;   one-sided wall, so the ray stops here anyway
        lda [zp_sptr],y              ;   -- the flag is all we need. main acts on it
        sec                          ;   after the frame is flipped; the swtchx
        sbc MAP_HSECS                ;   click comes from snd_q_nowayx.
        cmp #2                       ; ...and WHICH exit is the sector key
        bcs ?nsecr                   ;   (pack_map._secret_sector): the secret one
        lda MAP_HNEXTS               ;   owns MAP_HSECS and, for a two-sided line,
        sta MAP_HNEXT                ;   the sector behind it. $FF when the map has
?nsecr  lda #1                       ;   no secret exit -- and there MAP_HNEXTS
                                     ;   equals MAP_HNEXT, so the $FF key
                                     ;   wrapping onto sector 0 cannot matter.
        sta EXIT_REQ                 ; G_SecretExitLevel is then just this copy:
?noexit                              ;   exit_level AND wi.asm both read MAP_HNEXT,
                                     ;   and the map slot is untouched until
                                     ;   exit_level streams the next level.
        jsr switch_match             ; THE LINE'S OWN SPECIAL COMES FIRST. p_map.c
        bcs ?fired                   ;   :1099 PTR_UseTraverse tests
                                     ;   line->special and goes straight to
                                     ;   P_UseSpecialLine; what stands BEHIND the
                                     ;   line never enters into it.
        ldy #SEG_BACK                ; back_sec: none -> one-sided wall -> blocks
        lda [zp_sptr],y
        sta m_a
        cmp #NO_SECTOR
        beq ?block                   ; one-sided, and no switch on it -> a wall
        jsr door_index_of            ; back sector a door? (m_a still = back_sec)
        cmp #$FF
        beq ?plain
        tax                          ; THE SIDE THE DOOR OPENS FROM. p_switch.c
        ldy #SEG_FRONT               ;   P_UseSpecialLine: `if (side) return
        lda [zp_sptr],y              ;   false` -- a manual door answers the
        cmp.l DOOR_DENY,x            ;   FRONT sector of the line that carries the
        beq ?plain                   ;   special, and its other face has special 0
        txa                          ;   and only says "oof". pack_map names that
        rts                          ;   face's sector in DOOR_DENY, because a seg
                                     ;   cannot tell the two faces apart: BOTH
                                     ;   have the door as their back sector.
?plain  jsr use_shut                 ; not a switch face: does its opening block?
        beq ?next
?block  lda #1
        sta USE_BLK
?next
	rep #$21
	.LONGA ON
	lda zp_sptr
	adc #SEG_SIZE
	sta zp_sptr
	dec zp_segcnt
	sep #$20
	.LONGA OFF
        bra ?loop
?none   lda #$FF
        rts
?fired  lda #$FE                     ; a switch fired (its sound is queued):
        rts                          ;   stop the ray; try_use skips the toggle
.endp
        .endseg


;--------------------------------------------------------------
; use_sample -- A = distance n along the player's facing (0..USERANGE);
;   OUT: zp_px/zp_py = USE_PT_A + n*(cos,sin) -- where DOOM's trace would be.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_sample
        sta m_ma                     ; keep n (smul_14 eats m_a)
	rep #$20
	.LONGA ON
	and #$00ff
	sta m_a
        lda zp_cos
        sta m_b
	sep #$20
	.LONGA OFF
        jsr smul_14                  ; m_res = n*cos
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit,
        clc                          ;   and that rep also cleared C
	.LONGA ON
;       lda USE_PT_A                 ; smul_14 leaves m_res IN A: add the other
        adc USE_PT_A                 ;   operand to it (the sum commutes)
        sta zp_px
	lda m_ma
	and #$00ff
	sta m_a
        lda zp_sin
        sta m_b
	sep #$20
	.LONGA OFF
        jsr smul_14                  ; m_res = n*sin
                                    ; 2026-09-22 (65816-windows): smul_14 returns 16-bit,
        clc                          ;   and that rep also cleared C
	.LONGA ON
;       lda USE_PT_A+2               ; smul_14 leaves m_res IN A (as above)
        adc USE_PT_A+2
        sta zp_py
                                    ; 2026-09-22 (65816-windows): use_sample returns 16-bit
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; try_use -- DOOM P_UseLines (p_map.c). Walk a ray USERANGE units forward, visit
;   the subsectors it passes through in order, and in each one test the segs the
;   ray CROSSES: activate the first door line, stop at the first wall.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc try_use
	rep #$20
	.LONGA ON
        lda zp_px                    ; USE_PT_A = the real player position (the walk
        sta USE_PT_A                 ;   moves zp_px/zp_py, the BSP descent reads it)
        lda zp_py
        sta USE_PT_A+2
	sep #$20
	.LONGA OFF
        lda #USE_STEP*USE_NSTEPS     ; USE_PT_B = the ray END, USERANGE ahead
        jsr use_sample

                                    ; 2026-09-22 (65816-windows): use_sample returns 16-bit
	.LONGA ON
        lda zp_px
        sta USE_PT_B
        lda zp_py
        sta USE_PT_B+2
	lda #$ffff
	sta USE_SS
	sep #$20
	.LONGA OFF
	sta USE_DOOR
	stz USE_BLK
	stz USE_N
?loop   lda USE_N                    ; zp_px/zp_py = A + n * facing
        jsr use_sample
                                    ; 2026-09-22 (65816-windows): use_sample returns 16-bit
        sep #$20
        jsr use_locate               ; zp_nid = leaf at (zp_px, zp_py)
	.LONGA ON                    ; (2026-09-26: use_locate returns 16-bit, A = zp_nid)
	cmp USE_SS
	beq ?step
	sta USE_SS
	sep #$20
	.LONGA OFF
        jsr use_leaf                 ; A = door index, USE_BLK = hit a wall
        cmp #$FF
        bne ?hit
        lda USE_BLK
        bne ?restore                 ; "can't use through a wall"
?step
	sep #$20
	.LONGA OFF
	clc                          ; next sample, USE_STEP further along the ray
        lda USE_N
        adc #USE_STEP
        sta USE_N
        cmp #USE_STEP*USE_NSTEPS+1   ; still within USERANGE -> keep walking
        bcc ?loop
        bcs ?restore                 ; ray exhausted, no door
?hit    jsr gun_seg_p                ; use_leaf stopped ON the crossed seg: the 46
        bcc ?nogun                   ;   line opens NOTHING by hand, from either
        lda #$FE                     ;   side, and says nothing either -- p_map.c
?nogun  sta USE_DOOR                 ;   :1099 sounds noway ONLY for a line with no
?restore                             ;   special, and 572 has one. $FE is try_use's
                                     ;   silent stop (the switch-fired path)
	rep #$20
	.LONGA ON
        lda USE_PT_A                 ; restore the real player position
        sta zp_px
        lda USE_PT_A+2
        sta zp_py
	sep #$20
	.LONGA OFF
        lda USE_DOOR
        cmp #$FF
        beq ?none
        cmp #$FE                     ; a switch line fired -- its action queued
        beq ?swit                    ;   its own sound, and there is no DR door
        bra use_door_go              ; A = door index -> key check, then DR/D1 open
?none   lda USE_BLK                  ; p_map.c PTR_UseTraverse: the "uh-uh"
        beq ?swit                    ;   belongs to a WALL (openrange <= 0); a
        jmp snd_q_nowayx             ;   ray that just RAN OUT found nothing
                                     ;   and says nothing -- spacebar into open ...
?swit   rts                          ; (also the EXIT switch's silent stop --
                                     ;   snd_q_nowayx plays ITS click)
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org dap_resume

;--------------------------------------------------------------
; use_door_go -- A = door index the USE ray hit. EV_VerticalDoor's key gate
;   (p_doors.c:186-244), the same shape as w3d Cmd_Use: MAP_DOORLOCK[door]
;   bits0-2 = the PS_KEYS bit this door needs (blue=1 yellow=2 red=4, card and
;   skull share a bit like P_CheckKeys), 0 = unlocked.
;--------------------------------------------------------------
udg_resume = *
        org USEDOORGO_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc use_door_go
        tax
        lda MAP_DOORLOCK,x           ; (under-ROM read: USE runs after rom_out)
        and #$27                     ; key bits 0-2 -- plus bit5, "this door has
                                     ;   no PUSH line at all" (pack_map _doors).
        beq ?open
        and PSTATE+PS_KEYS           ; the one required key bit present?
        beq ?locked
?open   lda MAP_DOORLOCK,x
        bpl ?dr
        lda #1                       ; D1: park OPEN forever once used
        sta.l DOORSTAY,x
        jmp door_force_open.dfo_go   ; X = door index; open + positional SFX.
?dr     txa
        jmp snd_door_toggle          ; DR: the normal toggle + open/close SFX
?locked
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>door_keymsg          ;   next byte of this segment -- fall through
.endp                                ;   nothing moves (tail-parked: this
        .endseg
                                     ;   block has 4 B of slack)
    .if * > USEDOORGO_END+1
        ert 'use_door_go outgrew USEDOORGO_BASE..END (memory_map.inc)'
    .endif
;--------------------------------------------------------------
; door_keymsg -- use_door_go's locked tail (X = the door): DOOM shows
;   PD_BLUEK/YELLOWK/REDK with the oof; this port's message line shows the
;   ONE colour-blind PD strip (the array is a row from full -- pack_menu.py's
;   note).
;--------------------------------------------------------------
dkm_resume = *
        org DKEYMSG_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_keymsg
        lda MAP_DOORLOCK,x           ; a key bit refused the door?
        and #7
        beq ?nw
        lda #36+MSG_IDX0             ; the PD strip (pack_menu.py)
        jsr msg_set.msg_arm
                                      ; 2026-09-22 idiom: snd_q_noway inlined (the tail
?nw     lda #SFX_NOWAY               ;   jmp went: -3) ...and the "uh-uh" either way
        sta snd_pending
        rts
.endp
        .endseg
    .if * > DKEYMSG_END+1
        ert 'door_keymsg outgrew DKEYMSG_BASE..END (memory_map.inc)'
    .endif
        org dkm_resume
        org udg_resume

;==============================================================
; SWITCHES (S1/SR) + walkover doors -- 1:1 with _pomocne/_doomsrc:
;   p_switch.c P_UseSpecialLine:  103 S1 EV_DoDoor(open)   62 SR EV_DoPlat(DWU)
;                                  29 S1 EV_DoDoor(normal)  63 SR EV_DoDoor(normal)
;   p_spec.c  P_CrossSpecialLine:   2 W1 EV_DoDoor(open)    90 WR EV_DoDoor(normal)
;==============================================================

;--------------------------------------------------------------
; switch_match -- is the crossed seg (zp_sptr) a USE-activated trigger line?
;   (b14. A GUN record, b8, carries no b14 and is invisible here on purpose --
;   gun_match owns those, off the seg a BULLET stopped on.)
;   Fires every matching record (a tag can move several sectors). C=1 if any
;   fired. Preserves zp_sptr/zp_segcnt (use_leaf's loop); clobbers A/X/Y+zp_ptr.
;--------------------------------------------------------------
swf_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc switch_match
        stz sw_hit
        stz mv_i
?loop   lda mv_i
        cmp THINGS_BASE+13           ; trigger count
        bcs ?done
        jsr mv_used_get              ; a spent S1 button? (C=1 -> skip)
        bcs ?nx
        jsr mv_ptr                   ; zp_ptr = the record
        ldy #13
        lda (zp_ptr),y
        and #$40                     ; b14 = USE-activated
        beq ?nx

        ldy #4                       ; 4 seg-record address slots @ bytes 4..11
	rep #$20
	.LONGA ON
?slot	lda (zp_ptr),y
	cmp zp_sptr
	beq ?hitw
	iny
	iny
	cpy #12
	bcc ?slot
	sep #$20
	.LONGA OFF
	bra ?nx
?hitw	sep #$20
	.LONGA OFF
?hit    ldy #13
        lda (zp_ptr),y
        sta sw_fl                    ; flags: b12 once = S1, clear = SR button
        jsr trig_fire                ; keeps mv_i/zp_ptr
        inc sw_hit                   ; only ever tested for "not zero"
?nx     inc mv_i
	bra ?loop
?done   lda sw_hit
        beq ?no
        jsr sw_swap                  ; P_ChangeSwitchTexture (SW1 -> SW2)
        bcc ?nosw                    ; BUG FIX 2026-09-15: p_switch.c plays sfx_swtchn
        lda #SFX_SWTCHN              ;   C=1). E3M1's lift "door" (62 on BIGDOOR7)
        sta snd_pending              ;   has none, and the click overwrote its
?nosw   sec                          ;   sfx_pstart in the single sound slot
        rts
?no     clc
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
sw_hit  dta 0

;--------------------------------------------------------------
; sw_swap -- P_ChangeSwitchTexture: flip the pressed seg's SW1 texid to its
;   SW2 mate (textab row MAP_TEXSWMATE, packed by pack_textures.py). Tries the
;   wall byte, then the lower (62 sits on lift fronts' lower texture). An SR
;   button (sw_fl b12 clear) arms the one button slot to flip back after
;   BUTTONTIME (update_button); S1 stays pressed forever.
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sw_swap
        ldy #SEG_WALL
        jsr ?try
        bcs ?arm
        ldy #SEG_LOW
        jsr ?try
        bcc ?out                     ; neither byte is a switch face
?arm    lda sw_fl
        and #$10                     ; b12 = once (S1)
        bne ?out
        lda zp_sptr                  ; SR: arm the (single) button slot
        sta btn_ptr
        lda zp_sptr+1
        sta btn_ptr+1
        lda sw_y
        sta btn_y
        lda btn_old
        sta btn_tex
        lda #BTN_VB
        sta btn_timer
?out    rts
;  Y = seg byte (SEG_WALL/SEG_LOW): texid in bits 0-5. C=1 if it swapped.
?try    sty sw_y
        lda [zp_sptr],y
        sta btn_old                  ; the whole byte, for the flip back
        and #SEG_TEXM
        cmp #SEG_TEXM                ; $7F is "THIS SLOT HAS NO TEXTURE", not a
        beq ?nosw                    ;   texid -- and MAP_TEXSWMATE is TEX_COUNT
                                     ;   = 63 entries wide (0..62), so index $3F
                                     ;   reads the first byte of the NEXT row,
                                     ;   MAP_TEXIXLO[0].
        tax
        lda.l MAP_TEXSWMATE,x        ; $FF = not a switch texture (EXT bank row)
        cmp #$FF
        beq ?nosw
        sta sw_t
        lda btn_old
        and #$80                     ; keep the blocking / EXIT bit
        ora sw_t
                                      ; 2026-09-22 idiom: Y IS sw_y (?try's sty; tax and
        sta [zp_sptr],y
        sec
        rts
?nosw   clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; trig_fire -- run the trigger record at zp_ptr: DOOR actions go to the door
;   state machine, the rest is a floor/plat for mv_start. Shared by
;   check_triggers (walkover) and switch_match (USE). Preserves mv_i/zp_ptr.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc trig_fire
        ldy #13
        lda (zp_ptr),y
        and #$20                     ; b13 = DOOR action
        bne ?door
        lda (zp_ptr),y               ; (Y still 13) b9 WITHOUT b13 = STOP the
        and #$02                     ;   plat, p_spec.c case 89 EV_StopPlat. The
                                      ; 2026-09-22 (drac030 inline): mv_stop -- its rts returns
        beq ?nstop                   ;   from trig_fire, as the jmp's did
        ldx #MV_NMAX-1
?stop   stz MV_STATE,x
        dex
        bpl ?stop
        rts
?nstop
                                     ;   mv_stop's rts returns from trig_fire
                                     ;   directly.
        jsr mv_free                  ; a slot for this record? mv_free also runs
        bcs ?go                      ;   EV_DoPlat's "if (sec->specialdata)
        rts                          ;   continue" -- all busy, or that sector is
                                     ;   already moving: drop this fire and do
                                     ;   NOT spend the once-bit (try again later)
?go     jsr mv_start                 ; stays-down floors mark the bitmap there
        jmp ?once

?door   lda (zp_ptr),y               ; (Y is still 13) b15 WITH b13 is not a door
	jmi trig_light
        ldy #12                      ; door index from the tagged sector id
        lda (zp_ptr),y
        sta m_a
	stz m_a+1
        jsr door_index_of
        cmp #$FF
        beq trig_light 
        ;jmp trig_light               ; no door carries this tag: either the LIGHTS ...
?have
        tax
        ldy #14                      ; DST. A door record has never used it ("the
        lda (zp_ptr),y               ;   height is in MAP_DOORS"), so it is where
	jne trig_crush
	dey                          ; ...and back to 13, the flags
        lda (zp_ptr),y
        and #$08                     ; b11 = the door parks OPEN (103 / type 2)
        beq ?fo
        lda #1
        sta.l DOORSTAY,x
?fo     jsr door_force_open
?once
tl_once ldy #13                      ; (trig_light comes back in here)
        lda (zp_ptr),y
        and #$10                     ; b12 = once -> spend the fired-bitmap bit
        beq ?out
        jmp mv_used_set
?out    rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org swf_resume


;--------------------------------------------------------------
; trig_light -- p_spec.c case 35 / p_lights.c EV_LightTurnOn: every sector with
;   the line's tag takes a fixed light level (35, "Lights Very Dark"). The
;   packer emits one record per tagged sector, so this is one write; the level
;   itself rides in the record's dst field, where a floor keeps its height.
;--------------------------------------------------------------
tl_resume = *
        org TRIGLT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc trig_light
	ldy #12
	rep #$20
	.LONGA ON
	lda (zp_ptr),y
	bpl ?w
	and #$00ff
	asl
	asl
	asl
;	clc
	adc #MAP_SECTORS
	sta zp_mvsec
	sep #$20
	.LONGA OFF
        ldy #14                      ; the LEVEL rides where a floor keeps its
        lda (zp_ptr),y               ;   height
        ldy #4                       ; sector->lightlevel
        sta (zp_mvsec),y
tl_back jmp trig_fire.tl_once        ; and spend the W1 bit
?w	sep #$20
	bra tl_back
.endp
        .endseg
    .if * > TRIGLT_END+1
        ert 'trig_light outgrew TRIGLT_BASE..END (memory_map.inc)'
    .endif
        org tl_resume

;--------------------------------------------------------------

;--------------------------------------------------------------
; gun_seg_p / gun_match -- p_spec.c P_ShootSpecialLine, the half a DOOM episode
;   needs: special 46, GR "open door on impact". E1M2's secret computer wall
;   (linedef 572, tag 6 -> sector 188) is the only one in episode 1, so the
;   packer hands the engine ONE seg address instead of a table to scan.
;--------------------------------------------------------------
gm_resume = *
        org GUNMATCH_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc gun_seg_p                      ; C=1 if zp_sptr is EITHER face of the 46
        pha                          ;   line. A survives (try_use still needs it)
                                     ; 2026-09-22 (6502-idioms: counting UP to zero):
        ldy #256-4                   ;   Y = $FC, $FE = slots 26, 28 (the callers read
	rep #$20
	.LONGA ON
?l	lda zp_sptr
	cmp THINGS_BASE+30-256,y
	beq ?yes
	iny                          ; 0 on a level with no gun line, and no seg
        iny                          ;   record ever lives at $0000
        bne ?l
	sep #$20
	.LONGA OFF
        pla
        clc
        rts

?yes
	sep #$21
	.LONGA OFF
	pla
        rts
.endp
        .endseg
    .if * > GUNMATCH_END+1
        ert 'gun_seg_p outgrew GUNMATCH_BASE..END (memory_map.inc)'
    .endif
        org gm_resume

gf_resume = *
        org GUNFIRE_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc gun_match                      ; fire it: the record index is in the header too
        jsr gun_seg_p
        bcc ?out
        lda THINGS_BASE+30
        sta mv_i
        jsr mv_ptr                   ; zp_ptr = the trigger record
        jsr trig_fire                ; EV_DoDoor(open) + DOORSTAY (b11)
        ldx en_snd_q                 ; the DOROPN snd_q_door_at just queued is
        bpl ?out                     ;   about to be overwritten: wp_fire_a stores
        lda snd_pending              ;   the GUNSHOT into snd_pending after
        bmi ?out                     ;   en_gunshot returns. Move the door onto the
        ldx #$FF                     ;   other queue byte while it is free and
        stx snd_pending              ;   snd_dispatch starts both, each on its own
        sta en_snd_q                 ;   voice (SND_NV = 4)
?out    rts
.endp
        .endseg
    .if * > GUNFIRE_END+1
        ert 'gun_match outgrew GUNFIRE_BASE..END (memory_map.inc)'
    .endif
        org gf_resume

;--------------------------------------------------------------
; door_force_open -- X = door index: make it open (NOT the DR toggle: an
;   already-open door stays put). Queues the door-open sound.
;--------------------------------------------------------------
dfo_resume = *
        org DFORCE_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_force_open
        ldy #13                      ; TRIGGER-RECORD entry: zp_ptr = the record
        lda (zp_ptr),y
        and #$02                     ; b9 = the action CLOSES
        bne ?shut
dfo_go                               ; no-record entry: open, never close
        lda.l DOOR_STATE,x
        cmp #1
        beq ?out                     ; already opening
        cmp #2
        beq ?out                     ; already open (dwelling / parked)
        cmp #3
        beq ?rev                     ; closing -> reopen (still counted live)
        inc DOOR_NACT                ; closed -> wake it
?rev    lda #1
        sta.l DOOR_STATE,x
        lda #SFX_DOROPN              ; positional: a REMOTE door opens quietly
        bra snd_q_door_at            ;   or silently (s_sound.c attenuation)
?out    rts
?shut   lda (zp_ptr),y               ; Y is still 13 HERE -- the b9 test at the
                                     ;   top of this proc left it, and ?shut is
                                     ;   only reachable through that test.
        and #$08                     ; b11 WITH b9 = close and STAY shut, i.e.
        eor #$08                     ; 8 -> 0 (stay shut), 0 -> 8 (arm the timer)
        lsr @
        lsr @                        ; ...8 lands on b1, which is what
                                     ;   update_door30 waits on, and b0 (parked
                                     ;   open) comes out 0 either way -- it has
                                     ;   to, or the dwell test never fires.
        pha                          ; onto the stack, not into a RAM cell
        lda.l DOOR_STATE,x           ; already on its way down? leave it alone
        cmp #3
        beq ?outp
        tay                          ; parked (0) -> it joins the live scan
        bne ?go
        inc DOOR_NACT
?go     lda #3
        sta.l DOOR_STATE,x
        pla
        sta.l DOORSTAY,x
        lda #SFX_DORCLS
        bra snd_q_door_at
?outp   pla                          ; the early exit has to balance it
        rts
.endp
        .endseg
    .if * > DFORCE_END+1
        ert 'door_force_open outgrew the DFORCE hole (memory_map.inc)'
    .endif
        org dfo_resume

;--------------------------------------------------------------
; update_button -- the SR button face flips back BUTTONTIME after the press
;   (p_spec.h: 35 tics = 1 s = 50 PAL VBLANKs). One slot; runs once per frame.
;--------------------------------------------------------------
btu_resume = *
        org BTNUPD_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc update_button
        lda btn_timer
        bne ?run
        rts
?run    sec
        sbc dt_vbl
        bcs ?ok
        lda #0
?ok     sta btn_timer
        bne ?out
        lda btn_ptr                  ; time: put the SW1 byte back on the seg.
        sta zp_sptr                  ;   THROUGH zp_sptr, exactly like sw_swap
        lda btn_ptr+1                ;   wrote it in the first place: btn_ptr is
        sta zp_sptr+1                ;   only the seg's OFFSET, so the store has
        ldy btn_y                    ;   to be a LONG one into the seg bank
        lda btn_tex                  ;   (map_syms.inc:14, [[map-offsets-not-
        sta [zp_sptr],y              ;   addresses]] -- plain (zp),y here wrote
                                     ;   btn_tex into BASE RAM: seg 683, E1M4's ...
        lda #SFX_SWTCHN              ; the button pops back out (p_switch.c)
        sta snd_pending
?out    rts
.endp
        .endseg
btn_timer dta 0                      ; VBLANKs left (0 = idle)
btn_ptr   dta 0,0                    ; seg record holding the flipped byte
btn_y     dta 0                      ; which byte (SEG_WALL / SEG_LOW)
btn_tex   dta 0                      ; the original byte to restore
btn_old   dta 0                      ; sw_swap scratch (original byte)
sw_y      dta 0
sw_t      dta 0
sw_fl     dta 0
    .if * > BTNUPD_END+1
        ert 'update_button outgrew BTNUPD (memory_map.inc)'
    .endif
        org btu_resume

;--------------------------------------------------------------
; snd_q_door_at -- queue a door SFX only if the door is AUDIBLE: p_doors.c
;   plays at the door sector's soundorg (bbox centre, MAP_DOORS record +4) and
;   s_sound.c cuts it dead past S_CLIPPING_DIST (1200).
;--------------------------------------------------------------
sda_resume = *
        org SNDDIST_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_q_door_at
        sta sda_id
        stx sda_x
        txa
        asl
        asl                          ; MAP_DSND records are 4 B: {i16 x, i16 y}.
        tay                          ;   FOUR and not eight, so this index still
                                     ;   fits a byte at DOORS_NMAX 48 (47*4=188);
                                     ;   at the old 8 B stride it wrapped past 31
	rep #$20
	.LONGA ON
	sec
        lda zp_px
        sbc MAP_DSND+0,y
	sta sda_sx                   ; the SIGN survives for snd_setpan (16-bit
	bpl ?ax                      ;   store: the high byte lands in sda_sx+1)
	eor #$ffff
	inc
?ax	sta m_a
	sec
        lda zp_py
        sbc MAP_DSND+2,y
	sta sda_sy                   ; ... and dy's
	bpl ?ay
	eor #$ffff
	inc
?ay	sta m_b

	lda m_a
	cmp m_b
	bcs ?far

	lda m_b
	sta m_a

?far	cmp #1200
	sep #$20
	.LONGA OFF
        bcs ?silent
        jsl snd_setpan_w0               ; STEREO: which ear gets this door
        ldx sda_id                   ; PLAY it, do not queue it: snd_pending is
        jsr snd_play                 ;   one byte and spr_pickup runs later in
                                     ;   the same frame -- the key's ITEMUP ...
?silent ldx sda_x
        rts
.endp
        .endseg
sda_id  dta 0
sda_x   dta 0
    .if * > SNDDIST_END+1
        ert 'snd_q_door_at outgrew SNDDIST (memory_map.inc)'
    .endif
        org sda_resume

;--------------------------------------------------------------
; snd_setpan -- QUADRANT pan for the door snd_q_door_at is about to start:
;   snd_side = pan_tab[world quadrant of the door * 4 + facing quadrant].
;--------------------------------------------------------------
spn_resume = *
        org SNDPAN_BASE
; snd_setpan LEFT for sound.asm (SNDPAN2, 2026-09-09): the monsters wanted DOOM's
;   angle model (s_sound.c S_AdjustSoundParams: sep = 128 - 96*sin(angle to the
;   source, relative to the facing), silence past S_CLIPPING_DIST) and the
;   quadrant table below could not say "centre" at all. Same contract for
;   the door: sda_sx/sda_sy = player - soundorg, words. The variables stay
;   here; the code and its tables live in the bigger hole.
sda_sx  dta 0,0                     ; 16-bit cells: snd_q_door_at stores
sda_sy  dta 0,0                     ;   the whole difference, the sign is +1
sda_f   dta 0
snd_side dta 0                       ; the NEXT snd_play's pan; 0 = centre
    .if * > SNDPAN_END+1
        ert 'snd_setpan outgrew SNDPAN_BASE..END (memory_map.inc)'
    .endif
        org spn_resume

;==============================================================
; CRUSHERS -- p_ceilng.c EV_DoCeiling / T_MoveCeiling, on the door mover.
;==============================================================
crush_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; crush_pre -- A = the whole-unit ceiling step door X takes this frame.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc crush_pre
        sta DOOR_DELTA
        lda MAP_DOORLOCK,x           ; (under-ROM read: the frame loop banks the
        and #CRUSH_BIT              ;   OS ROM out -- bsp_main.asm's rom_out)
        beq ?out
        jsr snd_q_grind              ; T_MoveCeiling plays sfx_stnmov on
                                     ;   !(leveltime&7), which is snd_q_grind's ...
        lda.l DOOR_WAIT,x            ; the crusher's speed class: 0 = CEILSPEED,
        beq ?half                    ;   1 = CEILSPEED*2 (special 77),
        cmp #1                       ;   2 | acc<<4 = CEILSPEED/8 (crush_slow)
        beq ?out
        lsr
        lsr
        lsr
        lsr                          ; acc; C=0 -- the class nibble is 2
        adc DOOR_DELTA               ; + this frame's whole step (< 256)
        pha
        lsr
        lsr
        lsr
        lsr                          ; /16: VDOORSPEED is 2*CEILSPEED
        sta DOOR_DELTA
        pla
        asl
        asl
        asl
        asl                          ; what did not move yet rides to next frame
        ora #2
        sta.l DOOR_WAIT,x
        bra ?out
?half   lsr DOOR_DELTA
?out    lda.l DOOR_STATE,x
        rts
.endp

;--------------------------------------------------------------
; crush_slow -- something does not fit under crusher X: crushAndRaise drops to
;   CEILSPEED/8 until the bottom (p_ceilng.c:154, door_end resets); the fast
;   one never slows. Preserves X.
;--------------------------------------------------------------
.proc crush_slow
        lda.l DOOR_WAIT,x
        bne ?out                     ; fast, or slowed already (acc kept)
        lda #2
        sta.l DOOR_WAIT,x
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; door_crush -- the descending ceiling has caught the player (update_doors'
;   opening < PLAYER_H test). p_doors.c sends a `normal` door back UP, and that
;   is what T_MovePlane's `crushed` means for a door.
;   OUT: C=1 = go on moving (a crusher), C=0 = leave the ceiling alone.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_crush
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        bne ?hurt
        lda #1                       ; an ordinary door: back up (p_doors.c:151)
        sta.l DOOR_STATE,x
        clc
        rts
?hurt   lda dt_vbl                   ; P_DamageMobj(player, NULL, NULL, 10) every
        asl                          ;   4 tics = CRUSH_DMG_VB a VBLANK, scaled
        jsr en_plr_hurt              ;   by the frame like every other timer
                                     ;   here. X survives it (enemy.asm) --
                                     ;   update_damage leans on the same fact
        jsr crush_slow
        sec
        rts
.endp
        .endseg

;--------------------------------------------------------------
; door_end -- door X has arrived at one end of its travel.
;   IN: A = the state an ORDINARY door takes there (2 = dwell at the top,
;           0 = parked shut)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc door_end
        pha
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        beq ?door
        pla
        tya                          ; the crusher's other direction
        sta.l DOOR_STATE,x
        lda.l DOOR_WAIT,x            ; pastdest: speed = CEILSPEED again
        and #1                       ;   (p_ceilng.c:131) -- fast stays fast
        sta.l DOOR_WAIT,x
        rts
?door   pla
        sta.l DOOR_STATE,x           ; (A survives the store, for the cmp)
        cmp #2
        beq ?dwell
        dec DOOR_NACT                ; parked: one less to scan next frame
        rts
?dwell  lda #DOOR_DWELL_VB           ; the dwell counts VBLANKs
        sta.l DOOR_WAIT,x
        rts
.endp
        .endseg

;--------------------------------------------------------------
; trig_crush -- a crusher line was crossed (trig_fire, off the record's dst).
;   IN: A = 1 (73 crushAndRaise) | 2 (77 fastCrushAndRaise) | 3 (74 stop)
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc trig_crush
        cmp #3
        beq ?halt
        pha
        lda.l DOOR_STATE,x
        bne ?pull                    ; already running -> leave it alone
        inc DOOR_NACT                ; one more live ceiling for update_doors
        lda #3                       ; EV_DoCeiling: direction = -1, i.e. DOWN
        sta.l DOOR_STATE,x
        pla
        lsr                          ; dst 1 -> speed 0 (CEILSPEED),
        sta.l DOOR_WAIT,x            ;     dst 2 -> speed 1 (CEILSPEED*2)
        bpl ?out                     ; (always: the lsr cleared bit 7)
?pull   pla
?out    jmp trig_fire.tl_once        ; the tail every fired trigger ends on
?halt   lda.l DOOR_STATE,x           ; EV_CeilingCrushStop: park it where it
        beq ?out                     ;   stands, and stop scanning it
        dec DOOR_NACT
        lda #0
        sta.l DOOR_STATE,x
	bra ?out
.endp
        .endseg

;--------------------------------------------------------------
; crush_things -- P_ChangeSector(sector, true) for the crusher whose door index
;   is X: the MONSTERS under the descending ceiling, not only the player.
;   Preserves X and m_ma (the ceiling ?move is about to store) and rebuilds
;   zp_ptr, which door_at_point clobbers.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc crush_things
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        bne ?go
?rts    rts                          ; an ordinary door crunches nobody here:
                                     ;   P_ChangeSector(crunch=false) only says ...
?go     stx ct_d
	rep #$20
	.LONGA ON
        lda m_ma                     ; ?move still wants the new ceiling, and
        sta ct_m                     ;   door_at_point/en_bhit own the maths
        lda zp_px                    ; ...and the player's probe point, which
        sta ct_p                     ;   door_at_point reads
        lda zp_py
        sta ct_p+2
	sep #$20
	.LONGA OFF
	stz en_bi
?lp     lda en_bi
        cmp THINGS_BASE              ; the thing count (blob header +0)
        bcs ?done

        ldy en_bi
        lda #<TH_HPL                 ; (every bank $01 page has low byte 0)
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        lda [zp_ptr],y
        sta m_a
        lda #>TH_HPH
        sta zp_ptr+1
        lda [zp_ptr],y
        ora m_a
        beq ?next                    ; 0 health: a decoration, or already dead
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?next                    ; already dying -- PIT_ChangeSector gibs a
                                     ;   corpse; there is no gib state here
        lda en_bi                    ; its x/y -> the point to place
        jsr en_thing.en_th2w          ; 2026-09-22: returns 16-bit
	.LONGA ON
        lda (sp_ptr)
        sta zp_px
        ldy #2
        lda (sp_ptr),y
        sta zp_py
	sep #$20
	.LONGA OFF
        jsr door_at_point            ; standing in THIS crusher's sector?
        cmp ct_d
        bne ?next
        tax                          ; (= ct_d) a MONSTER slows it as the player
        jsr crush_slow               ;   does: `crushed` does not ask who
        lda dt_vbl                   ; the same 10-every-4-tics the player takes
        asl                          ;   (CRUSH_DMG_VB), scaled by the frame
        jsr en_bhit                  ; P_DamageMobj: health, death, the scream
?next   inc en_bi
        bne ?lp                      ; (always: the count is a byte)
?done
	rep #$20
	.LONGA ON
	lda ct_p
        sta zp_px
        lda ct_p+2
        sta zp_py
        lda ct_m
        sta m_ma
	sep #$20
	.LONGA OFF
        ldx ct_d                     ; update_doors' door index and its sector
        lda.l DOOR_SECL,x            ;   pointer, both of which the descent and
        sta zp_ptr                   ;   the damage above went through
        lda.l DOOR_SECH,x
        sta zp_ptr+1
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
ct_d    dta 0                        ; the door being crushed under
ct_m    dta 0,0                      ; m_ma across the sweep
ct_p    dta 0,0,0,0                  ; the player's probe point across it
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org crush_resume
