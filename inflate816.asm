;--------------------------------------------------------------
; inflate816.asm -- DEFLATE depacker for the packed boot streams (2026-09-26).
;   Piotr Fusik's 6502 "inflate" (zlib6502, zlib license), bent to this engine
;   three ways:
;     input  -- pulled off the ATR: TEX_STAGE holds 1 KB and read_sectors
;               refills it (ll_sec walks on; the caller only seeds it);
;     output -- a 24-bit cursor, sta [inf_out],y with Y = 0 PINNED, so one
;               stream crosses any number of 64 KB banks (SRAM or SDRAM);
;     window -- the 32 KB back-references subtract on the full 24 bits
;               (inf_src = inf_out - distance), so they follow the output
;               across bank lines too. [dp],y with Y = 0 is the same opcode
;               pair read_ext already runs, in the sim and on iron.
;   Call: ll_sec = the stream's first ATR sector, inf_out(3) = destination,
;   jsr inflate. Returns Y = 0. Clobbers A/X, m_a + the DCB (read_sectors),
;   and inf_dat. The stream ends itself (BFINAL): no length argument, and up
;   to 1 KB of the NEXT region may be prefetched into TEX_STAGE -- harmless,
;   every loader re-seeds ll_sec.
;   BOOT ONLY (menu_boot's stream window): inf_dat below is load-time
;   scratch in the $561C-$5BC4 free hole (tools/ram_map.py). $B000 was the
;   first pick and is NOT free -- sprites.asm code lives there (2026-09-26's
;   half-garbage menu: the depack ate the sprite pipeline's first pages).
;--------------------------------------------------------------

; the two 24-bit cursors need DIRECT PAGE; zero page is full, so they alias
; render-only cells exactly as mus_p does (music.asm): zp_sptr/zp_vptr are
; re-seeded by init_level/spr_draw, which first run AFTER the last inflate.
inf_out equ zp_sptr                  ; 3 B: 24-bit output cursor
inf_src equ zp_vptr                  ; 3 B: 24-bit back-reference cursor
inf_in  equ zp_nodeptr               ; 2 B: input cursor inside TEX_STAGE
                                     ;   (+2 = calc_nodeptr's, untouched)
inf_bitbuf equ zp_xa                 ; 1 B: getBit's shift register -- hammered
                                     ;   once per stream BIT, so it rides a
                                     ;   render-only zp byte (screen column
                                     ;   scratch, rebuilt every frame)
inf_base equ zp_xb                   ; 1 B: getBits partial / extra-bits base
                                     ;   (same argument -- zp_xa's pair)
; (A 512-slot fast-decode table for the primary tree lived here for an
;  evening, 2026-09-26, and MEASURED 53 % SLOWER on E2M1: the reservoir it
;  needed made the bit-serial distance tree and extra bits dearer than the
;  literal lookups saved. Reverted whole -- measured as a loss.)

INF_TREE     equ 16                  ; TREE_SIZE: one Huffman tree's slots
INF_PRIT     equ 0                   ; PRIMARY_TREE
INF_DIST     equ INF_TREE            ; DISTANCE_TREE
INF_LSYM     equ 1+29+2              ; LENGTH_SYMBOLS
INF_CSYM     equ INF_LSYM+30         ; CONTROL_SYMBOLS (+DISTANCE_SYMBOLS)

; getBits arguments: bit 7 set stops the ror-loop after 1..7 pulls
INF_G1  equ $81
INF_G2  equ $82
INF_G3  equ $84
INF_G4  equ $88
INF_G5  equ $90
INF_G7  equ $C0

; --- the 764 B tree scratch + state. The RELATIVE layout is load-bearing
;     (the -1/+16/-$100 index tricks), a straight copy of zlib6502's
;     inflate_data.
inf_dat    equ $5620                 ; the ram_map free hole, load-time only
inf_litlen equ inf_dat               ; literal symbol code lengths (256)
inf_ctllen equ inf_dat+256           ; control symbol code lengths (INF_CSYM)
inf_clear  equ inf_ctllen+INF_CSYM   ; the 256-byte clear starts here
inf_tcnt   equ inf_clear             ; codes of each length, both trees (2x16)
inf_lcnt   equ inf_tcnt+2*INF_TREE   ; ... literal codes (16)
inf_ccnt   equ inf_lcnt+INF_TREE     ; ... control codes, both trees (2x16)
inf_loff   equ inf_ccnt+2*INF_TREE   ; sorted-symbol offsets, literal (16)
inf_coff   equ inf_loff+INF_TREE     ; ... control, both trees (2x16)
inf_c2lit  equ inf_coff+2*INF_TREE   ; code -> literal symbol (256)
inf_c2ctl  equ inf_c2lit+256         ; code -> control symbol (INF_CSYM)
; state, right behind the tables (inf_bitbuf + inf_base sit in zp, above)
inf_len    equ inf_c2ctl+INF_CSYM    ; sequence length - 2
inf_sym    equ inf_len+1             ; dynamic block: current symbol
inf_last   equ inf_sym+1             ; dynamic block: last code length
inf_tmpc   equ inf_last+1            ; dynamic block: temp code count   } the
inf_allc   equ inf_tmpc+1            ; ... all codes                    } header
inf_pric   equ inf_allc+1            ; ... primary codes                } loop
                                     ;   writes these three ,x-1: KEEP ADJACENT
inf_pgc    equ inf_pric+1            ; stored block: page counter
inf_end    equ inf_pgc+1
    .if inf_end > $5940
        ert 'inflate scratch runs into the lvl_pak directory at $5940 (diskio.asm)'
    .endif
    .if [TEX_STAGE&$3FF] <> 0
        ert 'inf_inbyte refills on the KB line: TEX_STAGE must be 1 KB-aligned'
    .endif

        .segment B1                  ; like every loader: SIOV-era code
.proc inflate
        ldy #0                       ; Y = 0 is the routine-wide invariant:
        sty inf_bitbuf               ;   every [dp],y and (dp),y below rides it
        jsr ?ifill                   ; the first KB in, cursor at its start:
                                     ;   ?gbfill re-fills on the page-wrap path
                                     ;   and needs a valid buffer from byte one
?block                               ; --- per block: 1 bit EOF + 2 bits type
        sty inf_base
        lda #INF_G3
        jsr ?getbits
        lsr @
        php                          ; C = the EOF bit, parked
        bne ?packed
        ; --- stored block: length, then raw bytes
        sty inf_bitbuf               ; drop bits up to the byte line
        jsr ?getword                 ; LEN, dropped (NLEN is enough)
        jsr ?getword                 ; NLEN: X = low, A = high (one's compl.)
        sta inf_pgc
        bcs ?st1                     ; C = 1 out of ?getword's ror: always
?stcp   jsr ?getbyte
        jsr ?store
?st1    inx                          ; count the complement UP to $0000
        bne ?stcp
        inc inf_pgc
        bne ?stcp
?next   plp                          ; the parked EOF bit
        bcc ?block
        rts

; --- a compressed block: A = 1 fixed, 2 dynamic (3 invalid, not handled)
?packed eor #2
?fxlen  tax                          ; A = 0 while dynamic: lengths stay clear
        beq ?fxlit
        lda #4                       ; fixed literal lengths: 144 x 8, 112 x 9
        cpy #144
        rol @
?fxlit  sta inf_litlen,y
        beq ?fxctl
        lda #5+INF_DIST              ; fixed control: 24 x 7, 8 x 8, 30 x 5+D
        cpy #INF_LSYM
        bcs ?fxctl
        cpy #24
        adc #[2-INF_DIST]&$FF        ; -14 + the y>=24 carry: 21 -> 7 or 8
?fxctl  cpy #INF_CSYM
        bcs ?fxsk                    ; y past the control array: keep going,
        sta inf_ctllen,y             ;   the literal array is the full page
?fxsk   iny
        bne ?fxlen
        tax                          ; A stayed 0 the whole dynamic sweep;
        jne ?codes                   ;   fixed left the last control length

; --- dynamic block: read the code-length code lengths, then the real ones
        ldx #3                       ; header: 5+5+4 bits -> pric/allc/tmpc
?hdr    lda inf_hbits-1,x            ;   (C = 1 out of ?getbits: the +1 rides
        jsr ?getbits                 ;   into the base, wanted -- 257/1/4)
        adc inf_hbase-1,x
        sta inf_tmpc-1,x             ; x = 3,2,1 -> pric, allc, tmpc: ADJACENT
        dex
        bne ?hdr
?tmpl   lda #INF_G3                  ; temp code lengths, permuted order
        jsr ?getbits
        ldy inf_tsym,x
        sta inf_litlen,y
        ldy #0
        inx
        cpx inf_tmpc
        bcc ?tmpl
        jsr ?tree                    ; the temp tree
;       ldx #0  -- ?tree returns X undefined? no: falls out of ?asgn with X..
        ; C = 1 into the first pass: literal lengths first
?dynl   stx inf_sym                  ; C = 1 literal codes, C = 0 control codes
        php
        jsr ?prim                    ; one temp code
        bpl ?verb                    ; 0..15: a verbatim length
        tax                          ; 16/17/18: a repeat (getBits arg rides X)
        jsr ?getbits
        cpx #INF_G3
        bcc ?rep                     ; 16: repeat the LAST length 3+bits(2)
        beq ?z17                     ; 17: zero length 3+bits(3)
        adc #7                       ; 18: zero length 11+bits(7) (C = 1: +8)
?z17    sty inf_last                 ; 17/18 repeat a ZERO length
?rep    tay
        lda inf_last
        iny
        iny
?verb   iny
        plp
        ldx inf_sym
?dstore bcc ?dctl
        sta inf_litlen,x             ; the literal pass
        inx
        cpx #1
?dnext  dey
        bne ?dstore
        sta inf_last
        jeq ?dynl                    ; Z = 1 out of ?dnext's bne: always
?dctl   cpx inf_pric                 ; the control pass
        bcc ?dsctl
        bne ?dskip                   ; past primaryCodes: skip to the distance
        ldx #INF_LSYM                ;   codes (their lengths stayed zero)
?dskip  ora #INF_DIST
?dsctl  sta inf_ctllen,x
        inx
        cpx inf_allc
        bcc ?dnext
        dey

; --- decompress with the trees in place
?codes  jsr ?tree
        beq ?loop                    ; Z = 1 out of ?tree: always
?lit    sta [inf_out],y              ; a literal: the store INLINE (2026-09-26)
        inc inf_out
        bne ?loop
        inc inf_out+1
        bne ?loop
        inc inf_out+2
?loop   ldx #INF_PRIT                ; the PRIMARY fetch, a second copy INLINE
        tya                          ;   (2026-09-26): one jsr/rts+bcc per
?mbit   lsr inf_bitbuf               ;   SYMBOL gone; ?fetch stays for the
        bne ?mbc                     ;   header and distance paths. Body =
        jsr ?gbfill                  ;   ?fetch line for line, only the two
?mbc    rol @                        ;   exits BRANCH instead of returning.
        inx
        sec
        sbc inf_tcnt,x
        bcs ?mbit
        adc inf_ccnt,x               ; C = 0 (bcs fell through)
        bcs ?mctl
        adc inf_loff,x               ; C = 0 (bcs fell through)
        tax
        lda inf_c2lit,x
        bra ?lit                     ; a literal byte -> store, next symbol
?mctl   adc inf_coff-1,x             ; C = 1 (bcs taken)
        tax
        lda inf_c2ctl-1,x
        and #$1f                     ; A = X = control symbol, Z on 256
        tax
        jeq ?next                    ; end of block
        ; length symbol: 3..258 = the coded base + extra bits
        sty inf_base
        cmp #9
        bcc ?slen
        tya                          ; A = 0
        cpx #1+28
        bcs ?slen                    ; symbol 285: length 258, no extra bits
        dex
        txa
        lsr @
        ror inf_base
        inc inf_base
        lsr @
        rol inf_base
        jsr ?gnb1
        adc #0                       ; C = 1 out of ?gnb1's ror loop
?slen   sta inf_len                  ; = length - 2
        ldx #INF_DIST
        jsr ?fetch                   ; the distance symbol -> A (= X)
        cmp #4
        bcc ?dlo                     ; 0..3: distance 1..4, no extra bits
        inc inf_base
        lsr @
        jsr ?gnb1                    ; low extra bits -> A, high -> inf_base
?dlo    eor #$ff                     ; A = ~dLo, parked while dHi arrives
        sta inf_src
        lda inf_base
        cpx #10
        bcc ?dhi                     ; C = 0 (bcc) ...
        lda inf_nmask-10,x
        jsr ?getbits
        clc                          ; ... = 0 here too
?dhi    eor #$ff                     ; A = ~dHi
        ; inf_src = inf_out - distance on the FULL 24 bits: distance - 1 = d,
        ; so out + ~d (sign byte $FF) is exactly out - distance. This replaces
        ; zlib6502's Y-carries-the-low-byte trick, which cannot cross banks.
        tax                          ; ~dHi parked (X is dead until ?prim)
        lda inf_src                  ; ~dLo
        clc
        adc inf_out
        sta inf_src
        txa
        adc inf_out+1
        sta inf_src+1
        lda #$ff                     ; ~d's sign byte: d < 65536
        adc inf_out+2
        sta inf_src+2
        ; --- the match copy. Y WALKS, the pointers stand still (2026-09-26):
        ; [dp],y carries the full 24 bits, so ptr+Y crosses banks by itself
        ; and both cursors advance ONCE at the end -- ~21 cyc/B against ~37
        ; for per-byte 24-bit incs. Bytes still land one at a time in file
        ; order, so a distance < length match (RLE) reads what it just wrote.
        ; Length = inf_len + 2, inf_len 1..256 ($00 = 256): 257/258 cannot
        ; ride an 8-bit Y, and only a maximal match hits them -- ?cslow.
        ldx inf_len
        beq ?cslow                   ; length 258
        cpx #255
        beq ?cslow                   ; length 257
        ldy #0
?cpb    lda [inf_src],y
        sta [inf_out],y
        iny
        dex
        bne ?cpb
        lda [inf_src],y              ; the +2 tail (Y = len-2, len-1 <= 255)
        sta [inf_out],y
        iny
        lda [inf_src],y
        sta [inf_out],y
        iny                          ; Y = length; $00 when length = 256
        tya
        beq ?c256
        clc                          ; both cursors += length
        adc inf_out
        sta inf_out
        bcc ?c1
        inc inf_out+1
        bne ?c1
        inc inf_out+2
?c1     tya
        clc
        adc inf_src
        sta inf_src
        bcc ?c2
        inc inf_src+1
        bne ?c2
        inc inf_src+2
?c2     ldy #0                       ; the routine-wide invariant, back on
        jmp ?loop
?c256   inc inf_out+1                ; += 256 is one mid-byte step
        bne ?c3
        inc inf_out+2
?c3     inc inf_src+1
        bne ?c2
        inc inf_src+2
        bra ?c2
?cslow  jsr ?copy                    ; the rare 257/258: byte-serial, as the
        jsr ?copy                    ;   2026-09-25 depacker always did
?csb    jsr ?copy
        dec inf_len
        bne ?csb
        jeq ?loop                    ; Z = 1: always

; --- build both Huffman trees from the *len arrays -----------------------
?tree   tya                          ; A = 0, and clear counts + offsets
?clr    sta inf_clear,y              ;   (256 B: the tail overlaps inf_c2lit,
        iny                          ;   rebuilt below anyway)
        bne ?clr
?cnt    ldx inf_litlen,y             ; count codes of each length
        inc inf_lcnt,x
        inc inf_tcnt,x
        cpy #INF_CSYM
        bcs ?cnt1
        ldx inf_ctllen,y
        inc inf_ccnt,x
        inc inf_tcnt,x
?cnt1   iny
        bne ?cnt
        ; offsets = prefix sums: the 48 count bytes sit right before the
        ; 48 offset bytes, so one -$100-biased X walks both (zlib6502 as-is)
        ldx #256-3*INF_TREE
?offs   sta inf_loff+3*INF_TREE-$100,x
        clc
        adc inf_lcnt+3*INF_TREE-$100,x
        inx
        bne ?offs
?asgn   tya                          ; place each symbol by its code length
        ldx inf_litlen,y
        ldy inf_loff,x
        inc inf_loff,x
        sta inf_c2lit,y
        tay
        cpy #INF_CSYM
        bcs ?asgn1
        ldx inf_ctllen,y
        ldy inf_coff,x
        inc inf_coff,x
        sta inf_c2ctl,y
        tay
?asgn1  iny
        bne ?asgn
        rts                          ; Z = 1 (the bne above): ?codes leans on it


; --- fetch one code ------------------------------------------------------
?prim   ldx #INF_PRIT
?fetch  tya                          ; walk the canonical code, length by
?fbit   lsr inf_bitbuf               ;   length (X = tree base). getBit sits
        bne ?fbc                     ;   INLINE here (2026-09-26): this loop
        jsr ?gbfill                  ;   runs once per BIT of the stream, and
?fbc    rol @                        ;   the jsr/rts pair was a third of it
        inx
        sec
        sbc inf_tcnt,x
        bcs ?fbit
        adc inf_ccnt,x               ; C = 0 (bcs fell through)
        bcs ?fctl
        adc inf_loff,x               ; C = 0 (bcs fell through)
        tax
        lda inf_c2lit,x
        clc                          ; C = 0: a literal
        rts
?fctl   adc inf_coff-1,x             ; C = 1 (bcs taken)
        tax
        lda inf_c2ctl-1,x
        and #$1f                     ; distance symbols zero-based
        tax
        sec                          ; C = 1: a control code, A = X = symbol
        rts

; --- bit plumbing --------------------------------------------------------
?gnb1   rol inf_base                 ; read A-1 bits (at most 8)
        tax
        cmp #9
        bcs ?getbyte
        lda inf_nmask-2,x
?getbits
        jsr ?gbloop
?gbnorm lsr inf_base                 ; align: exits with C = 1 (the marker)
        ror @
        bcc ?gbnorm
        rts
?getword
        jsr ?getbyte                 ; -> X = low byte, A = high
        tax
?getbyte
        lda #$80                     ; the marker bit: 8 pulls, C = 1 out
?gbloop lsr inf_bitbuf               ; getBit inline, as in ?fbit
        bne ?gbc
        jsr ?gbfill
?gbc    ror @
        bcc ?gbloop
        rts
?gbfill pha                          ; the 1-in-8 slow half of getBit: pull a
        lda (inf_in),y               ;   stream byte (Y = 0) -- the old jsr'd
        inc inf_in                   ;   reader merged in (2026-09-26), and the
        beq ?gnp                     ;   buffer check rides the page-wrap path
?gret   sec                          ;   (1 in 256): the cursor is valid here
        ror @                        ;   by construction. C = the byte's bit 0,
        sta inf_bitbuf               ;   buffer = the other seven + the marker.
        pla
        rts
?gnp    inc inf_in+1                 ; page wrap: past the buffer's end?
        pha                          ; the stream byte, across a refill
        lda inf_in+1
        cmp #>[TEX_STAGE+1024]
        bne ?gnr
        jsr ?ifill                   ; the NEXT byte's KB, cursor reset
?gnr    pla
        bra ?gret

; --- the streaming input: TEX_STAGE, refilled a KB at a time. The check
;     sits on ?gbfill's page-wrap path: the entry and every refill leave
;     the cursor on a valid byte.
?ifill  phx                          ; X = the Huffman walk, live
        lda #<TEX_STAGE
        sta DBUFLO
        sta inf_in                   ; (<TEX_STAGE -- the address low byte)
        lda #>TEX_STAGE
        sta DBUFHI
        sta inf_in+1
        lda #8
        sta ll_cnt
        stz ll_cnt+1
        jsr read_sectors             ; advances ll_sec; clobbers A/X/Y, m_a
        jsr con_tick                 ; one KB pulled: the startup console's
        plx                          ;   R_Init dot ticker (console.asm)
        ldy #0                       ; the routine-wide invariant, back on
        rts

; --- the two byte sinks: full 24-bit cursors, Y = 0 ----------------------
?copy   lda [inf_src],y              ; one byte of the back-window
        inc inf_src
        bne ?store
        inc inf_src+1
        bne ?store
        inc inf_src+2
?store  sta [inf_out],y              ; write + advance the output cursor
        inc inf_out
        bne ?sret
        inc inf_out+1
        bne ?sret
        inc inf_out+2
?sret   rts
.endp
inflate_w1 jsr inflate               ; bank-0 callers (menu_boot's map-slot
        rtl                          ;   half) jsl B1CODE_BASE+inflate_w1
        .endseg

        .segment D0                  ; constants: DBR = 0 data, like pre_slo
inf_nmask dta INF_G1,INF_G2,INF_G3,INF_G4,INF_G5,$A0,INF_G7
inf_tsym  dta INF_G2,INF_G3,INF_G7,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15
inf_hbits dta INF_G4,INF_G5,INF_G5
inf_hbase dta 3,INF_LSYM,0
        .endseg
