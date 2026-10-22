; Each song's 24-bit address in Rapidus SDRAM, as an offset into the stream
; load_music depacks at MUS_BANK0 (music_syms.inc): mus_reset loads mus_p
; from these by song index.
mus_b0
        dta $00, $AE, $8B, $03, $86, $21, $47, $84, $AC, $F1, $C1, $6E, $5C, $B2, $24, $AC, $2A, $2B, $18, $3C, $3C, $E8, $DA, $F1, $AC, $84, $1D, $56, $C1
mus_b1
        dta $00, $E6, $EC, $3D, $A7, $46, $DA, $27, $70, $C9, $1B, $99, $1C, $7C, $39, $70, $AB, $11, $46, $D2, $D2, $2A, $95, $C9, $70, $27, $0D, $42, $1B
mus_b2
        dta MUS_BANK0+0, MUS_BANK0+0, MUS_BANK0+0, MUS_BANK0+1, MUS_BANK0+1, MUS_BANK0+2, MUS_BANK0+2, MUS_BANK0+3, MUS_BANK0+3, MUS_BANK0+3, MUS_BANK0+4, MUS_BANK0+4, MUS_BANK0+5, MUS_BANK0+5, MUS_BANK0+6, MUS_BANK0+3, MUS_BANK0+6, MUS_BANK0+7, MUS_BANK0+7, MUS_BANK0+7, MUS_BANK0+7, MUS_BANK0+8, MUS_BANK0+8, MUS_BANK0+3, MUS_BANK0+3, MUS_BANK0+3, MUS_BANK0+9, MUS_BANK0+9, MUS_BANK0+4
; snd_vmax while the song plays: 0 = the mixer keeps voice 1 (the song has
; voices 2-4), 2 = it keeps voices 1-2 (a level: the song has 3-4)
mus_vm
        dta 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
; the SECOND POKEY's AUDCTL while the song plays: $28 = its channels 3+4
; joined and clocked at 1.79 MHz -- the bass, a pure 16-bit tone
mus_ac
        dta $00, $00, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28, $28
