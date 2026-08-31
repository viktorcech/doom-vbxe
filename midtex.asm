;==============================================================
; midtex.asm -- SEE-THROUGH walls: the two-sided MIDDLE texture.
;
; WHAT WAS MISSING. A DOOM sidedef has three texture slots and the port shipped
; two of them: the solid middle / portal upper (col_a) and the portal lower
; (col_b). The third -- the MIDDLE texture of a TWO-SIDED line -- is the one
; that draws the big brown support struts (BRNBIGL/C/R), the small ones
; (BRNSMAL*) and the window grilles: geometry you look THROUGH, hung in an
; opening you can also walk through. Episode 1 has 91 of them, and without this
; the room past E1M1's first door has nothing in it at all (plot.png).
;
; WHY IT CANNOT BE DRAWN IN THE WALK. The BSP walk paints FRONT TO BACK and a
; column is finished the moment something opaque closes it. A masked texture
; closes nothing -- the wall BEHIND it still has to be painted, and it is
; painted LATER. So the strut has to be drawn after the walk, over the top,
; which is exactly what r_segs.c does (R_StoreWallRange defers it and
; R_RenderMaskedSegRange draws it from R_DrawMasked, after the sprites).
;
; HOW IT IS DONE HERE, in three parts:
;
;   1. COLLECT (mseg_snap, called from process_seg's ?have_planes). A two-sided
;      seg whose MAP_SEGMID entry is not $FF snapshots the OCCLUSION WINDOW over
;      its columns -- the rows nearer geometry has already taken -- into the
;      sprite clip pool, and appends (seg index, clip block) to a small list.
;      The snapshot is the one thing the second visit cannot recompute;
;      everything else is a function of the seg and the player, and both still
;      hold when the pass runs.
;
;   2. REPLAY (mseg_draw -> process_seg with rs_mpass = 1). The list is walked
;      BACKWARDS, i.e. far to near, and each seg goes through the very same
;      process_seg: same transform, same projection, same column loop, same
;      painter. Four tests inside it read rs_mpass and change three things:
;        * the texture comes from MAP_SEGMID instead of the seg record;
;        * the front ceiling/floor planes become the MID TEXTURE's own top and
;          bottom (mid_planes), so the "wall" the loop draws IS the strut;
;        * the portal branch is skipped -- rs_isport = 0, so it takes the solid
;          path, which draws one span and no upper/lower step.
;
;   3. CLIP (mseg_prime + mseg_win). The column loop reads its window out of
;      ytopc_arr/ybotc_arr, so mseg_prime writes the snapshot back into them
;      (and clears solid_arr, which the walk left set). mseg_win then narrows
;      that window to the texture's own span, and THAT is what makes the reuse
;      work: with the window equal to [pyc,pyf], the loop's ceiling fill
;      (top..pyc-1) and floor fill (pyf+1..bot) are both empty ranges and
;      draw_clip drops them, so the only thing that reaches the screen is the
;      textured span in between.
;
; THE TRANSPARENCY ITSELF is in the DATA and costs the painter six cycles a run:
; a stored run whose colour is PLAYPAL index 0 is skipped (paint.asm ?ynok), and
; tools/texruns.py guarantees index 0 never appears in an opaque texture --
; exact_idx excludes it, and wadtex composes a masked texture with 0 meaning
; "no patch covered this texel".
;
; WHAT IS DELIBERATELY NOT DOOM:
;   * Masked segs are drawn as ONE pass, before the sprites. DOOM interleaves
;     them: R_DrawSprite scans the drawsegs and, the moment one is BEHIND the
;     sprite it is about to draw, renders that masked range there and then
;     (r_things.c:891), marking each column done (maskedtexturecol[x] =
;     MAXSHORT) so its final sweep only picks up what no sprite ever covered.
;     That is per SPRITE and per COLUMN. Matching it needs a depth key per
;     masked seg (rs_sscl at collect time, 2 arrays) and a merge of the two
;     back-to-front walks -- about 45 bytes of code, and the 6502 map has none.
;     Of the two flat orders this is the right one: the struts stand on the
;     walls of the room the player is IN, so nearly everything that shares the
;     screen with them is in front (l1/l2.png -- a candelabra swallowed by the
;     braces; pc1/pc2.png -- the same lamp whole on the PC). The mirror error,
;     a thing BEHIND a strut drawing over it, needs the far side of a window
;     to be occupied.
;   * The texture does not tile vertically. Neither does vanilla's: the span is
;     the intersection of the opening with ONE texture height, which is what
;     mid_planes computes.
;   * Column merging is off for these segs (mseg_win parks cm_x = $FF). The
;     merge copies SCREEN pixels sideways, and behind a strut those include the
;     wall showing through the gaps, which differs column by column.
;
; SCRATCH. mid_planes and mseg_snap borrow cx_a..cx_d, the backface test's
; zero-page cross-product operands. Those are written at the TOP of process_seg
; and read only by the test itself, so from ?whave on they are dead for the rest
; of the seg -- and zero page is what keeps these two routines inside the block
; the seg table left behind.
;==============================================================
mtx_t       = cx_b                   ; snapshot: this column's window top
mtx_b       = cx_b+1                 ;           ... and bottom (255 = closed)
mtx_t0      = cx_d                   ; snapshot: the FIRST column's window, for
mtx_b0      = cx_d+1                 ;   the uniform test

mtx_resume = *

        org MSEG_BASE
;--------------------------------------------------------------
; mid_planes -- the pair of world heights the column loop projects as this
;   strut's "ceiling" and "floor", i.e. the top and bottom of the drawn span.
;
;   r_segs.c derives them per frame: two min/max pairs for the opening, then
;   the ML_DONTPEGBOTTOM anchor, then a clip. All of that is two sector heights
;   and a texture height -- constants, because pack_map.py asserts no strut
;   hangs on a door or lift sector -- so the MIDTEX row already holds the
;   answer and this only has to make it eye-relative. The whole calculation in
;   6502 came to ~180 bytes of a 628-byte budget; this is 90.
;
;   THE PEG needs no code at all. process_seg's ONE-SIDED branch, which the
;   masked pass takes (mtx_back), already answers ML_DONTPEGBOTTOM with
;   rs_vshw = (-worldh) mod texH -- and for a strut standing on the opening's
;   floor the texels above the drawn span ARE texH - worldh. Without the flag
;   both come out 0. So the anchor falls out of the rule that is already there.
;
;   IN : ms_i (mseg_draw's cursor), zp_pz.  OUT: rs_wtop/rs_wbot/rs_worldh.
;   Cannot fail: pack_map.py asserts every MIDTEX row's span is positive, and
;   SHIP_ALL_TEXTURES gives every mid texture pixels. Were one ever shipped
;   without them, rs_wtexid comes back $FF and the column loop paints the span
;   in its dominant colour -- ugly, not fatal. Clobbers A/X.
;--------------------------------------------------------------
.proc mid_planes
        ldx ms_i                     ; the entry mseg_draw is replaying ...
        lda ms_ixa,x                 ; ... and its MIDTEX row
        tax
        sec
        lda.l MTXTLO_EXT,x
        sbc zp_pz
        sta rs_wtop
        lda.l MTXTHI_EXT,x
        sbc zp_pz+1
        sta rs_wtop+1
        sec
        lda.l MTXBLO_EXT,x
        sbc zp_pz
        sta rs_wbot
        lda.l MTXBHI_EXT,x
        sbc zp_pz+1
        sta rs_wbot+1
        sec
        lda rs_wtop
        sbc rs_wbot
        sta rs_worldh
        lda rs_wtop+1
        sbc rs_wbot+1
        sta rs_worldh+1
        rts
.endp

;--------------------------------------------------------------
; The three one-line stand-ins process_seg calls in place of instructions it
; already had, so the masked pass costs its segment ONE byte -- it ends 14 below
; load_dtab ($3BC3) and there was nowhere for a test to go.
;--------------------------------------------------------------
mtx_peg_resume = *
        org MTXPEG_BASE
.proc mtx_pegf                       ; = lda rs_pegf
        lda rs_mpass
        beq ?wall
        jsr mid_planes               ; the masked pass, and this is the last
                                     ;   point before the front planes are laid
                                     ;   down: swap the front sector's ceiling
                                     ;   and floor for the strut's own span
        lda rs_midtex                ; ... then answer with the MIDTEX row's bare
        rts                          ;   texid, whose peg bits read as 0 -- which
?wall   lda rs_pegf                  ;   is what a middle texture wants
        rts
.endp
    .if * > MTXPEG_END+1
        ert 'mtx_pegf outgrew MTXPEG_BASE..END (memory_map.inc)'
    .endif
        org mtx_peg_resume

;--------------------------------------------------------------
; mtx_hook -- = jsr seg_yoff, plus the two-sided MIDDLE texture's own business
;   at the same point: the WALK defers such a seg (mseg_snap), the masked pass
;   prepares the window arrays for it (mseg_prime).
;--------------------------------------------------------------
.proc mtx_hook
        jsr seg_yoff
        lda rs_mpass
        bne ?prime                   ; the masked pass was primed by mtx_occ
        rep #$10                     ; MAP_SEGMID[seg]: which MIDTEX row this seg
        ldx rs_segi                  ;   uses, $FF = it has no middle texture.
        lda.l SEGMID_EXT,x           ;   $FF for every one-sided seg too, so no
        sep #$10                     ;   separate test is needed.
        sta rs_midtex
        cmp #$FF
        bne ?snap
?prime
?ret    rts
?snap   jmp mseg_snap
.endp


; --- the other stand-ins. They lived in win2 ("nowhere fast left") until
;     2026-08-31, when the day's evictions opened the $1EF0/$4D3C holes and
;     MTXBACK_BASE/MTXPEG_BASE moved there -- ~1 ms/frame of x11.2 fetches
;     back at ~29 mid-segs (memory_map.inc).
mtx_back_resume = *
        org MTXBACK_BASE
.proc mtx_back                       ; = cmp #NO_SECTOR
        ldy rs_mpass
        beq ?real
        lda #NO_SECTOR               ; the masked pass answers ONE-SIDED
?real   cmp #NO_SECTOR
        rts
.endp

.proc mtx_occ                        ; = ldx zp_xa
        lda rs_mpass
        beq ?keep
        jsr mseg_prime               ; the walk closed every one of these columns
?keep   ldx zp_xa                    ;   -- put the snapshot back before the
        rts                          ;   "all solid, drop the seg" scan sees them
.endp

.proc mtx_flat                       ; = lda tex_flat
        lda rs_mpass                 ; 'T' FLATTENS WALLS, NOT STRUTS. The toggle
        bne ?on                      ;   exists to take the per-column texture
        lda tex_flat                 ;   work off thousands of wall columns; a
        rts                          ;   frame has a handful of masked segs, so
?on     lda #0                       ;   painting those properly costs nothing
        rts                          ;   measurable -- and flat is the one thing
                                     ;   a see-through texture cannot be. Flat
                                     ;   would paint the opening SHUT in its
                                     ;   dominant colour, which is why mtx_hook
                                     ;   used to refuse to collect them at all
                                     ;   ("no hint of it there") -- the wrong
                                     ;   half of the choice.
.endp
    .if * > MTXBACK_END+1
        ert 'mtx_back/mtx_occ outgrew MTXBACK_BASE..END (memory_map.inc)'
    .endif
        org mtx_back_resume

;--------------------------------------------------------------
; mseg_snap -- this seg has a middle texture: remember it for the masked pass.
;
;   The snapshot is the OCCLUSION window as it stands BEFORE this seg draws
;   anything, i.e. what nearer geometry has already taken. It goes into the
;   SPRITE clip pool, in the same layout and with the same uniform collapse
;   spr_add uses (bit 0 of the block address = "one window for every column"),
;   because in an open room the window IS uniform and the whole seg then costs
;   two bytes of a 256-byte page.
;
;   Anything that does not fit -- the list full, the block bigger than the page,
;   every column closed -- DROPS the seg. A missing strut is a missing strut; a
;   wrongly clipped one is a strut floating over the wall in front of it.
;   IN: zp_xa/zp_xb, rs_segi. Clobbers A/X/Y, cx_b/cx_d.
;--------------------------------------------------------------
.proc mseg_snap
        lda ms_n
        cmp #MSEG_MAX
        bcc ?room
?drop   rts
?room   sec                          ; the block is 2*ceil(columns/4) bytes: the
        lda zp_xb                    ;   snapshot SAMPLES every fourth column
        sbc zp_xa                    ;   (?put below), and the three between take
        lsr @                        ;   their neighbour's window.
        lsr @
        clc                          ; A 160-column seg is 80 bytes at 2 B each
        adc #1                       ;   and the pool is ONE page shared with the
        asl @                        ;   sprites -- two wide struts and the third
                                     ;   fell off the end and was dropped, which
        adc sp_clip                  ;   is a strut that blinks as you turn
                                     ;   (NO clc: (xb-xa)>>2+1 <= 40, so the asl
                                     ;   cannot carry out -- 2026-08-31)
        bcs ?drop                    ;   (measured: 77 columns = 154 B, tools/
                                     ;    tests/_dbg_midtex.py). Quartering costs
                                     ;   at most three columns of lag where a
                                     ;   nearer edge cuts the strut -- under two
                                     ;   degrees -- and buys a 4x margin.
        lda sp_clip
        sta ms_cbase
        lda #1
        sta ms_uni
        ldx zp_xa
        ldy #0                       ; Y is the cursor into the block and stays
                                     ;   live for the whole loop -- nothing in
                                     ;   it touches Y
?snap   lda solid_arr,x
        bne ?closed
        lda ytopc_arr,x
        cmp ybotc_arr,x
        beq ?open
        bcs ?closed                  ; top > bot -> nothing open in this column
?open   sta mtx_t
        lda ybotc_arr,x
        sta mtx_b
        jmp ?put
?closed lda #255                     ; 255/255 = fully covered, the same "no
        sta mtx_t                    ;   window" spr_add writes
        sta mtx_b
?put    txa                          ; only every FOURTH column reaches the pool,
        and #3                       ;   and the FIRST one whatever xa is -- that
        beq ?wr                      ;   is what lets mseg_prime step its cursor
        cpx zp_xa                    ;   off the same absolute grid without
        bne ?nx                      ;   carrying (X - xa) around. The uniform
                                     ;   check below sees the SAMPLED columns
                                     ;   only, which is exactly what the block
                                     ;   holds -- so "uniform" still means "one
                                     ;   pair reproduces this block".
?wr     lda mtx_t
        sta (sp_clip),y
        iny
        lda mtx_b
        sta (sp_clip),y
        iny
        cpy #2
        beq ?first
        lda mtx_t
        cmp mtx_t0
        bne ?unot
        lda mtx_b
        cmp mtx_b0
        beq ?nx
?unot   lda #0
        sta ms_uni
        beq ?nx                      ; (always: A = 0)
?first  lda mtx_t
        sta mtx_t0
        lda mtx_b
        sta mtx_b0
?nx     cpx zp_xb
        beq ?done
        inx
        jmp ?snap
?done   lda ms_uni
        beq ?keep
        lda mtx_t0
        cmp #255
        bne ?uni                     ; uniform AND closed -> invisible, and a
        rts                          ;   dropped seg must not eat a list slot
?uni    ldy #2                       ; uniform -> hand the pool back all but the
?keep   tya                          ;   one pair
        clc
        adc sp_clip
        sta sp_clip
        ldx ms_n
        lda rs_segi
        sta ms_slo,x
        lda rs_segi+1
        sta ms_shi,x
        lda zp_sptr                  ; the record address too: the replay would
        sta ms_plo,x                 ;   otherwise redo segi*8 for it
        lda zp_sptr+1
        sta ms_phi,x
        lda rs_midtex                ; ... and the MIDTEX row (mtx_hook read it)
        sta ms_ixa,x
        lda ms_uni                   ; blocks are 2 B aligned, so bit 0 is free
        eor #1                       ;   to carry the format: 1 = PER-COLUMN, so
        ora ms_cbase                 ;   mseg_prime's step is one AND and a shift
        sta ms_cpl,x
        inc ms_n
        rts
.endp

;--------------------------------------------------------------
; mseg_win -- the masked pass's per-column clip, called from the column loop
;   once rs_pyc16/rs_pyf16 hold the mid texture's own top and bottom rows.
;   Narrows [rs_top,rs_bot] to that span, which is what collapses the loop's
;   ceiling and floor fills to empty ranges (see the header). C = 1 -> nothing
;   open in this column and the loop skips it. Preserves X.
;--------------------------------------------------------------
.proc mseg_win
        lda #$FF                     ; never merge a masked column: the copy
        sta cm_x                     ;   would carry the background showing
                                     ;   through the gaps sideways with it
        cmp rs_top                   ; 255 = the snapshot says nearer geometry
        beq ?closed                  ;   took this column whole (A = $FF)
        lda rs_pyc16+1               ; rs_top = max(rs_top, pyc16)
        bmi ?tkeep                   ;   above the screen -> the window wins
        bne ?closed                  ;   below it -> nothing to draw
        lda rs_pyc16
        cmp rs_top
        bcc ?tkeep
        sta rs_top
?tkeep  lda rs_pyf16+1               ; rs_bot = min(rs_bot, pyf16)
        bmi ?closed
        bne ?bkeep
        lda rs_pyf16
        cmp rs_bot
        bcs ?bkeep
        sta rs_bot
?bkeep  lda rs_bot
        cmp rs_top
        bcc ?closed
        clc
        rts
?closed sec
        rts
.endp

    .if * > MSEG_END+1
        ert 'mid_planes/mseg_snap/mseg_win outgrew MSEG_BASE..MSEG_END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mseg_prime -- put the snapshot back where the column loop looks for it.
;   The walk left solid_arr set on nearly every column and ytopc/ybotc carrying
;   a closed column's SCALE (cm_sscl2), so both have to be rewritten over this
;   seg's span before the loop runs again. sp_clip is borrowed as the reader:
;   the sprite pool's allocator is finished for the frame by the time this runs.
;   Clobbers A/X/Y.
;--------------------------------------------------------------
        org MSEGPRE_BASE
.proc mseg_prime
        lda ms_cur                   ; sp_clip+1 is $07 already and cannot be
        and #$FE                     ;   anything else: CLIP_BASE is page
        sta sp_clip                  ;   aligned, spr_reset sets the high byte,
                                     ;   and every allocator checks its block
                                     ;   against the page end before committing.
                                     ;   Those four bytes went to the sampling
                                     ;   step below.
        lda ms_cur
        and #1                       ; bit 0 = per-column -> step 2; a single
        asl @                        ;   window for the whole seg -> step 0
        sta ms_cstep
        ldx zp_xa
        ldy #0
?p      lda (sp_clip),y
        sta ytopc_arr,x
        iny
        lda (sp_clip),y
        sta ybotc_arr,x
        dey
        stz solid_arr,x              ; 65816 stz abs,x: 2 cycles and 2 bytes off
                                     ;   EVERY replayed column (drac030
                                     ;   hand-review, 2026-08-31)
        txa                          ; the snapshot samples every FOURTH column
        and #3                       ;   (mseg_snap ?put): the three between it
        cmp #3                       ;   reuse the pair just read, and the cursor
        bne ?nadv                    ;   steps at the END of each group of four
        tya
        clc
        adc ms_cstep
        tay
?nadv   cpx zp_xb
        beq ?done
        inx
        jmp ?p
?done   rts
.endp
    .if * > MSEGPRE_END+1
        ert 'mseg_prime outgrew MSEGPRE_BASE..END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mseg_draw -- the masked pass. Walk the collected segs BACKWARDS (the BSP walk
;   hands them over front to back, so backwards is far to near) and send each
;   one through process_seg again with rs_mpass set. Called from render_world
;   after spr_draw -- vanilla's own order.
;--------------------------------------------------------------
        org MSEGDRW_BASE
.proc mseg_draw
        lda ms_n
        bne ?go
        sta rs_mpass                 ; A = 0, and this doubles as the flag's only
        rts                          ;   INIT: it lives in $1000-$13FF, which is
                                     ;   also the SIO staging buffer, so a level
                                     ;   load leaves it holding stream bytes. A
                                     ;   stray value sends every seg down the
                                     ;   strut path for one frame; this is where
                                     ;   that frame ends. (render_world is the
                                     ;   natural home -- its segment ends ONE
                                     ;   byte below load_dtab.)
?go     sta ms_i
    .if TEX_RUNS
        jsr ptc_open                 ; RE-SYNC THE PAINTER'S BUILDER before
                                     ;   emitting anything. It is a no-op in the
                                     ;   order render_world uses today (the walk
                                     ;   left zp_pt and tw_chn agreeing, and
                                     ;   bg_blit fires the chain itself), but it
                                     ;   is what makes this pass independent of
                                     ;   what ran before it: every sprite column
                                     ;   that goes through the 8x expander builds
                                     ;   in slot 0 of tw_chn and then
                                     ;   tw_chain_fire FLIPS tw_chn. Run this
                                     ;   after spr_draw without re-opening and
                                     ;   the emits go to one buffer while
                                     ;   ptc_fire launches the other -- a chain
                                     ;   of stale BCBs, i.e. the blitter writing
                                     ;   whatever size to whatever address.
                                     ;   Nothing had ever painted after the
                                     ;   sprites, so the two had never had to
                                     ;   agree this late in the frame.
    .endif
        lda #1
        sta rs_mpass
?loop   dec ms_i
        ldx ms_i
        lda ms_cpl,x
        sta ms_cur
        lda ms_slo,x                 ; seg_yoff still keys off the INDEX; the
        sta rs_segi                  ;   record ADDRESS was saved beside it so
        lda ms_shi,x                 ;   the replay pays no shift chain
        sta rs_segi+1
        lda ms_plo,x                 ; (zp_sptr+2 is MAP_SEG_BANK, set once by
        sta zp_sptr                  ;  init_level and untouched since)
        lda ms_phi,x
        sta zp_sptr+1
        lda ms_ixa,x                 ; the row's TEXID: what process_seg's
        tax                          ;   texture resolve reads in place of the
        lda.l MTXTEX_EXT,x           ;   seg record's wall_tex. mid_planes finds
        sta rs_midtex                ;   the row itself, off ms_i.
        jsr process_seg
        lda ms_i
        bne ?loop
        sta rs_mpass                 ; A = 0 -- the loop just ended on it
    .if TEX_RUNS
        jmp ptc_fire                 ; LAUNCH what is still in the painter's
                                     ;   chain. Everything after render_world
                                     ;   only ever blits and waits (spr_draw,
                                     ;   draw_weapon, the status bar), so this
                                     ;   is the last chance -- ptc_frame would
                                     ;   reopen the builder next frame and the
                                     ;   strut's last runs would simply vanish.
    .else
        rts
    .endif
.endp
    .if * > MSEGDRW_END+1
        ert 'mseg_draw outgrew MSEGDRW_BASE..END (memory_map.inc)'
    .endif

        org mtx_resume
