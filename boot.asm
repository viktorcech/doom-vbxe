;--------------------------------------------------------------
; boot.asm -- custom ATR boot loader: the OS loads it to $0700, it reads
;   doom_bsp.xex from raw sectors via SIO and runs its INIT/RUN vectors.
;--------------------------------------------------------------
        opt h+
        opt o+

        org $0700

; === Boot header (6 bytes, read by the OS) ===
        dta $00                 ; boot flag
        dta 3                   ; load 3 sectors (384 bytes)
        dta a($0700)            ; load address
        dta a(boot_init)        ; init address (DOSINI) -- also == BLDADR+6

zp_dest     = $E0               ; 2-byte destination pointer (free ZP at boot)
; 128-byte sector read buffer. It MUST start above the loader's own last byte:
; at $0800 it used to sit right behind a 248-byte loader, and the moment this
; file grew past that (under-ROM support) every sector read overwrote read_sec
; and the loader variables -- the machine cold-started into the OS with a black
; screen. The ert at the end of the file now fails the build instead.
SECBUF      = $0880             ; loader is $0700..$082D; $0880-$08FF is free
                                ; (the engine's vissprite arrays only live there
                                ; once the game runs, long after this is dead)

; === Boot entry point ===
; CRITICAL: this label MUST sit at BLDADR+6 ($0706). The Atari OS boot path
; (OS ROM `EBL`: RAMLO=BOOTAD+6, `JMP (RAMLO)`) executes the FIRST instruction
; at load_address+6 -- it does NOT enter via the init vector first. So real
; code lives at +6 here, and the loader's data variables go at the TAIL (else
; the OS would execute them as code first).
boot_init
        lda #0
        sta $22F                ; SDMCTL off (screen off for fast load)
        sta $D400               ; DMACTL off

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
        opt c-

        ; --- SAFETY NET (2026-08-10, the Rapidus black-screen boot) ---------
        ; Park RTI vectors in the RAM under the ROM BEFORE anything loads.
        sei
        lda #0
        sta $D40E               ; NMIs off while the ROM is out (as below)
        lda $D301
        and #$FE
        sta $D301               ; ROM out
        lda #<vec_rti
        sta $FFFA               ; NMI
        sta $FFFE               ; IRQ/BRK
        lda #>vec_rti
        sta $FFFB
        sta $FFFF
        lda $D301
        ora #$01
        sta $D301               ; ROM back in
        lda #$40
        sta $D40E
        cli

        jsr get_byte            ; skip $FF $FF XEX header
        jsr get_byte

parse_seg
        jsr get_byte
        sta seg_lo
        jsr get_byte
        sta seg_hi

        lda seg_lo              ; skip optional $FF $FF separators
        and seg_hi
        cmp #$FF
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
                                      ; 2026-09-23: A is reloaded right below -> stz
        opt c+
        stz under_rom
        opt c-
        lda seg_lo
        sta zp_dest
        lda seg_hi
        sta zp_dest+1
        ; --- $C000+ segments land in the RAM UNDER the OS ROM ---------------
        ; With PORTB bit0 = 1 (the boot default) writes to $C000-$FFFF hit ROM
        ; and are lost.
        cmp #$C0                     ; (A = seg_hi from the copy above)
        bcc ?lp
        inc under_rom
                                      ; 2026-09-22 (rapidus-bus-timing): (zp) has no
?lp     jsr get_byte                 ;   index cycle, so no dummy read of the target
        ldx under_rom                ;   before the store ($8000-$BFFF is slow); Y
        bne ?uram                    ;   was always 0 anyway
        opt c+
        sta (zp_dest)
        opt c-
        jmp ?tail
?uram   sta byte_tmp
        sei                          ; IRQs off -- and SEI is NOT enough: NMI is
        lda #0                       ;   unmaskable, so the VBI has to be turned
        sta $D40E                    ;   off AT ANTIC (NMIEN). With the ROM out,
                                     ;   an NMI fetches its vector from RAM at ...
        lda $D301                    ; PORTB: OS ROM out (bit0 = 0)
        and #$FE
        sta $D301
        lda byte_tmp
        opt c+
        sta (zp_dest)                ; (Y is no longer loaded: see ?lp)
        opt c-
        lda $D301                    ; ... and straight back in
        ora #$01
        sta $D301
        lda #$40                     ; VBI back on: SIO's timeout counters are
        sta $D40E                    ;   decremented by the OS VBI, and the next
                                     ;   get_byte may call SIOV
        cli
?tail   lda zp_dest
        cmp end_lo
        bne ?next
        lda zp_dest+1
        cmp end_hi
        bne ?next                    ; (jmp: the under-ROM path pushed the loop
        jmp parse_seg                ;  body past a relative branch's reach)
?next   inc zp_dest
        bne ?lp
        inc zp_dest+1
        jmp ?lp

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
jmp_tgt jmp $0000               ; patched with the RUN address

jsr_tgt jmp $0000               ; patched, called via JSR (INIT handlers)

get_byte
        ldx buf_pos
        cpx #128
        bcc ?ok
        jsr read_sec
        ldx #0
?ok     lda SECBUF,x
        inx
        stx buf_pos
        rts

read_sec
        lda #$31
        sta $0300               ; DDEVIC (disk)
        lda #$01
        sta $0301               ; DUNIT (drive 1)
        lda #$52
        sta $0302               ; DCOMND (read sector)
        lda #$40
        sta $0303               ; DSTATS (receive)
        lda #<SECBUF
        sta $0304               ; DBUFLO
        lda #>SECBUF
        sta $0305               ; DBUFHI
        lda #$0F
        sta $0306               ; DTIMLO
        lda #128
        sta $0308               ; DBYTLO
                                      ; 2026-09-23: A is reloaded right below -> stz
        opt c+
        stz $0309               ; DBYTHI
        opt c-
        lda cur_sec
        sta $030A               ; DAUX1 (sector lo)
        lda cur_sec+1
        sta $030B               ; DAUX2 (sector hi)
?retry  jsr $E459               ; SIOV
        cpy #1                  ; Y = SIO status (1 = success). Retry on any error:
        bne ?retry              ;   a failed read leaves garbage -> corrupt XEX.
        inc cur_sec
        bne ?done
        inc cur_sec+1
?done   rts

; vec_rti -- the boot-time NMI/IRQ/BRK handler: clear the ANTIC latch, return.
; (RTCLOK does not tick from here; nothing before urom_init depends on it.)
vec_rti pha
        sta $D40F               ; any write resets the ANTIC NMI latch
        pla
        rti

; === Variables (kept OUT of the execution path -- see boot_init note) ===
cur_sec     dta a(4)            ; current sector (XEX starts at sector 4)
buf_pos     dta 128             ; position in buffer (128 = force first read)
seg_lo      dta 0
seg_hi      dta 0
end_lo      dta 0
end_hi      dta 0
under_rom   dta 0                   ; 1 = this segment loads under the OS ROM
byte_tmp    dta 0                   ; the byte being stored there

; HARD limit: the loader must not reach into its own sector buffer (see SECBUF).
    .if * > SECBUF
        ert 'boot loader grew into SECBUF -- raise SECBUF or shrink the loader'
    .endif
; ... and all of it has to fit in the 3 boot sectors the OS loads.
    .if * > $0700 + 3*128
        ert 'boot loader > 3 sectors -- raise the sector count in the boot header'
    .endif
