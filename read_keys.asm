;--------------------------------------------------------------
; RAM BUDGET: 1118 B free, biggest contiguous block 268 B.
;   Full map: the generated RAM-BUDGET block at the top of memory_map.inc.
;   Print it any time with:  python tools/ram_map.py
;
; BEFORE YOU ADD CODE ANYWHERE, read this: some RAM looks free to MADS and is
; NOT. It carries no XEX segment, so the assembler places code there happily --
; and then something overwrites it at runtime, before the first frame:
;     $1000-$13FF  TEX_STAGE   -- the SIO staging buffer, every loader streams here
;     $4000-$4BFF  map slot    -- load_level streams the level here
;                              ($4C00-$85FF was the seg table until
;                               2026-07-31; it is ordinary RAM now)
;     $9000-$9FFF  MEMAC window-- writes go to VBXE, not to RAM
;     $1400-$14FF  bsp_stack   -- rebuilt every frame ($1500+ is CODE now)
;     $0700-$08FF  ATR boot loader, alive WHILE the XEX loads
; There is no error message. The symptom is a flat pink screen at boot. It has
; already cost one debugging session ($A800 blit segment crept past $B000).
;
; When a segment runs out of room, move a whole .proc out with `org` + absolute
; jsr -- that is why collision sits at $0900, check_bbox at $1B00 and tw_setup at
; $8D00 -- instead of letting the segment creep into the next thing.
;
; Guards, all three wired into build.ps1 / build_atr.ps1:
;   * the RESERVED list in tools/ram_map.py (check_xex.py enforces it)
;   * tools/check_xex.py                    (fails the build on any overlap)
;   * tools/ram_map.py --update             (regenerates these figures)
;--------------------------------------------------------------

;==============================================================
; KEYBOARD (the whole of it) -- one POKEY sample per frame, one edge test.
;
; This lived at the tail of doors.asm until 2026-07-31, for a historical reason
; only: it grew out of read_use, and USE is doors (try_use / use_leaf are still
; in that file). By the time the view-size and weapon keys had been folded into
; the same sample, "the door file" was the wrong home for the engine's only
; keyboard reader, so it is its own file now.
;
; The move is TEXT ONLY. The block carries its own org wrap (rk_resume = * ...
; org rk_resume), so it emits nothing at the ambient PC and can be icl'd from
; anywhere -- renderer.asm keeps it next to `icl 'doors.asm'` because try_use is
; its one under-ROM callee and because that is where this build's org-redirect
; chain lives. The assembled bytes are identical to the doors.asm version.
;==============================================================

;--------------------------------------------------------------
; read_keys -- ONE keyboard sample per frame drives every toggle key. The OS IRQ
;   is masked, so this polls POKEY directly: SKSTAT bit2 = 0 while a key is held,
;   KBCODE = its hardware code. Only one key can be down at a time, which is why
;   a single read serves both keys -- the old read_use/read_texkey pair sampled
;   SKSTAT+KBCODE twice per frame for the same answer.
;     SPACE = USE: on the press EDGE, toggle a door at/ahead of the player. (The
;       fire button stays free for shooting.) Edge via DOOR_TRIGPREV.
;     '-'/'=' = shrink / grow the 3D view, DOOM's screenblocks (viewsize.asm):
;       the same picture drawn smaller, which is the port's one real speed knob.
;     '1'..'6' = select weapon, DOOM's own keys.
;   key_prev holds WHICH toggle key was down last frame (1 '-', 2 '='), so one
;   sample and one edge test still serve all of them.
;   Parked at READKEYS_BASE (it does not fit the doors-block tail at $FC13) --
;   cold code, once per frame; it tail-calls vw_frame, which is why every exit
;   path goes through ?ret.
;--------------------------------------------------------------
rk_resume = *
        org READKEYS_BASE
.proc read_keys
        lda KBCODE                    ; --- the IDKFA sniffer gets the FIRST look,
        jsr cht_key                   ;   and it must NOT ask SKSTAT whether a key
                                      ;   is down right now. SKSTAT bit2 is low
                                      ;   only while the key is physically held
                                      ;   (Altirra pokey.cpp:1510), this runs once
                                      ;   per RENDERED frame -- 100-200 ms at this
                                      ;   engine's fps -- and a normal keystroke is
                                      ;   shorter than that. So "idkfa" typed at
                                      ;   any human speed lost letters, hit a wrong
                                      ;   one and reset the matcher; the cheat
                                      ;   worked only if you held each key for a
                                      ;   whole frame. KBCODE LATCHES the last key
                                      ;   pressed and keeps it after the release,
                                      ;   and cht_key's own `cmp cht_prev` is the
                                      ;   press edge -- so reading it unconditionally
                                      ;   catches keys that came and went between
                                      ;   two frames, and drops the second POKEY
                                      ;   read at the same time (-6 B).
        ldx #0                        ; X = SPACE state this frame, Y = which
        ldy #0                        ;   toggle key is down
        lda SKSTAT                    ; no key down -> all released
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
        ldy #WK_LAST                  ; 3..9 = '1'..'7' (select weapon). A table
?wk     cmp wk_tab-3,y                ;   scan, not a chain of cmp/beq: the chain
        beq ?edge                     ;   cost 5 B per key and the block is hard
        dey                           ;   against en_los at $F218. Scanned from
        cpy #3                        ;   the top so Y IS the key's slot, which is
        bcs ?wk                       ;   what ?wkey below turns into the wp_* id.
                                      ;   '7' joined it 2026-08-28 with the BFG:
                                      ;   the table grew a byte and NOTHING else
                                      ;   in the scan changed, which is the whole
                                      ;   point of it being a table.
        ldy #10                       ; 10 = 'T': flat walls on/off (fast frame)
        cmp #KEY_T
        beq ?edge
        ldy #0                        ; any other key: no toggle down
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
        jmp ?ret
?not2   cpy #8                        ; slot 10 = 'T' (Y is slot-2 here)
        bne ?wkey
        lda tex_flat                  ; flip the runtime flat-walls switch --
        eor #1                        ;   seg_draw's resolve reads it per seg
        sta tex_flat
        jmp ?ret
?wkey   dey                           ; Y was 3..9 and is now 0..6 = the wp_* id
        tya                           ;   ('1' = fist .. '7' = the BFG, DOOM's
        jsr wp_select                 ;   own keys); wp_select ignores what the
        jmp ?ret                      ;   player does not own
?vsm    jsr vw_smaller
?ret    jmp mn_key                    ; tail-call: ESC (menu.asm), which tail-calls
                                      ;   vw_frame -- the border repaint after a
                                      ;   resize. Retargeting the existing jump
                                      ;   costs this block zero bytes, and it has
                                      ;   none: $F180-$F217 is full.
.endp
wk_tab  dta KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7  ; slot 3..9 -> wp 0..6
WK_LAST equ 2 + * - wk_tab           ; = the LAST slot ('7' -> 9)
    .if * > READKEYS_END+1
        ert 'read_keys outgrew READKEYS_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; cht_key -- m_cheat.c cht_CheckCheat, for the one sequence this port has.
;   A = KBCODE on a frame where a key IS down. Clobbers A/X.
;
;   id's matcher is simpler than people remember: on a mismatch it does
;   `cht->p = cht->sequence` and does NOT re-test the offending key against the
;   first letter. So does this -- type "iidkfa" and you start over, exactly as
;   in DOOM.
;
;   The port has no key-UP event, so "a new press" is "KBCODE differs from the
;   last code we accepted". That is enough here and only here: "idkfa" has no
;   doubled letter. IDDQD does, and would need a real release edge -- which is
;   why this is one cheat and not a table of them.
;
;   cht_n is RANGE-CHECKED rather than initialised at boot. Both cost 4 bytes;
;   only this block had them (the `sta cht_n` in bsp_main grew the $2000 segment
;   into its neighbour and check_xex.py failed the build). Skip either one and
;   boot RAM indexes cht_tab out of bounds -- a 1-in-256 IDKFA on the first key.
;--------------------------------------------------------------
        org CHTKEY_BASE
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
;   * armortype HAS a home now (pl_armt, memory_map.inc), so IDKFA hands out the
;     real blue suit: 200 points at the 1/2 rate. cht_arm does both, and it is a
;     jsr because this block has two spare bytes and needs five.
;   * "every weapon" is WP_ART, which is $FF now -- 2026-08-28 gave the BFG
;     its psprite and set bit 6, so IDKFA really does hand out all eight. It
;     stays the named constant: WP_ART is what wp_select gates on, and the next
;     weapon that arrives without art wants exactly this bit cleared again.
;   * maxammo[] IS the backpack-doubled cap in DOOM, so this goes through
;     pw_max like the backpack pickup does, and reuses its table. powerups.asm
;     needs its pw_aidx indirection because give_bonus hands it a bonus id; here
;     the four types ARE PSTATE+PS_BULLETS..PS_CELLS in pw_amax's own order, so
;     the same X indexes both and the lookup is three bytes that need not exist.
;   * DOOM answers with a MESSAGE (STSTR_KFAADDED) and nothing else -- no sound.
;     This used to end `lda #SFX_WPNUP / sta snd_pending` as a stand-in for the
;     message line the HUD does not have (2026-08-29: removed). st_stuff.c's
;     cht_CheckCheat block for cheat_ammo sets armour, weapons, ammo and cards
;     and assigns plyr->message; S_StartSound appears nowhere in it, and none of
;     the other cheats make a noise either. The acknowledgement is the HUD
;     itself: the ARMS boxes light up, the armour reads 200 and the keys appear.
;--------------------------------------------------------------
        org CHTGIVE_BASE
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
        rts                           ; SILENT -- see the note above. A cheat that
                                      ;   announces itself with the weapon-pickup
                                      ;   sound is not what m_cheat.c does.
.endp
    .if * > CHTGIVE_END+1
        ert 'cht_give outgrew CHTGIVE_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; cht_arm -- IDKFA's "armorpoints = 200; armortype = 2" (st_stuff.c), parked in
;   en_bkill's tail because cht_give's own block is full to two bytes. Setting
;   the type is pl_armset's job, and the blue-armour bonus id is what says 2.
;--------------------------------------------------------------
        org CHTARM_BASE
.proc cht_arm
        lda #200
        sta PSTATE+PS_ARMOR
        ldy #7                        ; the blue-armour bonus id -> armortype 2
        jmp pl_armset
.endp
    .if * > CHTARM_END+1
        ert 'cht_arm outgrew CHTARM_BASE..CHTARM_END (memory_map.inc)'
    .endif
        org rk_resume
