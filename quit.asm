quit_snd dta SFX_PLDETH, SFX_DMPAIN, SFX_POPAIN, SFX_SLOP
        dta SFX_TELEPT, SFX_POSIT1, SFX_POSIT3, SFX_SGTATK

;--------------------------------------------------------------
; quit_doom -- M_QuitResponse (m_menu.c:1080): the quit sound gametic picks,
;   ENDOOM and its prompt (console.asm), the reboot. Does not return.
;--------------------------------------------------------------
.proc quit_doom
        jsr mus_stop_t               ; 2026-10-20: the song off FIRST -- it plays from
                                     ;   the VBLANK and went on through ENDOOM and the
                                     ;   prompt; and quit_wait's snd_stop must follow a
                                     ;   mus_stop (music.asm mus_play)
        jsr quit_wait                ; the menu's select shot ends first
        lda RTCLOK3
        lsr
        lsr
        and #7                       ; (gametic >> 2) & 7
        tax
        lda quit_snd,x
        tax
        jsr snd_play_t
        jsr quit_wait                ; I_WaitVBL(105)
        jsl B1CODE_BASE+con_end_w1   ; I_Quit: ENDOOM, then the prompt: A = what
        tay                          ;   was typed, 0 DOOM / 4 EXIT (2026-10-20) --
        jmp quit_boot                ;   parked in Y (65816-style), X is blitw_hard's
.endp

;--------------------------------------------------------------
; quit_wait -- until the mixer is empty: POKMSK bit 0 is "a voice plays"
;   (snd_arm sets it, snd_disarm clears it).
;--------------------------------------------------------------
.proc quit_wait
?w      lda POKMSK_R
        lsr
        bcc ?done
        lda RTCLOK3                  ; a frame
?v      cmp RTCLOK3
        beq ?v
        bra ?w
?done   jmp snd_stop                 ; ... and the channels with it
.endp
