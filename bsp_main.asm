;--------------------------------------------------------------
; RAM BUDGET: 0 B free, biggest contiguous block 0 B.
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
; DOOM BSP engine for Atari XL/XE + VBXE  --  M0: VBXE bring-up
;--------------------------------------------------------------
; First buildable milestone of the flat-shaded BSP DOOM port.
; Reuses the wolf3d VBXE approach (vbxe_regs.inc) but is a clean,
; minimal build: bring up a 160x100 LR framebuffer, install a
; grayscale palette, then exercise the vertical-span fill BCB
; (bcb_vline) that the wall/floor/ceiling renderer will use.
;
; No BSP yet -- this proves the framebuffer + blitter span fill
; before the renderer lands on top.
;
; Build:  mads -i:. bsp_main.asm -o:doom_bsp.xex   (see build.ps1)
;==============================================================


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
;
; THE ORDER OF THE DECLARATIONS BELOW IS DELIBERATE -- DO NOT SHUFFLE THEM.
;
; This block starts at $80 and does NOT fit in the zero page: it runs a few
; bytes past $FF, and MADS silently assembles every access to that tail as an
; ABSOLUTE address (one cycle and one byte more each), pointing into the stack
; page. Nothing warns about it. So the only real question is WHICH variables
; end up in the tail, and that is decided purely by the order here.
;
; 2026-07-29: the tail used to hold qs_p -- the quarter-square multiply output,
; which sits under every multiply the renderer does. That cost 196 absolute
; accesses across the engine, 40 of them inside a single umul16 call (~11 % of
; it). qs_p was moved up in front of the cold rc_m/rc_e/sin_sgn/cos_sgn, and
; the dead qs_x/qs_y/zp_i (declared, never referenced anywhere) were dropped to
; make room. The tail now costs 19 accesses instead of 196.
;
; HONEST NOTE ON THE PAYOFF: umul16 got ~11 % cheaper, but you cannot SEE the
; difference while playing -- the frame is dominated by draw_twall_col, not by
; the multiplies (tools/_verify_interleave.py prices the whole frame). This was
; done because it is free and because that tail living in the stack page is a
; latent bug, not because it makes the game feel faster.
;
; If you ever need bytes here, take them from the tail, never from the head,
; and re-run the check in tools/_verify_interleave.py to see what moved out.
;--------------------------------------------------------------
        org $80
zp_col      .ds 1                    ; current test column
zp_color    .ds 1
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
zback_hi    .ds 1                    ; back-buffer VRAM hi byte ($00=A, $01=B)
zp_cm       .ds 3                    ; -> the sector's COLORMAP row in Rapidus
                                     ;   SRAM (lights.asm; +2 = bank byte, low
                                     ;   byte and bank set once by lt_init, the
                                     ;   HIGH byte IS the light row). Read with
                                     ;   [zp_cm],y once per shaded surface.
mv_dx       .ds 2                    ; per-frame move delta x (signed16)
mv_dy       .ds 2                    ; per-frame move delta y
cols_open   .ds 1                    ; columns not yet closed (early-out counter)
frame_done  .ds 1                    ; 1 = all columns solid -> stop BSP walk

; --- player / frame ---
zp_px       .ds 2                    ; player pos (signed 16, world units)
zp_py       .ds 2
zp_ang      .ds 1                    ; BAM angle
zp_sin      .ds 2                    ; sin(ang) Q14 (signed 16)
zp_cos      .ds 2
zp_pz       .ds 2                    ; player eye Z (world units, signed 16)
loc_floor   .ds 2                    ; locate_floor result: sector floor at a point
cur_floor   .ds 2                    ; move_player: floor under the player pre-move (step-up ref)

; --- per-seg working set ---
zp_rx       .ds 2                    ; vertex - player (signed 16)
zp_ry       .ds 2
zp_X        .ds 2                    ; view-space (signed 16)
zp_Z        .ds 2
zp_X1       .ds 2
zp_Z1       .ds 2
zp_X2       .ds 2
zp_Z2       .ds 2
zp_xa       .ds 1                    ; left/right screen column
zp_xb       .ds 1
zp_sptr     .ds 3                    ; -> current seg record (SEG bank; +2 = bank,
                                     ;   set once by init_level. The seg table left
                                     ;   base RAM for Rapidus bank $03 on
                                     ;   2026-07-31 -- see map_syms.inc)
zp_vptr     .ds 3                    ; -> current vertex (EXT bank; +2 = bank)
zp_vidx     .ds 2                    ; vertex index
zp_rx1      .ds 2                    ; v1/v2 relative coords (for backface)
zp_ry1      .ds 2
zp_rx2      .ds 2
zp_ry2      .ds 2
zp_segcnt   .ds 2                    ; subsector seg count

; --- BSP walk (M2b) ---
zp_nid      .ds 2                    ; current node/subsector id (bit15=leaf)
zp_nodeptr  .ds 3                    ; -> current node record (EXT bank; +2 = bank
                                     ;   set by calc_nodeptr; textures.asm reuses
                                     ;   the low 2 B as its (zp),y emit pointer)
zp_near     .ds 2                    ; near child id
zp_far      .ds 2                    ; far child id
bsp_sp      .ds 1                    ; iterative-walk stack ptr (byte index into bsp_stack, step 2)
cx_a        .ds 2                    ; cross_pos inputs: sign(a*b - c*d)
cx_b        .ds 2
cx_c        .ds 2
cx_d        .ds 2
cx_p1       .ds 4                    ; saved first product (collision.asm aliases
                                     ;   coll_t onto it -- it is hot, it stays)

; --- math scratch (math.asm) ---
m_a         .ds 2
m_b         .ds 2
m_ma        .ds 4
m_prod      .ds 4
m_res       .ds 2
m_sign      .ds 1
m_den       .ds 2
m_quot      .ds 2
m_rem       .ds 2
m_xs        .ds 2                    ; screenx_signed result (unclamped signed col)
qs_p        .ds 2                    ; quarter-square 8x8 output (tips #2). FIRST
                                     ;   of the tail on purpose: 177 accesses,
                                     ;   40 of them inside umul16 -- it must not
                                     ;   be the one that spills past $FF.
                                     ;   (qs_x/qs_y are gone: qsmul reads the
                                     ;    operand bytes directly, so they were
                                     ;    declared but never referenced.)
; --- the tail below runs PAST $FF and is assembled as absolute addresses into
;     the stack page. That is deliberate now: the block starts at $80 and does
;     not fit, so the only question is WHICH variables pay the extra cycle per
;     access. These four are touched 19 times in the whole engine; qs_p, which
;     used to be here, is touched 177 times -- 40 of them inside umul16, which
;     sits under every multiply the renderer does.
rc_m        .ds 2                    ; recip_norm working mantissa (16-bit)
rc_e        .ds 1                    ; recip_norm exponent (signed)
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
        ; BASIC ROM off. Four segments live at $A000-$AEDF (palette + textab, the
        ; QSqr tables, the textured blit) and load_textures streams through $B000.
        ; With BASIC enabled that whole window is ROM, so those segments are lost
        ; and `jsr draw_twall_col` executes BASIC. Altirra hides this (it defaults
        ; BASIC off and auto-holds OPTION); real hardware does not. This must
        ; happen HERE, in the first-loaded segment, before those segments arrive.
        ; (PORTB/BASIC-off was tried here and backed out: it is the only change
        ;  outside the render path, and collision started failing right after it.
        ;  Re-add it only once the walk-through-walls regression is understood.)
        rts
.endp
        ini early_init

;==============================================================
; MAIN
;==============================================================
        org $2000
.proc main
        sei
        lda #0
        sta SDMCTL                   ; ANTIC off; VBXE drives the display
        sta NMIEN                    ; no VBI yet

        jsr detect_vbxe
        bcc ?ok
        jmp *                        ; no VBXE -> halt (error UI added later)
?ok
        jsr setup_memac
        jsr setup_xdl
        jsr setup_bcbs
        jsr recip_to_ext             ; the reciprocal tables -> Rapidus bank $01,
                                     ;   BEFORE load_level overwrites the map slot
                                     ;   they are staged in (memory_map.inc
                                     ;   RECIP_EXT). Nothing has divided yet.

        ; --- stream level 0 (E1M1) from the mounted ATR (D1:). SIOV waits on the
        ;     serial IRQ, so it needs the OS VBI running + IRQs enabled -- matches
        ;     the working wolf3d order: NMIEN=$40 + CLI around the load, then SEI
        ;     back to our IRQ-masked world. Done BEFORE setup_palette because the
        ;     palette (MAP_PAL) is inside the streamed map blob. ---
        lda #$40
        sta NMIEN                    ; OS VBI on (SIO needs the OS interrupt chain)
        cli                          ; IRQs on: SIOV needs them
        lda #0
        sta current_level            ; E1M1
        jsr load_hud                 ; MOVED UP FROM BELOW (2026-08-13): the
                                     ;   save/load picker draws its slot numbers
                                     ;   out of the status bar's own digits
                                     ;   (mn_slotdig -> hud_entry -> HUD_TAB,
                                     ;   "already in VRAM, already the right
                                     ;   red") -- and at the TITLE they were not,
                                     ;   because this call sat AFTER menu_boot.
                                     ;   LOAD GAME painted six slots out of
                                     ;   whatever VRAM $078000 happened to hold
                                     ;   (load.png, the noise column down the
                                     ;   middle). It costs nothing to hoist:
                                     ;   HUD_BANK0 is its own VRAM, nothing in
                                     ;   menu_boot or the level loaders writes
                                     ;   there, and the ROM + IRQs it needs are
                                     ;   already the state this cli just set.
        jsr menu_boot                ; title + main menu FIRST, then load_level_c.
                                     ;   It also runs load_sounds + snd_init
                                     ;   itself, once the title is on screen:
                                     ;   DOOM's menu has sound and music
                                     ;   (sfx_pstop/sfx_pistol, D_INTRO), and
                                     ;   none of that is map data -- so the
                                     ;   350 KB streams in BEHIND the picture
                                     ;   instead of before it.
                                     ;   Retargeting this call instead of adding
                                     ;   one costs the $2000 segment zero bytes --
                                     ;   it has none (check_xex caught +6).
                                     ; SIO first time + the SDRAM tee: a level
                                     ;   already streamed once reloads out of
                                     ;   Rapidus SDRAM with no drive at all
                                     ;   (diskio.asm, the SDRAM LEVEL CACHE)
        jsr load_textures            ; stream this level's .tex into VBXE VRAM (SIO, IRQs on)
        jsr load_sprites             ; ... then the billboard pixels (.spr)
        jsr wi_newlvl                ; ... then the things + sprite table + PLAYPAL
                                     ;     (wi_newlvl zeroes the level clock and
                                     ;      falls through to load_things -- wi.asm)
                                     ; (load_sounds ran inside menu_boot and
                                     ;  load_hud just above it: the menu needs
                                     ;  the mixer, and the save/load picker needs
                                     ;  the HUD digits -- see up there. Nothing
                                     ;  here writes HUD_BANK0, so the bar is
                                     ;  still streamed exactly once.)
        jsr load_palette             ; ... and the PLAYPAL slots, each read into the
                                     ;   staging buffer and installed straight into its
                                     ;   VBXE palette. MUST STAY LAST: every loader
                                     ;   above streams THROUGH that buffer
                                     ;   (MAP_PLAYPAL equ TEX_STAGE), so a loader after
                                     ;   it eats the palette -> the whole screen goes
                                     ;   to sample noise.
                                     ;   It installs THREE of them, into VBXE
                                     ;   palettes 1-3: palette 0 is what VBXE maps
                                     ;   plain GTIA colours through and a warm
                                     ;   reset does not refill it, so writing it
                                     ;   left a black screen after RESET (see
                                     ;   FL_PAL_GOLD in memory_map.inc).
        sei                          ; back to our world (IRQ masked)
                                     ; (snd_init ran before menu_boot too, and
                                     ;  SIO has owned POKEY ever since -- the
                                     ;  loaders above leave AUDCTL and channels
                                     ;  3/4 theirs, exactly like a mid-game
                                     ;  load, so put the mixer back the way
                                     ;  snd_resume does after exit_level)
        jsr snd_pokey                ; AUDCTL 0, every voice idle, Timer-1 rate
        jsr urom_init                ; RAM vectors at $FFFA/$FFFE, so an NMI or the
                                     ;   sound IRQ taken while the OS ROM is banked
                                     ;   out lands in our handlers (underrom.asm)

        ; clear BOTH framebuffers once (palette idx 255 = black; 0 is a map colour).
        ; The frame loop no longer clears -- bg_fill only repaints the gaps -- so
        ; whatever is in a buffer at boot would otherwise show through.
        jsr clear_both               ; both buffers (colmerge.asm)

        ; (the VBXE display is already ON: menu.asm's mn_vbxe_on switches it on
        ;  the moment the title picture is in FRAME_A, thousands of frames
        ;  before this point. Doing it here as well was what kept the menu
        ;  BLACK -- and moving the block gave this segment 18 bytes back.)

        ; --- sanity: did the level actually stream from D1:? The counts are per
        ;     level now, so the check is the FORMAT VERSION word the packer stamps
        ;     into every header (pack_map.py, = 3). If it doesn't match, the data
        ;     ATR isn't mounted as D1: / SIO failed -> paint a solid RED screen and
        ;     halt, so a load failure is obvious instead of rendering garbage. ---
        lda MAP_LOAD+24
        cmp #3
        bne ?loadfail
        lda MAP_LOAD+25              ; (lda already sets Z -- no cmp #0 needed)
        beq ?loadok
?loadfail
        ; Diagnostic colour into VBXE palette 1, entry 254:
        ;   RED  = SIO error (sio_status != 1) -> ATR not mounted as D1: / SIO failed
        ;   BLUE = SIO ok but header wrong      -> loaded, but not a map (bad sectors/layout)
        lda #1
        sta VBXE_PSEL
        lda #254
        sta VBXE_CSEL
        lda sio_status
        cmp #1
        beq ?wrongdata
        lda #$FF                     ; RED
        sta VBXE_CR
        lda #0
        sta VBXE_CG
        sta VBXE_CB
        jmp ?fillerr
?wrongdata
        lda #0                       ; BLUE
        sta VBXE_CR
        sta VBXE_CG
        lda #$FF
        sta VBXE_CB
?fillerr
        lda #0
        sta zback_hi                 ; target FRAME_A (the displayed buffer)
        lda #254
        jsr clear_screen
        jmp *                        ; halt (see colour above)
?loadok

        ; --- double-buffer + interactive game loop ---
        ; Render to FRAME_B first; the XDL initially shows FRAME_A (from xdl_data).
        lda #$01
        sta zback_hi
        lda #$40                     ; enable OS VBI so RTCLOK3 ticks (swap_buffers)
        sta NMIEN

        ; --- OS ROM OUT, for the whole game loop ---------------------------------
        ; The map's SECTORS/SSECTORS/NODES live at $D800, i.e. under the ROM, so the
        ; renderer has to see RAM there. Nothing in the frame path needs the OS: the
        ; joystick is read straight off PIA ($D300), the keyboard off POKEY, and
        ; urom_init has already put OUR handlers in the RAM vectors at $FFFA/$FFFE,
        ; so the VBI (RTCLOK3, which swap_buffers waits on) and the Timer-1 sound IRQ
        ; both still work while the ROM is out. Only the SIO loaders need it back,
        ; and exit_level banks it in around them.
        ; This also retires the under-ROM trampolines: doors/triggers/seg_yoff are
        ; plain jsr now, which gives back the ~40 cycles each was paying -- seg_yoff
        ; alone ran ~140 times a frame.
        jsr rom_out
        jsr init_level               ; spawn point, doors, per-level state
        lda #0
        sta key_prev
        sta tex_flat                 ; boot with textures ON ('T' flips it;
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
                                     ;   am_kgate is read_keys unless the AUTOMAP
                                     ;   is up, in which case it jumps straight
                                     ;   to mn_key: '-'/'=' are the map's ZOOM
                                     ;   keys then (automap.asm)
?nokeys                              ; one KBCODE poll: SPACE = USE (door), 'T' = textures
        ldx #3                       ; remember where we were: the trigger test is
?olat   lda zp_px,x                  ; a line CROSSING (P_CrossSpecialLine).
        sta mv_ox,x                  ; zp_px..zp_py and mv_ox..mv_oy are both four
        dex                          ; consecutive bytes, so one loop does it in
        bpl ?olat                    ; 10 B instead of 20 -- the 10 pay for
                                     ; move_player's pk_x/pk_y latch.
        jsr move_player              ; walk forward/back (collision in stage 2)
        jsr frame_dt                 ; dt_vbl = VBLANKs this frame -> doors + lifts
        jsr check_triggers           ; crossed a lift line?
        jsr pf_frameb                ; animate it -- and let a floor that moved
                                     ;   carry what stands on it (mv_carry);
                                     ;   then the ball + the player's missile
                                     ;   (proj.asm wraps ball.asm's wrapper)
        jsr spr_pickup               ; take any item the player is standing on
        jsr update_doors             ; animate door ceilings
        jsr update_lights            ; p_lights.c: flicker/strobe/glow sectors
        jsr update_button            ; SR switch face flips back (BUTTONTIME)
        jsr update_pz                ; floor-follow: eye Z tracks the sector floor
                                     ;   (and it tail-calls update_damage +
                                     ;   update_door30 -- the $2000 segment has
                                     ;   no room left for their jsrs)
        jsr snd_dispatch             ; start the SFX the frame's events queued
                                     ; (no clear_screen here any more: bg_fill in
                                     ;  render_world paints just the gaps the BSP
                                     ;  walk leaves -- see colmerge.asm)
        jsr am_gate                  ; BSP walk + portals + per-column occlusion
                                     ;   -- or, on TAB, the AUTOMAP instead of
                                     ;   the world (automap.asm). Retargeting
                                     ;   this jsr rather than adding one is what
                                     ;   keeps the automap out of this segment,
                                     ;   which has no spare byte at all.
        jsr draw_hud_gate            ; the gun (R_DrawPlayerSprites, always) and
                                     ;   then the DOOM status bar: full repaint
                                     ;   only while
                                     ;   hud_dirty>0, else just face anim + FPS
        lda blk_dirty                ; a thing moved? then rebuild the blockmap
        beq ?noblk                   ;   for the next frame's move tests (the
        lda #0                       ;   player is not in the thing table, so his
        sta blk_dirty
        jsr blk_fill                 ;   own step never invalidates it)
                                     ;   65 stores and 255 pushes, ~6k cycles,
                                     ;   against the 30k a single monster step
                                     ;   used to pay sweeping the thing table
?noblk  jsr ai_look                  ; A_Look proper: one sight ray a frame from
                                     ;   an idle monster to the player, camera
                                     ;   nowhere in it (enemy_ai.asm)
        jsr ai_wake                  ; A_Look: whatever the player just SAW that is
                                     ;   a live monster starts chasing. Has to be
                                     ;   after render_world (it reads the vissprite
                                     ;   list that the BSP walk built) and before
                                     ;   the next frame overwrites it.
        jsr swap_buffers             ; wait VBLANK, flip
        lda EXIT_REQ                 ; the USE ray hit an EXIT line this frame
        beq ?loop
        jsr fin_exit                 ; the FINALE (f_finale.asm) on an ExM8, and
        jmp ?loop                    ;   for everything else one `jmp` on into
                                     ;   the INTERMISSION (wi.asm) -- which
                                     ;   tail-jumps to exit_level -> next level
                                     ;   (MAP_HNEXT).
                                     ;   Same three bytes the `jsr exit_level`
                                     ;   here used to be: exit_level's own block
                                     ;   is full to the byte, so the whole chain
                                     ;   had to be free at every call site
.endp

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
;   assembly-time equs baked from E1M1 (MAP_STARTX/Y/ANG/EYE); with more than one
;   level they have to come from the level that is actually in RAM.
;--------------------------------------------------------------
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

;--------------------------------------------------------------
; init_level -- everything that has to be reset for the map now in RAM. Called
;   once at boot and again after every exit switch.
;--------------------------------------------------------------
.proc init_level
        ldx #0                       ; things blob header: p_ss @5, p_things @7,
?cp     lda THINGS_BASE+5,x          ;   p_sprtab @9. Read HERE and not in
        sta th_ss,x                  ;   load_things: the blob is under the ROM,
        inx                          ;   which is banked IN while the loaders run.
        cpx #6
        bne ?cp
        lda #MAP_EXT_BANK            ; the long pointers' bank bytes: constant
        sta zp_ptr+2                 ;   for the whole game, set ONCE here.
        sta zp_vptr+2                ;   zp_nodeptr+2 = MAP_SEG_BANK is seeded
                                     ;   by load_level since 2026-08-18 (NODES
                                     ;   live with the segs now; this block is
                                     ;   full, load_level has the value in A)
                                     ; (zp_sptr+2 = MAP_SEG_BANK is set by
                                     ;   load_level instead: this block is the
                                     ;   128 B at $1B00 and it is FULL)
        jsr en_init                  ; spawnhealth -> TH_HP in bank $01. HERE: it
                                     ;   needs th_things (just cached) and the
                                     ;   zp_ptr bank byte (just set)
                                     ;   (and en_init tail-calls ai_reset, so
                                     ;   nothing chases yet either -- the $1B00
                                     ;   block has no room for a second jsr)
        jsr spawn_player
        jsr vw_apply                 ; view window: boot AND every level, so the
                                     ;   size the player picked survives an exit
        jsr init_doors               ; doors closed + the per-level door tables
        jsr wp_init                  ; the ready weapon back up, no raise. It KEEPS
                                     ;   wp_cur, so an exit carries the weapon over
                                     ;   (load_things keeps PSTATE too -- only the
                                     ;   cards are dropped, as G_PlayerFinishLevel)
        jsr fl_init                  ; no tint, and commit the normal palette once
        jsr mv_reset                 ; per LEVEL: the W1 "already fired" bitmap
        lda #0                       ;   and every floor slot parked (movers.asm)
        sta EXIT_REQ
        sta tw_scr                   ; scratch selector must be 0/1
        lda #DMG_VB                  ; a full grace period before the first
        sta dmg_timer                ;   nukage tic (update_damage)
        lda #>[MEMW+MEMW_CHA_OFF]    ; tw_chn holds the chain's WINDOW PAGE
        sta tw_chn                   ;   (eor in tw_chain_fire flips $97<->$9A)
        rts
.endp

;--------------------------------------------------------------
; exit_level -- the EXIT switch was used: load the level the header points at.
;   Mirrors the boot load order (SIO wants the OS interrupt chain + IRQs on).
;--------------------------------------------------------------
.proc exit_level
        jsr rom_in                   ; SIOV is in the OS ROM
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
                                     ;   map LOW to $4000, HIGH under the ROM --
                                     ;   out of the SDRAM cache when this level
                                     ;   already streamed once (death restarts
                                     ;   and backtracks skip the drive whole)
        jsr load_textures            ; this level's walls -> VBXE
        jsr load_sprites             ; ... billboard pixels
        jsr wi_newlvl                ; ... things + sprite table (+ THING_ALIVE reset)
                                     ;     and the level clock back to zero
        sei
        jsr rom_out                  ; back to the frame loop's world
        jmp snd_resume               ; POKEY back from SIO, then init_level
.endp
    .if * > UROM_TRAMP_END+1
        ert 'spawn_player/init_level/exit_level overran the $1B00 block'
    .endif
        org lvl_resume

        icl 'bsp_main_video.asm'
        icl 'diskio.asm'             ; ATR/SIO streaming: level, textures, sprites, things

        icl 'bsp_main_player.asm'
;==============================================================
; row_lo/row_hi -- row * SCREEN_WIDTH lookup (0..SCREEN_HEIGHT-1)
;==============================================================
row_lo
        :SCREEN_HEIGHT dta <[#*SCREEN_WIDTH]
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
        org HUDTAB_BASE              ; HUD_TAB: it outgrew the $A000 hole (119 B
HUD_TAB                              ; to mv_step at $A077) when the face frames
        ins 'build/assets/hud/hud.tab'   ; joined; data, so the slow freed
                                     ; vissprite-record area is fine.
                                     ; 0 STBAR, 1..10 digits, 11 '%', 12 arms,
                                     ; 13..15 keys, 16..18 look faces, 19 grin
    .if * > HUDTAB_END+1
        ert 'HUD_TAB overran HUDTAB_BASE..END (memory_map.inc)'
    .endif
        org mov_resume
hud_resume = *
        org HUDCODE_BASE
        icl 'hud.asm'
        icl 'fps.asm'                ; the 'F' frame-rate readout (was in hud.asm)
        org hud_resume                ; DOOM status bar (drawn after render_world)
        ; qs_tables (1 KB, page-aligned) relocated out of the $2000 segment: it
        ; used to flow here and reach $3FFF, but the textured-wall code grew the
        ; segment and pushed QSqrHiExt into $4000 -- where the map streams at
        ; runtime, corrupting umul16.
        ;
        ; 2026-08-11 pm -- IT SWAPPED HOMES WITH THE MIRROR, and the comment that
        ; used to sit here ("the absolute address is immaterial to speed") was
        ; the single most expensive sentence in the port. It is FALSE on a
        ; Rapidus: alt-src rapidus.cpp enables each SRAM window for
        ; kATMemoryAccessMode_AR -- Anticipated fetch AND Read -- so a table
        ; OUTSIDE a window is read over the 1.79 MHz chip bus even though the
        ; code doing the reading runs at 20 MHz. At $A400 (win2, the one block
        ; that can never be fast: MEMAC-A) QSqr was costing 21,586 reads/frame
        ; x ~0.51 us = 11.1 ms of a 181 ms frame -- measured, bench_fps.txt's
        ; DATA READS section. It is the table qsmul reads (umul16 four times
        ; over, plus paint_col's inline pair) AND half of what pt_dy reads; the
        ; mirror is read by pt_dy alone. So the hot half now lives in win1
        ; (fast) and the mirror takes the slow block. Same two 1 KB
        ; page-aligned blocks, exchanged -- the RAM map does not move a byte.
        org TEXIX_BASE               ; QSqr -> $6100-$64FF, win1 = FAST
        icl 'qs_tables.inc'          ; quarter-square LUTs for qs8/umul16 (tips #2)
        icl 'qs_mirror.inc'          ; ... + the MIRRORED half pt_dy multiplies
                                     ; with -- org's ITSELF to $A400 (win2), the
                                     ; block QSqr just left (paint.asm)
        ; recip.inc moved above the map (parked at $8600+ with the BCB templates)
        ; so the $2000 code segment has room below $4000.

        icl 'bsp_main_load.asm'
;==============================================================
; The reciprocal tables (SCALE_TAB/SX_TAB/INV_TAB) no longer LIVE in base RAM.
; They are 6 pages of pure lookup and they were the last contiguous 1.5 KB down
; here, so 2026-07-31 they moved to Rapidus bank $01 and the monster AI took
; their hole at $8700 (memory_map.inc RECIP_EXT / AI_BASE).
;
; The data still ships inside the XEX -- there is no new ATR slot and no new
; loader. It is assembled into the MAP SLOT, which is empty until the first
; load_level, and recip_to_ext copies it up before that happens. After the copy
; this whole segment is dead RAM that the level stream is free to overwrite.
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
?page   ldy #0
?byte   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        bne ?byte
        inc sp_ptr+1
        inc zp_ptr+1
        dex
        bne ?page
        jmp snd_to_ext               ; ...and the five per-SFX arrays ride the same
.endp                                ;   road (2026-08-25): staged in dead RAM,
                                     ;   copied to bank $01, read by snd_play with
                                     ;   `lda.l` from then on. It is a TAIL JUMP and
                                     ;   snd_to_ext is org'd well clear of here,
                                     ;   because everything behind recip_to_ext in
                                     ;   this segment FLOATS -- savegame's and
                                     ;   menu.asm's loaders assemble from `*` and
                                     ;   the fixed one behind them is only ~6 B
                                     ;   away. Growing this proc by the copy loop
                                     ;   overlapped them (check_xex caught it).

;--------------------------------------------------------------
; snd_to_ext -- recip_to_ext's tail: sound_tables.inc -> Rapidus bank $01.
;   Also the one-shot's other job, the automap's initial state, which used to
;   sit at the end of recip_to_ext and moved here with the tail jump.
;
;   Pages first, then the remainder: SNDX_STAGE is not page aligned (the hole it
;   lives in does not start on a page) and the reciprocal loop's `inc sp_ptr+1`
;   trick needs a zero low byte. zp_ptr+2 is still MAP_EXT_BANK from above.
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
?page   ldy #0
?byte   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        bne ?byte
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
?done   lda #0                       ; the AUTOMAP starts CLOSED. am_on is boot RAM
        sta am_on                    ;   otherwise, and a non-zero one would send
        sta am_karm                  ;   am_gate into mn_open with a garbage VRAM
        jmp b1_to_ext                ;   bank on the very first frame.
.endp
    .if * > SNDX_STAGE
        ert 'snd_to_ext ran into SNDX_STAGE (memory_map.inc)'
    .endif
        org sndcopy_resume

;--------------------------------------------------------------
; b1_to_ext -- snd_to_ext's tail: bank01.asm -> Rapidus bank $01.
;   The third and last of the boot one-shots (recip_to_ext -> snd_to_ext ->
;   here), same shape and the same bargain: the block ships in the XEX parked
;   at B1CODE_STAGE ($C000, the THINGS slot -- EMPTY in the shipped XEX, see
;   memory_map.inc) and is copied to B1CODE_OFF inside bank $01, after which
;   the slot goes back to being the things slot. The code RUNS there; what it
;   leaves at its old address is a 5-byte thunk (bank01.asm).
;
;   THE ROM HAS TO COME OUT for the read. main does not bank it out until
;   right before the game loop (underrom.asm) and this runs long before that,
;   so $C000 would read OS ROM and the bank would get 3 KB of kernel instead.
;   rom_out also enters native mode, which is why rom_in is a jmp: it has to
;   be the last thing that happens on the way back either way.
;
;   WHOLE PAGES, rounded up. The tail bytes are whatever the things slot holds
;   and they land past b1_code_end in 26 KB of free bank -- cheaper than the
;   remainder loop snd_to_ext needs, and nothing ever reads them.
;
;   Parked at B1COPY_BASE, the hole behind setup_chains in the map slot: this
;   is boot-only code, exactly like recip_to_ext at $4A00 two blocks down.
;--------------------------------------------------------------
b1copy_resume = *
        org B1COPY_BASE
.proc b1_to_ext
        jsr rom_out                  ; $C000 is RAM only with the ROM out
        lda #<B1CODE_STAGE
        sta sp_ptr
        lda #>B1CODE_STAGE
        sta sp_ptr+1
        lda #<B1CODE_OFF
        sta zp_ptr
        lda #>B1CODE_OFF
        sta zp_ptr+1
        lda #MAP_EXT_BANK
        sta zp_ptr+2
        ldx #[B1CODE_BYTES+255]/256
?page   ldy #0
?byte   lda (sp_ptr),y
        sta [zp_ptr],y
        iny
        bne ?byte
        inc sp_ptr+1
        inc zp_ptr+1
        dex
        bne ?page
        jmp rom_in                   ; ...and back to emulation mode with it
.endp
    .if * > B1COPY_END+1
        ert 'b1_to_ext outgrew B1COPY_BASE..END (memory_map.inc)'
    .endif
        org b1copy_resume

        icl 'savegame.asm'           ; SAVE/LOAD -- the menu's second overlay.
                                     ;   Same two-address org trick, same VRAM
                                     ;   window; only the bank differs.
        icl 'menu.asm'               ; the title + main menu ride the SAME staged
                                     ;   slot: they run once, before load_level_c,
                                     ;   and die with the rest of it. See the
                                     ;   header there -- zero permanent RAM, which
                                     ;   is the only way a menu fits at all now.
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
;   $B000-$B6FF  code           (this)
;   $B700-$BBFF  things blob    (streamed by load_things)
;   $BC00-$BCFF  vissprites     $BD00-$BFFF  clip snapshots
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
                                     ; (music.asm is NOT icl'd: the songs were
                                     ;  wired up on 2026-08-08 and taken back
                                     ;  out the same day -- the RMT renderings
                                     ;  sounded wrong. The file, its packer and
                                     ;  its two verifiers are intact; putting it
                                     ;  back is this icl plus the two tail calls
                                     ;  named in music.asm's header.)
        icl 'weapon.asm'             ; the player's weapon (p_pspr.c psprites).
                                     ; AFTER sound.asm: its WP_SFX table names the
                                     ; SFX_* ids sound_tables.inc defines.
        icl 'enemy_ai.asm'           ; p_enemy.c A_Look/A_Chase. Parked at $8700,
                                     ; the hole the reciprocal tables left when
                                     ; they moved to Rapidus bank $01. AFTER
                                     ; weapon.asm: wp_think calls ai_tick.
        icl 'infight.asm'            ; p_inter.c:904 -- actor->target, and the
                                     ; bullet that lands in the monster standing
                                     ; in the way. AFTER enemy_ai.asm: it calls
                                     ; ai_get/ai_put/ai_start/ai_hurt
        icl 'powerups.asm'           ; p_inter.c P_GivePower + the backpack: the
                                     ; third class of give_bonus (bonus ids 25-31)
        icl 'underrom.asm'           ; RAM under the OS ROM: vectors + trampolines
        icl 'automap.asm'            ; the automap (am_map.c): am_mark is resident
                                     ; (21 B in a 21 B hole), the drawing is an
                                     ; overlay in MENU_RUN's window. Both org
                                     ; their own homes, so this emits nothing at
                                     ; the ambient PC.
        icl 'wi.asm'                 ; the INTERMISSION (wi_stuff.c): three
                                     ; resident stubs in three holes, and the
                                     ; fourth MENU_RUN overlay. Same deal --
                                     ; every part orgs its own home.
        icl 'm_episode.asm'          ; WHICH EPISODE? (m_menu.c EpiDef) -- NEW
                                     ; GAME's submenu, an overlay of its own
                                     ; because the menu's window is 8 bytes from
                                     ; full. AFTER menu.asm: it uses KEY_RET and
                                     ; the generated menu_syms.inc, both of which
                                     ; that file brings in.
        icl 'f_finale.asm'           ; the end-of-episode FINALE (f_finale.c):
                                     ; the fifth and sixth MENU_RUN overlays.
                                     ; AFTER wi.asm -- fin_exit jumps into
                                     ; wi_exit for every ordinary level exit,
                                     ; and its stage 2 shares wi.asm's home in
                                     ; the map slot.
        icl 'pl_kick.asm'            ; P_DamageMobj's KICK for the PLAYER. LAST:
                                     ; forward-references oct_of, thr_comp, the
                                     ; thr_sx/thr_sy tables, skipx_ref, pl_latch
                                     ; and move_player's mp_slide/mp_nomove.

;==============================================================
; Map data is NO LONGER embedded -- it streams from the data ATR (D1:) at boot
; via load_level (see above). The XEX carries no $4000 segment now; load_level
; fills MAP_LOAD ($4000) from disk before the renderer runs. map_syms.inc still
; provides the per-section base addresses -- valid for EVERY level, because the
; packer pads every section to the shared capacity of the whole build (that is
; the point of pack_map.py's Caps). Build the disk with: .\build_atr.ps1
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
.proc mvg_arm
        lda #40                      ; deeper than any tree these maps build
        sta mv_dep
        lda MAP_HROOT                ; ...and hand back what the lda took
        rts
.endp
mv_dep  dta 0
    .if * > MVGUARD_END+1
        ert 'mvg_arm outgrew MVGUARD_BASE..END (memory_map.inc)'
    .endif

        org MVGUARD2_BASE
.proc mv_guard
        dec mv_dep
        beq ?bail                    ; 40 nodes deep and still no leaf: the tree
        jmp mv_sector.mvs_top        ;   is cyclic, so stop walking it
?bail   jmp mv_sector.mvs_leaf
.endp
    .if * > MVGUARD2_END+1
        ert 'mv_guard outgrew MVGUARD2_BASE..END (memory_map.inc)'
    .endif

        org SGFRESH_BASE
;--------------------------------------------------------------
; sg_fresh -- see SGFRESH_BASE in memory_map.inc. Tail-jumps into pl_reload, so
;   sg_go2's call site is the three bytes it always was.
;--------------------------------------------------------------
.proc sg_fresh
        ldx current_level
        lda #0
        sta lvl_res,x
        jmp exit_level.pl_reload
.endp
    .if * > SGFRESH_END+1
        ert 'sg_fresh outgrew SGFRESH_BASE..END (memory_map.inc)'
    .endif

        icl 'bank01.asm'             ; the procedures that RUN in Rapidus bank $01.
                                     ;   LAST on purpose: it ends on a two-address
                                     ;   `org` and everything it moved already has
                                     ;   a thunk at its old address.

        run main
