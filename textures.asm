; AUTO-SPLIT from bsp_main.asm 2026-07-24 -- assembled in place via icl, so the
; org juggling below is unchanged (verified: the XEX is byte-identical).
;
; Textured wall rendering: the $A800 blit segment (bcb_twall/bcb_tex8 templates,
; tw_expand, tw_blit, draw_twall_col) plus the pieces relocated out of it --
; seg_len/tw_texmask/wall_src/low_src/draw_twall_clip at TWCLIP_BASE and tw_setup
; at TWSETUP_BASE. bsp_main.asm keeps the tw_seg_end ceiling assert.
;==============================================================
; Textured wall blit (B2) -- parked at $A400 (spare RAM above the palette,
; below the $B000 texture-load staging). Reuses the w3d draw_textured_vline
; mechanism: textures are column-major in VBXE banks $20+, one BCB per screen
; column (SRC_STEPY=1 walks down the column), vertical fit via the ZOOMY
; magnify ladder + centre-crop. Called by renderer.asm's per-column loop via
; absolute jsr (separate load segment; $2000 segment stays untouched).
;==============================================================
; !! HARD CEILING $B000 !! This segment grows UP into TEX_STAGE, which the level
;    loader streams textures over AFTER the XEX has loaded. Code up there is not
;    an assembler error -- it boots to a flat pink screen and nothing else. It has
;    already happened once. If this segment runs out of room, move a whole .proc
;    out with `org` + absolute jsr (that is why tw_setup lives at $8D00) instead
;    of letting it creep. Free RAM: see the RAM-BUDGET block in memory_map.inc,
;    or run `python tools/ram_map.py`. Guarded by the tw_seg_end assert at the end
;    of this file and by tools/check_xex.py in build.ps1 / build_atr.ps1.
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
;
;   texel(row) = (row - pegrow) * tpr   (mod texH),  tpr = texels per screen row
;
; pegrow is the screen row of a FIXED world height (the front ceiling for the
; middle wall and the upper step, the back floor for the lower step), and
; tpr = 1/scale depends only on the column's distance -- never on which span is
; drawn, and never on the texture. That is the whole fix: the old code squeezed
; texH over the span's on-screen height (stretch-to-fit) with a TRUNCATED integer
; scale, so every step of that integer moved the texture up or down the wall.
;
; plane_setup gives dscr = worldH*scale/256 for the front wall, hence
;       tpr_q8 = 4096*worldH / dscr_q4     (tw_setup, once per column)
; dscr comes from the 24-bit Q8 plane accumulators, NOT from the truncated row
; numbers: a +-1 row error there is a whole rung of the rate ladder on a short
; wall, which shows up as per-column shimmer.
;
; The blitter can only step its source by whole bytes, so a raw texture column
; yields rates 1,2,3.. (SRC_STEPY) or 1,1/2,1/3.. (ZOOMY) and NOTHING in between.
; Between two rungs the texture keeps a fixed on-screen size while the wall grows
; -- that is the second half of the sliding. Fix: expand the column 8x vertically
; into VRAM_TEX8 (one blit) and sample THAT, optionally with ZOOMY on top:
;       rate = spy / (8*rpt),   rpt = floor(1/tpr) when magnifying
; giving a 1/(8*rpt) ladder instead of 1/rpt. rpt never exceeds the natural texel
; height, so a held sample is always finer than one texel (no skipping).
; Far columns (tpr >= 8 texels/row) are a few rows tall -- expanding them is pure
; cost, so they sample the texture directly.
;
; Residual, measured by tools/_verify_twall.py: a fixed world point on a wall
; slides <= ~9 screen rows over the whole walk-up range, against 60-350 rows for
; the stretch-to-fit code this replaces. TW_RUNROWS is the speed/stability knob.
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
; VRAM link by link and must stay intact) and fired with a single START. The
; per-run blitter_wait + BL_ADR/START pokes are gone; the one wait left sits in
; tw_chain_fire, and by then the PREVIOUS column's chain has been running the
; whole time this one was being built. vbxe.cpp: CTRL bit3 = another BCB
; follows at +21.
; The emit pointer is zp_nodeptr: the BSP walk re-derives it per node
; (calc_nodeptr) and reads both children BEFORE descending, so it is dead
; while a subsector's columns are drawn -- exactly the open..fire window.
;--------------------------------------------------------------
; tw_chain_open / tw_scrbase / tw_chain_fire live in the $273E-$278F hole
; (the TEXBLIT segment is packed to the byte).
;--------------------------------------------------------------
twchain_resume = *
        org TWCHAIN_BASE
    .if TEX_RUNS
;--------------------------------------------------------------
; ptc_fire -- close + launch the PAINTER's open chain, flip buffers, reopen.
;   Called when the buffer fills (pt_span's dec), before cm_flush's copy reads
;   what the chain paints, and at the walk's end (ptc_fbg). A no-op when
;   nothing was emitted (zp_pt's low byte is still exactly 21: the +21 steps
;   stay unique mod 256 for all 47 links). Clobbers A.
;   The terminator dance: every slot's CTRL is prefilled "chained"; the fire
;   clears the LAST link's chain bit -- and the NEXT fire, once the blitter is
;   provably done with it, puts the bit back (ptc_put's operand still points
;   there) before terminating its own last link. So exactly one CTRL byte is
;   ever off-template, and no slot is rewritten while a chain still runs.
;--------------------------------------------------------------
ptc_put sta MEMW+MEMW_VL_OFF+63      ; operand rewritten below on every fire
        rts                          ;   (the initial target is an unused byte)

ptc_fire
        lda zp_pt                    ; low byte still at slot 1 = empty chain
        cmp #BCB_SIZE
        beq ptc_out
        phx                          ; THE PREVIOUS CHAIN -- and `lda BL_BUSY /
        jsr blitter_wait             ;   bne` is NOT proof that it is done. BUSY
        plx                          ;   (BL_BUSY D1) goes LOW between chained BCB
                                     ;   fetches -- Altirra's IsBlitterActive() is
                                     ;   false while a BCB is being read in
                                     ;   (vbxe.cpp:2094) -- so a single clean read
                                     ;   lands mid-chain. The ptc_put below then
                                     ;   re-arms the chain bit on the terminator of
                                     ;   a chain that is STILL RUNNING, and the
                                     ;   blitter walks off its end into whatever
                                     ;   BCBs follow. blitw_hard demands four zero
                                     ;   reads for exactly this reason and says so.
                                     ;   It cost a second of missing WALLS after
                                     ;   every overlay close -- the walk had run
                                     ;   (solid_arr 88/160 closed) and the sprites
                                     ;   were there, because spr_blit waits.
                                     ;   phx/plx: paint.asm's callers need X.
        lda #BLT_COPY|BLT_NEXT       ; it is done: re-arm ITS terminated slot
        jsr ptc_put
        sec                          ; this chain's last link: CTRL is the byte
        lda zp_pt                    ;   right below the next free slot
        sbc #1
        sta ptc_put+1
        lda zp_pt+1
        sbc #0
        sta ptc_put+2
        lda #BLT_COPY                ; ... loses the chain bit = end of list
        jsr ptc_put
        lda #BCB_SIZE                ; launch from slot 1 (slot 0 is the 8x
        jsr ptc_tail                 ;   expander's; ptc_tail flips tw_chn)
ptc_open                             ; (re)open: builder -> tw_chn's slot 1
        lda #PT_LINKS
        sta zp_links
        lda #BCB_SIZE
        sta zp_pt
        lda tw_chn
        sta zp_pt+1
ptc_out rts
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
;   With TEX_RUNS there is no open: tw_expand addresses slot 0 itself and
;   spr_chfire fires only when tw_x1st says a real expansion was queued (a
;   cache hit leaves the previous nonzero value -- and the FIRST call can
;   never hit, tw_lastsrc boots as $FF, so the flag needs no init either).
;--------------------------------------------------------------
spre_resume = *
        org SPREXP_BASE
    .if TEX_RUNS
.proc tw_expand_spr
        jsr tw_expand
        jmp spr_chfire
.endp
    .else
.proc tw_expand_spr
        jsr tw_chain_open
        jsr tw_expand
        jmp tw_chain_fire
.endp
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
;   tw_expand + tw_blit are parked at TWEMIT_BASE: the fast page behind
;   tw_runs, in the room coll_seg/collide_leaf vacated (-> COLLFAST_BASE).
;--------------------------------------------------------------
twem_resume = *
        org TWEMIT_BASE
.proc tw_expand
        lda #0                       ; tw_base = the scratch that holds (or will
        sta tw_base                  ;   hold) this column: VRAM_TEX8 + scr*$400
        lda tw_scr
        asl
        asl
        ora #>VRAM_TEX8              ; 2026-08-11: the scratch moved to $00F800/
        sta tw_base+1                ;   $00FC00 -- without this OR the mid byte
        lda #[VRAM_TEX8>>16]         ;   was $00/$04 again = the expander blitted
        sta tw_base+2                ;   into FRAME_A rows 0-8 (top-row flicker
                                     ;   whenever a sprite expanded)
        ; --- THE SCRATCH-CONTAINMENT CACHE WAS HERE, AND IT WAS DEAD (deleted
        ;     2026-08-14). It compared rs_tsrc against tw_lastsrc and, on the
        ;     same column, served the expansion out of the scratch whenever
        ;     [t0, t0+need) fell inside [lastt0, lastt0+lastneed).
        ;     MEASURED (tools/tests/_bench_cache.py, real ATR, real E1M1, the
        ;     whole 41-frame gameplay tape): 0 hits in 913 calls. And it CANNOT
        ;     hit in this build, for two reasons that compound:
        ;       * with TEX_RUNS=1 the wall path is gone -- walls are painted
        ;         from SDRAM runs -- so the ONLY live caller is spr_ctcol;
        ;       * spr_ctcol only runs when sp_lastx has already decided the
        ;         source column CHANGED (spr_draw.asm). So rs_tsrc differs from
        ;         tw_lastsrc on entry every single time, and the first compare
        ;         always falls through. sp_lastx catches the repeats this was
        ;         built to catch, one byte earlier and cheaper.
        ;     Its outputs went with it: tw_lastt0/tw_lastneed were read only by
        ;     the !TEX_RUNS wall path (not assembled) and by the test itself.
        lda tw_scr                   ; expand into the OTHER scratch: the chain
        eor #1                       ;   still running may read the current one
        sta tw_scr
        asl
        asl
        ora #>VRAM_TEX8              ; (the same $00F800-base OR as above)
        sta tw_base+1                ; ... and retarget tw_base at it
    .if TEX_RUNS
        lda #0                       ; slot 0 of the buffer being built: the
        sta zp_nodeptr               ;   painter owns slots 1.. and never
        lda tw_chn                   ;   touches this one (zp_nodeptr is the
        sta zp_nodeptr+1             ;   BSP walk's, dead during sprites)
    .else
        sec                          ; emit ptr -> slot 0 (chain base lo is $00,
        lda zp_nodeptr               ;   so slot 1's low byte is exactly 21)
        sbc #21
        sta zp_nodeptr
    .endif
        ldy #BCB_SRC_ADDR            ; SRC = column base + t0 texels
        clc
        lda rs_tsrc
        adc tw_t0
        sta (zp_nodeptr),y
        iny
        lda rs_tsrc+1
        adc #0
        sta (zp_nodeptr),y
        iny
        lda rs_tsrc+2
        adc #0
        sta (zp_nodeptr),y
        ldy #BCB_DST_ADDR+1          ; DST mid byte picks the scratch (lo/hi are
        lda tw_base+1                ;   prefilled: $00 xx $07)
        sta (zp_nodeptr),y
        ldy #BCB_HEIGHT              ; HEIGHT = need SOURCE rows - 1
        lda tw_need
        sec
        sbc #1
        sta (zp_nodeptr),y
        ldy #BCB_ZOOM                ; ZOOMY = S (the oversampling factor)
        lda tw_s
        sec
        sbc #1
        asl
        asl
        asl
        asl
        sta (zp_nodeptr),y
        ldy #BCB_CTRL
    .if TEX_RUNS
        lda #BLT_COPY                ; a chain of ONE: nothing ever follows the
        sta (zp_nodeptr),y           ;   expansion (the painter fires its own)
        lda #0
        sta tw_x1st                  ; a real expansion is queued -> fire it
        rts
    .else
        lda #BLT_COPY|8              ; the runs follow in slots 1..
        sta (zp_nodeptr),y
        clc                          ; emit ptr back to slot 1
        lda zp_nodeptr
        adc #21
        sta zp_nodeptr
        lda #0
        sta tw_x1st                  ; the chain starts at slot 0 now
        rts
    .endif
                                     ; (the cache-HIT exit `?done rts` stood
                                     ;  here; nothing branches to it any more)
.endp

;--------------------------------------------------------------
; tw_blit -- EMIT one run as the chain's next link: tw_base + tw_boff (source),
;   tw_brow (dest top row), tw_bh (BCB HEIGHT = source rows - 1), tw_spy /
;   tw_zoomv (per-column rate). No blitter touch -- tw_chain_fire launches the
;   whole column. Clobbers A/X/Y.
;   Its ONLY caller is tw_runs, so painted walls leave it unreachable: it is
;   not assembled either, and the fast $0D51 page keeps the ~100 B.
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
;
;   tw_wt is the exact Q8 world texel at the current row, kept reduced mod
;   texH*256. The blitter cannot wrap its source, so a span is split into runs;
;   every run re-derives its source offset from tw_wt, which keeps the run
;   boundaries world-anchored and every read inside [0, tile). Ports
;   tools/_tex_tile.py; tools/_verify_twall.py mirrors it and measures the
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
        sec
        sbc #1
        sta tw_b
        ; ---- tw_wt = (a - peg) * tpr, reduced mod texH*256 --------------------
        ;      (runs AFTER the expander was fired, so this CPU math overlaps the
        ;       1 KB expansion blit instead of stalling behind it)
?wtcalc sec
        lda tw_row
        sbc rs_pegrow
        sta m_a
        lda #0
        sbc rs_pegrow+1
        sta m_a+1
        bpl ?apos
        lda #0                       ; a above the peg (clip slack) -> texel 0
        sta m_a
        sta m_a+1
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
        jmp ?srcsel                  ; NOT ?srcok -- the source select is below
?slowmod lda m_prod+3                ; cannot happen for real geometry, but a
        beq ?red0                    ; 32-bit product would break udiv24
        lda #0
        sta m_prod
        sta m_prod+1
        sta m_prod+2
?red0   lda #0                       ; m_den = texH*256 (one texture tile, Q8)
        sta m_den
        lda rs_texh_cur
        sta m_den+1
        jsr udiv24                   ; m_rem = wt inside the tile (destroys m_prod)
        lda m_rem
        sta tw_wt
        lda m_rem+1
        sta tw_wt+1
        ; ---- source select. The 8x expander is BY FAR the most expensive blit in
        ;      the frame: it costs 2 VBXE cycles per destination byte (vbxe.cpp
        ;      :3861), so a full texH=128 column is 1024*2 = 2048 cycles, and the
        ;      blitter only gets 912 per scanline (vbxe.cpp:1827). A span almost
        ;      never needs the whole column, so expand exactly the texel range it
        ;      touches: [wt>>8 .. (wt + h*tpr)>>8]. Only a span that wraps past
        ;      texH falls back to the full column.
?srcsel lda #0
        sta tw_soff
        sta tw_soff+1
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
        lda #0
        sta tw_tile+1
        jmp tw_runs                  ; raw texture column: straight to the run loop
?exp8
    .if TW_SAFE
        jmp ?full                    ; TW_SAFE: always expand the whole column
    .endif
        lda tw_wt+1                  ; t0 = first texel the span touches
        sta tw_t0
        qsmul tw_h, rs_tpr, qs_p           ; m_prod = h*tpr + wt  -> last texel at >>8
        lda qs_p
        sta m_prod
        lda qs_p+1
        sta m_prod+1
        lda #0
        sta m_prod+2
        qsmul tw_h, rs_tpr+1, qs_p
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
        clc
        lda m_prod
        adc tw_wt
        sta m_prod
        lda m_prod+1
        adc tw_wt+1
        sta m_prod+1
        lda m_prod+2
        adc #0
        sta m_prod+2
        bne ?full                    ; last texel >= 256 -> past any texH
        sec                          ; need = t1 - t0 + 1
        lda m_prod+1
        sbc tw_t0
        clc
        adc #1
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
        ; the column again. Padding is nearly free (the expander writes whole
        ; source rows anyway) -- but only while it stays inside the texture.
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
        jmp ?tile8
?full   lda #0                       ; whole column: t0 = 0, need = texH
        sta tw_t0
        lda rs_texh_cur
        sta tw_need
?tile8
        jsr tw_expand                ; texels [t0, t0+need) -> VRAM_TEX8 (or a
                                     ;   cache hit on a range that contains them)
        ; The scratch may hold MORE than was asked for (cache hit on a superset),
        ; so the source offset and the tile length come from what is actually in
        ; it -- tw_lastt0/tw_lastneed -- not from tw_t0/tw_need.
        lda tw_lastt0                ; tw_soff = lastt0 * S (samples)
        sta tw_soff
        lda #0
        sta tw_soff+1
        jsr ?x8soff
        lda tw_lastneed              ; tile = lastneed * S samples
        sta tw_tile
        lda #0
        sta tw_tile+1
        ldy tw_ssh
        beq ?tdone
?tlp    asl tw_tile
        rol tw_tile+1
        dey
        bne ?tlp
?tdone
        ; NO tw_base store here: tw_expand owns it now -- the expander alternates
        ; between TWO scratches, and re-pointing at the fixed VRAM_TEX8 made the
        ; runs read the OTHER scratch's stale column (2026-07-28: banding bug)
        jmp tw_runs                  ; the run loop lives in FAST RAM (see below)
?x8soff ldy tw_ssh                   ; tw_soff *= S
        beq ?x8done
?x8lp   asl tw_soff
        rol tw_soff+1
        dey
        bne ?x8lp
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
;   Measured 2026-07-25: textured mode cost ~1 ms per column more than flat,
;   which is what this loop's instruction fetches cost at bus speed while it
;   sat in $8000-$BFFF (never a Rapidus fast window -- the MEMAC window at
;   $9000 lives there). The MEMW stores below still cross the bus at 1.79 --
;   that is the VBXE itself and cannot be faster; only the fetches sped up.
;   Entered with everything set up: tw_base/tw_tile/tw_soff/tw_wt + the BCB.
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
        sec                          ;   rows. tw_spy/tw_zoomv go into every link
        sbc #1                       ;   tw_blit emits (chained BCBs)
        asl
        asl
        asl
        asl
        sta tw_zoomv
        ; ======================= one run per source tile =======================
?run    lda tw_use8                  ; tw_off = wt >> 5 (samples) or wt >> 8 (texels)
        beq ?offraw
        lda tw_wt
        sta tw_off
        lda tw_wt+1
        sta tw_off+1
        ldy tw_rsh
?sh5    lsr tw_off+1
        ror tw_off
        dey
        bne ?sh5
        sec                          ; relative to the first expanded texel
        lda tw_off
        sbc tw_soff
        sta tw_off
        lda tw_off+1
        sbc tw_soff+1
        sta tw_off+1
        jmp ?havoff
?offraw lda tw_wt+1
        sta tw_off
        lda #0
        sta tw_off+1
        ; n = SOURCE rows this run may use = min(TW_RUNROWS, rows left in tile).
        ; The run is capped anyway, so first just check whether a FULL run would
        ; still land inside the tile -- it usually does, and then the divide is
        ; skipped entirely (it used to cost more than the blit it set up).
?havoff qsmul tw_cnm1, tw_spy, qs_p        ; (TW_RUNROWS-1) * spy
        clc
        lda qs_p
        adc tw_off
        sta m_a
        lda qs_p+1
        adc tw_off+1
        sta m_a+1
        cmp tw_tile+1                ; last sample < tile -> full run fits
        bcc ?nfull
        bne ?nslow
        lda m_a
        cmp tw_tile
        bcc ?nfull
?nslow  sec                          ; near the tile end: n = (tile-1-off)/spy + 1
        lda tw_tile
        sbc #1
        sta m_prod
        lda tw_tile+1
        sbc #0
        sta m_prod+1
        sec
        lda m_prod
        sbc tw_off
        sta m_prod
        lda m_prod+1
        sbc tw_off+1
        sta m_prod+1
        lda tw_spy
        sta m_den
        lda tw_spy+1
        sta m_den+1
        jsr udiv16
        lda m_quot+1
        bne ?ncap
        lda m_quot
        cmp #TW_RUNROWS
        bcc ?nok
?ncap   lda #TW_RUNROWS-1
?nok    clc
        adc #1
        sta tw_n
        jmp ?haven
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
        clc
        adc #1
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
        lda #0
        sta tw_r
        jmp ?emit
?spanlim lda tw_rem                  ; span-limited: dr = rem, n1 = dr/rpt + rest
        sta tw_dr
        lda #0
        sta tw_dr+1
        sta tw_lim
        lda tw_rpt
        cmp #1
        bne ?sdiv
        lda tw_dr                    ; rpt == 1 -> one source row per dest row
        sta tw_n1
        lda #0
        sta tw_r
        jmp ?emit
?sdiv   lda tw_dr
        sta m_prod
        lda #0
        sta m_prod+1
        lda tw_rpt
        sta m_den
        lda #0
        sta m_den+1
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
        sec
        sbc #1
        sta tw_bh                    ; HEIGHT = SOURCE rows - 1
        lda tw_off
        sta tw_boff
        lda tw_off+1
        sta tw_boff+1
        jsr tw_blit
?rest   lda tw_r
        bne ?dorest
        jmp ?adv
?dorest qsmul tw_n1, tw_rpt, qs_p          ; the leftover rows continue the last sample
        clc
        lda tw_row
        adc qs_p
        sta tw_brow
        lda tw_r
        sec
        sbc #1
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
        bne ?more
        jmp ?out                     ; span-limited -> the span is done
?more   dec tw_guard
        bne ?keeprun
        jmp ?fill
?keeprun
        qsmul tw_dr, rs_tpr, qs_p          ; wt += dr*tpr (dr is a byte -> 2 qsmuls),
        lda qs_p                     ; then reduce mod texH*256
        sta m_prod
        lda qs_p+1
        sta m_prod+1
        lda #0
        sta m_prod+2
        qsmul tw_dr, rs_tpr+1, qs_p
        clc
        lda m_prod+1
        adc qs_p
        sta m_prod+1
        lda m_prod+2
        adc qs_p+1
        sta m_prod+2
        clc
        lda m_prod
        adc tw_wt
        sta m_prod
        lda m_prod+1
        adc tw_wt+1
        sta m_prod+1
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
        ; often down it (tiny texH on a tall wall). Rather than leave a hole, hold
        ; the current sample over the rest of the span: a flat band, but no garbage.
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

