;--------------------------------------------------------------
; textures.asm -- part of bsp_main.asm (icl in place): the textured wall blit --
;   bcb_twall/bcb_tex8, tw_expand, tw_blit, draw_twall_col.
;--------------------------------------------------------------
        org TEXBLIT_BASE             ; per-column code in the Rapidus-fast window
                                     ; (2026-07-28: swapped homes with the TCOS
                                     ; pages -- see TWSETUP_BASE in memory_map).
; The two 21-byte BCB TEMPLATES are pure boot-time data (setup_bcbs copies them
; into VRAM once), so they are parked in two spare holes instead of eating the
; $A800 code segment, which is hard-limited by the HUD block at $AF40.
tmpl_resume = *
        org BCBTMPL_BASE
; --- per-column textured wall BCB (1 byte wide, col-major src in banks $20+) --
bcb_twall_tmpl
        dta $00,$00,$02              ; SRC_ADDR (patched per column)
        dta a(1)                     ; SRC_STEPY = 1 (next texel down = next byte)
        dta 0                        ; SRC_STEPX = 0 (single column slice)
        dta <VRAM_SCREEN             ; DST_ADDR (patched)
        dta >VRAM_SCREEN
        dta [VRAM_SCREEN>>16]
        dta a(SCREEN_WIDTH)          ; DST_STEPY (down one row)
        dta 1                        ; DST_STEPX
        dta a(0)                     ; WIDTH-1 = 0 (1 byte / LR column)
        dta 0                        ; HEIGHT-1 (patched = src rows-1)
        dta $FF                      ; AND
        dta $00                      ; XOR
        dta $00                      ; COLLIDE
        dta $00                      ; ZOOM (0: the 8x scratch carries the zoom)
        dta $00                      ; PATTERN
        dta BLT_COPY                 ; CTRL

        org BCBTMPL2_BASE
; --- 8x column expander BCB: texture column -> VRAM_TEX8, each texel x8 down ---
tw_cnm1 dta TW_RUNROWS-1             ; qsmul needs an address, not an immediate

bcb_tex8_tmpl
        dta $00,$00,$02              ; SRC_ADDR (patched per column = rs_tsrc)
        dta a(1)                     ; SRC_STEPY = 1 (column-major: next texel)
        dta 0                        ; SRC_STEPX = 0
        dta <VRAM_TEX8               ; DST_ADDR = scratch
        dta >VRAM_TEX8
        dta [VRAM_TEX8>>16]
        dta a(1)                     ; DST_STEPY = 1 (samples are consecutive)
        dta 1                        ; DST_STEPX
        dta a(0)                     ; WIDTH-1 = 0 (one byte per source row)
        dta 0                        ; HEIGHT-1 (patched = texH-1 SOURCE rows)
        dta $FF                      ; AND
        dta $00                      ; XOR
        dta $00                      ; COLLIDE
        dta [(TEX8_ZOOM-1)*16]       ; ZOOM: ZOOMY = 8, ZOOMX = 1
        dta $00                      ; PATTERN
        dta BLT_COPY                 ; CTRL
        org tmpl_resume              ; back to the $A800 blit segment


;--------------------------------------------------------------
; VERTICAL WALL TEXTURING -- world-anchored, so the texture stays STATIC on the
; wall while the player walks.
;--------------------------------------------------------------

;--------------------------------------------------------------
; tw_setup -- PER-COLUMN setup. IN: rs_worldh (front ceil-floor == texels) and
;   the front wall's plane accumulators rs_ycacc/rs_yfacc.
;   OUT: rs_dscr (Q4 screen rows), rs_tpr (Q8 texels/row), tw_use8 (1 = sample
;        the 8x scratch), tw_spy (SRC_STEPY), tw_rpt (ZOOMY).
;   Preserves X. Ports tools/_tex_tile.py (tpr = 1/inv).
;--------------------------------------------------------------
; tw_setup is 600 B and only ever entered by absolute jsr, so it is relocated to
; the spare $8D00 page-block instead of eating the $A800 segment, which has to
; stay clear of TEX_STAGE at $B000 (load_textures streams 4 KB chunks there).
; tw_texmask / wall_src / low_src / draw_twall_clip are pure setup and do not
; belong in the cramped $A800 blit segment (hard ceiling $B000 = TEX_STAGE);
; they live in the free tail of the $2000 engine segment instead.
        icl 'tw_setup.asm'           ; per-column rate setup + span clipping (relocated)


;==============================================================
; BLIT CHAINS (2026-07-28). One textured column = ONE blitter list:
;   [slot 0: 8x expand (optional) | slot 1..: the runs]
; built into VRAM_BCB_CHA/CHB (alternating -- the running chain is fetched from
; VRAM link by link and must stay intact) and fired with a single START.
;--------------------------------------------------------------
; tw_chain_open / tw_scrbase / tw_chain_fire live in the $273E-$278F hole
; (the TEXBLIT segment is packed to the byte).
;--------------------------------------------------------------
twchain_resume = *
        org TWCHAIN_BASE
    .if TEX_RUNS
;--------------------------------------------------------------
; ptc_fire -- close + launch the PAINTER's open chain, flip buffers, reopen.
;   stay unique mod 256 for all 47 links). Clobbers A.
;--------------------------------------------------------------

        .segment B1                  ; bank $01 with all its callers (jsr, not jsl): the
                                     ;   wait and ptc_tail/ptc_go are inline -- the two
                                     ;   jsl wrappers cost 52 cycles a fire (89 a frame)
ptc_fire
        lda zp_pt                    ; low byte still at slot 1 = empty chain
                                      ; 2026-09-22: zp_pt points at the slot's DST field
        cmp #BCB_SIZE+BCB_DST_ADDR   ;   (paint_col's phase rewrite)
        beq ptc_out
        phx                          ; THE PREVIOUS CHAIN (blitw_hard inline): BUSY
ptc_bw  ldx #4                       ;   must read 0 four times in a row -- it can
ptc_bc  lda VBXE_BL_BUSY             ;   drop for an instant between chained BCB
        bne ptc_bw                   ;   fetches, and a START while busy is dropped
        dex
        bne ptc_bc
        plx
        lda #BLT_COPY|BLT_NEXT       ; it is done: re-arm ITS terminated slot
ptc_p1  sta MEMW+MEMW_VL_OFF+63      ; ptc_put INLINED, both stores (2026-09-15):
        rep #$20                     ;   the operands are patched below on every
        .LONGA ON                    ;   fire, the initial target is an unused byte
        lda zp_pt
        sec                          ; 2026-09-22: the last link's CTRL = the next
        sbc #BCB_DST_ADDR+1          ;   slot's base - 1 = zp_pt - DST_ADDR - 1
        sta.l B1CODE_BASE+ptc_p1+1   ; (long: the code is in bank $01, DBR is 0)
        sta.l B1CODE_BASE+ptc_p2+1
        sep #$20
        .LONGA OFF
        lda #BLT_COPY                ; ... loses the chain bit = end of list
ptc_p2  sta MEMW+MEMW_VL_OFF+63
        lda #BCB_SIZE                ; ptc_tail/ptc_go inline: launch from slot 1 (slot
        sta VBXE_BL_ADR0             ;   0 is the 8x expander's); ADR2 is 0 for good
        lda tw_chn                   ; $97/$9B window page -> $A7/$AB VRAM page
        clc
        adc #[>VRAM_OVERHEAD]-[>MEMW]
        sta VBXE_BL_ADR1
        lda #1
        sta VBXE_BL_START
        lda tw_chn                   ; build the NEXT chain in the other buffer
        eor #[>[MEMW+MEMW_CHA_OFF]]^[>[MEMW+MEMW_CHB_OFF]]
        sta tw_chn
        bra ptc_oa                   ; A = tw_chn, as ptc_open loads it
ptc_open                             ; (re)open: builder -> tw_chn's slot 1
        lda tw_chn
ptc_oa  sta zp_pt+1                  ; 2026-09-22: zp_pt -> slot 1's DST field, and the
        clc                          ;   builder's END slot (tw_chn:00 + 21*48 = tw_chn+3
        adc #>[BCB_SIZE*TW_MAXLINKS] ;   : $F0) into the two `cmp #` operands
        sta.l B1CODE_BASE+paint_col.pc_cend+2   ; paint_col/pt_span test zp_pt against
        sta.l B1CODE_BASE+pt_span.ps_cend+2
        lda #BCB_SIZE+BCB_DST_ADDR
        sta zp_pt
        stz zp_savex                 ; zp_pt+2: the bank of [zp_pt],y -- the window is bank 0
    .if <[BCB_SIZE*TW_MAXLINKS] != $F0 || >[BCB_SIZE*TW_MAXLINKS] != 3 || <[BCB_SIZE*TW_MAXLINKS] + BCB_DST_ADDR > $FF
        ert 'ptc_open patches the END operand as tw_chn+3:$F0 -- TW_MAXLINKS or BCB_SIZE moved'
    .endif
                                      ; 2026-09-22 (vbxe-blitter): cm_flush's copy links --
ptc_rsh rts                          ;   PATCHED to `jsl cm_rest` (4 bytes) while a copy
        dta 0,0,0                    ;   slot waits for its template (colmerge.asm);
ptc_out rts                          ;   unhooked it is this rts again (cm_rest)
        .endseg
    .else
;--------------------------------------------------------------
; tw_chain_open -- start building a column's chain: emit ptr -> slot 1, no
;   links, no expand yet (tw_x1st doubles as the FIRST LINK's low byte: 21 =
;   runs-only, 0 = tw_expand claimed slot 0). Clobbers A/X.
;--------------------------------------------------------------
.proc tw_chain_open
        lda tw_chn                   ; tw_chn IS the chain's window page
        sta zp_nodeptr+1
        lda #21
        sta zp_nodeptr
        sta tw_x1st
        rts
.endp

;--------------------------------------------------------------
; tw_chain_fire -- terminate + launch the chain, flip buffers. Clobbers A/Y.
;   BL_ADR2 is never written: every BCB this port owns sits in the $00Axxx
;   overhead bank, so it is 0 from setup_palette's first fire onward.
;--------------------------------------------------------------
.proc tw_chain_fire
        lda tw_x1st                  ; 0 = an expand is queued -> always fire
        beq ?go
        lda zp_nodeptr               ; runs-only: ptr still AT slot 1 (low byte
        cmp #21                      ;   exactly 21) means nothing was emitted
        beq ?out
?go     sec                          ; last emitted link: CTRL loses the chain bit
        lda zp_nodeptr
        sbc #21
        sta zp_nodeptr
        bcs ?nb                      ; links cross pages (slot 13+): borrow!
        dec zp_nodeptr+1
?nb     ldy #BCB_CTRL
        lda #BLT_COPY
        sta (zp_nodeptr),y
        jsr blitter_wait             ; the PREVIOUS chain -- ran during our build
        lda tw_x1st                  ; first link's low byte (0 or 21)
        sta VBXE_BL_ADR0
        lda tw_chn                   ; $97/$9B window page -> $A7/$AB VRAM page
        clc
        adc #[>VRAM_OVERHEAD]-[>MEMW]
        sta VBXE_BL_ADR1
        lda tw_chn                   ; build the NEXT column in the other buffer
        eor #[>[MEMW+MEMW_CHA_OFF]]^[>[MEMW+MEMW_CHB_OFF]]
        sta tw_chn
        lda #1
        sta VBXE_BL_START
?out    rts
.endp
    .endif                           ; TEX_RUNS
    .if * > TWCHAIN_END+1
        ert 'the chain helpers outgrew the $273E-$278F hole (memory_map.inc)'
    .endif
        org twchain_resume

;--------------------------------------------------------------
; tw_expand_spr -- the sprite path's expander: a chain of ONE (just the 8x
;   expansion; the sprite blit that follows does its own wait, so it reads the
;   scratch only after this chain has finished). Parked at SPREXP_BASE.
;--------------------------------------------------------------
spre_resume = *
        org SPREXP_BASE
    .if TEX_RUNS
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tw_expand_spr
        jsr tw_expand
        jmp spr_chfire
.endp
        .endseg
    .else
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tw_expand_spr
        jsr tw_chain_open
        jsr tw_expand
        jmp tw_chain_fire
.endp
        .endseg
    .endif
    .if * > SPREXP_END+1
        ert 'tw_expand_spr outgrew the $AF34-$AF3F hole (memory_map.inc)'
    .endif
        org spre_resume

;--------------------------------------------------------------
; tw_expand -- queue the 8x expansion of the current texture column (rs_tsrc,
;   [tw_t0, tw_t0+tw_need) texels) into the OTHER scratch as slot 0 of the
;   chain. Skipped when either scratch already holds the range (tw_lastsrc).
;   Leaves tw_base = the scratch the runs must sample. Clobbers A/Y.
;--------------------------------------------------------------
twem_resume = *
        org TWEMIT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tw_expand
	stz tw_base
        stz tw_base+2                ; VRAM_TEX8 is in bank 0 (ert); the mid byte
    .if [VRAM_TEX8 >> 16] != 0       ;   is stored once, below, from the FLIPPED
        ert 'VRAM_TEX8 left bank 0 -- put the lda #>>16 back (tw_expand)'
    .endif                           ;   tw_scr: the store that was here was
        ; --- THE SCRATCH-CONTAINMENT CACHE WAS HERE, AND IT WAS DEAD (deleted
        ;     2026-08-14).
        lda tw_scr                   ; expand into the OTHER scratch: the chain
        eor #1                       ;   still running may read the current one
        sta tw_scr
        asl
        asl
        ora #>VRAM_TEX8              ; (the same $00F800-base OR as above)
        sta tw_base+1                ; ... and retarget tw_base at it
                                      ; 2026-09-22 (rapidus-bus-timing): the slot is
    .if !TEX_RUNS                     ;   written through [zp_nodeptr],y with the bank
        ert 'tw_expand: the [zp_nodeptr],y body is written for TEX_RUNS'
    .endif                           ;   byte parked at 0 -- a (dp),y store dummy-
        stz zp_nodeptr               ;   reads the MEMAC window first. Slot 0 of the
        lda tw_chn                   ;   buffer being built: the painter owns 1..
        sta zp_nodeptr+1
        lda zp_nodeptr+2             ; the node bank (set once per level) rides
        pha                          ;   the stack across the stores
        stz zp_nodeptr+2
                                     ; 2026-09-22 (rapidus-bus-timing): SRC lo/mid as ONE
        rep #$21                     ;   bus word (the slot's base is the pointer: the
        .LONGA ON                    ;   unindexed [dp] store, BCB_SRC_ADDR = 0)
        lda tw_t0                    ; SRC = column base + t0 texels (t0 a byte: the
        and #$00FF                   ;   word read drags its neighbour in)
        adc rs_tsrc
        sta [zp_nodeptr]
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone: the bank byte takes it)
        lda rs_tsrc+2
        adc #0
        ldy #BCB_SRC_ADDR+2
        sta [zp_nodeptr],y
    .if BCB_SRC_ADDR != 0
        ert 'tw_expand stores SRC through [zp_nodeptr] unindexed: BCB_SRC_ADDR must be 0'
    .endif
        ldy #BCB_DST_ADDR+1          ; DST mid byte picks the scratch (lo/hi are
        lda tw_base+1                ;   prefilled: $00 xx $07)
        sta [zp_nodeptr],y
        ldy #BCB_HEIGHT              ; HEIGHT = need SOURCE rows - 1
        lda tw_need
        dec
        sta [zp_nodeptr],y
        ldy #BCB_ZOOM                ; ZOOMY = S (the oversampling factor)
        lda tw_s
        dec
        asl
        asl
        asl
        asl
        sta [zp_nodeptr],y
                                     ; 2026-09-22 (vbxe-blitter: templates): CTRL =
        stz tw_x1st                  ; a real expansion is queued -> fire it
        pla
        sta zp_nodeptr+2
        rts
                                     ; (the cache-HIT exit `?done rts` stood
                                     ;  here; nothing branches to it any more)
.endp
        .endseg

;--------------------------------------------------------------
; tw_blit -- EMIT one run as the chain's next link: tw_base + tw_boff (source),
;   tw_brow (dest top row), tw_bh (BCB HEIGHT = source rows - 1), tw_spy /
;   tw_zoomv (per-column rate). No blitter touch -- tw_chain_fire launches the
;   whole column. Clobbers A/X/Y.
;--------------------------------------------------------------
    .if !TEX_RUNS
.proc tw_blit
        ldy #BCB_SRC_ADDR            ; SRC = tw_base + tw_boff
        clc
        lda tw_base
        adc tw_boff
        sta (zp_nodeptr),y
        iny
        lda tw_base+1
        adc tw_boff+1
        sta (zp_nodeptr),y
        iny
        lda tw_base+2
        adc #0
        sta (zp_nodeptr),y
        iny                          ; Y = BCB_SRC_STEPY
        lda tw_spy
        sta (zp_nodeptr),y
        iny
        lda tw_spy+1
        sta (zp_nodeptr),y
        ldy #BCB_DST_ADDR            ; DST = row(tw_brow) + col, back buffer
        ldx tw_brow
        lda row_lo,x
        clc
        adc zp_col
        sta (zp_nodeptr),y
        iny
        lda row_hi,x
        adc #0
        sta (zp_nodeptr),y
        iny
        lda zback_hi
        sta (zp_nodeptr),y
        ldy #BCB_HEIGHT
        lda tw_bh
        sta (zp_nodeptr),y
        ldy #BCB_ZOOM
        lda tw_zoomv
        sta (zp_nodeptr),y
        ldy #BCB_CTRL
        lda #BLT_COPY|8              ; provisionally chained; tw_chain_fire
        sta (zp_nodeptr),y           ;   clears the bit on the LAST link
        clc                          ; emit ptr -> next slot. No overflow guard:
        lda zp_nodeptr               ;   tw_runs' TW_MAXRUN cap bounds a column
        adc #21                      ;   at 32 runs + ?fill + the expand = 34
        sta zp_nodeptr               ;   links = TW_MAXLINKS exactly
        bcc ?nc
        inc zp_nodeptr+1
?nc     rts
.endp
    .endif                           ; !TEX_RUNS (tw_blit)
    .if * > TWEMIT_END+1
        ert 'tw_expand/tw_blit outgrew TWEMIT_BASE..END (memory_map.inc)'
    .endif
        org twem_resume

    .if TEX_RUNS
; PAINTED WALLS. draw_twall_col and its tw_holdfix take the whole TEXBLIT
; segment; with TEX_RUNS neither is reachable (draw_twall_clip tail-calls
; paint_col instead) and paint.asm moves into the room they leave. tw_expand
; stays: the SPRITE path shares it (tw_expand_spr).
        icl 'paint.asm'
    .else

;--------------------------------------------------------------
; draw_twall_col -- one textured wall column. A = dst top row, Y = dst height,
;   zp_col = column, rs_tsrc = texture column base (VRAM 24b), rs_texh_cur = texH,
;   rs_pegrow = peg row, rs_tpr / tw_use8 / tw_spy / tw_rpt from tw_setup.
;   residual slide. Preserves X.
;--------------------------------------------------------------
.proc draw_twall_col
        sta tw_row                   ; a = dst top row
        stx zp_savex                 ; preserve caller's X
        sty tw_h                     ; h = dst height (>= 1)
        lda rs_texh_cur              ; texH 0 would divide by zero
        bne ?texok
        ldx zp_savex                 ; (the run loop, and with it the shared ?out,
        rts                          ;  now lives in fast RAM as tw_runs)
?texok  jsr tw_chain_open            ; this column's blit list starts empty
        clc                          ; tw_b = a + h - 1
        lda tw_row
        adc tw_h
	dec
        sta tw_b
        ; ---- tw_wt = (a - peg) * tpr, reduced mod texH*256 -------------------- ...
?wtcalc sec
        lda tw_row
        sbc rs_pegrow
        sta m_a
        lda #0
        sbc rs_pegrow+1
        sta m_a+1
        bpl ?apos
                                     ; a above the peg (clip slack) -> texel 0
        stz m_a
        stz m_a+1
?apos   lda rs_tpr
        sta m_b
        lda rs_tpr+1
        sta m_b+1
        jsr umul16                   ; m_prod(32) = (a-peg) * tpr_q8
        lda rs_vsh                   ; DOOM peg shift (r_segs.c): whole texels, so
        beq ?novsh                   ;   it lands on m_prod+1. The modulo below
        clc                          ;   folds it back inside the tile. (No carry
        adc m_prod+1                 ;   into m_prod+3: the code below already
        sta m_prod+1                 ;   treats a 32-bit product as impossible.)
        bcc ?novsh
        inc m_prod+2
?novsh  lda rs_texpow2               ; texH a power of two -> the modulo is an AND
        bne ?slowmod
        lda m_prod
        sta tw_wt
        lda m_prod+1
        and rs_texmask+1
        sta tw_wt+1
	bra ?srcsel
?slowmod lda m_prod+3                ; cannot happen for real geometry, but a
        beq ?red0                    ; 32-bit product would break udiv24
        stz m_prod
        stz m_prod+1
        stz m_prod+2
?red0
        stz m_den
        lda rs_texh_cur
        sta m_den+1
        jsr udiv24                   ; m_rem = wt inside the tile (destroys m_prod)
        lda m_rem
        sta tw_wt
        lda m_rem+1
        sta tw_wt+1
        ; ---- source select.
?srcsel
        stz tw_soff
        stz tw_soff+1
        lda tw_use8
        bne ?exp8
        lda rs_tsrc                  ; raw texture column, tile = texH texels
        sta tw_base
        lda rs_tsrc+1
        sta tw_base+1
        lda rs_tsrc+2
        sta tw_base+2
        lda rs_texh_cur
        sta tw_tile
        stz tw_tile+1
        jmp tw_runs                  ; raw texture column: straight to the run loop
?exp8
    .if TW_SAFE
        jmp ?full                    ; TW_SAFE: always expand the whole column
    .endif
        lda tw_wt+1                  ; t0 = first texel the span touches
        sta tw_t0
 .ifdef ANTONIA2
        lda rs_tpr+1                 ; ANTONIA II: m_prod = h*tpr + wt in ONE
        bmi ?hsw                     ;   multiply while tpr is below $8000 (see
        rep #$21                     ;   smul32); else the quarter-squares below.
        .LONGA ON                    ;   C = 0 from the rep
        lda tw_h
        and #$00FF                   ; a byte: the word read drags its neighbour
        sta.l ANT_MUL
        lda rs_tpr
        sta.l ANT_MUL+2
        lda.l ANT_MUL                ; + wt -- its carry out of byte 1 is what
        adc tw_wt                    ;   the shared tail below adds into byte 2
        sta m_prod
        sep #$20                     ; (sep keeps C)
        .LONGA OFF
        lda.l ANT_MUL+2              ; byte 2 alone: h*tpr < 2^24, and m_prod+3
        sta m_prod+2                 ;   stays untouched, as the software leaves it
        jmp ?htail                   ; (jmp keeps C)
?hsw
 .endif
        qsmul tw_h, rs_tpr, qs_p           ; m_prod = h*tpr + wt  -> last texel at >>8
        lda qs_p
        sta m_prod
        lda qs_p+1
        sta m_prod+1
	stz m_prod+2
        qsmul tw_h, rs_tpr+1, qs_p
	rep #$21
	.LONGA ON
        lda m_prod+1
        adc qs_p
        sta m_prod+1

        clc
        lda m_prod
        adc tw_wt
        sta m_prod
	sep #$20
	.LONGA OFF
?htail                               ; (ANTONIA2's multiply joins here, C live)
        lda m_prod+2
        adc #0
        sta m_prod+2
        bne ?full                    ; last texel >= 256 -> past any texH

        sec                          ; need = t1 - t0 + 1
        lda m_prod+1
        sbc tw_t0
	inc
        sta tw_need
        clc                          ; t0 + need > texH -> the span wraps: full column
        adc tw_t0
        bcs ?full
        cmp rs_texh_cur
        beq ?sized
        bcs ?full
?sized  ; Expand a few texels MORE than this span needs: the next screen column
        ; usually wants a range shifted by a texel or two, and the containment
        ; test in tw_expand then serves it from the scratch instead of blitting
        ; the column again.
        lda tw_t0                    ; end = t0 + need + TW_PAD
        clc
        adc tw_need
        adc #TW_PAD
        bcs ?tile8                   ; wrapped a byte -> keep the exact range
        cmp rs_texh_cur
        bcs ?tile8                   ; past the tile end -> keep the exact range
        sec                          ; need = end - t0
        sbc tw_t0
        sta tw_need
	bra ?tile8
?full
        stz tw_t0
        lda rs_texh_cur
        sta tw_need
?tile8
        jsr tw_expand                ; texels [t0, t0+need) -> VRAM_TEX8 (or a
                                     ;   cache hit on a range that contains them) ...
        lda tw_lastt0                ; tw_soff = lastt0 * S (samples)
        sta tw_soff
        stz tw_soff+1
        jsr ?x8soff
        lda tw_lastneed              ; tile = lastneed * S samples
        sta tw_tile
        stz tw_tile+1
        ldy tw_ssh
        beq ?tdone
	rep #$20
	.LONGA ON
	lda tw_tile
?tlp	asl
	dey
	bne ?tlp
	sta tw_tile
	sep #$20
	.LONGA OFF
?tdone
        ; NO tw_base store here: tw_expand owns it now -- the expander alternates ...
        jmp tw_runs                  ; the run loop lives in FAST RAM (see below)
?x8soff ldy tw_ssh                   ; tw_soff *= S
        beq ?x8done
	rep #$20
	.LONGA ON
	lda tw_soff
?x8lp	asl
	dey
	bne ?x8lp
	sta tw_soff
	sep #$20
	.LONGA OFF
?x8done rts
.endp

;--------------------------------------------------------------
; tw_holdfix -- turn the link tw_blit JUST emitted into a HOLD run: SRC_STEPY=0,
;   ZOOM=0 (one source sample smeared down the rest of the span). The tw_spy /
;   tw_zoomv VARS stay untouched on purpose: tw_setup's dscr memo skips
;   recomputing them for the next column, so zeroing the vars themselves let a
;   memo-hit column inherit spy=0 and smear WHOLE columns (2026-07-28 banding).
;--------------------------------------------------------------
.proc tw_holdfix
        sec                          ; back to the link just emitted
        lda zp_nodeptr
        sbc #21
        sta zp_nodeptr
        bcs ?nb
        dec zp_nodeptr+1
?nb     ldy #BCB_SRC_STEPY
        lda #0
        sta (zp_nodeptr),y
        iny
        sta (zp_nodeptr),y
        ldy #BCB_ZOOM
        sta (zp_nodeptr),y
        clc                          ; ... and past it again (fire steps back
        lda zp_nodeptr               ;   from HERE to clear the chain bit)
        adc #21
        sta zp_nodeptr
        bcc ?nc
        inc zp_nodeptr+1
?nc     rts
.endp
    .endif                           ; !TEX_RUNS (draw_twall_col + tw_holdfix)

;--------------------------------------------------------------
; tw_runs -- the run loop of draw_twall_col, relocated to TWRUNS_BASE in the
;   Rapidus-fast $0900 page (2026-07-28: swapped places with collision.asm).
;--------------------------------------------------------------
    .if !TEX_RUNS                    ; the run loop is draw_twall_col's tail (and
                                     ; tw_holdfix's only caller): painted walls
                                     ; leave the whole $0900 page unused
twruns_resume = *
        org TWRUNS_BASE
.proc tw_runs
?srcok  lda #TW_MAXRUN               ; runaway guard (see ?fill for the fallback)
        sta tw_guard
        lda tw_rpt                   ; ZOOM = (rpt-1)<<4: hold each sample rpt
	dec
        asl
        asl
        asl
        asl
        sta tw_zoomv
        ; ======================= one run per source tile =======================
?run    lda tw_use8                  ; tw_off = wt >> 5 (samples) or wt >> 8 (texels)
        beq ?offraw
	rep #$20
	.LONGA ON
	lda tw_wt
	ldy tw_rsh
?sh5	lsr
	dey
	bne ?sh5
	sec
	sbc tw_soff
	sta tw_off
	sep #$20
	.LONGA OFF
	bra ?havoff

?offraw lda tw_wt+1
        sta tw_off
        stz tw_off+1
        ; n = SOURCE rows this run may use = min(TW_RUNROWS, rows left in tile).
?havoff qsmul tw_cnm1, tw_spy, qs_p        ; (TW_RUNROWS-1) * spy
	rep #$21
	.LONGA ON
        lda qs_p
        adc tw_off
;       sta m_a			;is this necessary?
	cmp tw_tile
        bcc ?nfullw
	lda tw_tile
	dec
	sec
	sbc tw_off
	sta m_prod
        lda tw_spy
        sta m_den
	sep #$20
	.LONGA OFF
        jsr udiv16

        lda m_quot+1
        bne ?ncap
        lda m_quot
        cmp #TW_RUNROWS
        bcc ?nok
?ncap   lda #TW_RUNROWS-1
?nok
	inc
	sta tw_n
	bra ?haven
?nfullw	sep #$20
	.LONGA OFF
?nfull  lda #TW_RUNROWS
        sta tw_n
?haven
        qsmul tw_n, tw_rpt, qs_p           ; avail = n*rpt dest rows (multiple of rpt)

        lda qs_p
        sta tw_dr
        lda qs_p+1
        sta tw_dr+1
        sec                          ; rem = tw_b - tw_row + 1  (>= 1)
        lda tw_b
        sbc tw_row
	inc
        sta tw_rem
        lda tw_dr+1                  ; dr = min(avail, rem)
        bne ?spanlim

        lda tw_dr
        cmp tw_rem
        bcs ?spanlim

        lda #1                       ; run-limited: dr = avail, n1 = n, no remainder
        sta tw_lim
        lda tw_n
        sta tw_n1
        stz tw_r
	bra ?emit

?spanlim lda tw_rem                  ; span-limited: dr = rem, n1 = dr/rpt + rest
        sta tw_dr
        stz tw_dr+1
        stz tw_lim
        lda tw_rpt
	dec
        bne ?sdiv
        lda tw_dr                    ; rpt == 1 -> one source row per dest row
        sta tw_n1
	stz tw_r
        bra ?emit

?sdiv   lda tw_dr
        sta m_prod
        stz m_prod+1
        lda tw_rpt
        sta m_den
        stz m_den+1
        jsr udiv16

        lda m_quot
        sta tw_n1
        qsmul tw_n1, tw_rpt, qs_p
        sec                          ; r = dr - n1*rpt  (0..rpt-1 leftover rows)
        lda tw_dr
        sbc qs_p
        sta tw_r

?emit   lda tw_n1
        beq ?rest                    ; shorter than one zoom group -> rest only

        lda tw_row
        sta tw_brow
        lda tw_n1
	dec
        sta tw_bh                    ; HEIGHT = SOURCE rows - 1
        lda tw_off
        sta tw_boff
        lda tw_off+1
        sta tw_boff+1
        jsr tw_blit

?rest   lda tw_r
	jeq ?adv
	qsmul tw_n1, tw_rpt, qs_p          ; the leftover rows continue the last sample
        clc
        lda tw_row
        adc qs_p
        sta tw_brow
        lda tw_r
	dec
        sta tw_bh
        qsmul tw_n1, tw_spy, qs_p          ; source sample off + n1*spy
        clc
        lda tw_off
        adc qs_p
        sta tw_boff
        lda tw_off+1
        adc qs_p+1
        sta tw_boff+1
        jsr tw_blit                  ; emit, then zero the LINK's STEPY/ZOOM --
        jsr tw_holdfix               ;   never the vars (tw_setup's dscr memo!)
?adv    clc                          ; tw_row += dr
        lda tw_row
        adc tw_dr
        sta tw_row
        lda tw_lim
	jeq ?out
	dec tw_guard
	jeq ?fill
 .ifdef ANTONIA2
        lda rs_tpr+1                 ; ANTONIA II: m_prod = dr*tpr + wt in ONE
        bmi ?dsw                     ;   multiply while tpr is below $8000, exactly
        rep #$21                     ;   as the h*tpr one above
        .LONGA ON
        lda tw_dr
        and #$00FF                   ; the byte the two quarter-squares used
        sta.l ANT_MUL
        lda rs_tpr
        sta.l ANT_MUL+2
        lda.l ANT_MUL                ; + wt, carry into the shared tail's byte 2
        adc tw_wt
        sta m_prod
        sep #$20                     ; (sep keeps C)
        .LONGA OFF
        lda.l ANT_MUL+2              ; byte 2 alone (dr*tpr < 2^24), m_prod+3
        sta m_prod+2                 ;   untouched
        jmp ?dtail                   ; (jmp keeps C)
?dsw
 .endif
        qsmul tw_dr, rs_tpr, qs_p          ; wt += dr*tpr (dr is a byte -> 2 qsmuls),
        lda qs_p                     ; then reduce mod texH*256
        sta m_prod
        lda qs_p+1
        sta m_prod+1
        stz m_prod+2
        qsmul tw_dr, rs_tpr+1, qs_p
	rep #$21
	.LONGA ON
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        clc
        lda m_prod
        adc tw_wt
        sta m_prod
	sep #$20
	.LONGA OFF
?dtail                               ; (ANTONIA2's multiply joins here, C live)
        lda m_prod+2
        adc #0
        sta m_prod+2

        lda rs_texpow2               ; power-of-two texH -> the modulo is an AND
        bne ?red

        lda m_prod
        sta tw_wt
        lda m_prod+1
        and rs_texmask+1
        sta tw_wt+1

        jmp ?run

?red    lda m_prod+2                 ; while wt >= texH*256: wt -= texH*256
        bne ?sub                     ; (a run covers at most one tile -> 1-2 laps)
        lda m_prod+1
        cmp rs_texh_cur
        bcc ?reddone
?sub    sec
        lda m_prod+1
        sbc rs_texh_cur
        sta m_prod+1
        lda m_prod+2
        sbc #0
        sta m_prod+2
        jmp ?red

?reddone lda m_prod
        sta tw_wt
        lda m_prod+1
        sta tw_wt+1
        jmp ?run
        ; A span needing more than TW_MAXRUN runs means the texture repeats absurdly
        ; often down it (tiny texH on a tall wall).
?fill   sec
        lda tw_b
        sbc tw_row
        bcc ?out
        sta tw_bh                    ; HEIGHT = remaining rows - 1
        lda tw_row
        sta tw_brow
        lda tw_off
        sta tw_boff
        lda tw_off+1
        sta tw_boff+1
        jsr tw_blit                  ; hold one sample down the rest of the span
        jsr tw_holdfix               ;   (the LINK's fields, not the vars)
?out    jsr tw_chain_fire            ; launch the whole column's blit list
        ldx zp_savex
        rts
.endp
    .if * > TWRUNS_END
        ert 'tw_runs outgrew its fast-RAM block -- see memory_map.inc'
    .endif
        org twruns_resume
    .endif                           ; !TEX_RUNS (tw_runs)
    .if * > TEXBLIT_END+1
        ert 'the blit segment outgrew TEXBLIT_BASE..END -- see memory_map.inc'
    .endif
