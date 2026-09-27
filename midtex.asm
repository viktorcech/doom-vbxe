;--------------------------------------------------------------
; midtex.asm -- see-through walls: the two-sided MIDDLE texture (struts, grilles),
;   drawn in a masked pass after the solid walls.
;--------------------------------------------------------------
mtx_t       = cx_b                   ; snapshot: this column's window top
mtx_b       = cx_b+1                 ;           ... and bottom (255 = closed)
mtx_t0      = cx_d                   ; snapshot: the FIRST column's window, for
mtx_b0      = cx_d+1                 ;   the uniform test

mtx_resume = *

        org MSEG_BASE
;--------------------------------------------------------------
; mid_planes -- the pair of world heights the column loop projects as this
;   strut's "ceiling" and "floor", i.e. the top and bottom of the drawn span.
;   IN : ms_i (mseg_draw's cursor), zp_pz.  OUT: rs_wtop/rs_wbot/rs_worldh.
;   in its dominant colour -- ugly, not fatal. Clobbers A/X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        rep #$20                     ; worldh = top - bottom, one word subtract
        .LONGA ON                    ;   (drac030 idiom)
        sec
        lda rs_wtop
        sbc rs_wbot
        sta rs_worldh
        .LONGA OFF
        sep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; The three one-line stand-ins process_seg calls in place of instructions it
; already had, so the masked pass costs its segment ONE byte -- it ends 14 below
; load_dtab ($3BC3) and there was nowhere for a test to go.
;--------------------------------------------------------------
mtx_peg_resume = *
        org MTXPEG_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mtx_pegf                       ; = lda rs_pegf
        lda rs_mpass
        beq ?wall
        jsr mid_planes               ; the masked pass, and this is the last
                                     ;   point before the front planes are laid ...
        lda rs_midtex                ; ... then answer with the MIDTEX row's bare
        rts                          ;   texid, whose peg bits read as 0 -- which
?wall   lda rs_texw                  ;   is what a middle texture wants
        rts
.endp
        .endseg
    .if * > MTXPEG_END+1
        ert 'mtx_pegf outgrew MTXPEG_BASE..END (memory_map.inc)'
    .endif
        org mtx_peg_resume

;--------------------------------------------------------------
; mtx_hook -- = jsr seg_yoff, plus the two-sided MIDDLE texture's own business
;   at the same point: the WALK defers such a seg (mseg_snap), the masked pass
;   prepares the window arrays for it (mseg_prime).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
                                      ; 2026-09-23: straight to mseg_snap, not a branch
        jne mseg_snap                ;   onto a `bra` (in range: a plain bne)
?prime
?ret    rts
.endp
        .endseg


; --- the other stand-ins. They lived in win2 ("nowhere fast left") until
;     2026-08-31, when the day's evictions opened the $1EF0/$4D3C holes and
;     MTXBACK_BASE/MTXPEG_BASE moved there -- ~1 ms/frame of x11.2 fetches
;     back at ~29 mid-segs (memory_map.inc).
mtx_back_resume = *
        org MTXBACK_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mtx_back                       ; = cmp #NO_SECTOR
        ldy rs_mpass
        beq ?real
        lda #NO_SECTOR               ; the masked pass answers ONE-SIDED
?real   cmp #NO_SECTOR
        rts
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mtx_occ                        ; = ldx zp_xa
        lda rs_mpass
        beq ?keep
        jsr mseg_prime               ; the walk closed every one of these columns
?keep   ldx zp_xa                    ;   -- put the snapshot back before the
        rts                          ;   "all solid, drop the seg" scan sees them
.endp
        .endseg

        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mtx_flat                       ; = lda tex_flat
        lda rs_mpass                 ; 'T' FLATTENS WALLS, NOT STRUTS. The toggle
        bne ?on                      ;   exists to take the per-column texture
        lda tex_flat                 ;   work off thousands of wall columns; a
        rts                          ;   frame has a handful of masked segs, so
?on     lda #0                       ;   painting those properly costs nothing
        rts                          ;   measurable -- and flat is the one thing
                                     ;   a see-through texture cannot be.
.endp
        .endseg
    .if * > MTXBACK_END+1
        ert 'mtx_back/mtx_occ outgrew MTXBACK_BASE..END (memory_map.inc)'
    .endif
        org mtx_back_resume

;--------------------------------------------------------------
; mseg_snap -- this seg has a middle texture: remember it for the masked pass.
;   IN: zp_xa/zp_xb, rs_segi. Clobbers A/X/Y, cx_b/cx_d.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
	inc
        asl @                        ;   sprites -- two wide struts and the third
                                     ;   fell off the end and was dropped, which
        adc sp_clip                  ;   is a strut that blinks as you turn
                                     ;   (NO clc: (xb-xa)>>2+1 <= 40, so the asl
                                     ;   cannot carry out -- 2026-08-31)
        bcs ?drop                    ;   (measured: 77 columns = 154 B, tools/
                                     ;    tests/_dbg_midtex.py).
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
	bra ?put
?closed lda #255                     ; 255/255 = fully covered, the same "no
        sta mtx_t                    ;   window" spr_add writes
        sta mtx_b
?put    txa                          ; only every FOURTH column reaches the pool,
        and #3                       ;   and the FIRST one whatever xa is -- that
        beq ?wr                      ;   is what lets mseg_prime step its cursor
        cpx zp_xa                    ;   off the same absolute grid without
        bne ?nx                      ;   carrying (X - xa) around. The uniform
                                     ;   check below sees the SAMPLED columns ...
?wr     lda mtx_t
        sta (sp_clip),y
        iny
        lda mtx_b
        sta (sp_clip),y
        iny
        cpy #2
        beq ?first
        cmp mtx_b0                   ; A still holds mtx_b (iny/cpy leave it): test
        bne ?unot                    ;   the bottom first, one load fewer -- the two
        lda mtx_t                    ;   equalities have no order (2026-09-15)
        cmp mtx_t0
        beq ?nx
?unot
	stz ms_uni
	bra ?nx
?first  sta mtx_b0                   ; (A = mtx_b here as well; A is dead at ?nx)
        lda mtx_t
        sta mtx_t0
?nx     cpx zp_xb
        beq ?done
        inx
        bra ?snap		;bra?

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
        .endseg

;--------------------------------------------------------------
; mseg_win -- the masked pass's per-column clip, called from the column loop
;   once rs_pyc16/rs_pyf16 hold the mid texture's own top and bottom rows.
;   Narrows [rs_top,rs_bot] to that span, which is what collapses the loop's
;   ceiling and floor fills to empty ranges (see the header). C = 1 -> nothing
;   open in this column and the loop skips it. Preserves X.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
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
        .endseg

    .if * > MSEG_END+1
        ert 'mid_planes/mseg_snap/mseg_win outgrew MSEG_BASE..MSEG_END (memory_map.inc)'
    .endif

;--------------------------------------------------------------
; mseg_prime -- put the snapshot back where the column loop looks for it.
;   Clobbers A/X/Y.
;--------------------------------------------------------------
        org MSEGPRE_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mseg_prime
        lda ms_cur                   ; sp_clip+1 is $07 already and cannot be
        and #$FE                     ;   anything else: CLIP_BASE is page
        sta sp_clip                  ;   aligned, spr_reset sets the high byte,
                                     ;   and every allocator checks its block
                                     ;   against the page end before committing.
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
        cpx zp_xb                    ; the snapshot samples every FOURTH column
        beq ?done                    ;   (mseg_snap ?put): the three between it
        inx                          ;   reuse the pair just read, and the cursor
        txa                          ;   steps when the NEXT column starts a
        and #3                       ;   group of four -- (new X & 3) == 0 is
        bne ?p                       ;   the old (X & 3) == 3, tested after the
        tya                          ;   end test (a step past xb was dead work)
        clc
        adc ms_cstep
        tay
        bra ?p
?done   rts
.endp
        .endseg
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
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mseg_draw
        lda ms_n
        bne ?go
        sta rs_mpass                 ; A = 0, and this doubles as the flag's only
        rts                          ;   INIT: it lives in $1000-$13FF, which is
                                     ;   also the SIO staging buffer, so a level
                                     ;   load leaves it holding stream bytes.
?go     sta ms_i
    .if TEX_RUNS
        jsr ptc_open                    ; RE-SYNC THE PAINTER'S BUILDER before
                                     ;   emitting anything.
    .endif
        lda #1
        sta rs_mpass
                                      ; 2026-09-22: process_seg's column loop takes
        lda #$80                     ;   the masked path by a patched `bra msko` at
        sta.l B1CODE_BASE+process_seg.mskj   ;   mskj, for the whole pass
        lda #<[process_seg.msko-process_seg.mskj-2]
        sta.l B1CODE_BASE+process_seg.mskj+1
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
        lda #$86                     ; ...and mskj back to `stx zp_col` ($86 = stx dp)
        sta.l B1CODE_BASE+process_seg.mskj
        lda #zp_col
        sta.l B1CODE_BASE+process_seg.mskj+1
    .if TEX_RUNS
        jmp ptc_fire                    ; LAUNCH what is still in the painter's
                                     ;   (tail call, both in bank $01)
                                     ;   chain.
    .else
        rts
    .endif
.endp
        .endseg
    .if * > MSEGDRW_END+1
        ert 'mseg_draw outgrew MSEGDRW_BASE..END (memory_map.inc)'
    .endif

        org mtx_resume
