;--------------------------------------------------------------
; Part of enemy_ai.asm (icl in place): the things blockmap -- blk_tgt, blk_fill, blk_push.
;--------------------------------------------------------------
;--------------------------------------------------------------
; blk_tgt -- en_solid's entry: which blockmap cell is the move target in?
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc blk_tgt
        lda coll_cx+1                ; the SAME grid blk_push files things on:
        lsr                          ;   (coord >> 9) & 7
        and #7
        sta sol_cx
        lda coll_cy+1
                                      ; 2026-09-23: sol_cy = the row * 8, i.e. the cell
        asl                          ;   index's own bits 3-5 (blk_push's trick) --
        asl                          ;   the sweeps add blk_oy (rows * 8) and mask
        and #$38                     ;   #$38, three asl a cell fewer
        sta sol_cy
        rts
.endp
        .endseg


;--------------------------------------------------------------
; blk_fill -- file EVERY thing in the blockmap cell pages. Once per level, from
;   en_init (which has three bytes left, hence the jsr and not the loop).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc blk_fill
        lda #<TH_CELL                ; (every bank $01 page has low byte 0)
        sta zp_ptr
        lda #>BLK_HEAD               ; every cell empty...
        sta zp_ptr+1
        ldy #63
        lda #$FF
?clr    sta [zp_ptr],y
        dey
        bpl ?clr
        lda th_things                ; ...then every thing onto its cell's list
        sta sp_ptr
        lda th_things+1
        sta sp_ptr+1
        stz sol_i
?l      lda sol_i
        cmp THINGS_BASE
        bcs ?done
        jsr blk_push
        clc
        lda sp_ptr
        adc #8
        sta sp_ptr
        bcc ?nc
        inc sp_ptr+1
?nc     inc sol_i
        bne ?l
?done   lda #>TH_RAD                 ; en_radfill's page back
        sta zp_ptr+1
?out    rts
.endp
        .endseg

;--------------------------------------------------------------
; blk_push -- sp_ptr = a thing record, sol_i = its index: onto the head of its
;   cell's list. p_maputl.c relinks a thing when it moves; this port rebuilds
;   the whole map once a frame instead -- 6k cycles against the 30k a single
;   monster step used to pay, and no unlink to get wrong.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc blk_push
        ldy #1                       ; cell = ((y >> 9) & 7) << 3 | (x >> 9) & 7
        lda (sp_ptr),y
        lsr
        and #7
        sta blk_t
        ldy #3
        lda (sp_ptr),y
                                      ; 2026-09-23: ((hi>>1)&7)<<3 = (hi<<2)&$38 -- bits
        asl                          ;   1-3 of the high byte straight to 3-5, two
        asl                          ;   shifts and the mask instead of four and it
        and #$38
        ora blk_t
        tay                          ; Y = the cell
        lda #>BLK_HEAD
        sta zp_ptr+1
        lda [zp_ptr],y               ; the old head becomes our next
                                      ; 2026-09-22 (65816-style): parked on the stack
        pha
        lda sol_i
        sta [zp_ptr],y               ; ...and we become the head
        lda #>TH_BNEXT
        sta zp_ptr+1
        ldy sol_i
        pla
        sta [zp_ptr],y
        rts
.endp
        .endseg

