;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): A_Look's P_CheckSight -- ai_sight, sg_bsp, sg_tgt, sg_set/sg_shut.
;--------------------------------------------------------------
;==============================================================
; A_Look's REAL half (2026-08-05, "nepriatelia ma vidia len ked sa na nich
; pozeram"). ai_wake above is the port's original stand-in: it walks the
; PLAYER's vissprite list, so a monster woke exactly when the player's camera
; was pointing at it. p_enemy.c does nothing of the sort --
;==============================================================
;--------------------------------------------------------------
; ai_sight -- C=1 if thing ai_t can see the player. Builds the ray
;   (USE_PT_A = the monster, USE_PT_B = the player) and the sample step, then
;   falls into sg_walk. Clobbers A/X/Y, sp_ptr, zp_px/zp_py (put back).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_sight
        lda #$FF                     ; no leaf tested yet ($FFFF is not a leaf
        sta USE_SS                   ;   id). Primed here and not in sg_walk:
        sta USE_SS+1                 ;   that block is full to the byte.
        jsr sg_tgt                   ; USE_PT_B = the monster's TARGET (its own
                                     ;   quarry, not always the player) and
                                     ;   sg_pl = the player, for sg_bsp's restore
        lda ai_t                     ; ...and the monster is its ORIGIN
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = its record: x, y are +0..+3
        .LONGA ON                    ;   target - monster, each leg ONE 16-bit
        lda (sp_ptr)                 ;   subtract (2026-09-15: the byte loops
        sta USE_PT_A                 ;   were ~170 cycles; this is ~40)
        ldy #2
        lda (sp_ptr),y
        sta USE_PT_A+2
        sec
        lda USE_PT_B
        sbc USE_PT_A
        sta sg_dx
        sec
        lda USE_PT_B+2
        sbc USE_PT_A+2
        sta sg_dy
        .LONGA OFF
        sep #$20
                                      ; 2026-09-23: A still holds sg_dy -- xba is its
        xba                          ;   high byte; max() is symmetric, so dy first
        bpl ?py
        eor #$FF
?py     sta sg_t
        lda sg_dx+1
        bpl ?px
        eor #$FF
?px     cmp sg_t
        bcs ?far
        lda sg_t
?far    cmp #4                       ; 1024 units and out: nothing notices you
        bcs ?no                      ;   that far off (DOOM has no such limit,
        jsr sg_set                   ;   but no E1 sightline is longer)
        bra sg_bsp                   ; (sg_set: p_sight.c's z, for sh_leaf's sill
                                     ;  test -- and sp_ptr is still the monster's
                                     ;  record here, which is what it reads)
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_pvis -- aif_isvis' player case (infight.asm): DOOM's
;   P_CheckMissileRange opens with P_CheckSight(actor, target) and the player's
;   camera is not in it -- a monster used to stop firing the moment you turned
;   your back. On screen still answers yes for free; off screen costs the ray,
;   and only for a monster that is already chasing.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_pvis
        jsr aif_pchk                 ; is there still a player to shoot at, and
        beq ?no                      ;   was it drawn this frame? (2026-08-20:
        bcs ?yes                     ;   the dead half -- see aif_pchk)
        lda #>TH_SEEN                ; off screen: the CACHED ray, the one
        jsr ai_get                   ;   ai_look spends a frame on. Running a
        lsr                          ;   fresh one here cost 250k cycles per
        rts                          ;   attack decision -- most of a frame.
?no     clc
?yes    rts
.endp
        .endseg

        org SGSTK_BASE               ; the stack + counters (the old sg_walk hole)
SG_LEAFN equ 64                      ; leaves one ray may test before it gives up
                                     ;   and answers "blocked".
SG_STKN equ 40                       ; BSP depth the walk can hold. E1's deepest
                                     ;   tree is 605 nodes -- nowhere near this.
sg_stl  :SG_STKN dta 0               ; the far child waiting to be walked, low
sg_sth  :SG_STKN dta 0               ;   ...and high
sg_sp   dta 0                        ; stack pointer (0 = empty)
sg_sa   dta 0                        ; which side of this node USE_PT_A is on
    .if * > SGSTK_END+1
        ert 'the sight stack outgrew SGSTK_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; sg_bsp -- ai_sight's tail: p_sight.c P_CrossBSPNode, iterative.
;   C=1 = nothing crossed the ray USE_PT_A..USE_PT_B, i.e. they see each other.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_bsp
        stz sg_sp
        lda #SG_LEAFN
        sta sg_lf
        lda MAP_HROOT                ; from the root, like use_locate
        sta zp_nid
        lda MAP_HROOT+1
        sta zp_nid+1
                                      ; 2026-09-23: every producer of zp_nid+1 tests its own
        bmi ?leaf                    ;   N (sta keeps it) -- no reload, no `and #$80`
?nd
        jsr calc_nodeptr
                                    ; 2026-09-22 (65816-windows): calc_nodeptr returns 16-bit
        .LONGA ON                    ;   moves, not a byte loop: 2026-09-15)
        lda USE_PT_A
        sta zp_px
        lda USE_PT_A+2
        sta zp_py
        .LONGA OFF
                                     ; 2026-09-22 (65816-windows): past point_on_side's
        jsr point_on_side.pos_w16    ;   rep, still 16-bit (it returns 8-bit as before)
        sta sg_sa
        rep #$20                     ; ...and the PLAYER?
        .LONGA ON
        lda USE_PT_B
        sta zp_px
        lda USE_PT_B+2
        sta zp_py
        .LONGA OFF
                                     ; 2026-09-22 (65816-windows): past its rep
        jsr point_on_side.pos_w16    ; A = side of B, 0 or 1
        cmp sg_sa
        beq ?one                     ; both the same side: the other subtree
                                     ;   cannot hold anything the ray crosses
        asl                          ; the ray SPANS the split: park B's child
        adc #8
        tay
        ldx sg_sp
        lda [zp_nodeptr],y
        sta sg_stl,x
        iny
        lda [zp_nodeptr],y
        sta sg_sth,x
        inc sg_sp
?one    lda sg_sa                    ; ...and carry on into A's child, so the
        asl                          ;   walk stays roughly monster-to-player
        adc #8
        tay
        lda [zp_nodeptr],y
        sta zp_nid
        iny
        lda [zp_nodeptr],y
        sta zp_nid+1
                                      ; 2026-09-23: a node goes straight on, a leaf
        bpl ?nd                      ;   falls into ?leaf (the bra is gone)
?leaf   dec sg_lf                    ; out of budget -> "no sight this time", and
        beq ?blocked                 ;   the next lap of the table looks again
        jsr sh_leaf                  ; C=1: a wall or a shut door is in the way
        bcs ?blocked
        ldx sg_sp                    ; the far children this ray still owes
        beq ?clear
                                      ; 2026-09-23: X already holds sg_sp
        dex
        stx sg_sp
        lda sg_stl,x
        sta zp_nid
        lda sg_sth,x
        sta zp_nid+1
                                      ; 2026-09-23: N of the high byte picks node/leaf
        bpl ?nd
        bra ?leaf
?clear  sec                          ; nothing crossed it: they see each other
        bcs ?done                    ; (always)
?blocked clc
?done   stz sg_zon                   ; the walk is over: sh_leaf is the HITSCAN's
                                     ;   leaf test again, and those fly level
        rep #$20                     ; (two word moves, 2026-09-15)
        .LONGA ON
        lda sg_pl                    ; the PLAYER, back into zp_px/zp_py -- and
        sta zp_px                    ;   out of sg_tgt's own copy, not out of
        lda sg_pl+2                  ;   USE_PT_B: since 2026-08-25 the ray's far
        sta zp_py                    ;   end is the monster's TARGET, which for an
        .LONGA OFF
        sep #$20
        rts                          ;   read USE_PT_B for as long as the two were
.endp                                ;   the same point, and putting a monster's
        .endseg
                                     ;   position into zp_px would have moved the
                                     ;   PLAYER there for every reader downstream.

sgtgt_resume = *
        org SGTGT_BASE
;==============================================================
; THE RAY GOES WHERE THE MONSTER IS LOOKING (2026-08-25).
;==============================================================
;--------------------------------------------------------------
; sg_tgt -- ai_sight's head: sg_pl = the player, USE_PT_B = ai_t's target.
;   Clobbers A/X/Y, sp_ptr, m_prod, zp_ptr (aif_tpos' own list).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_tgt
        rep #$20                     ; the player, parked for sg_bsp's restore:
        .LONGA ON                    ;   two word moves (2026-09-15)
        lda zp_px
        sta sg_pl
        lda zp_py
        sta sg_pl+2
        .LONGA OFF
        sep #$20
        jsr aif_tpos                 ; ai_tx/ai_ty = TH_TARG resolved: the player
                                    ; 2026-09-22 (65816-windows): aif_tpos returns 16-bit
        .LONGA ON                    ;   is not. ai_ty follows ai_tx (infight.asm)
        lda ai_tx
        sta USE_PT_B
        lda ai_ty
        sta USE_PT_B+2
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; aif_mvis -- aif_isvis' MONSTER-target arm: Y = the target's thing index.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc aif_mvis
        jsr aif_live                 ; `target->health <= 0` first: it is the
        bcc ?no                      ;   cheaper test and the one A_SpidRefire's
        lda #>TH_SEEN                ;   livelock needs (see aif_isvis)
        jsr ai_get                   ; ...and the ray's own answer, for ai_t
        lsr                          ;   (TH_SEEN is 0/1 -- lsr puts it in C)
?no     rts
.endp
        .endseg

;--------------------------------------------------------------
; sg_seen -- aif_reset's tail: TH_SEEN = 0 for all 256 things. See the note
;   there for why a page that only ai_look ever wrote had to start being
;   cleared -- bank $01 keeps the previous level's answers otherwise.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_seen
        lda #<TH_SEEN                ; 0: the page is 256 B aligned like every
        sta zp_ptr                   ;   other per-thing page (zp_ptr+2 is on
        lda #>TH_SEEN                ;   MAP_EXT_BANK already -- init_level)
        sta zp_ptr+1
        ldy #0
        tya
?clr    sta [zp_ptr],y
        iny
        bne ?clr
        rts
.endp
        .endseg

sg_pl   dta 0,0,0,0                  ; the player's x/y across one sight walk
                                     ;   (sg_tgt saves it, sg_bsp puts it back).
    .if * > SGTGT_END+1
        ert 'sg_tgt/aif_mvis outgrew SGTGT_BASE..SGTGT_END (memory_map.inc)'
    .endif
        org sgtgt_resume

sgz_resume = *
        org SGZ_BASE
;==============================================================
; THE SIGHT RAY GETS A Z (2026-08-25, "e3m1 -- na zaciatku ma hned vidi IMP,
; ale to by nemal, som dole, nizsie ako on ... podobny problem je aj v e2m1").
;==============================================================
SG_EYE  equ 42                       ; sightzstart: mobj z + height - height/4,
                                     ;   for the 56 every monster but the barons
                                     ;   and the cyberdemon is.
SG_TOP  equ 56                       ; ...and the target's own height, same deal

;--------------------------------------------------------------
; sg_set -- ai_sight's tail: the four numbers the sill test needs, once per RAY.
;   In: ai_t = the monster, sp_ptr = its thing record, sg_dx/sg_dy = the ray.
;   Clobbers A/X/Y, m_a, sp_ptr, zp_ptr.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_set
        lda #>TH_TARG                ; ONLY A PLAYER TARGET gets a z. A_Look is the
        jsr ai_get                   ;   one path that WAKES anything and its target
        bne ?off                     ;   is always the player (p_enemy.c); an
                                     ; 2026-09-21 (drac030 #37/#44: word arithmetic split
        ldy #4                       ;   into byte halves, RIGHT BEFORE a 16-bit window):
        rep #$21                     ;   both adds move into the window that was already
        .LONGA ON                    ;   here for the subtract. C = 0 from the rep.
        lda (sp_ptr),y               ; z is a WORD at +4 of the thing record (plain RAM)
        adc #SG_EYE                  ; sightzstart
        sta sg_zs
        clc                          ; (z can be negative: the add above may carry)
        lda pl_z                     ; m_a = the TOP of the player
        adc #SG_TOP
        sta m_a                      ; (?lo reads it back) ... and A still holds it:
        sec                          ; sg_th = topslope at the far end of the ray,
        sbc sg_zs                    ;   one word subtract; N from it
        sta sg_th                    ; Y stays 4, not 5: both ways on reload it
                                      ; 2026-09-23: sg_lo = min(eye, target top) as
        bmi ?lo                      ;   one word store inside this window
        lda sg_zs
        bra ?st
?lo     lda m_a
?st     sta sg_lo
        .LONGA OFF
        sep #$20
        ldx #0                      ; a projection axis. ANY axis is SAFE -- the
        lda sg_dx+1                  ;   seg's two endpoints bracket the crossing
        bpl ?a1                      ;   on every one of them -- it only has to be
        eor #$FF                     ;   NON-ZERO, because the verdict reads its
?a1     bne ?got                     ;   sign. So: x while |dx| >= 256, else y --
        ldx #2                       ;   and a y of zero needs no guard here, the
?got    stx sg_ax                    ;   `ora sg_dt` below already turns the whole
                                     ;   test off for a leg that came out zero.
        lda sg_dx,x                  ; sg_dy FOLLOWS sg_dx, so the axis is an index
        sta sg_dt
        lda sg_dx+1,x
        sta sg_dt+1
        ora sg_dt                    ; a leg of zero would read as "blocked" on
        sta sg_zon                   ;   every seg -- then no z test at all, and
        rts                          ;   any other value means "this is a sight ray"
?off    rts                          ; sg_zon is ALREADY 0 here and this block had
                                     ;   one byte of room, not four: sg_set is only ...
.endp
        .endseg

;--------------------------------------------------------------
; sg_shut -- use_shut PLUS the sill. A = 1 if this seg stops the ray.
;   Called from sh_leaf in use_shut's place, so it costs sh_leaf nothing -- and
;   for the hitscan (sg_zon = 0) it IS use_shut, to the cycle.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_shut
        jsr use_shut
        bne ?out                     ; already shut: A = 1, there is nothing to add
        lda sg_zon
        beq ?out                     ; the bullet path: A = 0, and no z anywhere
                                      ; 2026-09-23: both word compares in one window
        rep #$20                     ;   (N/Z of a 16-bit sbc = the byte pair's)
        .LONGA ON
        sec
        lda coll_bx
        sbc coll_ax
        beq ?opw                     ; equal floors -> not a sill
        bpl ?have
        lda coll_ax
        sta coll_bx
?have   sec
        lda coll_bx
        sbc sg_lo
        .LONGA OFF
        sep #$20
        bmi ?open
        jsr use_seg_hit             ; ...and does the ray actually cross it?
        beq ?open                    ;   (coll_bx SURVIVES it: use_seg_hit works out
        rep #$20                     ; cx_a = openbottom - sill, cx_b = the ray's
        .LONGA ON                    ;   dominant extent, cx_c = target top -
        sec                          ;   sill: one window (drac030 idiom)
        lda coll_bx
        sbc sg_zs
        sta cx_a
        lda sg_dt
        sta cx_b
        lda sg_th
        sta cx_c
                                      ; 2026-09-23: ?ep opens with rep -- enter it 16-bit
        ldx sg_ax                    ; v1 first, then v2 (USE_PT_Q = USE_PT_P+4).
        jsr ?ep                      ;   (returns 8-bit, from cross_pos)
        .LONGA OFF
        bcs ?open
        lda sg_ax                    ; C = 0 (bcs not taken): X = sg_ax + 4
        adc #4
        tax
        jsr ?ep
        bcs ?open
        lda #1
        rts
?open   lda #0
?out    rts
?opw    sep #$20                     ; (16-bit here: the equal-floors exit above)
        lda #0
        rts
;   ?ep -- C=0 if the sill stands above the eye->target-top line at THIS
;   endpoint's projection. The test is
;       (openbottom - zs) * leg  >=  (top - zs) * (endpoint - start)
;   i.e. cross_pos' own a*b - c*d, and dividing that by the leg to get a real
;   slope is what the sign compare below replaces.
                                      ; 2026-09-23: the delta as one word, straight into
?ep     ldy sg_ax                    ;   cross_pos past its rep (entered 16-bit from
        rep #$20                     ;   the window above, 8-bit for v2)
        .LONGA ON
        sec
        lda USE_PT_P,x
        sbc USE_PT_A,y
        bvs ?nb                      ; (past signed 16: the safe answer)
        sta cx_d
        jsr cross_pos.cp_w16         ; (returns 8-bit; a*b - c*d stays in cx_p1)
        .LONGA OFF
        lda cx_p1+3
        eor sg_dt+1                  ; blocked <=> the product has the leg's OWN
        asl                          ;   sign; C=1 here means they differ
        rts
        .LONGA ON
?nb     sep #$21                     ; 8-bit, C = 1
        .LONGA OFF
        rts
.endp
        .endseg

sg_zs   dta a(0)                     ; sightzstart -- the monster's eye
sg_th   dta a(0)                     ; target top - sightzstart (DOOM's topslope)
sg_lo   dta a(0)                     ; min(eye, target top): the prefilter floor
sg_dt   dta a(0)                     ; the ray's projection leg, signed
sg_ax   dta 0                        ; 0 = project on x, 2 = on y (offset in a point)
sg_zon  dta 0                        ; 1 while sg_bsp is walking. sh_leaf is the
                                     ;   HITSCAN's leaf test too and this port's
                                     ;   bullets fly level (proj.asm), so they must
                                     ;   keep getting the old flat answer.
    .if * > SGZ_END+1
        ert 'sg_set/sg_shut outgrew SGZ_BASE..SGZ_END (memory_map.inc)'
    .endif
        org sgz_resume

