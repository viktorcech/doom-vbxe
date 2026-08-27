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
.proc wi_tick
        lda wi_time
        clc
        adc fps_n
        sta wi_time
        bcc ?nc
        inc wi_time+1
?nc     jmp wi_secr
.endp
    .if * > WITICK_END+1
        ert 'wi_tick outgrew WITICK_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; wi_secr -- p_spec.c P_PlayerInSpecialSector's `case 9: SECRET SECTOR`, then
;--------------------------------------------------------------
        org WISECR_BASE
.proc wi_secr
        ldy #7
        lda (zp_ptr),y               ;   b4 SECRET (pack_map.py)
        and #$EF
        cmp (zp_ptr),y
        beq ?out
        sta (zp_ptr),y
?out    jmp update_damage
.endp
    .if * > WISECR_END+1
        ert 'wi_secr outgrew WISECR_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; wi_exit -- the frame loop's EXIT_REQ tail. main used to `jsr exit_level`
;--------------------------------------------------------------
        org WIEXIT_BASE
.proc wi_exit
        ldx EXIT_REQ
        dex
        lda #BANK_EN | WIOVL_BANK
        jmp mn_open                  ; ...which lands in wi_head below
.endp
    .if * > WIEXIT_END+1
        ert 'wi_exit outgrew WIEXIT_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; wi_newlvl -- G_DoLoadLevel's `leveltime = 0`, in front of load_things: both
;--------------------------------------------------------------
        org WINEW_BASE
.proc wi_newlvl
        lda #0
        sta wi_time
        sta wi_time+1
        jmp load_things
.endp
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
        cpx #WI_E_MELT
        bne ?inter
        jmp wi_melt2
?inter  jsr wi_pre
        lda #BANK_EN | WI2_BANK
        sta VBXE_BANK_SEL
        ldx #0
?s2     txa                          ;   inside WI2_PAGES and the slot
        clc
        adc #>MEMW
        sta ?src+2
        txa
        clc
        adc #>WI2_RUN
        sta ?dst+2
        ldy #0
?src    lda MEMW,y
?dst    sta WI2_RUN,y
        iny
        bne ?src
        inx
        cpx #WI2_PAGES
        bne ?s2
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        jmp WI2_RUN
.endp

;--------------------------------------------------------------
; wi_pre -- the reads that have to happen while the map slot is still a MAP.
;--------------------------------------------------------------
.proc wi_pre
        lda MAP_HNSECR
        sta wi_maxsecr
        sta wi_secret                ; ...and count DOWN from it
        lda #<MAP_SECTORS
        sta sp_ptr
        lda #>MAP_SECTORS
        sta sp_ptr+1
        ldx MAP_HNSEC
        beq ?next
?slp    ldy #7
        lda (sp_ptr),y
        and #$10                     ; still SET = never walked into
        beq ?sn
        dec wi_secret
?sn     clc
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?sc
        inc sp_ptr+1
?sc     dex
        bne ?slp
?next   ldx MAP_HNEXT
        cpx #NUM_LEVELS              ;   on this ATR the next one is E1M1
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
; wi_rect -- one plain COPY: wc_src -> wc_dst, wc_w+1 bytes by wc_h+1 rows,
;--------------------------------------------------------------
.proc wi_rect
        ldx #2
?a      lda wc_src,x
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR,x
        lda wc_dst,x
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR,x
        dex
        bpl ?a
        lda #SCREEN_WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda #0
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH+1
        lda #1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda wc_w
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda wc_h
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        lda #BLT_COPY
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsr hud_blit.hud_fire
        jmp blitter_wait
.endp

;--------------------------------------------------------------
; wi_set24 -- wc_src/wc_dst = a 24-bit base (wa_b) + row*160 + column, the one
;--------------------------------------------------------------
.proc wi_set24
        lda row_lo,x
        clc
        adc wa_col
        sta wc_src,y
        lda row_hi,x
        adc wa_b+1
        sta wc_src+1,y
        lda wa_b+2
        adc #0
        sta wc_src+2,y               ;   and +$7C00 crosses into $06
        rts
.endp

;--------------------------------------------------------------
; wi_grab -- the screen AS SHOWN -> wa_b. Two rectangles, because the port's
;--------------------------------------------------------------
.proc wi_grab
        lda #0
        sta wa_col
        sta wc_src
        sta wc_src+1
        lda ZFRONT
        sta wc_src+2
        lda #0
        sta wc_dst
        lda wa_b+1
        sta wc_dst+1
        lda wa_b+2
        sta wc_dst+2
        lda #SCREEN_WIDTH-1
        sta wc_w
        lda #VIEW_HEIGHT-1
        sta wc_h
        jsr wi_rect
        lda #<VRAM_HUDROWS
        sta wc_src
        lda #>VRAM_HUDROWS
        sta wc_src+1
        lda #[VRAM_HUDROWS>>16]
        sta wc_src+2
        ldx #VIEW_HEIGHT             ; ...to the same rows of the target
        ldy #3
        jsr wi_set24
        lda #WIPE_H-VIEW_HEIGHT-1
        sta wc_h
        jmp wi_rect
.endp

;--------------------------------------------------------------
; wi_page -- a whole 200-row screen from wa_b to wa_b2 (or the other way).
;--------------------------------------------------------------
.proc wi_page
        ldx #2
?c      lda wa_b,x
        sta wc_src,x
        lda wa_b2,x
        sta wc_dst,x
        dex
        bpl ?c
        lda #SCREEN_WIDTH-1
        sta wc_w
        lda #WIPE_H-1
        sta wc_h
        jmp wi_rect
.endp

;--------------------------------------------------------------
; wi_meltinit -- f_wipe.c wipe_initMelt (:141). P_Random is POKEY's LFSR here,
;--------------------------------------------------------------
.proc wi_meltinit
        lda RANDOM
        and #15
        eor #15
        clc
        adc #1                       ; = 16 - (rnd&15), so 1..16
        sta wy
        ldx #1
?l      lda RANDOM                   ; r = (M_Random()%3) - 1
        and #3
        cmp #3
        bcc ?ok
        lda #0
?ok     sec
        sbc #1
        clc
        adc wy-1,x                   ; y[i] = y[i-1] + r
        cmp #WI_BIAS+1               ; "if (y[i] > 0) y[i] = 0"
        bcc ?lo
        lda #WI_BIAS
        bne ?put                     ; (WI_BIAS is 16, never zero)
?lo     bne ?put                     ; "else if (y[i] == -16) y[i] = -15"
        lda #1
?put    sta wy,x
        inx
        cpx #SCREEN_WIDTH
        bne ?l
        rts
.endp

;--------------------------------------------------------------
; wi_melt -- run the whole wipe. One wipe_doMelt step per DOOM tic, so it
;--------------------------------------------------------------
.proc wi_melt
        jsr wi_meltinit
?tic    jsr wi_tic
        lda #0
        sta wm_busy
        ldx #0
        stx wa_col
?col    lda wy,x
        cmp #WI_BIAS
        bcs ?run
        inc wy,x
        inc wm_busy
        jmp ?next
?run    sec
        sbc #WI_BIAS                 ; ...and now it is a real row number
        cmp #WIPE_H
        bcc ?live
        jmp ?next
?live   sta wm_y                     ;   does not reach from here)
        inc wm_busy
        cmp #16                      ; dy = (y < 16) ? y+1 : 8
        bcs ?d8
        clc
        adc #1
        bne ?dy
?d8     lda #8
?dy     sta wm_dy
        clc
        adc wm_y                     ; clamp y+dy to the bottom
        cmp #WIPE_H+1
        bcc ?dok
        sec
        lda #WIPE_H
        sbc wm_y
        sta wm_dy
?dok    lda #<WIPE_END
        sta wa_b
        lda #>WIPE_END
        sta wa_b+1
        lda #[WIPE_END>>16]
        sta wa_b+2
        ldx wm_y
        ldy #0
        jsr wi_set24                 ; src = END + y*160 + col
        lda #0
        sta wa_b+1                   ; ...dst = the screen, same place
        sta wa_b+2
        ldx wm_y
        ldy #3
        jsr wi_set24
        lda #0
        sta wc_w                     ; one byte wide -- a COLUMN
        lda wm_dy
        sec
        sbc #1
        sta wc_h
        jsr wi_rect
        clc                          ; y += dy
        lda wm_y
        adc wm_dy
        sta wm_y
        clc
        adc #WI_BIAS                 ; ...stored biased again
        ldx wa_col
        sta wy,x
        lda wm_y
        cmp #WIPE_H
        bcc ?slide
        jmp ?next
?slide
        lda #<WIPE_START
        sta wa_b
        lda #>WIPE_START
        sta wa_b+1
        lda #[WIPE_START>>16]
        sta wa_b+2
        ldx #0
        ldy #0
        jsr wi_set24
        lda #0
        sta wa_b+1
        sta wa_b+2
        ldx wm_y
        ldy #3
        jsr wi_set24                 ; dst = the screen at row y
        lda #0
        sta wc_w
        sec                          ; height = 200 - y
        lda #WIPE_H-1
        sbc wm_y
        sta wc_h
        jsr wi_rect
?next   inc wa_col
        ldx wa_col
        cpx #SCREEN_WIDTH
        beq ?all
        jmp ?col
?all    lda wm_busy                  ; "done" -- every column has landed
        beq ?fin
        jmp ?tic
?fin    rts
.endp

;--------------------------------------------------------------
; wi_wipe -- the whole ceremony around one melt: WIPE_START already holds the
;--------------------------------------------------------------
.proc wi_wipe
        lda #0
        sta wa_b
        sta wa_b+1
        sta wa_b+2
        lda #<WIPE_END
        sta wa_b2
        lda #>WIPE_END
        sta wa_b2+1
        lda #[WIPE_END>>16]
        sta wa_b2+2
        jsr wi_page
        lda #<WIPE_START
        sta wa_b
        lda #>WIPE_START
        sta wa_b+1
        lda #[WIPE_START>>16]
        sta wa_b+2
        lda #0
        sta wa_b2
        sta wa_b2+1
        sta wa_b2+2
        jsr wi_page
        jsr wi_show                  ; only NOW is FRAME_A worth showing
        jmp wi_melt
.endp

;--------------------------------------------------------------
; wi_melt2 -- the SECOND melt: the intermission picture (still in WIPE_START,
;--------------------------------------------------------------
.proc wi_melt2
        lda #0
        sta XDLA_PEND
        sta wa_b
        sta wa_b+1
        sta wa_b+2
        lda ZFRONT
        beq ?have
        jsr wi_grab                  ;    there on purpose)
?have   jsr wi_wipe
        lda #1
        sta zback_hi
        lda #0
        sta EXIT_REQ                 ; ...and the game goes on
        rts
.endp

;--------------------------------------------------------------
; wi_show -- FRAME_A on screen, and nothing about to take it away again.
;--------------------------------------------------------------
.proc wi_show
        lda #0
        sta zback_hi
        sta ZFRONT
        sta XDLA_PEND                ; $00 = rom_nmi's "nothing pending"
        lda #>VRAM_XDL_A
        sta VBXE_XDLA1
        rts
.endp

wc_src      dta 0,0,0
wc_dst      dta 0,0,0
wc_w        dta 0
wc_h        dta 0
wa_b        dta 0,0,0
wa_b2       dta 0,0,0
wa_col      dta 0
wm_y        dta 0
wm_dy       dta 0
wm_busy     dta 0
wy          :SCREEN_WIDTH dta 0      ; f_wipe.c's y[], one per column

    .if * > WI_XLOAD
        ert 'wi.asm STAGE 1 ran into WI_XLOAD (memory_map.inc)'
    .endif
        :[WI_XLOAD-*] dta 0

;--------------------------------------------------------------
; WI_XLOAD -- the across-the-load driver, and the ONLY part of stage 1 above
;--------------------------------------------------------------
        jsr exit_level
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
        lda #<WIPE_START
        sta wa_b                     ;   picture the first melt takes away
        lda #>WIPE_START
        sta wa_b+1
        lda #[WIPE_START>>16]
        sta wa_b+2
        jsr wi_grab
        jsr wi_stats
        jsr wi_initstats             ; WI_initStats
        jsr wi_slam
        jsr wi_redraw
        jsr wi_wipe
?loop   jsr wi_tic
        jsr wi_accel                 ; WI_checkForAccelerate
        jsr wi_anim                  ; WI_updateAnimatedBack
        jsr wi_updstats              ; the sp_state machine
        lda wi_state
        cmp #WI_ST_DONE
        bne ?loop
        jsr wi_nextloc
        lda #0
        sta wa_b
        sta wa_b+1                   ;   survives it; nothing in RAM does)
        sta wa_b+2
        lda #<WIPE_START
        sta wa_b2
        lda #>WIPE_START
        sta wa_b2+1
        lda #[WIPE_START>>16]
        sta wa_b2+2
        jsr wi_page
        jmp WI_XLOAD
.endp                                ;   second melt for the frame after it

;--------------------------------------------------------------
; wi_stats -- everything G_DoCompleted puts in wminfo, derived rather than
;--------------------------------------------------------------
.proc wi_stats
        lda #0
        sta wi_kills
        sta wi_items
        sta wi_maxkills              ;   throw the tally away
        sta wi_maxitems
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
        txa
        tay
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
        ldx wi_i
        jsr thing_alive_bit          ;   en_kill just cleared the ALIVE bit
        bne ?next
?gotkill inc wi_kills
        jmp ?next
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
        jsr thing_alive_bit          ; taken = spr_take cleared its bit
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
        jsr wi_div16                 ; wi_m /= 50
        lda wi_m
        sta wi_secs
        lda wi_m+1
        sta wi_secs+1
        ldx current_level            ; pars[1][map] (g_game.c:981)
        lda wi_par,x
        sta wi_parsec
        lda #0
        sta wi_parsec+1
        rts
.endp

;--------------------------------------------------------------
; wi_bonus -- A = sprite id -> A/Z = th_sprtab[id*8 + 7], the shared kind/bonus
;--------------------------------------------------------------
.proc wi_bonus
        ldy #0
        sty wi_t2+1
        asl
        rol wi_t2+1
        asl
        rol wi_t2+1
        asl
        rol wi_t2+1
        clc
        adc th_sprtab
        sta sp_tab
        lda wi_t2+1
        adc th_sprtab+1
        sta sp_tab+1
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
        lda #0
        sta wi_accelst
        sta wi_bcnt
        sta wi_state
        sta wi_tacc
        sta wi_tvis
        sta wi_ctime                 ;   and cnt_par start at -1, and
        sta wi_ctime+1               ;   WI_drawTime returns on t < 0)
        sta wi_cpar
        sta wi_cpar+1
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
        lda #0
        sta wi_karm
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
        lda #0
        sta wi_accelst
        jsr wi_finals
        ldx #SFX_BAREXP
        jsr snd_play
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
        jmp wi_ratio
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
        jsr snd_play
        lda #WI_ST_DONE
        sta wi_state
        rts
.endp

;--------------------------------------------------------------
; wi_ratio -- states 2/4/6, X = which row. "cnt += 2; pistol every 4th tic;
;--------------------------------------------------------------
.proc wi_ratio
        stx wi_row
        jsr wi_pctof                 ; A = the row's true percentage
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
        jsr snd_play
?nosnd  ldx wi_row
        lda wi_cnt,x
        cmp wi_t
        bcc ?draw
        lda wi_t                     ; landed: clamp, bang, next state
        sta wi_cnt,x
        ldx #SFX_BAREXP
        jsr snd_play
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
        jsr snd_play
?not    clc                          ; cnt_time += 3, clamped at stime
        lda wi_ctime
        adc #3
        sta wi_ctime
        bcc ?t1
        inc wi_ctime+1
?t1     lda wi_ctime+1
        cmp wi_secs+1
        bcc ?par
        bne ?tclamp
        lda wi_ctime
        cmp wi_secs
        bcc ?par
?tclamp lda wi_secs
        sta wi_ctime
        lda wi_secs+1
        sta wi_ctime+1
?par    clc                          ; cnt_par += 3, clamped at partime
        lda wi_cpar
        adc #3
        sta wi_cpar
        bcc ?p1
        inc wi_cpar+1
?p1     lda wi_cpar+1
        cmp wi_parsec+1
        bcc ?draw
        bne ?pclamp
        lda wi_cpar
        cmp wi_parsec
        bcc ?draw
?pclamp lda wi_parsec                ; par has landed -- and time too?
        sta wi_cpar
        lda wi_parsec+1
        sta wi_cpar+1
        lda wi_ctime+1
        cmp wi_secs+1
        bne ?draw
        lda wi_ctime
        cmp wi_secs
        bne ?draw
        ldx #SFX_BAREXP
        jsr snd_play
        inc wi_sp
?draw   jmp wi_redraw
.endp

;--------------------------------------------------------------
; wi_finals -- acceleratestage: every counter to its final value at once.
;--------------------------------------------------------------
.proc wi_finals
        ldx #2
?r      stx wi_row
        jsr wi_pctof
        ldx wi_row
        sta wi_cnt,x
        dex
        bpl ?r
        lda wi_secs
        sta wi_ctime
        lda wi_secs+1
        sta wi_ctime+1
        lda wi_parsec
        sta wi_cpar
        lda wi_parsec+1
        sta wi_cpar+1
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
        sta wi_m
        lda #0
        sta wi_m+1
        asl wi_m
        rol wi_m+1                   ; *2
        asl wi_m
        rol wi_m+1                   ; *4
        lda wi_m
        sta wi_t3
        lda wi_m+1
        sta wi_t3+1                  ; keep *4
        asl wi_m
        rol wi_m+1                   ; *8
        asl wi_m
        rol wi_m+1                   ; *16
        asl wi_m
        rol wi_m+1                   ; *32
        clc
        lda wi_m
        adc wi_t3
        sta wi_t3
        lda wi_m+1
        adc wi_t3+1
        sta wi_t3+1                  ; *36
        asl wi_m
        rol wi_m+1                   ; *64
        clc
        lda wi_m
        adc wi_t3
        sta wi_m
        lda wi_m+1
        adc wi_t3+1
        sta wi_m+1                   ; *100
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
        sta wi_ix
        lda #0
        sta zp_ptr+1
        lda wi_ix
        asl
        rol zp_ptr+1
        asl
        rol zp_ptr+1
        asl
        rol zp_ptr+1                 ; index*8
        sec
        sbc wi_ix                    ; ...-index = *7
        bcs ?nb
        dec zp_ptr+1
?nb     clc
        adc #<WI_TAB
        sta zp_ptr
        lda zp_ptr+1
        adc #>WI_TAB
        sta zp_ptr+1
        rts
.endp

;--------------------------------------------------------------
; wi_put -- A = lump, X = column, Y = row. V_DrawPatch, through hud_blit --
;--------------------------------------------------------------
.proc wi_put
        stx wi_px
        sty wi_py
        jsr wi_entry
        ldx wi_px
        ldy wi_py
        jmp hud_blit
.endp

;--------------------------------------------------------------
; wi_slam -- WI_slamBackground + WI_drawLF: the background, the ten animations,
;--------------------------------------------------------------
.proc wi_slam
        lda #0
        sta wi_tmode
        jmp wi_slambg                ; ...whose anim pass tail-draws the whole
.endp                                ;   layer above it (wi_over: LF title +
                                     ;   the five labels)

;--------------------------------------------------------------
; wi_labels -- the five static rows of WI_drawStats. Drawn once: the per-tic
;--------------------------------------------------------------
.proc wi_labels
        lda #0
        sta wi_row
?l      ldx wi_row
        lda wi_rowy,x
        sta wi_arg
        lda wi_lblix,x
        ldx #WI_STATSX
        ldy wi_arg
        jsr wi_put
        inc wi_row
        lda wi_row
        cmp #3
        bne ?l
        lda #WI_I_TIME
        ldx #WI_TIMEX
        ldy #WI_TIMEY
        jsr wi_put
        lda #WI_I_PAR
        ldx #WI_PARX
        ldy #WI_TIMEY
        jmp wi_put
.endp

;--------------------------------------------------------------
; wi_redraw -- the animated half: three percentages and two times, each erased
;--------------------------------------------------------------
.proc wi_redraw
        lda #0
        sta wi_row
?l      ldx wi_row
        lda wi_rowy,x
        sta wi_py
        ldx #WI_PCTX-WI_FLDW
        ldy wi_py
        jsr wi_erase
        ldx wi_row
        lda wi_cnt,x
        bmi ?nx
        ldx #WI_PCTX                 ;      `if (p < 0) return`)
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
        ldx #WI_TIMEVX-WI_TFLDW
        ldy #WI_TIMEY
        jsr wi_erase.wi_erasew
        ldx #WI_PARVX-WI_TFLDW
        ldy #WI_TIMEY
        jsr wi_erase.wi_erasew
        lda wi_tvis
        beq ?out
        lda wi_ctime
        sta wi_cur
        lda wi_ctime+1
        sta wi_cur+1
        ldx #WI_TIMEVX
        ldy #WI_TIMEY
        jsr wi_dotime
        lda wi_cpar
        sta wi_cur
        lda wi_cpar+1
        sta wi_cur+1
        ldx #WI_PARVX
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
        stx wi_px
        sty wi_py
        ldx wi_py
        lda row_lo,x
        clc
        adc wi_px                    ;   the column is a plain add.
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR
        lda row_hi,x
        adc #>WI_VRAM
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+1  ; and threw the carry away -- and it
        lda #[WI_VRAM>>16]
        adc #0                       ;   the TIME row alone is +$6900, so
        sta MEMW+MEMW_HD_OFF+BCB_SRC_ADDR+2
        lda #SCREEN_WIDTH
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY
        lda #0
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPY+1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH+1
        lda #1
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        lda wi_ew
        sec
        sbc #1
        sta MEMW+MEMW_HD_OFF+BCB_WIDTH
        lda wi_eh
        sec
        sbc #1
        sta MEMW+MEMW_HD_OFF+BCB_HEIGHT
        lda row_lo,x
        clc
        adc wi_px
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+1
        lda #[VRAM_SCREEN>>16]
        sta MEMW+MEMW_HD_OFF+BCB_DST_ADDR+2
        lda #BLT_COPY                ; opaque: this IS the background
        sta MEMW+MEMW_HD_OFF+BCB_CTRL
        jsr hud_blit.hud_fire
        jmp blitter_wait
.endp

;--------------------------------------------------------------
; wi_num -- WI_drawNum(x, y, n, digits): digits right to left from x, leaving
;--------------------------------------------------------------
.proc wi_num
        stx wi_px
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
        bcc ?done
        sec
        sbc #10
        inx
        jmp ?d
?done   sta wi_arg                   ; the digit
        stx wi_n                     ; ...and what is left
        lda wi_px
        sec
        sbc #WI_NUMW
        sta wi_px
        lda wi_arg
        clc
        adc #WI_I_NUM0
        ldx wi_px
        ldy wi_py
        jsr wi_put
        dec wi_dig
        beq ?out
        lda wi_n
        jmp ?loop
?out    rts
.endp

;--------------------------------------------------------------
; wi_pct -- WI_drawPercent: the '%' AT x, then the digits leftwards from it.
;--------------------------------------------------------------
.proc wi_pct
        sta wi_n2
        stx wi_px
        sty wi_py
        lda #WI_I_PCNT
        jsr wi_put
        lda #$FF
        sta wi_dig
        lda wi_n2
        ldx wi_px
        ldy wi_py
        jmp wi_num
.endp

;--------------------------------------------------------------
; wi_dotime -- WI_drawTime(x, y, wi_cur): two digits, a colon, and the next
;--------------------------------------------------------------
.proc wi_dotime
        stx wi_px
        sty wi_py
        lda wi_cur+1                 ; > 3599 s? (61*59, wi_stuff.c:388)
        cmp #>3600
        bcc ?ok
        bne ?sucks
        lda wi_cur
        cmp #<3600
        bcc ?ok
?sucks  lda #WI_I_SUCKS
        ldx wi_px
        ldy wi_py
        jmp wi_put
?ok     lda wi_cur                   ; minutes = t/60, seconds = t mod 60
        sta wi_m
        lda wi_cur+1
        sta wi_m+1
        lda #60
        jsr wi_div16                 ; wi_m = minutes
        lda wi_m
        sta wi_mins
        jsr wi_mul60
        sec
        lda wi_cur
        sbc wi_m
        sta wi_arg
        lda #2
        sta wi_dig
        lda wi_arg
        ldx wi_px
        ldy wi_py
        jsr wi_num
        lda wi_px                    ; ...then the colon left of them
        sec
        sbc #WI_COLONW
        sta wi_px
        lda #WI_I_COLON
        ldx wi_px
        ldy wi_py
        jsr wi_put
        lda wi_mins
        beq ?out
        sta wi_n2
        lda #$FF
        sta wi_dig
        lda wi_n2
        ldx wi_px
        ldy wi_py
        jmp wi_num
?out    rts
.endp

;--------------------------------------------------------------
; wi_mul60 -- A -> wi_m = A*60 (= 32 + 16 + 8 + 4), for the seconds remainder.
;--------------------------------------------------------------
.proc wi_mul60
        sta wi_m
        lda #0
        sta wi_m+1
        asl wi_m
        rol wi_m+1
        asl wi_m
        rol wi_m+1                   ; *4
        lda wi_m
        sta wi_t3
        lda wi_m+1
        sta wi_t3+1
        asl wi_m
        rol wi_m+1                   ; *8
        clc
        lda wi_m
        adc wi_t3
        sta wi_t3
        lda wi_m+1
        adc wi_t3+1
        sta wi_t3+1                  ; *12
        asl wi_m
        rol wi_m+1                   ; *16
        clc
        lda wi_m
        adc wi_t3
        sta wi_t3
        lda wi_m+1
        adc wi_t3+1
        sta wi_t3+1                  ; *28
        asl wi_m
        rol wi_m+1                   ; *32
        clc
        lda wi_m
        adc wi_t3
        sta wi_m
        lda wi_m+1
        adc wi_t3+1
        sta wi_m+1                   ; *60
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
        lda #0
        sta wi_af
?draw   ldx current_level            ; epsd0animinfo is the only set packed, so
        lda wi_ebase,x               ;   only episode 1 has animations at all --
        bne wi_over                  ;   see wi_syms.inc. Episode 1 IS ebase 0.
        lda #0
        sta wi_ai
?l      ldy wi_ai
        lda wi_animy,y
        sta wi_arg
        lda wi_animx,y
        sta wi_arg+1
        lda wi_ai                    ; lump = ANIM0 + anim*ANIMF + frame
        asl
        clc
        adc wi_ai                    ; *3
        adc wi_af
        clc
        adc #WI_I_ANIM0
        ldx wi_arg+1
        ldy wi_arg
        jsr wi_put
        inc wi_ai
        lda wi_ai
        cmp #WI_ANIMS
        bne ?l
        jmp wi_over                  ; the anims just stamped their rectangles
?out    rts                          ;   OVER the once-drawn layer -- re-assert
.endp                                ;   all of it, not only the title

;--------------------------------------------------------------
; wi_over -- everything that lives ABOVE the animations, repainted after every
;   anim redraw. DOOM repaints the WHOLE screen each tic (WI_drawStats /
;   WI_drawShowNextLoc: background, anims, THEN labels/splats/pointer/title);
;   this port draws incrementally, and redrawing only the title here left the
;   rest to be eaten: anim 1 sits on E1M1's node and chewed its splat to an
;   outline (flak.png), anims 4/5 sit in the KILLS/SECRET labels. Order is
;   DOOM's: stats = LF title then labels; ENTERING = splats, pointer, EL
;   title LAST (it overlaps node 8's splat).
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
?ttl    jmp wi_title
.endp

;--------------------------------------------------------------
; wi_title -- the two title lines for whichever screen is up: WI_drawLF during
;--------------------------------------------------------------
.proc wi_title
        lda wi_tmode
        bne ?el
        ldx current_level            ; --- WI_drawLF
        lda wi_lvx,x
        sta wi_arg
        lda current_level
        clc
        adc #WI_I_LV0
        ldx wi_arg
        ldy #WI_TITLEY
        jsr wi_put
        ldx wi_finx
        lda #WI_I_FINISH
        ldy #WI_LFY2
        jmp wi_put
?el     lda #WI_I_ENTER              ; --- WI_drawEL
        ldx wi_entx
        ldy #WI_TITLEY
        jsr wi_put
        ldx wi_next
        lda wi_lvx,x
        sta wi_arg
        lda wi_next
        clc
        adc #WI_I_LV0
        ldx wi_arg
        ldy #WI_LFY2
        jmp wi_put
.endp

;==============================================================
; ShowNextLoc (:752) then NoState (:730) -- the world map with a splat on every
;==============================================================
.proc wi_nextloc
        lda #1
        sta wi_tmode
        jsr wi_slambg                ; the map again, over the tally -- and its
                                     ;   anim pass tail-draws the whole ABOVE
                                     ;   layer (wi_over: splats + EL title;
                                     ;   wi_yon is still 0 here)
        lda #0                       ; cnt = SHOWNEXTLOCDELAY * TICRATE
        sta wi_accelst
        sta wi_yon
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
        lda wi_cnt16                 ; --cnt
        bne ?d1
        dec wi_cnt16+1
?d1     dec wi_cnt16
        lda wi_cnt16
        ora wi_cnt16+1
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
        sec
        sbc #1
?have   clc
        adc wi_ai                    ; ...so stop at ebase + last, INCLUSIVE
        sta wi_arg+1                 ;   (wi_stuff.c:793 is i <= last)
?sp     ldx wi_ai
        lda wi_nodey,x
        sta wi_arg
        ldx wi_ai
        lda wi_nodex,x
        tax
        lda #WI_I_SPLAT
        ldy wi_arg
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
        lda wi_nodey,x
        sta wi_arg
        lda wi_nodex,x
        tax
        lda #WI_I_YAH0
        ldy wi_arg
        jmp wi_put
.endp

;--------------------------------------------------------------
; wi_yah -- A = 1 to show the "YOU ARE HERE" pointer on the next level's node,
;--------------------------------------------------------------
.proc wi_yah
        cmp wi_yon
        beq ?out
        sta wi_yon
        lda wi_yon                   ; (sta keeps the cmp's flags -- refresh)
        bne wi_yahput
        ldx wi_next                  ; OFF: erase its box back to the map
        lda wi_nodey,x
        sta wi_arg
        ldx wi_next
        lda wi_nodex,x
        tax
        lda #WI_YAHW
        sta wi_ew
        lda #WI_YAHH
        sta wi_eh
        txa
        clc
        adc #WI_YAHDX
        tax
        lda wi_arg
        sec
        sbc #WI_YAHDY
        tay
        jmp wi_erase.wi_erasew
?out    rts
.endp

;--------------------------------------------------------------
; wi_slambg -- background + animations, no title lines: WI_slamBackground.
;--------------------------------------------------------------
.proc wi_slambg
        lda #BLT_COPY
        sta hb_ctrl
        lda #WI_I_BG
        ldx #0
        ldy #0
        jsr wi_put
        lda #BLT_BSTENCIL
        sta hb_ctrl
        lda #0
        sta wi_bcnt
        sta wi_anext                 ;   all ten over the fresh background
        jmp wi_anim
.endp

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
                                     ;   be released first (DOOM's attackdown/
                                     ;   usedown gate) -- 1 let it slam the
                                     ;   tally on the very first tic
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
wi_px       dta 0
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
; They live down HERE, past stage 2's guard, and not behind an `org`-and-back in
; the middle of it: stage 2 is assembled at its run address with no parking
; address of its own, so a detour splits its single $4100 segment in two and
; tools/split_menu_ovl.py only lifts the half that starts there -- the other
; half then lands in the map slot and check_xex.py stops the build.
;==============================================================
        org WIPCT_BASE
.proc wi_pctof
        lda wi_max,x
        beq ?none
        sta wi_t2
        lda wi_val,x
        jsr wi_mul100
        lda wi_t2
        jsr wi_div16
        lda wi_m
        rts
?none   lda #100
        rts
.endp
    .if * > WIPCT_END+1
        ert 'wi_pctof outgrew WIPCT_BASE..END (memory_map.inc)'
    .endif

        org WIDIV_BASE
.proc wi_div16
        sta wi_d
        lda #0
        ldx #16
?l      asl wi_m
        rol wi_m+1
        rol
        bcs ?sub
        cmp wi_d
        bcc ?next
?sub    sec
        sbc wi_d
        inc wi_m                     ; quotient bit
?next   dex
        bne ?l
        rts
.endp
    .if * > WIDIV_END+1
        ert 'wi_div16 outgrew WIDIV_BASE..END (memory_map.inc)'
    .endif
