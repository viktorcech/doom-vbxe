;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): A_Look itself -- ai_cand, the round-robin ray (ai_look) and P_NoiseAlert's soundtarget (snd_flood, ai_heard).
;--------------------------------------------------------------
;--------------------------------------------------------------
; ai_cand -- C=1 if thing ai_t is a monster that CHASES and is still alive, and
;   ai_wk = whether it is chasing already (then ai_look's ray only refreshes
;   the frame's ray on one is the difference between 1k cycles and 100k.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_cand
                                      ; 2026-09-22 idiom: ai_bank inlined (see ai_look)
        stz zp_ptr
        lda #>TH_WROW
        sta zp_ptr+1
        ldy ai_t
        lda [zp_ptr],y               ; TH_WROW: chasing already?
        sta ai_wk
        lda #>TH_KIND                ; a monster at all? (en_kfill prefilled it)
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?no
        tax
        lda mk_ctic,x                ; ...one with RUN states?
        beq ?no
        jsr ai_ismon                 ; alive, and not already dying?
        beq ?no
        sec
        rts
?no     clc
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_look -- A_Look for ONE SIGHT RAY a frame (the header above says why).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_look
        lda pl_dead                  ; a corpse is not worth looking for
        bne ?out
        jsr snd_flood                ; P_NoiseAlert, on the frame of a shot
        lda THINGS_BASE              ; one full lap of the table. The counter
        sta ai_lc                    ;   lives in MEMORY: ai_sight and ai_start
                                     ;   clobber X and Y
?next   ldx ai_lk
        inx
        cpx THINGS_BASE              ; the level's thing count -> wrap
        bcc ?ok
        ldx #0
?ok     stx ai_lk
        stx ai_t
                                      ; 2026-09-26: ai_cand's two common-case reads
        lda.l MAP_EXT_BANK*$10000+TH_WROW,x  ;   inline, long,x: ai_wk as it wrote
        sta ai_wk                    ;   it, and a thing that is no monster (TH_KIND
        lda.l MAP_EXT_BANK*$10000+TH_KIND,x  ;   0, most of them) skips without the
        beq ?skip                    ;   call and the zp_ptr page switches
        jsr ai_cand                  ; a monster that can chase, and alive?
        bcc ?skip
        lda ai_wk                    ; (a monster already chasing still gets a
        bne ?ray                     ;   ray -- aif_pvis reads the cached answer)
        jsr ai_heard                 ; p_enemy.c:609: the sector's soundtarget
        beq ?face                    ;   FIRST. 0 = silence
        dec @
        beq ?ray                     ; 1 = heard but MF_AMBUSH: sight, no angle
                                      ; 2026-09-22: seestate's A_Chase runs at once
        jsr ai_see                   ; 2 = heard: `goto seeyou`, no sight at all
        bra ?skip                    ;   -- and on round the lap: the room wakes
?face   jsr ai_front                 ; A_Look's 180-degree test, BEFORE the ray:
        bcs ?skip                    ;   back turned costs nothing
?ray    stz sg_n                     ; "no ray has run yet" (ai_sight starts
        jsr ai_sight                 ;   with its own lda)
        lda #0                       ;   really happens, and a walk that comes
        rol                          ;   back BLOCKED always stops with at least
        ldx #>TH_SEEN                ;   one sample left (sg_walk tests before
        jsr ai_put                   ;   it decrements). So on C=0, sg_n tells
        beq ?blind                   ;   the two apart. Cache the answer for
        lda ai_wk                    ;   aif_pvis either way (ai_put leaves the
        bne ?out                     ;   value in A); already chasing means the
                                      ; 2026-09-22: seestate's A_Chase runs at once
        jmp ai_see                   ;   refresh was the whole point
?blind  lda sg_n                     ; nothing seen -- but did it COST anything?
        beq ?skip                    ;   culled on distance: two compares, carry
        rts                          ;   on scanning. A real ray: frame is done
?skip   dec ai_lc
        bne ?next
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; ai_see -- A_Look's P_SetMobjState(actor, seestate): ai_start, then the RUN1
;   state's own action, A_Chase, at once (P_SetMobjState runs it on entry).
;   TH_WROW = 0 after ai_start: it refused the thing (no RUN states).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ai_see
        jsr ai_start
        lda #>TH_WROW
        jsr ai_get
        beq ?out
        jmp ai_chase
?out    rts
.endp
        .endseg

;==============================================================
; P_NoiseAlert -- p_enemy.c P_RecursiveSound: soundtarget floods node to node
;   through open gaps, across ONE sound-block line, not two. The graph is baked
;   by pack_map._sndgraph (EXT bank); openings are read live from MAP_SECTORS.
;   MAP_SNDHEARD b7 = soundtarget (never clears), b0 = reached by this flood.
;==============================================================
        .segment B1
;--------------------------------------------------------------
; node_at_point -- (zp_px, zp_py) -> A = its sound node. 16-bit X only
;   (snd_irq saves no 16-bit Y). Clobbers what use_locate does.
;--------------------------------------------------------------
.proc node_at_point
        jsr use_locate               ; (2026-09-26: returns 16-bit M, A = zp_nid:
        rep #$10                     ;   only X widens here)
        .LONGA ON
        and #$7FFF                   ; the leaf bit
        tax
        sep #$20
        .LONGA OFF
        lda.l MAP_SNDSS,x
        sep #$10                     ; (flags are still the lda's)
        rts
.endp

;--------------------------------------------------------------
; snd_flood -- from ai_look: floods on the frame of a shot, and not again from
;   the same node while no door moves.
;--------------------------------------------------------------
.proc snd_flood
        lda ai_noise
        cmp #NOISE_FR
        bne ?out
        jsr node_at_point            ; the player's node
        cmp sf_last
        bne ?go
        lda DOOR_NACT
        beq ?out
        lda sf_last
?go     sta sf_last
        ldx #SND_NODES               ; "this flood" off everywhere, the
                                      ;   soundtargets stay. 2026-09-23: the base -1
?cl     lda.l MAP_SNDHEARD-1,x       ;   and dex/bne (X = N..1 = entries N-1..0,
        and #$80                     ;   the same ones): no txa a pass
        sta.l MAP_SNDHEARD-1,x
        dex
        bne ?cl
        stz sf_head
        stz sf_tail
        stz sf_pass
        lda sf_last
        jsr sf_push
        jsr sf_drain                 ; A: through no block line
        lda sf_tail
        sta sf_na
        stz sf_head
        inc sf_pass                  ; B: one block line out of each of those...
?b1     ldx sf_head
        cpx sf_na
        bcs ?b2
        jsr sf_expand
        bra ?b1
?b2     stz sf_pass                  ; ...and on from there, ordinary lines only
        bra sf_drain                 ;   (sf_head = sf_na: the new ones)
?out    rts
.endp

.proc sf_drain                       ; expand until the queue runs dry
?l      ldx sf_head
        cpx sf_tail
        bcs ?out
        jsr sf_expand
        bra ?l
?out    rts
.endp

;--------------------------------------------------------------
; sf_expand -- X = sf_head: push the far node of every open, unreached edge on
;   that queue entry's sf_pass list (0 ordinary, 1 block-line).
;--------------------------------------------------------------
.proc sf_expand
        inc sf_head
        lda.l MAP_SNDQ,x
        tax
        lda.l MAP_SNDIXL,x
        sta zp_ptr
        lda.l MAP_SNDIXH,x
        sta zp_ptr+1
                                      ; 2026-09-23 (6502-idioms: stream bytes): Y walks
        ldy #0                       ;   the list, [zp_ptr],y carries into the bank
        lda sf_pass                  ;   itself and the pointer's mid byte bumps when
        beq ?lp                      ;   Y wraps -- no jsr sf_next a byte. sf_open and
?sk     lda [zp_ptr],y               ;   sf_push keep Y (sf_open's rep/sep #$30 keeps
        iny                          ;   its low byte)
        sne
        inc zp_ptr+1
        inc @                        ; past the ordinary list, an edge at a time
        beq ?lp
        iny
        sne
        inc zp_ptr+1
        iny
        sne
        inc zp_ptr+1
        bra ?sk
?lp     lda [zp_ptr],y               ; the edge: neighbour node...
        cmp #$FF
        beq ?out
        sta sf_n
        iny
        sne
        inc zp_ptr+1
        lda [zp_ptr],y
        sta sf_ra                    ; ...my row...
        iny
        sne
        inc zp_ptr+1
        lda [zp_ptr],y
        sta sf_rb                    ; ...its row
        iny
        sne
        inc zp_ptr+1
        ldx sf_n
        lda.l MAP_SNDHEARD,x
        lsr
        bcs ?lp                      ; reached already
        jsr sf_open
        bcs ?lp                      ; openrange <= 0: a closed door
        lda sf_n
        jsr sf_push
        bra ?lp
?out    rts
.endp

.proc sf_next                        ; A = the list's next byte
        lda [zp_ptr]
        inc zp_ptr
        bne ?nc
        inc zp_ptr+1
?nc     rts
.endp

.proc sf_push                        ; A = a sector: soundtarget + reached, and queue it
        tax
        lda #$81
        sta.l MAP_SNDHEARD,x
        txa
        ldx sf_tail
        sta.l MAP_SNDQ,x
        inc sf_tail
        rts
.endp

;--------------------------------------------------------------
; sf_open -- C=0 when the opening between rows sf_ra/sf_rb is > 0. Heights are
;   small, so a subtraction's sign IS the compare. 16-bit X only, no X immediates.
;--------------------------------------------------------------
.proc sf_open
        rep #$30
        .LONGA ON
        lda sf_ra
        and #$00FF
        asl @
        asl @
        asl @
        tax
        lda MAP_SECTORS,x
        sta sf_bot
        lda MAP_SECTORS+2,x
        sta sf_top
        lda sf_rb
        and #$00FF
        asl @
        asl @
        asl @
        tax
                                      ; 2026-09-23: cmp keeps A (no reload); small heights,
        lda MAP_SECTORS,x            ;   so N of the compare IS the sign of the
        cmp sf_bot                   ;   difference (the header's invariant). the
        bmi ?f                       ;   higher floor...
        sta sf_bot
?f      lda MAP_SECTORS+2,x          ; ...the lower ceiling (equal: the same value,
        cmp sf_top                   ;   so skipping it changes nothing)
        bpl ?c
        sta sf_top
?c      lda sf_top
        clc                          ; openrange - 1: the clear carry IS the -1
        sbc sf_bot                   ; > 0  <=>  range-1 >= 0
        asl @                        ; C = its sign
        sep #$30
        .LONGA OFF
        rts
.endp

;--------------------------------------------------------------
; ai_heard -- thing ai_t: A = 0 no soundtarget in its node, 1 = heard but
;   MF_AMBUSH (record flags b7), 2 = heard. An idle monster stays in its spawn node.
;--------------------------------------------------------------
.proc ai_heard
        ldx ai_t
        lda.l MAP_THNODE,x
        tax
        lda.l MAP_SNDHEARD,x
        bpl ?no
        lda ai_t
        jsr en_thing.en_th2
        ldy #7
        lda (sp_ptr),y
        bmi ?amb
        lda #2
        rts
?amb    lda #1
        rts
?no     lda #0
        rts
.endp

;--------------------------------------------------------------
; snd_thnode -- en_radfill's tail: MAP_THNODE[thing] = its spawn node. Leaves
;   zp_ptr's low byte 0, the page pattern en_kfill reads through.
;--------------------------------------------------------------
.proc snd_thnode
        lda #$FF
        sta sf_last                  ; no flood yet on this level
        stz sf_head
?l      lda sf_head
        cmp THINGS_BASE
        bcs ?done
                                      ; 2026-09-22: en_th2w returns 16-bit
        jsr en_thing.en_th2w          ; sp_ptr = its record
        .LONGA ON
        lda (sp_ptr)
        sta zp_px
        ldy #2
        lda (sp_ptr),y
        sta zp_py
        sep #$20
        .LONGA OFF
        jsr node_at_point
        ldx sf_head
        sta.l MAP_THNODE,x
        inc sf_head
        bne ?l                       ; (always: the count is a byte)
?done   stz zp_ptr
        rts
.endp
        .endseg
        .segment D0
sf_last dta $FF                      ; the node the last flood started in
sf_head dta 0                        ; the work queue (MAP_SNDQ)
sf_tail dta 0
sf_na   dta 0                        ; ...and where phase A's part of it ends
sf_pass dta 0                        ; 0 = ordinary lists, 1 = block-line lists
sf_n    dta 0                        ; the edge under test: the far node...
sf_ra   dta 0                        ;   ...my MAP_SECTORS row on that line...
sf_rb   dta 0,0                      ;   ...and its row (+1: sf_open's word read)
sf_bot  dta a(0)                     ; sf_open: the higher floor...
sf_top  dta a(0)                     ;   ...and the lower ceiling
        .endseg

