;--------------------------------------------------------------
; Part of proj.asm (icl in place): the bolt SLOTS -- pj_slot, pj_load/pj_save, pj_frameN, pj_draw1, pj_pick, pj_clr, spr_chasec, and the context.
;--------------------------------------------------------------

;--------------------------------------------------------------
; THE SLOT MACHINERY (2026-08-09). Nothing below the context swap knows there
;   is more than one bolt: pj_load puts a slot into the pj_* variables, the
;   shipped flight code ticks it exactly as it did when there was one, and
;   pj_save puts it back.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_slot                        ; X = slot -> zp_ptr = its bank $01 block
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_load                        ; X = slot -> the context. Preserves X.
                                      ; 2026-09-23: pj_slot inlined INTO the copy's window:
        txa                          ;   slot*64 + PJSLOT_EXT as one word (slot <= 7:
        rep #$21                     ;   the shifts carry nothing out, C = 0 from the
        .LONGA ON                    ;   rep for the adc), no jsr/rts, no sep/rep
        and #$00FF
        asl @
        asl @
        asl @
        asl @
        asl @
        asl @
        adc #PJSLOT_EXT&$FFFF
        sta zp_ptr
        ldy #PJ_CTXN-2               ; WORDS: 18 moves for the 36 bytes
?c      lda [zp_ptr],y
        sta pj_ctx,y
        dey
        dey
        bpl ?c
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_save                        ; X = slot <- the context. Preserves X.
                                      ; 2026-09-23: pj_slot inlined, as pj_load
        txa
        rep #$21
        .LONGA ON
        and #$00FF
        asl @
        asl @
        asl @
        asl @
        asl @
        asl @
        adc #PJSLOT_EXT&$FFFF
        sta zp_ptr
        ldy #PJ_CTXN-2               ; WORDS, as pj_load
?c      lda pj_ctx,y
        sta [zp_ptr],y
        dey
        dey
        bpl ?c
        sep #$20
        .LONGA OFF
        ert *<>pj_mirr              ;   next byte of this segment -- fall through
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_mirr                        ; X = slot: what spr_chasec reads per
        lda pj_on                    ;   SUBSECTOR, kept in fast base RAM so the
        sta pj_ons,x                 ;   walk never unpacks a slot to find out
        lda pj_ss                    ;   the bolt is somewhere else
        sta pj_ssl,x
        lda pj_ss+1
        sta pj_ssh,x
        jmp pj_orup                  ; ...and refresh pj_any (X comes back as
.endp                                ;   pj_cur, which is what X holds here)
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_frameN                      ; the frame hook: every bolt, in turn
        lda current_level            ; the level check is HERE and not in
        cmp pj_lvl                   ;   pj_frame any more: pj_relvl has to run
        beq ?go                      ;   even when no slot is live, and it now
        jsr pj_relvl                 ;   forgets every slot, not just one
?go
        ert *<>pj_frameN2           ;   next byte of this segment -- fall through
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_frameN2
        lda pj_any                   ; nothing flying (the usual frame): the scan
        bne ?scan                    ;   below would find every slot idle and only
        ldx #PJ_NSLOT-1              ;   leave pj_cur on the last one -- do that
        stx pj_cur                   ;   and go (pj_orup keeps pj_any exact after
        rts                          ;   every pj_save; pj_clr zeroes both)
?scan
        ldx #0
?lp     stx pj_cur
        lda pj_ons,x                 ; idle: not worth 62 bytes of copying
        beq ?nx
        jsr pj_load
        jsr pj_frame
        ldx pj_cur
        jsr pj_save
?nx     inx                          ; (pj_save left X = pj_cur; the skip path
        cpx #PJ_NSLOT                ;  never touched it)
        bne ?lp
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_draw1                       ; X = slot, and its leaf is the one the walk
        stx pj_cur                   ;   is in: unpack it and project it
        jsr pj_load
        jsr pj_rec_up                ; pj_rec = x, y, z-8 out of the context
        lda pj_frm                   ; the frame THIS bolt is on -- it used to
        sta pj_rec+6                 ;   reload pj_fid here, which is the FLIGHT
                                     ;   frame, so the three burst frames ...
        lda #TH_NOTHING              ; vs_th: the missile's "not a thing"
        sta sp_i
        lda #<pj_rec
        sta sp_ptr
        lda #>pj_rec
        sta sp_ptr+1
        jmp spr_proj
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_pick                        ; the slot a NEW shot gets, context loaded.
        ldx #PJ_NSLOT-1              ;   Z=1 = it is somebody's LIVE bolt (every
?lp     lda pj_ons,x                 ;   slot was busy), so the caller has to
        cmp #1                       ;   merge into it or land it first.
        bne ?take                    ; idle or already bursting: reuse it
        dex
        bne ?lp                      ; slot 0 is the fallback
?take   stx pj_cur
        jsr pj_load
        lda pj_on
        cmp #1
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_rocket2
        pha                          ; the roll, while pj_pick eats A
        jsr pj_pick
        bne ?arm
        jsr pj_hit                   ; every slot busy: the missile in this one
        dec pj_on                    ;   lands NOW, on ITS victim and with ITS
?arm    pla                          ;   roll -- pj_aim is about to overwrite
        jsr pj_aim                   ;   both (it used to land after, so the new
        jsr pj_rspawn                ;   rocket's damage went off early on the
        ldx pj_cur                   ;   new target)
        jmp pj_save
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc pj_clr                         ; a new level: forget every bolt
        stz pj_on
        stz pj_any                   ; ...and the walk's "anything flying" flag
        ldx #PJ_NSLOT-1
                                      ; 2026-09-23 BUG FIX: stz -- A is NOT 0 here (pj_relvl
?z      stz pj_ons,x                 ;   arrives with the PLSE sprite id in it), so the
        dex
        bpl ?z
        rts
.endp
        .endseg

        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
pj_ons  dta 0,0,0,0,0,0,0,0          ; per slot: pj_on, and the leaf it is in --
pj_ssl  dta 0,0,0,0,0,0,0,0          ;   the only projectile state the render
pj_ssh  dta 0,0,0,0,0,0,0,0          ;   walk ever reads (PJ_NSLOT of each)
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; spr_chasec -- spr_add's chase hook, retargeted a second time (sprites.asm
;   calls it instead of spr_chaseb): the ball's chain first, then every bolt
;   whose leaf is the one the walk is in.
;--------------------------------------------------------------
        .endseg
        org SPRCHC_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_chasec
        jsr spr_chaseb
        lda pj_any                   ; nothing flying anywhere (the usual
        beq ?out                     ;   frame): one load instead of an 8-slot
        ldx #PJ_NSLOT-1              ;   scan on EVERY subsector of the walk
?lp     lda pj_ons,x
        beq ?nx
        lda zp_nid
        cmp pj_ssl,x
        bne ?nx
        lda zp_nid+1
        and #$7F
        cmp pj_ssh,x
        bne ?nx
        lda sp_n
        cmp #VIS_MAX
        bcs ?nx
        jsr pj_draw1
        ldx pj_cur                   ; (pj_draw1 goes through spr_proj)
?nx     dex
        bpl ?lp
?out    rts
.endp
        .endseg
pj_any  dta 0                        ; OR of the eight pj_ons (pj_orup): 0 = no
                                     ;   bolt flying anywhere. Lives with its
                                     ;   only per-frame reader now.
    .if * > SPRCHC_END+1
        ert 'spr_chasec + pj_any outgrew SPRCHC_BASE..END (memory_map.inc)'
    .endif
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; THE PER-BOLT CONTEXT (2026-08-09). One shot's whole flight, 31 bytes, and
;   the ONLY thing pj_load/pj_save move between here and the PJ_NSLOT slots
;   that live in Rapidus bank $01 (PJSLOT_EXT).
;--------------------------------------------------------------
pj_ctx
pj_on   dta 0                        ; 0 idle, 1 flying, 2/3/4 burst frames
pj_fid  dta 0                        ; this shot's flight frame
pj_xid  dta 0                        ; ...and its burst first frame
pj_bsnd dta 0                        ; ...and its deathsound
pj_bt0  dta 0                        ; burst frame clocks, VB
pj_bt1  dta 0
pj_bt2  dta 0
pj_x    dta a(0)                     ; position (whole units) + Q8 fraction
pj_xf   dta 0
pj_y    dta a(0)
pj_yf   dta 0
pj_z    dta a(0)                     ; flight height: eye - 9 at the launch, and
                                     ;   pj_zstep walks it from there (it was a
                                     ;   constant until the z leg landed)
pj_zf   dta 0                        ; ...its Q8 fraction, like pj_xf/pj_yf
pj_sz   dta a(0)                     ; the z step, Q8 + sign extension: DOOM's
pj_sze  dta 0                        ;   th->momz (p_mobj.c:983)
pj_tx   dta a(0)                     ; the impact point it flies to
pj_ty   dta a(0)
pj_sx   dta a(0)                     ; step per VBLANK, Q8 + sign extension
pj_sxe  dta 0
pj_sy   dta a(0)
pj_sye  dta 0
pj_ttl  dta 0                        ; flight guard / burst frame countdown
pj_ss   dta a(0)                     ; the leaf the missile is in
pj_cap  dta 1                        ; sub-steps per drawn frame for this shot
pj_vic  dta $FF                      ; the thing this shot will hurt when it
pj_dmg  dta 0                        ;   lands ($FF = none, it flies at a wall)
pj_frm  dta 0                        ; the frame it is SHOWING right now: pj_fid
                                     ;   while it flies, then the three burst ids
                                     ;   in turn.
PJ_CTXN equ *-pj_ctx                 ; 36: was 31, +4 for the z leg and +1 for
    .if PJ_CTXN & 1
        ert 'PJ_CTXN must be even: pj_load/pj_save move it as words'
    .endif
                                     ;   pj_frm -- which is why PJ_SLSTR had to
                                     ;   go 32 -> 64 (_verify_pjz checks both)
;--------------------------------------------------------------
; ...and the SHARED half: scratch and level state, one copy for all bolts.
;--------------------------------------------------------------
pj_cur  dta 0                        ; the slot the context above belongs to
                                     ; (pj_any moved to the FRACTAB block with
                                     ;   spr_chasec, its per-frame reader)
pj_ti   dta 0                        ; pj_thit: the caller's X, parked (the
                                     ;   sweep cursor is X itself now)
pj_bd   dta a(0)                     ; ...and this candidate's blockdist. A
                                     ;   WORD: pj_thit's 16-bit compares read
                                     ;   it whole, and +1 is a permanent 0
pj_hold dta 0                        ; 1 = en_shoot picks the victim and stops
                                     ;   there, hurting nobody (enemy.asm)
pj_lvl  dta $FF                      ; the level the ids below belong to
pj_rid  dta $FF                      ; MISL A sprtab id (things header +20)
pj_rxid dta $FF                      ; MISL B, burst first of B/C/D (+21)
pj_pid  dta $FF                      ; PLSS A (+22)
pj_pxid dta $FF                      ; PLSE A, burst first of A/B/C (+23)
pj_dx   dta a(0)                     ; spawn scratch: the aim vector
pj_dy   dta a(0)
pj_ax   dta 0                        ; |dx8|
pj_f    dta 0                        ; k7 factor
pj_sgn  dta 0                        ; a leg's sign, held across umul16
pj_sh   dta 0                        ; shrinks the aim vector needed = log2(dist)
; shrinks -> sub-steps per drawn frame. dist ~ 96 << sh, and a sub-step is 14
; units, so this keeps every shot at roughly 7-11 DRAWN frames whatever the
; range: 1 (dist < 128, ~7 frames), 2 (~192, 7), 4 (~384, 7), then the ceiling.
; PJ_MAXSUB is the ceiling -- past it the missile would jump so far between
; frames that it is never seen twice at the same size.
; pj_ctab -- sub-steps per drawn frame, indexed by pj_sh (the shrink count, so
;   the distance's magnitude: the loop stops with the larger leg in [64,127],
;   i.e. dist ~ 96 << sh).
;   IT USED TO PACE THE SHOT: 1,2,4 for the first three rows, so a missile
;   fired at something close crawled 14 units per DRAWN FRAME instead of per
;   VBLANK -- seven times slower than DOOM at point-blank range and 30-70 %
;   everywhere else ("raketa leti moc pomaly", 2026-08-19). The intent was to
;   stop a short shot being over in two frames, but info.c is unambiguous:
;   MT_ROCKET is 20*FRACUNIT a tic, which IS 14 units per PAL VBLANK, and in
;   DOOM a rocket really does cross a small room in two frames.
;   Flat now, so min(dt_vbl, pj_cap) is always dt_vbl. The row stays a table
;   rather than becoming one constant because pj_go2 already indexes it and
;   pj_capdbl already doubles it for the plasma -- there is no room in either
;   block to delete the machinery, and none of it costs a cycle in flight.
pj_ctab dta PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB
        dta PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB,PJ_MAXSUB
pj_rec  dta a(0), a(0), a(0), 0, 0   ; pseudo thing record: x, y, z(anchor),
                                     ;   sprite id, flags 0
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; pj_aim -- A_FireMissile's fire half (A = the damage roll). Runs the crosshair
;   aim to learn WHO the rocket is going to hit and WHERE that is, and stops
;   there: pj_hold makes en_shoot return the moment it has the victim, so
;   nothing takes damage and nothing dies yet.
;--------------------------------------------------------------
        .endseg
