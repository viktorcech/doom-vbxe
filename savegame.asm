;==============================================================
; savegame.asm -- SAVE GAME / LOAD GAME (g_game.c G_DoSaveGame / G_DoLoadGame).
;--------------------------------------------------------------
; THE MODEL IS WOLF3D'S, and it is the only one that fits: a load RELOADS THE
; LEVEL and then overwrites the state a fresh level does not reproduce. So the
; slot does not have to describe the world -- the ATR already does -- it only
; has to carry what the player CHANGED.
;
; Where this port differs from wolf3d is that it does not pick FIELDS, it takes
; whole REGIONS (sg_tab). Enumerating every mutated byte of a DOOM level is how
; a save gets silently, subtly wrong months later; a region snapshot cannot miss
; one. The cost is disk, and disk is the one thing this port has spare.
;
; WHAT EACH REGION IS, and therefore what a save actually keeps:
;   $0F00 1 pg  the player page -- PSTATE (health/armour/4x ammo/weapons/keys),
;               PW_FLAGS + the powerup timers, wp_cur/wp_state (the gun in his
;               hands), THING_ALIVE (which items are already picked up),
;               pl_dead/pl_vh, the view size, hud_dirty/face
;   $7200 1 pg  MV_TAB -- lifts, floors and stairs that are still MOVING
;   $4000 12pg  the map's LOW region -- MAP_SECTORS, i.e. every floor and
;               ceiling height in the level. This is the "rozohraný level":
;               doors left open, lifts left down, stairs already built, plus
;               the per-sector light levels
;   $6000 3 pg  bank $01: DOOR_STATE/CURLO/CURHI/WAIT -- doors mid-swing and
;   $C000 16pg  the THINGS blob -- every thing's x/y, so monsters are where you
;               left them (ai_move writes the record at +0/+2)
;   $6400 6 pg  bank $01: TH_HPL/HPH (health), TH_STATE/TH_TICS (0 = alive, else
;               the DEATH-animation row and its tics -- this is what makes a
;               corpse still a corpse, in the right frame), + the blockmap pages
;   $7700 9 pg  bank $01: TH_WROW/WST/WTIC/DIR/MCNT/KIND/MODE/SEEN/RAD -- who is
;               chasing, in which walk state, facing where
;   $6300 1 pg  bank $01: TH_TARG -- who each monster is fighting (saved as
;               part of the $6300 run above), and $FF00 1 pg TH_THRS
; and the header sector carries what is scattered: the player's x/y/angle/eye,
; current_level, and mv_used (which one-shot W1 triggers have already fired).
;
; NOT KEPT, deliberately: a flipped SWITCH face (the seg's texture byte lives in
; the 14 KB seg table in Rapidus bank $03 -- far too much disk for a cosmetic
; byte; whatever the switch OPENED is kept, because sector heights are), and the
; phase of blinking lights / animated textures, which simply restart.
;
; SAVE/LOAD ARE IN-GAME ONLY (ESC). At the title there is no game to save and
; nothing to load INTO -- menu_boot's tail is `jmp load_level_c`, which would
; immediately re-stream level 0 over anything this restored.
;
; HOW IT RUNS. This is the SECOND overlay (memory_map.inc): the menu tail-jumps
; into it, so the two never coexist and neither has to make room for the other.
; A LOAD is two phases, because reloading the level streams THROUGH TEX_STAGE --
; which is this code:
;   phase 1 (sg_load)     read the header, take current_level from it, and jump
;                         to SG_RESUME, the one part of the overlay that lives
;                         above $13FF and therefore survives the load
;   SG_RESUME             reload the level exactly as exit_level does, then pull
;                         the overlay back in for
;   phase 2 (sg_restore)  the header's vars + every region, over the fresh level
;==============================================================

sg_amb = *                           ; the ambient PC (the map-slot staging block
                                     ;   savegame.asm is icl'd inside) -- put
                                     ;   back at the bottom of the file
        org MENU_RUN, SGOVL_STAGE    ; runs at $1000, LOADS at $C800, and
                                     ;   tools/split_menu_ovl.py lifts it out of
                                     ;   the XEX into menu.bin's second overlay
                                     ;   chunk. See menu.asm's header.

;--------------------------------------------------------------
; sg_head -- the overlay's bootstrap, and the FIRST bytes at MENU_RUN (mn_open
;   jumped straight here with the window still on this overlay's bank).
;--------------------------------------------------------------
.proc sg_head
        ldy #0
?p      lda MEMW+$100,y
        sta MENU_RUN+$100,y
        lda MEMW+$200,y
        sta MENU_RUN+$200,y
        lda MEMW+$300,y
        sta MENU_RUN+$300,y
        lda MEMW+$400,y
        sta MENU_RUN+$400,y
        iny
        bne ?p
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        cpx #SG_E_LOAD
        bne ?n1
        jmp sg_load
?n1     cpx #SG_E_REST
        beq ?rest
        cpx #SG_E_QUIT
        beq ?quit
        cpx #SG_E_SCAN
        beq ?scan
        jmp sg_save
?scan   jmp sg_scan
?rest   jmp sg_restore
?quit   jmp sg_quit
.endp

; --- the regions. (address, 256-byte pages, kind) ---------------------------
SGK_RAM  equ 0                       ; main RAM below $C000: SIO reads/writes it
                                     ;   where it lies, no staging at all
SGK_UROM equ 1                       ; under the OS ROM: SIOV *is* the ROM, so
                                     ;   every sector goes through SG_BUF with
                                     ;   the ROM banked out for the copy alone
SGK_EXT  equ 2                       ; Rapidus bank $01: same staging, with the
                                     ;   65816 long addressing read_ext uses

sg_tab
        dta a($0F00), 1,  SGK_RAM    ; the player page (PSTATE/weapon/items)
        dta a($7200), 1,  SGK_RAM    ; MV_TAB: movers still in flight
        dta a($4000), 12, SGK_RAM    ; the map's LOW region: SECTOR HEIGHTS
        dta a($C000), 16, SGK_UROM   ; the THINGS blob: every thing's position
        dta a($E400), 1,  SGK_UROM   ; mv_used, the WALKOVER TRIGGERS. It is in
                                     ;   the MVUSED block ($E400) under the OS
                                     ;   ROM, which check_triggers never minded
                                     ;   (it runs after rom_out) -- but sg_vars
                                     ;   reaches its entries with a plain
                                     ;   (zp_tmp),y while sg_begin holds the ROM
                                     ;   IN for SIOV, so it was reading the OS
                                     ;   ROM: a written .atr had 'c2 4c 5c e9 4c
                                     ;   17...' where the trigger bits belong.
                                     ;   SGK_UROM stages through SG_BUF with the
                                     ;   ROM banked out for the copy alone, which
                                     ;   is exactly what these bytes needed. It
                                     ;   also fixes a second, quieter bug: the
                                     ;   sg_vars entry said 12 bytes and MV_TRIGS
                                     ;   went 96 -> 192, so HALF the triggers had
                                     ;   stopped being saved at all.
        dta a($6000), 3,  SGK_EXT    ; the door arrays (DOOR_EXT: they left
                                     ;   $F000 under the ROM on 2026-08-18, so
                                     ;   this went SGK_UROM 2 pg -> EXT 3, the
                                     ;   12 x 48 = 576 B rounded up)
        dta a($6300), 7,  SGK_EXT    ; TARGETS + health + alive/dead + the death
                                     ;   frame. TH_TARG moved to $6300 on
                                     ;   2026-08-20 (it was colliding with
                                     ;   PJSLOT_EXT, see memory_map.inc), which
                                     ;   makes it contiguous with these -- six
                                     ;   pages became seven and the pair below
                                     ;   became one, so the table did not grow.
        dta a($7700), 9,  SGK_EXT    ; the chase state
        dta a($FF00), 1,  SGK_EXT    ; ...and the thresholds, the bank's last page
SG_TAB_N equ * - sg_tab
; The header's second magic byte doubles as the FORMAT version. Bump it whenever
; sg_tab's regions change: a slot written by an older build has the same sectors
; in a different order/stride and would restore as plausible-looking nonsense --
; here, doors at the old 32-entry stride, which can leave one shut for good.
; 'M' was the original; 'N' is the DOOR_EXT layout (2026-08-18); 'O' moved
; TH_TARG/TH_THRS off PJSLOT_EXT (2026-08-20); 'P' took mv_used out of sg_vars
; and made it a UROM region, because sg_vars was reading it through the OS ROM.
SG_MAGIC2 equ 'P'
SG_PAGES equ 1+1+12+16+1+3+7+9+1       ; -> SG_PAGES*2 + 1 sectors per slot

    .if SG_PAGES*2 + 1 > SAVE_SECTORS
        ert 'the save regions no longer fit SAVE_SECTORS (tools/make_atr_doom.py)'
    .endif

; --- the scattered bytes, as (address, length) runs. Header order IS the
;     on-disk format: append, never reorder. ---------------------------------
sg_vars
        dta a(zp_px), 2              ; where he is standing
        dta a(zp_py), 2
        dta a(zp_ang), 1             ; ... and which way he is looking
        dta a(zp_pz), 2              ; the eye
        dta a(pl_z), 2               ; ... and the feet
        dta a(pl_snap), 1
        dta a(ps_started), 1         ; so a load does not re-run the boot-time
                                     ;   PSTATE init over the restored one
        dta a(tex_flat), 1           ; the 'T' switch is part of the session
SG_VARS_N equ * - sg_vars

;--------------------------------------------------------------
; sg_sio -- sg_cnt sectors from ll_sec to/from (DBUFLO), command sg_cmd.
;   NOT diskio's read_sectors: that one TEES every sector into the Rapidus level
;   cache, and a save slot is not level data -- it would poison the cache and
;   make the next load_level serve a saved game as a map.
;   C set on any SIO error; ll_sec and DBUFLO are left past the last sector.
;--------------------------------------------------------------
sg_cmd  dta $52                      ; $52 'R' read / $50 'P' put (no verify)
sg_dir  dta $40                      ; $40 device->memory / $80 memory->device
sg_cnt  dta 0

.proc sg_sio
?lp     lda #$31                     ; D1:
        sta DDEVIC
        lda #$01
        sta DUNIT
        lda sg_cmd
        sta DCOMND
        lda sg_dir
        sta DSTATS
        lda #128
        sta DBYTLO
        lda #0
        sta DBYTHI
        lda #$0F
        sta DTIMLO
        lda ll_sec
        sta DAUX1
        lda ll_sec+1
        sta DAUX2
        jsr SIOV
        sty sio_status
        cpy #1
        bne ?err
        inc ll_sec
        bne ?bok
        inc ll_sec+1
?bok    lda DBUFLO
        clc
        adc #128
        sta DBUFLO
        bcc ?cok
        inc DBUFHI
?cok    dec sg_cnt
        bne ?lp
        clc
        rts
?err    sec
        rts
.endp

;--------------------------------------------------------------
; sg_read / sg_write -- point sg_cmd/sg_dir at the direction wanted.
;--------------------------------------------------------------
.proc sg_read
        lda #$52
        sta sg_cmd
        lda #$40
        sta sg_dir
        rts
.endp

.proc sg_write
        lda #$50
        sta sg_cmd
        lda #$80
        sta sg_dir
        rts
.endp

;--------------------------------------------------------------
; sg_slot_sec -- ll_sec = SAVE_SEC1 + sg_slot*SAVE_SECTORS (16-bit; the region
;   is past sector 27000, so both halves matter).
;--------------------------------------------------------------
.proc sg_slot_sec
        lda #0
        sta ll_sec
        sta ll_sec+1
        ldx sg_slot
        beq ?done
?add    clc                          ; six slots -- an add loop is smaller than
        lda ll_sec                   ;   a multiply and runs once per menu pick
        adc #<SAVE_SECTORS
        sta ll_sec
        lda ll_sec+1
        adc #>SAVE_SECTORS
        sta ll_sec+1
        dex
        bne ?add
?done   clc
        lda ll_sec
        adc #<SAVE_SEC1
        sta ll_sec
        lda ll_sec+1
        adc #>SAVE_SEC1
        sta ll_sec+1
        rts
.endp

;--------------------------------------------------------------
; sg_dbuf -- DBUFLO/HI = SG_BUF, sg_cnt = 1 (the header + every staged sector).
;--------------------------------------------------------------
.proc sg_dbuf
        lda #<SG_BUF
        sta DBUFLO
        lda #>SG_BUF
        sta DBUFHI
        lda #1
        sta sg_cnt
        rts
.endp

;--------------------------------------------------------------
; sg_vars_out / sg_vars_in -- the scattered bytes between their homes and
;   SG_BUF+3, in sg_vars order. One table, both directions.
;--------------------------------------------------------------
sg_vi   dta 0                        ; index into sg_vars
sg_vo   dta 0                        ; write cursor in SG_BUF

.proc sg_vars_out
        jsr sg_vsetup
?e      ldx sg_vi
        cpx #SG_VARS_N
        bcs ?done
        jsr sg_vptr                  ; zp_tmp -> the var, X = its length
        ldy #0
?b      lda (zp_tmp),y
        stx sg_vx
        ldx sg_vo
        sta SG_BUF+3,x
        inc sg_vo
        ldx sg_vx
        iny
        dex
        bne ?b
        jmp ?e
?done   rts
.endp

.proc sg_vars_in
        jsr sg_vsetup
?e      ldx sg_vi
        cpx #SG_VARS_N
        bcs ?done
        jsr sg_vptr
        ldy #0
?b      stx sg_vx
        ldx sg_vo
        lda SG_BUF+3,x
        inc sg_vo
        ldx sg_vx
        sta (zp_tmp),y
        iny
        dex
        bne ?b
        jmp ?e
?done   rts
.endp

sg_vx   dta 0

.proc sg_vsetup
        lda #0
        sta sg_vi
        sta sg_vo
        rts
.endp

;--------------------------------------------------------------
; sg_vptr -- zp_tmp = sg_vars[sg_vi] address, X = its length; sg_vi += 3.
;--------------------------------------------------------------
.proc sg_vptr
        ldx sg_vi
        lda sg_vars,x
        sta zp_tmp
        lda sg_vars+1,x
        sta zp_tmp+1
        lda sg_vars+2,x
        tay
        lda sg_vi
        clc
        adc #3
        sta sg_vi
        tya
        tax
        rts
.endp

;--------------------------------------------------------------
; sg_run -- every region in sg_tab, in the direction sg_cmd/sg_dir already
;   holds. ll_sec must sit on the slot's first REGION sector. C set on error.
;--------------------------------------------------------------
sg_ri   dta 0                        ; index into sg_tab
sg_src  dta a(0)                     ; this region's address
sg_pg   dta 0                        ; ... pages left
sg_kind dta 0

.proc sg_run
        lda #0
        sta sg_ri
?r      ldx sg_ri
        cpx #SG_TAB_N
        bcs ?done
        lda sg_tab,x
        sta sg_src
        lda sg_tab+1,x
        sta sg_src+1
        lda sg_tab+2,x
        sta sg_pg
        lda sg_tab+3,x
        sta sg_kind
        jsr sg_region
        bcs ?err
        lda sg_ri
        clc
        adc #4
        sta sg_ri
        jmp ?r
?done   clc
?err    rts
.endp

;--------------------------------------------------------------
; sg_region -- one sg_tab entry. SGK_RAM goes straight to/from the region (SIO
;   can address it); the other two go a sector at a time through SG_BUF.
;--------------------------------------------------------------
.proc sg_region
        lda sg_kind
        bne ?staged
        lda sg_src                   ; --- plain RAM: one SIO run over the lot
        sta DBUFLO
        lda sg_src+1
        sta DBUFHI
        lda sg_pg
        asl                          ; pages -> 128-byte sectors
        sta sg_cnt
        jmp sg_sio                   ; tail (C = its result)
?staged lda sg_pg                    ; --- staged: two sectors per page
        asl
        sta sg_pg                    ; sg_pg is now a SECTOR countdown
?s      lda sg_dir                   ; save? then fill SG_BUF first
        bpl ?rd
        jsr sg_gather
?rd     jsr sg_dbuf
        jsr sg_sio
        bcs ?err
        lda sg_dir
        bmi ?adv
        jsr sg_scatter               ; load: SG_BUF -> the region
?adv    clc                          ; source pointer += 128
        lda sg_src
        adc #128
        sta sg_src
        bcc ?nc
        inc sg_src+1
?nc     dec sg_pg
        bne ?s
        clc
?err    rts
.endp

;--------------------------------------------------------------
; sg_gather / sg_scatter -- 128 bytes between (sg_src) and SG_BUF, whichever
;   address space sg_kind says. The ROM has to go OUT to see RAM at $C000+, and
;   while it is out the interrupt vectors are RAM -- so mask both for the copy,
;   exactly as read_urom does. SIO is idle here, so nothing is missed.
;--------------------------------------------------------------
.proc sg_gather
        lda sg_kind
        cmp #SGK_EXT
        beq ?ext
        jsr sg_zpsrc
        jsr sg_rom_out
        ldy #127
?u      lda (zp_tsrc),y
        sta SG_BUF,y
        dey
        bpl ?u
        jmp sg_rom_in                ; tail
?ext    jsr sg_extptr
        ldy #127
?e      lda [zp_ptr],y               ; 65816 long: Rapidus bank $01
        sta SG_BUF,y
        dey
        bpl ?e
        rts
.endp

.proc sg_scatter
        lda sg_kind
        cmp #SGK_EXT
        beq ?ext
        jsr sg_zpsrc
        jsr sg_rom_out
        ldy #127
?u      lda SG_BUF,y
        sta (zp_tsrc),y
        dey
        bpl ?u
        jmp sg_rom_in                ; tail
?ext    jsr sg_extptr
        ldy #127
?e      lda SG_BUF,y
        sta [zp_ptr],y
        dey
        bpl ?e
        rts
.endp

;--------------------------------------------------------------
; sg_zpsrc -- zp_tsrc = sg_src. (indirect),y wants a ZERO PAGE pointer and
;   sg_src lives up here in the overlay; zp_tsrc is the loaders' own copy
;   pointer, and nothing is loading while a menu is up.
;--------------------------------------------------------------
.proc sg_zpsrc
        lda sg_src
        sta zp_tsrc
        lda sg_src+1
        sta zp_tsrc+1
        rts
.endp

;--------------------------------------------------------------
; sg_extptr -- zp_ptr = sg_src in Rapidus bank MAP_EXT_BANK (read_ext's own
;   addressing: banks $01+ ignore PORTB, so no ROM games are needed there).
;--------------------------------------------------------------
.proc sg_extptr
        lda sg_src
        sta zp_ptr
        lda sg_src+1
        sta zp_ptr+1
        lda #MAP_EXT_BANK
        sta zp_ptr+2
        rts
.endp

.proc sg_rom_out
        sei
        lda #0
        sta NMIEN
        jmp rom_out                  ; tail
.endp

.proc sg_rom_in
        jsr rom_in
        lda #$40
        sta NMIEN
        cli
        rts
.endp

;--------------------------------------------------------------
; sg_begin / sg_end -- SIOV lives in the OS ROM and waits on the serial IRQ, but
;   the frame loop this was called from runs with the ROM banked OUT and IRQs
;   masked. Same bracket exit_level puts round its loaders.
;--------------------------------------------------------------
.proc sg_begin
        jsr rom_in
        lda #$40
        sta NMIEN
        cli
        jmp snd_stop                 ; SIO takes POKEY over whole -- no voice may
                                     ;   be left running across the transfer
.endp

.proc sg_end
        sei
        jsr rom_out                  ; back to the frame loop's world...
        jsr snd_pokey                ; ...and POKEY back from SIO. THIS IS NOT
                                     ;   OPTIONAL: SIO takes the chip over whole
                                     ;   -- serial bits in AUDCTL, channels 3/4,
                                     ;   the lot -- and every other SIO window in
                                     ;   this engine ends with the same call
                                     ;   (exit_level -> snd_resume). Without it
                                     ;   the FIRST save came back to a POKEY that
                                     ;   was still SIO's, and the next menu's own
                                     ;   sfx_swtchn armed Timer-1 on top of it:
                                     ;   the second SAVE never happened.
                                     ;   snd_pokey, not snd_resume -- the latter
                                     ;   tail-calls init_level, which would throw
                                     ;   away the very state that was saved.
        sei                          ; snd_pokey ends with cli (it is written for
        rts                          ;   the loader path); the frame loop wants
.endp                                ;   its IRQs masked again

;--------------------------------------------------------------
; sg_scan -- what wolf3d's refresh_slot_labels does: read every slot's header
;   and write down what is in it, so the picker can say so. One sector per slot,
;   and only the first three bytes matter -- magic plus the level.
;   The picker is in the MENU overlay and the drive is in this one, so the two
;   pass through sg_lvl[] in permanent RAM and this entry hands control straight
;   back with MN_E_PICK.
;--------------------------------------------------------------
.proc sg_scan
        jsr sg_begin
        jsr sg_read
        lda #0
        sta sg_si
?s      lda sg_si
        sta sg_slot
        jsr sg_slot_sec
        jsr sg_dbuf
        jsr sg_sio
        lda #$FF                     ; unreadable or not a save -> EMPTY
        bcs ?put
        ldx SG_BUF+0
        cpx #'D'
        bne ?put
        ldx SG_BUF+1
        cpx #SG_MAGIC2
        bne ?put
        lda SG_BUF+2                 ; the level this slot holds
?put    ldx sg_si
        sta sg_lvl,x
        inc sg_si
        lda sg_si
        cmp #SAVE_SLOTS
        bcc ?s
        ldx mn_ing                   ; THE ONE ENTRY HERE THAT CAN RETURN TO A
        bne ?ing                     ;   ROM-IN WORLD (2026-08-13, the title
        jsr snd_pokey                ;   LOAD freeze). sg_begin/sg_end bracket
        jmp ?back                    ;   the IN-GAME frame loop, which runs with
?ing    jsr sg_end                   ;   the ROM banked OUT -- so sg_end's
?back   lda #BANK_EN | MENU_OBANK    ;   rom_out is a RESTORE there and a
        ldx #MN_E_PICK               ;   CHANGE at the title, where menu_boot
        jmp mn_open                  ;   still holds the ROM in for SIOV.
                                     ;   Two things died on that change: rom_out
                                     ;   also does clc/xce, so NMI moved to
                                     ;   $FFEA -- and urom_init, the only thing
                                     ;   that ever fills the RAM vectors, runs
                                     ;   in main AFTER menu_boot. NMIEN is $40
                                     ;   and SEI does not mask NMI, so the next
                                     ;   VBI fetched its handler out of the
                                     ;   virgin FF 00 under the ROM ($FFE4-$FFEF
                                     ;   is kept EMPTY on purpose, see
                                     ;   memory_map.inc ENEMY_END) and ran off
                                     ;   into $00FF -- the frozen garbage screen
                                     ;   (load2.png), inside mn_vsync, before
                                     ;   the picker ever drew. Had it survived
                                     ;   that, menu_boot's tail `jmp
                                     ;   load_level_c` would have called SIOV
                                     ;   with the ROM still banked out.
                                     ;   mn_ing is the right test HERE and only
                                     ;   here: a title LOAD fires deferred
                                     ;   (mn_pend), and by then sg_load and
                                     ;   sg_restore ARE in the frame loop's
                                     ;   world with mn_ing still 0 -- so the
                                     ;   gate must not go into sg_end itself.
                                     ;   All the title owes SIO is POKEY back
                                     ;   (tools/tests/_dbg_titleload.py).
.endp
sg_si   dta 0

;--------------------------------------------------------------
; sg_quit -- M_QuitResponse (m_menu.c:1080-1092), which is the only part of QUIT
;   DOOM this port can have: M_QuitDOOM itself just puts up the "are you sure"
;   message and there is no message system here to put it on.
;   What survives is the part people remember -- DOOM says goodbye with one of
;   eight monster/gore sounds picked by (gametic>>2)&7, waits for it, and only
;   then quits. quitsounds[], not quitsounds2[]: the second table is
;   `gamemode == commercial` and this ATR is episode 1. gametic is RTCLOK3 here,
;   the VBLANK counter this engine times everything else by -- the same
;   "whatever the clock happens to say" as id's.
;   I_WaitVBL(105) is the POKMSK spin: waiting until the mixer is actually empty
;   is the same intent and exactly as long as the sound really is.
;   It lives in THIS overlay, not the menu's, purely for room -- and it can,
;   because it never returns.
;--------------------------------------------------------------
sg_qsnd dta SFX_PLDETH, SFX_DMPAIN, SFX_POPAIN, SFX_SLOP
        dta SFX_TELEPT, SFX_POSIT1, SFX_POSIT3, SFX_SGTATK

.proc sg_quit
        jsr sg_qwait                 ; let the menu's select shot finish -- DOOM
                                     ;   has the y/n prompt in this gap, so its
                                     ;   two sounds never overlap either
        lda RTCLOK3
        lsr
        lsr
        and #7                       ; (gametic>>2) & 7
        tax
        lda sg_qsnd,x
        tax
        jsr snd_play
        jsr sg_qwait                 ; I_WaitVBL(105)
        jmp sg_bye                   ; ...and out. NOT `rom_in + jmp COLDSV`: that
                                     ;   hands the OS a machine nobody reset.
                                     ;   See sg_bye, up beside sg_go2.
.endp

;--------------------------------------------------------------
; sg_qwait -- spin until the mixer is empty. snd_arm sets POKMSK bit0 when a
;   sample starts and snd_disarm zeroes the byte when the last voice ends, so
;   bit0 IS "something is playing".
;--------------------------------------------------------------
.proc sg_qwait
?w      lda POKMSK_R
        lsr
        bcc ?done
        lda RTCLOK3                  ; one frame
?v      cmp RTCLOK3
        beq ?v
        jmp ?w
?done   jmp snd_stop                 ; ... and the channels with it
.endp

;--------------------------------------------------------------
; sg_save -- G_DoSaveGame. Header sector, then every region. A = 0 ok / $FF SIO
;   error; DOOM closes the menu either way (M_DoSave -> M_ClearMenu).
;--------------------------------------------------------------
.proc sg_save
        jsr sg_begin
        ldx #127                     ; a clean header: unused bytes read as 0
        lda #0
?cl     sta SG_BUF,x
        dex
        bpl ?cl
        lda #'D'
        sta SG_BUF+0
        lda #SG_MAGIC2
        sta SG_BUF+1
        lda current_level
        sta SG_BUF+2
        jsr sg_vars_out
        jsr sg_slot_sec
        jsr sg_write
        jsr sg_dbuf
        jsr sg_sio                   ; ... the header
        bcs ?err
        jsr sg_run                   ; ... and the world
        bcs ?err
        jsr sg_end
        lda #0
        rts
?err    jsr sg_end
        lda #$FF
        rts
.endp

;--------------------------------------------------------------
; sg_load -- G_DoLoadGame, phase 1: the header alone, then hand over to
;   SG_RESUME, which reloads the level and calls phase 2 back in.
;   A bad magic (an empty slot) returns $FF with the game untouched.
;--------------------------------------------------------------
.proc sg_load
        jsr sg_begin
        jsr sg_slot_sec
        jsr sg_read
        jsr sg_dbuf
        jsr sg_sio
        bcs ?bad
        lda SG_BUF+0
        cmp #'D'
        bne ?bad
        lda SG_BUF+1
        cmp #SG_MAGIC2
        bne ?bad
        lda SG_BUF+2
        sta current_level
        jmp SG_RESUME                ; (the ROM is IN and IRQs are on, which is
                                     ;  exactly what the level loaders want)
?bad    jsr sg_end
        lda #$FF
        rts
.endp

;--------------------------------------------------------------
; sg_restore -- phase 2: the fresh level is up; put the saved world back over
;   it. Called with the ROM OUT (pl_reload's tail), so it brackets its own SIO.
;--------------------------------------------------------------
.proc sg_restore
        jsr sg_begin
        jsr sg_slot_sec
        jsr sg_read
        jsr sg_dbuf
        jsr sg_sio                   ; the header again -- phase 1 only wanted
        bcs ?err                     ;   the level out of it, and load_things
        jsr sg_vars_in               ;   has reset everything since
        jsr sg_run
        bcs ?err
        jsr sg_end
        lda #$FF                     ; the weapon in his hands changed under
        sta wp_wldd                  ;   wp_wload's cache...
        jsr blitter_wait             ; ...and STREAM IT NOW. Invalidating alone
        lda wp_cur                   ;   was not enough: wp_init already called
        jsr wp_wload                 ;   wp_wload during the level load above,
                                     ;   with the weapon the player was holding
                                     ;   BEFORE the load, and nothing calls it
                                     ;   again until a weapon SWITCH. So the slot
                                     ;   kept that weapon's pixels while wp_cur
                                     ;   became the saved one, draw_weapon
                                     ;   indexed a different frame layout into
                                     ;   them, and the psprite came out as noise
                                     ;   until you pressed a number (load.png,
                                     ;   2026-08-09: save on E1M5, finish the
                                     ;   level, load).
        jsr vw_apply                 ; THE VIEW WINDOW, and it is not cosmetic.
                                     ;   solid_arr is at $1000 and ytopc_arr at
                                     ;   $1100 -- i.e. UNDER THIS OVERLAY. Every
                                     ;   byte of them is this code while the
                                     ;   restore runs. render_world re-opens only
                                     ;   [vw_x0,vw_xend) and trusts everything
                                     ;   else to be solid already; vw_apply is
                                     ;   the ONLY thing that marks the rest, and
                                     ;   after a load nothing called it, so the
                                     ;   first frame walked the BSP against a
                                     ;   solid_arr full of overlay bytes and hung
                                     ;   in calc_nodeptr.
                                     ;   It also rebuilds vw_x0..vw_t from
                                     ;   vw_size ($A04D), which sg_tab does NOT
                                     ;   restore -- so the eight bytes that came
                                     ;   off the disk stop disagreeing with the
                                     ;   size the engine actually thinks it has.
        jsr blk_fill                 ; the things moved: rebuild the blockmap
        lda #2
        sta hud_dirty                ; ... and repaint the bar in both buffers
        lda #0
        rts
?err    jsr sg_end
        lda #$FF
        rts
.endp

    .if * > SG_BUF
        ert 'savegame.asm ran into SG_BUF -- it must fit $1000-$13FF'
    .endif

;==============================================================
; SG_RESUME -- the load's middle phase, and the only code here that runs ACROSS
;   a level load. It lives above $13FF on purpose: load_level_c and every asset
;   loader stream through TEX_STAGE ($1000-$13FF), i.e. straight over the rest
;   of this overlay. Everything it needs is resident engine code.
;==============================================================
    .if * > SG_RESUME
        ert 'savegame.asm ran past SG_RESUME'
    .endif
        :[SG_RESUME-*] dta 0         ; PAD, not a second `org`: an org would start
                                     ;   a second XEX block at $1480 and
                                     ;   split_menu_ovl.py lifts exactly one per
                                     ;   overlay (the leftover landed in
                                     ;   bsp_stack and check_xex caught it).
                                     ;   The padding is SG_BUF's 128 bytes plus
                                     ;   slack -- a buffer, so zeros are right.
.proc sg_go2                         ; (SG_RESUME is the equ; MADS labels are
                                     ;  case-insensitive, so the proc cannot
                                     ;  carry the same name)
        jsr sg_fresh                 ; drop this level's SDRAM-resident bit, THEN
                                     ;   the level, exactly as a normal level
                                     ;   change loads it (NMIEN + cli, the map,
                                     ;   textures, sprites, things, then sei +
                                     ;   rom_out and init_level)
        lda #BANK_EN | SGOVL_BANK    ; ... and pull the overlay back in for the
        ldx #SG_E_REST               ;   regions. mn_open re-copies this page
        jmp mn_open                  ;   too, but we have already left it.
.endp

;--------------------------------------------------------------
; sg_bye -- I_Quit: put the machine back and RE-BOOT THE ATR OURSELVES.
;
;   The obvious version -- `jsr rom_in` + `jmp COLDSV` -- is what
;   wolfenstein3d-vbxe does (src/menu.asm) and it never worked here. COLDSV is a
;   SOFTWARE entry into the OS, so the Atari's RESET line is never pulled and
;   nothing on the board is reset; but that is not what killed it. The OS has a
;   gate in front of its disk boot (_pomocne/A800-OS-XL-Rev2-main, PRS):
;
;       LDA NGFLAG      ;memory status
;       BNE PRS21       ;if memory good
;       LDA PORTB
;       AND #$7F        ;enable self-test ROM
;       STA PORTB
;       JMP EMS         ;execute memory self-test
;
;   NGFLAG is cleared by the power-up RAM walk (PRS3/PRS4) and by the ROM
;   checksum (PRS6). When it is, the OS banks in the self-test and scans memory
;   forever -- and that is the ONLY path in the whole kernel that produces what
;   was reported: a black screen with a live OS behind it, the keyclick still
;   working, RETURN doing nothing, identical after QUIT and after the RESET key,
;   every single time. The boot is never reached, so the game never comes back.
;
;   So do not ask the OS. The boot sectors ARE this game's loader -- boot.asm's
;   boot_init sits at BLDADR+6 and redoes everything from the Rapidus MCR down --
;   and reading three sectors is something this overlay already does for save
;   slots. Nothing is borrowed from the OS but SIOV, which is why the ROM, the
;   OS VBI and IRQs all have to go back on first.
;
;   What still has to be undone by hand, and why:
;     VBXE      a DEVICE: no software entry into the OS reaches it (alt-src
;               Altirra/source/vbxe.cpp, ATVBXEEmulator::WarmReset), so the XDL
;               would keep painting over the loader. Writing 0 to VIDEO_CONTROL
;               is the documented off switch (_pomocne/vbxe/vbxe.txt:175).
;     ANTIC     screen DMA off, the same open as boot_init and
;               _pomocne/games/combat.s.
;     the 65816 out of native mode, BEFORE PORTB puts the ROM back over
;               $FFEA/$FFEE -- the same order rom_in uses. boot.asm runs as a
;               6502 until it enables the 65816 itself.
;     PORTB     $FF, as a real XL reset leaves it (alt-src simulator.cpp,
;               InternalWarmReset -> SetBankRegister(0xFF)); rom_in only ever
;               ORed bit 0 in and left the other seven wherever the game had
;               them. The Rapidus MCR needs nothing: boot_init read-modify-writes
;               it on the way through.
;   POKEY needs nothing either -- sg_qwait tail-calls snd_stop, which falls into
;   snd_disarm and zeroes POKMSK and IRQEN before we ever get here.
;
;   Verified end to end in tools/tests/_dbg_reboot.py: sg_quit -> sg_bye -> the
;   loader at $0706 -> main, the same halt tools/check_boot.py calls a good boot.
;
;   It lives up here with sg_go2 because the $1000-$13FF half is eight bytes from
;   full and this end of the overlay window is empty.
;--------------------------------------------------------------
BOOT_RUN equ $0700                   ; the ATR boot loader's home (boot.asm: the
                                     ;   loader is $0700..$082D and boot_init
                                     ;   MUST sit at BLDADR+6 = $0706)
.proc sg_bye
        sei
        cld
        jsr blitter_wait             ; the blitter still owns VRAM until it stops
        lda #0
        sta NMIEN                    ; NMI off across the handover
        sta VBXE_VCTL                ; --- VBXE: XDL off, so nothing garbles the
        sta VBXE_MEMAC_CTL           ;     screen while the loader streams. It is
        sta VBXE_MEMAC_B             ;     a DEVICE -- no software entry into the
        sta VBXE_BANK_SEL            ;     OS ever reaches it (vbxe.cpp WarmReset)
        sta DMACTL                   ; --- ANTIC: screen DMA off, as boot_init
                                     ;     does it (and _pomocne/games/combat.s)
        sec                          ; --- CPU: out of 65816 native mode. boot.asm
        xce                          ;     runs as a 6502 until it turns the
                                     ;     65816 on itself, and this must happen
                                     ;     BEFORE the ROM covers $FFEA/$FFEE --
                                     ;     the same order rom_in uses.
        lda #$FF
        sta PORTB                    ; --- PIA/MMU: SetBankRegister($FF) as a real
                                     ;     XL reset does (alt-src simulator.cpp
                                     ;     InternalWarmReset). SIOV lives in that
                                     ;     ROM, so it has to be in either way.
        lda #$40
        sta NMIEN                    ; --- and SIOV's world back: the OS VBI on
        cli                          ;     and IRQs enabled, because SIOV waits on
                                     ;     the serial IRQ (diskio.asm's header).

        ; --- RE-BOOT THE ATR OURSELVES, instead of asking the OS to do it -----
        ; This is the fix. `jmp COLDSV` looked right and is what
        ; wolfenstein3d-vbxe does, but the OS cold start has a gate in front of
        ; the disk boot that this machine does not get through
        ; (_pomocne/A800-OS-XL-Rev2-main, PRS/PRS6):
        ;       LDA NGFLAG      ;memory status
        ;       BNE PRS21       ;if memory good
        ;       ... AND #$7F -> enable self-test ROM ...
        ;       JMP EMS         ;execute memory self-test
        ; NGFLAG is cleared by the power-up RAM walk (PRS3/PRS4) and by the ROM
        ; checksum (PRS6), and when it is, the OS never reaches the boot at all:
        ; it banks in the self-test and scans memory forever. That is exactly the
        ; report -- a black screen with a live keyboard, RETURN doing nothing, the
        ; same after QUIT and after RESET, every single time.
        ; So do not go through the OS. The boot sectors ARE the game's loader
        ; (boot.asm: boot_init sits at BLDADR+6 and re-does everything from the
        ; Rapidus MCR down), and reading three sectors is something this overlay
        ; already knows how to do. Nothing but SIOV is borrowed.
        lda #1                       ; the ATR's own boot sectors, 1..3
        sta ll_sec
        lda #0
        sta ll_sec+1
        lda #<BOOT_RUN
        sta DBUFLO
        lda #>BOOT_RUN
        sta DBUFHI
        lda #3
        sta sg_cnt
        jsr sg_read
        jsr sg_sio
        bcs ?fallback                ; drive gone? then the OS is still a better
        jmp BOOT_RUN+6               ;   answer than sitting here
?fallback
        jmp COLDSV
.endp
    .if * > MENU_RUN_END+1
        ert 'sg_go2/sg_bye outgrew the overlay window (memory_map.inc)'
    .endif
        org sg_amb                   ; ... and back to the staging block
