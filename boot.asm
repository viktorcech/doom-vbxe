;--------------------------------------------------------------
; RAM BUDGET: 1118 B free, biggest contiguous block 268 B.
;   Full map: the generated RAM-BUDGET block at the top of memory_map.inc.
;   Print it any time with:  python tools/ram_map.py
;
; BEFORE YOU ADD CODE ANYWHERE, read this: some RAM looks free to MADS and is
; NOT. It carries no XEX segment, so the assembler places code there happily --
; and then something overwrites it at runtime, before the first frame:
;     $1000-$13FF  TEX_STAGE   -- the SIO staging buffer, every loader streams here
;     $4000-$4BFF  map slot    -- load_level streams the level here
;                              ($4C00-$85FF was the seg table until
;                               2026-07-31; it is ordinary RAM now)
;     $9000-$9FFF  MEMAC window-- writes go to VBXE, not to RAM
;     $1400-$14FF  bsp_stack   -- rebuilt every frame ($1500+ is CODE now)
;     $0700-$08FF  ATR boot loader, alive WHILE the XEX loads
; There is no error message. The symptom is a flat pink screen at boot. It has
; already cost one debugging session ($A800 blit segment crept past $B000).
;
; When a segment runs out of room, move a whole .proc out with `org` + absolute
; jsr -- that is why collision sits at $0900, check_bbox at $1B00 and tw_setup at
; $8D00 -- instead of letting the segment creep into the next thing.
;
; Guards, all three wired into build.ps1 / build_atr.ps1:
;   * the RESERVED list in tools/ram_map.py (check_xex.py enforces it)
;   * tools/check_xex.py                    (fails the build on any overlap)
;   * tools/ram_map.py --update             (regenerates these figures)
;--------------------------------------------------------------
;==============================================================
; DOOM BSP port -- custom ATR boot loader
;   The Atari OS loads this to $0700 from boot sectors 1-3, then it reads
;   doom_bsp.xex from raw ATR sectors (4+) via SIO and parses the standard
;   segmented XEX format (INIT $02E2 + RUN $02E0 vectors). Booting THIS way
;   means the OS has fully cold-started first -- the interrupt vectors
;   (VIMIRQ, serial IRQ handlers) are valid -- so the engine's own SIO level
;   streaming (load_level) works. Running the bare XEX without a clean OS boot
;   left VIMIRQ pointing into RAM (-> BRK on every IRQ -> SIO hang).
;
;   Verbatim approach from woll3d/src/boot.asm (which adapted doom2d's loader).
;==============================================================



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

        ; --- RAPIDUS FAST WINDOWS (2026-08-10) ------------------------------
        ; MCR $FF0080 (Rapidus FPGA; the EEPROM config is already loaded):
        ; bits0-3 = SLOW flags for $0000/$4000/$8000/$C000, bit5 = write-
        ; through, bit6 = I/O split ($D000-D7FF stays on the bus), bit7 = OS
        ; select. Clear slow1 ($4000-7FFF: map slot, ENTICK, DISKIO2, the
        ; PRELOAD code) and -- only with the I/O split on -- slow3 (RAM under
        ; the ROM: TWS anchors, CHECKBBOX, ENANIM). $8000-BFFF is left alone:
        ; MEMAC-A ($9000) lives there. Write-through stays ON and this runs
        ; BEFORE the XEX streams: the FPGA never back-fills its SRAM mirror,
        ; the mirror is built by the loader's writes passing through. Refs:
        ; alt-src rapidus.cpp SetMCR/UpdateSRAMWindows, rapidfirmware.s:641
        ; (default MCR $EF); profile bench/bench_fps.txt -- win1+urom carried
        ; 32% of the Rapidus frame at x11.2 fetch cost.
        opt c+
        lda.l $FF0080
        ora #$60                ; write-through on (the $EF default has it on)
                                ;   + I/O SPLIT ON (2026-08-11, was
                                ;   EEPROM-dependent): $D000-D7FF stays on the
                                ;   chip bus, which is exactly what makes a
                                ;   fast $C000 window safe -- so fast3 is
                                ;   unconditional now, not hostage to the menu
        and #$F5                ; fast1 ($4000-7FFF: ENTICK, TWMASK, SPRCROP)
                                ;   + fast3 (RAM under ROM: TWS anchors,
                                ;   CHECKBBOX, PICKUP). $8000-BFFF stays per
                                ;   menu; xdl_build later forces it slow
                                ;   (MEMAC-A at $9000 -- the one true no-go)
        sta.l $FF0080
        ; --- CMCR $FF0081 bit6 (2026-08-17): write-through OFF for $0000-3FFF.
        ; With MCR bit5 set, EVERY bank-0 write is routed through the slow
        ; write-through shadow (~0.56 us at 20 MHz): zero page, the STACK (two
        ; writes per jsr), the per-frame arrays -- alt-src rapidus.cpp
        ; UpdateSRAMWindows lines 906-914. CMCR bit6 (fastMem0) re-enables
        ; window 0's own fast write layer instead. Nothing reads the stale chip
        ; copy of $0000-3FFF: ANTIC DMA is off from early_init on (VBXE drives
        ; the display) and SIO buffers are CPU-written, CPU-read. QUIT's switch
        ; back to the 6502 reboots RapidOS from scratch, so stale chip RAM
        ; there is fine too.
        ; NOTE: rapidus.cpp's DumpStatus labels the bit "fastwrite3" while the
        ; IMPLEMENTATION applies it to $0000-3FFF -- an Altirra doc/impl
        ; mismatch. On the metal it is one of the two; either is a win, but
        ; A/B the fps on real hardware before trusting the Altirra number.
        lda.l $FF0081
        ora #$40
        sta.l $FF0081
        opt c-

        ; --- SAFETY NET (2026-08-10, the Rapidus black-screen boot) ---------
        ; Park RTI vectors in the RAM under the ROM BEFORE anything loads.
        ; Everything from here to urom_init (the whole XEX load, the title,
        ; the menu, the first level stream) runs without real RAM vectors, and
        ; ONE interrupt taken in any ROM-out moment reads $FFFA/$FFFE from
        ; virgin RAM: FF 00 -> PC $00FF -> a BRK loop and a black screen.
        ; The write happens with the ROM banked OUT -- the exact path the
        ; later vector fetch takes, so it cannot land anywhere else.
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
        lda seg_lo
        sta zp_dest
        lda seg_hi
        sta zp_dest+1
        ; --- $C000+ segments land in the RAM UNDER the OS ROM ---------------
        ; With PORTB bit0 = 1 (the boot default) writes to $C000-$FFFF hit ROM
        ; and are lost. So for those segments each byte is stored with the ROM
        ; banked out for the three instructions it takes. Boot-time only, so the
        ; per-byte cost is irrelevant; SIO in between always runs with the ROM
        ; back in. (The engine later uses that RAM for cold code -- see the
        ; UNDER-ROM section of memory_map.inc.)
        lda #0
        sta under_rom
        lda seg_hi
        cmp #$C0
        bcc ?lp
        inc under_rom
?lp     jsr get_byte
        ldy #0
        ldx under_rom
        bne ?uram
        sta (zp_dest),y
        jmp ?tail
?uram   sta byte_tmp
        sei                          ; IRQs off -- and SEI is NOT enough: NMI is
        lda #0                       ;   unmaskable, so the VBI has to be turned
        sta $D40E                    ;   off AT ANTIC (NMIEN). With the ROM out,
                                     ;   an NMI fetches its vector from RAM at
                                     ;   $FFFA, which at load time is still
                                     ;   uninitialised garbage -> PC into the
                                     ;   weeds (a BRK in zero page, typically).
                                     ;   The OS VBI runs every 20 ms and this
                                     ;   window is ~half of each byte's loop, so
                                     ;   without this the load ALWAYS died,
                                     ;   somewhere in the first $C000+ segment.
        lda $D301                    ; PORTB: OS ROM out (bit0 = 0)
        and #$FE
        sta $D301
        lda byte_tmp
        sta (zp_dest),y
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
        lda #0
        sta $0309               ; DBYTHI
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
