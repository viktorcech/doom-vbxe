;--------------------------------------------------------------
; xdl.asm -- the VBXE display list: DOOM's 200 rows over the PAL screen's 240
;   scanlines.
;--------------------------------------------------------------
XDL_C1  equ XDLC_GMON | XDLC_MAPOFF | XDLC_RPTL | XDLC_OVADR
XDL_C2  equ XDLC_LR                  ; VIEW: 160 bytes = 320 hw pixels, 256 col.
XDL_C2S equ 0                        ; BAR: neither HR nor LR = SR -- 320 bytes,
                                     ;   one per hardware pixel, still 256
                                     ;   colours.
BAR_W   equ 320                      ; VRAM_BAR320's row pitch, in bytes
BAR_LO  equ VRAM_BAR320 & $FFFF
BAR_HI  equ VRAM_BAR320 >> 16        ; $D000 + 31*320 = $F6C0: the 16-bit part
                                     ;   never carries, so this is a constant

; Entry = 8 bytes: ctrl1, ctrl2, RPTL, then OVADR (3) + OVSTEP (2). Only the
; FIRST entry carries ATT (+2 bytes): VBXE keeps mode/palette/priority until
; something re-flags them, which is what update_flash relies on -- it still has
; one byte to poke for the damage tint (xdl_att, weapon.asm).
xdl_tab
        dta XDL_C1, XDLC_ATT|XDLC_LR, 3          ; rows 0-3
        dta a(0), 0, a(SCREEN_WIDTH)
        dta XDL_ATT_BASE | FL_PAL_NORM, PRI_ALL
        dta XDL_C1, XDL_C2, 1                    ; row 4, twice
        dta a(4*SCREEN_WIDTH), 0, a(0)
        .rept 31                                 ; rows 5..159
        dta XDL_C1, XDL_C2, 3
        dta a([[#+1]*5]*SCREEN_WIDTH), 0, a(SCREEN_WIDTH)
        dta XDL_C1, XDL_C2, 1
        dta a([[#+1]*5+4]*SCREEN_WIDTH), 0, a(0)
        .endr
        dta XDL_C1, XDL_C2, 7                    ; rows 160-167, 1:1
        dta a(160*SCREEN_WIDTH), 0, a(SCREEN_WIDTH)
XDL_VIEWB equ * - xdl_tab            ; the bar's entries start here: everything
                                     ;   before it is a VIEW entry and flips
        .rept 7                                  ; bar rows 0..27 (screen 168..195)
        dta XDL_C1, XDL_C2S, 2
        dta a(BAR_LO + [#*4]*BAR_W), BAR_HI, a(BAR_W)
        dta XDL_C1, XDL_C2S, 1
        dta a(BAR_LO + [#*4+3]*BAR_W), BAR_HI, a(0)
        .endr
        dta XDL_C1, XDL_C2S, 2                   ; bar rows 28-30
        dta a(BAR_LO + 28*BAR_W), BAR_HI, a(BAR_W)
        dta XDL_C1, XDL_C2S|XDLC_END, 1          ; bar row 31, twice -- and done
        dta a(BAR_LO + 31*BAR_W), BAR_HI, a(0)
xdl_tab_end
XDL_NVIEW equ [XDL_VIEWB - 10] / 8   ; view entries AFTER the 10-byte first one
XDL_BARB  equ xdl_tab_end - xdl_tab - XDL_VIEWB  ; 128 B: the bar tail, and the
                                     ;   only part list L differs in

;--------------------------------------------------------------
; xdl_bar_lr -- list L's bar tail: the SAME sixteen entries this file used to
;   end with, LR and reading FRAME_A rows 168-199. ?barlr writes it over list L's
;   copy of the SR tail.
;--------------------------------------------------------------
        .segment D0                  ; DRAC_PLAN 3a: OUT of the 1 KB staging
xdl_bar_lr                           ;   buffer -- 128 B of data, not code
        .rept 7                                  ; rows 168..195
        dta XDL_C1, XDL_C2, 2
        dta a([168+#*4]*SCREEN_WIDTH), 0, a(SCREEN_WIDTH)
        dta XDL_C1, XDL_C2, 1
        dta a([168+#*4+3]*SCREEN_WIDTH), 0, a(0)
        .endr
        dta XDL_C1, XDL_C2, 2                    ; rows 196-198
        dta a(196*SCREEN_WIDTH), 0, a(SCREEN_WIDTH)
        dta XDL_C1, XDL_C2|XDLC_END, 1           ; row 199, twice -- and done
        dta a(199*SCREEN_WIDTH), 0, a(0)
    .if * - xdl_bar_lr != XDL_BARB
        ert 'xdl_bar_lr is not the same size as the SR bar tail -- list L would'
        ert '  end in the middle of an entry'
    .endif

;--------------------------------------------------------------
; xdl_build -- both lists into VRAM. Called by setup_xdl, before any SIO, so
;   zp_ptr and zp_tsrc are free (nothing has rendered or loaded yet).
;--------------------------------------------------------------
.proc xdl_build
        ; --- RAPIDUS GUARD (2026-08-10, the Rapidus-device black boot).
        lda.l $FF0080
        ora #$04                     ; bit2 = window $8000-$BFFF -> slow (chip
        sta.l $FF0080                ;   bus, MEMAC-A ok); win1 stays as boot
                                     ;   set it: FAST ($4000-$7FFF, en_tick!)
                                      ; DRAC_PLAN 3b: 16 KB window
        ldy #>[MEMW16+[[XDL_BANKA&3]<<12]]
        lda #BANK_EN | XDL_BANKA
        jsr xb_copy                  ; list A: every entry reads FRAME_A
        lda #1                       ; list B: the VIEW entries read FRAME_B.
        jsr ?pat                     ;   The bar entries keep bank 0 -- rows
                                      ; DRAC_PLAN 3b: 16 KB window
        ldy #>[MEMW16+[[[XDL_BANKA+1]&3]<<12]]
        lda #BANK_EN | XDL_BANKA+1   ;   in FRAME_A only (memory_map.inc)
        jsr xb_copy
        lda #FRAME_C_BANK            ; list C: the VIEW entries read FRAME_C
        jsr ?pat                     ;   (2026-08-11, the triple buffer)
                                      ; DRAC_PLAN 3b: 16 KB window
        ldy #>[MEMW16+[[XDL_BANKA&3]<<12]+$800]
        lda #BANK_EN | XDL_BANKA     ;   (VRAM_XDL_C -- never-streamed padding)
        jsr xb_copy
        lda #0                       ; list L: view entries back on FRAME_A, and
        jsr ?pat                     ;   then the bar tail back to LR -- see
                                      ;   xdl_bar_lr. It rides list B's chunk at
        ldy #>[MEMW16+[[XDL_BANKL&3]<<12]+$300]  ; +$300 (list B ends at $28A).
        lda #BANK_EN | XDL_BANKL
        jsr xb_copy
        jsr ?barlr
        lda #BANK_EN | BANK_OVERHEAD ; window back where everything else wants it
        sta VBXE_BANK_SEL
        rts
                                      ; 2026-09-22 (rapidus-bus-timing): into the window
?barlr  lda #<[MEMW16+[[XDL_BANKL&3]<<12]+$300+XDL_VIEWB]
        sta zp_tsrc                  ;   through [zp_tsrc],y, bank byte zp_savex = 0:
        lda #>[MEMW16+[[XDL_BANKL&3]<<12]+$300+XDL_VIEWB]
        sta zp_tsrc+1                ;   a (dp),y store dummy-reads the window first
        stz zp_savex
        ldy #XDL_BARB-1              ; 128 B, and 127 fits a bpl countdown
?blb    lda xdl_bar_lr,y
        sta [zp_tsrc],y
        dey
        bpl ?blb
        rts
?pat    sta xdl_tab+5                ; A = the bank every VIEW entry reads
        sta ?pv+1                    ;   (boot-only staged code: self-mod is ok)
        ldx #XDL_NVIEW
        lda #<[xdl_tab+10+5]
        sta zp_ptr
        lda #>[xdl_tab+10+5]
        sta zp_ptr+1
        ldy #0                       ; (nothing in the loop touches Y: hoisted)
?p
?pv     lda #1
        sta (zp_ptr),y
        lda zp_ptr
        clc
        adc #8                       ; ... and on to the next entry's bank byte
        sta zp_ptr
        bcc ?nc
        inc zp_ptr+1
?nc     dex
        bne ?p
        rts
.endp

;--------------------------------------------------------------
; xb_copy -- A = the MEMAC bank byte; 3 pages of xdl_tab through the window.
;   Three pages is 768 for a 650-byte list: the tail is this code, which lands
;   past the END entry and is never looked at.
;--------------------------------------------------------------
.proc xb_copy                        ; A = BANK_EN|chunk, Y = >dst window page
        sta VBXE_BANK_SEL            ;   ($90 = chunk base, $98 = +$800: list C
                                      ; 2026-09-22 (rapidus-bus-timing): source through
        lda #<xdl_tab                ;   (zp_ptr),y, the WINDOW through [zp_tsrc],y
        sta zp_ptr                   ;   (bank byte zp_savex = 0) -- a (dp),y store
        lda #>xdl_tab                ;   dummy-reads the window first
        sta zp_ptr+1
        lda #<MEMW
        sta zp_tsrc
        sty zp_tsrc+1
        stz zp_savex
        ldx #3
?pg     ldy #0
?by     lda (zp_ptr),y
        sta [zp_tsrc],y
        iny
        bne ?by
        inc zp_ptr+1
        inc zp_tsrc+1
        dex
        bne ?pg
        rts
.endp
        .endseg

    .if * > XDLSTAGE_END+1
        ert 'xdl.asm outgrew TEX_STAGE ($1000-$13FF) -- memory_map.inc'
    .endif

;--------------------------------------------------------------
; xdl_att -- A = the overlay mode|palette byte, into BOTH lists. update_flash
;   used to store it straight into the window because the XDL was in the
;   overhead bank; it is in $08/$09 now, so the window takes a trip.
;--------------------------------------------------------------
xdlatt_resume = *
        org XDLATT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc xdl_att                        ; A = the byte -> ALL THREE lists (list C
                                      ; DRAC_PLAN 3b: 16 KB window
        ldx #BANK_EN | XDL_BANKA+1   ;   rides chunk 8 at +$800, 2026-08-11)
        stx VBXE_BANK_SEL
        sta MEMW16+[[[XDL_BANKA+1]&3]<<12]+8
        dex                          ; -> BANK_EN | XDL_BANKA
        stx VBXE_BANK_SEL
        sta MEMW16+[[XDL_BANKA&3]<<12]+8
        sta MEMW16+[[XDL_BANKA&3]<<12]+$800+8
        ldx #BANK_EN | BANK_OVERHEAD
        stx VBXE_BANK_SEL
        rts
.endp
        .endseg
    .if * > XDLATT_END+1
        ert 'xdl_att outgrew XDLATT_BASE..END (memory_map.inc)'
    .endif
        org xdlatt_resume
