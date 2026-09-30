;--------------------------------------------------------------
; inflate816.asm -- DEFLATE depacker for the packed streams of the ATR.
;   Call: ll_sec = the stream's first sector, inf_out(3) = destination,
;   jsr inflate (native, 8-bit A/X/Y). Returns Y = 0, inf_out behind the
;   last byte. Clobbers A/X, the DCB, TEX_STAGE and the cells below. The
;   stream ends itself (BFINAL); one sector of the next region may be
;   prefetched -- every loader re-seeds ll_sec. The sectors come straight
;   off the drive: no stream sits in the SDRAM cache's ranges (pre_map),
;   make_atr_doom.py keeps them below LVL_SEC1.
;
;   A symbol is ONE table read: the stream's next 8 bits index INF_LT/LV
;   (literal/length), the next 7 INF_DT/DS (distance). The bit offset k
;   inside the input byte is not a variable: the decoders exist once per
;   k (sym, dis, ext, lgx 0-7) and a table entry picks the code that
;   stores, steps the input and enters the next decoder. A literal/length
;   code of 9 or 10 bits takes a second read (INF_T2/V2); longer ones
;   walk the canonical counts bit by bit (?walk).
;   Distance symbols 30 and 31 are FAR matches (tools/deflate_far.py):
;   32769 + 16 extra bits, 98305 + 21 -- back through the whole output.
;--------------------------------------------------------------

; --- zero page: the renderer's per-seg working set, rebuilt every frame
inf_zp  equ zp_rx
inf_k2  equ inf_zp                   ; 1 B: bit offset x 2 (generic code only)
inf_j   equ inf_zp+1                 ; 1 B: a count
inf_ws  equ inf_zp+2                 ; 2 B: ?walk's state
inf_r   equ inf_zp+4                 ; 2 B: ?walk's bits / a parked word
inf_p   equ inf_zp+6                 ; 3 B: -> code lengths
inf_n   equ inf_zp+9                 ; 2 B: a count
inf_q   equ inf_zp+11                ; 2 B: the code set, 0 or 32
inf_sy  equ inf_zp+13                ; 2 B: a page's first symbol
inf_wx  equ inf_zp+15                ; 1 B: ?walk's length index
inf_len equ zp_xa                    ; 1 B: match length (256..258: - 256)
inf_t   equ zp_xb                    ; 1 B: inf_xd's index across the copy
inf_out equ zp_sptr                  ; 3 B: output cursor
inf_src equ zp_vptr                  ; 3 B: match source
inf_in  equ zp_nodeptr               ; 2 B: input cursor (+2 is calc_nodeptr's)
inf_s   equ rs_yfacc                 ; 3 B: -> symbols in code order
inf_fin equ rs_yfacc+3               ; 1 B: bit 7 = the last block
inf_c   equ rs_ybcacc                ; 1 B: a code, left-aligned in 8 bits
inf_bl  equ rs_ybcacc+1              ; 1 B: a code length
inf_m   equ rs_ybcacc+2              ; 1 B: table entries to write
inf_fs  equ rs_ybcacc+3              ; 1 B: 1 << length: entry step
inf_v   equ rs_t2                    ; 1 B: an entry's value
inf_em  equ rs_t2+1                  ; 1 B: mask of the folded extra bits
inf_cl  equ rs_t2+2                  ; 1 B: the first pattern of a longer code
inf_tv  equ rs_t2+3                  ; 1 B: an entry's dispatch code
inf_p2  equ cx_a                     ; 3 B: -> INF_T2's page
inf_s2  equ cx_a+3                   ; 3 B: -> INF_V2's page
inf_bg  equ cx_a+6                   ; 1 B: bit 7 = a match of 256..258 bytes
    .if zp_xa-zp_rx <> 16
        ert 'inflate: zp_rx..rs_ycacc are 16 B in a row (bsp_main.asm)'
    .endif
    .if cx_d-cx_a <> 6
        ert 'inflate: cx_a..cx_d are 8 B in a row (bsp_main.asm)'
    .endif

; --- TEX_STAGE: the input sector behind the 3 bytes kept from the last
;     one, and the decode tables -- bank 0 (abs,y), writes fast, no read
;     crosses a page
INF_DT   equ TEX_STAGE               ; 128 B distance / code-length code:
                                     ;   (length-1) << 5, $E0 = ?walk
INF_BUF  equ TEX_STAGE+$80
INF_RD   equ INF_BUF+3               ; read_sectors' target
INF_TOP  equ TEX_STAGE+$100          ; inf_in crossing INTO this page refills
INF_DS   equ INF_TOP+3               ; 128 B: ... and its symbol x 2
INF_NX   equ INF_DS+128              ; 16 B: each length's next code
INF_LT   equ TEX_STAGE+$200          ; literal/length: inf_sd index - 2k
INF_LV   equ TEX_STAGE+$300          ;   ... and the value
    .if [<INF_TOP] || [<INF_LT] || INF_NX+16 > INF_LT
        ert 'inflate: TEX_STAGE layout'
    .endif

; --- the symbols' constants, a copy in bank 0 (abs,x): inf_kst's layout
INF_K    equ $5620                   ; load-time scratch (tools/ram_map.py)
INF_KDMK  equ INF_K                   ; distance symbol x 2: the extra bits' mask
INF_KDNB  equ INF_K+64                ;   ... - base
INF_KDX2  equ INF_K+128               ;   ... 2 x extra bits
INF_KLEM  equ INF_K+192               ; length symbol: the extra bits' mask
INF_KLB3  equ INF_K+224               ;   ... base - 3
INF_KLX2  equ INF_K+256               ;   ... 2 x extra bits
INF_KLEN equ 288
    .if INF_K+INF_KLEN > LVPTAB_BASE || [[INF_KLEM+31]^INF_KLEM] > 255
        ert 'inflate: the constants run into the lvl_pak directory / over a page'
    .endif

; --- bank $01 below the code segment (long,x / [dp],y): the build scratch
;     at INF_X (memory_map.inc)
INF_CLN  equ INF_X                   ; 320 B: code lengths, as the header has them
INF_DLN  equ INF_X+$0140             ; 32 B: the distance code's
INF_TLN  equ INF_X+$0160             ; 32 B: the code-length code's
INF_CNT  equ INF_X+$0180             ; 2 x 16 words: codes of each length
INF_PTR  equ INF_X+$01C0             ; 2 x 16 words: -> a length's first symbol
INF_RUN  equ INF_X+$0200             ; 2 x 16 words: ... while they are placed
INF_HL   equ INF_X+$0240             ; HLIT
INF_HD   equ INF_X+$0241             ; HDIST
INF_LAST equ INF_X+$0242             ; the last code length
INF_TK   equ INF_X+$0243             ; sectors towards con_tick's KB
INF_SRT  equ INF_X+$0280             ; 288 + 32 words: the symbols ?walk reads
INF_SRTD equ INF_SRT+2*288
; ... and the 9/10-bit codes at INF_T2: 4 pages of inf_sd index - 2k, one
;     per value of the code's bits 8-9, indexed by ?walk's state behind its
;     first 8; the values 4 pages on
INF_V2   equ INF_T2+$400
    .if [INF_SRTD&$FFFF]+64 > [INF_X&$FFFF]+INF_XLEN || [INF_X&$FFFF]+INF_XLEN > [INF_T2&$FFFF]
        ert 'inflate: the build scratch outgrew INF_XLEN (memory_map.inc)'
    .endif
    .if [[>INF_T2]&7] || [INF_T2&$FFFF]+INF_T2LEN > B1SEG_BASE
        ert 'inflate: INF_T2 is 8 pages from a page whose low 3 bits are clear'
    .endif

; inf_sd's rows: +2t a literal, 32+2t a length with its extra bits (t = k +
;   the bits used), 64+2t a length, the extra bits to come, then by k:
INF_TPEND equ 64
INF_TLONG equ 96                     ; a code past 8 bits
INF_TEOB  equ 128                    ; end of block
INF_TLNG2 equ 160                    ; a code past 10 bits

        .segment B1
.proc inflate
        lda #INF_X>>16
        sta inf_p+2
        sta inf_s+2
        sta inf_p2+2
        sta inf_s2+2
        stz inf_p2
        stz inf_s2
        stz inf_bg
        lda inf_out+2
        sta inf_src+2
        lda #0
        sta.l INF_TK
        stz inf_k2
        ldx #0                       ; the constants into bank 0
?kst    lda.l B1CODE_BASE+inf_kst,x
        sta INF_K,x
        inx
        bne ?kst
        ldx #INF_KLEN-256
?ks2    lda.l B1CODE_BASE+inf_kst+255,x
        sta INF_K+255,x
        dex
        bne ?ks2
        ldx #11                      ; the DCB: D1:, read 128 B to INF_RD.
?dcb    lda.l B1CODE_BASE+inf_dcb,x  ;   SIOV changes DSTATS alone
        sta DDEVIC,x
        dex
        bpl ?dcb
        lda #<INF_RD
        sta inf_in
        lda #>INF_RD
        sta inf_in+1
        jsr ?rdsec

; --- a block: 1 bit last, 2 bits type
?block  lda #3
        jsr ?gbits
        lsr @
        tay                          ; the type
        lda #0
        ror @
        sta inf_fin
        dey
        bmi ?stor
        bne ?dyn
        ldx #0                       ; fixed: 144 x 8, 112 x 9, 24 x 7, 8 x 8
?fx1    lda #8
        cpx #144
        adc #0
        sta.l INF_CLN,x
        inx
        bne ?fx1
        ldx #31
?fx2    lda #7
        cpx #24
        adc #0
        sta.l INF_CLN+256,x
        lda #5
        sta.l INF_DLN,x
        dex
        bpl ?fx2
        jmp ?mk

; --- stored: to the byte line, LEN, NLEN, the bytes
?stor   lda inf_k2
        beq ?so1
        stz inf_k2
        inc inf_in
        bne ?so1
        jsr ?inpage
?so1    jsr ?gpeek
        .LONGA ON
        sta inf_n
        sep #$20
        .LONGA OFF
        lda #32
        jsr ?gadv
?so2    lda inf_n
        ora inf_n+1
        beq ?eob1
        lda (inf_in)
        sta [inf_out]
        inc inf_out
        bne ?so3
        inc inf_out+1
        bne ?so3
        inc inf_out+2
        inc inf_src+2
?so3    inc inf_in
        bne ?so4
        jsr ?inpage
?so4    lda inf_n
        bne ?so5
        dec inf_n+1
?so5    dec inf_n
        bra ?so2

; --- end of block (A = the code's bits, X = 2k)
?eob    stx inf_k2
        jsr ?gadv
?eob1   lda inf_fin
        jpl ?block
        ldy #0
        rts

; --- dynamic: the code-length code, then both codes' lengths through it
?dyn    lda #5
        jsr ?gbits
        sta.l INF_HL
        lda #5
        jsr ?gbits
        sta.l INF_HD
        lda #4
        jsr ?gbits
        clc
        adc #4
        sta inf_n
        ldx #31
        lda #0
?dy1    sta.l INF_TLN,x
        dex
        bpl ?dy1
        ldy #0
?dy2    lda #3
        jsr ?gbits                   ; (Y kept)
        pha
        tyx
        lda.l B1CODE_BASE+inf_ord,x
        tax
        pla
        sta.l INF_TLN,x
        iny
        cpy inf_n
        bcc ?dy2
        rep #$20
        .LONGA ON
        lda #INF_TLN&$FFFF
        sta inf_p
        sep #$20
        .LONGA OFF
        jsr ?bdt
        lda.l INF_HL                 ; HLIT + HDIST + 258 lengths: the sum is
        clc                          ;   60 at most, so the word is $01xx
        adc.l INF_HD
        adc #2
        sta inf_n
        lda #1
        sta inf_n+1
        rep #$20
        .LONGA ON
        lda #INF_CLN&$FFFF
        sta inf_p
?dy3    jsr ?gpeek                   ; a code-length symbol
        sep #$20
        .LONGA OFF
        and #$7F
        tay
        lda INF_DT,y
        lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        inc @
        jsr ?gadv                    ; (Y kept)
        lda INF_DS,y
        lsr @
        cmp #16
        bcs ?dy4
        sta.l INF_LAST               ; 0..15: a length
        ldy #1
        bra ?dy7
?dy4    bne ?dy5
        lda #2                       ; 16: the last length, 3..6 times
        jsr ?gbits
        clc
        adc #3
        tay
        lda.l INF_LAST
        bra ?dy7
?dy5    lsr @                        ; 17: C = 1, 18: C = 0
        bcs ?dy6
        lda #7                       ; 18: 11..138 zeros
        jsr ?gbits
        clc
        adc #11
        bra ?dy6a
?dy6    lda #3                       ; 17: 3..10 zeros
        jsr ?gbits
        clc
        adc #3
?dy6a   tay
        lda #0
        sta.l INF_LAST
?dy7    sty inf_j                    ; A, Y times
?dy8    dey
        sta [inf_p],y
        bne ?dy8
        lda inf_j
        clc
        adc inf_p
        sta inf_p
        bcc ?dy9
        inc inf_p+1
?dy9    lda inf_n
        sec
        sbc inf_j
        sta inf_n
        bcs ?dy9a
        dec inf_n+1
?dy9a   ora inf_n+1
        bne ?dy3
        ldx #31                      ; the distance lengths out to their own
        lda #0                       ;   array, zeros behind both codes
?dya    sta.l INF_DLN,x
        dex
        bpl ?dya
        rep #$21
        .LONGA ON
        lda.l INF_HL
        and #$00FF
        adc #[INF_CLN&$FFFF]+257
        sta inf_p
        sep #$20
        .LONGA OFF
        lda.l INF_HD
        tay
?dyb    lda [inf_p],y
        tyx
        sta.l INF_DLN,x
        dey
        bpl ?dyb
        ldy #31
        lda #0
?dyc    sta [inf_p],y
        dey
        bpl ?dyc

; --- both codes' tables, then the symbols
?mk     jsr ?bll
        rep #$20
        .LONGA ON
        lda #INF_DLN&$FFFF
        sta inf_p
        sep #$20
        .LONGA OFF
        jsr ?bdt
        ldx inf_k2
        jmp (inf_s8,x)

;==============================================================
; THE DECODERS, once per bit offset k. Entered and left with 8-bit A.
;==============================================================
; literal/length symbol. lit<t> / len<t>: t = k + the code's bits, so
;   t >> 3 input bytes are done and sym/dis<t & 7> is next.
        .rept 8, #, #*2, #+8, 8-#
lit:3   sta [inf_out]
        inc inf_out
        beq loc:3
fin:3   inc inf_in
        beq syc:1
fin:1
    .if :1 = 0
sym:1   lda (inf_in)                 ; on a byte line: the byte is the index
        tay
    .else
sym:1   rep #$20
        .LONGA ON
        lda (inf_in)
    .if :1 > 4
        :+:4 asl @                   ; (from 5 bits on the other way is
        xba                          ;   shorter)
    .else
        :+:1 lsr @
    .endif
        sep #$20
        .LONGA OFF
        tay
    .endif
        ldx INF_LT,y
        lda INF_LV,y
        jmp (inf_sd+:2,x)
    .if :1 > 0
lit:1   sta [inf_out]
        inc inf_out
        bne sym:1
        inc inf_out+1
        bne sym:1
        inc inf_out+2
        inc inf_src+2
        bra sym:1
    .endif
loc:3   inc inf_out+1
        bne fin:3
        inc inf_out+2
        inc inf_src+2
        bra fin:3
syc:1   jsr ?inpage
        bra sym:1
        .endr

; a code of 9 or 10 bits: A = ?walk's state behind its first 8, the two
;   bits behind them pick the page. The entry is one of inf_sd's again.
        .rept 8, #, #*2, #+8, 8-#
lng:1   inc inf_in
        beq lgc:1
lgx:1   tay
    .if :1 = 0
        lda (inf_in)
    .else
        rep #$20
        .LONGA ON
        lda (inf_in)
    .if :1 > 4
        :+:4 asl @                   ; (from 5 bits on the other way is
        xba                          ;   shorter)
    .else
        :+:1 lsr @
    .endif
        sep #$20
        .LONGA OFF
    .endif
        and #3
        ora #>INF_T2
        sta inf_p2+1
        ora #4
        sta inf_s2+1
        lda [inf_p2],y
        tax
        lda [inf_s2],y
        jmp (inf_sd+:2,x)
lgc:1   pha
        jsr ?inpage
        pla
        bra lgx:1
        .endr

; a length whose extra bits are not in the table (A = its symbol): read
;   behind the code, then on to dis<k> by inf_pd
        .rept 8, #, #*2, #+8, 8-#
pnd:3   inc inf_in
        beq pnc:1
pnd:1
pxb:1   tax
    .if :1 = 0
        lda (inf_in)
    .else
        rep #$20
        .LONGA ON
        lda (inf_in)
    .if :1 > 4
        :+:4 asl @                   ; (from 5 bits on the other way is
        xba                          ;   shorter)
    .else
        :+:1 lsr @
    .endif
        sep #$20
        .LONGA OFF
    .endif
        and INF_KLEM,x
        clc
        adc INF_KLB3,x  ; the length - 3
        cmp #253
        bcs pxg:1                    ; 256..258 bytes: generic
        adc #3                       ; C = 0
        sta inf_len
        lda INF_KLX2,x  ; 2 x extra bits
        tax
        jmp (inf_pd+:2,x)
pxg:1   pha
        lda #:2
        sta inf_k2
        lda.l B1CODE_BASE+inf_lxt,x
        jsr ?gadv
        pla
        sec
        jmp ?lbig
pnc:1   pha
        jsr ?inpage
        pla
        bra pxb:1
        .endr

; distance symbol: Y = its table index on to ext<k>
        .rept 8, #, #*2, #+8, 8-#
len:1   sta inf_len
    .if :1 = 0
dis:1   lda (inf_in)
    .else
dis:1   rep #$20
        .LONGA ON
        lda (inf_in)
    .if :1 > 4
        :+:4 asl @                   ; (from 5 bits on the other way is
        xba                          ;   shorter)
    .else
        :+:1 lsr @
    .endif
        sep #$20
        .LONGA OFF
    .endif
        and #$7F
        tay
        ldx INF_DT,y
        jmp (inf_dd+:2,x)
len:3   sta inf_len
dad:3   inc inf_in
        bne dis:1
        jsr ?inpage
        bra dis:1
        .endr

; the distance's extra bits and the source = output - distance, then by
;   inf_xc -- the input on the next symbol -- to the copy. A distance past
;   16 - k bits takes its bits from three bytes (far<k>, k = 4..7 only).
;   inf_src+2 = inf_out+2 between two matches: only a source in the bank
;   below pays for its bank byte (?ebor).
        .rept 8, #, #*2, #+8
    .if :1 < 7
dgo:3   inc inf_in
        beq exc:1
    .endif
dgo:1
ext:1   ldx INF_DS,y
        beq rle:1                    ; distance 1
    .if :1 > 3
        cpx #72-4*:1
        bcs far:1
    .endif
        rep #$20
        .LONGA ON
        lda (inf_in)
        :+:1 lsr @
        and INF_KDMK,x
etl:1   eor #$FFFF
        sec
        adc INF_KDNB,x  ; - distance
        clc
        adc inf_out
        sta inf_src
        sep #$20
        .LONGA OFF
        bcc ebo:1
        lda INF_KDX2,x
        tax
        jmp (inf_xc+:2,x)
rle:1   lda #:2
        jmp ?rle
ebo:1   lda #:2
        jmp ?ebor
    .if :1 > 3
far:1   rep #$20
        .LONGA ON
        ldy #1
        lda (inf_in),y
        :+:1 lsr @
        and.l B1CODE_BASE+inf_dmh,x  ; bits 8+ of the extra bits ...
        xba
        sta inf_r
        lda (inf_in)
        :+:1 lsr @
        and #$00FF                   ; ... over the low 8
        ora inf_r
        bra etl:1
        .LONGA OFF
    .endif
    .if :1 < 7
exc:1   jsr ?inpage                  ; (Y kept)
        bra ext:1
    .endif
        .endr

; the copy: inf_len bytes (3..255), the distance 2 at least. Two matches of
;   three are 3 or 4 bytes long.
        .rept 8, #, #*2, #+8
cps:3   inc inf_in
        beq cpc:1
cps:1
cpy:1   lda inf_len
        cmp #5
        bcc csh:1
        lsr @
        tax                          ; words, C = the odd byte
        ldy #0
        bcc cpe:1
        lda [inf_src]
        sta [inf_out]
        iny
cpe:1   rep #$21
        .LONGA ON
cpw:1   lda [inf_src],y
        sta [inf_out],y
        iny
        iny
        dex
        bne cpw:1
        tya                          ; C = 0
        adc inf_out
        sta inf_out
        sep #$20
        .LONGA OFF
        bcs cpb:1
        jmp sym:1
csh:1   lsr @                        ; 3: C = 1, 4: C = 0
        rep #$20
        .LONGA ON
        lda [inf_src]
        sta [inf_out]
        ldy #2
        bcs cpt:1
        lda [inf_src],y
        sta [inf_out],y
        lda inf_out
        adc #4                       ; C = 0
        sta inf_out
        sep #$20
        .LONGA OFF
        bcs cpb:1
        jmp sym:1
cpt:1   sep #$20
        lda [inf_src],y
        sta [inf_out],y
        lda inf_out
        adc #2                       ; C = 1: + 3
        sta inf_out
        bcs cpp:1
        jmp sym:1
cpp:1   inc inf_out+1
        beq cpb:1
        jmp sym:1
cpb:1   inc inf_out+2
        inc inf_src+2
        jmp sym:1
cpc:1   jsr ?inpage
        jmp cpy:1
        .endr

; two input bytes done behind a distance (17..20 bits on)
        .rept 5, #+16, #+8
cps:1   inc inf_in
        jne cps:2
        jsr ?inpage
        jmp cps:2
        .endr

; two input bytes done behind a distance (17..20 bits on)
        .rept 5, #+16, #+8
fin:1   inc inf_in
        jne fin:2
        jsr ?inpage
        jmp fin:2
        .endr

;==============================================================
; THE MATCH: source = output - distance, then inf_len bytes
;==============================================================
; the same, generic (?dlong, the source in the bank below, distance 1,
;   256..258 bytes): inf_t = inf_xd's index behind the copy.
; A (16-bit) = the extra bits, X = the distance symbol x 2.
?etl    .LONGA ON
        eor #$FFFF
        sec
        adc INF_KDNB,x  ; - distance
        clc
        adc inf_out
        sta inf_src
        sep #$20
        .LONGA OFF
        bcc ?ebog
?ecpy   lda inf_len                  ; words: the distance is 2 at least
        lsr @
        tax                          ; words, C = the odd byte
        ldy #0
        bcc ?cw0
        lda [inf_src]
        sta [inf_out]
        iny
?cw0    rep #$21
        .LONGA ON
?cw1    lda [inf_src],y
        sta [inf_out],y
        iny
        iny
        dex
        bne ?cw1
?cend   tya                          ; output += the length (C = 0)
        adc inf_out
        sta inf_out
        sep #$20
        .LONGA OFF
        bcs ?cbnk
?cfin   ldx inf_t
        jmp (inf_xd,x)
?cbnk   inc inf_out+2
?csyn   lda inf_out+2
        sta inf_src+2
        bra ?cfin
?ebor   clc                          ; (A = 2k, X = the distance symbol x 2)
        adc INF_KDX2,x
        sta inf_t
?ebog   dec inf_src+2                ; ... and the bank comes back behind
?efar   lda inf_t                    ;   the copy: inf_xd's last entry
        sta inf_wx
        lda #INF_XSYN
        sta inf_t
        bra ?ecpy
?esyn   lda inf_out+2
        sta inf_src+2
        ldx inf_wx
        jmp (inf_xd,x)

; 256..258 bytes (inf_j = the bytes past 256): 128 words, both cursors a
;   page on, the rest
?cbig   ldx #32
        ldy #0
        rep #$20
        .LONGA ON
?cb1    lda [inf_src],y
        sta [inf_out],y
        iny
        iny
        lda [inf_src],y
        sta [inf_out],y
        iny
        iny
        lda [inf_src],y
        sta [inf_out],y
        iny
        iny
        lda [inf_src],y
        sta [inf_out],y
        iny
        iny
        dex
        bne ?cb1
        sep #$20
        .LONGA OFF
?cb2    inc inf_src+1
        bne ?cb3
        inc inf_src+2
?cb3    inc inf_out+1
        bne ?cb4
        inc inf_out+2
?cb4    ldx inf_j                    ; (Y = 0)
        beq ?csyn
?cb5    lda [inf_src],y
        sta [inf_out],y
        iny
        dex
        bne ?cb5
        tya
        clc
        adc inf_out
        sta inf_out
        bcc ?csyn
        inc inf_out+1
        bne ?csyn
        inc inf_out+2
        bra ?csyn

; distance 1 (A = inf_t): the byte behind the cursor, inf_len times
?rle    sta inf_t
        rep #$21
        .LONGA ON
        lda inf_out
        adc #$FFFF
        sta inf_src
        sep #$20
        .LONGA OFF
        bcs ?rl1
        dec inf_src+2                ; the last byte of the bank below
        lda [inf_src]
        inc inf_src+2
        bra ?rl2
?rl1    lda [inf_src]
?rl2    sta inf_r
        sta inf_r+1
        bit inf_bg
        bmi ?rbig
        lda inf_len
        lsr @
        tax
        ldy #0
        lda inf_r
        bcc ?rw0
        sta [inf_out]
        iny
?rw0    rep #$21
        .LONGA ON
        lda inf_r
?rw1    sta [inf_out],y
        iny
        iny
        dex
        bne ?rw1
        jmp ?cend
        .LONGA OFF
?rbig   stz inf_bg
        lda inf_len
        sta inf_j
        ldx #64
        ldy #0
        rep #$20
        .LONGA ON
        lda inf_r
?rb1    sta [inf_out],y
        iny
        iny
        sta [inf_out],y
        iny
        iny
        dex
        bne ?rb1
        sep #$20
        .LONGA OFF
        jmp ?cb2

;==============================================================
; THE RARE SYMBOLS, generic: X = 2k
;==============================================================
        .rept 8, #, #*2
eob:1   ldx #:2
        jmp ?eob
lg2:1   ldx #:2
        jmp ?lng2
dlg:1   ldx #:2
        jmp ?dlong
        .endr

; a literal/length code past 10 bits (Y = ?walk's state behind its first 8)
?lng2   sty inf_ws
        stz inf_ws+1
        stx inf_k2
        ldx #2*9
        jsr ?walk
        .LONGA ON
        cmp #256
        bcs ?lg3
        sep #$20
        .LONGA OFF
        sta [inf_out]
        inc inf_out
        bne ?lg2
        inc inf_out+1
        bne ?lg2
        inc inf_out+2
        inc inf_src+2
?lg2    ldx inf_k2
        jmp (inf_s8,x)
?lg3    .LONGA ON
        sep #$20
        .LONGA OFF
        jeq ?eob1
        sbc #257-256                 ; C = 1: the low byte is the length symbol
        bra ?lenx

; a length symbol out of ?walk (A): its extra bits, generic
?lenx   tax
        lda.l B1CODE_BASE+inf_lxt,x
        beq ?lx1
        phx
        jsr ?gbits
        plx
?lx1    clc
        adc INF_KLB3,x  ; the length - 3
        cmp #253
        bcs ?lbig
        adc #3                       ; C = 0
        sta inf_len
        ldx inf_k2
        jmp (inf_d8,x)

; a match of 256..258 bytes (A = its length - 3, C = 1): its distance
;   through the table, generic
?lbig   sbc #253
        sta inf_len
        dec inf_bg
        jsr ?gpeek
        sep #$20
        and #$7F
        tay
        lda INF_DT,y
        cmp #$E0
        bcs ?dl0                     ; (Y = the table index)
        lsr @
        lsr @
        lsr @
        lsr @
        lsr @
        inc @
        jsr ?gadv                    ; (Y kept)
        ldx INF_DS,y
        bra ?dl1

; a distance code past 7 bits (Y = the table index: INF_DS holds ?walk's
;   state behind them, bit 7 set = a far symbol's code of 7 bits or less)
?dlong  stx inf_k2
?dl0    lda INF_DS,y
        jmi ?dfs
        sta inf_ws
        stz inf_ws+1
        lda #7
        jsr ?gadv
        ldx #32+2*8
        jsr ?walk
        .LONGA ON
        asl @
        tax
        sep #$20
        .LONGA OFF
?dl1    beq ?dl7                     ; distance 1
        cpx #2*30
        jcs ?dfw
        stz inf_r
        stz inf_r+1
        lda INF_KDX2,x
        lsr @
        beq ?dl4
        phx
        cmp #9
        bcc ?dl2
        sbc #8                       ; C = 1
        pha
        lda #8
        jsr ?gbits
        sta inf_r
        pla
        jsr ?gbits
        sta inf_r+1
        bra ?dl3
?dl2    jsr ?gbits
        sta inf_r
?dl3    plx
?dl4    lda inf_k2
        sta inf_t
        bit inf_bg
        bmi ?dl5
        rep #$20
        .LONGA ON
        lda inf_r
        jmp ?etl
        .LONGA OFF
?dl5    stz inf_bg
        rep #$20
        .LONGA ON
        lda inf_r
        eor #$FFFF
        sec
        adc INF_KDNB,x
        clc
        adc inf_out
        sta inf_src
        sep #$20
        .LONGA OFF
        bcs ?dl6
        dec inf_src+2                ; (?csyn puts it back)
?dl6    lda inf_len
        sta inf_j
        jmp ?cbig
?dl7    lda inf_k2
        jmp ?rle

; a far match. ?dfs: A = $80 | 8 x (the symbol - 30) | its code's bits - 1,
;   the stream on the code. ?dfw: X = the symbol x 2, the stream behind it.
?dfs    pha
        and #7
        inc @
        jsr ?gadv
        pla
        and #8
        bra ?dfar
?dfw    txa
        and #2
?dfar   tay                          ; <> 0: symbol 31 (?gbits keeps Y)
        lda #8
        jsr ?gbits
        sta inf_r
        lda #8
        jsr ?gbits
        sta inf_r+1
        tya
        beq ?df1
        lda #5
        jsr ?gbits
        inc @                        ; 98305 = $01:8001
?df1    tax                          ; the distance's bits 16+
        rep #$21                     ; C = 0
        .LONGA ON
        lda inf_r
        adc #$8001                   ; both bases end in $8001
        bcc ?df2
        inx
?df2    eor #$FFFF                   ; the source = the output - the distance
        sec
        adc inf_out
        sta inf_src
        sep #$20
        .LONGA OFF
        txa
        eor #$FF
        adc inf_out+2                ; C = the low word's
        sta inf_src+2
        lda inf_k2
        sta inf_t
        bit inf_bg
        jpl ?efar                    ; (?esyn puts the source's bank in step)
        stz inf_bg
        bra ?dl6                     ; 256..258 bytes

; ?walk -- a code bit by bit through the canonical counts. inf_ws = the
;   state, X = the first length's INF_CNT index. -> A (16-bit) = the symbol.
?walk   stx inf_wx
?wk0    jsr ?gpeek
        .LONGA ON
        sta inf_r
        ldy #8                       ; bits to the next byte
        ldx inf_wx
        lda inf_ws
?wk1    lsr inf_r
        rol @
        cmp.l INF_CNT,x
        bcc ?wk2
        sbc.l INF_CNT,x
        inx
        inx
        dey
        bne ?wk1
        sta inf_ws
        stx inf_wx
        sep #$20
        .LONGA OFF
        inc inf_in
        bne ?wk0
        jsr ?inpage
        bra ?wk0
?wk2    .LONGA ON
        asl @                        ; C = 0
        adc.l INF_PTR,x
        sta inf_s
        sep #$21
        .LONGA OFF
        sty inf_j
        lda #9
        sbc inf_j                    ; the bits of this byte
        jsr ?gadv
        rep #$20
        .LONGA ON
        lda [inf_s]
        rts
        .LONGA OFF

;==============================================================
; THE STREAM, generic
;==============================================================
; ?gpeek -- A (16-bit) = the stream from its next bit on. Leaves M = 0.
?gpeek  ldx inf_k2
        rep #$20
        .LONGA ON
        lda (inf_in)
        jmp (inf_gs,x)
?gp7    lsr @
?gp6    lsr @
?gp5    lsr @
?gp4    lsr @
?gp3    lsr @
?gp2    lsr @
?gp1    lsr @
?gp0    rts
        .LONGA OFF

; ?gbits -- A = n (1..8) -> A = the next n bits, the stream behind them.
;   Y kept.
?gbits  sta inf_j
        jsr ?gpeek
        sep #$20
        ldx inf_j
        and.l B1CODE_BASE+inf_m8,x
        pha
        txa
        jsr ?gadv
        pla
        rts

; ?gadv -- the stream A bits on (A < 120). X, Y kept.
?gadv   asl @                        ; C = 0
        adc inf_k2
?ga1    cmp #16
        bcc ?ga2
        sbc #16                      ; C = 1
        inc inf_in
        bne ?ga1
        pha
        jsr ?inpage
        pla
        bra ?ga1
?ga2    sta inf_k2
        rts

; ?inpage -- inf_in's low byte wrapped: the 3 bytes behind the page line
;   to the front, the next sector behind them. A lost, X and Y kept.
?inpage phx
        phy
        lda INF_TOP
        sta INF_BUF
        lda INF_TOP+1
        sta INF_BUF+1
        lda INF_TOP+2
        sta INF_BUF+2
        lda #<INF_BUF
        sta inf_in
        jsr ?rdsec
        ply
        plx
        rts

?rdsec  lda #$40
        sta DSTATS
        lda ll_sec
        sta DAUX1
        lda ll_sec+1
        sta DAUX2
        jsl siov_r_w0
        sty sio_status
        dey                          ; Y = 1: the sector is in. Anything else:
        bne ?rdsec                   ;   again -- a bad one cannot be depacked
        inc ll_sec
        bne ?rs0
        inc ll_sec+1
?rs0    lda.l INF_TK                 ; con_tick counts KBs
        inc @
        sta.l INF_TK
        and #7
        beq ?rs1
        rts
?rs1    jmp con_tick

;==============================================================
; THE TABLES OF A CODE
;==============================================================
; ?clr -- X = the set: inf_q, its 16 counts cleared
?clr    stx inf_q
        stz inf_q+1
        ldy #16
        rep #$20
        .LONGA ON
        lda #0
?cl1    sta.l INF_CNT,x
        inx
        inx
        dey
        bne ?cl1
        sep #$20
        .LONGA OFF
        rts

; ?cnt -- inf_p -> Y lengths (0 = 256): counted
?cnt    sty inf_j
        ldy #0
?cn1    lda [inf_p],y
        beq ?cn2
        asl @
        ora inf_q
        tax
        rep #$20
        .LONGA ON
        lda.l INF_CNT,x
        inc @
        sta.l INF_CNT,x
        sep #$20
        .LONGA OFF
?cn2    iny
        cpy inf_j
        bne ?cn1
        rts

; ?pre -- A = the table's longest code, inf_s -> the symbols of the longer
;   ones. INF_NX = each table length's first code, INF_PTR = each longer
;   length's first symbol, inf_cl = the first pattern of a longer code,
;   inf_wx bit 7 = there is none.
?pre    sta inf_bl
        stz inf_c
        stz inf_wx
        ldx inf_q
        ldy #1
?pr1    inx
        inx
        lda inf_c
        sta INF_NX,y
        lda.l INF_CNT,x
        beq ?pr4
        sty inf_j
        sta inf_m
        lda #8
        sec
        sbc inf_j
        tay                          ; count << (8 - length)
        lda inf_m
        cpy #0
        beq ?pr3
?pr2    asl @
        bcs ?pr3b                    ; 256: this length alone uses them up
        dey
        bne ?pr2
?pr3    clc
        adc inf_c
        sta inf_c
        bcc ?pr3a
?pr3b   dec inf_wx                   ; every pattern is a code of the table
?pr3a   ldy inf_j
?pr4    cpy inf_bl
        iny
        bcc ?pr1
        lda inf_c
        sta inf_cl
        rep #$21
        .LONGA ON
        lda inf_s
?pr5    inx
        inx
        sta.l INF_PTR,x
        sta.l INF_RUN,x
        adc.l INF_CNT,x              ; (C stays 0: 320 words at most)
        adc.l INF_CNT,x
        iny
        cpy #16
        bcc ?pr5
        sep #$20
        .LONGA OFF
        rts

; ?plc -- A = the length of symbol inf_sy + Y: into its place for ?walk.
;   Y kept.
?plc    asl @                        ; C = 0
        rep #$20
        .LONGA ON
        and #$00FF
        ora inf_q
        tax
        lda.l INF_RUN,x
        sta inf_s
        inc @
        inc @
        sta.l INF_RUN,x
        tya
        adc inf_sy
        sta [inf_s]
        sep #$20
        .LONGA OFF
        rts

; ?bll -- INF_CLN's 288 lengths -> INF_LT/INF_LV, INF_T2/INF_V2
?bll    rep #$20
        .LONGA ON
        lda #INF_CLN&$FFFF
        sta inf_p
        lda #INF_SRT&$FFFF
        sta inf_s
        stz inf_sy
        sep #$20
        .LONGA OFF
        ldx #0
        jsr ?clr
        ldy #0
        jsr ?cnt
        inc inf_p+1
        ldy #32
        jsr ?cnt
        dec inf_p+1
        lda #8
        jsr ?pre
        ldy #0                       ; --- the literals
?lt1    lda [inf_p],y
        beq ?lt3
        cmp #9
        bcs ?lt4
        tax                          ; C = 0
        lda.l B1CODE_BASE+inf_stp,x
        sta inf_m
        lda INF_NX,x
        sta inf_c
        adc inf_m
        sta INF_NX,x
        lda.l B1CODE_BASE+inf_fst,x
        sta inf_fs
        txa
        asl @
        sta inf_tv
        ldx inf_c
        lda.l B1CODE_BASE+inf_rev,x
        tax
        clc                          ; (the index carries behind the last
?lt2    lda inf_tv                   ;   entry only)
        sta INF_LT,x
        tya
        sta INF_LV,x
        txa
        adc inf_fs
        tax
        dec inf_m
        bne ?lt2
?lt3    iny
        bne ?lt1
        beq ?ct0
?lt4    jsr ?plc
        bra ?lt3
?ct0    inc inf_p+1                  ; --- end of block and the lengths
        inc inf_sy+1                 ;     (Y = 0)
?ct1    lda [inf_p],y
        beq ?ct2
        jsr ?cte
?ct2    iny
        cpy #32
        bne ?ct1
?lp0    bit inf_wx                   ; --- the longer codes' patterns
        jmi ?lp9
        stz inf_j                    ; ?walk's state behind each
        ldx inf_cl
?lp1    lda.l B1CODE_BASE+inf_rev,x
        tay
        lda #INF_TLONG
        sta INF_LT,y
        lda inf_j
        sta INF_LV,y
        inc inf_j
        inx
        bne ?lp1
        ldx #0                       ; ... and their second read: past 10
        lda #INF_TLNG2               ;   bits until a code says otherwise
?lp2    sta.l INF_T2,x
        sta.l INF_T2+$100,x
        sta.l INF_T2+$200,x
        sta.l INF_T2+$300,x
        inx
        cpx inf_j
        bne ?lp2
        lda #1                       ; the 9-bit codes: bit 9 is either
        sta inf_bl
        rep #$20
        .LONGA ON
        stz inf_ws
        lda.l INF_PTR+18
        sta inf_s
        lda.l INF_CNT+18
        beq ?lp4
        sta inf_n
?lp3    jsr ?s2v
        rep #$20
        lda inf_ws
        lsr @                        ; the state, C = bit 8
        tay
        sep #$20
        .LONGA OFF
        lda #0
        rol @
        pha
        jsr ?s2w
        pla
        ora #2
        jsr ?s2w
        rep #$20
        .LONGA ON
        inc inf_ws
        dec inf_n
        bne ?lp3
?lp4    inc inf_bl                   ; (8-bit cell: its neighbour inf_m is free)
        stz inf_ws
        lda.l INF_PTR+20
        sta inf_s
        lda.l INF_CNT+20
        beq ?lp6
        sta inf_n
?lp5    jsr ?s2v
        rep #$20
        lda inf_ws
        and #1
        asl @
        sta inf_r                    ; bit 9 x 2
        lda inf_ws
        lsr @
        clc
        adc.l INF_CNT+18
        lsr @                        ; the state, C = bit 8
        tay
        lda inf_r
        adc #0
        sep #$20
        .LONGA OFF
        jsr ?s2w
        rep #$20
        .LONGA ON
        inc inf_ws
        dec inf_n
        bne ?lp5
?lp6    sep #$20
        .LONGA OFF
?lp9    rts

; ?cte -- A = the length of control symbol Y (0 = end of block, 1.. = a
;   match length): its INF_LT/INF_LV entries, or its place for ?walk. Y kept.
?cte    cmp #9
        jcs ?plc
        sta inf_bl
        tax                          ; C = 0
        lda.l B1CODE_BASE+inf_stp,x
        sta inf_m
        lda INF_NX,x
        sta inf_c
        adc inf_m
        sta INF_NX,x
        lda.l B1CODE_BASE+inf_fst,x
        sta inf_fs
        stz inf_em
        stz inf_j
        tya
        bne ?ce1
        lda inf_bl                   ; 256: end of block
        sta inf_v
        lda #INF_TEOB
        bra ?ce3
?ce1    tax                          ; length symbol + 1
        cpx #28
        bcs ?ce2                     ; 284, 285: up to 258 bytes -- generic
        lda.l B1CODE_BASE+inf_lxt-1,x
        adc inf_bl                   ; C = 0
        cmp #9
        bcs ?ce2
        asl @                        ; the extra bits fit: C = 0
        adc #32
        sta inf_tv
        lda.l B1CODE_BASE+inf_lb3-1,x
        adc #3                       ; C = 0: the length
        sta inf_v
        lda.l B1CODE_BASE+inf_lem-1,x
        sta inf_em
        bra ?ce4
?ce2    dex                          ; the extra bits wait
        stx inf_v
        lda inf_bl
        asl @                        ; C = 0
        adc #INF_TPEND
?ce3    sta inf_tv
?ce4    ldx inf_c
        lda.l B1CODE_BASE+inf_rev,x
        tax
        clc                          ; (a length is 255 at most, and the
?ce5    lda inf_tv                   ;   index carries behind the last entry
        sta INF_LT,x                 ;   only.) The bits above the code count
        lda inf_j                    ;   the extra bits up
        and inf_em
        adc inf_v
        sta INF_LV,x
        inc inf_j
        txa
        adc inf_fs
        tax
        dec inf_m
        bne ?ce5
        rts

; ?s2v -- the next symbol of inf_s, inf_bl = its bits past the first 8:
;   inf_tv / inf_v = its entry. M = 0 in, 8-bit out.
?s2v    .LONGA ON
        lda [inf_s]
        inc inf_s
        inc inf_s
        cmp #256
        sep #$20
        .LONGA OFF
        bcs ?sv1
        sta inf_v
        lda inf_bl
        asl @
        sta inf_tv
        rts
?sv1    bne ?sv2
        lda inf_bl
        sta inf_v
        lda #INF_TEOB
        sta inf_tv
        rts
?sv2    sbc #257-256                 ; C = 1
        sta inf_v
        lda inf_bl
        asl @                        ; C = 0
        adc #INF_TPEND
        sta inf_tv
        rts

; ?s2w -- A = the page (bits 8-9 of the code), Y = the state: the entry in
?s2w    ora #>INF_T2
        sta inf_p2+1
        ora #4
        sta inf_s2+1
        lda inf_tv
        sta [inf_p2],y
        lda inf_v
        sta [inf_s2],y
        rts

; a far symbol's entries (A = its code's bits - 1, Z = symbol 30): ?dlong's
?bdf    beq ?bdg
        ora #8
?bdg    ora #$80
        sta inf_v
        lda #$E0
        sta inf_tv
        bra ?bdm

; ?bdt -- inf_p -> 32 lengths -> INF_DT/INF_DS
?bdt    rep #$20
        .LONGA ON
        lda #INF_SRTD&$FFFF
        sta inf_s
        stz inf_sy
        sep #$20
        .LONGA OFF
        ldx #32
        jsr ?clr
        ldy #32
        jsr ?cnt
        lda #7
        jsr ?pre
        ldy #0
?bd1    lda [inf_p],y
        beq ?bd3
        cmp #8
        bcs ?bd4
        tax                          ; C = 0
        dec @
        cpy #30
        bcs ?bdf
        asl @
        asl @
        asl @
        asl @
        asl @
        sta inf_tv                   ; (length - 1) << 5
        tya
        asl @
        sta inf_v                    ; symbol x 2
?bdm    lda.l B1CODE_BASE+inf_stp,x
        lsr @
        sta inf_m                    ; 128 >> length entries
        lda INF_NX,x
        sta inf_c
        adc.l B1CODE_BASE+inf_stp,x  ; C = 0
        sta INF_NX,x
        lda.l B1CODE_BASE+inf_fst,x
        sta inf_fs
        ldx inf_c
        lda.l B1CODE_BASE+inf_rev,x
        tax
        clc                          ; (7 bits of index: no carry)
?bd2    lda inf_tv
        sta INF_DT,x
        lda inf_v
        sta INF_DS,x
        txa
        adc inf_fs
        tax
        dec inf_m
        bne ?bd2
?bd3    iny
        cpy #32
        bne ?bd1
        beq ?bd5
?bd4    jsr ?plc
        bra ?bd3
?bd5    bit inf_wx                   ; the longer codes' patterns: ?walk's
        bmi ?bd7                     ;   state behind each
        stz inf_j
        ldx inf_cl
?bd6    lda.l B1CODE_BASE+inf_rev,x
        tay
        lda #$E0
        sta INF_DT,y
        lda inf_j
        sta INF_DS,y
        inc inf_j
        inx
        inx
        bne ?bd6
?bd7    rts

;==============================================================
; DISPATCH + CONSTANTS (program bank)
;==============================================================
inf_sd  dta a(0)                     ; [INF_LT / INF_T2] + 2k
        .rept 15, #+1
        dta a(lit:1)
        .endr
        dta a(0)
        .rept 15, #+1
        dta a(len:1)
        .endr
        dta a(0)
        .rept 15, #+1
        dta a(pnd:1)
        .endr
        .rept 8, #
        dta a(lng:1)
        .endr
        :8 dta a(0)
        .rept 8, #
        dta a(eob:1)
        .endr
        :8 dta a(0)
        .rept 8, #
        dta a(lg2:1)
        .endr

inf_dd  .rept 7, #+1, #+2, #+3, #+4, #+5, #+6, #+7, #+8
        dta a(dgo:1), a(dgo:2), a(dgo:3), a(dgo:4)
        dta a(dgo:5), a(dgo:6), a(dgo:7), a(dgo:8)
        :+8 dta a(0)
        .endr
        .rept 8, #
        dta a(dlg:1)
        .endr

inf_pd  .rept 8, #                   ; 2(k + a length's extra bits)
        dta a(dis:1)
        .endr
        .rept 8, #+8
        dta a(dad:1)
        .endr
inf_xc  .rept 21, #                  ; 2(k + a distance's extra bits)
        dta a(cps:1)
        .endr
inf_xd  .rept 21, #
        dta a(fin:1)
        .endr
INF_XSYN equ *-inf_xd
        dta a(?esyn)
inf_s8  .rept 8, #
        dta a(sym:1)
        .endr
inf_d8  .rept 8, #
        dta a(dis:1)
        .endr
inf_gs  dta a(?gp0), a(?gp1), a(?gp2), a(?gp3)
        dta a(?gp4), a(?gp5), a(?gp6), a(?gp7)

; the DCB: disk 1, read 128 B into INF_RD, 15 s (the sector: ?rdsec)
inf_dcb dta $31, 1, $52, $40, a(INF_RD), $0F, 0, a(128), a(0)
inf_m8  dta 0,1,3,7,15,31,63,127,255
inf_stp dta 0,128,64,32,16,8,4,2,1   ; 256 >> length
inf_fst dta 1,2,4,8,16,32,64,128,0   ; 1 << length
inf_ord dta 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15
; length symbols 257..285: extra bits
inf_lxt dta 0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2
        dta 3,3,3,3,4,4,4,4,5,5,5,5,0,0,0
; the constants inflate copies to INF_K, in its layout -- distance symbols
;   0..29, a word each: the extra bits' mask, - base, 2 x extra bits; length
;   symbols 257..285: the extra bits' mask, base - 3, 2 x extra bits
inf_kst
inf_dmk dta a($0000),a($0000),a($0000),a($0000),a($0001),a($0001)
        dta a($0003),a($0003),a($0007),a($0007),a($000F),a($000F)
        dta a($001F),a($001F),a($003F),a($003F),a($007F),a($007F)
        dta a($00FF),a($00FF),a($01FF),a($01FF),a($03FF),a($03FF)
        dta a($07FF),a($07FF),a($0FFF),a($0FFF),a($1FFF),a($1FFF)
        :4 dta 0
inf_dnb dta a($FFFF),a($FFFE),a($FFFD),a($FFFC),a($FFFB),a($FFF9)
        dta a($FFF7),a($FFF3),a($FFEF),a($FFE7),a($FFDF),a($FFCF)
        dta a($FFBF),a($FF9F),a($FF7F),a($FF3F),a($FEFF),a($FE7F)
        dta a($FDFF),a($FCFF),a($FBFF),a($F9FF),a($F7FF),a($F3FF)
        dta a($EFFF),a($E7FF),a($DFFF),a($CFFF),a($BFFF),a($9FFF)
        :4 dta 0
inf_dx2 dta a(0),a(0),a(0),a(0),a(2),a(2),a(4),a(4),a(6),a(6)
        dta a(8),a(8),a(10),a(10),a(12),a(12),a(14),a(14),a(16),a(16)
        dta a(18),a(18),a(20),a(20),a(22),a(22),a(24),a(24),a(26),a(26)
        :4 dta 0
inf_lem dta 0,0,0,0,0,0,0,0,1,1,1,1,3,3,3,3
        dta 7,7,7,7,15,15,15,15,31,31,31,31,0,0,0
        dta 0
inf_lb3 dta 0,1,2,3,4,5,6,7,8,10,12,14,16,20,24,28
        dta 32,40,48,56,64,80,96,112,128,160,192,224,255,0,0
        dta 0
inf_lx2 dta 0,0,0,0,0,0,0,0,2,2,2,2,4,4,4,4
        dta 6,6,6,6,8,8,8,8,10,10,10,10,0,0,0
        dta 0
    .if *-inf_kst <> INF_KLEN
        ert 'inflate: inf_kst is INF_KLEN bytes'
    .endif
; a distance past 8 extra bits: the mask of its bits 8+
inf_dmh dta a($0000),a($0000),a($0000),a($0000),a($0000),a($0000)
        dta a($0000),a($0000),a($0000),a($0000),a($0000),a($0000)
        dta a($0000),a($0000),a($0000),a($0000),a($0000),a($0000)
        dta a($0000),a($0000),a($0001),a($0001),a($0003),a($0003)
        dta a($0007),a($0007),a($000F),a($000F),a($001F),a($001F)
; a byte's bits the other way round
inf_rev .rept 256, #
        dta [[:1&1]<<7]|[[:1&2]<<5]|[[:1&4]<<3]|[[:1&8]<<1]|[[:1&16]>>1]|[[:1&32]>>3]|[[:1&64]>>5]|[[:1&128]>>7]
        .endr
.endp
inflate_w1 jsr inflate               ; bank-0 callers (menu_boot's map-slot
        rtl                          ;   half) jsl B1CODE_BASE+inflate_w1
        .endseg
