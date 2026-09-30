;--------------------------------------------------------------
; quit_boot.asm -- I_Quit's last step: the machine back in the OS's hands and
;   the ATR booted again. In the save overlay above SG_BUF, beside sg_go2.
;--------------------------------------------------------------

BOOT_RUN equ $0700                   ; the ATR's boot loader (boot.asm): boot_init
                                     ;   at +6, the sectors it takes at +1
;--------------------------------------------------------------
; quit_boot -- the machine back in the OS's hands, the boot loader read again
;   and entered. EVERY sector its header counts: the engine's arrays lie over
;   what the boot left of the loader. Entered native, as the engine runs.
;--------------------------------------------------------------
.proc quit_boot
        sei
        cld
        rep #$20
        .LONGA ON
        lda snd_old_irq              ; the OS's IRQ vector back (snd_init took
        beq ?os                      ;   it): the loader's SIO runs on the OS's
        sta VIMIRQ_R
?os     sep #$20
        .LONGA OFF
        jsr blitter_wait_t           ; the blitter owns VRAM until it stops
        stz NMIEN
        stz VBXE_VCTL                ; VBXE is a device, no OS entry resets it:
        stz VBXE_MEMAC_CTL           ;   the XDL and both windows off
        stz VBXE_MEMAC_B
        stz VBXE_BANK_SEL
        stz DMACTL
        sec                          ; emulation BEFORE the ROM covers the
        xce                          ;   native vectors
        lda #$FF
        sta PORTB
        lda #$40
        sta NMIEN                    ; the OS VBI and the IRQs: SIOV waits on
        cli                          ;   them
        lda #1
        sta ll_sec
        sta sg_cnt
        stz ll_sec+1
        lda #<BOOT_RUN
        sta DBUFLO
        lda #>BOOT_RUN
        sta DBUFHI
        jsr sg_read
        jsr sg_sio                   ; the first sector: the header
        bcs ?got
        lda BOOT_RUN+1
        dec @
        beq ?got                     ; (C = 0)
        sta sg_cnt
        jsr sg_sio
?got    php                          ; (C = a read failed)
        sei                          ; siov_r handed back the ENGINE's world,
        stz NMIEN                    ;   native and the ROM out: the OS's again
        sec                          ;   before a VBI can come
        xce
        lda #$FF
        sta PORTB
        lda #$40
        sta NMIEN
        plp
        bcs ?cold                    ; no drive: the OS's cold start
        jmp BOOT_RUN+6
?cold   jmp COLDSV
.endp
