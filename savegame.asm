;--------------------------------------------------------------
; savegame.asm -- SAVE / LOAD GAME: a load reloads the level, then overwrites the
;   state REGIONS (sg_tab) a fresh level does not reproduce.
;--------------------------------------------------------------
sg_amb = *                           ; the ambient PC (the map-slot staging block
                                     ;   savegame.asm is icl'd inside) -- put
                                     ;   back at the bottom of the file
        org MENU_RUN, SGOVL_STAGE    ; runs at $1000, LOADS at $C800, and
                                     ;   tools/split_menu_ovl.py lifts it out of
                                     ;   the XEX into menu.bin's second overlay
                                     ;   chunk.

;--------------------------------------------------------------
; sg_head -- the overlay's bootstrap, and the FIRST bytes at MENU_RUN (mn_open
;   jumped straight here with the window still on this overlay's bank).
;--------------------------------------------------------------
.proc sg_head
        ldy #0
                                      ; DRAC_PLAN 3b: 16 KB window
SGOVL_WIN       equ MEMW16+[[SGOVL_BANK&3]<<12]
?p      lda SGOVL_WIN+$100,y
        sta MENU_RUN+$100,y
        lda SGOVL_WIN+$200,y
        sta MENU_RUN+$200,y
        lda SGOVL_WIN+$300,y
        sta MENU_RUN+$300,y
        lda SGOVL_WIN+$400,y
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
?quit   jmp quit_doom
.endp

; --- the regions. (address, 256-byte pages, kind) ---------------------------
SGK_RAM  equ 0                       ; main RAM below $C000: SIO reads/writes it
                                     ;   where it lies, no staging at all
SGK_UROM equ 1                       ; under the OS ROM: SIOV *is* the ROM, so
                                     ;   every sector goes through SG_BUF with
                                     ;   the ROM banked out for the copy alone
SGK_EXT  equ 2                       ; Rapidus bank $01: same staging, with the
                                     ;   65816 long addressing read_ext uses
SGK_AMB  equ 3                       ; the automap's SEEN marks (AMSEEN, bank $03,
                                     ;   r_segs.c ML_MAPPED) as ONE BIT a linedef: ...
; The LOW region stops at the end of MAP_TEXADDRHI: the header, MAP_SECTORS and
; the three texture ADDRESS tables (update_scroll moves them) are below it; past
; it (MAP_TEXWMASK..MAP_YVAL) nothing in the engine writes a byte -- the level
; load lays those tables down again. That is 8 pages instead of 12 today, and it
; is what pays for the bitmap without growing SAVE_SECTORS.
SG_LOWPG equ [[MAP_TEXWMASK+255]/256]-[MAP_LOAD/256]
    .if MAP_SECTORS >= MAP_TEXADDRLO
        ert 'map_syms.inc reordered the LOW tables -- recheck SG_LOWPG'
    .endif
    .if MAP_TEXADDRHI >= MAP_TEXWMASK
        ert 'map_syms.inc reordered the LOW tables -- recheck SG_LOWPG'
    .endif

sg_tab
        dta a($0F00), 1,  SGK_RAM    ; the player page (PSTATE/weapon/items)
        dta a($7200), 1,  SGK_RAM    ; MV_TAB: movers still in flight
        dta a($4000), SG_LOWPG, SGK_RAM ; the map's LOW region: SECTOR HEIGHTS
        dta a($C000), 16, SGK_UROM   ; the THINGS blob: every thing's position
        dta a($E400), 1,  SGK_UROM   ; mv_used, the WALKOVER TRIGGERS. It is in
                                     ;   the MVUSED block ($E400) under the OS ...
        dta a($6000), 3,  SGK_EXT    ; the door arrays (DOOR_EXT: they left
                                     ;   $F000 under the ROM on 2026-08-18, so ...
        dta a($6300), 7,  SGK_EXT    ; TARGETS + health + alive/dead + the death
                                     ;   frame.
        dta a($7700), 9,  SGK_EXT    ; the chase state
        dta a($FF00), 1,  SGK_EXT    ; ...and the thresholds, the bank's last page
        dta a(0), 1, SGK_AMB         ; the automap bitmap: sg_src = its byte offset
SG_TAB_N equ * - sg_tab
; The header's second magic byte doubles as the FORMAT version. Bump it whenever
; sg_tab's regions change: a slot written by an older build has the same sectors
; in a different order/stride and would restore as plausible-looking nonsense --
; here, doors at the old 32-entry stride, which can leave one shut for good.
; 'M' was the original; 'N' is the DOOR_EXT layout (2026-08-18); 'O' moved
; TH_TARG/TH_THRS off PJSLOT_EXT (2026-08-20); 'P' took mv_used out of sg_vars
; and made it a UROM region, because sg_vars was reading it through the OS ROM.
SG_MAGIC2 equ 'Q'                    ; 'Q' trimmed LOW to SG_LOWPG and appended the
SG_PAGES equ 1+1+SG_LOWPG+16+1+3+7+9+1+1   ;   automap bitmap (2026-09-15)

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
        stz DBYTHI
        lda #$0F
        sta DTIMLO
        lda ll_sec
        sta DAUX1
        lda ll_sec+1
        sta DAUX2
        jsr siov_r                   ; DRAC_PLAN 4a: SIOV with the ROM banked in
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

                                      ; 2026-09-22 (drac030 inline): inlined at its one caller

;--------------------------------------------------------------
; sg_slot_sec -- ll_sec = SAVE_SEC1 + sg_slot*SAVE_SECTORS (16-bit; the region
;   is past sector 27000, so both halves matter).
;--------------------------------------------------------------
.proc sg_slot_sec
        stz ll_sec
        stz ll_sec+1
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
                                      ; 2026-09-22 (drac030 inline): sg_vsetup, its proc dropped (SG_BUF)
        stz sg_vi
        stz sg_vo
?e      ldx sg_vi
        cpx #SG_VARS_N
        bcs ?done
        jsr sg_vptr                  ; zp_tmp -> the var, X = its length
                                      ; 2026-09-23: X = the SG_BUF cursor for the whole
        stx sg_vx                    ;   var, Y the source, the count in memory -- no
        ldx sg_vo                    ;   X swap and no inc sg_vo per byte
        ldy #0
?b      lda (zp_tmp),y
        sta SG_BUF+3,x
        inx
        iny
        dec sg_vx
        bne ?b
        stx sg_vo
        bra ?e
?done   rts
.endp

.proc sg_vars_in
                                      ; 2026-09-22 (drac030 inline): sg_vsetup, its proc dropped (SG_BUF)
        stz sg_vi
        stz sg_vo
?e      ldx sg_vi
        cpx #SG_VARS_N
        bcs ?done
        jsr sg_vptr
                                      ; 2026-09-23: as sg_vars_out -- X the SG_BUF cursor,
        stx sg_vx                    ;   Y the destination, the count in memory
        ldx sg_vo
        ldy #0
?b      lda SG_BUF+3,x
        sta (zp_tmp),y
        inx
        iny
        dec sg_vx
        bne ?b
        stx sg_vo
        bra ?e
?done   rts
.endp

sg_vx   dta 0

                                      ; 2026-09-22 (drac030 inline): inlined at both callers

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
                                      ; 2026-09-23: X IS sg_vi (the ldx above)
        txa
        clc
        adc #3
        sta sg_vi
        tyx
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
        stz sg_ri
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
        ;clc
        adc #4
        sta sg_ri
        bra ?r
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
        bcs ?am                      ; SGK_AMB (> SGK_EXT): the automap bitmap
        jsr sg_zpsrc
        jsr sg_rom_out
        ldy #127
?u      lda (zp_tsrc),y
        sta SG_BUF,y
        dey
        bpl ?u
                                      ; 2026-09-22 (drac030 inline): sg_rom_in, minus its no-op
        lda #$40                     ;   jsr rom_in_t
        sta NMIEN
        cli
        rts
?ext    jsr sg_extptr
        ldy #127
?e      lda [zp_ptr],y               ; 65816 long: Rapidus bank $01
        sta SG_BUF,y
        dey
        bpl ?e
        rts
?am     jsl B1CODE_BASE+sg_amout     ; resident bank-$01 code (automap.asm): this
        rts                          ;   overlay had 20 bytes left before SG_BUF
.endp

.proc sg_scatter
        lda sg_kind
        cmp #SGK_EXT
        beq ?ext
        bcs ?am                      ; SGK_AMB: the automap bitmap
        jsr sg_zpsrc
        jsr sg_rom_out
        ldy #127
?u      lda SG_BUF,y
        sta (zp_tsrc),y
        dey
        bpl ?u
                                      ; 2026-09-22 (drac030 inline): sg_rom_in, minus its no-op
        lda #$40                     ;   jsr rom_in_t
        sta NMIEN
        cli
        rts
?ext    jsr sg_extptr
        ldy #127
?e      lda SG_BUF,y
        sta [zp_ptr],y
        dey
        bpl ?e
        rts
?am     jsl B1CODE_BASE+sg_amin
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
        stz NMIEN
        jmp rom_out_t ; tail
.endp

                                      ; 2026-09-22 (drac030 inline): inlined at both callers

;--------------------------------------------------------------
; sg_begin / sg_end -- SIOV lives in the OS ROM and waits on the serial IRQ, but
;   the frame loop this was called from runs with the ROM banked OUT and IRQs
;   masked. Same bracket exit_level puts round its loaders.
;--------------------------------------------------------------
.proc sg_begin
                                      ; 2026-09-22 (drac030 inline): rom_in is only an rts (DRAC_PLAN 4a): so is rom_in_t
        lda #$40
        sta NMIEN
        cli
        jmp snd_stop                 ; SIO takes POKEY over whole -- no voice may
                                     ;   be left running across the transfer
.endp

.proc sg_end
        sei
        jsr rom_out_t ; back to the frame loop's world...
        jsr snd_pokey_t ; ...and POKEY back from SIO. THIS IS NOT
                                     ;   OPTIONAL: SIO takes the chip over whole ...
        sei                          ; snd_pokey ends with cli (it is written for
        rts                          ;   the loader path); the frame loop wants
.endp                                ;   its IRQs masked again

;--------------------------------------------------------------
; sg_scan -- read every slot's header
;   and write down what is in it, so the picker can say so. One sector per slot,
;   and only the first three bytes matter -- magic plus the level.
;--------------------------------------------------------------
.proc sg_scan
        jsr sg_begin
        jsr sg_read
        stz sg_si
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
        jsr snd_pokey_t ;   LOAD freeze). sg_begin/sg_end bracket
        bra ?back                    ;   the IN-GAME frame loop, which runs with
?ing    jsr sg_end                   ;   the ROM banked OUT -- so sg_end's
?back   lda #BANK_EN | MENU_OBANK    ;   rom_out is a RESTORE there and a
        ldx #MN_E_PICK               ;   CHANGE at the title, where menu_boot
        jmp mn_open                  ;   still holds the ROM in for SIOV.
.endp
sg_si   dta 0

        icl 'quit.asm'               ; QUIT DOOM: it lives in this overlay for room

;--------------------------------------------------------------
; sg_save -- G_DoSaveGame. Header sector, then every region. A = 0 ok / $FF SIO
;   error; DOOM closes the menu either way (M_DoSave -> M_ClearMenu).
;--------------------------------------------------------------
.proc sg_save
        jsr sg_begin
        ldx #127                     ; a clean header: unused bytes read as 0
                                      ; 2026-09-23: stz abs,x -- A is reloaded right after
?cl     stz SG_BUF,x                 ;   the loop (lda #'D')
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
                                      ; 2026-09-22 (drac030 inline): sg_write, its proc dropped (SG_BUF)
        lda #$50
        sta sg_cmd
        lda #$80
        sta sg_dir
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
        jsr blitter_wait_t ; ...and STREAM IT NOW. Invalidating alone
        lda wp_cur                   ;   was not enough: wp_init already called
        jsr wp_wload_t                 ;   wp_wload during the level load above,
                                     ;   with the weapon the player was holding
                                     ;   BEFORE the load, and nothing calls it
                                     ;   again until a weapon SWITCH.
        jsr vw_apply_t                 ; THE VIEW WINDOW, and it is not cosmetic.
        jsr blk_fill_t                 ; the things moved: rebuild the blockmap
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
                                     ;   a second XEX block at $1480 and ...
.proc sg_go2                         ; (SG_RESUME is the equ; MADS labels are
                                     ;  case-insensitive, so the proc cannot
                                     ;  carry the same name)
        jsr sg_fresh_t ; drop this level's SDRAM-resident bit, THEN
                                     ;   the level, exactly as a normal level ...
        lda #BANK_EN | SGOVL_BANK    ; ... and pull the overlay back in for the
        ldx #SG_E_REST               ;   regions. mn_open re-copies this page
        jmp mn_open                  ;   too, but we have already left it.
.endp

        icl 'quit_boot.asm'          ; ... and its reboot
    .if * > MENU_RUN_END+1
        ert 'sg_go2/quit_boot outgrew the overlay window (memory_map.inc)'
    .endif
        org sg_amb                   ; ... and back to the staging block
