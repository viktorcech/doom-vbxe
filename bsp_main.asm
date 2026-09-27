;--------------------------------------------------------------
; bsp_main.asm -- DOOM BSP engine for Atari XL/XE + VBXE + Rapidus: main, the frame
;   loop, zero page and the file includes.  Build: build_atr.ps1
;--------------------------------------------------------------
        opt h+
        opt o+
        opt c+                       ; 65816: the port is Rapidus-only and VERTS+
                                     ; NODES live in SRAM bank $01 ([zp],y reads)

        icl 'vbxe_regs.inc'
        icl 'map_syms.inc'           ; section base addrs, shared by all NUM_LEVELS
        icl 'atr_layout.inc'         ; LVL_SEC1/LVL_SECTORS/NUM_LEVELS (make_atr_doom.py)
        icl 'weap_tables.inc'        ; WPF_* psprite frame ids + the VBXE regions
        icl 'hud_syms.inc'           ; VRAM of the HUD lumps HUD_TAB cannot reach
                                     ;   (it stops at 29 entries -- pack_hud.py)
                                     ; load_weapons streams them to (pack_weap.py)

;--------------------------------------------------------------
; Memory layout -- SINGLE SOURCE OF TRUTH (geometry, 6502 RAM, VBXE VRAM,
; MEMAC window). See memory_map.inc; keep all fixed addresses there.
;--------------------------------------------------------------
        icl 'memory_map.inc'

;--------------------------------------------------------------
; Zero page scratch
;--------------------------------------------------------------
        org $80
zp_col      .ds 1                    ; current test column (ZERO PAGE: midtex patches `stx zp_col` = $86 dp)
                                      ; 2026-09-22 zero page = the register file
pc_w        .ds 1                    ;   (tools/tests/drac_zpplan.py, bench accesses):
zp_tmp      .ds 2
zp_ptr      .ds 3                    ; general pointer; +2 = bank byte, valid only
                                     ;   for the [zp_ptr],y readers (coll_vptr,
                                     ;   read_ext set it; plain (zp),y ignores it)
zp_tsrc     .ds 2                    ; load_textures copy source pointer
zp_savex    .ds 1                    ; draw_vspan preserves caller's X
sp_ptr      .ds 2                    ; sprites.asm: -> thing record / prefix entry
sp_tab      .ds 2                    ; sprites.asm: -> sprite table entry
sp_clip     .ds 2                    ; sprites.asm: -> clip snapshot (walks the pool)
zp_mvsec    .ds 2                    ; movers.asm: sector being moved
mv_ss       .ds 2                    ; movers.asm: BSP descent scratch                    ; movers.asm: sector being moved (lives across frames)
                                      ; 2026-09-22 zero-page swap (drac_zpplan): the
pc_x        .ds 1  ; zp swap 2026-09-23 (drac_zpplan)
zp_cm       .ds 3                    ; -> the sector's COLORMAP row in Rapidus
                                     ;   SRAM (lights.asm; +2 = bank byte, low
                                     ;   byte and bank set once by lt_init, the
                                     ;   HIGH byte IS the light row).
                                      ; 2026-09-22 zero-page swaps (drac_zpplan): the
rs_tpr      .ds 2                    ;   painter's per-column words and bytes in; the
tw_wt       .ds 2                    ;   player's move deltas (not touched while the
rs_vsh      .ds 1                    ;   frame renders) and two once-a-column flags out
rs_texh_cur .ds 1

; --- player / frame ---
zp_px       .ds 2                    ; player pos (signed 16, world units)
zp_py       .ds 2
zp_ang      .ds 1                    ; BAM angle
                                      ; 2026-09-22 zero-page swap (6502-idioms): the floor
rs_yfacc    .ds 4                    ;   track accumulator in (3,467 accesses a frame, the
                                      ; 2026-09-22 zero-page swap (drac_zpplan)
rs_pegrow   .ds 2
loc_floor   .ds 2                    ; locate_floor result: sector floor at a point
                                      ; 2026-09-22 zero-page swap (drac_zpplan)
rs_nt16     .ds 2

; --- per-seg working set ---
zp_rx       .ds 2                    ; vertex - player (signed 16)
zp_ry       .ds 2
zp_X        .ds 2                    ; view-space (signed 16)
zp_Z        .ds 2
rs_t1       .ds 4  ; zp group swap 2026-09-23 (drac_zpplan)
                                      ; 2026-09-22 zero-page swap (6502-idioms): the ceiling
rs_ycacc    .ds 4                    ;   track accumulator in (3,102 accesses a frame);
zp_xa       .ds 1                    ; left/right screen column
zp_xb       .ds 1
zp_sptr     .ds 3                    ; -> current seg record (SEG bank; +2 = bank,
                                     ;   set once by init_level.
zp_vptr     .ds 3                    ; -> current vertex (EXT bank; +2 = bank)
                                      ; 2026-09-22 (6502-idioms "zero page is the register
rs_spa      .ds 2                    ;   file"): draw_clip/draw_span/paint_col's span rows
rs_ybcacc   .ds 4  ; zp group swap 2026-09-23 (drac_zpplan)
rs_t2       .ds 4  ; zp group swap 2026-09-23 (drac_zpplan)
                                      ; 2026-09-22: span end row in, zp_segcnt (35 x 3
rs_spb      .ds 2                    ;   accesses a frame) out to its D0 slot

; --- BSP walk (M2b) ---
                                      ; 2026-09-22: the column's clip window in (~5,000
rs_top      .ds 1                    ;   accesses a frame: draw_clip x4 a call, process_seg,
rs_bot      .ds 1                    ;   cm_test/cm_save read the PAIR as one word: keep
zp_nodeptr  .ds 3                    ; -> current node record (EXT bank; +2 = bank
                                     ;   set by calc_nodeptr; textures.asm reuses
                                     ;   the low 2 B as its (zp),y emit pointer)
                                      ; 2026-09-22: draw_clip's raw span rows in (written
rs_ra       .ds 2                    ;   16-bit 2-3x a column, read 6x a draw_clip call);
rs_rb       .ds 2                    ;   zp_near/zp_far (render_node, ~100 a frame) out
                                      ; 2026-09-22 zero-page swap (drac_zpplan): recip's
rc_e        .ds 1                    ;   exponent (814 a frame) in, bsp_sp (145) out
cx_a        .ds 2                    ; cross_pos inputs: sign(a*b - c*d)
cx_b        .ds 2
cx_c        .ds 2
cx_d        .ds 2
cx_p1       .ds 4                    ; saved first product (collision.asm aliases
                                     ;   coll_t onto it -- it is hot, it stays)

; --- math scratch (math.asm) ---
m_a         .ds 2
m_b         .ds 2
                                      ; 2026-09-22 zero-page swap (drac_zpplan): the
rs_rptf     .ds 1                    ;   rows-per-texel cell (one 32-bit cell: rptf,
rs_rpt      .ds 3                    ;   rpt lo, rpt hi, pad) in, m_ma out to D0
m_prod      .ds 4
rs_nb16       .ds 2  ; zp swap 2026-09-23 (drac_zpplan)
m_sign      .ds 1
m_den       .ds 2
m_quot      .ds 2
rs_texmask       .ds 2  ; zp swap 2026-09-23 (drac_zpplan)
m_xs        .ds 2                    ; screenx_signed result (unclamped signed col)
qs_p        .ds 2                    ; quarter-square 8x8 output (tips #2). FIRST
                                     ;   of the tail on purpose: 177 accesses,
                                     ;   40 of them inside umul16 -- it must not
                                     ;   be the one that spills past $FF.
; --- the tail below runs PAST $FF and is assembled as absolute addresses into
;     the stack page. That is deliberate now: the block starts at $80 and does
;     not fit, so the only question is WHICH variables pay the extra cycle per
;     access. These four are touched 19 times in the whole engine; qs_p, which
;     used to be here, is touched 177 times -- 40 of them inside umul16, which
;     sits under every multiply the renderer does.
rc_m        .ds 2                    ; recip_norm working mantissa (16-bit)
                                      ; 2026-09-22 zero-page swap (drac_zpplan)
bsp_sp      .ds 1                    ; iterative-walk stack ptr (byte index into bsp_stack, step 2)
sin_sgn     .ds 1                    ; frac-table: sign of frame sin (fmul_sin)
cos_sgn     .ds 1                    ; frac-table: sign of frame cos (fmul_cos)
; 2026-08-06: these three came DOWN from the head of the block to pay for
; zp_cm (lights.asm needs a 3-byte direct-page pointer for [zp_cm],y and there
; was no spare zero page). All three are touched once or twice a FRAME and only
; ever with plain lda/sta, which is exactly what may live past $FF; qs_p, the
; one that must not, keeps its place because the swap is byte-for-byte.
stick_save  .ds 1                    ; STICK0 snapshot for this frame
frame_ang   .ds 1                    ; angle the frac tables were last built for (tips #4 cache)
fps_last    .ds 1                    ; RTCLOK3 at the previous frame (FPS bar)
; 2026-09-21: four scratch cells that were `dta 0` beside their code -- under the
; ROM / in window 1, where every WRITE is a write-through onto the chip bus:
; 11..21 fast cycles a store instead of 1 (tools/tests/_probe_slowbus.py: stx
; tws_sx 112x, sta las_sh 106x, sta las_n 80x, stx ai_t 89x a frame, ~5,500
; cycles). Page 1 below the stack writes fast, like the cells above. All four
; are written before they are read, 8-bit, never indexed or offset.
tws_sx      .ds 1                    ; tws_anchor's column (colmerge.asm)
las_n       .ds 1                    ; look-ahead block: columns (1/2/4/8)
las_sh      .ds 1                    ; ... and its shift (0/1/2/3)
ai_t        .ds 1                    ; the thing being worked on (enemy_ai.asm)

; (per-frame arrays solid_arr/ytopc_arr/ybotc_arr + the rs_* render scratch are
;  defined in memory_map.inc -- the single source of truth.)

;==============================================================
; EARLY INIT (runs during XEX load) -- kill the ANTIC screen
;==============================================================
        org $0600
.proc early_init
        lda #0
        sta SDMCTL
        sta DMACTL
        ; BASIC ROM off.
        rts
.endp
        ini early_init

;==============================================================
; RAM CHECK (phaeron's review, 2026-08-31) -- parked at RAMCHK_BASE
;==============================================================
; Probe every linear-RAM bank the port uses, BEFORE anything streams into
; them: SRAM $01-$06 (map EXT + AI tables, SFX, segs, weapon master + CMAP),
; $08 (sprite coltabs) and the TOP bank of the SDRAM level cache (PRE1 end,
; atr_layout.inc), which spr_fget and every level revisit read at runtime.
; A configuration without that RAM boots, plays a while and then silently
; loses textures (phaeron measured ~4 MB as the visible floor) -- this turns
; that into one message at power-on.
;   Method per bank: pattern -> $BB:rc_twin (long store), INVERTED pattern ->
; the bank-0 twin (same 16-bit offset -- this block's own byte), long read
; back. A real bank answers the pattern; a partial-decode MIRROR of bank 0
; answers the twin's inverted value; open bus answers junk -- and the second
; pass swaps the patterns so a floating value cannot pass both. No restore
; needed: it runs before the loaders, so every scribble is streamed over.
;   The failure path calls NO OS -- the IOCBs at $0340 are engine RAM
; (RECLAIMED OS RAM, memory_map.inc) -- and needs no VBI: it programs ANTIC
; through the hardware registers (the shadows are dead, NMIEN is 0) and
; halts, the same policy as main's no-VBXE `jmp *`.
DLISTL  equ $D402                    ; ANTIC display-list pointer (hardware --
DLISTH  equ $D403                    ;   not SDLST: no VBI runs here)
CHBASE  equ $D409                    ; charset base ($E0 = the ROM font)
COLPF1  equ $D017                    ; mode-2 text luminance
COLPF2  equ $D018                    ; mode-2 background
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
.proc ram_check
        ldx #0
?bank   lda rc_banks,x
        beq ?ok                      ; table end -> every bank answered
        sta ?wr+3                    ; the bank byte of all four long operands
        sta ?rd+3                    ;   (self-mod; cold one-shot code)
        sta ?sv+3
        sta ?rs+3
        lda #$A5
        jsr ?probe                   ; pattern, the twin gets $5A...
        bne ?fail
        lda #$5A                     ; ...then swapped, so neither open bus
        jsr ?probe                   ;   nor a stale $A5 can pass twice
        bne ?fail
        inx
        bne ?bank                    ; table < 256 B: always taken
?ok     rts
?probe  pha
?sv     lda.l rc_twin                ; THE BANK'S OWN BYTE, saved (2026-09-14):
        sta rc_save                  ;   bank $01 already holds the staged engine
        pla                          ;   here (b1_stage_copy ran during the XEX
        pha                          ;   load), and the probe used to leave $5A
                                     ;   in it -- an `rts` of crush_things once
                                     ;   the code grew onto $2A6F (door crash)
?wr     sta.l rc_twin                ; -> $BB:rc_twin (bank byte patched)
        eor #$FF
        sta rc_twin                  ; bank-0 twin: a mirror now differs
        pla
?rd     cmp.l rc_twin                ; Z=1 iff the bank held the pattern
        php
        lda rc_save
?rs     sta.l rc_twin                ; ... and the bank's byte goes back
        plp
        rts
?fail   lda rc_banks,x               ; the failing bank -> two hex digits
        pha
        lsr @
        lsr @
        lsr @
        lsr @
        jsr ?hex
        sta rc_bnk
        pla
        and #$0F
        jsr ?hex
        sta rc_bnk+1
        lda #<rc_dl
        sta DLISTL
        lda #>rc_dl
        sta DLISTH
        lda #$E0
        sta CHBASE
        lda #$0E
        sta COLPF1                   ; white text ...
        stz COLPF2                   ; ... on black
        lda #$22
        sta DMACTL                   ; normal playfield + DL DMA on
        bra *                        ; halt (the no-VBXE path's policy)
?hex    cmp #10                      ; nibble -> SCREEN code ('0'=$10,'A'=$21)
        bcc ?dig
        adc #$16                     ; C=1: n+$17 = $21..$26 ('A'-'F')
        rts
?dig    adc #$10                     ; C=0: n+$10 = $10..$19 ('0'-'9')
        rts
.endp
; the SDRAM level cache's top bank: its last cached sector must exist
RC_TOP  equ [[PRE1_BASE+[PRE1_CNT*128]-1]>>16]
rc_banks dta $01,$02,$03,$04,$05,$06,MAP_EXT_BANK,$08,RC_TOP,SPRCOL_BANK,MUS_BANK0,0
                                     ; (+SPRCOL_BANK / MUS_BANK0 2026-09-13: both ...
rc_twin dta 0                        ; every probe's bank-0 twin byte
rc_save dta 0                        ; the probed bank's original byte
rc_dl   dta $70,$70,$70              ; 24 blank scans
        dta $42,a(rc_msg)            ; two mode-2 lines, one LMS
        dta $02
        dta $41,a(rc_dl)             ; JVB
rc_msg  dta d'LINEAR RAM MISSING AT BANK $'
rc_bnk  dta d'XX'
        dta d'.         '
        dta d'THIS PORT NEEDS A 16MB RAPIDUS.         '
    .if * <> rc_msg+80
        ert 'rc_msg is not 2 x 40 B -- each mode-2 line reads exactly 40'
    .endif
;--------------------------------------------------------------
; snd_vgo -- snd_play's stereo tail (X = voice*2): the trigger's pan into the
;   voice, reset it to CENTRE, arm the voice. Lives HERE because the sound
;   segment ends flush and this block still had the bytes (boot/infra hole).
;--------------------------------------------------------------
        .endseg
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc snd_vgo
        lda snd_side                 ; snd_setpan armed it; a trigger that did
        sta sv_side,x                ;   not = the centre, which is also what a
        stz snd_side                 ;   mono machine always hears
        lda #1
        sta sv_act,x                 ; 1 = phase 0 (hi nibble) next
        rts
.endp
        .endseg
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
;--------------------------------------------------------------
; snd_init2 -- the second (STEREO) POKEY out of init, from main at boot. On
;   mono both writes mirror onto POKEY1 with the values it holds anyway.
;--------------------------------------------------------------
.proc snd_init2
        lda #3
        sta $D21F                    ; SKCTL2: out of the init state
        stz $D218                    ; AUDCTL2: 64 kHz base, like AUDCTL
        rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)

;==============================================================
; MAIN
;==============================================================
        org $2000
.proc main
        sei
        ;lda #0
        stz SDMCTL                   ; ANTIC off; VBXE drives the display
        stz NMIEN                    ; no VBI yet

        jsr ram_check                ; every linear-RAM bank answers, or halt
                                     ;   with a message (parked block above) --
                                     ;   BEFORE anything streams into them
                                      ; 2026-09-22 idiom: snd_init2 inlined (-12)
        lda #3                       ; the STEREO POKEY out of init (harmless
        sta $D21F                    ;   SKCTL2: out of the init state
        stz $D218                    ;   AUDCTL2: 64 kHz base, like AUDCTL
                                     ;   mirror writes on a mono machine)

        jsr detect_vbxe
        bcs * 
        ;bra *                        ; no VBXE -> halt (error UI added later)
?ok
        jsr setup_memac
        jsr setup_xdl
        jsr setup_bcbs
        jsr urom_init                ; DRAC_PLAN 4a: our vectors, ROM out and native
                                     ;   BEFORE any load -- the loaders run like the
                                     ;   frame loop now (SIOV via siov_r)
        jsr recip_to_ext             ; the reciprocal tables -> Rapidus bank $01,
                                     ;   BEFORE load_level overwrites the map slot
                                     ;   they are staged in (memory_map.inc
                                     ;   RECIP_EXT).

    .ifdef ANTONIA2
        ; 2026-09-23 (drac030: VBXE palette 0 trashed on Antonia II only). CONF1
        ; ($FF:F001, Antonia2 1.4pl.pdf s.3) has VBENA = 0 by default: VBXE then
        ; decodes the 16-bit address only, so every store to $xx:D6xx in ANY bank --
        ; the read_sectors tee parks each sector in its SDRAM home, ~100 banks -- is
        ; a VBXE register write (PSEL/CSEL/CR/CG/CB). VBENA = 1 = the card's own
        ; bank-$00 decoder, VBADR = 0 = VBXE at $D6xx; bits 7-2 stay as they are.
        ; Native here, and before the first level load (the first tee).
        lda.l ANT_CONF1
        and #%11111100
        ora #%00000001
        sta.l ANT_CONF1
    .endif
        jsl B1CODE_BASE+con_init_w1  ; the PC text-mode startup goes UP first
        jsl B1CODE_BASE+con_msg_w1   ;   (2026-09-26): the script prints in
        jsl B1CODE_BASE+con_msg_w1   ;   ORDER -- the bar, then WAD + the box
        lda #$40
        sta NMIEN                    ; OS VBI on (SIO needs the OS interrupt chain)
        cli                          ; IRQs on: SIOV needs them
        lda #0
        sta current_level            ; E1M1 -- the operand above is what
                                     ;   tools/wad/test-levels.py patches
        jsr load_hud_t ; MOVED UP FROM BELOW (2026-08-13): the
                                     ;   save/load picker draws its slot numbers ...
        jsr menu_boot                ; title + main menu FIRST, then load_level_c.
        jsr load_textures_t ; stream this level's .tex into VBXE VRAM (SIO, IRQs on)
        jsr load_sprites_t ; ... then the billboard pixels (.spr)
        jsr wi_newlvl_t              ; ... then the things + sprite table + PLAYPAL
                                     ;     (wi_newlvl zeroes the level clock and ...
        jsr load_palette_t ; ... and the PLAYPAL slots, each read into the
                                     ;   staging buffer and installed straight into its
                                     ;   VBXE palette.
        sei                          ; back to our world (IRQ masked)
                                     ; (snd_init ran before menu_boot too, and ...
        jsr snd_pokey_t ; AUDCTL 0, every voice idle, Timer-1 rate
                                      ; DRAC_PLAN 4a: urom_init ran before the loads
                                     ;   sound IRQ taken while the OS ROM is banked
                                     ;   out lands in our handlers (underrom.asm)

        ; clear BOTH framebuffers once (palette idx 255 = black; 0 is a map colour).
        jsr clear_both_t ; both buffers (colmerge.asm)

        ; (the VBXE display is already ON: menu.asm's mn_vbxe_on switches it on
        ;  the moment the title picture is in FRAME_A, thousands of frames
        ;  before this point.

        ; --- sanity: did the level actually stream from D1:?
        lda MAP_LOAD+24
        cmp #3
        bne ?loadfail
        lda MAP_LOAD+25              ; (lda already sets Z -- no cmp #0 needed)
        beq ?loadok
?loadfail
        ; Diagnostic colour into VBXE palette 1, entry 254: ...
        lda #1
        sta VBXE_PSEL
        lda #254
        sta VBXE_CSEL
        lda sio_status
        cmp #1
        beq ?wrongdata
        lda #$FF                     ; RED
        sta VBXE_CR
        ;lda #0
        stz VBXE_CG
        stz VBXE_CB
        bra ?fillerr
?wrongdata
        ;lda #0                       ; BLUE
        stz VBXE_CR
        stz VBXE_CG
        lda #$FF
        sta VBXE_CB
?fillerr
        stz zback_hi                 ; target FRAME_A (the displayed buffer)
        lda #254
        jsr clear_screen_t
        bra *                        ; halt (see colour above)
?loadok

        ; --- double-buffer + interactive game loop ---
        ; Render to FRAME_B first; the XDL initially shows FRAME_A (from xdl_data).
        lda #$01
        sta zback_hi
        lda #$40                     ; enable OS VBI so RTCLOK3 ticks (swap_buffers)
        sta NMIEN

        ; --- OS ROM OUT, for the whole game loop ---------------------------------
        ; The map's SECTORS/SSECTORS/NODES live at $D800, i.e. under the ROM, so the
        ; renderer has to see RAM there.
        jsr rom_out_t
        jml B1CODE_BASE+game_loop    ; DRAC_PLAN 2b (2026-09-13): the frame loop
                                     ;   is bank-$01 code; main's prelude above
                                     ;   runs with the ROM in and stays in bank 0
.endp
        .segment B1                  ; DRAC_PLAN 2b: bank $01
.proc game_loop
        jsr init_level               ; spawn point, doors, per-level state
        stz key_prev
        stz tex_flat                 ; boot with textures ON ('T' flips it;
                                     ;   the byte is random RAM otherwise)
        lda zp_ang                   ; force the first frame_setup to build the frac tables
        eor #$01                     ;   (frame_ang != zp_ang -> tips #4 cache misses once)
        sta frame_ang

?loop   jsr read_input               ; snapshot stick + rotate angle
        jsr frame_setup              ; sin/cos for the (new) angle
        jsr pl_deadkey               ; dead? then the next key press restarts the
        lda pl_dead                  ;   level -- and read_keys is skipped outright,
        bne ?nokeys                  ;   or SPACE would ALSO reach try_use and play
        jsr am_kgate                 ;   the "nothing there" grunt at a corpse.
?nokeys                              ; one KBCODE poll: SPACE = USE (door), 'T' = textures
        rep #$20                     ; remember where we were: the trigger test is
        .LONGA ON                    ;   a line CROSSING (P_CrossSpecialLine). Two
        lda zp_px                    ;   word moves (zp_px..zp_py and mv_ox..mv_oy
        sta mv_ox                    ;   are both two adjacent words)
        lda zp_py
        sta mv_oy
        sep #$20
        .LONGA OFF
        jsr move_player              ; walk forward/back (collision in stage 2)
        jsr frame_dt                 ; dt_vbl = VBLANKs this frame -> doors + lifts
        jsr check_triggers           ; crossed a lift line?
        jsr pf_frameb                ; animate it -- and let a floor that moved
                                     ;   carry what stands on it (mv_carry); ...
        jsr spr_pickup               ; take any item the player is standing on
        jsr update_doors             ; animate door ceilings
        jsr update_lights            ; p_lights.c: flicker/strobe/glow sectors
        jsr update_button            ; SR switch face flips back (BUTTONTIME)
        jsr update_pz                ; floor-follow: eye Z tracks the sector floor
                                     ;   (and it tail-calls update_damage + ...
        jsr snd_dispatch             ; start the SFX the frame's events queued
                                     ; (no clear_screen here any more: bg_fill in ...
        jsr am_gate                  ; BSP walk + portals + per-column occlusion
                                     ;   -- or, on TAB, the AUTOMAP instead of
                                     ;   the world (automap.asm).
        jsr draw_hud_gate            ; the gun (R_DrawPlayerSprites, always) and
                                     ;   then the DOOM status bar: full repaint ...
        lda blk_dirty                ; a thing moved? then rebuild the blockmap
        beq ?noblk                   ;   for the next frame's move tests (the
        stz blk_dirty                ;   player is not in the thing table, so his
        jsr blk_fill                 ;   own step never invalidates it)
                                     ;   65 stores and 255 pushes, ~6k cycles, ...
?noblk  jsr ai_look                  ; A_Look proper: one sight ray a frame from
                                     ;   an idle monster to the player, camera
                                     ;   nowhere in it (enemy_ai.asm)
        jsr ai_wake                  ; A_Look: whatever the player just SAW that is
                                     ;   a live monster starts chasing.
        jsr swap_buffers             ; wait VBLANK, flip
        lda EXIT_REQ                 ; the USE ray hit an EXIT line this frame
        beq ?loop
        jsr fin_exit              ; the FINALE (f_finale.asm) on an ExM8, and
        bra ?loop                    ;   for everything else one `jmp` on into
                                     ;   the INTERMISSION (wi.asm) -- which
                                     ;   tail-jumps to exit_level -> next level
                                     ;   (MAP_HNEXT).
.endp
        .endseg

;--------------------------------------------------------------
; BANK-0 WRAPPERS for bank-$01 callers (DRAC_PLAN 2b, 2026-09-13).
;   `jsl X_w0` from bank $01 is `jsr X` here and back with rtl. These procs
;   stay in bank 0: what the ROM-in paths and the overlays share (the blitter
;   wait, clear_screen, snd_play, spr_fget, the BCB chain launcher), the
;   overlay entries (mn_open, hud_blit), the level restart and the finale.
;--------------------------------------------------------------
hud_blit_w0     jsr hud_blit
                rtl
hud_fire_w0     jsr hud_blit.hud_fire
                rtl
mn_open_w0      jsr mn_open
                rtl
snd_setpan_w0   jsr snd_setpan
                rtl
menu_run_w0     jsr MENU_RUN                 ; the automap overlay, from b1_amgate
                rtl
; bank-0 THUNKS for the runtime overlays: they run in bank 0 (MENU_RUN) and
; call procs that moved. `jsr X_t` = jsl to `jsr X` in bank $01, and back.
wp_wload_t      jsl B1CODE_BASE+wp_wload_w1
                rts
vw_apply_t      jsl B1CODE_BASE+vw_apply_w1
                rts
blk_fill_t      jsl B1CODE_BASE+blk_fill_w1
                rts
hud_entry_t     jsl B1CODE_BASE+hud_entry_w1
                rts
load_vertex_t   jsl B1CODE_BASE+load_vertex_w1
                rts
thing_alive_bit_t jsl B1CODE_BASE+thing_alive_bit_w1
                rts
        .segment B1
wp_wload_w1     jsr wp_wload
                rtl
vw_apply_w1     jsr vw_apply
                rtl
blk_fill_w1     jsr blk_fill
                rtl
hud_entry_w1    jsr hud_entry
                rtl
load_vertex_w1  jsr load_vertex
                rtl
thing_alive_bit_w1 jsr thing_alive_bit
                rtl
        .endseg
; ...and the other way: snd_resume's tail call into init_level (bank $01).
init_level_t    jsl B1CODE_BASE+init_level_w1
                rts
        .segment B1
init_level_w1   jsr init_level
                rtl
        .endseg
; DRAC_PLAN 4b (xbank_fix.py): bank-0 callers of code that moved to bank $01
blitter_wait_t  jsl B1CODE_BASE+blitter_wait_w1
                rts
clear_both_t    jsl B1CODE_BASE+clear_both_w1
                rts
clear_screen_t  jsl B1CODE_BASE+clear_screen_w1
                rts
exit_level_t    jsl B1CODE_BASE+exit_level_w1
                rts
load_hud_t      jsl B1CODE_BASE+load_hud_w1
                rts
load_level_c_t  jsl B1CODE_BASE+load_level_c_w1
                rts
load_palette_t  jsl B1CODE_BASE+load_palette_w1
                rts
load_sounds_t   jsl B1CODE_BASE+load_sounds_w1
                rts
load_sprites_t  jsl B1CODE_BASE+load_sprites_w1
                rts
load_textures_t jsl B1CODE_BASE+load_textures_w1
                rts
load_vram_t     jsl B1CODE_BASE+load_vram_w1
                rts
mn_sbox_t       jsl B1CODE_BASE+mn_sbox_w1
                rts
mn_sdraw_t      jsl B1CODE_BASE+mn_sdraw_w1
                rts
mn_togame_t     jsl B1CODE_BASE+mn_togame_w1
                rts
mus_play_t      jsl B1CODE_BASE+mus_play_w1
                rts
mus_reset_t     jsl B1CODE_BASE+mus_reset_w1
                rts
mus_stop_t      jsl B1CODE_BASE+mus_stop_w1
                rts
pl_restart_t    jsl B1CODE_BASE+pl_restart_w1
                rts
rom_in_t        jsl B1CODE_BASE+rom_in_w1
                rts
rom_out_t       jsl B1CODE_BASE+rom_out_w1
                rts
sg_fresh_t      jsl B1CODE_BASE+sg_fresh_w1
                rts
snd_init_t      jsl B1CODE_BASE+snd_init_w1
                rts
snd_play_t      jsl B1CODE_BASE+snd_play_w1
                rts
snd_pokey_t     jsl B1CODE_BASE+snd_pokey_w1
                rts
wi_newlvl_t     jsl B1CODE_BASE+wi_newlvl_w1
                rts
ptc_tail_t      jsl B1CODE_BASE+ptc_tail_w1
                rts
wi_pctof_t      jsl B1CODE_BASE+wi_pctof_w1
                rts
wi_div16_t      jsl B1CODE_BASE+wi_div16_w1
                rts
wi_mul100_w0    jsr wi_mul100                ; the intermission overlay's, for
                rtl                          ;   wi_pctof in bank $01
        .segment B1
wi_newlvl_w1    jsr wi_newlvl
                rtl
ptc_tail_w1     jsr ptc_tail
                rtl
wi_pctof_w1     jsr wi_pctof
                rtl
wi_div16_w1     jsr wi_div16
                rtl
spr_fcopy_w1    jsr spr_fcopy                ; wi.asm wi_bgfetch (stage 2) jsl-s
                rtl                          ;   straight here: no bank-0 thunk
blitter_wait_w1 jsr blitter_wait
                rtl
clear_both_w1   jsr clear_both
                rtl
clear_screen_w1 jsr clear_screen
                rtl
exit_level_w1   jsr exit_level
                rtl
load_hud_w1     jsr load_hud
                rtl
load_level_c_w1 jsr load_level_c
                rtl
load_palette_w1 jsr load_palette
                rtl
load_sounds_w1  jsr load_sounds
                rtl
load_sprites_w1 jsr load_sprites
                rtl
load_textures_w1 jsr load_textures
                rtl
load_vram_w1    jsr load_vram
                rtl
mn_sbox_w1      jsr mn_sbox
                rtl
mn_sdraw_w1     jsr mn_sdraw
                rtl
mn_togame_w1    jsr mn_togame
                rtl
mus_play_w1     jsr mus_play
                rtl
mus_reset_w1    jsr mus_reset
                rtl
mus_stop_w1     jsr mus_stop
                rtl
pl_restart_w1   jsr pl_restart
                rtl
rom_in_w1       jsr rom_in
                rtl
rom_out_w1      jsr rom_out          ; (b1_check wants the wrapper's jsr/rtl shape)
                rtl
sg_fresh_w1     jsr sg_fresh
                rtl
snd_init_w1     jsr snd_init
                rtl
snd_play_w1     jsr snd_play
                rtl
snd_pokey_w1    jsr snd_pokey
                rtl
        .endseg
; DRAC_PLAN 4b (xbank_fix.py): bank-$01 callers of code that stays in bank 0
siov_r_w0       jsr siov_r
                rtl
snd_fetch_w0    jsr snd_fetch
                rtl
snd_stop_w0     jsr snd_stop
                rtl

;==============================================================
; LEVEL ENTRY / EXIT -- parked in the 128 B block the under-ROM trampolines used
; to occupy ($1B00-$1B7F; see underrom.asm, they are gone now).
;   These MUST live below $C000: exit_level drives the SIO loaders, and those
;   call SIOV in the OS ROM, which the frame loop otherwise keeps banked OUT (the
;   map's HIGH region lives at $D800 -- see load_level / underrom.asm).
;==============================================================
lvl_resume = *
        org UROM_TRAMP_BASE

;--------------------------------------------------------------
; spawn_player -- player start from the loaded map's header. These were
;   level they have to come from the level that is actually in RAM.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc spawn_player
        ldx #3                       ; start_x, start_y: 4 B, header order == zp order
?l      lda MAP_HSX,x
        sta zp_px,x
        dex
        bpl ?l
        lda MAP_HSANG
        sta zp_ang
        lda MAP_HEYE                 ; eye Z = spawn sector floor + EYE
        sta zp_pz
        lda MAP_HEYE+1
        sta zp_pz+1
        rts
.endp
        .endseg

;--------------------------------------------------------------
; init_level -- everything that has to be reset for the map now in RAM. Called
;   once at boot and again after every exit switch.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc init_level
        lda #$FF                     ; vertex cache: force the stamp clear on the
        sta vc_frame                 ;   first frame (SDRAM is random at boot)
                                      ; 2026-09-22 idiom: count DOWN (a 6-byte copy, order-free)
        ldx #5                       ; things blob header: p_ss @5, p_things @7,
?cp     lda THINGS_BASE+5,x          ;   p_sprtab @9. Read HERE and not in
        sta th_ss,x                  ;   load_things: the blob is under the ROM,
        dex                          ;   which is banked IN while the loaders run.
        bpl ?cp
        lda #MAP_EXT_BANK            ; the long pointers' bank bytes: constant
        sta zp_ptr+2                 ;   for the whole game, set ONCE here.
        sta zp_vptr+2                ;   zp_nodeptr+2 = MAP_SEG_BANK is seeded
                                     ;   by load_level since 2026-08-18 (NODES ...
        jsr en_init                  ; spawnhealth -> TH_HP in bank $01. HERE: it
                                     ;   needs th_things (just cached) and the ...
        jsr spawn_player
        jsr vw_apply                 ; view window: boot AND every level, so the
                                     ;   size the player picked survives an exit
        jsr init_doors               ; doors closed + the per-level door tables
        jsr wp_init                  ; the ready weapon back up, no raise. It KEEPS
                                     ;   wp_cur, so an exit carries the weapon over ...
        jsr fl_init                  ; no tint, and commit the normal palette once
        jsr tst_cheats               ; mv_reset -- per LEVEL: the W1 "already
        ;lda #0                       ;   fired" bitmap and every floor slot parked
        stz EXIT_REQ                 ;   (movers.asm) -- then the test GUI's cheats
        stz tw_scr                   ; scratch selector must be 0/1
        lda #DMG_VB                  ; a full grace period before the first
        sta dmg_timer                ;   nukage tic (update_damage)
        lda #>[MEMW+MEMW_CHA_OFF]    ; tw_chn holds the chain's WINDOW PAGE
        sta tw_chn                   ;   (eor in tw_chain_fire flips $97<->$9A)
        rts
.endp

;--------------------------------------------------------------
; tst_cheats -- init_level's `jsr mv_reset`, plus the TEST GUI's cheats:
;   tst_cheat is 0 in every build, tools/wad/test-levels.py patches it in its
;   ATR copy (b0 = IDDQD, b1 = IDKFA).
;--------------------------------------------------------------
.proc tst_cheats
        jsr mv_reset
        lda tst_cheat
        lsr
        pha                          ; (C survives the push)
        bcc ?nk
        jsr dqd_give
?nk     pla
        lsr
        bcc ?out
        jmp cht_give
?out    rts
.endp
        .endseg
        .segment D0
tst_cheat dta 0
        .endseg

;--------------------------------------------------------------
; exit_level -- the EXIT switch was used: load the level the header points at.
;   Mirrors the boot load order (SIO wants the OS interrupt chain + IRQs on).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc exit_level
                                      ; 2026-09-22 (drac030 inline): rom_in is only an rts (DRAC_PLAN 4a)
        lda MAP_HNEXT                ; read BEFORE load_level overwrites the header
        cmp #NUM_LEVELS              ; past the last level on this ATR -> wrap to
        bcc ?lok                     ;   level 0. An out-of-range index streamed
        lda #0                       ;   the TEXTURE sectors as a "map" and the
?lok    sta current_level            ;   engine ran off into them (freeze @ $6137)
pl_reload                            ; pl_restart re-enters HERE: same level, and
        lda #$40                     ;   it has already banked the ROM in
        sta NMIEN
        cli
        jsr snd_sio                  ; snd_stop + SOUNDR off, then load_level_c:
                                     ;   map LOW to $4000, HIGH under the ROM -- ...
        jsr load_textures            ; this level's walls -> VBXE
                                      ; 2026-09-22 (drac030 inline): load_sprites is only an rts
        jsr wi_newlvl                ; ... things + sprite table (+ THING_ALIVE reset)
                                     ;     and the level clock back to zero
        sei
                                      ; 2026-09-22 idiom: rom_out inlined (-12)
        lda PORTB                    ; back to the frame loop's world
        and #$FE
        sta PORTB
        jmp snd_resume               ; POKEY back from SIO, then init_level
.endp
        .endseg
    .if * > UROM_TRAMP_END+1
        ert 'spawn_player/init_level/exit_level overran the $1B00 block'
    .endif
        org lvl_resume

        icl 'bsp_main_video.asm'
        icl 'diskio.asm'             ; ATR/SIO streaming: level, textures, sprites, things
        icl 'inflate816.asm'         ; DEFLATE depacker: the packed boot streams
        icl 'console.asm'            ; the PC DOOM text-mode startup, 1:1

        icl 'bsp_main_player.asm'
;==============================================================
; row_lo/row_hi -- row * SCREEN_WIDTH lookup (0..SCREEN_HEIGHT-1)
;==============================================================
                                      ; 2026-09-22 (6502-idioms: page-align hot tables):
rowlo_resume = *                      ;   paint_col/pt_span read row_lo,y/x ~4,000 times a
        org ROWLO_BASE               ;   frame, and at $21EF every row past 16 crossed a
row_lo                               ;   page (+1 a read); low byte + 200 <= $100 never does
        :SCREEN_HEIGHT dta <[#*SCREEN_WIDTH]
    .if [row_lo & $FF] + SCREEN_HEIGHT > $100
        ert 'row_lo crosses a page -- its low byte must be <= $100-SCREEN_HEIGHT'
    .endif
        org rowlo_resume
rowhi_resume = *
        org ROWHI_BASE               ; parked: the tail reached TWCHAIN ($2747)
row_hi
        :SCREEN_HEIGHT dta >[#*SCREEN_WIDTH]
    .if * > ROWHI_END+1
        ert 'row_hi outgrew ROWHI_BASE..END -- see memory_map.inc'
    .endif
        org rowhi_resume

;==============================================================
; renderer + math modules
;==============================================================
        org TRIGTAB_BASE             ; trig.inc used to sit here; it moved to
                                     ;   Rapidus bank $01 (TRIG_EXT) and rides the
                                     ;   RECIP_STAGE copy, which freed this whole
                                     ;   kilobyte for code.
        icl 'viewsize.asm'           ; '-'/'=' view window (math.asm calls vw_q34x)
        icl 'math.asm'
        icl 'renderer.asm'
mov_resume = *
        org MOVERS_BASE
        icl 'movers.asm'             ; walkover lifts / lowering floors
        icl 'ball.asm'               ; the imp's fireball (MT_TROOPSHOT reduced)
        icl 'proj.asm'               ; the player's visible rocket/plasma shot
                                     ; HUD_TAB lives in Rapidus bank $01 since
                                     ; 2026-08-30 (bank01.asm) -- 203 B of base
                                     ; RAM back.
        org mov_resume
hud_resume = *
        org HUDCODE_BASE
        icl 'hud.asm'
        icl 'fps.asm'                ; the 'F' frame-rate readout (was in hud.asm)
        icl 'strip.asm'              ; ...both at 320, on the view's SR strip
        icl 'melt.asm'               ; f_wipe.c's melt at 320 (wi.asm drives it)
        org hud_resume                ; DOOM status bar (drawn after render_world)
        ; qs_tables (1 KB, page-aligned) relocated out of the $2000 segment: it ...
        org TEXIX_BASE               ; QSqr -> $6100-$64FF, win1 = FAST
        icl 'qs_tables.inc'          ; quarter-square LUTs for qs8/umul16 (tips #2)
        icl 'qs_mirror.inc'          ; ... + the MIRRORED half pt_dy multiplies
        icl 'qs_words.inc'           ; ... + both as WORDS for paint_col's per-run
                                     ;   multiply (2026-09-22; org's itself under
                                     ;   the ROM at SQ1W_UROM/NSQ2W_UROM)
                                     ; with -- org's ITSELF to $A400 (win2), the ...

        icl 'bsp_main_load.asm'
;==============================================================
; The reciprocal tables (SCALE_TAB/SX_TAB/INV_TAB) no longer LIVE in base RAM.
; They are 6 pages of pure lookup and they were the last contiguous 1.5 KB down
; here, so 2026-07-31 they moved to Rapidus bank $01 and the monster AI took
; their hole at $8700 (memory_map.inc RECIP_EXT / AI_BASE).
;==============================================================
        org RECIP_STAGE
rc_stage
        icl 'recip.inc'              ; SCALE_TAB/SX_TAB (+INV) -- the labels in
                                     ;   here are the STAGING copy; the readers
                                     ;   use RCX_* in bank $01
        icl 'trig.inc'               ; ...and SIN/COS ride the same copy, read as
                                     ;   TRGX_* (frame_setup). recip.inc is a
                                     ;   whole number of pages, so trig.inc's
                                     ;   .align $100 changes nothing here.
rc_stage_end
    .if rc_stage_end - rc_stage != RECIP_BYTES
        ert 'recip.inc is not RECIP_BYTES long -- memory_map.inc / gen_tables.py'
    .endif

;--------------------------------------------------------------
; recip_to_ext -- the one-shot copy, called from main before the first level
;   load. Lives in the staging segment itself, so it costs no permanent RAM.
;   sp_ptr/zp_ptr are both free this early (nothing has rendered yet).
;--------------------------------------------------------------
.proc recip_to_ext
        lda #<rc_stage
        sta sp_ptr
        lda #>rc_stage
        sta sp_ptr+1
        lda #<RECIP_EXT
        sta zp_ptr
        lda #>RECIP_EXT
        sta zp_ptr+1
        lda #MAP_EXT_BANK
        sta zp_ptr+2
        ldx #RECIP_BYTES/256
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
?page   ldy #0                       ;   two bytes a pass (native: after urom_init)
        rep #$20
        .LONGA ON
?byte   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        iny
        bne ?byte
        sep #$20
        .LONGA OFF
        inc sp_ptr+1
        inc zp_ptr+1
        dex
        bne ?page
        jmp snd_to_ext               ; ...and the five per-SFX arrays ride the same
.endp                                ;   road (2026-08-25): staged in dead RAM,
                                     ;   copied to bank $01, read by snd_play with
                                     ;   `lda.l` from then on.

;--------------------------------------------------------------
; snd_to_ext -- recip_to_ext's tail: sound_tables.inc -> Rapidus bank $01.
;   Also the one-shot's other job, the automap's initial state, which used to
;   sit at the end of recip_to_ext and moved here with the tail jump.
;--------------------------------------------------------------
sndcopy_resume = *
        org SNDX_COPY
.proc snd_to_ext
        lda #<snd_stage
        sta sp_ptr
        lda #>snd_stage
        sta sp_ptr+1
        lda #<SNDX_EXT
        sta zp_ptr
        lda #>SNDX_EXT
        sta zp_ptr+1
        ldx #SNDX_BYTES/256          ; the whole pages...
        beq ?tail
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
?page   ldy #0                       ;   two bytes a pass (native: after urom_init)
        rep #$20
        .LONGA ON
?byte   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        iny
        bne ?byte
        sep #$20
        .LONGA OFF
        inc sp_ptr+1
        inc zp_ptr+1
        dex
        bne ?page
?tail   ldy #0                       ; ...and the bytes that do not fill one
?rem    cpy #SNDX_BYTES&$FF
        beq ?done
        lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        bne ?rem
                                      ; 2026-09-22 idiom: stz -- A is dead (b1_to_ext
?done   stz am_on                    ;   starts with rom_out_t's lda PORTB)
        stz am_karm                  ; the AUTOMAP starts CLOSED. am_on is boot RAM
        jmp b1_to_ext
.endp
    .if * > SNDX_STAGE
        ert 'snd_to_ext ran into SNDX_STAGE (memory_map.inc)'
    .endif
        org sndcopy_resume

;--------------------------------------------------------------
; b1_to_ext -- snd_to_ext's tail: bank01.asm -> Rapidus bank $01.
;--------------------------------------------------------------
b1copy_resume = *
        org B1COPY_BASE
.proc b1_to_ext
        ; 2026-08-31: table-driven -- FOUR blocks ride up now: both code
        ; stages (B1CODE, B1CODE2) and the two SQ2 masters, whose staged
        ; win2 pages die right here.
        jsr rom_out_t ; $C000 is RAM only with the ROM out
        ldx #0
?next   lda ?tab+0,x
        sta sp_ptr
        lda ?tab+1,x
        sta sp_ptr+1
        lda ?tab+2,x
        sta zp_ptr
        lda ?tab+3,x
        sta zp_ptr+1
        lda ?tab+4,x
        sta m_a                      ; pages left (math scratch, dead at boot)
        lda ?tab+5,x                 ; 2026-09-13: the row's OWN bank -- code
        sta zp_ptr+2                 ;   goes to B1CODE_BANK, the automap
                                     ;   overlay to the data bank (drac.txt:
                                     ;   bank $01 is the code bank)
                                      ; 2026-09-22 (65816-style: a byte sweep read as words):
?page   ldy #0                       ;   two bytes a pass (native: after urom_init)
        rep #$20
        .LONGA ON
?byte   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        iny
        bne ?byte
        sep #$20
        .LONGA OFF
        inc sp_ptr+1
        inc zp_ptr+1
        dec m_a
        bne ?page
        txa                          ; next 6-byte ?tab row
        clc
        adc #6
        tax
        cpx #12
        bcc ?next
        jmp rom_in_t ; ...and back to emulation mode with it
?tab    dta <AMOVL_STAGE, >AMOVL_STAGE, <AMOVL_EXT, >AMOVL_EXT, 5, MAP_EXT_BANK
        dta <B1CODE_STAGE, >B1CODE_STAGE, <HUDTAB_OFF, >HUDTAB_OFF, 1, MAP_EXT_BANK
                                     ; HUD_TAB's page (HU_TAB went 2026-09-24)
                                     ; (the SQ2 master rows are gone, 2026-08-31 ...
.endp
    .if * > B1COPY_END+1
        ert 'b1_to_ext outgrew B1COPY_BASE..END (memory_map.inc)'
    .endif
        org b1copy_resume

;--------------------------------------------------------------
; b1_stage_copy -- XEX INIT behind every chunk tools/split_b1.py stages:
;   B1STAGE = dst(16), len(16), payload -> copy the payload to $01:dst.
;--------------------------------------------------------------
stcopy_resume = *
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        .segment D0                  ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
.proc b1_stage_copy
        lda B1STAGE                  ; dst offset in bank $01
        sta zp_ptr
        lda B1STAGE+1
        sta zp_ptr+1
        lda #B1CODE_BANK
        sta zp_ptr+2
        lda #<[B1STAGE+4]            ; the payload
        sta sp_ptr
        lda #>[B1STAGE+4]
        sta sp_ptr+1
        ldy #0
        ldx B1STAGE+3                ; whole pages first
        beq ?tail
?page   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        bne ?page
        inc sp_ptr+1                 ; Y wrapped: both pointers one page on
        inc zp_ptr+1                 ;   (dst + len stays inside the bank:
        dex                          ;   B1SEG_BASE + B1SEG_LEN = $10000)
        bne ?page
?tail   cpy B1STAGE+2                ; then the remainder, Y = 0 on entry
        beq ?done
        lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        bne ?tail                    ; remainder < 256: the cpy ends it first
?done   rts
.endp
        .endseg
                                      ; DRAC_PLAN 3a: out of $8000-$BFFF (d0_mark.py)
        org stcopy_resume

        icl 'savegame.asm'           ; SAVE/LOAD -- the menu's second overlay.
                                     ;   Same two-address org trick, same VRAM
                                     ;   window; only the bank differs.
        icl 'menu.asm'               ; the title + main menu ride the SAME staged
                                     ;   slot: they run once, before load_level_c,
                                     ;   and die with the rest of it.
    .if * > RECIP_STAGE + $C00
        ert 'the staged slot (menu.asm) ran past the $4000-$4BFF map slot'
    .endif

;==============================================================
; Texture metadata. It used to be ONE level's table icl'd into the XEX at $A000
; (TEX_ADDR*/WMASK/H/DOM). With more than one level that cannot work, so the
; table travels IN the map blob (pack_map.py v3, MAP_TEXADDRLO..MAP_TEXDOM) and
; the level loader brings it along for free. Texture PIXELS still stream
; separately into VBXE VRAM ($020000).
;==============================================================
MAP_PLAYPAL equ TEX_STAGE            ; PLAYPAL is streamed into the staging buffer
                                     ; by load_palette (the 768 B it used to take
                                     ; here is movers.asm now)

;==============================================================
; sprites.asm -- billboards for the level's THINGS (items, decorations,
; monsters). Lives at $B000, which used to be the 4 KB SIO staging buffer: that
; moved into the per-frame array area, so this whole page block is now ours --
; the only hole big enough for the sprite renderer in one piece.
;==============================================================
        ; PINNED FAST (2026-08-11): the sprite pipeline runs per visible sprite
        ; per frame -- never move it back to win2 $8000-$BFFF (x11.2 fetch).
        org SPRITES_BASE
        icl 'sprites.asm'
        .if * > SPRONE_END+1
                ert 'the sprites flow tail overruns SPRONE_END (en_boomat at $75C0)'
        .endif

lights_resume = *
        org LIGHTS_BASE              ; sector light (p_lights.c) -- the thinkers
        icl 'lights.asm'             ; and lt_seg, in the 384 B the texture column
        org lights_resume            ; index reserve gave back (memory_map.inc)

        icl 'texcol.asm'             ; texture column de-dup: tex_getix lifts the
                                     ; index table out of the .tex blob, tex_setix
                                     ; points wall_src/low_src at a texture's array
        icl 'textures.asm'           ; textured wall blit: TEXBLIT segment ($1810,
                                     ; Rapidus-fast) + relocated setup/runs/blit

tw_seg_end = *                       ; watched by the .if below

;==============================================================
; sound.asm -- digitized DOOM SFX (POKEY Timer-1 DAC, samples in VBXE VRAM).
; Its own segment at SOUND_BASE ($0400): the OS cassette/user area, the only
; free contiguous block left (see the RAM-BUDGET block in memory_map.inc).
; Included AFTER tw_seg_end so it does not blunt the $B000 assert below.
;==============================================================
        icl 'sound.asm'
        icl 'music.asm'               ; D_INTER as a POKEY register stream.
        icl 'weapon.asm'             ; the player's weapon (p_pspr.c psprites).
                                     ; AFTER sound.asm: its WP_SFX table names the
                                     ; SFX_* ids sound_tables.inc defines.
        icl 'enemy_ai.asm'           ; p_enemy.c A_Look/A_Chase. Parked at $8700,
                                     ; the hole the reciprocal tables left when
                                     ; they moved to Rapidus bank $01.
        icl 'infight.asm'            ; p_inter.c:904 -- actor->target, and the
                                     ; bullet that lands in the monster standing
                                     ; in the way.
        icl 'powerups.asm'           ; p_inter.c P_GivePower + the backpack: the
                                     ; third class of give_bonus (bonus ids 25-31)
        icl 'underrom.asm'           ; RAM under the OS ROM: vectors + trampolines
        icl 'automap.asm'            ; the automap (am_map.c): am_mark is resident
                                     ; (21 B in a 21 B hole), the drawing is an
                                     ; overlay in MENU_RUN's window.
        icl 'wi.asm'                 ; the INTERMISSION (wi_stuff.c): three
                                     ; resident stubs in three holes, and the
                                     ; fourth MENU_RUN overlay.
        icl 'm_episode.asm'          ; WHICH EPISODE? (m_menu.c EpiDef) -- NEW
                                     ; GAME's submenu, an overlay of its own
                                     ; because the menu's window is 8 bytes from
                                     ; full.
        icl 'f_finale.asm'           ; the end-of-episode FINALE (f_finale.c):
                                     ; the fifth and sixth MENU_RUN overlays.
        icl 'pl_kick.asm'            ; P_DamageMobj's KICK for the PLAYER. LAST:
                                     ; forward-references oct_of, thr_comp, the
                                     ; thr_sx/thr_sy tables, skipx_ref, pl_latch
                                     ; and move_player's mp_slide/mp_nomove.

;==============================================================
; Map data is NO LONGER embedded -- it streams from the data ATR (D1:) at boot
; via load_level (see above).
;==============================================================

;==============================================================
; HARD LIMIT: the textured-blit segment lives at TEXBLIT_BASE ($1810) since
; 2026-07-28 and must stay below CHECKBBOX_BASE ($1B00, doors.asm) -- one byte
; over and the door code is silently shot to pieces. (The old $B000/TEX_STAGE
; hazard is gone with the move; the TCOS frac pages own $A800-$AAFF now.)
;==============================================================
        .if tw_seg_end > CHECKBBOX_BASE
                ert 'textured-blit segment overruns the door code at $1B00'
        .endif

        org MVGUARD_BASE
;--------------------------------------------------------------
; mvg_arm / mv_guard -- a bound on mv_sector's BSP descent (memory_map.inc).
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mvg_arm
        lda #40                      ; deeper than any tree these maps build
        sta mv_dep
        lda MAP_HROOT                ; ...and hand back what the lda took
        rts
.endp
        .endseg
; (mv_dep moved to memory_map.inc, 2026-09-26: here it sat at $6B5D, in the
;  $4000-$7FFF write-through window -- mv_guard's dec wrote the chip bus per node)
    .if * > MVGUARD_END+1
        ert 'mvg_arm outgrew MVGUARD_BASE..END (memory_map.inc)'
    .endif

        org MVGUARD2_BASE
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc mv_guard
        dec mv_dep
        beq ?bail                    ; 40 nodes deep and still no leaf: the tree
        jmp mv_sector.mvs_top        ;   is cyclic, so stop walking it
?bail   jmp mv_sector.mvs_leaf
.endp
        .endseg
    .if * > MVGUARD2_END+1
        ert 'mv_guard outgrew MVGUARD2_BASE..END (memory_map.inc)'
    .endif

        org SGFRESH_BASE
;--------------------------------------------------------------
; sg_fresh -- see SGFRESH_BASE in memory_map.inc. Tail-jumps into pl_reload, so
;   sg_go2's call site is the three bytes it always was.
;--------------------------------------------------------------
        .segment B1                  ; DRAC_PLAN 2b: bank $01 (b1_mark.py)
.proc sg_fresh
        ldx current_level
        ;lda #0
        stz lvl_res,x
        jmp exit_level.pl_reload
.endp
        .endseg
    .if * > SGFRESH_END+1
        ert 'sg_fresh outgrew SGFRESH_BASE..END (memory_map.inc)'
    .endif

        icl 'bank01.asm'             ; the procedures that RUN in Rapidus bank $01.

        run main
