;--------------------------------------------------------------
; paint.asm -- walls the engine PAINTS from texture runs read out of SDRAM
;   (TEX_RUNS) instead of blitting pixels from VRAM.
;--------------------------------------------------------------
PT_MAXRUN   equ 128                  ; REAL runs painted per column before the
                                     ;   tail is filled flat
PT_XB       equ 256-2*TEX_RUNK       ; 2026-09-28: the run index X starts HERE, so
                                     ;   the slot after the 32nd is its wrap to 0
                                     ;   (inx/inx/beq, no cpx); rs_tsrc arrives
                                     ;   lower by PT_XB (arena_init's tex_sdram)
    .if PT_MAXRUN+TEX_RUNK > 255 || PT_MAXRUN < TEX_RUNK
        ert 'paint_col ?lap keeps the run budget + a slot index in a byte, and never counts the first lap'
    .endif

paint_resume = *
        org TWRUNS_BASE              ; the $0900 fast page tw_runs vacates. It is
                                     ; the same Rapidus window the blit path's ...

    .ifdef FX127
;==============================================================
; FX127 (2026-10-19): the VBXE FX core 1.27 draws the wall column. A stored
; column is a 128-row PIXEL tile (pack_textures.FX127); seg_draw's tex_vget
; copies a texture's tiles into the sprites' VRAM arena on the first look
; (spr_draw.asm ar_alloc: bump + flush); wall_src hands the tile's address
; to paint_col, which emits ONE chain link: a raycasting
; container steps a 7.8 texture pixel accumulator up the tile (the step -tpr, the link
; paints bottom-up like every link) and MODE 7 shades each texture pixel through the
; sector's COLORMAP row in CMAP_VRAM. The painter below (.else) -- runs,
; the STRIP, the K-run loop -- is not assembled.
;==============================================================
    .if !FX127_TEX
        ert 'FX127: the level assets carry run textures -- pack with .\build_atr.ps1 -Fx127'
    .endif
FX_PAT   equ $04                     ; pattern byte: X size code 4 = 128 texture pixels (the
                                     ;   tile), Y code 0 (Y0 = its step = 0)
FX_CTL_W equ BLT_TABLE|BLT_NEXT|BLT_EXT|[CMAP_AUX*BLT_AUX]   ; a wall: MODE 7, the
                                     ;   COLORMAP's bank in AUX, the row in cmask
FX_CTL_M equ BLT_BSTENCIL|BLT_NEXT|BLT_EXT   ; the masked pass: texture pixel 0 see-through
                                     ;   (unshaded: MODE 1 has no table)
FX_CTL_F equ BLT_COPY|BLT_NEXT|BLT_EXT       ; a fill (constant source) or a copy
FX_RC_HDR equ $20                    ; the slot's raycasting container header: the
                                     ;   last container (the next BCB follows it in
                                     ;   the next slot). A copy link (colmerge.asm
                                     ;   CM_EMIT) jumps over it, cm_rest puts it back
zp_pt    = zp_tsrc                   ; -> the open slot's BASE (2 B; the loaders'
                                     ;   copy pointer, dead in-frame)
    .if zp_savex <> zp_pt+2
        ert 'zp_pt+2 must be zp_savex: the bank byte of [zp_pt],y, kept 0 (ptc_open)'
    .endif

;--------------------------------------------------------------
; pt_span -- a FILL link: A = the span's LAST row, Y = rows-1, B = the colour.
;   The slot paints 1 px wide, bottom-up (DST_STEPY -160: the template), a
;   constant source (AND 0), so the colour is XOR. Four bus words: XOR,
;   HEIGHT, CTRL (the slot may have held a wall), DST. OUT: X = the column,
;   16-bit A. Entry px: the row is in X already.
;--------------------------------------------------------------
        .segment B1
.proc pt_span
        tax
px      tya                          ; A = rows-1, B = the colour
        rep #$20
        .LONGA ON
        xba                          ; [16] XOR = the colour ([17], the collision
        ldy #BCB_XOR                 ;   mask, takes rows-1: a copy ignores it)
        sta [zp_pt],y
        xba
        and #$00FF                   ; [14] HEIGHT = rows-1, [15] AND = 0
        ldy #BCB_HEIGHT
        sta [zp_pt],y
        lda #FX_PAT|[FX_CTL_F<<8]    ; [19] pattern, [20] CTRL: a chained copy
        ldy #BCB_PATTERN
        sta [zp_pt],y
        lda row_hi-1,x               ; DST = row*160 + the column: row_hi[x] into B
        .LONGA OFF                   ;   by a word read, row_lo[x] under it
        sep #$20
        lda row_lo,x
        rep #$21
        .LONGA ON
pcw     adc #0                       ; + the column (patched per column: process_seg)
        ldy #BCB_DST_ADDR
        sta [zp_pt],y
pcx     ldx #0                       ; X = the column again (patched with pcw);
        lda zp_pt                    ;   C = 0: row*160+col < $8000
        adc #BCB_SLOT
        sta zp_pt
ps_cend cmp #BCB_SLOT*TW_MAXLINKS+PT_ZPOFF   ; the END slot (its high byte: ptc_open)
        beq ?full
        rts                          ; OUT 16-bit A
?full   .LONGA OFF
        sep #$20
        jsr ptc_fire                 ; (8-bit, textures.asm)
        rep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; paint_col -- a WALL column as ONE raycast link. IN at pc_in: 16-bit M, A =
;   the tile's VRAM address (low word), Y = its bank (wall_src / low_src),
;   X = the column; rs_spa/rs_spb the rows, rs_pegrow the peg row, rs_rpt the
;   rows a texture pixel, rs_vshw/rs_vshl (tx_slot) the peg shift, zp_cm the COLORMAP
;   row. X0 = the texture pixel at row spb, the step -tpr; the raycaster wraps at the
;   128-texture pixel tile. Nine bus words. Preserves X; OUT 16-bit A.
;   X0 is made from tpr with 16 fraction bits (rs_tpr Q8 + rs_tprf, the bake):
;   the hardware step is 7.8, but spb - pegrow is hundreds of rows on a near
;   wall and multiplies a Q8 tpr's rounding into whole texture pixels (2026-10-20).
;--------------------------------------------------------------
        .segment B1
.proc paint_col
        .LONGA ON
?bkj    jmp bake                     ; the rare exits' trampolines, in reach of
?wj     jmp ?wide                    ;   their branches (not taken on the common
                                     ;   path; the painter did the same)
pc_in   sta [zp_pt]                  ; [0-1] SRC lo/mid
        tya                          ; [2-3] SRC bank, SRC_STEPY lo = 0 (8-bit Y
        ldy #BCB_SRC_ADDR+2          ;   into 16-bit A: B = 0)
        sta [zp_pt],y
        lda rs_rpt                   ; rs_tpr, pc_dim and the light row follow
        cmp ptm_last                 ;   rs_rpt: baked when it changed (~30 %)
        bne ?bkj
?baked  ldy tx_slot                  ; the slot's step: the baked tpr x its tile's
        lda rs_tprk,y                ;   stretch (fx_tprk; tx_slot = 0 / 2)
        sta rs_tpr
        lda zp_cm                    ; [16-17] = (0, the COLORMAP row): zp_cm is
        sec                          ;   CMAP_EXT + row << 8, the row is the word
pccm    sbc #CMAP_EXT&$FFFF          ;   minus the base (XOR = 0 under it); the
        ldy #BCB_XOR                 ;   masked pass patches it to `and #0`: a
        sta [zp_pt],y                ;   MODE 1 cmask reads the dest (mseg_draw)
pcctl   lda #FX_PAT|[FX_CTL_W<<8]    ; [19-20] pattern + CTRL (the masked pass
        ldy #BCB_PATTERN             ;   patches the CTRL byte: mseg_draw)
        sta [zp_pt],y
        lda rs_spb                   ; [14-15] = (rows-1, AND $FF): spb - spa in
        and #$00FF                   ;   the low byte, the high byte forced. C = 1:
        sbc rs_spa                   ;   zp_cm >= CMAP_EXT (the sbc above), or the
        ora #$FF00
        ldy #BCB_HEIGHT
        sta [zp_pt],y
        lda rs_tpr                   ; the step = -tpr: its low byte at [5]
        eor #$FFFF                   ;   (SRC_STEPY hi = 0 under it), bits 14-8 at
        inc @                        ;   [26] (Y0 hi = 0 under it); the two masks
        pha                          ;   below drop bit 15
        and #$7F00                   ; [25-26] = (0, hi)
        ldy #BCB_SIZE+4
        sta [zp_pt],y
        pla
        xba
        and #$FF00                   ; [4-5] = (0, lo)
        ldy #BCB_SRC_STEPY+1
        sta [zp_pt],y
        lda rs_spb                   ; m_a = spb - pegrow, the rows under the peg
        and #$00FF                   ;   (spb >= spa >= pegrow: the clip). C = 1
        sbc rs_pegrow                ;   since `sbc rs_spa`: nothing between touches it
        sta m_a
        cmp #$0100                   ; 256+ rows under it (or above it): out of
        bcs ?wj                      ;   line. C = 0 out.
  .ifdef ANTONIA2
        ldy rs_tpr+1                 ; the card multiplies while tpr < $8000 (its
        bmi ?soft                    ;   bit 15 is unproven); m_a < 256 here
        sta.l ANT_MUL
        lda rs_tpr
        sta.l ANT_MUL+2
        lda.l ANT_MUL                ; wt = the product's low word, Q8 texture pixels
        sta m_prod
        lda m_a                      ; 2026-10-20: + (m_a x rs_tprf) >> 8, tpr's next 8
        sta.l ANT_MUL                ;   fraction bits (the byte path below does the
        lda rs_tprf                  ;   same: both builds draw the same X0)
        sta.l ANT_MUL+2
        lda.l ANT_MUL+1              ; the product's bytes 1-2 = its >> 8 (< 2^16)
        adc m_prod                   ; (C = 0: the bcs above fell through, nothing
        sta m_prod                   ;   since touched it; the sum stays under 2^16)
        bra ?havep
        .LONGA OFF
?soft
  .else
        .LONGA OFF
  .endif
        sep #$20                     ; A = m_a: the quarter-square byte x word
        qsmulx m_a, rs_tpr, m_prod, ld   ;   product (math.asm), m_prod = m_a*tpr_lo
        qsmulxa m_a, rs_tpr+1            ;   + (m_a*tpr_hi) << 8, in A:B
        rep #$21
        .LONGA ON
        stz m_prod+2
        adc m_prod+1
        sta m_prod+1                 ; (m_prod's low word is wt: Q8 texture pixels)
?frac   pei (m_prod)                 ; 2026-10-20: + (m_a x rs_tprf) >> 8, tpr's next 8
        lda rs_tprf                  ;   fraction bits: wt parks on the stack while
        sta m_b                      ;   umul16w makes the product (16-bit in and out,
        jsr umul16w                  ;   65816-windows: the callee's own window; bank
        clc                          ;   $01 had no room for an 8 x 8 of its own here,
        lda m_prod+1                 ;   ~35 cycles a column). A Q8 tpr alone stepped
        adc 1,s                      ;   X0 by two texture pixels every few columns on
        sta m_prod                   ;   a wall a step away (vyp2.png, m_a 400+ rows).
        pla                          ;   ?wide joins here with its own wt.
        clc                          ; (the sum may wrap: X0 is 15 bits either way)
?havep  ldy tx_slot                  ; X0 = wt + the peg shift (whole texture
        lda rs_vshw,y                ;   pixels) mod the 128-pixel tile: a word
        xba                          ;   whose high byte stays 0 (fx_chains_init
        adc m_prod                   ;   clears it, fx_segk writes < 128). C = 0 on
                                     ;   every way in: the byte path's last add is
                                     ;   below 2^16, the others clear it
        and #$7FFF
        ldy #BCB_SIZE+1              ; [22-23] = X0, the container's own word
        sta [zp_pt],y
        ldy rs_spb                   ; DST = row*160 + the column at the LAST row
        lda row_hi-1,y               ;   (the link paints up): row_hi[spb] into B
        .LONGA OFF                   ;   by a word read, row_lo[spb] under it
        sep #$20
        lda row_lo,y
        rep #$21
        .LONGA ON
pcolw   adc #0                       ; + the column (patched per column: process_seg)
        ldy #BCB_DST_ADDR
        sta [zp_pt],y
        lda zp_pt                    ; the next slot (C = 0: row*160+col < $8000)
        adc #BCB_SLOT
        sta zp_pt
        ldx zp_col                   ; X = the column again: the multiplies index
pc_cend cmp #BCB_SLOT*TW_MAXLINKS+PT_ZPOFF   ;   their tables with it. The END slot
        beq ?full                    ;   (its high byte: ptc_open)
        rts                          ; OUT 16-bit A
?full   .LONGA OFF
        sep #$20
        jsr ptc_fire
        rep #$20
        rts
        ; ---- the rare multiplies (16-bit M in and out, C = 0 out) -------------
        .LONGA ON
?wide   bmi ?aneg
        lda rs_tpr                   ; 256+ rows under the peg: the 16 x 16
        sta m_b                      ;   multiply (m_prod = 32 bits, its low
        jsr umul16w                  ;   word is wt), then the fraction's share
        bra ?frac                    ;   with the common path (its tail falls through)
?aneg   stz m_prod                   ; above the peg: texture pixel 0 (the clip never
        clc                          ;   lets it happen; kept from the painter)
        bra ?havep
        ; ---- the bake, out of line: rs_rpt changed (16-bit M in and out) ------
bake    lda rs_rpt
        eor ptm_last
        and #$FFE0                   ; rpt >> 5 moved: DOOM's scalelight row too
        beq ?hiok
        lda rs_rpt                   ; min(rpt >> 5, 23) rows off the wall's light
        cmp #24<<5                   ;   (r_main.c scalelight, rpt = rw_scale >> 8)
        bcc ?dim1
        lda #23<<5
?dim1   lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        sta pc_dim
        clc
        adc rs_wlit                  ; (a word: its high byte is 0)
        tay
        .LONGA OFF
        sep #$20
        lda LT_ROW,y                 ; the wall's colormap row at this scale
        sta zp_cm+1
        rep #$20
        .LONGA ON
?hiok   lda rs_rpt
        sta ptm_last                 ; the memo
        beq ?pr_sat                  ; rpt = 0: tpr saturates
        RECIP_NORM                   ; rs_tpr = 1/rpt, Q8: the mantissa's INV_TAB
        .LONGA OFF                   ;   word shifted by the exponent (recip_norm
        clc                          ;   RETURNS 8-bit; rc_e is signed)
        lda #RECIP_INV_K-16
        adc rc_e
        bmi ?pr_sat                  ; shift < 0 -> tpr >= 65536
        tay                          ; Y = the shift, 0..14 (7 + e). (A byte-only
                                     ;   path for 8+ went 2026-10-20: bank $01 is full;
                                     ;   the 14-pass worst case is a bake, ~30 % of
                                     ;   the columns, +130 cycles each)
        lda.l RCX_INV_HI,x           ; INV_TAB[m] = round(2^23/m), bank $01
        xba
        lda.l RCX_INV_LO,x
        rep #$20
        .LONGA ON
        stz m_b                      ; 2026-10-20: the bits the shift drops are KEPT --
?pr_sh  dey                          ;   they collect in m_b's high byte and become
        bmi ?pr_st                   ;   rs_tprf, tpr's next 8 fraction bits. X0 is
        lsr @                        ;   m_a x tpr, and m_a is 400+ rows on a wall a
        ror m_b                      ;   step away: a Q8 tpr alone stepped X0 by two
        bra ?pr_sh                   ;   texture pixels every few columns (vyp2.png).
?pr_st  sta rs_tpr                   ;   (Y passes; the taken bra: bank $01 is full)
        lda m_b
        xba                          ; the high byte down: rs_tprf, a word with its
        and #$00FF                   ;   byte 1 clean (every column reads the word:
        sta rs_tprf                  ;   the mask is paid once here, not there)
?pr_x   jsr fx_tprk                  ; (X, RECIP_NORM's count: the exit reloads it)
        sec                          ; (the common path arrives with C = 1 from its
        jmp ?baked                   ;   cmp: the spb - spa below counts on it)
?pr_sat rep #$20                     ; (entered at either width; rs_tprf stays stale:
        lda #$FFFF                   ;   256 texture pixels a row is a blur, its
        sta rs_tpr                   ;   fraction cannot show)
        bra ?pr_x
.endp
        .endseg

;--------------------------------------------------------------
; fx_tprk -- the bake's tail: the slots' steps rs_tprk = rs_tpr x K / 256,
;   the wall's at +0, the lower step's at +2; K - 256 is rs_texkw / rs_texkl
;   (0 = native: the step as it is). A texture whose height does not divide
;   128 is stored stretched to the tile (pack_textures), so its texture pixel step
;   grows by 128/h. 16-bit M in and out; clobbers A/X/Y, m_a, m_b, m_prod.
;--------------------------------------------------------------
        .segment B1
.proc fx_tprk
        .LONGA ON
        lda rs_tpr
        sta rs_tprk
        sta rs_tprk+2
        cmp #$2000                   ; 8192+ texture pixels a row: any stretch is off
        bcs ?out                     ;   the word -- the native step stays
        sta m_a
        lda rs_texkw
        beq ?low
        MULBW                        ; tpr x (K - 256) (math.asm)
        lda rs_tpr
        clc
        PRADC 1                      ; + its bytes 1-2 = tpr x K / 256 (< 2^16:
        sta rs_tprk                  ;   tpr < 2^13, K - 256 < 2^11)
?low    lda rs_texkl
        beq ?out
        MULBW
        lda rs_tpr
        clc
        PRADC 1
        sta rs_tprk+2
?out    rts
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; fx_segk -- once a seg (process_seg ?sy_done, before its columns): a
;   stretched tile's peg shift is in TILE rows, vsh x K / 256 (rs_texkw /
;   rs_texkl = K - 256, 0 = native; vsh < h, so the result is under 128). A
;   new K pair also voids paint_col's bake memo: its steps were made with the
;   old one. 8-bit M in and out; clobbers A/X/Y, m_a, m_b, m_prod.
;--------------------------------------------------------------
        .segment B1
.proc fx_segk
        rep #$20
        .LONGA ON
        lda rs_texkw
        cmp ptm_kw
        bne ?new
        lda rs_texkl
        cmp ptm_kl
        beq ?same
?new    lda rs_texkw
        sta ptm_kw
        lda rs_texkl
        sta ptm_kl
        lda #$FFFF                   ; (no rpt is $FFFF: the next column bakes)
        sta ptm_last
?same   lda rs_texkw
        beq ?low
        ldx rs_wtexid                ; ($FF: no wall texture, the shift is unused)
        inx
        beq ?low
        lda rs_vshw                  ; (a word, its high byte 0: fx_chains_init)
        sta m_a
        lda rs_texkw
        MULBW
        lda rs_vshw
        clc
        PRADC 1                      ; vsh + vsh x (K - 256) / 256, the pad 0
        sta rs_vshw
?low    lda rs_texkl
        beq ?out
        ldx rs_ltexid
        inx
        beq ?out
        lda rs_vshl
        sta m_a
        lda rs_texkl
        MULBW
        lda rs_vshl
        clc
        PRADC 1
        sta rs_vshl
?out    .LONGA OFF
        sep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; tex_vget -- X = texid (kept). OUT: 16-bit A = the texture's tiles in the
;   VRAM arena (low word), Y = their bank. The tiles share the sprites' arena
;   (spr_draw.asm ar_alloc: bump + flush, TEXVR_* their address per texid) and
;   are copied out of SDRAM on the first look (spr_fcopy). 8-bit in; zp_ptr
;   is kept (its bank byte is MAP_EXT_BANK, the frame's).
;--------------------------------------------------------------
    .if TEX_COUNT > 256
        ert 'TEXVR_LO/MID/HI are a page each'
    .endif
        .segment B1
.proc tex_vget
        lda.l EXT_BASE+TEXVR_HI,x    ; resident? (an arena bank byte is never 0)
        beq ?miss
        tay
        lda.l EXT_BASE+TEXVR_MID,x   ; A = lo | mid << 8
        xba
        lda.l EXT_BASE+TEXVR_LO,x
        rep #$20
        .LONGA ON
        rts
        .LONGA OFF
?miss   pei (zp_ptr)                 ; spr_fcopy walks zp_ptr; the seg's sector
        rep #$20                     ;   pointer comes back below
        .LONGA ON
        lda.l MAP_TEXNC,x            ; (stored tiles - 1) * 128 + 128 = the bytes
        and #$00FF                   ;   (256 tiles = $8000: no inc before the
        xba                          ;   shift)
        lsr @                        ; C = 0 out: bit 0 was 0
        adc #128
        sta sf_size
        lda ar_bump                  ; the tiles 128-ALIGNED: the raycaster ORs the
        adc #127                     ;   texture pixel into bits 0-6 of a column's address
                                     ;   (C = 0: the size is at most $8000;
        and #$FF80                   ;   texture must be clear) and a sprite frame
        sta ar_bump                  ;   before them ends anywhere. The size is a
        .LONGA OFF                   ;   multiple of 128, so the next texture stays
        sep #$20                     ;   aligned by itself
        bcc ?al
        inc ar_bump+2                ; (the low word wrapped: the next bank)
?al     jsr ar_alloc                 ; sp_addr = room for them (a flush when none)
        lda sp_addr
        sta.l EXT_BASE+TEXVR_LO,x
        lda sp_addr+1
        sta.l EXT_BASE+TEXVR_MID,x
        lda sp_addr+2
        sta.l EXT_BASE+TEXVR_HI,x
        clc                          ; the pool bytes: LVL_TEXSD_C + the texture's
        lda MAP_TEXADDRLO,x          ;   offset (24 bits, three byte arrays)
        adc #<LVL_TEXSD_C
        sta sf_src
        lda MAP_TEXADDRMID,x
        adc #>LVL_TEXSD_C
        sta sf_src+1
        lda MAP_TEXADDRHI,x
        adc #[LVL_TEXSD_C>>16]
        sta sf_src+2
        jsr spr_fcopy                ; (keeps X; parks the window on the BCB bank)
        rep #$20
        .LONGA ON
        pla
        sta zp_ptr
        lda sp_addr                  ; (spr_fcopy leaves it)
        ldy sp_addr+2
        rts
        .LONGA OFF
.endp
        .endseg

;--------------------------------------------------------------
; fx_chains_init -- per level (arena_init): both chain buffers, slots 1..47
;   fx_slot_tmpl (slot 0, the old 8x expander's, is unused: ptc_fire launches
;   from slot 1) -- then the
;   32 COLORMAP rows into CMAP_VRAM, a page a row. Clobbers A/X/Y, m_a,
;   zp_tsrc, zp_ptr (its bank byte back on MAP_EXT_BANK).
;--------------------------------------------------------------
        .segment B1
.proc fx_chains_init
        stz rs_vshw+1                ; the peg shifts' high bytes: seg_draw writes
        stz rs_vshl+1                ;   them 8-bit, paint_col reads words
        lda #BANK_EN|BANK_OVERHEAD   ; the window on the BCB bank (a loader may
        sta VBXE_BANK_SEL            ;   have left it elsewhere)
        stz zp_savex                 ; [zp_tsrc],y / [zp_ptr],y: bank 0 = the window
        stz zp_ptr+2
        lda #>[MEMW+MEMW_CHB_OFF]
        jsr ?buf                     ; buffer B, then A
        lda #>[MEMW+MEMW_CHA_OFF]
        jsr ?buf
        lda #BANK_EN|[CMAP_VRAM>>12] ; ---- the COLORMAP: the window on the cache's
        sta VBXE_BANK_SEL            ;   16 KB group
        lda #[CMAP_EXT>>16]
        sta zp_ptr+2
        rep #$20
        .LONGA ON
        lda #CMAP_EXT&$FFFF
        sta zp_ptr
        lda #MEMW16+[CMAP_VRAM&$3FFF]
        sta zp_tsrc
        ldx #32                      ; rows = pages, a word a store
?pg     ldy #0
?by     lda [zp_ptr],y
        sta [zp_tsrc],y
        iny
        iny
        bne ?by
        .LONGA OFF
        sep #$20
        inc zp_ptr+1                 ; (the two 8-bit page steps: a 16-bit inc
        inc zp_tsrc+1                ;   would touch the bank bytes)
        rep #$20
        .LONGA ON
        dex
        bne ?pg
        .LONGA OFF
        sep #$20
        lda #BANK_EN|BANK_OVERHEAD   ; the window back on the BCB bank
        sta VBXE_BANK_SEL
        lda #MAP_EXT_BANK            ; zp_ptr's bank as arena_init set it
        sta zp_ptr+2
        rts
?buf    stz zp_tsrc                  ; A = the buffer's window page
        sta zp_tsrc+1
        lda #TW_MAXLINKS-1
        sta m_a
?slot   lda zp_tsrc                  ; -> the next slot (its page on a carry)
        clc
        adc #BCB_SLOT
        sta zp_tsrc
        bcc ?nc
        inc zp_tsrc+1
?nc     ldx #[BCB_SLOT-1]&$FE        ; the template, a word a store (long is
        rep #$20                     ;   X-indexed only: Y takes X's value); the
                                     ;   odd slot's last word spills into the next
        .LONGA ON
?cp     lda.l B1CODE_BASE+fx_slot_tmpl,x
        txy
        sta [zp_tsrc],y
        dex
        dex
        bpl ?cp
        .LONGA OFF
        sep #$20
        dec m_a
        bne ?slot
        rts
.endp
fx_slot_tmpl                         ; a link slot: a 1-px constant fill painted
        dta a(VRAM_BCB_FF), [VRAM_BCB_FF>>16]   ;   bottom-up, chained. Every link
        dta a(0), 0                  ;   rewrites XOR/HEIGHT/CTRL/DST, a wall link
        dta a(0), 0                  ;   its SRC, step, X0 and cmask too, a copy
                                     ;   link (colmerge.asm) SRC/steps/WIDTH/AND
        dta a($2000-SCREEN_WIDTH), 1 ; DST_STEPY = -160 (13 bits), DST_STEPX
        dta a(0), 0                  ; WIDTH-1 = 0, HEIGHT-1
        dta 0, 0, 0                  ; AND = 0 (a constant source), XOR, COLLIDE
        dta 0, FX_PAT                ; ZOOM, PATTERN: the tile's size codes
        dta FX_CTL_F                 ; CTRL: copy, chained, containers follow
        dta FX_RC_HDR                ; a raycasting container, the last one:
        dta a(0), a(0), 0            ;   X0, Y0 = 0, source_step_x hi
    .if * - fx_slot_tmpl <> BCB_SLOT
        ert 'fx_slot_tmpl is not one slot'
    .endif
        dta 0                        ; (the copy's spill byte, not a slot's)
        .endseg
    .else                            ; !FX127: the painter

;--------------------------------------------------------------
; pt_seg -- once per seg (beside tw_seg_init): rs_rpt for the seg's FIRST
;   column and rs_drpt, the per-column step. Both divisions live here so the
;   column loop pays only an add. Clobbers A/X/Y and the m_* scratch.
;   Per SEG, not per column, so it lives in the second block (PAINT2_BASE) and
;   leaves the $0900 page to the per-column code.
;--------------------------------------------------------------
; (pt_seg is INLINE in process_seg since 2026-10-05 -- seg_draw.asm, right
;  before the per-seg patch block: one caller, once a seg, the jsr/rts went.
;  It stood here as a proc, parked at PTSEG_BASE.)
; pt_step (rpt += drpt per column) is INLINED in process_seg's ?cnext since
; 2026-09-14; pt_recip and pt_mul are inlined in paint_col's bake. Their
; standalone copies had no caller left and went on 2026-09-25.

;--------------------------------------------------------------
; pt_dy -- pc_dy (Q8 screen rows) = (pc_w + pc_f/256 texture pixels) * rs_rpt.
;   Clobbers A/Y and qs_p.
;--------------------------------------------------------------
    .if [<SQ1L]|[<SQ1H]|[<SQ2L]|[<SQ2H]
        ert 'SQ1L/SQ1H/SQ2L/SQ2H must all be page aligned -- the bake patches only the LOW byte of each base'
    .endif
  .ifndef ANTONIA2                   ; (ANTONIA2: pc_wide multiplies on the card)
        .segment B1
.proc pt_dy
        ; THE rpt_hi != 0 PATH ONLY (2026-09-14). paint_col's inline ?dyen ...
        stz pc_dy+2
        sec
m2a     lda SQ1L,y                   ; + (w * rpt_hi) << 8
m2b     sbc SQ2L+$FF,y
        sta qs_p
m2c     lda SQ1H,y
m2d     sbc SQ2H+$FF,y
        sta qs_p+1
                                      ; 2026-09-22 idiom: the 16-bit add in one window
        rep #$21                     ;   (absorbs the clc), as umul16 does: -2 a run on
        .LONGA ON                    ;   the near-wall path
        lda pc_dy+1
        adc qs_p
        sta pc_dy+1
        sep #$20
        .LONGA OFF
        ldy pc_f                     ; the run the anchor lands INSIDE starts on
        beq ?done                    ;   a fraction of a texture pixel; every later run
        sec                          ;   has pc_f = 0 and skips this
m3a     lda SQ1L,y                   ; + f * rpt_hi  (the f*rpt_lo term is worth
m3b     sbc SQ2L+$FF,y               ;   under 1/256 of a row and is dropped)
        sta qs_p
m3c     lda SQ1H,y
m3d     sbc SQ2H+$FF,y
        sta qs_p+1
        rep #$21                     ; pc_dy += the product, the low word in one
        .LONGA ON                    ;   add; its carry into byte 2 (drac030,
        lda pc_dy                    ;   2026-09-14)
        adc qs_p
        sta pc_dy
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        bcc ?done
        inc pc_dy+2
?done   stz pc_f                     ; the anchor run's part-texture pixel is consumed
        jmp paint_col.pc_paint_mem
.endp
        .endseg
  .endif

;--------------------------------------------------------------
; pt_span -- EVERY span the frame draws lands here: the painter's runs AND the
;   ceiling/floor flats. A = the span's LAST row (2026-09-28: the links paint
;   BOTTOM-UP, DST_STEPY = -160, see paint_col's loop), Y = rows-1, B = the
;   shade. OUT: X = the column, 16-bit A (2026-10-16). Entry px: the row is in
;   X already.
;--------------------------------------------------------------
zp_pt    = zp_tsrc                   ; -> current slot in the window (2 B; the
                                     ;   loaders' copy pointer, dead in-frame)
zp_links = mv_ss                     ; links left in the open chain (1 B; the
                                     ;   movers' descent scratch, dead in-frame)
; The painter's hottest cells, aliased onto more render-dead zp scratch
; (goal 2, 2026-08-10): loc_floor is locate_floor's per-call result and
; zp_mvsec is mv_secptr's per-call sector pointer -- movers, doors, AI and the
; player all run outside render_world. ~15 accesses per span go abs->zp.
pc_yacc  = loc_floor                 ; screen row accumulator, Q8 (frac, lo).
                                     ;   The old third byte was write-only --
                                     ;   the ?clamp carry test covers overflow
pc_y16   = zp_mvsec                  ; (y << 8) | $FF as ONE word: what the run
                                     ;   loop subtracts from yacc (2026-09-25,
                                     ;   see ?acc); its high byte ...
pc_y     = zp_mvsec+1                ; ... IS the row being painted
pc_a0    = pc_cum                    ; the anchor's slot (X), 0 once the first lap
                                     ;   is counted (2026-09-28; pc_cum was free)
    .if zp_savex <> zp_pt+2
        ert 'zp_pt+2 must be zp_savex: the bank byte of [zp_pt],y, kept 0 (ptc_open)'
    .endif
        .segment B1
.proc pt_span
        tax                          ; the row -> the row-table index. OUT: X = the
                                     ;   COLUMN (pcx), whatever X was: every caller
                                     ;   but sky_clip has X = the column anyway, and
                                     ;   sky_clip saves its run index itself
px                                    ; 2026-09-22 idiom: Y ARRIVES as rows-1 (BCB HEIGHT)
                                     ;   -- "a constant added on every pass belongs in
                                     ;   the start value": draw_span/sky_clip/paint_col
                                     ;   hand it over that way, the dey went
        tya                          ; A = height-1 -- and B is the COLOUR: every
                                      ;   caller `xba`s it there where it used to
                                     ;   `sta zp_color` (2026-09-22, 6502-idioms: a
                                     ;   temp that is only parked lives in a
                                     ;   register; the store and the reload go)
        rep #$21                     ;   fills HEIGHT (14) and AND (15) -- the
        .LONGA ON                    ;   colour is the AND byte, see paint_col's
                                      ;   emit (2026-09-14)
        ldy #BCB_HEIGHT-BCB_DST_ADDR ; 2026-09-22: zp_pt -> the slot's DST field
                                      ; 2026-09-22 (alt-src cpu65c816.cpp): a (dp),y STORE
        sta [zp_pt],y                ;   always dummy-reads its target first, and in the
                                      ; HEIGHT -> DST is 22 fast cycles, two chip cycles
        lda row_hi-1,x               ;   exactly (rapidus-bus-timing): row_hi[x] into B
        .LONGA OFF                   ;   by a word read (row_hi-1+199 stays in page),
        sep #$20                     ;   the column as an immediate, `sta (zp_pt)` (no
        lda row_lo,x                 ;   bank byte: DBR = 0 = zp_savex, alt-src
        rep #$21                     ;   cpu65c816.cpp DpInd)
        .LONGA ON
pcw     adc #0                       ; + the column, PATCHED per column (process_seg
        sta (zp_pt)                  ;   mskr; the high byte stays 0). DST, as paint_col
pcx     ldx #0                       ; X = the column again (patched with pcw; keeps
        lda zp_pt                    ;   C: row*160+col < $8000 did not carry). +21
        adc #BCB_SIZE
        sta zp_pt
                                      ; 2026-09-22: as paint_col's pc_cend -- the END
ps_cend cmp #BCB_SLOT*TW_MAXLINKS+PT_ZPOFF   ;   slot (its DST field) as the
        beq ?full                    ;   ptc_open
        rts                          ; 2026-10-16 (drac030: few rep/sep pairs): OUT
                                     ;   16-bit A -- the column code goes on 16-bit,
                                     ;   so no sep here and no rep at the caller
?full   .LONGA OFF
        sep #$20
        jsr ptc_fire                 ; (8-bit, textures.asm)
        rep #$20
        rts
.endp
        .endseg

;--------------------------------------------------------------
; paint_col -- draw ONE wall column as painted runs. draw_twall_clip tail-calls
;   it with A = rs_spa and Y = the height, exactly as it called draw_twall_col;
;   the span itself is read back out of rs_spa/rs_spb. Preserves X.
;   IN: rs_tsrc  this stored column's 2*TEX_RUNK run bytes, in SDRAM: per run
;                (2*texture pixels, PLAYPAL index). pack_textures stores the length
;                DOUBLED (2026-09-25): read as one word it is the word tables'
;                index as it comes, and a 128-texture pixel run is shipped as 64 + 64,
;                so w <= 127 everywhere (2w in a byte, SQ1W/NSQ2W in range).
;       rs_texh_cur / rs_texmask / rs_texpow2   the tile (wall_src set them)
;       rs_tpr   texture pixels per screen row (the bake below)
;       rs_rpt   screen rows per texture pixel        (pt_seg / process_seg ?cnext)
;       rs_pegrow / rs_vsh                    DOOM's peg (r_segs.c)
;       zp_cm    the sector's COLORMAP row    (lights.asm lt_seg)
;       zp_col   the screen column            (draw_vspan reads it)
;--------------------------------------------------------------
        .segment B1
pc_bkj  jmp paint_col.bake           ; the far reach for paint_col's memo test
.proc paint_col
        ; 2026-09-28: the column's three rare exits sit AHEAD of the entry
        ; (pc_in, draw_twall_clip's jmp), in the reach of their branches --
        ; the setup below has no unconditional branch left to hide them behind
        .LONGA ON
?bkp    pha                          ; (16-bit A = the address: kept)
        .LONGA OFF
        sep #$20
        tya
        sta.l B1CODE_BASE+?rlen+3    ; the bank byte into all five run readers --
        sta.l B1CODE_BASE+?rlenb+3   ;   the address is 64-aligned (a 128-aligned
        sta.l B1CODE_BASE+?rlen2+3   ;   payload + column*64 - PT_XB), so the
        sta.l B1CODE_BASE+?rcol+3    ;   +1/+2 the low-word patches add never
        sta.l B1CODE_BASE+?ccol+3    ;   carry into it
        sta.l B1CODE_BASE+pc_bk+1    ; ... and into the memo's own operand
        rep #$20
        .LONGA ON
        pla
        bra ?bkok
        .LONGA OFF
 .ifdef ANTONIA2
?aneg   stz m_a                      ; spa < pegrow (rare): m_a = 0 -> the byte
        stz m_a+1                    ;   path
        bra pc_abyte
?wj     jmp pc_widem                 ; |spa-peg| >= 256: the wide multiply (rare, 2026-09-26)
 .else
?ahi    lda #0                       ; 2026-09-29: the HIGH byte, only when it can
        sbc rs_pegrow+1              ;   be other than 0 (C is the low subtract's:
        bmi ?aneg                    ;   ldy keeps it)
        bne ?wj
        lda m_a                      ; 0 after all: the byte path, A = m_a, C = 1
        sec
        bra pc_abyte
?aneg   stz m_a+1                    ; spa < pegrow (rare): m_a = 0 -> the byte
        lda #0                       ;   path (a written 0: A = m_a for it)
        sta m_a
        sec
        bra pc_abyte
?wj     sta m_a+1                    ; |spa-peg| >= 256: the wide multiply (rare)
        jmp pc_widem
 .endif
        ; pc_in (2026-09-29) -- IN: 16-bit M, A = the run bytes' address (low
        ; word), Y = its bank byte, X = the column = zp_col, tx_slot = the tile.
                                     ; texH is never 0 here: a texid is only kept
                                     ;   (not $FF) when MAP_TEXH != 0 (seg_draw
                                     ;   ?wflat/?lflat), so no divide-by-zero test
        .LONGA ON
pc_in
pc_bk   cpy #0                       ; the bank byte, patched only when it changed
        bne ?bkp                     ;   (6502-loops-tables-smc: the memo IS this
?bkok                                ;   operand), out of line
        sta.l B1CODE_BASE+?rlen+1    ; point the run readers at this column
        sta.l B1CODE_BASE+?rlen2+1
        inc @
        sta.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?ccol+1
        inc @                        ; tsrc+2: ?find's second run of a pass (2026-09-26)
        sta.l B1CODE_BASE+?rlenb+1
                                     ; (the loop's DST add, pcolw, gets the column
                                     ;   from process_seg mskr, once a column)
        ; 2026-09-28: NO 2n here any more (a patch, a read and a bound per
        ; column, ~40 cycles x 350). The loop finds the column's end itself: a
        ; PAD (2w = 0) multiplies to dy-1 = -1 with C = 0, the add carries out
        ; and ?clamp sorts it from a real clamp by Y = 0; a full 32-run column
        ; ends on X's wrap. n is read at ?lap, 55 times a frame.
                                     ; rs_rpt baked into the table addresses,
                                     ;   before the FIRST run uses them -- but
        lda rs_rpt                   ;   ONLY when it CHANGED since the last bake
        cmp ptm_last                 ;   (2026-08-11 pm): ONE word compare. The
        .LONGA OFF                   ;   bake stores the memo itself (2026-09-25:
        sep #$20                     ;   it reads the OLD one first, for rpt_hi).
        bne pc_bkj                   ;   setup_chains zeroes ptm_last; the operands
                                     ;   ASSEMBLE to the rpt=0 bake (pc_wsel's word
                                     ;   form is safe there too, see the bake). The
                                     ;   memo holds for ~70 % through here, the
                                     ;   bake is out of line
?baked
        ; ---- wt = (spa - pegrow)*tpr + vsh*256, reduced mod texH*256 -------- ...
        sec
        lda rs_spa
        sbc rs_pegrow
        sta m_a
 .ifndef ANTONIA2
        bcc ?ahi                     ; 2026-09-29: no borrow, pegrow < 256 (common):
        ldy rs_pegrow+1              ;   the high byte is 0 without working it out,
        bne ?ahi                     ;   and A is still m_a for the multiply
 .else
        lda #0
        sbc rs_pegrow+1
        sta m_a+1
        bmi ?aneg                    ; m_a < 0: out of line (?aneg, below ?nok)
 .endif
?apos
 .ifdef ANTONIA2
        lda m_a+1                    ; ANTONIA II: (spa-peg) * tpr_q8 in ONE
        ora rs_tpr+1                 ;   hardware multiply while both factors are
        bmi ?apsw                    ;   below $8000 (see smul32: bit 15 on the
        rep #$20                     ;   card is unproven); otherwise the software
        .LONGA ON                    ;   path right below, byte or wide
        lda m_a
        sta.l ANT_MUL
        lda rs_tpr
        sta.l ANT_MUL+2
        lda.l ANT_MUL
        sta m_prod
        lda.l ANT_MUL+2
        sta m_prod+2
        sep #$20
        .LONGA OFF
        jmp ?havep
?apsw
 .endif
                                      ; 2026-09-22 idiom: flags are values you track --
  .ifdef ANTONIA2                     ;   Z is still `sbc rs_pegrow+1`'s (sta/bpl keep
        lda m_a+1                    ;   it), so the byte/wide fork needs no reload.
	bne ?wj                      ;   (ANTONIA2's block above clobbers it: reload)
pc_abyte
	qsmulx m_a, rs_tpr, m_prod
  .else
pc_abyte                             ; A = m_a and C = 1 on every way in: the low
                                     ;   subtract did not borrow (bcc ?ahi not taken)
                                      ; X is dead here (?havewt loads it): qsmulx fuses
	qsmulx m_a, rs_tpr, m_prod, ld, c1 ;   each table read with its subtract -- no
                                     ;   store/reload of :3 (6502-idioms)
  .endif
        qsmulxa m_a, rs_tpr+1              ; + (lo * tpr_hi) << 8, IN A:B (math.asm)
	rep #$21		;absorb CLC
	.LONGA ON
        stz m_prod+2                 ; bytes 2-3 = 0 as ONE word (qsmulxa keeps them:
        adc m_prod+1                 ;   A:B, X, Y only); the add reads byte 2
        sta m_prod+1
	sep #$20
	.LONGA OFF
                                     ; (the wide path, pc_widem, is out of line below)
?havep  ldy tx_slot                  ; the tile's three facts, by slot (0 the wall's,
        lda rs_vshw,y                ;   1 the lower step's: per SEG, process_seg).
        beq ?novsh                   ;   DOOM's peg shift: whole texture pixels
        clc
        adc m_prod+1
        sta m_prod+1
        bcc ?novsh
        inc m_prod+2

?novsh  lda rs_texpow2,y             ; power-of-two texH -> the modulo is an AND
        bne ?slowmod
        lda m_prod
        sta tw_wt
        lda m_prod+1
        and rs_texmask,y             ; A = wt's high byte, kept in A (only ?havewt
?havewt                              ;   reads it; ?slowmod arrives the same way)
        ; ---- walk to the run holding texture pixel wt>>8 ---------------------------
        ; COUNT DOWN, don't sum up: A = 2 * (the texture pixels still ahead of the
        ; anchor), the run bytes being 2w (2026-09-25).
        asl                          ; wt_hi <= texH-1 <= 127: no carry out
        ldx #PT_XB                   ; slot 0 (2026-09-28: X is biased, see ?next)
	sec			;get SEC outside the loop
                                     ; TWO runs a pass, no counter (2026-09-26):
?find                                ;   the packer makes the runs SUM to texH
?rlen	sbc.l $000000,x              ;   (texruns.py) and wt_hi <= texH-1, so the
	bcc ?found                   ;   walk always borrows inside the column --
?rlenb	sbc.l $000002,x              ;   the dey/bne guard never fired. ~2,600
	bcc ?found2                  ;   runs a frame walk here: -3.5 cycles each
	inx
	inx
	inx
	inx
	bra ?find
                                     ; the two rare paths, out of line:
?slowmod lda m_prod+3                ; cannot happen for real geometry, but a
        beq ?red0                    ;   32-bit product would break udiv24
        stz m_prod
        stz m_prod+1
        stz m_prod+2
?red0
	                              ; m_den = texH*256 (one tile, Q8)
        stz m_den
        lda rs_wtexh                 ; the tile's height, by slot (Y = tx_slot)
        cpy #0
        beq ?smh
        lda rs_ltexh
?smh    sta m_den+1
        jsr udiv24
        UD8                          ; (udiv24 hands back 16-bit A)

        lda m_rem
        sta tw_wt
        lda m_rem+1                  ; wt's high byte in A, as the pow2 path
        bra ?havewt
pc_widem lda rs_tpr                  ; |spa-peg| >= 256
        sta m_b
        lda rs_tpr+1
        sta m_b+1
        jsr umul16                   ; m_prod(32) = (spa-peg) * tpr_q8
        jmp ?havep
?found2 inx                          ; (2026-09-26) the borrow came from the pass's SECOND run
        inx
?found  tay                          ; 2026-09-29 (no php/plp, no pc_w): A = -2*(the leftover),
        sec                          ;   parked in Y. rem_q8 = (cum << 8) - wt: what
        lda #0                       ;   is LEFT of the run below the anchor
        sbc tw_wt
        sta pc_f                     ; C = 1 iff wt's fraction is 0 (b = 0)
        tya                          ; (tya / eor / dec / inc keep C)
        eor #$FF                     ; 2*leftover - 1 (leftover >= 1: the sbc.l
        dec @                        ;   borrowed), - 1 = 2*(leftover - 1): the
        bcc ?fs                      ;   fraction takes a texture pixel off the anchor run,
        inc @                        ;   the common case; b = 0 puts it back
        inc @
?fs     tay                          ; the run's WHOLE texture pixels, as 2w: in Y up to
                                     ;   pc_wsel (nothing below touches Y)
                                      ; 2026-09-21: pc_yacc is kept BIASED BY +255.
        lda #$FF                     ; yacc = spa.FF, Q8, biased: the high byte
        sta pc_yacc                  ;   is the ceiling
        sta pc_y16                   ; ... and the compare cell's low byte: y.FF
        ; ---- the PT_MAXRUN budget (2026-09-28): the tail fires on the 129th
        ; REAL run, and ?lap does ALL the counting -- the anchor only leaves
        ; its slot (X, never 0) for the first lap to count from.
        stx pc_a0
        ; 2026-09-27: the rows run BIASED by kh = 255-spb (yacc, pc_y, pc_y16 all
        ; carry +kh<<8), so yn > spb is exactly the carry out of the yacc add:
        ; the per-run `cmp #(spb+1)<<8 / bcs` went (5 cycles x ~5,300 runs a
        ; frame). y <= spb always, so y+kh <= 255 never wraps; the row tables
        ; are read through bases moved down by kh (patched here).
        lda rs_spb
        eor #$FF                     ; kh = 255 - spb
        clc
        adc rs_spa                   ; spa + kh <= 255 (spa <= spb: draw_twall_clip)
        sta pc_yacc+1
        sta pc_y
  .if STRIP
        jsr ps_col                   ; (2026-10-15) THE STRIP or runs for this column
  .endif
        rep #$21
        .LONGA ON
        lda rs_spb                   ; 2026-09-28: a run is painted UP from its last
        and #$00FF                   ;   row yn-1, and the tables are read at yn:
        adc #row_hi-$101             ;   row_hi-1-1-kh = row_hi-257+spb (no carry out)
        sta.l B1CODE_BASE+?rhi+1
        adc #row_lo-row_hi+1         ; row_lo-1-kh
        sta.l B1CODE_BASE+?rlo+1
        tya                          ; the anchor run's 2w -> the multiply (8-bit
                                     ;   Y: the high byte comes 0). w = 0
                                     ;   (only a part texture pixel left in the anchor
        beq ?next                    ;   run: pc_f) paints nothing: on to the next
        bra pc_wsel                  ;   run. C = 0: the word path adds it in
        .LONGA OFF
        ; ---- paint: one span per run, until spb -----------------------------
        ; 2026-09-25 -- THE LOOP RUNS 16-BIT (M = 0) end to end; only the
        ; colour lookup and the row tables drop to 8 bits. A run is two 16-bit
        ; bus stores (HEIGHT+AND, DST).
        ; 2026-09-28 -- 15 CHIP CYCLES A RUN (16 before; rapidus-bus-timing,
        ; _probe_phase): DST round to the next HEIGHT is 88 fast cycles = 8
        ; (96 = 9), HEIGHT to DST 31 = 3 (28 = 3). What paid for it:
        ;   * the links paint BOTTOM-UP (the slots' DST_STEPY is -160), so DST
        ;     is the row yn-1 and ONE `ldy pc_yacc+1` is both the table index
        ;     and the next run's pc_y -- the `ldy pc_y` went (-3), and the
        ;     pc_y update sits in the short stretch, where it is free;
        ;   * X runs PT_XB..254 and its wrap to 0 is the 33rd slot: inx/inx/
        ;     beq, no cpx (-2). A shorter column ends on its first PAD, which
        ;     the word path turns into a carry (see pc_in).
        ; Both stretches are full: +1 cycle in either costs 11.
        ; 2026-10-06 (rapidus-bus-timing: the floor is the BYTES a loop sends) --
        ; MEASURED (tools/tests/_probe_runmerge.py), do not derive them again.
        ; The STRIP is BUILT for ANTONIA2 (2026-10-15, ps_col/ps_fin below):
        ;   * 69 % of the painted runs are ONE row (1.8 rows a run), each 4 bus
        ;     bytes. A minified column sent as a STRIP -- a byte a row into VRAM
        ;     and one copy link -- prices at -57k cycles a frame standing, -170k
        ;     walking (9 chip cycles a 1-row run, 25 a column: the link, the arena,
        ;     the slot's SRC put back as cm_rest does).
        ;   * rows 256 bytes apart (the XDL's step) would make DST = pc_y16 + a
        ;     constant: HEIGHT -> DST 31 -> 18, one chip cycle a run (-35k / -74k),
        ;     for 16 KB of VRAM a frame buffer and every drawer's DST.
        ;   * a run merged into an equal shade above it: 17.9 % / 11.3 % of the
        ;     runs, but the compare takes every other run out of its 88 band.
        ; The rare exits sit above the loop, in branch reach:
  .if STRIP
        ; ---- THE STRIP (2026-10-15, ANTONIA2; ps_col below): a column in strip
        ; mode writes each run's colour into a VRAM arena, ONE BYTE A ROW, and
        ; ps_fin sends the whole column as one link -- 1 bus byte a row instead
        ; of 4 a run (rapidus-bus-timing: the floor is the bytes sent). Rows are
        ; biased (y+kh), so the arena index IS the row: [m_a],y, m_a = the
        ; arena byte of row 0, m_b = 0 (its bank). M 8-bit on every way in.
pcs_scc ldy #0                       ; the column's last run: rows y..255 (= spb)
?sc     dey
        sta [m_a],y
        cpy pc_y
        bne ?sc
        lda #$FF                     ; ... and the strip ends on spb
        jsr ps_fin
        ldx zp_col
        rep #$20                     ; OUT 16-bit A, as pt_span (2026-10-16)
        rts
?send   lda pc_y                     ; a see-through last run: the strip ends
        dec @                        ;   above it
        jsr ps_fin
        ldx zp_col
        rep #$20                     ; (OUT 16-bit A)
        rts
?sadv   lda pc_y                     ; a see-through run INSIDE the column: the
        dec @                        ;   strip ends above it (ps_fin keeps X), the
        jsr ps_fin                   ;   rest of the column paints runs
        jsr ps_off
        bra ?advr
?adv    bit ps_on                    ; (a strip column: close the strip first)
        bmi ?sadv
?advr   lda pc_yacc+1                ; a transparent run (midtex.asm): advance y,
        sta pc_y                     ;   draw nothing, what is behind stays
  .else
?adv    lda pc_yacc+1                ; a transparent run (midtex.asm): advance y,
        sta pc_y                     ;   draw nothing, what is behind stays
  .endif
        rep #$21
        .LONGA ON
        bra ?next
        .LONGA OFF
?clamp  cpy #0                       ; C = 1 out (cpy #0 never borrows). Y = 2w on
        beq ?padlap                  ;   the word path: 0 is a PAD, the column's
                                     ;   runs are spent, not its rows (pc_paint_mem
                                     ;   brings Y = 1)
        sep #$20                     ; yn > spb, or yacc past row 255: this run
        .LONGA OFF                   ;   ENDS the column.
?ccol   lda.l $000001,x              ;   The run's PLAYPAL index (patched
        beq ?cend                    ;   above): transparent -> nothing to paint
        tay
        lda [zp_cm],y                ; its shade through the sector's colormap
                                      ;   row (lights.asm) -- pt_span takes it in B
  .if STRIP
        bit ps_on                    ; (2026-10-15) a strip column ends in its strip
        bmi pcs_scc                  ;   (bit keeps C = 1 for the sbc below)
  .endif
        xba                          ;   (2026-09-22; the 8-bit code below keeps B)
        lda #$FF                     ; paint y..spb and RETURN: rows-1 = spb-y
        sbc pc_y                     ;   = 255 - (y+kh) (2026-09-27 bias; C = 1,
        tay                          ;   and y <= spb: no borrow)
                                      ; jsr X / rts -> jmp X: pt_span hands back X =
        lda rs_spb                   ;   the column (= pc_x) itself, so no ldx here.
        jmp pt_span                  ;   Its row is the LAST one (2026-09-28)
?cend
  .if STRIP
        bit ps_on                    ; (2026-10-15) the strip ends above it
        bmi ?send
  .endif
        ldx zp_col
        rep #$20                     ; OUT 16-bit A, as pt_span (2026-10-16)
        rts
        .LONGA ON
?padlap inc pc_yacc                  ; the pad's dy-1 = -1 went into yacc: put it
?lapj   jmp ?lap                     ;   back (16-bit), then the lap
  .if STRIP
        .LONGA OFF                   ; pcs_em's patched bra (THE STRIP, 8-bit M):
pcs_semit                            ;   A = the colour; rows y..yn-1 of the arena
        ldy pc_y                     ;   take it, a byte a row through the window
?sw     sta [m_a],y                  ;   ([dp],y: no dummy read, rapidus-bus-timing)
        iny
        cpy pc_yacc+1
        bne ?sw
        sty pc_y                     ; Y = yn: the next run starts there (6502-idioms:
        rep #$21                     ;   no reload). C = 0 for the word path, and it
        .LONGA ON                    ;   FALLS into ?next (6502-cycles-layout: no jmp)
  .endif
        ; ---- the loop proper: 16-bit M, C = 0 on every way to pc_wsel -------
?next   inx
        inx
        beq ?lapj                    ; the 33rd slot: a full column's lap
?rlen2  lda.l $000000,x              ; A = colour<<8 | 2w -- ONE 16-bit read
pc_wsel tay                          ; Y = 2w. THESE TWO BYTES ARE PATCHED by the
                                     ;   bake: `tay` + m1w's own opcode ($B9) on
                                     ;   the word path (rpt_hi = 0, rpt_lo != 0),
                                     ;   `bra pc_wide` otherwise. Assembled = the
                                     ;   word form; the rpt=0 memo hit that could
                                     ;   meet it (setup_chains' ptm_last = 0) ends
                                     ;   the column on its first run (dy-1 = -1)
m1w     lda SQ1W,y                   ; f(rpt+w)         (operand = SQ1W + 2 rpt)
m1n     adc NSQ2W+510,y              ; + ~f(|w-rpt|) = dy - 1, and C = 1: f(rpt+w)
                                     ;   > f(|w-rpt|) strictly for w, rpt >= 1
                                     ;   (operand = NSQ2W + 510 - 2 rpt). w = 0,
                                     ;   a pad: -1 and C = 0
?acc    adc pc_yacc                  ; yacc += dy (the word path's +1 rides in on
        sta pc_yacc                  ;   C; pc_paint_mem arrives with C = 0 and dy
        bcs ?clamp                   ;   exact). Carry = yn > spb (the kh bias)
        sbc pc_y16                   ; yacc - (y<<8|$FF) - 1 = (yn-y-1)<<8 | frac:
        bcc ?next                    ;   a borrow is yn == y, no row (yacc never
                                     ;   goes DOWN: dy >= 0), on to the next run
        .LONGA OFF
        sep #$20                     ; A = frac (dead), B = HEIGHT-1 already parked
?rcol   lda.l $000001,x              ; the run's PLAYPAL index (patched above).
        beq ?adv                     ;   0 = "no patch covered this texture pixel", the
                                     ;   see-through half of a two-sided middle
                                     ;   texture (midtex.asm)
        tay
        lda [zp_cm],y                ; through the sector's colormap row -- which
                                     ;   is the thing a blitted wall cannot do ...
pcs_em                               ; (ANTONIA2: `bra pcs_semit` over these two
                                     ;   bytes in a strip column -- ps_col/ps_off)
        xba                          ; A = height-1, B = colour
        rep #$21
        .LONGA ON
        ldy #BCB_HEIGHT-BCB_DST_ADDR ; zp_pt -> the slot's DST field (ptc_open)
        sta [zp_pt],y                ; [14] = HEIGHT, [15] = AND (the colour)
        ldy pc_yacc+1                ; yn: the run's rows end at yn-1, the next
        sty pc_y                     ;   run's start at yn
?rhi    lda row_hi-2,y               ; DST = (yn-1)*160 + col: row_hi[yn-1] into B
        .LONGA OFF                   ;   by a 16-bit read (its low byte is replaced
        sep #$20                     ;   below)
?rlo    lda row_lo-1,y               ; A = row_lo[yn-1] (both bases moved down by
                                     ;   kh per column)
        rep #$21
        .LONGA ON
pcolw   adc #0                       ; + the column, PATCHED per column (process_seg mskr)
        sta [zp_pt]                  ; DST: zp_pt points at it
        lda zp_pt                    ; slot += 21 -- no clc: the DST sum above is
        adc #BCB_SIZE                ;   row*160+col < $8000 (row_hi <= $7C), so
        sta zp_pt                    ;   its add cannot carry out
pc_cend cmp #BCB_SLOT*TW_MAXLINKS+PT_ZPOFF  ; the END slot's DST field; the
        bne ?next                    ;   high byte is ptc_open's patch (tw_chn + 3)
        sep #$20                     ; buffer full: falls out of the loop (a taken
        .LONGA OFF                   ;   bne on the common path, not beq + bra)
        jsr ptc_fire
        rep #$21
        .LONGA ON
        bra ?next
        .LONGA OFF
pc_paint_mem                         ; from pt_dy: dy in pc_dy (3 B), 8-bit M
        ldy #1                       ; (not a pad, should this run clamp)
        sec                          ; ?clamp's subtract relies on C = 1
        lda pc_dy+2                  ; a run 256+ rows tall cannot end inside a
        jne ?clamp                   ;   200-row span, so it ends it (6502-mads: jne)
        rep #$21
        .LONGA ON
        lda pc_dy
        bra ?acc
        .LONGA OFF
?wpad   jmp ?lap                     ; (pc_wide's pad, out of line)
pc_wide                              ; A = 2w in the low byte (16-bit M, B junk):
        .LONGA ON                    ;   rpt_hi != 0, or rpt = 0 -- the byte tables
  .ifdef ANTONIA2                    ;   for the rpt_lo product, pt_dy for the rest
        ; 2026-10-15 (6502-idioms: compute in A): dy = w * rpt in ONE card
        ; multiply (< 2^24, exactly pt_dy's two partial products summed), plus
        ; f * rpt_hi for the anchor run's part texture pixel, as pt_dy adds it. No
        ; tables, so the bake patches none of m1a-m1d / m2a-m3d here.
        and #$00FE
        lsr @                        ; w
        beq ?wpad
        sta.l ANT_MUL
        lda rs_rpt
        sta.l ANT_MUL+2
        lda.l ANT_MUL
        sta pc_dy
        lda.l ANT_MUL+1              ; bytes 1-2 (pc_dy is 3 bytes: no word at +2)
        sta pc_dy+1
        ldy pc_f
        beq ?wnf
        tya                          ; f (8-bit Y: its high byte comes 0)
        sta.l ANT_MUL
        lda rs_rpt+1
        and #$00FF
        sta.l ANT_MUL+2
        clc
        lda.l ANT_MUL
        adc pc_dy
        sta pc_dy
        .LONGA OFF
        sep #$20                     ; (sep leaves C alone)
        bcc ?wf0
        inc pc_dy+2
?wf0    stz pc_f                     ; the anchor run's part-texture pixel is consumed
        jmp pc_paint_mem
        .LONGA ON
?wnf    .LONGA OFF
        sep #$20
        jmp pc_paint_mem
  .else
        sep #$20
        .LONGA OFF
        lsr @                        ; w (2w is even: C = 0 out)
        beq ?wpad                    ; 2026-09-28: w = 0 is a PAD -- the column's
                                     ;   runs are spent (pt_dy would hand it the
                                     ;   anchor's part texture pixel, pc_f)
        tay
        sec
m1a     lda SQ1L,y                   ; dy_lo = w * rpt_lo via SQ1L/SQ1H/SQ2L/SQ2H
m1b     sbc SQ2L+$FF,y               ;   (the operands are the bake's; the +$FF
        xba                          ;   operands ARE the rpt=0 bake ptm_last
m1c     lda SQ1H,y                   ;   starts at, see setup_chains)
m1d     sbc SQ2H+$FF,y
        xba                          ; A = dy lo, B = dy hi
        sta pc_dy                    ; the rpt_lo product to memory: pt_dy adds
        xba                          ;   the two rpt_hi products (Y = w still)
        sta pc_dy+1                  ;   and comes back through pc_paint_mem above
        jmp pt_dy
  .endif
    .if [paint_col.pc_wide-paint_col.pc_wsel-2] > 127
        ert 'pc_wide is out of the reach of the bra the bake patches into pc_wsel'
    .endif
    .if paint_col.pc_wsel+1 <> paint_col.m1w
        ert 'the bake patches pc_wsel as `tay` + m1w opcode: m1w must follow pc_wsel directly'
    .endif
        ; ---- a lap ended: X = 0 (the wrap) or a pad's slot. The PT_MAXRUN
        ; budget is settled HERE, per lap (2026-09-14), all of it since
        ; 2026-09-28: pc_g = the runs the column may still paint once the lap
        ; that starts now is over; pc_a0 != 0 marks the first lap.
?lap    sep #$20
        .LONGA OFF
        txa                          ; n, the column's real runs, is WHERE THE LAP
        beq ?l32                     ;   ENDED: the first pad's slot, or 32 on the
        sec                          ;   wrap. (Not the pad's colour byte: texruns.py
        sbc #PT_XB                   ;   pads with the last run's colour, and the
        lsr @                        ;   2n the 2026-09-25 loop read there was never
        bra ?ln                      ;   shipped -- short textures did not tile.)
?l32    lda #TEX_RUNK
?ln     sta pc_n
        lda pc_a0
        beq ?l2
        stz pc_a0                    ; the first lap painted slots k0..n-1:
        sec
        sbc #PT_XB                   ; 2*k0
        lsr @                        ; k0, C = 0
        adc #PT_MAXRUN               ; PT_MAXRUN - (n - k0) are left (>= 96)
        sec
        sbc pc_n
        bra ?l3
?l2     lda pc_g
?l3     beq ?tail                    ; none: the tail, from where X stands
        cmp pc_n
        bcc ?lastlap
        sbc pc_n                     ; a whole lap fits (C = 1)
        sta pc_g
        ldx #PT_XB
?lapgo  rep #$21                     ; C = 0 for the word path
        .LONGA ON
        jmp ?rlen2
        .LONGA OFF
?lastlap                             ; A = m, 1..n-1 runs and then the tail: the
        stz pc_g                     ;   readers move so that X wraps after the
        asl @                        ;   m-th (rare: a column past 96 runs a lap)
        pha
        clc                          ; m_prod(24) = the column's address + 2m -
        adc.l B1CODE_BASE+?rlen+1    ;   2*TEX_RUNK. The address is ?rlen's operand
        sta m_prod                   ;   (pc_in; lower by PT_XB already)
        lda.l B1CODE_BASE+?rlen+2
        adc #0
        sta m_prod+1
        lda.l B1CODE_BASE+?rlen+3
        adc #0
        sta m_prod+2
        sec
        lda m_prod
        sbc #2*TEX_RUNK
        sta m_prod
        lda m_prod+1
        sbc #0
        sta m_prod+1
        lda m_prod+2
        sbc #0
        sta.l B1CODE_BASE+?rlen2+3
        sta.l B1CODE_BASE+?rcol+3
        sta.l B1CODE_BASE+?ccol+3
        lda #$FF                     ; ... and the bank memo forgets: the next
        sta.l B1CODE_BASE+pc_bk+1    ;   column patches all five again
        rep #$20
        .LONGA ON
        lda m_prod
        sta.l B1CODE_BASE+?rlen2+1
        inc @                        ; (even: no carry into the bank)
        sta.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?ccol+1
        .LONGA OFF
        sep #$20
        pla                          ; X = 256 - 2m
        eor #$FF
        inc @
        tax
        bra ?lapgo
        ; --- ?tail: fires only when a column crosses PT_MAXRUN real runs, i.e.
?tail   lda rs_mpass                 ; the flat tail fill is a MINIFICATION
        bne ?tend                    ;   fallback -- on a masked column it would
                                     ;   paint the gaps shut, so a far strut
                                     ;   simply stops instead (midtex.asm)
        rep #$20
        .LONGA ON
        lda.l B1CODE_BASE+?rcol+1
        sta.l B1CODE_BASE+?tcol+1
        sep #$20
        .LONGA OFF
        lda.l B1CODE_BASE+?rcol+3
        sta.l B1CODE_BASE+?tcol+3
        dex                          ; the run BEFORE the 129th: X = 0 or a pad's
        dex                          ;   slot came in, so X-2 is a run (2026-09-28)
?tcol   lda.l $000001,x
        tay
        lda [zp_cm],y
  .if STRIP
        bit ps_on                    ; (2026-10-15) a strip column: the tail's rows
        jmi pcs_scc                  ;   into the strip, then its link
  .endif
        xba                          ; colour -> B for pt_span (2026-09-22)
        sec                          ; rows-1 = spb - y = 255 - (y+kh) (2026-09-27
        lda #$FF                     ;   bias, as ?ccol)
        sbc pc_y
        tay
                                      ; jsr X / rts -> jmp X (as ?ccol, no ldx)
        lda rs_spb                   ; the span's LAST row (2026-09-28)
        jmp pt_span
?tend   ldx zp_col
        rep #$20                     ; (OUT 16-bit A)
        rts
        ; 2026-09-28: the bake's rare half, out of line: rpt >> 5 moved since
        ; the last bake. A = the bits that did (16-bit)
        .LONGA ON
?chg                                 ; (ANTONIA2: no pt_dy operands to patch)
  .ifndef ANTONIA2
        cmp #$0100
        bcc ?dimnew                  ; rpt_hi is as it was: the light alone
        .LONGA OFF
        sep #$20
        lda rs_rpt+1                 ; rpt_hi -> pt_dy's operands
        sta.l B1CODE_BASE+pt_dy.m2a+1
        sta.l B1CODE_BASE+pt_dy.m2c+1
        sta.l B1CODE_BASE+pt_dy.m3a+1
        sta.l B1CODE_BASE+pt_dy.m3c+1
        eor #$FF
        sta.l B1CODE_BASE+pt_dy.m2b+1
        sta.l B1CODE_BASE+pt_dy.m2d+1
        sta.l B1CODE_BASE+pt_dy.m3b+1
        sta.l B1CODE_BASE+pt_dy.m3d+1
        rep #$20
        .LONGA ON
  .endif
?dimnew lda rs_rpt                   ; DOOM's scalelight: the scale takes min(rw_scale
        cmp #24<<5                   ;   >> 12, 47)/2 rows off a wall, rs_rpt being
        bcc ?dim1                    ;   rw_scale >> 8
        lda #23<<5
?dim1   lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        sta pc_dim
        clc
        adc rs_wlit                  ; (a word: its high byte is 0)
        tay
        .LONGA OFF
        sep #$20
        lda LT_ROW,y                 ; the wall's colormap row at this scale
        sta zp_cm+1
        rep #$20
        .LONGA ON
        bra ?hiok
        .LONGA OFF
bake                                 ; --- the bake (rs_rpt changed), out of line:
                                     ;   pc_bkj brings the memo test's bne here
        stz pc_dy+2                  ; --- pt_dy's third byte
        rep #$20                     ; 2026-09-28: ONE test for rpt_hi (pt_dy's
        .LONGA ON                    ;   operands) and rpt >> 5 (the light's rows):
        lda rs_rpt                   ;   the memo is still the OLD rpt here
        eor ptm_last
        and #$FFE0
        bne ?chg
?hiok   lda rs_rpt                   ; the WORD tables' operands (see ?acc) and the
                                     ;   routing of pc_wsel
        sta ptm_last                 ; the memo, now that its old value is read
        and #$00FF
        asl @                        ; 2 rpt_lo (< 512: the asl cannot carry out)
        sta qs_p                     ; (scratch: no quarter-square product is live)
        adc #SQ1W                    ; C = 0 from the asl
        sta.l B1CODE_BASE+paint_col.m1w+1
        lda #NSQ2W+510
        sec
        sbc qs_p
        sta.l B1CODE_BASE+paint_col.m1n+1
        ldy rs_rpt+1                 ; the word path needs rpt_hi = 0 AND rpt_lo
        bne ?pm_wd                   ;   != 0 (rpt = 0: dy is 0 and the carry trick
        ldy rs_rpt                   ;   wants f(rpt+w) > f(|w-rpt|) -- the byte
        beq ?pm_wd                   ;   path through pc_wide computes 0 exactly)
        lda #$B9A8                   ; `tay` ($A8) + m1w's opcode ($B9, lda abs,y)
        bra ?pm_w
?pm_wd
  .ifndef ANTONIA2                   ; (ANTONIA2's pc_wide reads no tables)
        .LONGA OFF                   ; the BYTE path: it alone reads m1a-m1d, so
        sep #$20                     ;   their rpt_lo bake lives here (2026-09-25)
        lda rs_rpt
        sta.l B1CODE_BASE+paint_col.m1a+1
        sta.l B1CODE_BASE+paint_col.m1c+1
        eor #$FF                     ; 255 - b, for the mirrored table
        sta.l B1CODE_BASE+paint_col.m1b+1
        sta.l B1CODE_BASE+paint_col.m1d+1
        rep #$20
        .LONGA ON
  .endif
        lda #$80|[[paint_col.pc_wide-paint_col.pc_wsel-2]<<8]  ; `bra pc_wide`
?pm_w   sta.l B1CODE_BASE+paint_col.pc_wsel
                                     ; (stays 16-bit: recip_norm's entry below is
                                     ;   16-bit anyway -- no empty sep/rep pair)
        lda rs_rpt
                                      ; 2026-09-23: rpt straight into recip_norm's 16-bit
        beq ?pr_sat16                ;   entry; the shift count in Y, INV_TAB's word
        RECIP_NORM                   ; (inlined 2026-09-26)   built in A:B and shifted there -- no m_prod
        .LONGA OFF                   ; (recip_norm RETURNS 8-bit)
        clc                          ;   round trip, rs_tpr stored once
        lda #RECIP_INV_K-16
        adc rc_e                     ; rc_e is signed
        bmi ?pr_sat                  ; shift < 0 -> tpr >= 65536
        cmp #8
        bcs ?pr_ge8
        tay                          ; Y = shift 0..7
        lda.l RCX_INV_HI,x           ; INV_TAB[m] = round(2^23/m), bank $01
        xba
        lda.l RCX_INV_LO,x
        rep #$20
        .LONGA ON
?pr_sh  cpy #0
        beq ?pr_st
?pr_b   lsr @
        dey
        bne ?pr_b
?pr_st  sta rs_tpr
        .LONGA OFF
        sep #$20
        jmp ?baked
?pr_ge8 sbc #8                       ; C = 1 (bcs): Y = shift - 8, and the word >> 8
        tay                          ;   is INV_TAB's high byte alone
        lda.l RCX_INV_HI,x
        rep #$20
        .LONGA ON
        and #$00FF
        bra ?pr_sh
?pr_sat16
        sep #$20                     ; rpt = 0 (from the 16-bit test above)
        .LONGA OFF
?pr_sat lda #$FF                     ; the saturation tw_setup's ?tprmax used
        sta rs_tpr
        sta rs_tpr+1
                                     ;   memo (2026-08-27): tpr is rpt's exact ...
        jmp ?baked
.endp
        .endseg

  .if STRIP
;--------------------------------------------------------------
; ps_col -- THE STRIP or runs for the column paint_col is starting (2026-10-15).
;   8-bit M in and out, keeps X and Y. A strip when: not the masked pass (its
;   see-through texture pixels need the runs' gaps), rs_rpt < PS_RPT (short runs: the
;   bytes a run sends dwarf a row's), and the column's rows (y..255, biased)
;   fit this buffer's arena and its restore list has room -- else the chain
;   is launched once (ptc_fire: the reopened buffer's arena and list free in
;   ps_rest). Sets m_a = the arena byte of row 0, m_b = 0 (bank), ps_y0 = y,
;   and patches pcs_em on a change of mode.
;--------------------------------------------------------------
        .segment B1
.proc ps_col
        lda rs_mpass
        bne ?runs
    .if PS_RPT > $FF
        ert 'ps_col tests rs_rpt as a byte: PS_RPT must stay below one row a texture pixel'
    .endif
        lda rs_rpt+1                 ; rpt < PS_RPT (both bytes: the high one 0)
        bne ?runs
        lda rs_rpt
        cmp #PS_RPT
        bcs ?runs
        lda pc_y                     ; rows = 256 - y (biased): tall enough?
        cmp #256-PS_MINR+1
        bcs ?runs
        sta ps_y0                    ; the strip's first row, from A (6502-idioms: no
        phx                          ;   reload; harmless if it falls to runs)
        stz ps_try
?again  ldx tw_chn                   ; X = the open buffer's page ($A7 / $AB):
        lda ps_rc-PS_PA,x            ;   the state tables are indexed by it
        cmp #2*PS_RMAX               ;   (the count steps by 2: word entries)
        bcs ?fire
        rep #$20
        .LONGA ON
        lda ps_pos-PS_PA,x           ; row 255's byte must still fit: pos <= end-256
        cmp ps_lim-PS_PA,x
        .LONGA OFF
        sep #$20
        beq ?ok
        bcs ?fire
?ok     sec                          ; m_a = pos - y: [m_a],y is row y's byte
        sbc pc_y
        sta m_a
        lda ps_pos-PS_PA+1,x
        sbc #0
        sta m_a+1
        stz m_b                      ; the arena's bank (the window: VRAM = address)
        plx
        bit ps_on
        bmi ?out
        lda #$80                     ; pcs_em -> `bra pcs_semit`
        sta ps_on
        sta.l B1CODE_BASE+paint_col.pcs_em
        lda #<[paint_col.pcs_semit-[paint_col.pcs_em+2]]
        sta.l B1CODE_BASE+paint_col.pcs_em+1
?out    rts
?fire   lda ps_try                   ; no room: launch the open chain, once
        bne ?full
        inc ps_try
        jsr ptc_fire
        bra ?again
?full   plx                          ; still none (an empty chain): runs
?runs   bit ps_on
        bmi ps_off
        rts
.endp
    .if [paint_col.pcs_semit-[paint_col.pcs_em+2]] < -128 || [paint_col.pcs_semit-[paint_col.pcs_em+2]] > 127
        ert 'pcs_semit is out of the reach of the bra ps_col patches into pcs_em'
    .endif

;--------------------------------------------------------------
; ps_off -- pcs_em back to its own `xba / rep` (8-bit M; keeps X and Y).
;--------------------------------------------------------------
.proc ps_off
        lda #$EB                     ; xba
        sta.l B1CODE_BASE+paint_col.pcs_em
        lda #$C2                     ; rep (its #$21 stays behind it)
        sta.l B1CODE_BASE+paint_col.pcs_em+1
        stz ps_on
        rts
.endp

;--------------------------------------------------------------
; ps_fin -- send the open strip as ONE link: A = its last row (biased), 8-bit
;   M. The slot at zp_pt gets DST (the strip's bottom row), HEIGHT, AND = $FF
;   and SRC = the strip's last arena byte; the template's src stepY -1 and
;   dst stepY -160 walk both up the column. The slot goes on the open
;   buffer's restore list (ps_rest). Keeps X; clobbers A, Y and m_a.
;--------------------------------------------------------------
.proc ps_fin
        phx
        tax                          ; X = the last row
        sec
        sbc ps_y0                    ; rows-1
        bcs ?some
        plx                          ; no row: no link
        rts
?some   xba                          ; HEIGHT = rows-1 into B, AND = $FF in front:
        lda #$FF                     ;   the pair is ONE word (65816-idioms: pair
        xba                          ;   bytes with xba -- no cell for the height)
        rep #$20
        .LONGA ON
        ldy #BCB_HEIGHT-BCB_DST_ADDR
        sta [zp_pt],y                ; [14] HEIGHT, [15] AND
        .LONGA OFF
        sep #$20
        txa                          ; the bottom row on screen: last - kh
        sec                          ;   = last + spb + 1 (mod 256)
        adc rs_spb
        tay
        lda row_hi,y
        xba
        lda row_lo,y
        rep #$21
        .LONGA ON
        adc.l B1CODE_BASE+paint_col.pcolw+1  ; + the column (the operand word:
        sta [zp_pt]                  ;   high byte 0) -> [6-7] DST
        txa                          ; SRC = m_a + last: the strip's LAST byte (C = 0:
        adc m_a                      ;   row*160+col < $8000 did not carry); m_a is
        sta m_a                      ;   dead from here, it holds SRC
        inc @                        ; the arena's next free byte
        ldx tw_chn                   ; X = the open buffer's page (the tables')
        sta ps_pos-PS_PA,x
        lda zp_pt                    ; zp_pt -> the slot's BASE for the rest
        sec
        sbc #BCB_DST_ADDR
        sta zp_pt
        lda m_a
        sta [zp_pt]                  ; [0-1] SRC
        .LONGA OFF
        sep #$20
        lda ps_rc-PS_PA,x            ; the restore list's count (steps of 2)
        beq ?first
?rec    inc ps_rc-PS_PA,x
        inc ps_rc-PS_PA,x
        clc
        adc ps_lb-PS_PA,x            ; Y = the entry (A = the old count)
        tay
        rep #$21
        .LONGA ON
        lda zp_pt                    ; the slot's base, one word
        sta ps_rlw,y
        adc #BCB_SIZE+BCB_DST_ADDR   ; -> the next slot's DST field (C = 0)
        sta zp_pt
        cmp.l B1CODE_BASE+paint_col.pc_cend+1   ; the END slot (ptc_open patches it)
        .LONGA OFF
        sep #$20
        bne ?nf
        jsr ptc_fire
?nf     plx
        rts
?first  jsr ps_hook                  ; this buffer's first strip: `jsl ps_rest`
        lda #0                       ;   (6502-cycles-layout: the rare case out of
        bra ?rec                     ;   line -- no per-strip hook test)
.endp

;--------------------------------------------------------------
; ps_hook -- ptc_open's hook -> `jsl ps_rest` (8-bit M in and out).
;--------------------------------------------------------------
.proc ps_hook
        rep #$20
        .LONGA ON
        lda #$22|[[[B1CODE_BASE+ps_rest]&$FF]<<8]
        sta.l B1CODE_BASE+ptc_rsh
        lda #[[[B1CODE_BASE+ps_rest]>>8]&$FFFF]
        sta.l B1CODE_BASE+ptc_rsh+2
        .LONGA OFF
        sep #$20
        rts
.endp

;--------------------------------------------------------------
; ps_rest -- ptc_open's hook (`jsl`, patched by ps_fin and CM_EMIT): the
;   reopened buffer's chain has run, so its strip slots get the template's
;   SRC back (the $FF block's top) and its arena is free again; then
;   cm_rest's copy slots. Re-hooks while either list still holds strips.
;   Keeps X, Y and P.
;--------------------------------------------------------------
.proc ps_rest
        php
        phx
        phy
        sep #$20
        .LONGA OFF
        ldx tw_chn                   ; X = the reopened buffer's page
        lda ps_rc-PS_PA,x
        beq ?cm
        stz ps_rc-PS_PA,x
        clc
        adc ps_lb-PS_PA,x            ; the list's end (its count steps by 2)
        sta ps_t
        ldy ps_lb-PS_PA,x            ; Y = its first entry
        rep #$20
        .LONGA ON
        lda ps_base-PS_PA,x          ; the arena is free again
        sta ps_pos-PS_PA,x
        lda zp_pt                    ; (ptc_open's slot 1: put back below)
        pha
?ent    lda ps_rlw,y                 ; the strip slot's base, one word
        sta zp_pt                    ; (zp_savex = 0: ptc_open zeroed it)
        lda #PS_FFT&$FFFF
        sta [zp_pt]                  ; [0-1] SRC = the $FF block's top
        iny
        iny
        cpy ps_t
        bne ?ent
        pla
        sta zp_pt
        .LONGA OFF
        sep #$20
?cm     jsl B1CODE_BASE+cm_rest      ; the copy slots (it may unhook)
        lda ps_rc
        ora ps_rc+4
        beq ?done
        rep #$20
        .LONGA ON
        lda #$22|[[[B1CODE_BASE+ps_rest]&$FF]<<8]
        sta.l B1CODE_BASE+ptc_rsh
        lda #[[[B1CODE_BASE+ps_rest]>>8]&$FFFF]
        sta.l B1CODE_BASE+ptc_rsh+2
        .LONGA OFF
        sep #$20
?done   ply
        plx
        plp
        rtl
.endp
        .endseg

        .segment D0                  ; THE STRIP's state (2026-10-15): per chain buffer,
PS_PA   equ >[MEMW+MEMW_CHA_OFF]     ;   indexed by its window page tw_chn ($A7 / $AB):
    .if >[MEMW+MEMW_CHB_OFF] - PS_PA <> 4
        ert 'the strip tables expect the two chain pages 4 apart'
    .endif
ps_pos  dta a(PS_ARA&$FFFF), a(0), a(PS_ARB&$FFFF)    ; the next free arena byte
ps_base dta a(PS_ARA&$FFFF), a(0), a(PS_ARB&$FFFF)
ps_lim  dta a([PS_ARA+PS_ALEN-$100]&$FFFF), a(0), a([PS_ARB+PS_ALEN-$100]&$FFFF)
ps_rc   dta 0, 0, 0, 0, 0            ; strip slots recorded, x2 (word entries)
ps_lb   dta 0, 0, 0, 0, 2*PS_RMAX    ; ... at ps_rlw + lb
ps_rlw  :2*PS_RMAX dta a(0)          ; their slot bases
ps_y0   dta 0                        ; the open strip's first row (biased)
ps_on   dta 0                        ; $80 = pcs_em patched (a strip column)
ps_try  dta 0
ps_t    dta 0
        .endseg
  .endif
    .endif                           ; FX127 / the painter

    .if * > SGBSP_BASE
        ert 'paint.asm ran into sg_bsp at $0BFC -- the $0900 block ends there (cm_sscl left, memo+inline took its hole)'
    .endif
        org paint_resume
