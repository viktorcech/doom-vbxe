;--------------------------------------------------------------
; enemy.asm -- damage + death (P_DamageMobj / P_KillMobj / P_GunShot, reduced).
;   Hit points live in TH_HPL/TH_HPH in SRAM; 0 = not shootable.
;--------------------------------------------------------------
        org ENINIT_BASE

;--------------------------------------------------------------
; en_init -- per level: TH_HP[i] = hp_table[thing[i].sid]. Called from init_level
;   AFTER load_things has cached th_things (the blob's header pointers).
;   zp_ptr+2 already holds MAP_EXT_BANK -- init_level sets it and nothing else
;   writes it (collision.asm's note), so the long stores below need no setup.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_init
        ; sp_tab / sp_ptr borrowed as the two (zp),y readers -- they are sprites.asm
        ; per-frame scratch and init_level runs long before the first frame.
                                      ; 2026-09-22 idiom: two word copies -> one 16-bit
        rep #$20                     ;   window (bank $01 code = native)
        .LONGA ON
        lda THINGS_BASE+16           ; p_hp: the u16-per-sprite table (HEADER+16;
        sta sp_tab                   ;   the other pointers sit at +5/+11/+13/+14
        lda th_things                ;   and are untouched by that append); walk the
        sta sp_ptr                   ;   thing records with a running pointer
        sep #$20
        .LONGA OFF
        jsr wrot_init                ; cache the per-level stored-view count
                                     ;   (this block is full: the body lives
                                     ;   with spr_wrot at WROT_BASE)
        lda #<TH_HPL
        sta zp_ptr
        lda #>TH_HPL
        sta zp_ptr+1
        ldx #0                       ; X = thing index
?lp     cpx THINGS_BASE              ; thing count (the packer caps it at 255)
        bcs ?done
        ldy #6                       ; thing record +6 = sprite id
        lda (sp_ptr),y
        asl                          ; *2: the table is u16 (sid < 128 always --
        tay                          ;   a level has at most ~32 sprites)
        lda (sp_tab),y
        sta en_t
        iny
        lda (sp_tab),y
        sta en_t+1
        txy                          ; Y = thing index -> the bank $01 page offset
        lda en_t
        sta [zp_ptr],y               ; TH_HPL[i]
        inc zp_ptr+1                 ; $6400 -> $6500 = TH_HPH
        lda en_t+1
        sta [zp_ptr],y
        dec zp_ptr+1
        jsr wrot_dir                 ; TH_DIR[i] = the spawn facing (flags bits
                                     ;   4-6) -- P_SpawnMapThing's angle
        clc                          ; next record
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inx
        bne ?lp                      ; (count <= 255, so this always loops back)
?done   lda #<TH_STATE               ; nothing is dying at level start -- RAM in
        sta zp_ptr                   ;   bank $01 is whatever the last level left
        lda #>TH_STATE
        sta zp_ptr+1
                                      ; 2026-09-22 (65816-style: a byte sweep read as words)
        ldy #0
        rep #$20
        .LONGA ON
        lda #$0000
?cl     sta [zp_ptr],y
        iny
        iny
        bne ?cl
        sep #$20
        .LONGA OFF
        jsr blk_fill                 ; the blockmap, BEFORE the first move test:
                                     ;   move_player runs earlier in the frame
                                     ;   than the rebuild (enemy_ai.asm)
        jsr en_radfill               ; TH_RAD, the radius en_solid sweeps (it and
                                     ;   its variables live in the THCOLL block --
                                     ;   this one is full, see the note above)
        jmp en_kfill                 ; TH_KIND for every thing (WROT block: this
.endp                                ;   one is full) -- and IT tail-jumps the
        .endseg
                                     ;   ai_reset that used to sit here.

; (en_kind_of MOVED to the WROT block 2026-08-03: wrot_dir/wrot_init pushed
;  this block 6 B over, and wrot_idle calls it anyway -- same neighbourhood.)

; ---- split out 2026-09-21 into the enemy_* files (see each one's header). They are
;      included HERE, in the original order, so the assembler emits the same bytes.
        icl 'enemy_shoot.asm'


;--------------------------------------------------------------
; PLAN, so the next step does not have to re-derive it:
;   DEATH ANIMATION needs the deathstate chain from info.c (POSS: DIE1..DIE5 at
;   5 tics each, DIE5 tics = -1 = a frozen corpse) plus TH_STATE/TH_TICS arrays --
;   both fit next to TH_HP in bank $01 at $6600/$6700.
;--------------------------------------------------------------

;==============================================================
; DEATH ANIMATION -- p_mobj.c P_SetMobjState walking info.c's deathstate chain,
; reduced to a table walk. The frames live in Rapidus bank $01 (DTAB_ROWS,
; pack_things.pack_death); TH_STATE[i] is 0 for a live thing and otherwise the
; row index + 1, so spr_proj resolves a dying thing with one test and one shift.
;==============================================================

;--------------------------------------------------------------
; en_row -- en_k2+1 (a TH_STATE value, row+1) -> zp_ptr = &DTAB_ROWS[row].
;   zp_ptr+2 is already MAP_EXT_BANK (init_level sets it once). Clobbers A.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_row
        lda en_k2+1
	dec
	rep #$20
	.LONGA ON
	and #$00ff
	asl
	asl
	asl
;	clc
	adc #DTAB_ROWS
	sta zp_ptr
                                    ; 2026-09-22 (65816-windows): en_row returns 16-bit
	.LONGA OFF
        rts
.endp
        .endseg

;--------------------------------------------------------------
; en_kill -- Y = thing index, en_kind set. Start the death chain; if this kind
;   has none, fall back to the old behaviour (the thing just stops being drawn).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_kill
        sty en_k2
        jsr en_dropmark              ; P_KillMobj's "Drop stuff": the zombieman's
                                     ;   clip / the shotgun guy's gun ride on the
                                     ;   corpse (see the F_DROP note)
        ldy en_k2                    ; (en_dropmark walks the thing table)
        lda #<TH_WROW                ; STOP CHASING, now -- not at the AI's next
        sta zp_ptr                   ;   state expiry. ai_state does notice a dead
        lda #>TH_WROW                ;   thing, but only when its RUN state runs
        sta zp_ptr+1                 ;   out (2-4 tics), and until then the corpse
        lda #0                       ;   keeps taking steps. Clearing TH_WROW is
        sta [zp_ptr],y               ;   what stops it.
        jsr en_gibq                  ; p_inter.c:719: overkill past spawnhealth
                                     ;   goes to xdeathstate instead, and en_gibq
                                     ;   leaves zp_ptr on whichever header won
        ldy en_kind                  ; the per-kind first-row index
        lda [zp_ptr],y
        cmp #$FF
        beq ?none
	inc
        sta en_k2+1
        jsr en_row
                                    ; 2026-09-22 (65816-windows): en_row returns 16-bit
        sep #$20
        lda RANDOM                   ; P_KillMobj (p_inter.c:726): the first row
        and #3                       ;   runs P_Random() & 3 tics short, one tic
        sta en_t                     ;   at least
        ldy #7
        lda [zp_ptr],y               ; its tics (bits 6/7 are the A_Explode /
        and #$3F                     ;   last flags)
        sec
        sbc en_t
        beq ?min
        bcs ?tok
?min    lda #1
?tok    pha                          ; (over the TH_STATE store)
        stz zp_ptr                   ; <TH_STATE = 0 (page-aligned: ert)
        lda #>TH_STATE
        sta zp_ptr+1
    .if [TH_STATE & $FF] != 0
        ert 'TH_STATE is not page-aligned -- put the lda #< back (enemy.asm)'
    .endif
        ldy en_k2
        lda en_k2+1
        sta [zp_ptr],y
        lda #>TH_TICS
        sta zp_ptr+1
        pla
        sta [zp_ptr],y
        rts                          ; the chain runs; A_BossDeath waits for its
                                     ;   LAST frame, which is bd_at's job now
                                     ;   (2026-08-20).
?none   ldx en_k2                    ; ...but a kind whose frames did not fit VRAM
        jsr thing_kill               ;   has NO death chain to hang it on, so this
                                     ; 2026-09-21 drac_bra: the target is the very
        ert *<>en_bossdie           ;   next byte of this segment -- fall through
.endp                                ;   is why pack_death refuses to ship the
        .endseg
                                     ;   BOSS a chain it had to cut short: full
                                     ;   chain or none, never half of one.)


;--------------------------------------------------------------
; en_bossdie -- p_enemy.c A_BossDeath, all three episodes.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_bossdie
        lda en_kind                  ; en_kill leaves it set; en_row and the
        cmp THINGS_BASE+34           ;   TH_STATE/TH_TICS stores above do not
        bne ?out                     ;   touch it. +34 = the kind A_BossDeath
                                     ;   fires on HERE (0 = no boss hook, and ...
        lda THINGS_BASE+32           ; bosses still standing. 0 = this level has
        beq ?out                     ;   no record, so nothing to fire -- the
                                     ;   belt to the kind byte's braces
        dec THINGS_BASE+32           ; the blob is re-read on every level load
        bne ?out                     ;   (and on a death restart), so this counter
                                     ;   comes back with it
        lda THINGS_BASE+31           ; the tag-666 record -- fired exactly the way
        cmp #$FE                     ;   a walkover fires one. $FE (2026-08-18) is
        bne ?fire                    ;   pack_things' sentinel for E2M8/E3M8:
        inc EXIT_REQ                 ;   A_BossDeath there is G_ExitLevel, not a
        rts                          ;   666 floor -- main consumes the flag
                                     ;   after the flip, same as an EXIT seg.
?fire   sta mv_i                     ;   (mv_i is also what
                                     ;   mv_change reads to find its colour pair)
        lda m_prod                   ; en_bhit parks the blast damage here and
        pha                          ;   en_thrust_bl still wants it after we
        jsr mv_ptr                   ;   return -- mv_ptr uses m_prod as its
        jsr trig_fire                ;   *16 scratch. A barrel CAN kill a baron.
        pla
        sta m_prod
?out    rts
.endp
        .endseg


;--------------------------------------------------------------
; en_adv -- en_k2 = thing, en_k2+1 = the state whose tics just ran out.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_adv
        jsr en_row
                                    ; 2026-09-22 (65816-windows): en_row returns 16-bit
        sep #$20
        ldy #7
        lda [zp_ptr],y
        bmi ?gone                    ; $80|n -> the chain ended: no corpse
        inc en_k2+1                  ; step to the next row
        jsr en_row
                                    ; 2026-09-22 (65816-windows): en_row returns 16-bit
        sep #$20
        ldy #7
        lda [zp_ptr],y
        cmp #$FF
        beq ?put                     ; $FF -> park here for good
        pha                          ; DOOM runs the state's action on ENTRY:
        and #DT_BOOM                 ;   BEXP D is {A_Explode}, so the blast goes
        beq ?nb                      ;   off here, three frames into the barrel
        jsr en_boom
?nb     pla
        and #$3F
?put    pha                          ; the new row's tics, over the TH_STATE
        lda #<TH_STATE               ;   store -- on the STACK and not in en_t
        sta zp_ptr                   ;   since 2026-08-20. Four bytes cheaper
        lda #>TH_STATE               ;   than the pair of absolute accesses, and
        sta zp_ptr+1                 ;   four is what paid for the jmp below:
        ldy en_k2                    ;   ENANIM2 ends where snd_dispatch begins
        lda en_k2+1                  ;   and had not one byte spare. The push is
        sta [zp_ptr],y               ;   balanced over straight-line code (the
        lda #>TH_TICS                ;   only jsr on this path, en_boom, is
        sta zp_ptr+1                 ;   already above with a pha/pla of its own)
        pla
        sta [zp_ptr],y
        bra bd_at                    ; was the row we just entered the FROZEN
                                     ;   one? Then it is info.c's last death
                                     ;   frame and A_BossDeath goes off there
?gone   lda #<TH_STATE
        sta zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        ldy en_k2
        lda #0
        sta [zp_ptr],y               ; back to "not animating"...
        ldx en_k2
        jmp thing_kill               ;   ...and gone from the world
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; bd_at -- en_adv's tail: A = the tics byte it just stored, Y = en_k2 (the
;   thing), zp_ptr = TH_TICS. p_enemy.c does not hang A_BossDeath off the KILL,
;   it hangs it off a STATE -- S_BOSS_DIE7, S_CYBER_DIE10, S_SPID_DIE11 -- and
;   all three are the `-1 tics` corpse row at the end of the chain, which is
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc bd_at
        cmp #$FF                     ; DT_FREEZE: the corpse row, i.e. the last
        beq ?boss                    ;   death frame -- every other row just ran
        rts
?boss   lda #>TH_KIND                ; zp_ptr's low byte is still 0: every
        sta zp_ptr+1                 ;   per-thing AI page is 256 B aligned and
        lda [zp_ptr],y               ;   en_adv left it pointing at TH_TICS
        sta en_kind
        jmp en_bossdie               ; ...which answers "not the boss" for all
.endp                                ;   but three things in the whole game
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; en_tick -- one DOOM tic of every dying thing. Called from the game loop.
;   Parked at ENTICK_BASE: the trimmed idle path grew it out of ENANIM2.
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc en_tick
        ; 2026-09-09 (drac030 style): TH_STATE read as WORDS, two things per
        ; [zp_ptr],y -- see ai_tick (enemy_ai.asm) for the shape and the
        ; alignment argument.
    .if [TH_STATE & $FF] != 0
        ert 'en_tick: TH_STATE must be page-aligned for the word sweep'
    .endif
        stz zp_ptr
        lda #>TH_STATE
        sta zp_ptr+1
        ldx #0                       ; 2026-09-26: as ai_tick -- the idle sweep in X,
        rep #$20                     ;   long,x, the watermark a patched immediate
        .LONGA ON
?lp     lda.l MAP_EXT_BANK*$10000+TH_STATE,x
        bne ?hit
?next   inx
        inx
ent_lim cpx #0                       ; WATERMARK (2026-09-14): n_things, even --
        bne ?lp                      ;   ai_reset patches it (enemy_ai.asm)
        sep #$20
        .LONGA OFF
        jmp an_tick                  ; the idle rings ride the SAME DOOM tic
                                     ;   (sprites.asm). Chained, not a second jsr
                                     ;   in wp_think: that block is full
?hit    txy
        sep #$20                     ; one of the pair is dying: which?
        .LONGA OFF
        lda [zp_ptr],y               ; the even one
        beq ?odd
        jsr ?one
?odd    iny
        lda [zp_ptr],y               ; the odd one (?one puts TH_STATE back)
        beq ?cont
        jsr ?one
?cont   iny                          ; Z = Y at the watermark: the sweep is over
        tyx
ent_lim2 cpx #0
        rep #$20
        .LONGA ON
        bne ?lp
        sep #$20
        .LONGA OFF
        jmp an_tick
?one    sta en_k2+1                  ; ---- thing Y is dying: A = its row+1
        lda #>TH_TICS
        sta zp_ptr+1
        lda [zp_ptr],y
        cmp #$FF
        beq ?back                    ; the corpse: nothing left to do
        dec @
        sta [zp_ptr],y
        bne ?back
        sty en_k2                    ; the row is over -> next frame
        jsr en_adv
        ldy en_k2
        stz zp_ptr                   ; en_adv walked pages of its own
?back   lda #>TH_STATE
        sta zp_ptr+1
        rts
.endp
        .endseg


        icl 'enemy_coll.asm'

        icl 'enemy_blast.asm'
        icl 'enemy_wrot.asm'
