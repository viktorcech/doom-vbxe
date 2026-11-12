        opt h+
        opt o+

        icl 'boot_cfg.inc'      ; BOOT_TOPBANK, B_MCOL, BOOT_RELOC (tools/boot_cfg.py)

        org $0700

; === Boot header (6 bytes, read by the OS) ===
        dta $00                 ; boot flag
        dta BOOT_SECTORS        ; the sectors the OS loads
        dta a($0700)            ; load address
        dta a(boot_init)        ; init address (DOSINI) -- also == BLDADR+6

zp_dest     = $E0               ; 2-byte destination pointer (free ZP at boot);
                                ;   +2 = the bank, for the RAM probe
zp_msg      = $E3               ; 2-byte text pointer (b_say, b_reloc)
zp_cnt      = $E5               ; a segment's bytes still to come, counted UP to 0
SDMCTL      = $022F             ; the OS shadows: its VBI runs all through the load
SDLSTL      = $0230
COLOR1      = $02C5
COLOR2      = $02C6
COLOR4      = $02C8             ; GTIA's background: the border
COLBK       = $D01A
DCB         = $0300             ; the OS's device control block (SIOV)
DSTATS      = DCB+3
DAUX1       = DCB+10            ; the sector: read_sec steps it in place
SIOV        = $E459
PORTB       = $D301
DMACTL      = $D400
NMIEN       = $D40E
NMIRES      = $D40F
B_INK       equ $0A             ; the screen: this luminance ...
B_PAPER     equ $30             ;   ... of this hue, on its darkest
B_MARKW     equ 8               ; a mark's width
; No XEX segment loads below $0E88: the loader owns $0700 up to there (the
; ert at the end of the file; tools/ram_map.py reserves it). The XEX ships
; ZX02-packed (2026-10-01, make_atr_doom.py): zx_dec unpacks ALL of it off
; the drive into the linear RAM at ZX_BUF before parse_seg writes a byte of
; it, so the sector buffer may sit in RAM the XEX loads over later -- its END
; on a page (get_sio reads SECBUF-128,y).
SECBUF      equ $0F80
BOOT_TOP    equ $0E88
ZX_BUF      equ $200000             ; the unpacked XEX (verified RAM, idle at boot)
zx_off      = $E7                   ; zx_dec: the last offset (2)
zx_dst      = $E9                   ;   the output cursor (3) -- then parse_seg's
                                    ;   read cursor (get_byte)
zx_ptr      = $EC                   ;   a match's source (3)
zx_bit      = $EF                   ;   the bit buffer

; === Boot entry point ===
; CRITICAL: this label MUST sit at BLDADR+6 ($0706). The Atari OS boot path
; (OS ROM `EBL`: RAMLO=BOOTAD+6, `JMP (RAMLO)`) executes the FIRST instruction
; at load_address+6 -- it does NOT enter via the init vector first. So real
; code lives at +6 here, and the loader's data goes at the TAIL.
boot_init
        cld
        ; --- the loader's own screen: the OS's is in RAM the XEX loads over.
        ;     I set: the VBI leaves the shadows alone until all are written
        sei
        lda #<b_dl
        sta SDLSTL
        lda #>b_dl
        sta SDLSTL+1
        lda #B_INK
        sta COLOR1
        lda #B_PAPER
        sta COLOR2
        sta COLOR4              ; (do_run puts GTIA's background back: it is the
        lda #$22                ;   game's border, through VBXE's palette)
        sta SDMCTL
        cli

        ; === THE MACHINE CHECK (2026-09-28, drac030's list) ==================
        ; BEFORE the load: a machine that cannot run the game says so at once.
        ; ALL three checks run and show what they found; the first part that is
        ; missing is the one the text under them is about.
        ; 1. the CPU. Plain 6502 code, as all of the check but the RAM probe.
        lda #$99
        clc
        sed
        adc #$01
        cld
        bne ?nocpu              ; NMOS 6502: Z is the BINARY sum's
        lda #0                  ; (Z set)
        dta $C2,$02             ; rep #$02: a 65C816 clears Z, a 65C02 skips it
        bne ?cpu                ; A = 0: found
?nocpu  lda #1
?cpu    ldx #0                  ; X = the check
        jsr b_mark

        ; 2. linear RAM: every bank $01..BOOT_TOPBANK holds what is written to
        ;    it. The bank-0 twin of the probed byte takes the INVERTED pattern,
        ;    so a mirror of bank 0 fails; the second pattern is the first one
        ;    swapped, so neither open bus nor a stale byte passes twice.
        ;    A 65C816's alone: without one the RAM is missing, unprobed.
        ldy b_first
        iny                     ; 0: the CPU is there
        tya
        bne ?ram
        opt c+
        lda #<b_twin
        sta zp_dest
        lda #>b_twin
        sta zp_dest+1
        ldy #1
?bank   sty zp_dest+2
        lda [zp_dest]           ; the bank's own byte, put back below
        pha
        lda #$A5
        jsr b_probe
        bne ?rbad
        lda #$5A
        jsr b_probe
?rbad   tax                     ; 0 = the bank answered
        pla
        sta [zp_dest]
        txa
        bne ?noram
        iny
        cpy #BOOT_TOPBANK+1
        bcc ?bank
        bcs ?ram                ; (A = 0: found)
?noram  tya                     ; the bank that is not there, into the text
        jsr b_hex               ; (A <> 0 out: a screen code)
        opt c-
?ram    ldx #1
        jsr b_mark

        ; 3. VBXE: an FX core 1.2x at $D640 or at $D740. (zp),y: a 6502 may be
        ;    the one running this.
        lda #$40
        sta zp_dest
        ldx #$D6
?vbxe   stx zp_dest+1
        ldy #0
        lda (zp_dest),y         ; CORE_VERSION
        cmp #$10                ; FX 1.xx
        bne ?vnext
        iny
        lda (zp_dest),y         ; MINOR_REVISION
    .ifdef FX127
        and #$7F                ; the FX127 build drives the 1.27 raycaster:
        cmp #$20                ;   core 1.27 or newer (2026-10-19; the same 6
        bcs ?vfound             ;   bytes as the 1.2x test -- the sectors are full)
                                ; 2026-10-21: the 1.27 check SUSPENDED: any 1.2x
                                ;   passes, so a 1.26 boots too. TO RESTORE IT:
                                ;   cmp #$20 above back to cmp #$27, then
                                ;   .\build_atr.ps1 -Fx127
    .else
        and #$70
        cmp #$20                ; 1.2x
        beq ?vfound
    .endif
?vnext  inx
        cpx #$D8
        bne ?vbxe
        lda #1                  ; missing
        bne ?vmark
?vfound stx b_vhi               ; (do_run: a VBXE at $D7xx moves the engine's
        dey                     ;   register addresses)
        tya                     ; A = 0: VIDEO_CONTROL off, the picture on the
        sta (zp_dest),y         ;   screen is ANTIC's; and "found"
?vmark  ldx #2
        jsr b_mark

        ; 4. one POKEY or two (2026-10-06; Seban's test, mads-src/examples/
        ;    stereo_detect.asm): timer 1 is started through the SECOND chip's
        ;    registers, its IRQ on. A lone POKEY mirrors them, and ITS IRQST
        ;    shows the timer; with two it never does and VCOUNT's line 256 ends
        ;    the wait. IRQs held; plain 6502 code.
        ;    2026-10-06 ("ak je MONO, v hlavnej hre hudba hrat nebude"): the row
        ;    only SAYS which -- b_first is not touched, a mono machine loads on
        ;    and its levels have no song (music.asm mus_level). Skills:
        ;    6502-nmos-atari (plain 6502), 6502-idioms (cpx's C; no cell).
        sei
        lda #3
        sta $D21F               ; SKCTL2: out of init
        sta $D210               ; AUDF1': a short timer
        lda #1
        sta $D21E               ; IRQEN2: its IRQ on
?s1     ldx $D40B               ; VCOUNT: from the frame's top
        bne ?s1
        stx $D219               ; STIMER2: go
?s2     ldx $D40B
        bmi ?s3                 ; no IRQ on the first chip: there is a second
        bit $D20E               ; IRQST (A = 1): bit 0 = 0 once timer 1 is pending
        bne ?s2
?s3     lda #0
        sta $D21E               ; the timer's IRQ off again -- on a lone chip that
        lda $10                 ;   was its only mask: the OS's shadow goes back
        sta $D20E
        cli
        cpx #$80                ; VCOUNT as the wait ended: C = 1 -- two POKEYs
        ldx #0                  ; "OK"
        bcs ?pk
        ldx #2*B_MARKW          ; "MONO"
?pk     ldy #120+B_MCOL         ; the fourth row's mark
        jsr b_put

    .ifdef ANTONIA2
        ; 4. ANTONIA II (drac030 2026-09-30): the card's divider (+0..3), then its
        ;    multiplier (+4..7), stored lo-hi as a 16-bit sta.l would. A miss
        ;    rewrites the CPU row: the loader has no bytes for a fourth one.
        ;    2026-09-30 rules (.claude/skills/<name>/SKILL.md):
        ;    - 6502-loops-tables-smc: "index counting up to zero" -- X runs
        ;      256-8..0, `txa / bne` ends it, no `cpx` (6502-idioms forbids
        ;      inx / cpx #n / bne; counting down would store hi before lo).
        ;    - 65816-modes-banks: emulation mode, so byte stores (no rep/sep);
        ;      "long addressing is X-indexed only" -- sta.l / lda.l ...,x.
        ;    - 6502-nmos-atari: the 65816 opcodes run only after the CPU row
        ;      found one (b_first <> 0); no RMW on the card's registers.
        ;    - 6502-idioms: `beq ?mdx` on the known Z instead of a jmp.
        opt c+
        lda b_first
        beq ?mdx                ; no 65C816: the CPU row says so already
        ldx #256-8              ; X counts UP to 0: the stores go lo, hi
?mdu    ldy #4                  ; one unit: its two words in ...
?mdw    lda b_mdv+8-256,x
        sta.l B_ANTREG+8-256,x
        inx
        dey
        bne ?mdw
        dex
        dex
        dex
        dex
        ldy #4                  ; ... and its two words out
?mdr    lda.l B_ANTREG+8-256,x
        eor b_mdr+8-256,x
        bne ?mdno               ; A <> 0: "missing" for b_mark
        inx
        dey
        bne ?mdr
        txa
        bne ?mdu
        beq ?mdx                ; (A = 0) both answered
?mdno   ldx #0
        jsr b_mark
?mdx
        opt c-
    .endif

        ldx b_first            ; a part is missing: its two lines, and STOP
        bmi ?all
        lda b_errl,x
        ldy b_errh,x
        jsr b_say
?halt   jmp ?halt
?all    lda #<b_load
        ldy #>b_load
        jsr b_say

        ; --- RAPIDUS FAST WINDOWS (2026-08-10) ------------------------------ ...
        opt c+
        lda.l $FF0080
        ora #$60                ; write-through on (the $EF default has it on)
                                ;   + I/O SPLIT ON (2026-08-11, was ...
        and #$F5                ; fast1 ($4000-7FFF: ENTICK, TWMASK, SPRCROP)
                                ;   + fast3 (RAM under ROM: TWS anchors, ...
        sta.l $FF0080
        ; --- CMCR $FF0081 bit6 (2026-08-17): write-through OFF for $0000-3FFF.
        lda.l $FF0081
        ora #$40
        sta.l $FF0081

        ; --- SAFETY NET (2026-08-10, the Rapidus black-screen boot) ---------
        ; Park RTI vectors in the RAM under the ROM BEFORE anything loads.
        sei
        stz NMIEN               ; NMIs off while the ROM is out (as below)
        lda #$01
        trb PORTB               ; ROM out
        lda #<vec_rti
        sta $FFFA               ; NMI
        sta $FFFE               ; IRQ/BRK
        lda #>vec_rti
        sta $FFFB
        sta $FFFF
        lda #$03                ; ROM back in -- AND BASIC OUT (bit 1), for good:
        tsb PORTB               ;   an XL booted without OPTION has BASIC at
                                ;   $A000-$BFFF, and the FX 1.27 core gives the ROM
                                ;   priority over the MEMAC window there (manual
                                ;   ch. 6, CASINH): every VRAM access at MEMW was
                                ;   the BASIC ROM -- the menu overlay, the BCBs.
                                ;   (2026-10-20: title -> E1M1 by itself, ESC froze)
        lda #$40
        sta NMIEN
        cli

        ldx #B_DCBN-1           ; the DCB, once: SIOV changes DSTATS alone
?dcb    lda b_dcb,x
        sta DCB,x
        dex
        bpl ?dcb

        jsr zx_dec              ; the packed XEX off the drive, unpacked
        stz zx_dst              ; parse it from the start of the buffer
        stz zx_dst+1
        lda #ZX_BUF>>16         ; (the XEX is < 64 KB: still this bank, but
        sta zx_dst+2            ;   the store keeps that from being a rule)
        jsr get_byte            ; skip $FF $FF XEX header
        jsr get_byte

parse_seg
        jsr get_byte
        sta seg_lo
        jsr get_byte
        sta seg_hi
        and seg_lo              ; skip optional $FF $FF separators:
        inc @                   ;   $FF and $FF, + 1
        beq parse_seg

        jsr get_byte            ; segment end address
        sta end_lo
        jsr get_byte
        sta end_hi

        lda seg_hi              ; INIT ($02E2) or RUN ($02E0)?
        cmp #$02
        bne data_seg
        lda seg_lo
        cmp #$E2
        beq do_init
        cmp #$E0
        beq do_run

data_seg
        lda end_lo              ; start + ~end = -(the bytes), counted up to 0:
        eor #$FF                ;   no 16-bit compare a byte
        clc
        adc seg_lo
        sta zp_cnt
        lda end_hi
        eor #$FF
        adc seg_hi
        sta zp_cnt+1
        lda seg_lo
        sta zp_dest
        lda seg_hi
        sta zp_dest+1
        cmp #$C0                ; $C000+: the RAM UNDER the OS ROM -- with PORTB
        bcs ?ulp                ;   bit 0 set the write would hit the ROM
                                ; (zp): no index cycle, so no dummy read of the
?lp     jsr get_byte            ;   target before the store ($8000-$BFFF is slow)
        sta (zp_dest)
        inc zp_dest
        bne ?nc
        inc zp_dest+1
?nc     inc zp_cnt
        bne ?lp
        inc zp_cnt+1
        bne ?lp
        bra parse_seg
?ulp    jsr get_byte
        tay
        sei                     ; IRQs off -- and the VBI AT ANTIC: NMI is not
        stz NMIEN               ;   maskable, and with the ROM out its vector is RAM
        lda #$01
        trb PORTB               ; ROM out
        tya
        sta (zp_dest)
        lda #$01
        tsb PORTB               ; ... and straight back in
        lda #$40                ; VBI back on: SIO counts its timeouts on it, and
        sta NMIEN               ;   the next get_byte may call SIOV
        cli
        inc zp_dest
        bne ?uc
        inc zp_dest+1
?uc     inc zp_cnt
        bne ?ulp
        inc zp_cnt+1
        bne ?ulp
        jmp parse_seg           ; (out of a branch's reach)

do_init
        jsr get_byte
        sta jsr_tgt+1
        jsr get_byte
        sta jsr_tgt+2
        jsr jsr_tgt
        jmp parse_seg

do_run
        jsr get_byte
        sta jmp_tgt+1
        jsr get_byte
        sta jmp_tgt+2
        lda b_vhi
        cmp #$D7
        bne ?go
        jsr b_reloc
?go     stz SDMCTL              ; the loader's screen off: the game's is VBXE's
        stz DMACTL
        stz COLOR4              ; ... and GTIA's background black again, in the
        stz COLBK               ;   register too: main turns the VBI off
jmp_tgt jmp $0000               ; patched with the RUN address

jsr_tgt jmp $0000               ; patched, called via JSR (INIT handlers)

; get_byte -- the unpacked XEX's next byte, [zx_dst] on. Keeps X and Y.
get_byte
        lda [zx_dst]
        inc zx_dst
        bne ?gb
        inc zx_dst+1
        bne ?gb
        inc zx_dst+2
?gb     rts

; get_sio -- the packed stream's next byte off the drive. buf_pos runs
;   128..255 and wraps to 0 when the sector is spent. Keeps X and C: zx_dec
;   carries both across it, and SIOV keeps neither (the rare path pays).
get_sio
        ldy buf_pos
        bne ?ok
        php
        phx
        jsr read_sec
        plx
        plp
        ldy #128
?ok     lda SECBUF-128,y
        iny
        sty buf_pos
        rts

; zx_dec -- the ZX02 stream (zx02-optim.asm, DMSC, MIT; 6502 format) off
;   get_sio into ZX_BUF on, its cursor 24-bit. A 0 offset code ends it.
zx_dec  lda #$80
        sta zx_bit
        stz zx_off              ; (the first match always sets its offset)
        stz zx_off+1
        stz zx_dst
        stz zx_dst+1
        lda #ZX_BUF>>16
        sta zx_dst+2
?lit    ldx #1                  ; literals: Elias(n), then n bytes
        jsr ?eli
?cp0    jsr get_sio
        jsr ?put
        dex
        bne ?cp0
        asl zx_bit
        bcs ?new
        inx                     ; a match at the last offset: Elias(n)
        jsr ?eli
?cpy    lda zx_dst              ; source = cursor - offset - 1 (C = 0: ?eli
        sbc zx_off              ;   and ?sk1 return on it)
        sta zx_ptr
        lda zx_dst+1
        sbc zx_off+1
        sta zx_ptr+1
        lda zx_dst+2
        sbc #0
        sta zx_ptr+2
?cp1    lda [zx_ptr]
        inc zx_ptr
        bne ?p1
        inc zx_ptr+1
        bne ?p1
        inc zx_ptr+2
?p1     jsr ?put
        dex
        bne ?cp1
        asl zx_bit
        bcc ?lit
?new    inx                     ; a match at a new offset: Elias(MSB + 1),
        jsr ?eli                ;   LSB, Elias(n - 1); MSB code 0 = the end
        beq ?end
        dex
        txa
        lsr @
        sta zx_off+1
        jsr get_sio             ; (keeps the lsr's C for the ror)
        ror @
        sta zx_off
        ldx #1
        jsr ?sk1
        inx
        bra ?cpy                ; C = 0: ?sk1 returns on it
?elg    asl zx_bit              ; an interlaced Elias-gamma code into X
        rol @
        tax
?eli    asl zx_bit
        bne ?sk1
        jsr get_sio             ; C = 1 kept: the old byte's stop bit
        rol @
        sta zx_bit
?sk1    txa
        bcs ?elg
?end    rts
?put    sta [zx_dst]            ; one byte out, the cursor on
        inc zx_dst
        bne ?pt
        inc zx_dst+1
        bne ?pt
        inc zx_dst+2
?pt     rts

; read_sec -- the DCB's sector into SECBUF, and the DCB on to the next one.
;   Any error: again -- a bad sector would be a corrupt XEX.
read_sec
        lda #$40
        sta DSTATS              ; a read (SIOV leaves its status here)
        jsr SIOV
        dey                     ; Y = 1: done
        bne read_sec
        inc DAUX1
        bne ?r
        inc DAUX1+1
?r      rts

; vec_rti -- the boot-time NMI/IRQ/BRK handler: clear the ANTIC latch, return.
; (RTCLOK does not tick from here; nothing before urom_init depends on it.)
vec_rti sta NMIRES              ; any write resets the latch
        rti

; b_probe -- A = the pattern, zp_dest the probed byte (long): A = 0 when the
;   bank holds it.
b_probe sta [zp_dest]
        eor #$FF
        sta b_twin              ; the twin: a mirror of bank 0 now differs
        eor #$FF
        eor [zp_dest]
        rts

; b_reloc -- the VBXE is at $D7xx: the table at BOOT_RELOC names every byte
;   that is a register address's high byte, $D6 as assembled -- 3 B an entry
;   (lo, hi, bank), a bank of $FF ends it. tools/vbxe_reloc.py makes it and
;   make_atr_doom.py loads it in front of the RUN vector.
b_reloc lda #<BOOT_RELOC
        sta zp_msg
        lda #>BOOT_RELOC
        sta zp_msg+1
br_ent  ldy #2
        lda (zp_msg),y
        bmi br_done
        sta zp_dest+2
        dey
        lda (zp_msg),y
        sta zp_dest+1
        lda (zp_msg)
        sta zp_dest
        ldx #0                  ; X = 1: bank 0 from $C000, the RAM under the
        lda zp_dest+2           ;   OS ROM -- written as data_seg writes it
        bne br_step
        lda zp_dest+1
        cmp #$C0
        bcc br_step
        inx
        sei
        stz NMIEN
        lda #$01
        trb PORTB
br_step lda [zp_dest]
        inc @
        sta [zp_dest]
        txa
        beq br_next
        tsb PORTB               ; (A = 1: the txa)
        lda #$40
        sta NMIEN
        cli
br_next clc
        lda zp_msg
        adc #3
        sta zp_msg
        bcc br_ent
        inc zp_msg+1
        bra br_ent
br_done rts
        opt c-

;--------------------------------------------------------------
; The machine check's display. PLAIN 6502 CODE: it runs on whatever CPU is in
;   there.
;--------------------------------------------------------------
; b_mark -- X = the check (0-2), A = 0 found / else missing: the mark on the
;   check's row, and the FIRST check that missed into b_first.
; b_put -- X = a mark's offset in b_tok, Y = its cell in b_chk: the mark alone
;   (2026-10-06, the POKEY row; 6502-idioms: the loop's head is the entry).
b_mark  ldy b_rowo,x
        cmp #1                  ; C = 1: missing
        bcc ?fnd
        bit b_first
        bpl ?nf                 ; (not the first)
        stx b_first
?nf     ldx #B_MARKW
        dta $2C                 ; (bit abs: over the ldx)
?fnd    ldx #0
b_put   lda b_tok,x
        sta b_chk,y
        iny
        inx
        txa
        and #B_MARKW-1          ; a mark ends on a multiple of its width
        bne b_put
        rts

; b_say -- A/Y = an 80-cell text: into the two rows under the list.
b_say   sta zp_msg
        sty zp_msg+1
        ldy #79
?c      lda (zp_msg),y
        sta b_stat,y
        dey
        bpl ?c
        rts

; b_hex -- A -> two hex digits, as screen codes, into the RAM text's bank.
b_hex   pha
        lsr @
        lsr @
        lsr @
        lsr @
        jsr ?dig
        sta b_ebank
        pla
        and #$0F
        jsr ?dig
        sta b_ebank+1
        rts
?dig    cmp #10
        bcc ?d
        adc #6                  ; C = 1: n + 7, and no carry out ...
?d      adc #$10                ; ... so n + $10 ('0'-'9') or n + $17 ('A'-'F')
        rts

; === Variables (kept OUT of the execution path -- see boot_init note) ===
buf_pos     dta 0               ; get_byte's place in SECBUF (0 = read a sector)
seg_lo      dta 0
seg_hi      dta 0
end_lo      dta 0
end_hi      dta 0
b_first     dta $FF             ; the first check that missed ($FF: none)
b_twin      dta 0               ; the RAM probe's bank-0 twin
b_vhi       dta 0               ; the VBXE's page: $D6 or $D7

; the DCB: disk 1, read a sector into SECBUF, 15 s, 128 B -- the XEX's first
b_dcb   dta $31, 1, $52, $40, a(SECBUF), $0F, 0, a(128), a(BOOT_SECTORS+1)
B_DCBN  equ * - b_dcb
b_rowo  dta B_MCOL, 40+B_MCOL, 80+B_MCOL    ; a check's mark in b_chk (b_mark's three)
    .ifdef ANTONIA2
B_ANTREG    equ $FFF008         ; +0 divider (w: dividend, divisor  r: quotient,
                                ;   remainder), +4 multiplier (w: two factors
                                ;   r: the 32-bit product) -- math.asm ANT_DIV/MUL
b_mdv   dta a($C350), a(7)                  ; 50000 / 7
        dta a($1234), a($5678)              ; $1234 * $5678
b_mdr   dta a(7142), a(6)                   ; = 7142 r 6
        dta a($0060), a($0626)              ; = $06260060
    .endif
b_errl  dta <b_e0, <b_e1, <b_e2
b_errh  dta >b_e0, >b_e1, >b_e2
b_tok   dta d'OK      '
        dta d'MISSING!'
        dta d'MONO    '         ; the POKEY row's, when there is one chip (check 4)
    .if * - b_tok <> 3*B_MARKW
        ert 'a mark is B_MARKW cells'
    .endif
; the screen: 24 blank lines, DOOM, the title, the checks, the two status rows
b_dl    dta $70,$70,$70
        dta $42,a(b_logo)
        :6 dta $02
        dta $70
        dta $02
        dta $70
        dta $02,$02,$02,$02
        dta $70
        dta $02,$02
        dta $41,a(b_dl)
        icl 'boot_rows.inc'     ; the rows and the texts (tools/boot_cfg.py)
boot_end
BOOT_SECTORS equ [BOOT_TOP-$0700]/128   ; ALL the room below BOOT_TOP: the stock
                                        ;   and ANTONIA II loaders differ in size
                                        ;   and one disk layout serves both

; HARD limits: the loader stays in the RAM no XEX segment loads into, and
; the sector buffer ends on a page (get_sio); ZX_BUF starts a bank.
    .if boot_end > $0700+BOOT_SECTORS*128
        ert 'the boot loader outgrew its sectors below BOOT_TOP'
    .endif
    .if ZX_BUF & $FFFF
        ert 'ZX_BUF starts a bank: zx_dec and the parse reset only its bank byte'
    .endif
    .if BOOT_SECTORS > 255
        ert 'the boot header counts the sectors in a byte'
    .endif
    .if [SECBUF+128] & $FF
        ert 'get_sio reads SECBUF-128,y: the buffer must END on a page'
    .endif
    .if B_DCBN <> 12
        ert 'b_dcb is the DCB, $0300-$030B'
    .endif
