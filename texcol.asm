;==============================================================
; texcol.asm -- TEXTURE COLUMN DE-DUPLICATION (2026-08-01).
;   tools/pack_textures.py dedup_columns stores each DISTINCT column of a
;   texture once and emits one byte per column saying which stored column it
;   is. That is 14-34 % of a level's texture pixels (tools/_tex_dedup.py);
;   E1M3, the level the 212 KB VRAM slot is cut to, goes 214,784 -> 175,312 B.
;
;   Nothing about the BLIT changes: a column is still exactly h bytes at
;   base + index*h, so the tiling mask, the 8x expander and the BCB are
;   untouched. The only new work is turning tex_x into that index, which
;   tw_setup's wall_src/low_src do with one `lda abs,y` whose operand this
;   file patches once per SEG.
;
;   WHERE THE TABLE COMES FROM. It has to be in ordinary RAM -- the 6502 reads
;   it per column -- but giving it an ATR region of its own would mean a new
;   per-level stride in make_atr_doom.py, a loader, and a sector budget. It
;   rides at the FRONT of the .tex blob instead (TEXIX_MAX bytes, ahead of the
;   pixels), and tex_getix reads those first 16 sectors a SECOND time, straight
;   into base RAM, before load_vram streams the whole blob to VRAM.
;
;   NOT by reading VRAM back through the MEMAC window, which is what this did
;   first and why the doors came out flat: writes through $9000 are what the
;   loader has always done, but a READ back through it is a different thing on
;   a Rapidus -- its fast-RAM shadow of $9000-$9FFF can answer instead of VBXE
;   (Altirra's own battlescape loader re-reads defensively for exactly this,
;   _pomocne/alt-src ... loadmap.asm:424-439). The table came back as zeros, so
;   every column resolved to index 0 and every door drew as its first column
;   repeated. Re-reading 2 KB off the disk per level load costs nothing
;   measurable and cannot be wrong.
;
;   Blob layout (pack_textures.pack_map_textures):
;       +0        u8  texture count
;       +1        u8  pad
;       +2        u16 byte offset of texid n's array, from the blob start
;       ...       the arrays, one byte per column
;   A flat row (h = 0) has no pixels and no array; its offset is 0 and no seg
;   ever reaches it, because rs_wtexid/rs_ltexid are $FF for those.
;==============================================================
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
.proc tex_setix
    .if TEX_RUNS
        ; PAINTED walls (paint.asm): the index is NOT copied into base RAM at
        ; all -- the .tex blob it rides at the front of stays in SDRAM and the
        ; CPU reads both the index and the runs from there. That drops
        ; tex_getix's second disk read, frees TEXIX_MAX bytes of the scarcest
        ; RAM in the machine, and removes the ceiling the run encoding had just
        ; broken (E1M2's arrays 1488 -> 1904 B: the runs dedup MORE columns, so
        ; the index VALUES change and their substring aliasing changes with
        ; them). The answer is a 24-bit address; wall_src reads it with
        ; absolute long, which is X-indexed on the 65816.
        ; 2026-08-14, the EPISODE POOL: the blob is shared by all nine levels
        ; now, so it can no longer carry a per-level offset header at its front.
        ; The offsets moved into the map's own texture table (MAP_TEXIXLO/HI,
        ; pack_map.py _textab_row rows 7-8), which is already streamed per level
        ; and already indexed by texid -- so this is two absolute,x reads
        ; instead of building a 24-bit pointer and taking an indirect read
        ; through it, and zp_ptr is not touched at all any more (no bank byte to
        ; hand back either).
        clc
        lda MAP_TEXIXLO,x
        adc tex_sdram
        sta wt_ixl
        lda MAP_TEXIXHI,x
        adc tex_sdram+1
        sta wt_ixh
        lda tex_sdram+2
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

wt_ixl  dta 0                        ; tex_setix's answer, read by both callers
wt_ixh  dta 0
wt_ixb  dta 0                        ; ... + the SDRAM bank byte (TEX_RUNS)

    .if * > TEXIX_CODE_END+1
        ert 'texcol.asm outgrew TEXIX_CODE..TEXIX_CODE_END (memory_map.inc)'
    .endif
