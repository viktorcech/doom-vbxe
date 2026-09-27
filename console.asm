;--------------------------------------------------------------
; console.asm -- the PC DOOM text-mode startup, 1:1 (2026-09-26).
;   An 80x25 VBXE TEXT overlay (XDLC_TMON: 2 B a cell -- char + attribute,
;   font at CHBASE<<11, 8x8 cells) shows D_DoomMain's own startup lines
;   while the boot streams load, with R_Init's dots fed by the depacker
;   (one dot per 32 KB pulled through inflate's ?ifill). The title screen
;   takes the display over at the end exactly as before -- everything here
;   lives in VRAM $004000-$005FFF, which the first frame clear reuses.
;
;   Cells: attr bit 7 = opaque cell, low 7 bits = overlay-palette colour.
;   CON_COL = 7 -> light grey out of the hand-set boot palette first, and
;   PLAYPAL's own near-white 7 once load_palette lands -- both look DOS.
;--------------------------------------------------------------

CON_MAP   equ $004000                ; 25 rows x 160 B (char,attr per cell)
CON_BLANK equ $004FA0                ; one blank row: the 40 PAL pad lines
CON_XDL   equ $005100                ; the console's display list (page-
                                     ;   aligned, PAST the blank row's end)
CON_FONT  equ $005800                ; 2 KB-aligned (CHBASE = addr >> 11)
CON_COL   equ $07                    ; DOS light grey (palette 1, entry 7)
CON_BARI  equ $04                    ; the bar: DOS red ink, and attr bit 7
CON_BAR   equ $80|CON_BARI           ;   papers it in $84 = light grey
CON_W     equ 80
CON_H     equ 25
    .if CON_FONT & $7FF
        ert 'CHBASE is the font address >> 11: CON_FONT must be 2 KB-aligned'
    .endif

; --- the boot script: DOS DOOM v1.9's startup screen, 1:1 -----------------
;   (the real one, not linuxdoom's d_main.c: V/Z/W_Init print BEFORE DOS
;   DOOM clears the screen, so the screen starts at the red-on-grey bar)
;   Eight strings, printed IN ORDER by eight call sites (a ninth, ENDOOM,
;   is con_end's at QUIT DOOM; con_msg keeps its
;   own cursor); $9B = new line, 0 = end. The TEXT lives in the bank-$01
;   segment (b1 DATA reads fine long); the table and the state stay bank 0.
;   Exactly 25 rows: bar 1, WAD 2, box 4, M/R_Init 2, I_Startup 6, sound
;   and net 7, HU/ST 2, the cursor 1.
CON_NDOTS equ [[POOL_PAK_SECT+7]/8]/32   ; R_Init's dots: one per 32 KB of
                                         ;   the pool stream (con_tick)
        .segment D0                  ; DRAC_PLAN 3a: bank-0 data
con_stab dta a(con_s0), a(con_s1), a(con_s2), a(con_s3)
        dta a(con_s4), a(con_s5), a(con_s6), a(con_s7)
        dta a(con_s8)                ; ENDOOM, on QUIT DOOM (con_end)
        dta a(con_s9)                ; ... and its prompt's DIR
con_next dta 0
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
con_s0                               ; the BAR: "DOOM VBXE System Startup
        icl 'console_ver.inc'        ;   v<VERSION> by <author>", 80 columns,
        dta 0                        ;   pack_menu.py (the credits' own text)
con_s1  dta c'        adding doom.wad', $9B
        dta c'        registered version.', $9B
        dta c'==========================================================================='
        dta $9B
        dta c'           This version is NOT SHAREWARE, do not distribute!', $9B
        dta c'         Please report software piracy to the SPA: 1-800-388-PIR8', $9B
        dta c'==========================================================================='
        dta $9B, 0
con_s2  dta c'M_Init: Init miscellaneous info.', $9B, 0
con_s3  dta 0                        ; (a call site with nothing to say)
con_s4  dta c'R_Init: Init DOOM refresh daemon - ['
        :CON_NDOTS dta c' '          ; the dots' room, filled by con_tick
        dta c']', 0
con_s5  dta $9B, c'P_Init: Init Playloop state.', $9B
        dta c'I_Init: Setting up machine state.', $9B
        dta c'I_StartupDPMI', $9B
        dta c'I_StartupMouse', $9B
        dta c'I_StartupJoystick', $9B
        dta c'I_StartupKeyboard', $9B, 0
con_s6  dta c'I_StartupSound', $9B
        dta c'I_StartupTimer()', $9B
        dta c'  calling DMX_Init', $9B
        dta c'D_CheckNetGame: Checking network game status.', $9B
        dta c'startskill 2  deathmatch: 0  startmap: 1  startepisode: 1', $9B
        dta c'player 1 of 1 (1 nodes)', $9B
        dta c'S_Init: Setting up sound.', $9B, 0
con_s7  dta c'HU_Init: Setting up heads up display.', $9B
        dta c'ST_Init: Init status bar.', $9B
        dta c'_', 0                  ; DOS's cursor, where the prompt would be
; ENDOOM (DOOM.WAD's own lump, 1:1): what DOS DOOM's I_Quit leaves on the
;   screen. $01-$05 = the ink/paper pair (con_epal), $06 = the box's left
;   edge (column 7); the black margins and rows 23-24 are the cleared map.
;   The two CP437 glyphs it uses come out of the ROM font as ATASCII
;   graphics, $C0+code (con_putc keeps $60+ as internal codes).
con_s8
        dta $06, $05                 ; row 0: $DF (upper half block) =
        :66 dta $D5                  ;   ATASCII $15 (lower half), red on black
        dta $9B
        dta $06, $02, c'             DOOM', $01, c', a hellish 3-D game by ', $03, c'id', $01, c' Software.             ', $9B
        dta $06, $02, c' ', $01    ; $C4 (thin line) = ATASCII $12
        :64 dta $D2
        dta c' ', $9B
        dta $06, $02, c'          ', $01, c'YOU ARE PLAYING THE REGISTERED VERSION OF ', $02, c'DOOM', $01, c'.         ', $9B
        dta $06, $02, c'  ', $01, c'If you haven''t paid for ', $02, c'DOOM', $01, c', you are playing illegally. That   ', $9B
        dta $06, $02, c' ', $01, c'means you owe us money. Of course, a guy like you probably owes  ', $9B
        dta $06, $02, c'  ', $01, c'a lot of people money--your friends, maybe even your parents.   ', $9B
        dta $06, $02, c'   ', $01, c'Stop being a freeloader and register ', $02, c'DOOM', $01, c'. Call us now at      ', $9B
        dta $06, $02, c'                   1-800-IDGAMES', $01, c'. We can help!                    ', $9B
        dta $06, $02, c'                                                                  ', $9B
        dta $06, $01, c' If you have registered ', $02, c'DOOM', $01, c', feel confident that you have done   ', $9B
        dta $06, $02, c'    ', $01, c'the right thing--not only for yourself, but for the World.    ', $9B
        dta $06, $02, c'   ', $01, c'We hope you enjoy playing ', $02, c'DOOM', $01, c'. We enjoyed making it for you.  ', $9B
        dta $06, $02, c'                                                                  ', $9B
        dta $06, $01, c'      If you have any problems playing ', $02, c'DOOM', $01, c', please call our      ', $9B
        dta $06, $02, c'             ', $01, c'technical support line at (214) 613-0132.            ', $9B
        dta $06, $02, c'                                                                  ', $9B
        dta $06, $02, c'                 DOOM ', $01, c'WAS CREATED BY ', $03, c'id', $01, c' SOFTWARE:                 ', $9B
        dta $06, $02, c'       ', $04, c'Programming', $01, c': John Carmack, John Romero, Dave Taylor        ', $9B
        dta $06, $02, c'                  ', $04, c'Art', $01, c': Adrian Carmack, Kevin Cloud                ', $9B
        dta $06, $02, c'      ', $04, c'  Design', $01, c': Sandy Petersen    ', $04, c'Tech Support', $01, c': Shawn Green       ', $9B
        dta $06, $02, c'                        ', $04, c'BIZ', $01, c': Jay Wilbur                    ', $04, c'       ', $9B
        dta $06, $02, c'                                                                  ', $9B
        dta 0
; DIR at ENDOOM's prompt: a made-up C:\DOOM, in MS-DOS 6.22's own layout
;   (a blank line first, as DIR prints one; con_msg scrolls through con_nl)
con_s9
        dta $9B
        dta c' Volume in drive C is MS-DOS_6', $9B
        dta c' Volume Serial Number is 1F2E-3D4C', $9B
        dta c' Directory of C:', $5C, c'DOOM', $9B
        dta $9B
        dta c'.            <DIR>         02-01-95   1:09a', $9B
        dta c'..           <DIR>         02-01-95   1:09a', $9B
        dta c'DOOM     EXE       709,905 02-01-95   1:09a', $9B
        dta c'DOOM     WAD    11,159,840 02-01-95   1:09a', $9B
        dta c'SETUP    EXE        79,248 02-01-95   1:09a', $9B
        dta c'IPXSETUP EXE        48,946 02-01-95   1:09a', $9B
        dta c'SERSETUP EXE        39,982 02-01-95   1:09a', $9B
        dta c'DEFAULT  CFG         1,046 02-01-95   1:09a', $9B
        dta c'README   TXT        18,741 02-01-95   1:09a', $9B
        dta c'        9 file(s)     12,057,708 bytes', $9B
        dta c'                      31,457,280 bytes free', 0
    .if 36+CON_NDOTS+1 > CON_W-1
        ert 'the R_Init dots do not fit the 80-column line'
    .endif
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: bank-0 data
con_on   dta 0                       ; the console owns the display
con_dots dta 0                       ; ?ifill ticks: a dot per 32 of them,
                                     ;   only while bit 7 of con_on is set
con_cx   dta 0                       ; cursor column (0-79)
con_cy   dta 0                       ; cursor row (0-24)
con_attr dta CON_COL                 ; the attribute con_putc lays down
con_nd   dta 0                       ; R_Init dots still to come
con_kd   dta 0                       ; ENDOOM's prompt: a key is down
con_ci   dta 0                       ; con_find's name counter
con_ln   dta 0                       ; the typed line's length ...
CON_LNMAX equ CON_W-8-1              ;   (after the 8-char prompt, and the
con_lb   :CON_LNMAX dta 0            ;   cursor's cell) ... and its chars
        .endseg

;--------------------------------------------------------------
; con_init -- font out of the OS ROM (still banked IN here: runs before
;   urom_init), the map cleared, the XDL built, palette 1's grey seeded,
;   display on. All through the MEMAC window like every other VRAM writer.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc con_init
        lda #1                       ; palette 1 (NEVER 0 -- FL_PAL_GOLD): the
        sta VBXE_PSEL                ;   opaque text mode inks a cell in entry
        ldx #CON_PALN-4              ;   attr&$7F and papers it in $80, or in
?pal    lda.l B1CODE_BASE+con_palt,x ;   $80+ink when attr bit 7 is set
        sta VBXE_CSEL                ;   (vbxe.cpp:2943-2946). PLAYPAL takes
        lda.l B1CODE_BASE+con_palt+1,x   ;   all four back at load_palette,
        sta VBXE_CR                  ;   after the console's last line.
        lda.l B1CODE_BASE+con_palt+2,x
        sta VBXE_CG
        lda.l B1CODE_BASE+con_palt+3,x
        sta VBXE_CB                  ; (CB commits the entry)
        dex
        dex
        dex
        dex
        bpl ?pal

        lda #BANK_EN|[CON_MAP>>12]   ; the whole $004000-$005FFF block sits
        sta VBXE_BANK_SEL            ;   in ONE 16 KB window page
        php                          ; the OS font lives at $E000: ROM IN for the
        sei                          ;   copy -- and with it the ROM's $FFEA/$FFEE,
        stz NMIEN                    ;   so NO interrupt may land meanwhile: urom_init
                                     ;   left the VBI on, and a native NMI taken with
                                     ;   the ROM in jumps through the ROM's bytes
                                     ;   (Altirra, 2026-09-26: PC $FAFF). As siov_r.
        lda PORTB
        pha
        ora #1
        sta PORTB
        ldx #0                       ; ROM font $E000 -> CON_FONT (128 chars,
?fnt    lda $E000,x                  ;   1 KB x 4 copies fill the 2 KB slot
        sta MEMW16+[CON_FONT&$3FFF],x         ;   so bit 7 codes stay harmless)
        lda $E100,x
        sta MEMW16+[CON_FONT&$3FFF]+$100,x
        lda $E200,x
        sta MEMW16+[CON_FONT&$3FFF]+$200,x
        lda $E300,x
        sta MEMW16+[CON_FONT&$3FFF]+$300,x
        lda $E000,x
        sta MEMW16+[CON_FONT&$3FFF]+$400,x
        lda $E100,x
        sta MEMW16+[CON_FONT&$3FFF]+$500,x
        lda $E200,x
        sta MEMW16+[CON_FONT&$3FFF]+$600,x
        lda $E300,x
        sta MEMW16+[CON_FONT&$3FFF]+$700,x
        inx
        bne ?fnt
        pla                          ; PORTB back the way it was (ROM out) ...
        sta PORTB
        lda #$40                     ; ... and only then the VBI and the caller's
        sta NMIEN                    ;   I flag back (urom_init's state)
        plp
        ; the map + the blank row: char 0 (the internal SPACE) on attr 0 --
        ;   no ink, $80 paper: black. Map and XDL share one window page.
        lda #<[MEMW16+[CON_MAP&$3FFF]]
        sta zp_ptr
        lda #>[MEMW16+[CON_MAP&$3FFF]]
        sta zp_ptr+1
        ldx #[[CON_H*CON_W*2+CON_W*2+255]/256]
        ldy #0
        tya
?clr    sta (zp_ptr),y
        iny
        bne ?clr
        inc zp_ptr+1
        dex
        bne ?clr
        ; the XDL, THREE entries: 24 blank lines, the 25 text rows (ONE
        ;   entry: the text mode steps OVADR itself on every 8th line,
        ;   vbxe.cpp:2073), 16 blank lines. 240 = the title list's span;
        ;   24 on top puts row 0 at scan line 32 like ANTIC: at 28 a real
        ;   CRT's overscan ate the bar's top 4 lines (Altirra shows them).
        ldx #CON_XDLN-1
?xdl    lda.l B1CODE_BASE+con_xdlt,x
        sta MEMW16+[CON_XDL&$3FFF],x
        dex
        bpl ?xdl
        lda #BANK_EN|BANK_OVERHEAD   ; the window back on the BCB bank
        sta VBXE_BANK_SEL
        stz con_cx
        stz con_cy
        stz con_next
        stz con_nd
        lda #CON_COL
        sta con_attr
        lda #$01                     ; on; the R_Init dots gate (bit 7) shut
        sta con_on
        stz VBXE_XDLA0               ; show it (the list is page-aligned)
        lda #>CON_XDL
        sta VBXE_XDLA1
        lda #CON_XDL>>16
        sta VBXE_XDLA2
        lda #VC_XDL_ON|VC_NO_TRANS
        sta VBXE_VCTL
        rts
.endp
; the DOS text colours: entry, R, G, B
con_palt dta CON_COL, $AA, $AA, $AA  ; ink: light grey
        dta $80, $00, $00, $00       ; paper: black
        dta CON_BARI, $AA, $00, $00  ; the bar's ink: DOS red
        dta $80+CON_BARI, $AA, $AA, $AA  ; ... on light grey paper
CON_PALN equ * - con_palt
; ctrl1 = TMON|MAP_OFF|RPTL|OVADR. Field order per entry (vbxe.cpp:556-
;   671): repeat, OVADR+step (5), CHBASE (1), OVATT (2) -- the first entry
;   loads the font and the attributes (OV_NORMAL|OV_PAL1|PF_PAL1, PRI_ALL).
con_xdlt dta $71, $09, 23, <CON_BLANK, >CON_BLANK, CON_BLANK>>16, 0, 0
        dta CON_FONT>>11, $51, $FF
        dta $71, $00, 199, <CON_MAP, >CON_MAP, CON_MAP>>16, <[CON_W*2], >[CON_W*2]
        dta $71, $80, 15, <CON_BLANK, >CON_BLANK, CON_BLANK>>16, 0, 0
CON_XDLN equ * - con_xdlt
    .if CON_XDLN > 128
        ert 'con_xdlt: the copy loop counts with dex/bpl'
    .endif

;--------------------------------------------------------------
; con_row160 -- A = row -> A = low byte of row*160, con_r1 = high byte.
;--------------------------------------------------------------
.proc con_row160
        sta con_r0                   ; row*160 = row*128 + row*32
        stz con_r1
        rep #$20                     ; 16-bit: (row << 2 + row) << 5
        .LONGA ON
        lda con_r0
        and #$00FF
        asl @
        asl @
        adc con_r0
        and #$00FF                   ; (con_r1 is the high byte cell: keep
        asl @                        ;  the pair -- row*5 <= 120 fits a byte)
        asl @
        asl @
        asl @
        asl @
        sta con_r0
        .LONGA OFF
        sep #$20
        lda con_r0
        rts
.endp
        .endseg
        .segment D0
con_r0  dta 0
con_r1  dta 0
        .endseg

;--------------------------------------------------------------
; con_msg -- print the NEXT script string at the cursor. $9B = new line,
;   ASCII -> internal codes the ANTIC way ($20-$5F drop $20, $60+ stay).
;   Entry 0 is the inverted bar; entry 4 (R_Init) leaves the cursor inside
;   its [ ] and arms the depacker's dot ticker; entry 5 disarms it.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc con_msg
        lda con_next
        inc con_next
        pha                          ; the id, for the fixups after the print
        cmp #5                       ; entry 5 (P_Init): the dots are done
        bne ?n5
        lda #$80
        trb con_on
?n5     pla
        pha
        bne ?n0                      ; entry 0: the bar, red on grey
        lda #CON_BAR
        sta con_attr
        lda #0                       ; A = the id again, for the asl
?n0     asl @
        tax
        lda con_stab,x               ; the string sits in the B1 bank: walk
        sta zp_ptr                   ;   it [zp_ptr],y long (no loader runs
        lda con_stab+1,x             ;   mid-print, the cell is free)
        sta zp_ptr+1
        lda #B1CODE_BANK
        sta zp_ptr+2
        ldy #0
?lp     lda [zp_ptr],y
        beq ?done
        cmp #$9B
        bne ?ch
        jsr con_nl                   ; EOL (scrolls on the last row)
        bra ?nx
?ch     cmp #7
        bcs ?pc                      ; $07+ = a glyph
        cmp #6
        bne ?at
        lda #7                       ; $06: ENDOOM's box starts at column 7
        sta con_cx
        bra ?nx
?at     ora #$88                     ; $01-$05: ink entry 8+n, paper $88+n,
        sta con_attr                 ;   opaque (con_epal)
        bra ?nx
?pc     jsr con_putc
?nx     inc zp_ptr
        bne ?lp
        inc zp_ptr+1
        bra ?lp
?done   pla                          ; the id
        bne ?d0
        lda #CON_COL                 ; the bar filled all 80 columns: grey
        sta con_attr                 ;   ink again, and the next row
        stz con_cx
        inc con_cy
        rts
?d0     cmp #4
        bne ?d4
        lda con_cx                   ; R_Init: the cursor back inside [ ],
        sec                          ;   the dots' room, and the ticker armed
        sbc #CON_NDOTS+1
        sta con_cx
        lda #CON_NDOTS
        sta con_nd
        stz con_dots
        lda #$80
        tsb con_on
?d4     rts
.endp

;--------------------------------------------------------------
; con_putc -- A = ASCII: one glyph at the cursor, advance. Clobbers A/X.
;   Preserves Y (the loaders' invariant). Scrolling is not needed: the
;   script prints 24 lines at most -- the ert below counts them.
;--------------------------------------------------------------
.proc con_putc
        cmp #$60
        bcs ?cv                      ; $60+ = internal already
        sbc #$1F                     ; C = 0 (the bcs fell through): -$20
?cv     pha
        lda con_cy
        cmp #CON_H
        bcs ?off                     ; past the screen: swallow (belt)
        jsr con_row160               ; A = low of row*160, con_r1 = high
        clc
        adc con_cx                   ; + column*2
        sta zp_tmp
        lda con_r1
        adc #0
        sta zp_tmp+1
        lda con_cx
        clc
        adc zp_tmp
        sta zp_tmp
        bcc ?a1
        inc zp_tmp+1
?a1     lda #BANK_EN|[CON_MAP>>12]
        sta VBXE_BANK_SEL
        lda zp_tmp+1                 ; the cell offset is < $1000: the window
        ora #>MEMW16                 ;   address is simply MEMW16 + offset
        sta zp_tmp+1                 ;   ((CON_MAP >> 12) & 3 = 0)
        pla
        sta (zp_tmp)                 ; the char...
        lda con_attr                 ; ...and its attribute
        ldy #1
        sta (zp_tmp),y
        ldy #0                       ; the invariant, back on
        lda #BANK_EN|BANK_OVERHEAD
        sta VBXE_BANK_SEL
        inc con_cx
        rts
?off    pla
        rts
.endp

;--------------------------------------------------------------
; con_tick -- inflate's ?ifill calls this once per KB of packed stream.
;   While the R_Init gate is up, every 32nd KB prints one dot into the
;   [ ] room -- CON_NDOTS of them over the pool, and never past the ].
;--------------------------------------------------------------
.proc con_tick
        lda con_on
        bpl ?ret                     ; dots not armed (or console gone)
        lda con_nd
        beq ?ret                     ; the room is full
        inc con_dots
        lda con_dots
        and #31
        bne ?ret
        dec con_nd
        lda #'.'
        jmp con_putc
?ret    rts
.endp

;--------------------------------------------------------------
; con_off -- the title is about to take the display: stop printing.
;   (The XDL swap itself is mn_open's, exactly as before.)
;--------------------------------------------------------------
.proc con_off
        stz con_on
        rts
.endp

;--------------------------------------------------------------
; con_end -- I_Quit's ENDOOM (DOS DOOM): the console back up (con_init: the
;   ROM font, the map, the XDL), ENDOOM's inks on top, the screen printed,
;   then a key -- the reboot after QUIT DOOM would wipe it at once.
;   No SIO: TEX_STAGE is the overlay that calls this (sg_quit), and it
;   returns there -- after the quit sound, as DOS DOOM orders it.
;--------------------------------------------------------------
.proc con_end
        jsr con_init
        ldx #CON_EPALN-4             ; (PSEL is still 1: con_init)
?pal    lda.l B1CODE_BASE+con_epal,x
        sta VBXE_CSEL
        lda.l B1CODE_BASE+con_epal+1,x
        sta VBXE_CR
        lda.l B1CODE_BASE+con_epal+2,x
        sta VBXE_CG
        lda.l B1CODE_BASE+con_epal+3,x
        sta VBXE_CB
        dex
        dex
        dex
        dex
        bpl ?pal
        lda #8                       ; con_s8
        sta con_next
        jsr con_msg                  ; (the cursor ends on row 23, where
        lda #CON_COL                 ;   I_Quit parks it; its printf("\n")
        sta con_attr                 ;   puts COMMAND.COM's prompt on 24)
        jsr con_nl
        lda #1                       ; a key still held from the menu is not
        sta con_kd                   ;   typing
; --- COMMAND.COM (MS-DOS 6.22, PROMPT $P$G), just enough of it. Returns only
;   when DOOM is typed: sg_bye's reboot is DOOM.EXE starting over.
?pr     ldx #CON_T_PR                ; the prompt
        jsr con_str
        stz con_ln
?fr     lda RTCLOK3                  ; one frame
?w      cmp RTCLOK3
        beq ?w
        and #8                       ; the underline cursor: 8 frames on, 8 off
        beq ?cs                      ;   (VGA's own 16-frame blink cycle)
        lda #'_'
        bra ?cu
?cs     lda #' '
?cu     jsr con_putc
        dec con_cx
        lda SKSTAT
        and #4                       ; bit2 = 0 while a key is held
        beq ?kd
        stz con_kd                   ; released: the next press counts
        bra ?fr
?kd     lda con_kd                   ; one character a press, no repeat
        bne ?fr
        inc con_kd
        lda KBCODE
        bmi ?fr                      ; CONTROL+key: nothing
        cmp #$46                     ; SHIFT + '+' = backslash
        bne ?k1
        lda #$5C
        bra ?put
?k1     cmp #$42                     ; SHIFT + ';' = colon
        bne ?k2
        lda #':'
        bra ?put
?k2     and #$3F
        cmp #$0C                     ; RETURN
        beq ?ent
        cmp #$1C                     ; ESC: DOS cancels the line with a
        beq ?esc                     ;   backslash, and goes on on the next
        cmp #$34                     ;   row with no prompt. BACKSPACE:
        beq ?bs
        tax
        lda.l B1CODE_BASE+con_kmap,x
        beq ?fr                      ; a key DOS would not print
?put    ldx con_ln
        cpx #CON_LNMAX
        bcs ?fr                      ; the line is full
        sta con_lb,x
        inc con_ln
        jsr con_putc                 ; (over the cursor cell)
        bra ?fr
?bs     lda con_ln
        beq ?fr
        dec con_ln
        lda #' '                     ; the cursor cell blank, and one back:
        jsr con_putc                 ;   the blink paints over the char
        dec con_cx
        dec con_cx
        bra ?fr
?esc    lda #$5C                     ; over the cursor cell
        jsr con_putc
        jsr con_nl
        lda #8                       ; INT 21h/0Ah goes on under where the
        sta con_cx                   ;   line began, past the prompt
        stz con_ln
        jmp ?fr
?ent    lda #' '                     ; the cursor off the line
        jsr con_putc
        jsr con_nl
        lda con_ln
        bne ?cmd
        jmp ?pr                      ; an empty line: just the prompt
?cmd    jsr con_find
        tax
        beq ?doom                    ; 0 = DOOM
        dex
        beq ?cls                     ; 1 = CLS
        dex
        beq ?ver                     ; 2 = VER
        dex
        beq ?dir                     ; 3 = DIR
        ldx #CON_T_BAD
        jsr con_str
?done   jsr con_nl                   ; the command's line done, and the
        jsr con_nl                   ;   blank one COMMAND.COM puts before
        jmp ?pr                      ;   its prompt
?ver    jsr con_nl                   ; VER opens with a blank line itself
        ldx #CON_T_VER
        jsr con_str
        bra ?done
?cls    jsr con_cls
        jmp ?pr
?dir    lda #9                       ; con_s9
        sta con_next
        jsr con_msg
        bra ?done
?doom   rts
.endp

;--------------------------------------------------------------
; con_find -- the typed line's first word -> A = its con_cmds number
;   (0 DOOM, 1 CLS, 2 VER, 3 DIR) or $FF. DOS takes anything after a space as the
;   arguments, so "DOOM -WARP 1 1" is still DOOM.
;--------------------------------------------------------------
.proc con_find
        ldx #0
        stz con_ci
?ent    ldy #0
?ch     lda.l B1CODE_BASE+con_cmds,x
        beq ?end                     ; the name ended: so must the word
        cmp #$FF
        beq ?none
        cpy con_ln
        bcs ?skip                    ; the line ran out first
        cmp con_lb,y
        bne ?skip
        inx
        iny
        bra ?ch
?end    cpy con_ln
        beq ?hit
        lda con_lb,y
        cmp #' '
        beq ?hit
?skip   lda.l B1CODE_BASE+con_cmds,x ; on to this name's 0 ...
        beq ?nx
        inx
        bra ?skip
?nx     inx                          ; ... and the next name
        inc con_ci
        bra ?ent
?hit    lda con_ci
        rts
?none   lda #$FF
        rts
.endp

;--------------------------------------------------------------
; con_str -- X = offset into con_txt: print up to its 0.
;--------------------------------------------------------------
.proc con_str
?lp     lda.l B1CODE_BASE+con_txt,x
        beq ?r
        phx                          ; con_putc clobbers X
        jsr con_putc
        plx
        inx
        bra ?lp
?r      rts
.endp

;--------------------------------------------------------------
; con_nl -- CR LF: column 0 of the next row, and on the last row the whole
;   map scrolls up one instead (the DOS screen's own scroll).
;--------------------------------------------------------------
.proc con_nl
        stz con_cx
        lda con_cy
        cmp #CON_H-1
        bcs ?sc
        inc con_cy
        rts
?sc     pei (zp_ptr)                 ; con_msg walks its string with zp_ptr
        lda #BANK_EN|[CON_MAP>>12]
        sta VBXE_BANK_SEL
        ldx #CON_H-1
        rep #$20                     ; the whole scroll in words: zp_ptr = the
        .LONGA ON                    ;   row, zp_tmp = the one below
        sec
        lda #MEMW16+[CON_MAP&$3FFF]
?row    sta zp_ptr
        adc #CON_W*2-1               ; C = 1 here: the sec, then every cpy exit
        sta zp_tmp
        ldy #0
?cp     lda (zp_tmp),y
        sta (zp_ptr),y
        iny
        iny
        cpy #CON_W*2
        bne ?cp                      ; (leaves C = 1 for the adc above)
        lda zp_tmp
        dex
        bne ?row
        sta zp_ptr                   ; the new last row: blank, char 0 on attr 0
        lda #0                       ;   (Y = CON_W*2 from the copy, counted down)
?cl     dey
        dey
        sta (zp_ptr),y
        bne ?cl                      ; (Z from the dey: sta leaves it)
        pla
        sta zp_ptr
        .LONGA OFF
        sep #$20
        lda #BANK_EN|BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp

;--------------------------------------------------------------
; con_cls -- CLS: the map blank, the cursor home.
;--------------------------------------------------------------
.proc con_cls
        lda #BANK_EN|[CON_MAP>>12]
        sta VBXE_BANK_SEL
        lda #<[MEMW16+[CON_MAP&$3FFF]]
        sta zp_ptr
        lda #>[MEMW16+[CON_MAP&$3FFF]]
        sta zp_ptr+1
        ldx #[[CON_H*CON_W*2+255]/256]
        ldy #0
        tya
?clr    sta (zp_ptr),y
        iny
        bne ?clr
        inc zp_ptr+1
        dex
        bne ?clr
        stz con_cx
        stz con_cy
        lda #BANK_EN|BANK_OVERHEAD
        sta VBXE_BANK_SEL
        rts
.endp

; COMMAND.COM's words ($5C = the backslash), and its commands (con_find)
con_txt
CON_T_PR  equ *-con_txt
        dta c'C:', $5C, c'DOOM>', 0
CON_T_BAD equ *-con_txt
        dta c'Bad command or file name', 0
CON_T_VER equ *-con_txt
        dta c'MS-DOS Version 6.22', 0
con_cmds dta c'DOOM', 0, c'CLS', 0, c'VER', 0, c'DIR', 0, $FF
; hardware key code (bits 0-5) -> ASCII, CAPS on as the Atari boots; 0 = not
;   a key DOS prints
con_kmap dta c'LJ;', 0, 0, c'K+*O', 0, c'PU', 0, c'I-='
        dta c'V', 0, c'C', 0, 0, c'BXZ4', 0, c'36', 0, c'521'
        dta c', .N', 0, c'M/', 0, c'R', 0, c'EY', 0, c'TWQ'
        dta c'9', 0, c'07', 0, c'8<>FHD', 0, 0, c'GSA'
    .if * - con_kmap <> 64
        ert 'con_kmap must cover all 64 key codes'
    .endif
; ENDOOM's CGA colours: attr $88+n inks in entry 8+n, papers in $88+n
con_epal dta $09, $FF, $FF, $55      ; $01: yellow ...
        dta $89, $AA, $00, $00       ;   ... on red
        dta $0A, $FF, $FF, $FF       ; $02: white on red
        dta $8A, $AA, $00, $00
        dta $0B, $FF, $FF, $55       ; $03: yellow on blue ("id")
        dta $8B, $00, $00, $AA
        dta $0C, $55, $FF, $FF       ; $04: cyan on red
        dta $8C, $AA, $00, $00
        dta $0D, $AA, $00, $00       ; $05: red on black (row 0's half blocks)
        dta $8D, $00, $00, $00
CON_EPALN equ * - con_epal

con_end_w1 jsr con_end               ; savegame.asm sg_quit jsl's it
        rtl
con_init_w1 jsr con_init             ; the bank-0 boot code jsl's these
        rtl
con_msg_w1 jsr con_msg
        rtl
con_off_w1 jsr con_off
        rtl
        .endseg

    .if CON_XDL+[CON_H+1]*8+4 > CON_FONT
        ert 'the console XDL runs into its font'
    .endif
