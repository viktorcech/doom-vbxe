;--------------------------------------------------------------
; read_keys.asm -- the keyboard: one POKEY sample per frame, one edge test.
;--------------------------------------------------------------
; read_keys -- ONE keyboard sample per frame drives every toggle key. The OS IRQ
;   is masked, so this polls POKEY directly: SKSTAT bit2 = 0 while a key is held,
;   KBCODE = its hardware code. Only one key can be down at a time, which is why
;--------------------------------------------------------------
rk_resume = *
        org READKEYS_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc read_keys
                                      ; cht_scan's first instruction is `lda kb_new`:
        jsr cht_scan                  ; both cheats, off kb_scan's press edges
                                      ;   is down right now.
        ldx #0                        ; X = SPACE state this frame, Y = which
        ldy #0                        ;   toggle key is down
        lda SKSTAT                    ; no key down -> all released
                                      ; 2026-09-23 (rapidus-bus-timing): the ONE sample
        sta kb_sk                     ;   this frame -- mn_key's mnk_rk entry reads the
        and #4
        bne ?edge
        lda KBCODE
        cmp #KEY_SPACE
        bne ?nsp
        inx
        bne ?edge                     ; always taken
?nsp    ldy #1                        ; 1 = '-' (or '<': see KEY_LT -- that is the
        cmp #KEY_MINUS                ;   one Altirra's default map puts on the PC
        beq ?edge                     ;   '-' key, and both are free in the game)
        cmp #KEY_LT
        beq ?edge
        iny                           ; 2 = '=' (or '>')
        cmp #KEY_EQUALS
        beq ?edge
        cmp #KEY_GT
        beq ?edge
                                      ; 2026-09-22 (6502-idioms: the index counts DOWN to
        ldy #WK_LAST-3                ;   -1, no cpy): Y = slot - 3 in the scan, and the
?wk     cmp wk_tab,y                  ;   three iny below put the 3 back on a hit -- the
        beq ?wkh                      ;   same slot ?wkey turns into the wp_* id
        dey
        bpl ?wk
        ldy #10                       ; 10 = 'T': flat walls on/off (fast frame)
        cmp #KEY_T
        beq ?edge
        ldy #256-3                    ; any other key: no toggle down (0, after the iny)
?wkh    iny
        iny
        iny
?edge   cpx DOOR_TRIGPREV             ; --- SPACE: act once per press ---
        beq ?tog
        stx DOOR_TRIGPREV
        txa
        beq ?tog                      ; released -> ignore
        jsr try_use                   ; rising edge -> USE
        ldy #0                        ; try_use clobbers Y; SPACE means the rest are up
?tog    cpy key_prev                  ; --- toggles: act once per press ---
        beq ?ret
        sty key_prev
        dey
        bmi ?ret                      ; release -> ignore
        beq ?vsm                      ; 1 = '-' -> one step smaller
        dey
        bne ?not2                     ; 3..9 below
        jsr vw_bigger                 ; 2 = '=' -> one step bigger
        bra ?ret
?not2   cpy #8                        ; slot 10 = 'T' (Y is slot-2 here)
        bne ?wkey
        lda tex_flat                  ; flip the runtime flat-walls switch --
        eor #1                        ;   seg_draw's resolve reads it per seg
        sta tex_flat
        bra ?ret
?wkey   dey                           ; Y was 3..9 and is now 0..6 = the wp_* id
        tya                           ;   ('1' = fist .. '7' = the BFG, DOOM's
        jsr wp_select                 ;   own keys); wp_select ignores what the
        bra ?ret                      ;   player does not own
?vsm    jsr vw_smaller
?ret    jmp mn_key.mnk_rk             ; tail-call: ESC (menu.asm) on kb_sk, which tail-calls
                                      ;   vw_frame -- the border repaint after a
                                      ;   resize.
.endp
        .endseg
        .segment D0
kb_sk   dta 0                         ; read_keys' SKSTAT sample for mn_key (2026-09-23)
        .endseg
wk_tab  dta KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7  ; slot 3..9 -> wp 0..6
WK_LAST equ 2 + * - wk_tab           ; = the LAST slot ('7' -> 9)
    .if * > READKEYS_END+1
        ert 'read_keys outgrew READKEYS_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; cht_key -- m_cheat.c cht_CheckCheat, for the one sequence this port has.
;   A = KBCODE on a frame where a key IS down. Clobbers A/X.
;--------------------------------------------------------------
        org CHTKEY_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cht_key
        cmp cht_prev
        beq ?out                      ; still the same key held down
        sta cht_prev
        ldx cht_n
        cpx #CHT_LEN                  ; uninitialised RAM -> start over, do not
        bcs ?rst                      ;   read past the table
        cmp cht_tab,x
        bne ?rst                      ; wrong letter -> back to the start
        inx
        cpx #CHT_LEN
        bcc ?set
        jsr cht_give                  ; the whole word: hand it over
?rst    ldx #0
?set    stx cht_n
?out    rts
.endp
        .endseg
cht_tab dta KEY_I, KEY_D, KEY_K, KEY_F, KEY_A
CHT_LEN equ * - cht_tab
    .if * > CHTKEY_END+1
        ert 'cht_key outgrew CHTKEY_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; cht_give -- st_stuff.c's IDKFA body, verbatim except where the port has no
;   field for it:
;       plyr->armorpoints = 200;  plyr->armortype = 2;
;       weaponowned[i] = true;  ammo[i] = maxammo[i];  cards[i] = true;
;--------------------------------------------------------------
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cht_give
        jsr cht_arm                   ; armorpoints = 200, armortype = 2
        lda #WP_ART
        sta PSTATE+PS_WEAPONS
        lda #7                        ; blue|yellow|red -- BN_AMT's key bits 1/2/4
        sta PSTATE+PS_KEYS
        ldx #3
?am     lda pw_amax,x                 ; maxammo[], doubled if he has the backpack
        jsr pw_max                    ;   (powerups.asm; it only touches A)
        sta PSTATE+PS_BULLETS,x
        dex
        bpl ?am
        inc hud_dirty                 ; the bar IS the acknowledgement (note
                                      ;   above), so mark it dirty HERE: nothing
                                      ;   else repaints after a cheat.
        rts                           ; SILENT -- see the note above. A cheat that
                                      ;   announces itself with the weapon-pickup
                                      ;   sound is not what m_cheat.c does.
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;--------------------------------------------------------------
; cht_arm -- IDKFA's "armorpoints = 200; armortype = 2" (st_stuff.c), parked in
;   en_bkill's tail because cht_give's own block is full to two bytes. Setting
;   the type is pl_armset's job, and the blue-armour bonus id is what says 2.
;--------------------------------------------------------------
        org CHTARM_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc cht_arm
        lda #200
        sta PSTATE+PS_ARMOR
        ldy #7                        ; the blue-armour bonus id -> armortype 2
        jmp pl_armset
.endp
        .endseg
    .if * > CHTARM_END+1
        ert 'cht_arm outgrew CHTARM_BASE..CHTARM_END (memory_map.inc)'
    .endif
        org rk_resume
