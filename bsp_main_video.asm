;--------------------------------------------------------------
; Part of bsp_main.asm (icl in place): VBXE + framebuffer bring-up.
;--------------------------------------------------------------
; detect_vbxe -- C clear if found (base $D600 only)
;--------------------------------------------------------------
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
                                      ; DRAC_PLAN 3b: 16 KB window
        lda #MEMW_HI | MC_CPU | MC_16K
        sta VBXE_MEMAC_CTL
        stz VBXE_MEMAC_B
                                      ; 2026-09-22 (drac030 RELOAD): A = the MEMAC_CTL value, the same byte
        ert [MEMW_HI|MC_CPU|MC_16K]<>[BANK_EN|BANK_OVERHEAD]
        sta VBXE_BANK_SEL
        rts
.endp

;==============================================================
; setup_xdl -- copy XDL into VRAM (via window), point VBXE at it
;==============================================================
.proc setup_xdl
        stz VBXE_VCTL
        jmp xdl_build
                                     ;   VBXE banks $08/$09.
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
;==============================================================
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc setup_palette
        sta VBXE_PSEL
        stz VBXE_CSEL
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
        .endseg

;==============================================================
; setup_bcbs -- upload the vline + clear BCB templates to VRAM
;==============================================================
.proc setup_bcbs
                                      ; 2026-09-22 (rapidus-bus-timing): long,x -- an abs,x
        ldx #BCB_SIZE-1              ;   store dummy-reads the MEMAC window first, a
?vl     lda bcb_vline_tmpl,x         ;   whole chip cycle per byte
        sta.l MEMW+MEMW_VL_OFF,x
        dex
        bpl ?vl
        ldx #BCB_SIZE-1
?cl     lda bcb_clear_tmpl,x
        sta.l MEMW+MEMW_CL_OFF,x
        dex
        bpl ?cl
        ldx #BCB_SIZE-1
?tw     lda bcb_twall_tmpl,x
        sta.l MEMW+MEMW_TW_OFF,x
        dex
        bpl ?tw
        ldx #BCB_SIZE-1
?t8     lda bcb_tex8_tmpl,x
        sta.l MEMW+MEMW_T8_OFF,x
        dex
        bpl ?t8
        ldx #BCB_SIZE-1
?sp     lda bcb_spr_tmpl,x           ; sprite column (byte-stencil transparency)
        sta.l MEMW+MEMW_SP_OFF,x
        dex
        bpl ?sp
        ldx #BCB_SIZE-1
?hd     lda bcb_spr_tmpl,x           ; the HUD blit starts from the same template
        sta.l MEMW+MEMW_HD_OFF,x     ; (width/step/ctrl are patched per graphic)
        dex
        bpl ?hd
        lda #1                       ; ... but walks the source row by row
        sta MEMW+MEMW_HD_OFF+BCB_SRC_STEPX
                                      ; 2026-09-22 (vbxe-blitter: templates): bg_blit's
        lda #BG_COLOUR               ;   fill colour, once -- it was stored per blit
        sta MEMW+MEMW_VL_OFF+BCB_XOR ;   (emulation mode here: 8-bit stores only)
        jmp setup_chains             ; prefill the two column-chain buffers
                                     ; (tw_lastsrc = $FF "scratch holds nothing"
                                     ;  went with the expander cache 2026-08-14)
.endp

;--------------------------------------------------------------
; setup_chains -- prefill BOTH chain buffers: slot 0 from the expander
;   template (the sprite path's, tw_expand), slots 1..TW_MAXLINKS-1 from the
;   VLINE FILL template with CTRL pre-chained -- the painter's emit (pt_span)
;--------------------------------------------------------------
setchn_resume = *
        org SETCHN_BASE
.proc setup_chains
        stz ZFRONT                   ; triple-buffer flip state (2026-08-11):
        stz FRM_PAR                  ;   the XDL boots showing A, no publish
        stz XDLA_PEND                ;   pending, fuzz frame parity "even" --
                                     ;   zeroed HERE (boot-only, runs long
                                     ;   before urom_init arms rom_nmi)
        stz ptm_last                 ; paint_col's memo = 0 = the ASSEMBLED bake
        stz ptm_last+1               ;   (paint.asm; PAINT_VARS is random at boot)
                                     ; 2026-09-22 (rapidus-bus-timing): the prefill
        stz zp_savex                 ;   writes the window through [zp_tsrc],y (bank
        stz zp_tsrc                  ;   byte 0): a (dp),y store dummy-reads it first
        lda #>[MEMW+MEMW_CHA_OFF]
        sta zp_tsrc+1
        jsr ?one
        stz zp_tsrc
        lda #>[MEMW+MEMW_CHB_OFF]
        sta zp_tsrc+1                ; (2026-09-22: ?one walks zp_tsrc now)
        jsr ?one
    .if !TEX_RUNS
        rts                          ; the blit path patches CTRL per link itself
    .endif
        ; ---- the zback stamp chain (two vline fills, patched below) ---------
        ldx #BCB_SIZE-1
?st     lda bcb_vline_tmpl,x
                                      ; 2026-09-22: long,x -- no dummy read of the window
        sta.l MEMW+MEMW_VL_OFF+BCB_SIZE,x
        sta.l MEMW+MEMW_VL_OFF+2*BCB_SIZE,x
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
        rts                          ; (the $FF source byte + pc_colw+1: ptc_stamp,
                                     ;  bank $01 -- this bank-0 hole ends at $4B9E)
                                      ; 2026-09-22: [zp_tsrc],y -- no dummy read of the
?one    ldy #BCB_SIZE-1              ;   window before each store (see setup_chains)
?s0     lda bcb_tex8_tmpl,y
        sta [zp_tsrc],y
        dey
        bpl ?s0
        ldx #TW_MAXLINKS-1
?slot   clc
        lda zp_tsrc
        adc #BCB_SIZE
        sta zp_tsrc
        bcc ?nc
        inc zp_tsrc+1
?nc     ldy #BCB_SIZE-1
    .if TEX_RUNS
?cp     lda bcb_vline_tmpl,y
        sta [zp_tsrc],y
        dey
        bpl ?cp
        ldy #BCB_CTRL                ; provisionally chained; only ptc_fire's
        lda #BLT_COPY|BLT_NEXT       ;   terminator ever clears the bit (and
        sta [zp_tsrc],y              ;   re-arms it on the next fire)
    .else
?cp     lda bcb_twall_tmpl,y
        sta [zp_tsrc],y
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
;--------------------------------------------------------------
    .if TEX_RUNS
pfr_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ptc_frame
        jsr ptc_stamp                ; the chain's DST-bank stamp -- and the
                                     ;   MEMAC window pointed at the BCBs FIRST
                                     ;   (PTCSTAMP_BASE, memory_map.inc)
        jsr blitw_hard               ; a menu/hud blit can still be running --
                                     ;   and `lda BL_BUSY / bne` is NOT proof it
                                     ;   is done.
        lda #<[VRAM_BCB_VLINE+BCB_SIZE]
        sta VBXE_BL_ADR0
        lda #>[VRAM_BCB_VLINE+BCB_SIZE]
        sta VBXE_BL_ADR1             ; ADR2 is 0 for good (see ptc_tail)
        lda #1
        sta VBXE_BL_START            ; async -- overlaps the BSP walk's start
                                      ; 2026-09-22 (vbxe-blitter: write only what changes):
        lda zback_hi                 ;   the one field of the sprite and bg-fill BCBs that
        sta MEMW+MEMW_SP_OFF+BCB_DST_ADDR+2   ;   changes per FRAME, not per blit (spr_blit
        sta MEMW+MEMW_VL_OFF+BCB_DST_ADDR+2   ;   and bg_blit write DST lo/mid only). The
        jsr ptc_open
                                      ; 2026-09-22 idiom: spr_reset inlined (the tail jmp
        stz sp_n                     ;   went: -3)
        stz sp_clip
        lda #>CLIP_BASE
        sta sp_clip+1
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org pfr_resume
    .endif                           ; TEX_RUNS (ptc_frame)

;==============================================================
; clear_screen -- fill whole framebuffer with colour in A
;==============================================================
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc clear_screen
                                      ; 2026-09-22 (vbxe-blitter: fire early, wait late):
        pha                          ;   WAIT FIRST -- a running clear still reads this
        jsr blitw_hard               ;   BCB (not latched on real VBXE, cm_flush) --
        pla                          ;   then patch, fire and RETURN. The spin that sat
        sta MEMW+MEMW_CL_OFF+BCB_XOR ;   after the START (27.9k cyc a frame while the
        lda zback_hi                 ;   border repaints) moves to the next blitter
        sta MEMW+MEMW_CL_OFF+BCB_DST_ADDR+2 ;   user, which waits anyway; the CPU plotter
        stz VBXE_BL_ADR0             ; <VRAM_BCB_CLEAR = 0 and its bank byte too
        lda #>VRAM_BCB_CLEAR
        sta VBXE_BL_ADR1
        stz VBXE_BL_ADR2
    .if [VRAM_BCB_CLEAR & $FF] != 0 || [VRAM_BCB_CLEAR >> 16] != 0
        ert 'VRAM_BCB_CLEAR moved off a page in bank 0: put the lda #< / #>>16 back'
    .endif
        lda #1
        sta VBXE_BL_START
        rts
.endp
        .endseg

;--------------------------------------------------------------
; ptc_stamp -- ptc_frame's first act: stamp THIS frame's zback_hi into the two
;   chain slots' DST bank byte.
;   Out here because PTCFRAME_END ($BC47) was stale by 21 B: the block really
;--------------------------------------------------------------
ptcs_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ptc_stamp
        lda #BANK_EN | BANK_OVERHEAD
        sta VBXE_BANK_SEL
        lda zback_hi
        sta MEMW+MEMW_VL_OFF+BCB_SIZE+BCB_XOR
        sta MEMW+MEMW_VL_OFF+2*BCB_SIZE+BCB_XOR
        lda #$FF                     ; the painter links' source byte (VRAM_BCB_FF,
        sta MEMW+MEMW_VL_OFF+64      ;   2026-09-14): the window is on the overhead
        stz pc_colw+1                ;   bank here. pc_colw+1 = 0 for the emits'
        rts                          ;   16-bit column word (low byte: process_seg)
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ptc_tail
        sta VBXE_BL_ADR0
        lda tw_chn                   ; $97/$9B window page -> $A7/$AB VRAM page
        clc
        adc #[>VRAM_OVERHEAD]-[>MEMW]
        sta VBXE_BL_ADR1
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>ptc_go               ;   next byte of this segment -- fall through
.endp                                ;   (PTCGO_BASE, memory_map.inc)
        .endseg

;--------------------------------------------------------------
; ptc_go -- ptc_tail's tail: wait for the blitter, launch, flip the builder.
;--------------------------------------------------------------
ptcgo_resume = *
        org PTCGO_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ptc_go
                                      ; 2026-09-15: NO second wait. Both paths into
                                     ;   ptc_tail -- ptc_fire (textures.asm) and ...
        lda #1
        sta VBXE_BL_START
        lda tw_chn                   ; build the NEXT chain in the other buffer
        eor #[>[MEMW+MEMW_CHA_OFF]]^[>[MEMW+MEMW_CHB_OFF]]
        sta tw_chn
        rts
.endp
        .endseg
    .if * > PTCGO_END+1
        ert 'ptc_go outgrew PTCGO_BASE..END (memory_map.inc)'
    .endif
        org ptcgo_resume

;--------------------------------------------------------------
; spr_chfire -- launch the sprite path's 8x-expander chain: slot 0 alone,
;   already TERMINATED (tw_expand writes CTRL = BLT_COPY with TEX_RUNS -- no
;   runs ever follow it). tw_x1st = 0 means tw_expand really queued one; a
;   cache hit leaves it nonzero and there is nothing to fire.
;   so flipping tw_chn here keeps both users on the same selector. Clobbers A.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spr_chfire
        lda tw_x1st
        bne ?skip
        phx                          ; the previous chain/blit must finish first --
        jsr blitw_hard               ;   and it MUST be blitw_hard, not a lone
        plx                          ;   `lda BL_BUSY / bne`: BUSY blinks off
                                     ;   between chained BCB fetches, so a single ...
        lda #0                       ; the expander chain starts at slot 0
        jsr ptc_tail
        lda #BCB_SIZE                ; re-arm the flag for the next call
        sta tw_x1st
?skip   rts
.endp
        .endseg

;--------------------------------------------------------------
; ptc_fire_wait -- close + launch the open painter chain (if any), then wait
;   for the blitter: the drop-in for `jsr blitter_wait` at every site that is
;   about to READ what the chain paints or repatch a shared BCB (cm_flush's
;   copy, bg_blit's fill).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ptc_fire_wait
        jsr ptc_fire
        bra blitw_hard               ; tail call (both in bank $01)
.endp
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc ptc_fbg
        jsr ptc_fire
        jmp bg_fill
.endp
        .endseg
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
                                     ;   through zp_tmp "before blitter_wait ...
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
        xba                          ; the colour arrives in B (2026-09-22, as pt_span;
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc blitter_wait
                                      ; 2026-09-21 drac_bra: the target is the very
        ert *<>blitw_hard           ;   next byte of this segment -- fall through
.endp
        .endseg
blw_resume = *
        org BLITW_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc blitw_hard
?ag     ldx #4                       ; BUSY must read 0 FOUR times in a row: the
?ck     lda VBXE_BL_BUSY             ;   FX core can drop BUSY for an instant
        bne ?ag                      ;   between chained BCB fetches, and a
        dex                          ;   single clean read let swap publish a
        bne ?ck                      ;   frame whose last ceiling chains (the
        rts                          ;   TOP rows: the farthest walls draw last)
.endp                                ;   were still being blitted -- the old
        .endseg
                                     ;   VBLANK spin used to mask exactly this
    .if * > BLITW_END+1
        ert 'blitw_hard outgrew BLITW_BASE..END (memory_map.inc)'
    .endif
        org blw_resume

