;--------------------------------------------------------------
; texcol.asm -- texture column de-duplication: each distinct column is stored
;   once, one index byte per column says which.
;--------------------------------------------------------------
        org TEXIX_CODE

;--------------------------------------------------------------
; tex_getix -- load_textures has just pointed ll_sec at this level's .tex; read
;   its first TEXIX_SECT sectors into TEXIX_BASE and hand ll_sec back untouched,
;   so load_vram then streams the WHOLE blob (index bytes and all) to VRAM the
;   way it always did. Clobbers A/Y. Runs before load_vram, not after.
;--------------------------------------------------------------
    .if !TEX_RUNS
.proc tex_getix
        lda ll_sec                   ; read_sectors walks ll_sec forward
        pha
        lda ll_sec+1
        pha
        lda #<TEXIX_BASE
        sta DBUFLO
        lda #>TEXIX_BASE
        sta DBUFHI
        lda #TEXIX_SECT
        sta ll_cnt
        lda #0
        sta ll_cnt+1
        jsr read_sectors
        pla
        sta ll_sec+1
        pla
        sta ll_sec
        rts
.endp
    .endif

;--------------------------------------------------------------
; tex_setix -- X = texid: wt_ixl/wt_ixh = the address of its column index array.
;   Called from seg_draw once per seg per texture slot, not per column.
;   Clobbers A/X/Y.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc tex_setix
    .if TEX_RUNS
        ; PAINTED walls (paint.asm): the index is NOT copied into base RAM at
        ; all -- the .tex blob it rides at the front of stays in SDRAM and the
        ; CPU reads both the index and the runs from there.
        clc
        lda.l MAP_TEXIXLO,x
        adc #<LVL_TEXSD_C            ; tex_sdram is arena_init's copy of THIS
        sta wt_ixl                   ;   constant (atr_levels.inc) and nothing
        lda.l MAP_TEXIXHI,x            ;   else ever writes it: immediates, not
        adc #>LVL_TEXSD_C            ;   three cell reads (-6 per call)
        sta wt_ixh
        lda #[LVL_TEXSD_C>>16]
        adc #0
        sta wt_ixb
        rts
    .else
        txa
        asl                          ; the offset table is u16 per texid, and a
        tay                          ;   level holds at most 63 (NONE_SEG_ID), so
                                     ;   2*texid always fits Y
        clc
        lda TEXIX_BASE+2,y
        adc #<TEXIX_BASE
        sta wt_ixl
        lda TEXIX_BASE+3,y
        adc #>TEXIX_BASE
        sta wt_ixh
        rts
    .endif
.endp
        .endseg

wt_ixl  dta 0                        ; tex_setix's answer, read by both callers
wt_ixh  dta 0
wt_ixb  dta 0                        ; ... + the SDRAM bank byte (TEX_RUNS)

    .if * > TEXIX_CODE_END+1
        ert 'texcol.asm outgrew TEXIX_CODE..TEXIX_CODE_END (memory_map.inc)'
    .endif
