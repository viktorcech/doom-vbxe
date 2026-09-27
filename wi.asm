; wi.asm -- the INTERMISSION (wi_stuff.c) and the melt (f_wipe.c), episode 1.
;   Stage 1 runs at MENU_RUN, stage 2 in the map slot; the melt is stage 1's
;   because the second one runs after exit_level has reloaded the map.
;   Stats are derived from THING_ALIVE / TH_STATE / MAP_SECTORS, not counted.

WI_TICRATE  equ 35
WI_TICQ8    equ 179                  ;   numbers mean. 35/50 in Q8 = 179
WI_SNLDELAY equ 4                    ; SHOWNEXTLOCDELAY, seconds
WI_NOSTATE  equ 10                   ; WI_initNoState's cnt
WI_ST_DONE  equ 1
WI_FLDW     equ 26
WI_TFLDW    equ 34
WI_FLDH     equ 14
WI_BIAS     equ 16

;==============================================================
; PART 1 -- the three RESIDENT stubs. Everything else here is overlay. These
;==============================================================
wi_resume = *

;--------------------------------------------------------------
; wi_tick -- leveltime. update_pz's `jsr update_damage` points here instead, so
;--------------------------------------------------------------
        org WITICK_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wi_tick
        lda wi_time
        clc
        adc dt_vbl
        sta wi_time
        bcc ?nc
        inc wi_time+1
?nc
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>wi_secr              ;   next byte of this segment -- fall through
.endp
        .endseg
    .if * > WITICK_END+1
        ert 'wi_tick outgrew WITICK_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; wi_secr -- p_spec.c P_PlayerInSpecialSector's `case 9: SECRET SECTOR`, then
;--------------------------------------------------------------
        org WISECR_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wi_secr
        ldy #7
        lda (zp_ptr),y               ;   b4 SECRET (pack_map.py)
        bit #$10                     ; already clear (the usual case): nothing to
        beq ?out                     ;   write, and no and/cmp round trip to see it
        and #$EF
        sta (zp_ptr),y
?out    jmp update_damage
.endp
        .endseg
    .if * > WISECR_END+1
        ert 'wi_secr outgrew WISECR_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; wi_exit -- the frame loop's EXIT_REQ tail. main used to `jsr exit_level`
;--------------------------------------------------------------
        org WIEXIT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wi_exit
        ldx EXIT_REQ
        dex
        lda #BANK_EN | WIOVL_BANK
        jsl mn_open_w0 ; ...which lands in wi_head below
        rts                          ; DRAC_PLAN 4b (xbank_fix.py)
.endp
        .endseg
    .if * > WIEXIT_END+1
        ert 'wi_exit outgrew WIEXIT_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; wi_newlvl -- G_DoLoadLevel's `leveltime = 0`, in front of load_things: both
;--------------------------------------------------------------
        org WINEW_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc wi_newlvl
        stz wi_time
        stz wi_time+1
        jmp load_things
.endp
        .endseg
    .if * > WINEW_END+1
        ert 'wi_newlvl outgrew WINEW_BASE..END (memory_map.inc)'
    .endif
        org wi_resume

;==============================================================
; PART 2 -- STAGE 1, the bootstrap, at MENU_RUN ($1000-$14FF). Parked in the
;==============================================================
        org MENU_RUN, WIOVL_STAGE

;--------------------------------------------------------------
; wi_head -- the FIRST bytes at MENU_RUN, so mn_open's `jmp MENU_RUN` lands
;--------------------------------------------------------------
.proc wi_head
        ldy #0
                                      ; DRAC_PLAN 3b: 16 KB window
WIOVL_WIN       equ MEMW16+[[WIOVL_BANK&3]<<12]
WI2_WIN         equ MEMW16+[[WI2_BANK&3]<<12]    ; stage 2's chunk in the window
    .if [>WI2_WIN] + WI2_PAGES > 255
        ert 'wi_head: >WI2_WIN + page carries -- put the clc back'
    .endif
?p      lda WIOVL_WIN+$100,y
        sta MENU_RUN+$100,y
        lda WIOVL_WIN+$200,y
        sta MENU_RUN+$200,y
        lda WIOVL_WIN+$300,y
        sta MENU_RUN+$300,y
        lda WIOVL_WIN+$400,y
        sta MENU_RUN+$400,y
        iny
        bne ?p
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        cpx #WI_E_MELT
        bne ?inter
        jmp wi_melt2
?inter  jsr wi_pre
        lda #BANK_EN | WI2_BANK
        sta VBXE_BANK_SEL
                                      ; 2026-09-23: pages in any order (no overlap):
        ldx #WI2_PAGES-1             ;   count down, dex/bpl, no cpx
?s2     txa                          ;   inside WI2_PAGES and the slot
        clc
        adc #>WI2_WIN                ; 2026-09-24: WHERE the chunk sits in the 16 KB
        sta ?src+2                   ;   window, (WI2_BANK&3)*$1000 -- it was MEMW,
        adc #<[[>WI2_RUN]-[>WI2_WIN]] ;   right only while WI2_BANK&3 was 2 (the
        sta ?dst+2                   ;   crash when the run moved to $51). >WI2_WIN+X
        ldy #0                       ;   cannot carry, so the second add rides C=0
?src    lda WI2_WIN,y
?dst    sta WI2_RUN,y
        iny
        bne ?src
        dex
        bpl ?s2
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        jmp WI2_RUN
.endp

;--------------------------------------------------------------
; wi_pre -- the reads that have to happen while the map slot is still a MAP.
;--------------------------------------------------------------
.proc wi_pre
        lda #MUS_INTER               ; wi_stuff.c:1514 S_ChangeMusic(mus_inter):
        jsr mus_reset_t ;   the stats screen gets its own song, and
                                     ;   mus_play loops it at the $FF marker for
                                     ;   as long as the screen is up.
        lda MAP_HNSECR
        sta wi_maxsecr
        sta wi_secret                ; ...and count DOWN from it
        lda #<MAP_SECTORS
        sta sp_ptr
        lda #>MAP_SECTORS
        sta sp_ptr+1
        ldx MAP_HNSEC
        beq ?next
                                      ; 2026-09-23: Y walks the record offset (7, 15,
        ldy #7                       ;   ...), the page bumps on its carry: the same
?slp    lda (sp_ptr),y               ;   base + 8k + 7 addresses, no pointer add in RAM
        and #$10                     ; still SET = never walked into
        beq ?sn
        dec wi_secret
?sn     tya
        clc
        adc #8
        tay
        bcc ?sc
        inc sp_ptr+1
?sc     dex
        bne ?slp
?next   ldx MAP_HNEXT
        cpx #NUM_LEVELS
        bcc ?ok
        ldx #0
?ok     stx wi_next
        rts
.endp

;--------------------------------------------------------------
; THE SHARED STATS live in STAGE 1's RAM, not stage 2's, and that is forced:
;--------------------------------------------------------------
wi_val
wi_kills    dta 0
wi_items    dta 0
wi_secret   dta 0
wi_max
wi_maxkills dta 0
wi_maxitems dta 0
wi_maxsecr  dta 0
wi_next     dta 0

;==============================================================
; THE MELT -- f_wipe.c wipe_doMelt (:172), the effect DOOM runs on every
;==============================================================
;--------------------------------------------------------------
; wi_tic -- wait for the next DOOM tic. One VBLANK at a time (the menu's own
;--------------------------------------------------------------
.proc wi_tic
?v      lda RTCLOK3
?w      cmp RTCLOK3
        beq ?w
        jsr mus_play_t ; ONE frame of the song per VBLANK, not
                                     ;   per DOOM tic: the stream is authored ...
        lda wi_tacc
        clc
        adc #WI_TICQ8
        sta wi_tacc
        bcc ?v
        inc wi_bcnt
        rts
.endp
wi_bcnt     dta 0
wi_tacc     dta 0                    ; the 50 Hz -> 35 Hz Q8 accumulator

;--------------------------------------------------------------
; wi_melt -- X = 0: into the intermission, 1: out of it. The melt itself is
;   melt.asm's (bank $01) at 320 on MT_SR; the tic loop stays here, beside
;   the song (wi_tic). The chain's last tic has landed when it returns.
;--------------------------------------------------------------
.proc wi_melt
        jsl B1CODE_BASE+mt_init_w1
?t      jsr wi_tic
        jsl B1CODE_BASE+mt_step_w1   ; C = a column still to land
        bcs ?t
        rts
.endp

;--------------------------------------------------------------
; wi_melt2 -- the SECOND melt: the stats screen, on MT_SR through the level
;   load (mt_keep), into the next level's first frame (ZFRONT, never FRAME_A:
;   WI_XLOAD aims it at FRAME_B, and the chain lives in FRAME_A).
;--------------------------------------------------------------
.proc wi_melt2
        stz XDLA_PEND                ; list R stays up until the melt is over
        ldx #1
        jsr wi_melt
        stz EXIT_REQ                 ; ...and the game goes on: its next flip
        rts                          ;   takes the display back
.endp

;--------------------------------------------------------------
; melt.asm's data: bank 0 for its bank-$01 code, and here because D0 is full
;   and no melt runs without stage 1.
;--------------------------------------------------------------
    .if [*&$FF] <> 0                   ; mt_step's row*320 lookups: page-aligned
          :[256-[*&$FF]] dta 0       ;   (a read crossing a page is +1)
    .endif
mt_r320   .rept WIPE_H+1
          dta a(#*MT_W)
          .endr
mt_r      :SCREEN_WIDTH dta a(0)     ; f_wipe.c's y[], signed, per column
mt_y      dta a(0)
mt_n      dta a(0)                   ; y + dy
mt_t      dta a(0)
mt_busy   dta a(0)
;   per melt (X = 0 into the intermission, 1 out of it): slot A's source
mt_pst    dta <MT_W, <SCREEN_WIDTH   ; SRC_STEPY
mt_psth   dta >MT_W, >SCREEN_WIDTH
mt_pw     dta 1, 0                   ; WIDTH-1
mt_pz     dta BLT_ZOOM_1X, BLT_ZOOM_2X
mt_psp    dta WIPE_H, VIEW_HEIGHT
mt_pop    dta $EA, $4A               ; nop / lsr @
mt_r3     dta a($FFFF), a(0), a(1), a($FFFF)   ; mt_init: (rnd & 3) -> r - 1
;   one column's three BCBs (64 B: a pad byte for the word loop). S moves the
;   old picture down bottom-up; A and B bring in the new one.
mt_img    dta 0, 0, MT_BK, a([-MT_W]&$FFFF), 1                ; S
          dta 0, 0, MT_BK, a([-MT_W]&$FFFF), 1, a(1), 0, $FF, 0, 0, 0, 0, BLT_COPY|BLT_NEXT
          dta 0, 0, 0, a(MT_W), 1                             ; A
          dta 0, 0, MT_BK, a(MT_W), 1, a(1), 0, $FF, 0, 0, 0, 0, BLT_COPY|BLT_NEXT
          dta 0, 0, [VRAM_BAR320>>16], a(MT_W), 1             ; B
          dta 0, 0, MT_BK, a(MT_W), 1, a(1), 0, $FF, 0, 0, 0, 0, BLT_COPY|BLT_NEXT
          dta 0
    .if *-mt_img <> MT_COL+1
        ert 'wi.asm: mt_img is three BCBs and a pad byte'
    .endif

    .if * > WI_XLOAD
        ert 'wi.asm STAGE 1 ran into WI_XLOAD (memory_map.inc)'
    .endif
        :[WI_XLOAD-*] dta 0

;--------------------------------------------------------------
; WI_XLOAD -- the across-the-load driver, and the ONLY part of stage 1 above
;--------------------------------------------------------------
        jsr exit_level_t
        lda #1
        sta zback_hi                 ;   goes to FRAME_B, NOT FRAME_A.
        lda #EXIT_MELT
        sta EXIT_REQ
        rts

    .if * > MENU_RUN_END+1
        ert 'wi.asm STAGE 1 outgrew MENU_RUN..MENU_RUN_END (memory_map.inc)'
    .endif

;==============================================================
; PART 3 -- STAGE 2, in the map slot. `org` with no load address: it runs where
;==============================================================
        org WI2_RUN

;--------------------------------------------------------------
; wi_main -- WI_Start, then WI_Ticker/WI_Drawer once per DOOM tic.
;--------------------------------------------------------------
.proc wi_main
        lda #[WI_SRVRAM>>16]         ; mn_sbox's screen (wi_erase): the surface,
        sta mn_dbk                   ;   whatever the ESC panel left there
        jsr wi_bgfetch               ; WIMAP%d at 320 onto it, with its list
        jsl B1CODE_BASE+mt_grab_w1   ; the frame shown, at 320 on MT_SR and up
        jsl B1CODE_BASE+wi_kitfetch_w1  ; ...and the patches, full width
        jsr wi_stats
        jsr wi_initstats             ; WI_initStats
        jsr wi_slam                  ; (no wi_redraw: every counter is still -1
                                     ;   and the map is fresh -- nothing to erase)
        ldx #0
        jsr wi_melt                  ; the game melts into the stats surface
        lda #[WI_SRBG>>16]           ; the pristine map wi_erase restores from
        jsr wi_bgfetch
        lda #[WI_SRBG>>16]
        sta mn_sbk
        rep #$20
        .LONGA ON
        lda #WI_SRXDL&$FFFF
        ldx #[WI_SRXDL>>16]
        jsl B1CODE_BASE+xdl_to_r_w1  ; ...and the surface itself up (returns 8-bit)
        .LONGA OFF
?loop   jsr wi_tic
        jsr wi_accel                 ; WI_checkForAccelerate
        jsr wi_anim                  ; WI_updateAnimatedBack
        jsr wi_updstats              ; the sp_state machine
        lda wi_state
        cmp #WI_ST_DONE
        bne ?loop
        jsr wi_nextloc
        jsl B1CODE_BASE+mt_keep_w1   ; the stats onto MT_SR and up: the level
                                     ;   load takes the pool, not MT_SR, and the
                                     ;   second melt starts from it
        jsr mus_stop_t ; the stats screen is over: drop AUDC2/3/4
                                     ;   before WI_XLOAD, or the last note of ...
        jmp WI_XLOAD
.endp                                ;   second melt for the frame after it

;--------------------------------------------------------------
; wi_stats -- everything G_DoCompleted puts in wminfo, derived rather than
;--------------------------------------------------------------
.proc wi_stats
        stz wi_kills
        stz wi_items
        stz wi_maxkills              ;   throw the tally away
        stz wi_maxitems
        lda th_things
        sta sp_ptr
        lda th_things+1
        sta sp_ptr+1
        lda #MAP_EXT_BANK
        sta zp_ptr+2
        ldx #0
?lp     cpx THINGS_BASE              ; the packed thing count
        bcs ?time
        stx wi_i
        txy
        lda #<TH_KIND
        sta zp_ptr
        lda #>TH_KIND
        sta zp_ptr+1
        lda [zp_ptr],y
        beq ?item
        tay
        lda mk_ckill,y
        beq ?next
        inc wi_maxkills
        ldy wi_i
        lda #>TH_STATE
        sta zp_ptr+1
        lda [zp_ptr],y
        bne ?gotkill
                                      ; 2026-09-22 idiom: X IS wi_i (stx wi_i at ?lp;
        jsr thing_alive_bit_t          ;   en_kill just cleared the ALIVE bit
        bne ?next
?gotkill inc wi_kills
        bra ?next
?item   ldy #6
        lda (sp_ptr),y
        jsr wi_bonus
        beq ?next
        cmp #BN_COUNT
        bcs ?next
        tay
        lda bn_citem,y
        beq ?next
        inc wi_maxitems
        ldx wi_i
        jsr thing_alive_bit_t          ; taken = spr_take cleared its bit
        bne ?next
        inc wi_items
?next   clc                          ; the record is 8 B, like en_kfill's
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     ldx wi_i
        inx
        bne ?lp
?time   lda wi_time
        sta wi_m
        lda wi_time+1
        sta wi_m+1
        lda #50
        jsr wi_div16_t                 ; wi_m /= 50
        lda wi_m
        sta wi_secs
        lda wi_m+1
        sta wi_secs+1
        ldx current_level            ; pars[1][map] (g_game.c:981)
        lda wi_par,x
        sta wi_parsec
        stz wi_parsec+1
        rts
.endp

;--------------------------------------------------------------
; wi_bonus -- A = sprite id -> A/Z = th_sprtab[id*8 + 7], the shared kind/bonus
;--------------------------------------------------------------
.proc wi_bonus
                                      ; 2026-09-23: id*8 + th_sprtab in 16-bit A (the
        rep #$20                     ;   shifts of a byte cannot carry out: C = 0 for
        .LONGA ON                    ;   the add)
        and #$00FF
        asl @
        asl @
        asl @
        adc th_sprtab
        sta sp_tab
        sep #$20
        .LONGA OFF
        ldy #7
        lda (sp_tab),y
        rts
.endp

;==============================================================
; THE TALLY -- wi_stuff.c's sp_state machine (WI_updateStats, :1330).
;==============================================================
.proc wi_initstats
        lda #1
        sta wi_sp
        stz wi_accelst
        stz wi_bcnt
        stz wi_state
        stz wi_tacc
        stz wi_tvis
        stz wi_ctime                 ;   and cnt_par start at -1, and
        stz wi_ctime+1               ;   WI_drawTime returns on t < 0)
        stz wi_cpar
        stz wi_cpar+1
        ldx #2
        lda #$FF
?z      sta wi_cnt,x
        dex
        bpl ?z
        lda #WI_TICRATE              ; cnt_pause = TICRATE
        sta wi_pause
        rts
.endp

;--------------------------------------------------------------
; wi_accel -- WI_checkForAccelerate (:1470). One key, edge triggered: DOOM
;--------------------------------------------------------------
.proc wi_accel
        lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        bne ?up
        lda wi_karm
        beq ?no
        stz wi_karm
        lda #1
        sta wi_accelst
?no     rts
?up     lda #1
        sta wi_karm
        rts
.endp

;--------------------------------------------------------------
; wi_updstats -- WI_updateStats, one DOOM tic.
;--------------------------------------------------------------
.proc wi_updstats
        lda wi_accelst
        beq ?state
        lda wi_sp
        cmp #10
        beq ?state
        stz wi_accelst
        jsr wi_finals
        ldx #SFX_BAREXP
        jsr snd_play_t
        lda #10
        sta wi_sp
        jmp wi_redraw
?state  lda wi_sp
        lsr                          ; odd = one of the five PAUSES
        bcs ?pause
        cmp #5
        beq ?done
        cmp #4
        beq ?tp
        tax                          ; states 2/4/6 -> rows 0/1/2
        dex
        bra wi_ratio
?tp     jmp wi_timepar
?pause  dec wi_pause
        bne ?out
        inc wi_sp
        lda #WI_TICRATE
        sta wi_pause
        lda wi_sp
        cmp #8
        bne ?out
        inc wi_tvis
?out    rts
?done   lda wi_accelst               ; state 10: one more press leaves
        beq ?out
        ldx #SFX_SGCOCK              ; wi_stuff.c:1416's own sound
        jsr snd_play_t
        lda #WI_ST_DONE
        sta wi_state
        rts
.endp

;--------------------------------------------------------------
; wi_ratio -- states 2/4/6, X = which row. "cnt += 2; pistol every 4th tic;
;--------------------------------------------------------------
.proc wi_ratio
        stx wi_row
        jsr wi_pctof_t                 ; A = the row's true percentage
        sta wi_t
        ldx wi_row
        lda wi_cnt,x
        clc
        adc #2
        sta wi_cnt,x
        lda wi_bcnt
        and #3
        bne ?nosnd
        ldx #SFX_PISTOL
        jsr snd_play_t
?nosnd  ldx wi_row
        lda wi_cnt,x
        cmp wi_t
        bcc ?draw
        lda wi_t                     ; landed: clamp, bang, next state
        sta wi_cnt,x
        ldx #SFX_BAREXP
        jsr snd_play_t
        inc wi_sp
?draw   jmp wi_redraw
.endp

;--------------------------------------------------------------
; wi_timepar -- state 8. DOOM ticks BOTH by 3 and only advances once the PAR
;--------------------------------------------------------------
.proc wi_timepar
        lda wi_bcnt
        and #3
        bne ?not
        ldx #SFX_PISTOL
        jsr snd_play_t
?not
                                      ; 2026-09-23: both counters as words, one window
        rep #$21                     ; cnt_time += 3, clamped at stime
        .LONGA ON
        lda wi_ctime
        adc #3
        cmp wi_secs
        bcc ?t16
        lda wi_secs
?t16    sta wi_ctime
        clc                          ; cnt_par += 3, clamped at partime
        lda wi_cpar
        adc #3
        cmp wi_parsec
        bcs ?pl16
        sta wi_cpar
        sep #$20
        .LONGA OFF
        jmp wi_redraw
        .LONGA ON
?pl16   lda wi_parsec                ; par has landed -- and time too?
        sta wi_cpar
        lda wi_ctime
        cmp wi_secs
        sep #$20
        .LONGA OFF
        bne ?draw
        ldx #SFX_BAREXP
        jsr snd_play_t
        inc wi_sp                    ; (falls into ?draw)
?draw   jmp wi_redraw
.endp

;--------------------------------------------------------------
; wi_finals -- acceleratestage: every counter to its final value at once.
;--------------------------------------------------------------
.proc wi_finals
        ldx #2
?r      stx wi_row
        jsr wi_pctof_t
        ldx wi_row
        sta wi_cnt,x
        dex
        bpl ?r
                                      ; 2026-09-22 idiom: two word copies in a row -> one
        rep #$20                     ;   16-bit window (wi.asm runs in-game, native --
        .LONGA ON                    ;   its other windows prove it)
        lda wi_secs
        sta wi_ctime
        lda wi_parsec
        sta wi_cpar
        sep #$20
        .LONGA OFF
        inc wi_tvis
        rts
.endp

;--------------------------------------------------------------
; wi_pctof -- X = row (0 kills, 1 items, 2 secret) -> A = value*100/max.
;--------------------------------------------------------------

;--------------------------------------------------------------
; wi_mul100 -- A -> wi_m = A*100, as 4 + 32 + 64 shifted and added. 255*100 is
;--------------------------------------------------------------
.proc wi_mul100
        rep #$21                     ; ---- 16-bit A, C=0: *4 -> t3, *32 -> m,
        .LONGA ON                    ;   *64 + *32 + *4 = *100, all in A. No
        and #$FF                     ;   sum passes 25500, so no add carries
        asl @
        asl @                        ; *4
        sta wi_t3
        asl @
        asl @
        asl @                        ; *32
        sta wi_m
        asl @                        ; *64
        adc wi_m                     ; *96
        adc wi_t3                    ; *100
        sta wi_m
        sep #$20
        .LONGA OFF
        rts
.endp

;--------------------------------------------------------------
; wi_div16 -- wi_m (u16) /= A (u8), remainder dropped, quotient in wi_m.
;--------------------------------------------------------------

;==============================================================
; THE DRAWING -- WI_drawStats (:1436) and the two title lines.
;==============================================================
;--------------------------------------------------------------
; wi_entry -- A = wi.tab index -> zp_ptr = its 7-byte row, so hud_blit can draw
;--------------------------------------------------------------
.proc wi_entry
        rep #$20                     ; ---- 16-bit A: index*7 = *8 - index, and
        .LONGA ON                    ;   8i >= i leaves C=1: that is the +1 of a
        and #$FF                     ;   16-bit add of WI_TAB-1
        sta zp_ptr                   ; (the index, parked for the subtract)
        asl @
        asl @
        asl @
        sec
        sbc zp_ptr
        adc #WI_TAB-1
        sta zp_ptr
        sep #$20
        .LONGA OFF
        rts
.endp

;--------------------------------------------------------------
; wi_putx / wi_put -- A = lump, Y = row, the column in X (< 256) or in wi_px
;   (a word: the intermission's x reaches 304). V_DrawPatch at DOOM's own 320.
;--------------------------------------------------------------
.proc wi_putx                        ; X = the column, when it is < 256
        stx wi_px
        stz wi_px+1
?put                                 ; A = lump, wi_px = the column (a word),
        pha                          ;   Y = the row. The wait (A/Y): sr_put
        phy                          ;   writes the shared BCB before ITS wait,
        jsr blitter_wait_t           ;   and the last rect/erase is async
        ply
        pla
        jsr wi_entry                 ; (A only: Y rides through)
        jsl B1CODE_BASE+sr_put_w1    ; 2026-09-24: 1:1 onto the 320 SR surface
        rts
.endp
wi_put  = wi_putx.?put

;--------------------------------------------------------------
; wi_slam -- WI_slamBackground + WI_drawLF: the background, the ten animations,
;--------------------------------------------------------------
.proc wi_slam
        stz wi_tmode
        jmp wi_slambg                ; (it loads A itself)
.endp                                ;   layer above it (wi_over: LF title +
                                     ;   the five labels)

;--------------------------------------------------------------
; wi_labels -- the five static rows of WI_drawStats. Drawn once: the per-tic
;--------------------------------------------------------------
.proc wi_labels
        stz wi_row
?l      ldx wi_row
        lda wi_rowy,x
        sta wi_arg
        lda wi_lblix,x
        ldx #WI_STATSX
        ldy wi_arg
        jsr wi_putx
        inc wi_row
        lda wi_row
        cmp #3
        bne ?l
        lda #WI_I_TIME
        ldx #WI_TIMEX
        ldy #WI_TIMEY
        jsr wi_putx
        lda #WI_I_PAR
        ldx #WI_PARX
        ldy #WI_TIMEY
        jmp wi_putx
.endp

;--------------------------------------------------------------
; wi_redraw -- the animated half: three percentages and two times, each erased
;--------------------------------------------------------------
.proc wi_redraw
        stz wi_row
?l      ldx wi_row
        lda wi_rowy,x
        sta wi_py
        ldx #WI_PCTXH-WI_FLDW        ; (erase boxes are in 160 units)
        ldy wi_py
        jsr wi_erase
        ldx wi_row
        lda wi_cnt,x
        bmi ?nx
        ldx #<WI_PCTX                ;      `if (p < 0) return`); the '%'
        stx wi_px                    ;   at x = 270, a word
        ldx #>WI_PCTX
        stx wi_px+1
        ldy wi_py
        jsr wi_pct
?nx     inc wi_row
        lda wi_row
        cmp #3
        bne ?l
        lda #WI_TFLDW
        sta wi_ew                    ;   -- nothing between the two erases
        lda #WI_FLDH                 ;   touches wi_ew or wi_eh
        sta wi_eh
        ldx #WI_TIMEVXH-WI_TFLDW
        ldy #WI_TIMEY
        jsr wi_erase.wi_erasew
        ldx #WI_PARVXH-WI_TFLDW
        ldy #WI_TIMEY
        jsr wi_erase.wi_erasew
        lda wi_tvis
        beq ?out
        lda wi_ctime
        sta wi_cur
        lda wi_ctime+1
        sta wi_cur+1
        ldx #WI_TIMEVX               ; (< 256)
        stx wi_px
        stz wi_px+1
        ldy #WI_TIMEY
        jsr wi_dotime
        lda wi_cpar
        sta wi_cur
        lda wi_cpar+1
        sta wi_cur+1
        ldx #<WI_PARVX               ; x = 304: a word
        stx wi_px
        ldx #>WI_PARVX
        stx wi_px+1
        ldy #WI_TIMEY
        jsr wi_dotime
?out    rts
.endp

;--------------------------------------------------------------
; wi_erase -- X = column, Y = row: put WI_FLDW x WI_FLDH bytes of the
;--------------------------------------------------------------
.proc wi_erase
        lda #WI_FLDW
        sta wi_ew
        lda #WI_FLDH
        sta wi_eh
wi_erasew
        stx mn_bx                    ; 2026-09-24: the box, in 160 units, back out
        sty mn_by                    ;   of the pristine map (WI_SRBG, mn_sbk) at
        ldx wi_ew                    ;   320 -- menu.asm mn_sbox, the title's own
        dex                          ;   restore
        stx mn_bw
        ldx wi_eh
        dex
        stx mn_bh
        jsr blitter_wait_t           ; mn_sbox writes the BCB before ITS wait
        jmp mn_sbox_t
.endp

;--------------------------------------------------------------
; wi_num
;--------------------------------------------------------------
.proc wi_num                         ; A = n, wi_px = its right edge, Y = row
        sty wi_py
        sta wi_n
        lda wi_dig
        bpl ?have
        ldx #1
        lda wi_n
        cmp #10
        bcc ?got
        inx
        cmp #100
        bcc ?got                     ;   whole answer.
        inx
?got    stx wi_dig
?have   lda wi_n
?loop   ldx #0                       ; digit = n mod 10, X = n / 10
?d      cmp #10
        bcc ?done                    ; (not taken: C=1, the sbc needs no sec)
        sbc #10
        inx
        bra ?d
                                      ; 2026-09-23: the digit stays in A -- C = 0 from
?done   stx wi_n                     ;   the taken bcc ?done, so the lump add needs no
        adc #WI_I_NUM0               ;   clc; parked on the stack while x steps left
        pha
        rep #$20                     ; x -= WINUM0's width: a word (x reaches 304)
        .LONGA ON
        lda wi_px
        sec
        sbc #WI_NUMW
        sta wi_px
        .LONGA OFF
        sep #$20
        pla
        ldy wi_py
        jsr wi_put
        dec wi_dig
        beq ?out
        lda wi_n
        bra ?loop
?out    rts
.endp

;--------------------------------------------------------------
; wi_pct -- WI_drawPercent: the '%' AT x, then the digits leftwards from it.
;--------------------------------------------------------------
.proc wi_pct                         ; A = the value, wi_px = the '%''s x, Y = row
        sta wi_n2
        sty wi_py
        lda #WI_I_PCNT
        jsr wi_put
        lda #$FF
        sta wi_dig
        lda wi_n2
        ldy wi_py
        bra wi_num
.endp

;--------------------------------------------------------------
; wi_dotime -- WI_drawTime(x, y, wi_cur): two digits, a colon, and the next
;--------------------------------------------------------------
.proc wi_dotime                      ; wi_px = the right edge, Y = the row
        sty wi_py
        lda wi_cur+1                 ; > 3599 s? (61*59, wi_stuff.c:388)
        cmp #>3600
        bcc ?ok
        bne ?sucks
        lda wi_cur
        cmp #<3600
        bcc ?ok
?sucks  lda #WI_I_SUCKS
        ldy wi_py
        jmp wi_put
?ok     lda wi_cur                   ; minutes = t/60, seconds = t mod 60
        sta wi_m
        lda wi_cur+1
        sta wi_m+1
        lda #60
        jsr wi_div16_t                 ; wi_m = minutes
        lda wi_m
                                      ; 2026-09-22 (65816-style): the minutes ride the
        pha                          ;   stack across the seconds' print
        jsr wi_mul60
                                      ; 2026-09-23: the seconds straight from A
        lda #2
        sta wi_dig
        sec
        lda wi_cur
        sbc wi_m
        ldy wi_py
        jsr wi_num
        rep #$20                     ; ...then the colon left of them (a word)
        .LONGA ON
        lda wi_px
        sec
        sbc #WI_COLONW
        sta wi_px
        .LONGA OFF
        sep #$20
        lda #WI_I_COLON
        ldy wi_py
        jsr wi_put
        pla                          ; (pla sets Z as the lda did)
        beq ?out
                                      ; the minutes stay in A
        ldx #$FF
        stx wi_dig
        ldy wi_py
        jmp wi_num
?out    rts
.endp

;--------------------------------------------------------------
; wi_mul60 -- A -> wi_m = A*60 (= 32 + 16 + 8 + 4), for the seconds remainder.
;--------------------------------------------------------------
.proc wi_mul60
        rep #$20                     ; ---- 16-bit A: *60 = *64 - *4, in A
        .LONGA ON
        and #$FF
        asl @
        asl @                        ; *4
        sta wi_t3
        asl @
        asl @
        asl @
        asl @                        ; *64
        sec
        sbc wi_t3                    ; *60
        sta wi_m
        sep #$20
        .LONGA OFF
        rts
.endp

;==============================================================
; THE ANIMATED BACKGROUND -- epsd0animinfo (wi_stuff.c:222). Episode 1 is
;==============================================================
.proc wi_anim
        lda wi_bcnt
        cmp wi_anext
        bcc ?out
        clc
        adc #WI_ANIMPER
        sta wi_anext
        inc wi_af
        lda wi_af
        cmp #WI_ANIMF
        bcc ?draw
        stz wi_af
?draw   ldx current_level
        lda wi_ebase,x               ;   only episode 1 has animations at all --
        bne wi_over                  ;   see wi_syms.inc. Episode 1 IS ebase 0.
        stz wi_ai
                                      ; 2026-09-23: X/Y straight from the tables, the
?l      ldy wi_ai                    ;   row parked on the stack; wi_ai < 10, so the
        ldx wi_animx,y               ;   asl and every add stay < 256 (C = 0 through)
        lda wi_animy,y
        pha
        tya                          ; lump = ANIM0 + anim*ANIMF + frame
        asl
        adc wi_ai                    ; *3
        adc wi_af
        adc #WI_I_ANIM0
        ply
        jsr wi_putx                  ; (X = the anim's x, < 256)
        inc wi_ai
        lda wi_ai
        cmp #WI_ANIMS
        bne ?l
        bra wi_over                  ; the anims just stamped their rectangles
?out    rts                          ;   OVER the once-drawn layer -- re-assert
.endp                                ;   all of it, not only the title

;--------------------------------------------------------------
; wi_over -- everything that lives ABOVE the animations, repainted after every
;   anim redraw.
;--------------------------------------------------------------
.proc wi_over
        lda wi_tmode
        bne ?el
        jsr wi_title                 ; --- WI_drawStats' layer
        jmp wi_labels
?el     jsr wi_splats                ; --- WI_drawShowNextLoc's layer
        lda wi_yon
        beq ?ttl
        jsr wi_yahput
?ttl
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>wi_title             ;   next byte of this segment -- fall through
.endp

;--------------------------------------------------------------
; wi_title -- the two title lines for whichever screen is up: WI_drawLF during
;--------------------------------------------------------------
.proc wi_title
        lda wi_tmode
        bne ?el
                                      ; 2026-09-23: X straight from the table
        ldy current_level            ; --- WI_drawLF
        ldx wi_lvx,y
        tya
        clc
        adc #WI_I_LV0
        ldy #WI_TITLEY
        jsr wi_putx                  ; (every title x is < 256: centred)
        ldx wi_finx
        lda #WI_I_FINISH
        ldy #WI_LFY2
        jmp wi_putx
?el     lda #WI_I_ENTER              ; --- WI_drawEL
        ldx wi_entx
        ldy #WI_TITLEY
        jsr wi_putx
        ldy wi_next
        ldx wi_lvx,y
        tya
        clc
        adc #WI_I_LV0
        ldy #WI_LFY2
        jmp wi_putx
.endp

;==============================================================
; ShowNextLoc (:752) then NoState (:730) -- the world map with a splat on every
;==============================================================
.proc wi_nextloc
        lda #1
        sta wi_tmode
        jsr wi_slambg                ; the map again, over the tally -- and its
                                     ;   anim pass tail-draws the whole ABOVE ...
        stz wi_accelst               ; cnt = SHOWNEXTLOCDELAY * TICRATE
        stz wi_yon
        lda #<[WI_SNLDELAY*WI_TICRATE]
        sta wi_cnt16
        lda #>[WI_SNLDELAY*WI_TICRATE]
        sta wi_cnt16+1
?loop   jsr wi_tic
        jsr wi_accel
        jsr wi_anim
        lda wi_cnt16                 ; snl_pointeron = (cnt & 31) < 20
        and #31
        cmp #20
        lda #0
        rol                          ; A = 1 while the pointer is ON
        eor #1
        jsr wi_yah
                                      ; 2026-09-23: --cnt as ONE word; Z of the 16-bit
        rep #$20                     ;   dec is the whole word's, sep keeps it
        .LONGA ON
        dec wi_cnt16
        .LONGA OFF
        sep #$20
        beq ?done
        lda wi_accelst
        beq ?loop
?done   lda #1                       ; NoState: the pointer stays ON
        jsr wi_yah
        lda #WI_NOSTATE
        sta wi_pause
?nl     jsr wi_tic
        jsr wi_anim
        dec wi_pause
        bne ?nl
        rts
.endp

;--------------------------------------------------------------
; wi_splats -- WI_drawShowNextLoc's splat pass: one on every level up to and
;   including the one just finished. Split out of wi_nextloc so wi_over can
;   repaint them after every anim redraw -- six of the ten anim rectangles
;   share pixels with five of the nine nodes (the flak.png outline).
;--------------------------------------------------------------
.proc wi_splats
        ldx current_level            ; wbs->last is the map WITHIN the episode,
        lda wi_ebase,x               ;   not the disk index: E2M1 used to splat
        sta wi_ai                    ;   levels 0..9, i.e. the whole of episode
        sec                          ;   1's map. wi_ebase is that episode's M1
        lda current_level            ;   (tools/pack_wi.py), so the subtract is
        sbc wi_ai                    ;   wbs->last and wi_ai is where its nodes
        cmp #8                       ;   start.
        bne ?have                    ; last == 8 is the SECRET level, and DOOM
        ldx wi_next                  ;   shows next-1 instead (wi_stuff.c:790)
        sec
        lda wi_next
        sbc wi_ebase,x
        dec @
?have   clc
        adc wi_ai                    ; ...so stop at ebase + last, INCLUSIVE
        sta wi_arg+1                 ;   (wi_stuff.c:793 is i <= last)
                                      ; 2026-09-23: Y straight from the table
?sp     ldx wi_ai
        jsr wi_nodepx                ; wi_px = the node's x, Y = its y
        lda #WI_I_SPLAT
        jsr wi_put
        inc wi_ai
        lda wi_ai
        cmp wi_arg+1
        beq ?sp
        bcc ?sp
        rts
.endp

;--------------------------------------------------------------
; wi_yahput -- draw the pointer at wi_next's node, unconditionally: wi_yah's
;   ON half, and wi_over's way to re-assert an ON pointer an anim redraw just
;   stamped over (no blink-edge filter, no state change).
;--------------------------------------------------------------
.proc wi_yahput
        ldx wi_next
        jsr wi_nodepx                ; C = wi_nodexh bit 7: WI_drawOnLnode's
        lda #WI_I_YAH0               ;   WIURH0/WIURH1 pick, made at pack time
        adc #0                       ; + C
        jmp wi_put
.endp

;--------------------------------------------------------------
; wi_nodepx -- X = level: wi_px = its lnode's x (a word: nodes reach 281),
;   Y = its y, C = bit 7 of the x high byte (the WIURH1 pick). Keeps X.
;--------------------------------------------------------------
.proc wi_nodepx
        ldy wi_nodey,x
        lda wi_nodexl,x
        sta wi_px
        lda wi_nodexh,x
        cmp #$80                     ; C = bit 7: the WIURH1 pick
        and #$7F                     ; the x high byte (and leaves C alone)
        sta wi_px+1
        rts
.endp
    .if WI_I_YAH1 != WI_I_YAH0+1
        ert 'wi_yahput adds the WIURH1 pick to WI_I_YAH0: WIURH1 must be the next lump'
    .endif

;--------------------------------------------------------------
; wi_yah -- A = 1 to show the "YOU ARE HERE" pointer on the next level's node,
;--------------------------------------------------------------
.proc wi_yah
        cmp wi_yon
        beq ?out
        sta wi_yon
        tay                          ; (sta keeps the cmp's flags: tay sets them
        bne wi_yahput                ;  from A; Y is dead on both paths)
        ldx wi_next                  ; OFF: erase its box back to the map
        lda #WI_YAHW
        sta wi_ew
        lda #WI_YAHH
        sta wi_eh
        lda wi_nodey,x
        sec
        sbc #WI_YAHDY
        tay
        lda wi_yahex,x               ; the box's left edge in 160 units, per
        tax                          ;   level (pack_wi.py: x - left, halved)
        jmp wi_erase.wi_erasew
?out    rts
.endp

;--------------------------------------------------------------
; wi_slambg -- background + animations, no title lines: WI_slamBackground.
;--------------------------------------------------------------
.proc wi_slambg
        lda wi_tmode                 ; ShowNextLoc's: the map back from the
        beq ?fresh                   ;   pristine copy, whole screen (the stats'
        stz mn_bx                    ;   slam finds it fresh from wi_bgfetch --
        stz mn_by                    ;   and there is no pristine copy yet)
        lda #SCREEN_WIDTH-1
        sta mn_bw
        lda #SCREEN_HEIGHT-1
        sta mn_bh
        jsr blitter_wait_t           ; mn_sbox writes the BCB before ITS wait
        jsr mn_sbox_t
?fresh  lda #BLT_BSTENCIL
        sta hb_ctrl
        stz wi_bcnt
        stz wi_anext                 ;   all ten over the fresh background
        jmp wi_anim
.endp

;--------------------------------------------------------------
; wi_bgfetch -- A = the bank to fill (WI_SRVRAM's or WI_SRBG's): WI_loadData's
;   background, WIMAP%d for wbs->epsd (wi_stuff.c:1548), at 320 with its SR
;   list, out of its SDRAM bank (wi_bgm) -- WI_WIMCOPY bytes by spr_fcopy.
;--------------------------------------------------------------
.proc wi_bgfetch
        sta sp_addr+2                ; destination: bank A, offset 0
        ldx current_level
        lda wi_bgm,x
        clc
        adc #WIMAP_BANK
        sta sf_src+2                 ; source: the map's own bank, offset 0
        rep #$20
        .LONGA ON
        stz sp_addr
        stz sf_src
        lda #WI_WIMCOPY
        sta sf_size
        .LONGA OFF
        sep #$20
        jsl B1CODE_BASE+spr_fcopy_w1
        rts
.endp
    .if WI_SRVRAM <> MENU_SRVRAM || WI_SRXDL <> MENU_SRXDL || [WI_SRBG & $FFFF] <> 0
        ert 'wi.asm draws through mn_sdraw/mn_sbox: the surface must be MENU_SRVRAM, the pristine copy bank-aligned'
    .endif

        icl 'wi_tables.inc'          ; mk_ckill / bn_citem, from info.c
        icl 'wi_syms.inc'

;--------------------------------------------------------------
; WI_TAB -- the 63 seven-byte rows, in hud.tab's own layout so hud_entry and
;--------------------------------------------------------------
WI_TAB
        ins 'build/assets/wi/wi.tab'

;--------------------------------------------------------------
; wi_lblix / wi_rowy -- the three percentage rows as parallel arrays, so
;--------------------------------------------------------------
wi_lblix dta WI_I_KILLS, WI_I_ITEMS, WI_I_SECRET
wi_rowy  dta WI_STATSY, WI_STATSY+WI_LH, WI_STATSY+2*WI_LH

;--------------------------------------------------------------
; Stage 2's variables. Dead RAM the moment exit_level runs, so they live here
;--------------------------------------------------------------
wi_cnt      dta 0,0,0                ; cnt_kills / cnt_items / cnt_secret
wi_ctime    dta 0,0                  ; cnt_time, seconds
wi_cpar     dta 0,0                  ; cnt_par
wi_tvis     dta 0
wi_secs     dta 0,0                  ; plrs[me].stime / TICRATE
wi_parsec   dta 0,0                  ; wbs->partime / TICRATE
wi_mins     dta 0
wi_sp       dta 0                    ; sp_state
wi_state    dta 0
wi_accelst  dta 0                    ; acceleratestage
wi_pause    dta 0                    ; cnt_pause
wi_cnt16    dta 0,0                  ; ShowNextLoc's cnt
wi_karm     dta 0                    ; 0 = the key HELD from the exit press must
                                     ;   be released first (DOOM's attackdown/ ...
wi_yon      dta 0
wi_af       dta 0                    ; the animations' shared frame...
wi_anext    dta 0                    ; ...and the bcnt it next changes on
wi_ai       dta 0
wi_row      dta 0
wi_tmode    dta 0
wi_ew       dta 0                    ; wi_erase box width
wi_eh       dta 0                    ; ...and height
wi_i        dta 0
wi_ix       dta 0
wi_n        dta 0
wi_n2       dta 0
wi_dig      dta 0
wi_px       = sr_x                   ; the column, a WORD (menu.asm sr_put's)
wi_py       dta 0
wi_arg      dta 0,0
wi_m        dta 0,0
wi_cur      dta 0,0
wi_t        dta 0
wi_t2       dta 0,0
wi_t3       dta 0,0
wi_d        dta 0

    .if * > WI2_END+1
        ert 'wi.asm STAGE 2 outgrew the map slot (WI2_RUN..WI2_END)'
    .endif
    .if [* - WI2_RUN] > WI2_PAGES*256
        ert 'wi.asm STAGE 2 is more pages than wi_head copies (WI2_PAGES)'
    .endif
        org wi_resume

;==============================================================
; PART 4 -- the two helpers the map slot ran out of room for (2026-08-18: the
; per-episode lnodes + wi_ebase and the episode-relative wi_splats pushed stage
; 2 fourteen bytes past $4C00). They are pure arithmetic on stage-2 VARIABLES,
; so only the CODE moved; both are called with the ROM banked out like the rest.
;==============================================================
;--------------------------------------------------------------
; wi_kitfetch -- the patches at full width, out of SDRAM into the pool behind
;   the SR surface (pack_wi.py): the kit at WI_KITVRAM, then the finished
;   level's name into slot A and the next one's into slot B -- and their two
;   WI_TAB rows pointed at the slots. The level is over: the pool is free.
;--------------------------------------------------------------
        .segment B1
.proc wi_kitfetch
        lda #[WI_KITVRAM>>16]
        sta sp_addr+2
        lda #WIMAP_BANK+WI_KITBK
        sta sf_src+2
        rep #$20
        .LONGA ON
        lda #WI_KITVRAM&$FFFF
        sta sp_addr
        stz sf_src
        lda #WI_KITLEN
        sta sf_size
        .LONGA OFF
        sep #$20
        jsr spr_fcopy
        lda #[WI_LVA>>16]            ; slot A: the level just finished
        sta sp_addr+2
        rep #$20
        .LONGA ON
        lda #WI_LVA&$FFFF
        sta sp_addr
        .LONGA OFF
        sep #$20
        lda current_level
        jsr ?name
        lda #[WI_LVB>>16]            ; slot B: the one it leads to (the same
        sta sp_addr+2                ;   level twice is harmless: both rows
        rep #$20                     ;   are its, B is written last)
        .LONGA ON
        lda #WI_LVB&$FFFF
        sta sp_addr
        .LONGA OFF
        sep #$20
        lda wi_next
?name   pha                          ; A = level k: its WI_TAB row first --
        clc                          ;   (I_LV0 + k)*7 + WI_TAB, *8 - itself,
        adc #WI_I_LV0                ;   and 8i >= i leaves C = 1: the +1 of
        rep #$20                     ;   WI_TAB-1
        .LONGA ON
        and #$00FF
        sta zp_ptr
        asl @
        asl @
        asl @
        sec
        sbc zp_ptr
        adc #WI_TAB-1
        sta zp_ptr
        lda sp_addr                  ; the row's vram = the slot, lo/mid ...
        sta (zp_ptr)
        .LONGA OFF
        sep #$20
        ldy #2
        lda sp_addr+2                ; ... and bank
        sta (zp_ptr),y
        pla                          ; the name's SDRAM slot: bank = NAMEBK +
        pha                          ;   k/16, mid = (k & 15) * 16 (4 KB each)
        lsr
        lsr
        lsr
        lsr
        clc
        adc #WIMAP_BANK+WI_NAMEBK
        sta sf_src+2
        pla
        asl
        asl
        asl
        asl                          ; the top four bits fall out: (k & 15) << 4
        sta sf_src+1
        stz sf_src
        rep #$20
        .LONGA ON
        lda #WI_NAMESZ
        sta sf_size
        .LONGA OFF
        sep #$20
        jmp spr_fcopy
.endp
wi_kitfetch_w1 jsr wi_kitfetch       ; wi_main's (stage 2, bank 0)
        rtl
    .if WI_NAMESLOT <> $1000 || WI_NAMESZ > WI_NAMESLOT
        ert 'wi_kitfetch steps names by 4 KB: WI_NAMESLOT must be $1000'
    .endif
        .endseg

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 4b: bank $01
.proc wi_pctof
        lda wi_max,x
        beq ?none
                                      ; 2026-09-22 (65816-style): parked on the stack
        pha                          ;   across the jsl (rtl balances it)
        lda wi_val,x
        jsl wi_mul100_w0
        pla
        jsr wi_div16
        lda wi_m
        rts
?none   lda #100
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 4b: bank $01
.proc wi_div16
                                      ; 2026-09-23: in 16-bit A. The divisor is a WORD on
        rep #$20                     ;   the stack (1,s), the remainder (< 2*255) in A,
        .LONGA ON                    ;   and the quotient bit rides in on C: rol, no inc
        and #$00FF                   ;   (C = 0 first, so the 17th rol drops a 0). Callers
        pha                          ;   read wi_m only; X = 0 on exit as before
        lda #0
        ldx #16
        clc
?l      rol wi_m
        rol @
        cmp 1,s
        bcc ?s
        sbc 1,s                      ; C = 1 after: rem >= d
?s      dex
        bne ?l
        rol wi_m                     ; the last quotient bit
        pla
        sep #$20
        .LONGA OFF
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
