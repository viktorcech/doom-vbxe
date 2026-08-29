; Part of bsp_main.asm -- AUTO-SPLIT out of it 2026-08-09, assembled in place via
; icl at the exact point the text was cut from, so every org and every block
; guard below is unchanged (verified: build/doom_bsp.xex is byte-identical).
;   VBXE + framebuffer bring-up: detect_vbxe, setup_memac/xdl/palette/bcbs/chains, clear_screen, draw_vspan, blitter_wait
;==============================================================
; detect_vbxe -- C clear if found (base $D600 only)
;==============================================================
.proc detect_vbxe
        lda VBXE_VCTL                ; CORE_VERSION read
        cmp #CORE_FX_1XX
        beq ?ok
        sec
        rts
?ok     clc
        rts
.endp

;==============================================================
; setup_memac -- MEMAC-A 4K window at MEMW, CPU access, bank $0A
;==============================================================
.proc setup_memac
        lda #MEMW_HI | MC_CPU | MC_4K
        sta VBXE_MEMAC_CTL
        lda #0
        sta VBXE_MEMAC_B
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp

;==============================================================
; setup_xdl -- copy XDL into VRAM (via window), point VBXE at it
;==============================================================
.proc setup_xdl
        lda #0
        sta VBXE_VCTL
        jmp xdl_build                ; xdl.asm: the two stretched lists, into
                                     ;   VBXE banks $08/$09. This used to copy
                                     ;   28 bytes of xdl_data into the overhead
                                     ;   bank and describe 200 of the screen's
                                     ;   240 lines -- the other 40 were the
                                     ;   black band under everything.
.endp

xdlstg_resume = *
        org XDLSTAGE_BASE            ; the builder + its 650-byte list ride in
        icl 'xdl.asm'                ;   the SIO staging buffer: boot-only code
        org xdlstg_resume            ;   in RAM the loaders take back afterwards

; The two-entry list that used to live here (rows 0-167 from the front buffer,
; rows 168-199 always from the shared bar) is xdl.asm now: same split, but 81
; entries instead of 2, because the picture is stretched to the full 240 PAL
; lines. It is also built TWICE, so the flip is a store to VBXE_XDLA1 rather
; than a poke into one entry -- see swap_buffers and the header over there.

;==============================================================
; setup_palette -- A = VBXE palette index (0..3): install the 256 colours now in
;   the staging buffer (MAP_PLAYPAL) into it. Format v2: the framebuffer holds
;   real PLAYPAL indices (texture pixels + flat-colour indices), so a whole
;   palette goes down at once. CB write commits a colour and advances CSEL.
;   Called PAL_COUNT times by load_palette -- DOOM's damage/pickup tints are
;   further slots of the same lump and live in VBXE's other palettes, so the
;   flash is an XDL byte instead of an upload (see the PALETTE FLASH block in
;   memory_map.inc).
;==============================================================
.proc setup_palette
        sta VBXE_PSEL
        lda #0
        sta VBXE_CSEL
        lda #<MAP_PLAYPAL
        sta zp_ptr
        lda #>MAP_PLAYPAL
        sta zp_ptr+1
        ldx #0                       ; 256 entries
?lp     ldy #0
        lda (zp_ptr),y
        sta VBXE_CR
        iny
        lda (zp_ptr),y
        sta VBXE_CG
        iny
        lda (zp_ptr),y
        sta VBXE_CB                  ; commit, advances CSEL
        lda zp_ptr                   ; ptr += 3
        clc
        adc #3
        sta zp_ptr
        bcc ?nc
        inc zp_ptr+1
?nc     inx
        bne ?lp                      ; 256 iterations (X wraps 255->0)
        rts
.endp

;==============================================================
; setup_bcbs -- upload the vline + clear BCB templates to VRAM
;==============================================================
.proc setup_bcbs
        ldx #BCB_SIZE-1
?vl     lda bcb_vline_tmpl,x
        sta MEMW+MEMW_VL_OFF,x
        dex
        bpl ?vl
        ldx #BCB_SIZE-1
?cl     lda bcb_clear_tmpl,x
        sta MEMW+MEMW_CL_OFF,x
        dex
        bpl ?cl
        ldx #BCB_SIZE-1
?tw     lda bcb_twall_tmpl,x
        sta MEMW+MEMW_TW_OFF,x
        dex
        bpl ?tw
        ldx #BCB_SIZE-1
?t8     lda bcb_tex8_tmpl,x
        sta MEMW+MEMW_T8_OFF,x
        dex
        bpl ?t8
        ldx #BCB_SIZE-1
?sp     lda bcb_spr_tmpl,x           ; sprite column (byte-stencil transparency)
        sta MEMW+MEMW_SP_OFF,x
        dex
        bpl ?sp
        ldx #BCB_SIZE-1
?hd     lda bcb_spr_tmpl,x           ; the HUD blit starts from the same template
        sta MEMW+MEMW_HD_OFF,x       ; (width/step/ctrl are patched per graphic)
        dex
        bpl ?hd
        lda #1                       ; ... but walks the source row by row
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
        jmp setup_chains             ; prefill the two column-chain buffers
                                     ; (tw_lastsrc = $FF "scratch holds nothing"
                                     ;  went with the expander cache 2026-08-14)
.endp

;--------------------------------------------------------------
; setup_chains -- prefill BOTH chain buffers: slot 0 from the expander
;   template (the sprite path's, tw_expand), slots 1..TW_MAXLINKS-1 from the
;   VLINE FILL template with CTRL pre-chained -- the painter's emit (pt_span)
;   then writes only dst lo/hi, height and colour per span, and ptc_fire's
;   terminator is the only CTRL byte that ever changes again.
;   Also builds the 2-BCB "zback stamp" chain at VRAM_BCB_VLINE+21/+42: one
;   fill per buffer, dst step 21, that writes zback_hi into every slot's DST
;   bank byte -- fired once per frame by ptc_frame instead of a 94-store CPU
;   loop through the slow window.
;   BOOT-ONLY, so it is parked in the staged $4000-$4BFF area (SETCHN_BASE):
;   setup_bcbs calls it long before the first load_level stream reclaims the
;   region. (Its old $BC10 home is ptc_frame's now -- per-frame code.)
;--------------------------------------------------------------
setchn_resume = *
        org SETCHN_BASE
.proc setup_chains
        lda #0
        sta ZFRONT                   ; triple-buffer flip state (2026-08-11):
        sta FRM_PAR                  ;   the XDL boots showing A, no publish
        sta XDLA_PEND                ;   pending, fuzz frame parity "even" --
                                     ;   zeroed HERE (boot-only, runs long
                                     ;   before urom_init arms rom_nmi)
        sta ptm_last                 ; pt_mul memo = 0 = pt_dy's ASSEMBLED bake
        sta ptm_last+1               ;   (paint.asm; PAINT_VARS is random at boot)
        sta zp_ptr
        lda #>[MEMW+MEMW_CHA_OFF]
        sta zp_ptr+1
        jsr ?one
        lda #0
        sta zp_ptr
        lda #>[MEMW+MEMW_CHB_OFF]
        sta zp_ptr+1
        jsr ?one
    .if !TEX_RUNS
        rts                          ; the blit path patches CTRL per link itself
    .endif
        ; ---- the zback stamp chain (two vline fills, patched below) ---------
        ldx #BCB_SIZE-1
?st     lda bcb_vline_tmpl,x
        sta MEMW+MEMW_VL_OFF+BCB_SIZE,x
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE,x
        dex
        bpl ?st
        lda #BCB_SIZE+BCB_DST_ADDR+2 ; -> slot 1's DST bank byte...
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_DST_ADDR
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE+BCB_DST_ADDR
        lda #>VRAM_BCB_CHA           ; ... of chain buffer A / B
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_DST_ADDR+1
        lda #>VRAM_BCB_CHB
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE+BCB_DST_ADDR+1
        lda #BCB_SIZE                ; dst step = 21: next slot's bank byte
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_DST_STEPY
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE+BCB_DST_STEPY
        lda #PT_LINKS-1              ; HEIGHT-1: all 47 painter slots
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_HEIGHT
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE+BCB_HEIGHT
        lda #BLT_COPY|BLT_NEXT       ; A chains to B; B's template CTRL ends it
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_CTRL
        rts
?one    ldy #BCB_SIZE-1
?s0     lda bcb_tex8_tmpl,y
        sta (zp_ptr),y
        dey
        bpl ?s0
        ldx #TW_MAXLINKS-1
?slot   clc
        lda zp_ptr
        adc #BCB_SIZE
        sta zp_ptr
        bcc ?nc
        inc zp_ptr+1
?nc     ldy #BCB_SIZE-1
    .if TEX_RUNS
?cp     lda bcb_vline_tmpl,y
        sta (zp_ptr),y
        dey
        bpl ?cp
        ldy #BCB_CTRL                ; provisionally chained; only ptc_fire's
        lda #BLT_COPY|BLT_NEXT       ;   terminator ever clears the bit (and
        sta (zp_ptr),y               ;   re-arms it on the next fire)
    .else
?cp     lda bcb_twall_tmpl,y
        sta (zp_ptr),y
        dey
        bpl ?cp
    .endif
        dex
        bne ?slot
        rts
.endp
    .if * > SETCHN_END+1
        ert 'setup_chains outgrew SETCHN_BASE..END (memory_map.inc)'
    .endif
        org setchn_resume

;--------------------------------------------------------------
; ptc_frame -- frame entry (render_world calls it where spr_reset used to sit;
;   it tail-jmps there). Stamps THIS frame's zback_hi into every chain slot's
;   DST bank byte by firing the 2-BCB chain setup_chains built -- the CPU
;   writes just the two fill colours -- then resets the builder (ptc_open).
;   The first ptc_fire of the frame waits for the blitter anyway, so the
;   stamp is ordered before any painted span by construction.
;--------------------------------------------------------------
    .if TEX_RUNS
pfr_resume = *
        org PTCFRAME_BASE
.proc ptc_frame
        jsr ptc_stamp                ; the chain's DST-bank stamp -- and the
                                     ;   MEMAC window pointed at the BCBs FIRST
                                     ;   (PTCSTAMP_BASE, memory_map.inc)
        jsr blitter_wait             ; a menu/hud blit can still be running --
                                     ;   and `lda BL_BUSY / bne` is NOT proof it
                                     ;   is done. BUSY (D1) drops between chained
                                     ;   BCB fetches (vbxe.cpp IsBlitterActive is
                                     ;   false while a BCB is read in), so the
                                     ;   single-read spin that used to be here
                                     ;   could fall through MID-CHAIN. The
                                     ;   BL_START below is then IGNORED -- "if the
                                     ;   blitter is already running, trying to set
                                     ;   this bit again does nothing"
                                     ;   (vbxe.cpp:1346) -- so the DST-BANK STAMP
                                     ;   never runs, all 94 painter slots keep the
                                     ;   PREVIOUS frame's zback_hi, and every span
                                     ;   of this frame lands in the buffer nobody
                                     ;   is looking at. What is left on screen is
                                     ;   whatever that buffer held: the sporadic
                                     ;   garbage bands while walking (2026-08-27).
                                     ;   Same failure ptc_go and ptc_stamp were
                                     ;   fixed for on 2026-08-26; this poll was
                                     ;   missed, and it is the one that corrupts a
                                     ;   WHOLE frame rather than one chain.
                                     ;   blitw_hard's four zero reads are the
                                     ;   proof. It eats X -- free here, the frame
                                     ;   entry has no live index.
        lda #<[VRAM_BCB_VLINE+BCB_SIZE]
        sta VBXE_BL_ADR0
        lda #>[VRAM_BCB_VLINE+BCB_SIZE]
        sta VBXE_BL_ADR1             ; ADR2 is 0 for good (see ptc_tail)
        lda #1
        sta VBXE_BL_START            ; async -- overlaps the BSP walk's start
        jsr ptc_open
        jmp spr_reset
.endp
    .if * > PTCFRAME_END+1
        ert 'ptc_frame outgrew PTCFRAME_BASE..END (memory_map.inc)'
    .endif
        org pfr_resume
    .endif                           ; TEX_RUNS (ptc_frame)

;==============================================================
; clear_screen -- fill whole framebuffer with colour in A
;==============================================================
.proc clear_screen
        sta MEMW+MEMW_CL_OFF+BCB_XOR
        lda zback_hi                 ; clear the BACK buffer
        sta MEMW+MEMW_CL_OFF+BCB_DST_ADDR+2
        jsr blitter_wait
        lda #<VRAM_BCB_CLEAR
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_CLEAR
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_CLEAR>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START
        jmp blitter_wait
.endp

;--------------------------------------------------------------
; ptc_stamp -- ptc_frame's first act: stamp THIS frame's zback_hi into the two
;   chain slots' DST bank byte.
;   IT POINTS THE MEMAC WINDOW ITSELF, and that is the whole point. The stores
;   go through MEMW, and every other MEMW writer in this port sets the bank
;   first (mn_open, xdl_att, load_vram, mn_freeze) -- ptc_frame alone assumed
;   the window was still on the overhead bank. The MENU and the AUTOMAP both
;   move it (automap.asm repoints it per column at the back buffer), so on the
;   way out of an overlay the stamp landed in a foreign VRAM bank: the chain
;   kept the PREVIOUS frame's DST bank and every wall span went to a buffer
;   nobody was looking at. Sprites go through spr_blit, not the chain -- which
;   is why they were the only thing left on screen, and with the walls gone
;   nothing occluded, so am_mark lit the whole automap and ai_wake woke the
;   level (2026-08-26, 6.jpg: solid_arr had 88 of 160 columns CLOSED, i.e. the
;   walk HAD run and drawn -- the blits went nowhere).
;   Out here because PTCFRAME_END ($BC47) was stale by 21 B: the block really
;   ends at $BC32 and check_xex caught the overlap.
;--------------------------------------------------------------
ptcs_resume = *
        org PTCSTAMP_BASE
.proc ptc_stamp
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        lda zback_hi
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_XOR
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE+BCB_XOR
        rts
.endp
    .if * > PTCSTAMP_END+1
        ert 'ptc_stamp outgrew PTCSTAMP_BASE..END (memory_map.inc)'
    .endif
        org ptcs_resume

;==============================================================
; draw_vspan -- one vertical span via bcb_vline
;   X = column (0..159), A = top row, Y = height (>=1), zp_color = colour
;   dst = VRAM_SCREEN + top*SCREEN_WIDTH + col
;==============================================================
; 2026-08-10: with TEX_RUNS the routine is GONE -- every span (wall runs and
; flats alike) is a chain link now, emitted by pt_span (paint.asm; draw_span
; jmps straight there) and launched in batches by ptc_fire (textures.asm).
; What lives in its bytes instead is the chain plumbing that has no other home:
    .if TEX_RUNS
;--------------------------------------------------------------
; ptc_tail -- the launch every chain shares: A = BL_ADR0 (the chain's first
;   slot's low byte -- 21 for the painter, 0 for the sprite expander), the
;   VRAM mid byte comes from tw_chn, ADR2 is 0 for good (every BCB this port
;   owns sits in the $00Axxx overhead bank). Fires, then flips tw_chn so the
;   next chain builds in the other buffer while this one runs. Clobbers A.
;--------------------------------------------------------------
.proc ptc_tail
        sta VBXE_BL_ADR0
        lda tw_chn                   ; $97/$9B window page -> $A7/$AB VRAM page
        clc
        adc #[>VRAM_OVERHEAD]-[>MEMW]
        sta VBXE_BL_ADR1
        jmp ptc_go                   ; ...and the launch itself, which has to WAIT
.endp                                ;   (PTCGO_BASE, memory_map.inc)

;--------------------------------------------------------------
; ptc_go -- ptc_tail's tail: wait for the blitter, launch, flip the builder.
;   THE WAIT IS THE POINT. From Altirra's own VBXE emulation (vbxe.cpp:1338,
;   BLITTER_START): 'Note that if the blitter is already running, trying to
;   set this bit again does nothing' -- `if (!IsBlitterActive())`. So a chain
;   fired while the previous blit is still going is SILENTLY DROPPED; the
;   address registers take the new list and the blitter keeps running the old
;   one. ptc_frame already waits ('a menu/hud blit can still be running') and
;   spr_blit waits, but ptc_tail did not.
;   What that cost: closing the ESC panel or the automap leaves mn_freeze's
;   full-screen copy and clear_screen's 26 KB fill running for the best part
;   of a second, and every wall chain fired in that window was thrown away.
;   The walk still ran (solid_arr had 88 of 160 columns CLOSED) and the
;   sprites still appeared, because they wait -- so the player got a second of
;   sprites floating in the dark, no walls, the whole automap revealed and
;   every monster awake, since nothing was left to occlude (2026-08-26, 6.jpg).
;   The overlap the old code was after is not lost: the wait is five cycles
;   when the blitter is idle, and when it is NOT idle the alternative was
;   losing the chain outright.
;   IT MUST BE blitter_wait AND NOT A LONE `lda BL_BUSY / bne`. BL_BUSY has two
;   bits -- D1 BUSY, D0 BCB_LOAD -- and Altirra's IsBlitterActive() is FALSE
;   while the blitter is reading the next BCB ('only active if it is actually
;   running a bit, not while reading in a new BCB', vbxe.cpp:2094). So BUSY
;   blinks off between chained entries, and a single clean read would fire
;   mid-chain and take mBlitListFetchAddr with it. blitw_hard demands four
;   zero reads in a row for exactly that reason -- its own comment says so.
;--------------------------------------------------------------
ptcgo_resume = *
        org PTCGO_BASE
.proc ptc_go
        phx                          ; blitw_hard eats X, and ptc_tail's callers
        jsr blitter_wait             ;   rely on it surviving (paint.asm)
        plx
        lda #1
        sta VBXE_BL_START
        lda tw_chn                   ; build the NEXT chain in the other buffer
        eor #[>[MEMW+MEMW_CHA_OFF]]^[>[MEMW+MEMW_CHB_OFF]]
        sta tw_chn
        rts
.endp
    .if * > PTCGO_END+1
        ert 'ptc_go outgrew PTCGO_BASE..END (memory_map.inc)'
    .endif
        org ptcgo_resume

;--------------------------------------------------------------
; spr_chfire -- launch the sprite path's 8x-expander chain: slot 0 alone,
;   already TERMINATED (tw_expand writes CTRL = BLT_COPY with TEX_RUNS -- no
;   runs ever follow it). tw_x1st = 0 means tw_expand really queued one; a
;   cache hit leaves it nonzero and there is nothing to fire. The painter's
;   chains are all closed by now (ptc_fbg fired the last one before sprites),
;   so flipping tw_chn here keeps both users on the same selector. Clobbers A.
;--------------------------------------------------------------
.proc spr_chfire
        lda tw_x1st
        bne ?skip
        phx                          ; the previous chain/blit must finish first --
        jsr blitter_wait             ;   and it MUST be blitw_hard, not a lone
        plx                          ;   `lda BL_BUSY / bne`: BUSY blinks off
                                     ;   between chained BCB fetches, so a single
                                     ;   clean read fires MID-CHAIN and takes the
                                     ;   painter's mBlitListFetchAddr with it (the
                                     ;   note above ptc_go says exactly this).
                                     ;   The window is real here: bg_fill's
                                     ;   ptc_fire_wait only runs when the walk
                                     ;   left a GAP, so a view fully covered by
                                     ;   walls reaches this poll with the
                                     ;   painter's last chain still running.
                                     ;   Same 5 bytes; blitw_hard eats X, hence
                                     ;   the phx/plx (as ptc_go does).
        lda #0                       ; the expander chain starts at slot 0
        jsr ptc_tail
        lda #BCB_SIZE                ; re-arm the flag for the next call
        sta tw_x1st
?skip   rts
.endp

;--------------------------------------------------------------
; ptc_fire_wait -- close + launch the open painter chain (if any), then wait
;   for the blitter: the drop-in for `jsr blitter_wait` at every site that is
;   about to READ what the chain paints or repatch a shared BCB (cm_flush's
;   copy, bg_blit's fill).
; ptc_fbg -- the render_world seam: the walk is done, fire what is left, then
;   bg_fill as before (its bg_blit calls go through ptc_fire_wait themselves).
;--------------------------------------------------------------
.proc ptc_fire_wait
        jsr ptc_fire
        jmp blitter_wait
.endp
.proc ptc_fbg
        jsr ptc_fire
        jmp bg_fill
.endp
    .else                            ; !TEX_RUNS: the shared-BCB span submit
; 2026-06-03: ASYNC blitter (tips.txt #1). The previous version spun in a 2nd
; blitter_wait after BL_START while VBXE filled -- pure idle. Now we wait ONCE at
; the TOP (sync the previous blit before re-patching the shared BCB), fire, and
; RETURN immediately. The CPU then computes the next column's 24-bit math IN
; PARALLEL with VBXE drawing the current one; the next call's top-wait re-syncs.
; (swap_buffers does a final blitter_wait before flipping the displayed buffer.)
.proc draw_vspan
        stx zp_savex                 ; preserve caller's X (loop counter)
        tax                          ; top row -> row table index. (It used to go
                                     ;   through zp_tmp "before blitter_wait
                                     ;   clobbers A"; the wait moved down to
                                     ;   BL_START years ago and A is long gone
                                     ;   by then, so the detour was dead weight.)
        ; The wait used to sit HERE, so the ~7 slow window writes below happened
        ; with the CPU already idle. The blitter latches the whole BCB at
        ; BL_START (tw_blit relies on the same guarantee), so the patching is
        ; safe while the previous blit runs -- wait immediately before the start
        ; instead and the patch overlaps it.
        lda row_lo,x
        clc
        adc zp_col
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR
        lda row_hi,x
        adc #0
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR+1
        lda zback_hi                 ; back buffer (double-buffered)
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR+2
        ; tips #3: BCB width (1 px) is set once by setup_bcbs and never changes;
        ;   the blitter doesn't write it back, so re-patching it per column was dead.
        dey                          ; height-1
        tya
        sta MEMW+MEMW_VL_OFF+BCB_HEIGHT
        lda zp_color
        sta MEMW+MEMW_VL_OFF+BCB_XOR
?bw     lda VBXE_BL_BUSY             ; a START while busy is silently dropped.
        bne ?bw                      ;   Inlined (see pt_span): the call frame
                                     ;   around two instructions was 12 of the
                                     ;   105 cycles this routine cost.
        lda #<VRAM_BCB_VLINE
        sta VBXE_BL_ADR0
        lda #>VRAM_BCB_VLINE
        sta VBXE_BL_ADR1
        lda #[VRAM_BCB_VLINE>>16]
        sta VBXE_BL_ADR2
        lda #1
        sta VBXE_BL_START            ; fire and RETURN (overlap with CPU math)
        ldx zp_savex                 ; restore caller's X
        rts
.endp
    .endif                           ; TEX_RUNS

;==============================================================
; blitter_wait -- spin until idle
;==============================================================
.proc blitter_wait
        jmp blitw_hard               ; hardened wait (BLITW_BASE, 2026-08-11)
.endp
blw_resume = *
        org BLITW_BASE
.proc blitw_hard
?ag     ldx #4                       ; BUSY must read 0 FOUR times in a row: the
?ck     lda VBXE_BL_BUSY             ;   FX core can drop BUSY for an instant
        bne ?ag                      ;   between chained BCB fetches, and a
        dex                          ;   single clean read let swap publish a
        bne ?ck                      ;   frame whose last ceiling chains (the
        rts                          ;   TOP rows: the farthest walls draw last)
.endp                                ;   were still being blitted -- the old
                                     ;   VBLANK spin used to mask exactly this
    .if * > BLITW_END+1
        ert 'blitw_hard outgrew BLITW_BASE..END (memory_map.inc)'
    .endif
        org blw_resume

