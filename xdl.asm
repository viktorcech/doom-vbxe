;==============================================================
; xdl.asm -- DOOM's 200 rows over the PAL screen's 240 scanlines.
;--------------------------------------------------------------
; The port renders 160x200, which is DOOM's own 320x200 halved horizontally.
; The XDL used to describe exactly those 200 lines, so the bottom 40 lines of
; the 240 a PAL VBXE can show were never covered by the overlay and came out
; BLACK -- a band under the title, under the menu and under the game.
;
; The fix is a display-list change and nothing else: the framebuffer, the
; renderer, hud_blit's row tables and every screen coordinate in the port stay
; exactly as they were. An XDL entry covers RPTL+1 scanlines and adds OVSTEP to
; the overlay address on each one, so an entry with OVSTEP = 0 shows the SAME
; framebuffer row twice. Sprinkling those in stretches the picture vertically:
;
;   view  rows 0-159   32 groups of "4 rows, then one row twice"  = 192 lines
;         rows 160-167 one entry, 1:1                             =   8 lines
;   bar   rows 168-199  8 groups of "3 rows, then one row twice"  =  40 lines
;                                                                  ---------
;                                                                   240 lines
;
; That is a 1.19x stretch on the view and 1.25x on the status bar, against the
; 1.2x that DOOM itself was displayed at (320x200 on a 4:3 screen has 1.2:1
; pixels), so this is not just "fills the screen" -- it is CLOSER to what DOOM
; looked like than the unstretched picture was. The split is where it is
; because the view/bar boundary has to fall ON an entry boundary: the bar rows
; are the SHARED ones at VRAM_HUDROWS (bank 0 always), the view rows flip
; between FRAME_A and FRAME_B, and one entry cannot be half of each.
;
; TWO LISTS, NOT ONE PATCHED. 81 entries means the old trick -- swap_buffers
; pokes the OVADR bank byte of the single view entry -- would become a 65-entry
; write loop every frame. So the builder emits the list TWICE, into VBXE banks
; $08 and $09 (free VRAM, the old weapon region), identical except that XDL B's
; view entries read FRAME_B. Flipping is then one store to VBXE_XDLA1 ($80 or
; $90), which is CHEAPER than what it replaced.
;
; THE BAR IS SR NOW (2026-09-16). The bottom eight entries drop XDLC_LR, so the
; last 40 scanlines are scanned at 320 bytes a row -- one byte per hardware
; pixel, the mode the title picture has always used -- out of VRAM_BAR320, while
; everything above them stays LR out of the framebuffer. VBXE reads the mode off
; EVERY entry (alt-src vbxe.cpp:1669, kOvModeTable indexed by ctrl1's GMON and
; ctrl2's HR/LR bits), so mixing the two in one list costs nothing but the
; entries themselves. What it buys is the whole point: STBAR, the big red digits
; and the face stop being sampled 2:1 (tools/pack_hud.py).
;
; AND THAT IS WHY LIST L EXISTS. The intermission, the finale, the READ THIS!
; pages, the loading screen and the melt all paint a full 160x200 picture into
; FRAME_A and would lose their bottom 32 rows on a list whose bar comes from
; somewhere else. List L is lists A/B/C's table with the bar tail put back the
; way it was -- 128 bytes of it, xdl_bar_lr, because a second 650-byte table
; does not fit the 1 KB staging buffer and does not need to: every byte before
; XDL_VIEWB is shared. wi_show, fin_show, mn_readthis and mn_togame select it;
; nothing selects it back, because the game's own flip only knows A/B/C.
;
; A FOURTH LIST EXISTS AND IS NOT BUILT HERE. The title screen is shown in SR
; mode -- 320 bytes a row, one byte per pixel -- from a list with this exact
; stretch pattern and OVSTEP 320 instead of 160. It is not in this file because
; a second 650-byte table does not fit in the 1 KB staging buffer below; it is
; DATA, so tools/pack_menu.py emits it (_sr_entries / _sr_xdl) into the padding
; behind the 320-wide picture itself, at MENU_SRXDL. THE TWO PATTERNS MUST STAY
; IDENTICAL: menu.asm switches from that list to list A on the first keypress,
; and a different stretch would make the picture jump under the menu. Change the
; groups below and you change them there.
;
; This whole file is boot-only and lives in TEX_STAGE ($1000-$13FF), the 1 KB
; SIO staging buffer: setup_xdl runs before the first loader, and by the time
; anything streams through that buffer the list is in VRAM and this code is
; dead. tools/ram_map.py STAGED carries the claim (same deal as menu.asm).
;==============================================================
XDL_C1  equ XDLC_GMON | XDLC_MAPOFF | XDLC_RPTL | XDLC_OVADR
XDL_C2  equ XDLC_LR                  ; VIEW: 160 bytes = 320 hw pixels, 256 col.
XDL_C2S equ 0                        ; BAR: neither HR nor LR = SR -- 320 bytes,
                                     ;   one per hardware pixel, still 256
                                     ;   colours. VBXE decides the mode per
                                     ;   ENTRY (alt-src vbxe.cpp kOvModeTable is
                                     ;   indexed by ctrl1's GMON/TMON and ctrl2's
                                     ;   HR/LR), so the view above stays LR and
                                     ;   nothing but these eight entries changes.
                                     ;   The ATT byte is only on entry 0 and
                                     ;   carries OV_NORMAL for both, so the two
                                     ;   halves are the same 320 pixels WIDE --
                                     ;   the bar just gets twice the samples.
                                     ;   Costs 320 VRAM cycles a scanline instead
                                     ;   of 160 (kOvCyclesPerMode), i.e. 6,400 of
                                     ;   the frame's 284,544 -- 2.2% of what the
                                     ;   blitter would otherwise be credited.
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
;   copy of the SR tail. A SECOND FULL TABLE WOULD NOT FIT -- 650 B more in a
;   1 KB staging buffer -- and it does not have to: lists A/B/C and L share every
;   byte up to XDL_VIEWB.
;   THE PATTERN MUST STAY THE SAME as the SR tail above, 3+1 rows eight times:
;   the melt runs on list L and hands the picture over to list A at the end, and
;   a different stretch would make the bottom of the screen jump on the handover.
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
        ; --- RAPIDUS GUARD (2026-08-10, the Rapidus-device black boot). A fast
        ; window over $8000-$BFFF shadows every READ of the VBXE MEMAC-A window
        ; at $9000: the SRAM copy outprioritises the bus (underrom.asm header;
        ; alt-src rapidus.cpp UpdateSRAMWindows), so mn_open copied garbage
        ; instead of the menu overlay, execution fell through a bad RTS and
        ; load_level never ran -- the BLUE $2089 halt. Window 2 must stay SLOW
        ; forever (sprite arena fetches read MEMAC-A mid-game too).
        ; 2026-08-11: window 1 is NOT forced slow any more. The old `ora #$06`
        ; also re-slowed $4000-$7FFF moments after boot.asm's MCR write made it
        ; fast -- which is why every region experiment measured 0.0%: the game
        ; never actually ran with win1 fast. $4000-$7FFF has NO VBXE tenant:
        ; MEMAC-B is written 0 in setup_memac and snd_init (legacy off since
        ; the samples moved to Rapidus bank $02, 2026-07-31), and per alt-src
        ; rapidus.cpp:920 the FPGA yields window 1 to PORTB XE banking anyway
        ; (this port never banks). Without a Rapidus this is a write to plain
        ; RAM at $FF:0080 -- harmless. Runs HERE because this is the last
        ; boot-only code before anything reads through the window.
        lda.l $FF0080
        ora #$04                     ; bit2 = window $8000-$BFFF -> slow (chip
        sta.l $FF0080                ;   bus, MEMAC-A ok); win1 stays as boot
                                     ;   set it: FAST ($4000-$7FFF, en_tick!)
 .if 1                                ; DRAC_PLAN 3b: 16 KB window
        ldy #>[MEMW16+[[XDL_BANKA&3]<<12]]
 .else
        ldy #>MEMW
 .endif
        lda #BANK_EN | XDL_BANKA
        jsr xb_copy                  ; list A: every entry reads FRAME_A
        lda #1                       ; list B: the VIEW entries read FRAME_B.
        jsr ?pat                     ;   The bar entries keep bank 0 -- rows
 .if 1                                ; DRAC_PLAN 3b: 16 KB window
        ldy #>[MEMW16+[[[XDL_BANKA+1]&3]<<12]]
 .else
        ldy #>MEMW                   ;   168-199 are the SHARED bar and exist
 .endif
        lda #BANK_EN | XDL_BANKA+1   ;   in FRAME_A only (memory_map.inc)
        jsr xb_copy
        lda #FRAME_C_BANK            ; list C: the VIEW entries read FRAME_C
        jsr ?pat                     ;   (2026-08-11, the triple buffer)
 .if 1                                ; DRAC_PLAN 3b: 16 KB window
        ldy #>[MEMW16+[[XDL_BANKA&3]<<12]+$800]
 .else
        ldy #>[MEMW+$800]            ; ... and the LIST lands at chunk 8 + $800
 .endif
        lda #BANK_EN | XDL_BANKA     ;   (VRAM_XDL_C -- never-streamed padding)
        jsr xb_copy
        lda #0                       ; list L: view entries back on FRAME_A, and
        jsr ?pat                     ;   then the bar tail back to LR -- see
 .if 1                                ;   xdl_bar_lr. It rides list B's chunk at
        ldy #>[MEMW16+[[XDL_BANKL&3]<<12]+$300]  ; +$300 (list B ends at $28A).
 .else
        ldy #>[MEMW+$300]
 .endif
        lda #BANK_EN | XDL_BANKL
        jsr xb_copy
        jsr ?barlr
        lda #BANK_EN | BANK_OVERHEAD ; window back where everything else wants it
        sta VBXE_BANK_SEL
        rts
?barlr  lda #<[MEMW16+[[XDL_BANKL&3]<<12]+$300+XDL_VIEWB]
        sta zp_ptr                   ; (xb_copy left the window on XDL_BANKL)
        lda #>[MEMW16+[[XDL_BANKL&3]<<12]+$300+XDL_VIEWB]
        sta zp_ptr+1
        ldy #XDL_BARB-1              ; 128 B, and 127 fits a bpl countdown
?blb    lda xdl_bar_lr,y
        sta (zp_ptr),y
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
        lda #<xdl_tab                ;   rides list A's chunk padding)
        sta zp_tsrc
        lda #>xdl_tab
        sta zp_tsrc+1
        lda #<MEMW
        sta zp_ptr
        sty zp_ptr+1
        ldx #3
?pg     ldy #0
?by     lda (zp_tsrc),y
        sta (zp_ptr),y
        iny
        bne ?by
        inc zp_tsrc+1
        inc zp_ptr+1
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
;   overhead bank; it is in $08/$09 now, so the window takes a trip. Only ever
;   called when the tint actually CHANGES (weapon.asm compares fl_shown), so
;   the four register writes cost nothing per frame.
;   THE ONE PIECE OF THIS FILE THAT OUTLIVES BOOT -- everything above is staged
;   in the SIO buffer and gone after the first load, so this cannot be.
;--------------------------------------------------------------
xdlatt_resume = *
        org XDLATT_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc xdl_att                        ; A = the byte -> ALL THREE lists (list C
 .if 1                                ; DRAC_PLAN 3b: 16 KB window
        ldx #BANK_EN | XDL_BANKA+1   ;   rides chunk 8 at +$800, 2026-08-11)
        stx VBXE_BANK_SEL
        sta MEMW16+[[[XDL_BANKA+1]&3]<<12]+8
        dex                          ; -> BANK_EN | XDL_BANKA
        stx VBXE_BANK_SEL
        sta MEMW16+[[XDL_BANKA&3]<<12]+8
        sta MEMW16+[[XDL_BANKA&3]<<12]+$800+8
        ldx #BANK_EN | BANK_OVERHEAD
        stx VBXE_BANK_SEL
 .else
        ldx #BANK_EN | XDL_BANKA+1   ;   rides chunk 8 at +$800, 2026-08-11)
        stx VBXE_BANK_SEL
        sta MEMW+8
        dex                          ; -> BANK_EN | XDL_BANKA
        stx VBXE_BANK_SEL
        sta MEMW+8
        sta MEMW+$800+8
        ldx #BANK_EN | BANK_OVERHEAD
        stx VBXE_BANK_SEL
 .endif
        rts
.endp
        .endseg
    .if * > XDLATT_END+1
        ert 'xdl_att outgrew XDLATT_BASE..END (memory_map.inc)'
    .endif
        org xdlatt_resume
