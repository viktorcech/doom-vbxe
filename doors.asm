        .if MAP_NDOORS > DOORS_NMAX
                ert 'MAP_NDOORS > DOORS_NMAX -- widen the DOOR_EXT block (memory_map.inc)'
        .endif
        .if DOORSTAY+DOORS_NMAX > DOOR_BASE+$400
                ert 'the DOOR_* arrays outgrew DOOR_EXT and would reach TH_HPL'
        .endif


    .if MAP_NDEDGE > DEDGE_NMAX
        ert 'a level has more door edges than DEDGE_NMAX -- widen it (memory_map.inc)'
    .endif
    .if MK_HMAX > 255
        ert 'door_fit takes the opening in A: MK_HMAX must stay a byte'
    .endif

        .segment B1
.proc door_index_of                  ; m_a = sector id -> A = door index, or $FF
        ldx MAP_HNDOOR               ; this LEVEL's door count (0 -> straight out)
        beq ?no
        dex                          ; a compare per door, a sector id is a byte
?l      lda.l DOOR_SIDL,x
        cmp m_a
        beq ?yes
?nx     dex
        bpl ?l
?no     lda #$FF
        rts
?yes    txa
        rts
.endp
        .endseg

;--------------------------------------------------------------
; door_use -- p_doors.c EV_VerticalDoor for a DR door, A = door index (the
;   player's USE, or a monster's P_Move). A shut door gets a new thinker:
;   opening, sfx_doropn at its soundorg (dfo_go). A door already moving is
;   only flipped -- closing goes back up, opening/waiting comes down -- and
;   p_doors.c:416-436 returns before any sound for that.
;--------------------------------------------------------------
        .segment B1
.proc door_use
        tax
        lda.l DOOR_STATE,x
        jeq door_force_open.dfo_go   ; shut: wake it, DOROPN positional
        cmp #3                       ; C = 1: closing -> opening
        lda #1
        bcs ?put
        lda #3                       ; opening / waiting -> closing, at once
?put    sta.l DOOR_STATE,x
        rts
.endp
        .endseg

;--------------------------------------------------------------
; init_doors -- all doors closed (cur = ceil = floor) AND build the per-level
;   tables the frame loop reads: sector pointer, open_ceil, sector id.
;--------------------------------------------------------------
        .segment B1
.proc init_doors
        stz DOOR_TRIGPREV
        stz DOOR_NACT                ; nothing animating yet
        stz D30_ON                   ; ...and no close30 door armed
        stz btn_timer                ; no SR button mid-flip from the old level
        stz face_t                   ; face picks on the first frame
        lda #1                       ; paint the shared bar once
        sta hud_dirty                ;   (w3d hud_dirty model -- see hud.asm)
        lda #HUD_FACE
        sta face_cur                 ; doomguy starts looking straight ahead
        lda RTCLOK3                  ; prime the VBLANK clock: the first frame must
        sta fps_last                 ;   see a small delta, not "since power-on"
        ldx MAP_HNDOOR               ; this LEVEL's door count (see the note above)
        beq de_build                 ; (no doors: de_build still empties DE_S2D)
        dex
?l      txa                          ; door record @ MAP_DOORS + X*4
        asl                          ;   (u8 sector, u8 deny, i16 open_ceil).
        asl                          ;   The soundorg pair is MAP_DSND's own
        tay                          ;   4 B record -- see snd_q_door_at.
        lda MAP_DOORS+1,y            ; the byte the sector id's high half left:
        sta.l DOOR_DENY,x            ;   the face USE is refused from (use_leaf)
        lda MAP_DOORS+2,y            ; open_ceil -> DOOR_OPNL/H
        sta.l DOOR_OPNL,x
        lda MAP_DOORS+3,y
        sta.l DOOR_OPNH,x
        lda MAP_DOORS,y              ; sector id -> DOOR_SIDL
        sta.l DOOR_SIDL,x
        rep #$20                     ; zp_ptr = MAP_SECTORS + sec*8, one word
        .LONGA ON
        and #$00FF
        asl @
        asl @
        asl @                        ; (sec < 256: C = 0 for the add)
        adc #MAP_SECTORS
        sta zp_ptr
        sep #$20
        .LONGA OFF
        sta.l DOOR_SECL,x
        xba
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
                                      ; the door edges door_touch reads (falls in:
        ert *<>de_build              ;   de_build is the next proc of the segment)
.endp

;--------------------------------------------------------------
; de_build -- init_doors' second half: every TWO-SIDED seg with a door sector
;   in front, as an edge of that door (memory_map.inc DEDGE_EXT). A counting
;   sort over the level's segs: count per door, running sums into DE_END and
;   DE_FIRST, then each edge goes in at --DE_FIRST, which leaves DE_FIRST at
;   the door's first edge and DE_END one past its last. Load time only.
;--------------------------------------------------------------
.proc de_build
        lda #$FF                     ; DE_S2D: no sector is a door ...
        ldx #0
?f      sta.l DE_S2D,x
        inx
        bne ?f
        ldx MAP_HNDOOR               ; ... but these
        beq ?none
?s      dex
        txa
        asl @                        ; door*2, ready to index the word tables
        txy
        pha
        lda.l DOOR_SIDL,x
        tax
        pla
        sta.l DE_S2D,x
        tyx
        bne ?s
?none   rep #$30
        .LONGA ON
        .LONGI ON
        ldx #DOORS_NMAX*2-2          ; counts 0, door boxes empty (lo $FFFF,
?z      lda #0                       ;   hi 0: the first edge sets both)
        sta.l DE_END,x
        sta.l DB_XHI,x
        sta.l DB_YHI,x
        dec @
        sta.l DB_XLO,x
        sta.l DB_YLO,x
        dex
        dex
        bpl ?z
        stz de_ps                    ; pass 1: DE_END[door] = its edges * 2
        jsr ?segs
        lda #0                       ; running sums: DE_END = one past the
        ldx #$10000-DOORS_NMAX*2     ;   door's run, DE_FIRST = the same, the
        clc                          ;   cursor pass 2 counts back down. X counts
?p      adc.l DE_END+DOORS_NMAX*2-$10000,x   ; UP to 0 (same order, no cpx); C
        sta.l DE_END+DOORS_NMAX*2-$10000,x   ;   stays 0: the sum is 2 x the
        sta.l DE_FIRST+DOORS_NMAX*2-$10000,x ;   edges, far below 64K
        inx
        inx
        bne ?p
        inc de_ps                    ; pass 2: the edges themselves
        jsr ?segs
        ldx #DOORS_NMAX*2-2          ; the blockmap cells door_fit sweeps, per
?c      lda.l DB_XLO,x               ;   door, once a level
        sta de_t
        lda.l DB_XHI,x
        jsr ?span
        sta.l DB_CXN,x
        lda.l DB_YLO,x
        sta de_t
        lda.l DB_YHI,x
        jsr ?span
        sta.l DB_CYN,x
        dex
        dex
        bpl ?c
        sep #$30
        .LONGA OFF
        .LONGI OFF
        rts
        .LONGA ON
        .LONGI ON
;   every seg of the level: a two-sided one with a door in front -> the
;   pass's routine with A = door*2
?segs   lda MAP_HNSEG
        sta de_n
        lda #MAP_SEGS
        sta zp_sptr
?sg     ldy #SEG_FRONT               ; front, back: one word
        lda [zp_sptr],y
        cmp #NO_SECTOR*256
        bcs ?nx                      ; one-sided: PIT_CheckLine never gets past it
        and #$00FF
        tax
        lda.l DE_S2D,x
        and #$00FF
        cmp #$00FF
        beq ?nx                      ; no door in front
        ldy de_ps
        bne ?p2
        tax                          ; pass 1: count it
        lda.l DE_END,x
        inc @
        inc @
        sta.l DE_END,x
        bra ?nx
?p2     jsr ?put
?nx     lda zp_sptr
        clc
        adc #SEG_SIZE
        sta zp_sptr
        dec de_n
        bne ?sg
        rts
;   pass 2: this seg -> the edge at --DE_FIRST[door], and the door's box
?put    sta de_d
        tax
        lda.l DE_FIRST,x
        dec @
        dec @
        sta.l DE_FIRST,x
        sta de_i
        lda [zp_sptr]                ; v1: x1 -> tb_l, y1 -> tb_b (the asl's push
        jsr ?vtx                     ;   the peg bits out)
        sta tb_b
        stx tb_l
        lda [zp_sptr],y              ; v2 (Y = 2 = SEG_V2, ?vtx's): x2 -> tb_r, y2 -> tb_t
        jsr ?vtx
        sta tb_t
        stx tb_r
        ldx de_i
        sec                          ; slope class: dx or dy 0 -> axis (0), else
        lda tb_r                     ;   sign(dx) eor sign(dy): N = falling, and
        sbc tb_l                     ;   ORA #1 so that a rising one is never 0
        beq ?sl
        sta de_t
        sec
        lda tb_t
        sbc tb_b
        beq ?sl
        eor de_t
        ora #1
?sl     sta.l DE_SL,x
        lda tb_l                     ; x1 <= x2, y1 <= y2 (only the box is kept)
        cmp tb_r
        bcc ?xo
        ldy tb_r
        sta tb_r
        sty tb_l
?xo     lda tb_b
        cmp tb_t
        bcc ?yo
        ldy tb_t
        sta tb_t
        sty tb_b
?yo     lda tb_l
        sta.l DE_XLO,x
        lda tb_r
        sta.l DE_XHI,x
        lda tb_b
        sta.l DE_YLO,x
        lda tb_t
        sta.l DE_YHI,x
        ldx de_d                     ; ...and the door's box grows to hold it
        lda tb_l
        cmp.l DB_XLO,x
        bcs ?b1
        sta.l DB_XLO,x
?b1     lda tb_r
        cmp.l DB_XHI,x
        bcc ?b2
        sta.l DB_XHI,x
?b2     lda tb_b
        cmp.l DB_YLO,x
        bcs ?b3
        sta.l DB_YLO,x
?b3     lda tb_t
        cmp.l DB_YHI,x
        bcc ?b4
        sta.l DB_YHI,x
?b4     rts
;   A = a box's high edge, de_t = its low edge (EOR $8000, which moves a
;   cell -- (coord >> 9) & 7 -- by 64, a multiple of 8) -> A = the first cell
;   column/row | how many of them (1..8, 0 for an empty box) << 8
?span   clc
        adc #MK_RMAX                 ; no thing reaches further than MK_RMAX
        xba
        and #$00FF
        lsr @                        ; the last cell
        sta de_n
        lda de_t
        sec
        sbc #MK_RMAX
        xba
        and #$00FF
        lsr @                        ; the first
        sta de_t
        lda de_n
        sec
        sbc de_t
        bmi ?e0                      ; empty: lo $FFFF, hi 0
        cmp #8
        bcc ?e1
        lda #7                       ; 8 already wrap the whole grid
?e1     inc @
        xba
        ora de_t
        rts
?e0     lda #0
        rts
;   A = a seg's vertex word -> X = x EOR $8000, A = y EOR $8000
?vtx    asl @                       ; index*4: the two peg bits fall out, and
        asl @                        ;   C = 0 for the add (index < $4000)
        adc #MAP_VERTS
        sta zp_ptr                   ; (zp_ptr+2 = MAP_EXT_BANK, init_level)
        lda [zp_ptr]
        eor #$8000
        tax
        ldy #2
        lda [zp_ptr],y
        eor #$8000
        rts
        .LONGA OFF
        .LONGI OFF
.endp
        .endseg

;--------------------------------------------------------------
; frame_dt -- dt_vbl = VBLANKs the previous frame took (1..DOOR_DTMAX). Called once
;   per frame from the main loop, BEFORE anything that animates: doors and lifts
;   both scale their motion by it, so DOOM's 35 Hz tic rate survives any frame
;   rate (5 fps on a stock 800XL, far more on a Rapidus).
;--------------------------------------------------------------
        .segment B1
.proc frame_dt
?wt     lda RTCLOK3                  ; THE FPS CAP: a frame may not start before
        sec                          ;   FPS_MINVB VBLANKs have passed since the last
        sbc fps_last                 ;   one -- 2 on PAL (49.86 Hz, alt-src
        cmp #FPS_MINVB               ;   antic.cpp) = 25 fps at most. RTCLOK3 is
        bcc ?wt                      ;   rom_nmi's, zero page: a fast-RAM spin
?dt     cmp #DOOR_DTMAX+1            ; a load hitch must not fling a door open
        bcc ?ok
        lda #DOOR_DTMAX
?ok     sta dt_vbl
        tax                          ; DOOR_STEP/DOOR_FADD = SPEED_Q8 * dvb, once per
        lda RTCLOK3                  ;   frame: update_movers doubles it (PLATSPEED*4)
        sta fps_last                 ;   and update_doors uses it as it is, out of a
        lda dsq_hi,x                 ;   table (dt_vbl <= DOOR_DTMAX: 65 words,
        sta DOOR_STEP                ;   segment D0 below)
        lda dsq_lo,x
        sta DOOR_FADD
        ert *<>plr_steps            ; falls through: plr_steps is the next byte
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
psq     .rept PSPD_DTMAX+1, #        ; plr_steps' dt_vbl * PSPD_Q8, words
        dta a(#*PSPD_Q8)
        .endr
pn_tab  dta 0, 1, 3, 7               ; ...and its calls but the last, by halvings
    .if 2*PSPD_DTMAX*PSPD_Q8 > 65535 || [2*PSPD_DTMAX*PSPD_Q8]/8 > PSTEP_MAX*256 || PSPD_AIR > PSPD_DTMAX
        ert 'plr_steps: a frame of running is a word, and an eighth of it one call'
    .endif
        .endseg

;--------------------------------------------------------------
; plr_steps -- TRN_STEP for the next read_input, and THE WALK: what DOOM's
;   player covers in the frame's VBLANKs (PSPD_Q8, the run key doubling it), as
;   1, 2, 4 or 8 equal move_player calls of PSTEP_MAX units at most. frame_dt
;   falls in here BEFORE check_triggers: a crossing sees the whole travel.
;--------------------------------------------------------------
plrs_resume = *
        org PSTEP_BASE
        .segment B1
.proc plr_steps
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
                                     ;  has no fraction to carry)
?run    lda pl_air                   ; in the air: the keys he left the ground
        bne ?air                     ;   with, for PSPD_AIR VBLANKs a frame
        lda stick_save               ; on the ground: bits 0-1 the stick's forward
        and #$03                     ;   and back, bit 3 SET = no run key (DOOM's:
        sta pl_akey                  ;   SHIFT doubles forwardmove, $19 -> $32)
        lda SKSTAT
        and #SK_SHIFT
        tsb pl_akey
        lda dt_vbl                   ; ...for the frame's VBLANKs, PSPD_DTMAX at
        cmp #PSPD_DTMAX              ;   most
        bcc ?dt
        lda #PSPD_DTMAX
        bra ?dt
?air    lda #PSPD_AIR
?dt     asl @                        ; the word table's index (<= 32: C = 0 out)
        tax
        lda pl_akey
        and #$03
        cmp #$03
        beq ?idle                    ; neither way
        lda pl_akey
        and #SK_SHIFT
        cmp #1                       ; C = 0: the run key. rep, ldy and lda keep it
        rep #$20
        .LONGA ON
        ldy pl_air
        bne ?d
        lda zp_cos                   ; the heading, on the ground
        sta pl_acos
        lda zp_sin
        sta pl_asin
?d      lda psq,x                    ; PSPD_Q8 * dt
        bcs ?one
        asl @                        ; (a word still: psq's ert)
?one    ldy #0
        cmp #PSTEP_MAX*256+1
        bcc ?fit
?half   lsr @                        ; twice the calls, half as long each
        iny
        cmp #PSTEP_MAX*256+1
        bcs ?half
?fit    sta pl_step
        .LONGA OFF
        sep #$20
        lda pl_akey
        lsr @                        ; C = the forward bit, SET = not pressed
        bcs ?back
?cnt    lda pn_tab,y
        sta pl_n                     ; (the store keeps Z)
        beq ?last
?call   jsr move_player
        jsr spr_pickup               ; what he ran over on the way: the frame's
        dec pl_n                     ;   own spr_pickup takes the last stop
        bne ?call
?last   jmp move_player
?idle   lda pl_air                   ; the ONE call: on the ground it spends a
        beq ?last                    ;   shove (pl_idle), in the air it walks
        stz pl_step                  ;   nothing
        stz pl_step+1
        bra ?last
?back   rep #$20                     ; walking back: the distance negative
        .LONGA ON                    ;   (C = 1: the bcs took it here)
        lda #$0000
        sbc pl_step
        sta pl_step
        .LONGA OFF
        sep #$20
        bra ?cnt
.endp
        .endseg
;--------------------------------------------------------------
; pl_zref -- cur_floor = P_TryMove's thing->z, what a step up is measured from
;   (p_map.c:478): the FEET in the air, else floorz -- pl_fz, the highest floor
;   under his radius (P_CheckPosition's tmfloorz), which a committed move and
;   update_pz both keep. pl_fz = $8000: not known yet (a level just loaded),
;   the floor under his centre stands in once.
;--------------------------------------------------------------
        .segment B1
.proc pl_zref
        rep #$20
        .LONGA ON
        lda pl_z
        ldx pl_air
        bne ?put
        lda pl_fz
        cmp #$8000
        bne ?put
        jsr locate_floor             ; (16-bit out, A = the floor)
?put    sta cur_floor
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg
    .if * > PSTEP_END+1
        ert 'plr_steps/pl_zref outgrew PSTEP_BASE..END (memory_map.inc)'
    .endif
        org plrs_resume

        .segment B1
.proc update_doors
        lda DOOR_NACT                ; nothing is moving -> the whole scan is skippable
        beq ?ret
        stz DOOR_DELTA+1             ; the step's high byte: the moves below are
                                     ;   words (an older savegame restores a non-0
                                     ;   $0F4B, so every frame)
        ldx MAP_HNDOOR               ; loop control sits AHEAD of the body so the
        beq ?ret                     ;   idle path is all short branches
        dex
?l      lda.l DOOR_STATE,x
        bne ?act
?next   dex
        bpl ?l
?ret    rts
?dwell  lda.l DOORSTAY,x             ; open, waiting -- the usual live state, so
        bne ?next                    ;   first, with no step and no ceiling to
        lda.l DOOR_WAIT,x            ;   write. Parked OPEN by a switch (103/2:
        sec                          ;   p_doors.c removes the thinker) -> done.
        sbc dt_vbl                   ; the dwell counts VBLANKs, not frames
        sta.l DOOR_WAIT,x
        bcc ?dwend                   ; underflowed -> time is up
        bne ?next
?dwend  lda #3                       ; dwell over -> closing
        sta.l DOOR_STATE,x
        lda #SFX_DORCLS              ; positional: a far door closes quietly or
        jsr snd_q_door_at            ;   not at all (X survives)
        bra ?next
?act    cmp #2
        beq ?dwell
        tay                          ; Y = 1 opening / 3 closing, for the dispatch
        lda.l DOOR_SECL,x            ; zp_ptr = &sector (built by init_doors)
        sta zp_ptr
        lda.l DOOR_SECH,x
        sta zp_ptr+1
        clc                          ; this door's move = STEP + the Q8 carry
        lda.l DOOR_FRAC,x
        adc DOOR_FADD
        sta.l DOOR_FRAC,x
        lda DOOR_STEP
        adc #0
        sta DOOR_DELTA
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        beq ?st
        jsr crush_pre                ; a crusher's speed class: halves DOOR_DELTA
                                     ;   or runs it at CEILSPEED/8 (Y = the state)
?st     dey
        beq ?opening
        ; --- closing: new = cur - delta; what stands under it decides
        ;     (p_floor.c T_MovePlane -> p_map.c P_ChangeSector), the landing
        ;     step included
        lda.l DOOR_CURHI,x           ; cur as a word: hi to B, lo to A
        xba
        lda.l DOOR_CURLO,x
	rep #$20
	.LONGA ON
	sec
	sbc DOOR_DELTA               ; (a word: DOOR_DELTA+1 = 0)
	sta m_ma                     ; m_ma = the ceiling this frame WOULD reach
	sec
	sbc (zp_ptr)                 ; the opening it would leave
	bmi ?land
	beq ?land
	cmp #MK_HMAX                 ; taller than anything that can stand there:
	sep #$20                     ;   nothing to ask (sep keeps C)
	.LONGA OFF
	bcs ?move
	jsr door_fit                 ; A = the opening: C = 1 something living
	bcs ?bounce                  ;   does not fit under it
?move   rep #$20
        .LONGA ON
        lda m_ma
        ldy #2
        sta (zp_ptr),y               ; the sector's ceiling, one word
        sep #$20
        .LONGA OFF
        sta.l DOOR_CURLO,x
        xba
        sta.l DOOR_CURHI,x
        jmp ?next
?land   sep #$20                     ; at (or past) the floor: T_MovePlane's
        lda #0                       ;   pastdest still asks P_ChangeSector
        jsr door_fit
        bcc ?shut
?bounce lda #1                       ; p_doors.c:159 `crushed`: a door goes back
        sta.l DOOR_STATE,x           ;   up, with sfx_doropn at its soundorg (cur
        lda #SFX_DOROPN              ;   untouched: the sector still holds it)
        jsr snd_q_door_at            ;   (X survives)
        jmp ?next
?shut   rep #$20
        .LONGA ON
        lda (zp_ptr)                 ; the floor
        ldy #2
        sta (zp_ptr),y               ;   becomes the ceiling
        sep #$20
        .LONGA OFF
        sta.l DOOR_CURLO,x
        xba
        sta.l DOOR_CURHI,x
        ldy #1                       ; a CRUSHER turns straight round and rises;
        lda #0                       ;   a door PARKS shut: one less to scan next
        jsr door_end                 ;   frame (door_end gives DOOR_NACT back)
        jmp ?next

?opening ; cur += delta into the sector, clamp to open, then dwell
        lda.l DOOR_CURHI,x
        xba
        lda.l DOOR_CURLO,x
        rep #$21
        .LONGA ON
        adc DOOR_DELTA               ; (a word: DOOR_DELTA+1 = 0)
        ldy #2
        sta (zp_ptr),y               ; the sector's ceiling (re-clamped below)
        sep #$20
        .LONGA OFF
        sta.l DOOR_CURLO,x
        cmp.l DOOR_OPNL,x            ; cur - open, the sign is what counts
        xba
        sta.l DOOR_CURHI,x           ; (sta and xba keep C)
        sbc.l DOOR_OPNH,x
        bmi ?up                      ; cur < open -> keep rising
        lda.l DOOR_OPNL,x            ; cur >= open -> clamp open, dwell
        sta.l DOOR_CURLO,x
        sta (zp_ptr),y               ; (Y = 2)
        lda.l DOOR_OPNH,x
        sta.l DOOR_CURHI,x
        iny                          ; Y = 3 = door_end's "crusher going down" too:
        sta (zp_ptr),y               ;   no `ldy #3` (2026-10-06, 6502-idioms: no reload)
                                     ; a CRUSHER reverses at the top instead --
        lda #2                       ;   no dwell, and DOOR_WAIT keeps its speed
        jsr door_end                 ;   class (p_ceilng.c T_MoveCeiling case 1)
?up     jmp ?next
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
;   Shared by door_at_point and try_use's subsector walk.
;--------------------------------------------------------------
ul_resume = *
        org USELOC_BASE
        .segment B1
.proc use_locate
        rep #$20                     ; 16-bit descent through node_side
        .LONGA ON                    ;   (Y = the child's offset)
        lda MAP_HROOT                ; root node index (map header, per level)
        sta zp_nid
?w      bmi ?leaf
  .ifdef ANTONIA2                    ; 2026-10-15 (6502-loops-tables-smc: the loop
?l      jsr node_side                ;   tests at its END): the child's N decides
        lda [zp_nodeptr],y           ;   there, no bra back to the top test
        sta zp_nid
        bpl ?l
  .else
        jsr node_side
        lda [zp_nodeptr],y
        sta zp_nid
        bra ?w
  .endif
?leaf   rts                          ; returns 16-BIT with A = zp_nid
        .LONGA OFF
.endp
        .endseg
    .if * > USELOC_END+1
        ert 'use_locate outgrew USELOC_BASE..END (memory_map.inc)'
    .endif
        org ul_resume

dap_resume = *
        .segment B1
.proc door_at_point
        jsr use_locate
	.LONGA ON                    ; (use_locate returns 16-bit, A = zp_nid)
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
	sep #$20
	.LONGA OFF
        sta m_a                      ; (door_index_of compares the byte only)
        jmp door_index_of            ; tail call -> A = door index, or $FF
?none	sep #$20
	.LONGA OFF
	lda #$ff
	rts
.endp
        .endseg



;--------------------------------------------------------------
; use_refused -- C = 1 if zp_sptr is one of the door faces USE is refused
;   through that DOOR_DENY cannot name (MAP_DOORX, pack_map _doors). A free
;   slot holds 0, and no seg record lives at $0000. X survives.
;--------------------------------------------------------------
        .segment B1
.proc use_refused
        ldy #256-DOORX_N*2           ; the index counts up to zero
        rep #$20
        .LONGA ON
        lda zp_sptr
?l      cmp MAP_DOORX+DOORX_N*2-256,y
        beq ?out                     ; equal: C = 1
        iny
        iny
        bne ?l
        clc
?out    sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; use_leaf -- test every seg of the subsector in zp_nid against the USE ray.
;   OUT: A = door index if a crossed seg is a door line ($FF = none),
;        USE_BLK = 1 if a crossed seg blocks the ray.
;--------------------------------------------------------------
        .segment B1
.proc use_leaf
        jsr leaf_segs                ; zp_sptr / zp_segcnt = this leaf's segs
        lda zp_segcnt
        ora zp_segcnt+1
        beq ?none                    ; (the count is tested once; the loop runs
?loop   jsr use_seg_hit              ;   on the 16-bit dec's Z at its foot)
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
        jsr use_refused              ;   and only says "oof". pack_map names that
        bcs ?plain                   ;   face's sector in DOOR_DENY, because a seg
        txa                          ;   cannot tell the two faces apart: BOTH
        rts                          ;   have the door as their back sector. The
                                     ;   faces a sector cannot name: use_refused.
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
	sep #$20                     ; (sep keeps the word's Z)
	.LONGA OFF
        bne ?loop
?none   lda #$FF
        rts
?fired  lda #$FE                    ; a switch fired (its sound is queued):
        rts                          ;   stop the ray; try_use skips the toggle
.endp
        .endseg


;--------------------------------------------------------------
; use_sample -- A = distance n along the player's facing (0..USERANGE);
;   OUT: zp_px/zp_py = USE_PT_A + n*(cos,sin) -- where DOOM's trace would be.
;--------------------------------------------------------------
        .segment B1
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
        jsr smul_14                  ; m_res = n*cos, in A (smul_14 returns 16-bit)
	.LONGA ON
        clc
        adc USE_PT_A
        sta zp_px
	lda m_ma
	and #$00ff
	sta m_a
        lda zp_sin
        sta m_b
	sep #$20
	.LONGA OFF
        jsr smul_14                  ; m_res = n*sin, in A
	.LONGA ON
        clc
        adc USE_PT_A+2
        sta zp_py
        rts                          ; returns 16-bit
	.LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; try_use -- DOOM P_UseLines (p_map.c). Walk a ray USERANGE units forward, visit
;   the subsectors it passes through in order, and in each one test the segs the
;   ray CROSSES: activate the first door line, stop at the first wall.
;--------------------------------------------------------------
        .segment B1
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
        jsr use_sample               ; (returns 16-bit)
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
        jsr use_sample               ; (16-bit out: use_locate opens with rep anyway)
        jsr use_locate               ; zp_nid = leaf at (zp_px, zp_py)
	.LONGA ON                    ; (16-bit out, A = zp_nid)
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
        org dap_resume

;--------------------------------------------------------------
; use_door_go -- A = door index the USE ray hit. EV_VerticalDoor's key gate
;   (p_doors.c:186-244), the same shape as w3d Cmd_Use: MAP_DOORLOCK[door]
;   bits0-2 = the PS_KEYS bit this door needs (blue=1 yellow=2 red=4, card and
;   skull share a bit like P_CheckKeys), 0 = unlocked.
;--------------------------------------------------------------
udg_resume = *
        org USEDOORGO_BASE
        .segment B1
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
        jmp door_use                 ; DR: EV_VerticalDoor (open, or flip it)
?locked                              ; nothing moves: falls through, door_keymsg
        ert *<>door_keymsg          ;   is the next byte of the segment
.endp
        .endseg
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
        .segment B1
.proc door_keymsg
        lda MAP_DOORLOCK,x           ; a key bit refused the door?
        and #7
        beq ?nw
        lda #36+MSG_IDX0             ; the PD strip (pack_menu.py)
        jsr msg_set.msg_arm
?nw     lda #SFX_NOWAY               ; ...and the "uh-uh" either way
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
; SWITCHES (S1/SR) + walkover doors -- 1:1 with _doomsrc:
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
        .segment B1
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
        bcc ?nosw                    ; p_switch.c clicks sfx_swtchn only for a
        lda #SFX_SWTCHN              ;   switch texture it changed (C=1): E3M1's
        sta snd_pending              ;   lift "door" (62 on BIGDOOR7) has none, and
?nosw   sec                          ;   its sfx_pstart keeps the single slot
        rts
?no     clc
        rts
.endp
        .endseg
        .segment D0
sw_hit  dta 0

;--------------------------------------------------------------
; sw_swap -- P_ChangeSwitchTexture: flip the pressed seg's SW1 texid to its
;   SW2 mate (textab row MAP_TEXSWMATE, packed by pack_textures.py). Tries the
;   wall byte, then the lower (62 sits on lift fronts' lower texture). An SR
;   button (sw_fl b12 clear) arms the one button slot to flip back after
;   BUTTONTIME (update_button); S1 stays pressed forever.
        .endseg
        .segment B1
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
        sta [zp_sptr],y              ; (Y is still sw_y: ?try's sty)
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
        .segment B1
.proc trig_fire
        ldy #13
        lda (zp_ptr),y
        and #$20                     ; b13 = DOOR action
        bne ?door
        lda (zp_ptr),y               ; (Y still 13) b9 WITHOUT b13 = STOP the
        and #$02                     ;   plat, p_spec.c case 89 EV_StopPlat:
        beq ?nstop                   ;   every mover parked
        ldx #MV_NMAX-1
?stop   stz MV_STATE,x
        dex
        bpl ?stop
        rts
?nstop  jsr mv_free                 ; a slot for this record? mv_free also runs
        bcs ?go                      ;   EV_DoPlat's "if (sec->specialdata)
        rts                          ;   continue" -- all busy, or that sector is
                                     ;   already moving: drop this fire and do
                                     ;   NOT spend the once-bit (try again later)
?go     jsr mv_start                 ; stays-down floors mark the bitmap there
        bra ?once

?door   lda (zp_ptr),y               ; (Y is still 13) b15 WITH b13 is not a door
	bmi trig_light
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
        org swf_resume


;--------------------------------------------------------------
; trig_light -- p_spec.c case 35 / p_lights.c EV_LightTurnOn: every sector with
;   the line's tag takes a fixed light level (35, "Lights Very Dark"). The
;   packer emits one record per tagged sector, so this is one write; the level
;   itself rides in the record's dst field, where a floor keeps its height.
;--------------------------------------------------------------
tl_resume = *
        org TRIGLT_BASE
        .segment B1
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
tl_back bra trig_fire.tl_once        ; and spend the W1 bit
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
        .segment B1
.proc gun_seg_p                      ; C=1 if zp_sptr is EITHER face of the 46
        pha                          ;   line. A survives (try_use still needs it)
        ldy #256-4                   ; counting UP to zero: Y = $FC, $FE = slots 26, 28 (the callers read
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
        .segment B1
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
        .segment B1
.proc door_force_open
        ldy #13                      ; TRIGGER-RECORD entry: zp_ptr = the record
        lda (zp_ptr),y
        and #$02                     ; b9 = the action CLOSES
        bne ?shut
dfo_go                               ; no-record entry: open, never close
        lda.l DOOR_STATE,x
        bne ?mov
        inc DOOR_NACT                ; closed -> wake it
?rev    lda #1
        sta.l DOOR_STATE,x
        lda #SFX_DOROPN              ; positional: a REMOTE door opens quietly
        bra snd_q_door_at            ;   or silently (s_sound.c attenuation)
?mov    cmp #3
        beq ?rev                     ; closing -> reopen (still counted live);
?out    rts                          ;   opening / open: leave it
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
        beq ?st                      ; armed (2): update_door30 has work now
        sta D30_ON
?st     lda #SFX_DORCLS
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
        .segment B1
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
        .segment B1
.proc snd_q_door_at
        pha                          ; the SFX and the door, parked on the stack
        phx
        txa
        asl
        asl                          ; MAP_DSND records are 4 B: {i16 x, i16 y}
        tay                          ;   (47*4 = 188: a byte at DOORS_NMAX 48)
	rep #$20
	.LONGA ON
	sec
        lda zp_px
        sbc MAP_DSND+0,y
	sta sda_sx                   ; player - soundorg, the whole word: snd_setpan
	sec                          ;   takes the reach and the ear from these
        lda zp_py
        sbc MAP_DSND+2,y
	sta sda_sy
	sep #$20
	.LONGA OFF
        jsl snd_setpan_w0            ; C = 1 past S_CLIPPING_DIST (1200): silent
        bcs ?silent
        lda 2,s                      ; the SFX. PLAY it, do not queue it:
        tax                          ;   snd_pending is one byte and spr_pickup
        jsr snd_play                 ;   runs later in the same frame
?silent plx
        pla
        rts
.endp
        .endseg
    .if * > SNDDIST_END+1
        ert 'snd_q_door_at outgrew SNDDIST (memory_map.inc)'
    .endif
        org sda_resume

;--------------------------------------------------------------
; snd_setpan's cells (the code is sound.asm's, SNDPAN2): sda_sx/sda_sy =
;   player - source, words; snd_side = the next snd_play's pan.
;--------------------------------------------------------------
spn_resume = *
        org SNDPAN_BASE
sda_sx  dta 0,0                    ; 16-bit cells: snd_q_door_at stores
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

;--------------------------------------------------------------
; crush_pre -- crusher X (update_doors tested the CRUSH_BIT): DOOR_DELTA = the
;   whole-unit step at the crusher's speed. Returns Y = DOOR_STATE (the
;   dispatch's, which snd_q_grind may not keep).
;--------------------------------------------------------------
        .segment B1
.proc crush_pre
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
        tay
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
; door_end -- door X has arrived at one end of its travel.
;   IN: A = the state an ORDINARY door takes there (2 = dwell at the top,
;           0 = parked shut)
;--------------------------------------------------------------
        .segment B1
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
        .segment B1
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
; door_fit -- p_map.c P_ChangeSector for door X, A = the opening (floor to
;   where the ceiling is about to be, < MK_HMAX). A thing whose BOX reaches
;   into the sector (door_touch) and is taller than the opening
;   (P_ThingHeightClip) does not fit:
;     the living -- the player, a monster, a barrel (MF_SHOOTABLE): an
;       ordinary door is told so, C = 1 (update_doors sends it back up); a
;       CRUSHER hurts it instead (PIT_ChangeSector's crunch) and slows, C = 0;
;     a corpse lets it pass (DOOM gibs it), but the item it dropped is
;       crunched (MF_DROPPED -> P_RemoveMobj): its F_DROP goes. A dead player
;       lets it pass too.
;   Preserves X and m_ma; rebuilds zp_ptr (the door's sector).
;--------------------------------------------------------------
        .segment B1
.proc door_fit
        sta df_open
        stx df_d
        stz df_hit
        rep #$20                     ; ?move's ceiling onto the stack: the BSP
        .LONGA ON                    ;   descent and the damage below both run
        lda m_ma                     ;   through m_ma
        pha
        sep #$20
        .LONGA OFF
        lda MAP_DOORLOCK,x
        and #CRUSH_BIT
        sta df_cr
        lda pl_dead                  ; ---- the player, MT_PLAYER = PLAYER_H tall
        bne ?things
        lda df_open
        cmp #PLAYER_H
        bcs ?things
        rep #$20
        .LONGA ON
        lda zp_px
        sta tb_cx
        lda zp_py
        sta tb_cy
        lda #MK_PLRAD
        jsr ?box                     ; (8-bit out)
        .LONGA OFF
        jsr door_touch               ; X = the door
        bcc ?things
        lda df_cr
        bne ?phurt
        inc df_hit
        bra ?things
?phurt  lda dt_vbl                 ; P_DamageMobj(player, 10) every 4 tics =
        asl                          ;   CRUSH_DMG_VB a VBLANK, scaled by the
        jsr en_plr_hurt              ;   frame (X survives it)
        jsr crush_slow
?things txa                          ; ---- the things: P_BlockThingsIterator over
        asl                          ;   the cells round the door (de_build's
        tax                          ;   DB_CXN/DB_CYN). X is the door on all
        lda.l DB_CXN+1,x             ;   three ways in: door_touch, en_plr_hurt
        beq ?done                    ;   and crush_slow keep it. 0: no edges
        sta df_nx
        lda.l DB_CXN,x
        sta df_cx
        lda.l DB_CYN+1,x
        sta df_ny
        lda.l DB_CYN,x
        sta df_cy
?row    lda df_cy                   ; the row's cell bits 3-5
        asl
        asl
        asl
        and #$38
        sta df_c
        lda df_cx
        sta df_x
        lda df_nx
        sta df_i
?col    lda df_x
        and #7
        ora df_c
        tax
        lda.l EXT_BASE+BLK_HEAD,x
?item   cmp #$FF
        beq ?ncell
        sta df_t
        jsr ?thing
        ldx df_t
        lda.l EXT_BASE+TH_BNEXT,x
        bra ?item
?ncell  inc df_x
        dec df_i
        bne ?col
        inc df_cy
        dec df_ny
        bne ?row
?done   rep #$20
        .LONGA ON
        pla
        sta m_ma
        sep #$20
        .LONGA OFF
        ldx df_d                     ; update_doors' door and its sector pointer
        lda.l DOOR_SECL,x
        sta zp_ptr
        lda.l DOOR_SECH,x
        sta zp_ptr+1
        lda df_hit
        cmp #1                       ; C = 1: something living does not fit
?r      rts                          ; (also ?thing's near exit: ?item reads no flag)
;   A = thing df_t: removed, not MF_SHOOTABLE, or short enough -> nothing
?thing  lsr
        lsr
        lsr
        tax
        lda df_t
        and #7
        tay
        lda THING_ALIVE,x
        and mv_bit,y
        beq ?r                       ; picked up / removed from the level
        ldx df_t
        lda.l EXT_BASE+TH_KIND,x
        beq ?r                       ; a pickup or a decoration: not shootable
        tay
        lda.l EXT_BASE+TH_STATE,x
        bne ?dead
        lda df_open                  ; alive: opening >= info.c height -> it fits
        cmp mk_hgt,y
        bcs ?tno
        lda df_t
        jsr en_thing.en_th2w         ; sp_ptr = its record (16-bit out)
        bra ?pos
?dead   sta df_st                    ; a corpse (A = its row+1): P_KillMobj left
        lda df_t                     ;   it height/4, and the item it dropped is
        jsr en_thing.en_th2          ;   MK_DROPH tall (Y = kind survives en_th2)
        stz df_gh
        lda.l EXT_BASE+DTAB_EXT      ; the level's S_GIBS row (death header slot
        inc @                        ;   kind 0, pack_things), +1 like TH_STATE:
        sta df_gr                    ;   0 = this level has none
        beq ?nog
        cmp df_st
        beq ?nog                     ; gibs already: height 0
        lda mk_hgt,y
        lsr
        lsr
        sta df_gh
?nog    ldy #7
        lda (sp_ptr),y
        and #F_DROP
        beq ?nd
        lda #MK_DROPH
?nd     sta df_dh                    ; 0 or MK_DROPH
        cmp df_gh                    ; the taller of the two decides whether
        bcs ?mx                      ;   anything here is the ceiling's business
        lda df_gh
?mx     cmp df_open
        bcc ?tno
        beq ?tno
        rep #$20                     ; (sp_ptr stays: door_touch and ?box never
?pos    .LONGA ON                    ;   touch it -- ?crunch writes through it)
        lda (sp_ptr)
        sta tb_cx
        ldy #2
        lda (sp_ptr),y
        sta tb_cy
        ldx df_t
        lda.l EXT_BASE+TH_RAD,x      ; (lo = the radius: kind != 0 has one)
        and #$00FF
        jsr ?box
        .LONGA OFF
        ldx df_d
        jsr door_touch
        bcc ?tno
        ldx df_t
        lda.l EXT_BASE+TH_STATE,x
        bne ?crunch
        lda df_cr
        bne ?mhurt
        inc df_hit
?tno    rts
?mhurt  stx en_bi                    ; a monster slows a crusher as the player
        ldx df_d                     ;   does -- `crushed` does not ask who --
        jsr crush_slow               ;   and takes the same 10 every 4 tics
        lda dt_vbl
        asl
        jmp en_bhit                  ; P_DamageMobj: health, death, the scream
?crunch lda df_open                  ; PIT_ChangeSector on a corpse:
        cmp df_dh
        bcs ?gib
        ldy #7                       ;   MF_DROPPED -> P_RemoveMobj
        lda (sp_ptr),y
        and #255-F_DROP
        sta (sp_ptr),y
?gib    lda df_open
        cmp df_gh
        bcs ?tno
        lda df_gr                    ;   health <= 0 -> S_GIBS, tics -1: the
        sta.l EXT_BASE+TH_STATE,x    ;   frozen POL5 row (X = df_t, still)
        lda #$FF
        sta.l EXT_BASE+TH_TICS,x
        rts
;   16-bit A = the radius, tb_cx/tb_cy = the centre -> the box tb_l..tb_t
;   (EOR $8000, door_touch's coordinates). Returns 8-bit.
?box    .LONGA ON
        sta de_t
        lda tb_cx
        eor #$8000
        pha
        clc
        adc de_t
        sta tb_r
        pla
        sec
        sbc de_t
        sta tb_l
        lda tb_cy
        eor #$8000
        pha
        clc
        adc de_t
        sta tb_t
        pla
        sec
        sbc de_t
        sta tb_b
        sep #$20
        .LONGA OFF
        rts
.endp

;--------------------------------------------------------------
; door_touch -- X = door: does the box tb_l..tb_r x tb_b..tb_t (EOR $8000)
;   reach into the door sector, as P_CheckPosition sees it? Either it crosses
;   one of the door's two-sided lines -- PIT_CheckLine: a strict overlap of the
;   line's box, then P_BoxOnLineSide == -1 -- or its centre tb_cx/tb_cy (real
;   coordinates) stands inside the sector (R_PointInSubsector).
;   OUT: C = 1 it does. X = the door, 8-bit.
;--------------------------------------------------------------
.proc door_touch
        stx dt_d
        rep #$30
        .LONGA ON
        .LONGI ON
        txa
        asl @
        tax                          ; door*2 (XH = 0: X came in 8-bit)
        lda.l DB_XLO,x               ; the door's own box first: most things are
        cmp tb_r                     ;   nowhere near it
        bcs ?no
        lda tb_l
        cmp.l DB_XHI,x
        bcs ?no
        lda.l DB_YLO,x
        cmp tb_t
        bcs ?no
        lda tb_b
        cmp.l DB_YHI,x
        bcs ?no
        lda.l DE_END,x
        sta dt_last
        lda.l DE_FIRST,x
        tax                          ; X = edge*2, the whole walk
?e      cpx dt_last
        bcs ?in                      ; no line crossed: is the centre inside?
        lda.l DE_XLO,x
        cmp tb_r
        bcs ?n
        lda tb_l
        cmp.l DE_XHI,x
        bcs ?n
        lda.l DE_YLO,x
        cmp tb_t
        bcs ?n
        lda tb_b
        cmp.l DE_YHI,x
        bcs ?n
        lda.l DE_SL,x                ; an axis line: overlapping its box IS
        beq ?yes                     ;   crossing it
        jsr ?diag                    ; (N = falling, from this lda: jsr keeps it)
        bcs ?yes
?n      inx
        inx
        bra ?e
?yes    sep #$31                     ; C = 1, 8-bit
        .LONGA OFF
        .LONGI OFF
        ldx dt_d
        rts
        .LONGA ON
        .LONGI ON
?no     sep #$30
        .LONGA OFF
        .LONGI OFF
?n8     ldx dt_d
        clc
        rts
?in     sep #$30
        pei (zp_py)                  ; door_at_point descends from zp_px/zp_py,
        pei (zp_px)                  ;   which is the PLAYER: park him
        rep #$20
        .LONGA ON
        lda tb_cx
        sta zp_px
        lda tb_cy
        sta zp_py
        sep #$20
        .LONGA OFF
        jsr door_at_point            ; A = the door the centre stands in
        eor dt_d
        tax                          ; 0 = this one
        rep #$20
        .LONGA ON
        pla
        sta zp_px
        pla
        sta zp_py
        sep #$20
        .LONGA OFF
        txa
        bne ?n8
        sec
        ldx dt_d
        rts
;   16-bit A/X, X = a sloped edge*2, N = its DE_SL sign (the caller's lda):
;   P_BoxOnLineSide -- the two corners across the line (rising: top-left,
;   bottom-right; falling: top-right, bottom-left) on different sides of it.
;   C = 1 they are. X survives.
        .LONGA ON
        .LONGI ON
?diag   stx de_i                     ; (stx keeps N)
        bmi ?fall
        sec                          ; rising: from (xlo, ylo), dy > 0
        lda.l DE_YHI,x
        sbc.l DE_YLO,x
        sta cx_a
        lda.l DE_YLO,x
        ldy tb_l                     ; corners (l, t) and (r, b)
        ldx tb_r
        bra ?side
?fall   sec                          ; falling: from (xlo, yhi), dy < 0
        lda.l DE_YLO,x
        sbc.l DE_YHI,x
        sta cx_a
        lda.l DE_YHI,x
        ldy tb_r                     ; corners (r, t) and (l, b)
        ldx tb_l
?side   sta de_y0
        stx de_c2
        ldx de_i
        sec
        lda.l DE_XHI,x
        sbc.l DE_XLO,x
        sta cx_d                     ; the line's dx (> 0)
        tya
        sec
        sbc.l DE_XLO,x
        sta cx_b                     ; corner 1: x - x0
        sec
        lda tb_t
        sbc de_y0
        sta cx_c                     ;   y - y0
        sep #$10                     ; smul32 keeps its sign in an 8-bit Y
        .LONGI OFF
        jsr cross_pos.cp_sign        ; A = 1: in front (P_PointOnLineSide 0);
        sta de_s1                    ;   the sign shortcut (2026-10-05)
        rep #$30
        .LONGI ON
        ldx de_i
        sec
        lda de_c2
        sbc.l DE_XLO,x
        sta cx_b                     ; corner 2
        sec
        lda tb_b
        sbc de_y0
        sta cx_c
        sep #$10
        .LONGI OFF
        jsr cross_pos.cp_sign
        eor de_s1                    ; 1: the corners differ, the box straddles
        lsr                          ;   -> C
        rep #$30
        .LONGA ON
        .LONGI ON
        ldx de_i
        rts
        .LONGA OFF                   ; (the assembler's widths, back for what
        .LONGI OFF                   ;   follows: they are lexical)
.endp
        .endseg
        .segment D0
tb_l    dta a(0)                     ; the box door_touch tests, EOR $8000
tb_r    dta a(0)
tb_b    dta a(0)
tb_t    dta a(0)
tb_cx   dta a(0)                     ; ...and its centre, real
tb_cy   dta a(0)
de_t    dta a(0)                     ; de_build / door_fit scratch
de_n    dta a(0)                     ; de_build: segs left
de_ps   dta a(0)                     ; de_build: 0 = counting, else filling
de_d    dta a(0)                     ; de_build: door*2
de_i    dta a(0)                     ; edge*2
dt_last dta a(0)                     ; door_touch: one past the door's last edge
de_y0   dta a(0)                     ; ?diag: the line's origin y
de_c2   dta a(0)                     ; ?diag: corner 2's x
de_s1   dta 0                        ; ?diag: corner 1's side
dt_d    dta 0                        ; door_touch: the door
df_open dta 0                        ; door_fit: the opening asked about
df_d    dta 0                        ; door_fit: the door
df_hit  dta 0                        ; ...living things that do not fit
df_cr   dta 0                        ; ...CRUSH_BIT of the door
df_t    dta 0                        ; ...the thing in hand
df_st   dta 0                        ; ...a corpse's row+1
df_gr   dta 0                        ; ...the level's S_GIBS row+1 (0 = none)
df_gh   dta 0                        ; ...the corpse's height (0: gibs already)
df_dh   dta 0                        ; ...its dropped item's (0: none)
df_c    dta 0                        ; ...the row's cell bits
df_x    dta 0                        ; ...the column in hand
df_i    dta 0                        ; ...columns left in the row
df_cx   dta 0                        ; ...first column, columns, first row, rows
df_nx   dta 0
df_cy   dta 0
df_ny   dta 0
        .endseg
        org crush_resume
