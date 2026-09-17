#!/usr/bin/env python3
"""bank_map -- what lives in every Rapidus linear-RAM bank, and whether any of
it collides.

tools/ram_map.py has covered the 6502's own 64 KB since the beginning. Bank $01
never had a map, and on 2026-08-20 that cost the port a real bug: PJSLOT_EXT
(the player's eight projectile contexts, 512 B) sat exactly on top of TH_TARG
and TH_THRS (the infighting target and threshold pages). Both comments in
memory_map.inc claimed "the first free page of the bank"; they were written
months apart and nothing in the build could tell them apart, because the
assembler never sees these -- they are equates the engine reaches with
`lda [zp_ptr],y` and a bank byte, not segments MADS lays out.

So this is the guard that did not exist. It reads the equates straight out of
memory_map.inc (and the generated .inc files the build icl's next to it),
prices every region from the same constants the engine uses, and fails if two
overlap or one runs past its bank.

2026-09-13 (DRAC_PLAN 0.2): every bank the port uses, not just $01 -- SRAM
$01-$07 and the SDRAM from $08 up (the level cache, the songs, the sprite
column tables). Same rule for all of them: a region is here only if the CPU
reaches it with LONG addressing. See the VBXE note above REGIONS.

    python tools/bank_map.py              # every bank + the summary table
    python tools/bank_map.py --bank 55    # one bank; hex, as the sources write
                                          #   it (01, 0x66, 66h; $66 from bash)
    python tools/bank_map.py --check      # ...and exit 1 on an overlap or an
                                          #   overrun in ANY bank
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# Where the equates come from. memory_map.inc first: a name defined twice
# (MADS .if branches) keeps its FIRST definition.
SOURCES = ['memory_map.inc', 'atr_layout.inc', 'map_syms.inc',
           'sound_tables.inc', 'music_syms.inc', 'weap_tables.inc',
           'atr_levels.inc']

BANK = 0x10000                       # every Rapidus bank is 64 KB
SRAM_LAST = 0x07                     # $01-$07 SRAM; $00 is base RAM (ram_map.py)
SDRAM_LO = 0x080000                  # atr_layout.inc PRE0_BASE: "SDRAM starts here"
SDRAM_TOP = 0xEFFFFF                 # memory_map.inc's SPRCOL_BANK ert: $EF:FFFF


# ---- a small, SAFE equate evaluator ------------------------------------------
# Numbers ($hex, %bin, decimal), symbols, + - * / << >> & |, unary - < >, and
# [ ] / ( ) grouping. Nothing is handed to Python's eval. MADS and C do not
# agree on where << >> & | sit against + - * /, so an expression that mixes
# the two families without brackets is refused instead of guessed at.
class Unresolved(Exception):
    pass


_TOK = re.compile(r'\$[0-9A-Fa-f]+|%[01]+|\d+|[A-Za-z_?@][\w?@]*'
                  r'|<<|>>|[-+*/&|()\[\]<>]')
_LEVELS = (('|',), ('&',), ('<<', '>>'), ('+', '-'), ('*', '/'))
_BITWISE = {'|', '&', '<<', '>>'}


def _tokens(text):
    out, pos = [], 0
    while True:
        while pos < len(text) and text[pos].isspace():
            pos += 1
        if pos == len(text):
            return out
        m = _TOK.match(text, pos)
        if not m:
            raise Unresolved(f'cannot read {text[pos:]!r}')
        out.append(m.group())
        pos = m.end()


class _Parser:
    def __init__(self, toks, lookup):
        self.t, self.i, self.lookup = toks, 0, lookup
        self.families = [set()]

    def peek(self):
        return self.t[self.i] if self.i < len(self.t) else None

    def take(self):
        tok = self.peek()
        self.i += 1
        return tok

    def parse(self):
        val = self.binary(0)
        if self.peek() is not None:
            raise Unresolved(f'unexpected {self.peek()!r}')
        return val

    def binary(self, lvl):
        if lvl == len(_LEVELS):
            return self.unary()
        val = self.binary(lvl + 1)
        while self.peek() in _LEVELS[lvl]:
            op = self.take()
            fam = self.families[-1]
            fam.add('bit' if op in _BITWISE else 'arith')
            if len(fam) > 1:
                raise Unresolved('mixes + - * / with << >> & | outside '
                                 'brackets -- MADS precedence is not C\'s')
            rhs = self.binary(lvl + 1)
            if op == '|':
                val |= rhs
            elif op == '&':
                val &= rhs
            elif op == '<<':
                val <<= rhs
            elif op == '>>':
                val >>= rhs
            elif op == '+':
                val += rhs
            elif op == '-':
                val -= rhs
            elif op == '*':
                val *= rhs
            else:
                if rhs == 0:
                    raise Unresolved('division by zero')
                val //= rhs
        return val

    def unary(self):
        tok = self.peek()
        if tok == '-':
            self.take()
            return -self.unary()
        if tok == '<':
            self.take()
            return self.unary() & 0xFF
        if tok == '>':
            self.take()
            return (self.unary() >> 8) & 0xFF
        return self.primary()

    def primary(self):
        tok = self.take()
        if tok is None:
            raise Unresolved('expression ends early')
        if tok in ('[', '('):
            self.families.append(set())
            val = self.binary(0)
            self.families.pop()
            if self.take() != {'[': ']', '(': ')'}[tok]:
                raise Unresolved('unbalanced brackets')
            return val
        if tok[0] == '$':
            return int(tok[1:], 16)
        if tok[0] == '%':
            return int(tok[1:], 2)
        if tok[0].isdigit():
            return int(tok)
        if tok[0].isalpha() or tok[0] in '_?@':
            return self.lookup(tok)
        raise Unresolved(f'unexpected {tok!r}')


class Symbols:
    """`NAME equ <expr>` and `NAME = <expr>` at column 0, evaluated lazily."""
    _DEF = re.compile(r'^([A-Za-z_]\w*)\s+(?:equ\b|=)\s*(.*)$')

    def __init__(self, files):
        self.expr, self.where = {}, {}
        for fn in files:
            path = os.path.join(ROOT, fn)
            with open(path, encoding='latin-1') as f:
                for ln, line in enumerate(f, 1):
                    m = self._DEF.match(line)
                    if not m:
                        continue
                    text = m.group(2).split(';', 1)[0].strip()
                    if text and m.group(1) not in self.expr:
                        self.expr[m.group(1)] = text
                        self.where[m.group(1)] = f'{fn}:{ln}'
        self.val, self.busy = {}, set()

    def __call__(self, name):
        if name in self.val:
            return self.val[name]
        if name not in self.expr:
            raise Unresolved(f'{name} is not an equate in {", ".join(SOURCES)}')
        if name in self.busy:
            raise Unresolved(f'{name} is defined in terms of itself')
        self.busy.add(name)
        try:
            val = self.eval(self.expr[name])
        except Unresolved as e:
            raise Unresolved(f'{name} ({self.where[name]}): {e}')
        finally:
            self.busy.discard(name)
        self.val[name] = val
        return val

    def eval(self, text):
        return _Parser(_tokens(text), self).parse()


S = Symbols(SOURCES)


def v(text):
    try:
        return S.eval(text)
    except Unresolved as e:
        sys.exit(f'bank_map: cannot price {text!r}: {e}')


# ---- the regions -------------------------------------------------------------
# HOW A RAPIDUS BANK WAS TOLD FROM A VBXE ADDRESS. The two share the same
# 24-bit spelling and several numbers on purpose, and memory_map.inc keeps both
# maps in one file. Only what the 65816 itself reads or writes with LONG
# addressing is here: `lda.l/sta.l abs24`, or `[zp],y` whose zp+2 was loaded
# with a bank byte (read_ext's ll_bank, zp_ptr+2, zp_sptr+2, zp_cm+2, ...).
# VBXE VRAM is never a CPU operand: it is reached through the MEMAC window at
# $9000 (`BANK_EN|chunk` into VBXE_BANK_SEL -- a 4 KB CHUNK number, not a bank)
# or written into a blitter BCB's SRC/DST address bytes. The collisions that
# look like one address and are not:
#   $010000  FRAC_EXT is bank $01 (bank01.asm `sta.l FRAC_EXT+TSIN_LO,x`);
#            FRAME_B is VRAM (zback_hi -> a BCB DST bank byte, WIPE_END).
#   $018000  RECIP_EXT is bank $01 (math/paint/seg_draw `lda.l RCX_*,x`);
#            POOL_VRAM / ARENA_SPR_BASE / FIN_ARENA / MENU_VRAM are VRAM
#            (`#[..>>16]` into BCB fields, MENU_BANK0/FIN_ARBANK = chunk $18).
#   $020000  SND_EXT is bank $02 (sound.asm `sf_rd lda.l SND_EXT`, bank byte
#            patched per voice); MENU_SRVRAM is VRAM (menu.asm stores
#            #[MENU_SRVRAM>>16] into BCB_DST_ADDR+2). MENU_SRXDL too.
#   $040000  WEAP_EXT is bank $04 (load_weapons: ll_bank = WEAP_EXT_BANK);
#            TITLE_VRAM is VRAM (automap.asm: BCB_SRC_ADDR+2).
#   $05xxxx  CMAP_EXT is bank $05 (lights.asm lt_init: #[CMAP_EXT>>16] ->
#            zp_cm+2, a long pointer); WI_VRAM $050000 is VRAM.
#   $06xxxx  SND region 1 is bank $06 (sound_tables.inc SND_RBK1, same lda.l);
#            FIN_VRAM $065000 and WIPE_START $068000 are VRAM.
#   $07xxxx  FRAME_C, WEAP_SLOT, HUD_VRAM, HUDV_*, HUD_TAB_HI $07 are all VRAM
#            (hud_blit BCBs). Rapidus bank $07 has NO tenant: "kept free for
#            RMT music" -- the songs went to SDRAM instead (MUS_BANK0).
#   $08xxxx  XDL_BANKA $08 / VRAM_XDL_A $008000 are VRAM chunk 8; PRE0_BASE
#            $080000 is SDRAM bank $08 (diskio.asm pre_map -> zp_ptr+2).
#   $27/$34  LVL_TEXSD_C / LVL_SPRSD_C are SDRAM (seg_draw adds tex_sdram and
#            paint.asm/tw_setup.asm read it `lda.l $000000,x` SMC; spr_fcopy's
#            sf_src) -- they are READS inside the cache, listed as VIEWS below.
# Also not RAM, and so not here: $FF0080 (boot.asm/xdl.asm `lda.l`, the Rapidus
# control register) and $FFF008/$FFF00C (udiv24a/umul16a, Antonia II mul/div).
class Region:
    def __init__(self, name, base, size, what, size_expr, note, span):
        self.name, self.base, self.size, self.what = name, base, size, what
        self.size_expr, self.note, self.span = size_expr, note, span

    @property
    def hi(self):
        return self.base + self.size - 1

    def src(self):
        return f'{self.size_expr}  ({self.note})' if self.note else self.size_expr

    def span_note(self, bank=None):
        b0, b1 = self.base >> 16, self.hi >> 16
        if b0 == b1:
            return ''
        return (f'  [spans ${b0:02X}:{self.base & 0xFFFF:04X}-'
                f'${b1:02X}:{self.hi & 0xFFFF:04X}]')


def R(name, base, size, what, note='', span=False):
    return (name, base, size, what, note, span)


B1 = 'MAP_EXT_BANK*$10000+'          # bank $01: read_ext's own bank (map EXT)
PAGE = '[256] per thing: thing index straight into Y of [zp_ptr],y'

# (name, 24-bit base, size, what it is, where the size comes from, may it span
# banks). Base and size are equate expressions, priced by the evaluator above
# from the same constants the engine indexes with, so a table that grows moves
# the map with it.
REGIONS = [
    # ---- bank $01 (MAP_EXT_BANK). The rows and their order are the original
    # map's. Reached with lda.l/sta.l ($010000+TH_* in proj.asm/ball.asm) and
    # [zp],y with zp+2 = MAP_EXT_BANK (infight/enemy_ai/spr_draw/savegame).
    # The map itself owns everything below DOOR_EXT: pack_map.py EXT_LIMIT is
    # what holds it there, and it is a per-level blob, not an equate.
    R('MAP (EXT)',  B1 + '0', 'DOOR_EXT', 'the streamed MAP blob (pack_map.py EXT_LIMIT)',
      'EXT_LIMIT stops at DOOR_EXT; what streams today is MAP_VERTS+MAP_EXT_SECT*128'),
    R('DOOR_EXT',   B1 + 'DOOR_EXT', '13*DOORS_NMAX', 'door arrays (13 x DOORS_NMAX)',
      "memory_map.inc's ert bound -- the DOOR_STATE..DOORSTAY chain is 12 arrays"),
    R('TH_TARG',    B1 + 'TH_TARG',  '256', 'mobj_t.target, per thing (infight.asm)', PAGE),
    R('TH_HPL',     B1 + 'TH_HPL',   '256', 'health, low', PAGE),
    R('TH_HPH',     B1 + 'TH_HPH',   '256', 'health, high', PAGE),
    R('TH_CELL',    B1 + 'TH_CELL',  '256', 'blockmap cell', PAGE),
    R('TH_BNEXT',   B1 + 'TH_BNEXT', '256', 'next thing in that cell', PAGE),
    R('TH_STATE',   B1 + 'TH_STATE', '256', 'death-animation row + 1 (0 = alive)', PAGE),
    R('TH_TICS',    B1 + 'TH_TICS',  '256', 'tics left in that row', PAGE),
    R('LOS_EXT',    B1 + 'LOS_EXT', 'LOS_BYTES', 'barrel line-of-sight grids',
      'LOS_NMAX*LOS_REC; load_los streams LOS_SECTORS*128, checked below'),
    R('BLK_HEAD',   B1 + 'BLK_HEAD', '64', 'first thing in each blockmap cell',
      'no equ: 8x8 cells, TH_CELL = ((y>>9)&7)<<3 | ((x>>9)&7)'),
    R('TH_WROW',    B1 + 'TH_WROW',  '256', 'walk row + 1 (0 = not chasing)', PAGE),
    R('TH_WST',     B1 + 'TH_WST',   '256', 'RUN state index', PAGE),
    R('TH_WTIC',    B1 + 'TH_WTIC',  '256', 'tics left in that state', PAGE),
    R('TH_DIR',     B1 + 'TH_DIR',   '256', 'movedir', PAGE),
    R('TH_MCNT',    B1 + 'TH_MCNT',  '256', 'movecount', PAGE),
    R('TH_KIND',    B1 + 'TH_KIND',  '256', 'the kind byte (en_kfill)', PAGE),
    R('TH_MODE',    B1 + 'TH_MODE',  '256', 'RUN chain or ATTACK chain + the mode bits', PAGE),
    R('TH_SEEN',    B1 + 'TH_SEEN',  '256', 'the cached sight answer', PAGE),
    R('TH_RAD',     B1 + 'TH_RAD',   '256', 'PIT_CheckThing radius', PAGE),
    # RECIP_EXT is a full 24-bit $018000 -- bank $01 by its own bank byte, NOT
    # POOL_VRAM (see the note above). The old map masked it to 16 bits.
    R('RECIP_EXT',  'RECIP_EXT', 'RECIP_BYTES', 'reciprocal + trig tables (RECIP+TRGX)',
      '6 RCX_* + 4 TRGX_* pages, lda.l tab,x'),
    R('PJSLOT_EXT', B1 + 'PJSLOT_EXT', 'PJ_NSLOT*PJ_SLSTR', "the player's missile contexts",
      'pj_slot: slot << 6 into zp_ptr'),
    R('DTAB_EXT',   B1 + 'DTAB_EXT', 'DTAB_BYTES', 'death/walk/attack/gib/idle rows + 10 headers',
      'pack_things DTAB_MAX; load_dtab streams DTB_SECTORS*128, checked below'),
    R('SNDX_EXT',   'SNDX_EXT', 'SNDX_BYTES', 'the five per-SFX arrays (sound_tables.inc)',
      'SNDX_N*5; sound.asm snd_play lda.l SFX_*_EXT,x'),
    # 2026-08-26: CODE, not data. bank01.asm's procedures are assembled at
    # B1CODE_OFF and copied here by b1_to_ext at boot; the 65816 executes them
    # in place at full speed (the fetch goes through the PROGRAM bank register
    # and the SRAM layer is FastBus -- see memory_map.inc). Priced at
    # B1CODE_MAX, not at what the block happens to hold today, because that is
    # the bound b1_to_ext and bank01.asm's own ert are written against.
    # (HUD_TAB, 29 x 6 B, is data INSIDE this block -- bank01.asm.)
    # 2026-09-13 (DRAC_PLAN step 2): the whole code bank is the MADS segment
    # B1 now -- bank01.asm first, laid out by MADS, bounded by B1SEG_LEN.
    R('B1 segment', 'B1CODE_BASE+B1SEG_BASE', 'B1SEG_LEN',
      'the bank-$01 code segment (split_b1.py stages it, b1_stage_copy copies it)',
      'MADS .segdef bound'),
    R('HUD_TAB',    'EXT_BASE+HUDTAB_OFF', '180',
      'status-bar lump rows (data; b1_to_ext copies the page up)', 'hud.tab 30 x 6 B'),
    # 2026-08-31: the frac-table pages, the SQ2 masters and the second code
    # block (see memory_map.inc's B1CODE2 banner for the whole story).
    R('TSIN_LO',    'FRAC_EXT+TSIN_LO', '6*256',
      'TSIN/TCOS frac tables (b1_build_frac writes, FMUL reads long)',
      'no equ: six pages TSIN_LO..TCOS_HI, sta.l FRAC_EXT+Txxx,x'),
    R('AMOVL_EXT',  'EXT_BASE+AMOVL_EXT', '5*256',
      'the automap overlay (b1_amopen serves it per frame)',
      'no equ: 5 pages, am_head lda.l EXT_BASE+AMOVL_EXT+$100..$400,x'),
    # SPRCOL_EXT and FTAB_EXT left this bank on 2026-08-21 (for $08, and on
    # 2026-09-09 for SPRCOL_BANK $66 above the SDRAM cache): see bank $66.
    R('FARENA_EXT', B1 + 'FARENA_EXT', '255*3', 'frame -> VRAM arena address (runtime)',
      'NFRAMES_MAX 255 (pack_things.py) x u24; spr_draw.asm id*3, arena_init clears 3 pages'),
    R('TH_THRS',    B1 + 'TH_THRS',  '256', 'mobj_t.threshold, per thing', PAGE),

    # ---- bank $02 + $06: the SFX blob, one wadsound REGION per bank. The
    # Timer-1 IRQ reads a sample `lda.l` with the voice's own bank byte
    # (sfx_bnk); load_sounds streams SND_RCHn 32-sector chunks from offset 0 of
    # SND_RBKn and a region never crosses its bank.
    R('SND_EXT',    'SND_RBK0*$10000', 'SND_RCH0*4096',
      'digitized SFX, region 0 (snd_irq lda.l)', 'sound_tables.inc chunks x 4 KB'),
    R('SND_RBK1',   'SND_RBK1*$10000', 'SND_RCH1*4096',
      'digitized SFX, region 1 (snd_irq lda.l)', 'sound_tables.inc chunks x 4 KB'),

    # ---- bank $03 (MAP_SEG_BANK): [zp_sptr],y per seg, lda.l SEGS_EXT/AMSEG_EXT
    # /SEGMID_EXT/MTX*_EXT, zp_nodeptr+2, lights.asm LT_TAB -- all INSIDE the
    # streamed blob, which is priced as the whole sector run load_level reads.
    R('MAP_SEGS',   'MAP_SEG_BANK*$10000+MAP_SEGS', 'MAP_SEG_SECT*128',
      'SEG blob: seg records, nodes, lights, automap + midtex tables',
      'map_syms.inc sectors x 128; diskio.asm load_level streams them'),
    R('PK_IDX',     'PK_IDX', '255', 'pickup list: thing index (sprites.asm lda.l PK_IDX,x)',
      'no equ: [255] -- pk_append indexes X = pk_n, one row per thing (a byte count)'),
    R('PK_ALO',     'PK_ALO', '255', 'pickup list: record address, low', 'as PK_IDX'),
    R('PK_AHI',     'PK_AHI', '255', 'pickup list: record address, high', 'as PK_IDX'),

    # ---- bank $04-$05: the weapon master + COLORMAP, one stream. load_weapons
    # steps ll_bank when ll_dst wraps, so this one legitimately spans.
    R('WEAP_EXT',   'WEAP_EXT', 'WEAP_BYTES',
      'weapon psprite master (wp_wload copies one weapon out)',
      'weap_tables.inc, pack_weap.py', span=True),
    R('CMAP_EXT',   'CMAP_EXT', 'CMAP_ROWS*256', 'DOOM COLORMAP (lights.asm zp_cm long ptr)',
      'lt_seg reads [CMAP_EXT + row*256 + colour]; 2 WEAP_CHUNKS behind the weapons'),
    R('SKY_EXT',    'SKY_EXT', 'SKY_BYTES', 'DOOM sky columns SKY1-3 + view column offsets',
      'seg_draw.asm sky_clip lda.l; pack_sky.py, the last WEAP_CHUNKS'),

    # ---- SDRAM, bank $08 up. The LEVEL CACHE: read_sectors tees every drive
    # sector of the two ranges into PREn_BASE + (sec - PREn_SEC)*128 (pre_map),
    # so its size is the sector count, whatever the sectors hold.
    R('PRE0_BASE',  'PRE0_BASE', 'PRE0_CNT*128',
      'SDRAM level cache range 0: level slots + texture/sprite pools',
      'atr_layout.inc sectors x 128; diskio.asm pre_map', span=True),
    R('PRE1_BASE',  'PRE1_BASE', 'PRE1_CNT*128',
      'SDRAM level cache range 1: things/dtab/los/sprcol, HUD, PAL, SFX, weapons',
      'atr_layout.inc sectors x 128; diskio.asm pre_map', span=True),
    R('MUS_BANK0',  'MUS_BANK0*$10000', 'MUS_CHUNKS*4096',
      'POKEY song streams (music.asm load_music; mus_p long ptr)',
      'atr_layout.inc chunks x 4 KB, 32 sectors a chunk; MUS_BYTES of it is song',
      span=True),
    R('WIMAP_BANK', 'WIMAP_BANK*$10000', 'WIM_CHUNKS*4096',
      'E2/E3 intermission world maps (load_music; wi_bgsel spr_fcopy sf_src)',
      'atr_layout.inc chunks x 4 KB; pack_wi.py wimaps.bin, one map per 32 KB'),
    R('SPRCOL_EXT', 'SPRCOL_BANK*$10000+SPRCOL_EXT', 'FTAB_EXT-SPRCOL_EXT',
      'T4 sprite column tables (spr_ctcol [zp],y)',
      'implied: pack_things.py FTAB_OFF = FTAB_EXT-SPRCOL_EXT, the coltab run pads to it'),
    R('FTAB_EXT',   'SPRCOL_BANK*$10000+FTAB_EXT', '255*8',
      'frame table (spr_fget [zp],y, zp+2 = SPRCOL_BANK)',
      'no equ: NFRAMES_MAX 255 x FTAB_ROW 8 (pack_things.py); spr_draw.asm id*8'),
    R('SPRC pad',   'SPRCOL_BANK*$10000+FTAB_EXT+255*8',
      'SPRC_SECTORS*128-[FTAB_EXT-SPRCOL_EXT]-255*8',
      'sector padding load_sprcol streams behind the FTAB',
      'the .sprcol slot is SPRC_SECTORS*128 from SPRCOL_EXT (sprcol_read)'),
]

# Reads the engine makes INSIDE a region, by design: not regions of their own,
# but each must land inside the SDRAM cache or the reader gets unmapped SDRAM.
VIEWS = [
    ('LVL_TEXSD_C', 'pool.tex home: seg_draw + tex_sdram, paint.asm lda.l SMC'),
    ('LVL_SPRSD_C', 'sprpool.bin home: spr_fcopy sf_src'),
]

# Invariants the map leans on. (lhs, op, rhs, fatal, why). A fatal one means a
# stream writes past the region priced for it -- an overrun, and --check fails.
CHECKS = [
    ('LOS_SECTORS*128', '<=', 'LOS_BYTES', True, 'load_los streams whole sectors into LOS_EXT'),
    ('DTB_SECTORS*128', '<=', 'DTAB_BYTES', True, 'load_dtab streams whole sectors into DTAB_EXT'),
    ('MAP_VERTS+MAP_EXT_SECT*128', '<=', 'DOOR_EXT', True, 'the map EXT stream stays under DOOR_EXT'),
    ('SPRCOL_EXT+SPRC_SECTORS*128', '<=', '$10000', True,
     'load_sprcol never steps ll_bank, so the slot must fit SPRCOL_BANK'),
    ('FTAB_EXT-SPRCOL_EXT+255*8', '<=', 'SPRC_SECTORS*128', False,
     'the .sprcol slot holds the coltabs AND the FTAB'),
    ('SND_RCH0+SND_RCH1', '==', 'SND_CHUNKS', False, 'the region rows add up to the SFX blob'),
    ('SND_RBK0*$10000', '==', 'SND_EXT', False, 'SND_EXT names region 0'),
    ('SNDX_N', '==', 'SFX_COUNT', False, 'SNDX_BYTES prices the SFX count wadsound.py wrote'),
    ('WEAP_EXT_BANK*$10000', '==', 'WEAP_EXT', False, 'load_weapons starts at offset 0 of WEAP_EXT_BANK'),
    ('WEAP_EXT+WEAP_BYTES', '<=', 'CMAP_EXT', False, 'the COLORMAP rides behind the weapon master'),
    ('WEAP_EXT+WEAP_CHUNKS*4096', '>=', 'CMAP_EXT+CMAP_ROWS*256', False,
     'the COLORMAP is inside the WEAP_CHUNKS stream'),
    ('CMAP_EXT+CMAP_ROWS*256', '<=', 'SKY_EXT', False, 'the sky columns ride behind the COLORMAP'),
    ('WEAP_EXT+WEAP_CHUNKS*4096', '>=', 'SKY_EXT+SKY_BYTES', True,
     'load_weapons streams the whole sky blob (sky_clip reads its offset table at the end)'),
    ('MUS_BYTES', '<=', 'MUS_CHUNKS*4096', False, 'the songs fit the chunks load_music streams'),
    ('PRE0_BASE+PRE0_CNT*128', '==', 'PRE1_BASE', False, 'cache range 1 starts where range 0 ends'),
    ('PRE1_BASE+PRE1_CNT*128', '==', 'PRE_END', False, 'PRE_END is the end of range 1'),
    ('PK_IDX/$10000', '==', 'MAP_SEG_BANK', False, 'PK_* are hard 24-bit; their ert assumes MAP_SEG_BANK'),
    ('FRAC_EXT/$10000', '==', 'MAP_EXT_BANK', False, 'FRAC_EXT is spelled as bank $01'),
    ('RECIP_EXT/$10000', '==', 'MAP_EXT_BANK', False, 'RECIP_EXT is spelled as bank $01'),
    ('SNDX_EXT/$10000', '==', 'MAP_EXT_BANK', False, 'SNDX_EXT is spelled as bank $01'),
]

# ATR blocks, to say WHICH sectors of the level cache a collision hits:
# (tag, first sector, sectors per unit, units). Per-level blocks name the level.
ATR_BLOCKS = [
    ('LVL', 'LVL_SEC1', 'LVL_SECTORS', 'NUM_LEVELS'),
    ('POOL', 'POOL_SEC', 'POOL_SECTORS', '1'),
    ('THG', 'THG_SEC1', 'THG_SECTORS', 'NUM_LEVELS'),
    ('DTB', 'DTB_SEC1', 'DTB_SECTORS', 'NUM_LEVELS'),
    ('LOS', 'LOS_SEC1', 'LOS_SECTORS', 'NUM_LEVELS'),
    ('SPRC', 'SPRC_SEC1', 'SPRC_SECTORS', 'NUM_LEVELS'),
    ('HUD', 'HUD_SEC1', 'HUD_CHUNKS*32', '1'),
    ('PAL', 'PAL_SEC1', 'PAL_SECTORS', 'PAL_COUNT'),
    ('SND', 'SND_SEC1', 'SND_CHUNKS*32', '1'),
    ('WEAP', 'WEAP_SEC1', 'WEAP_CHUNKS*32', '1'),
    ('MENU', 'MENU_SEC1', 'MENU_CHUNKS*32', '1'),
    ('FIN', 'FIN_SEC1', 'FIN_ATRCHUNKS*32', '1'),
    ('MUS', 'MUS_SEC1', 'MUS_CHUNKS*32', '1'),
    ('WIM', 'WIM_SEC1', 'WIM_CHUNKS*32', '1'),
    ('SAVE', 'SAVE_SEC1', 'SAVE_SECTORS', 'SAVE_SLOTS'),
]
CACHE = [('PRE0_BASE', 'PRE0_SEC', 'PRE0_CNT'), ('PRE1_BASE', 'PRE1_SEC', 'PRE1_CNT')]


def level_names():
    with open(os.path.join(ROOT, 'atr_layout.inc'), encoding='latin-1') as f:
        m = re.search(r'^;\s*LEVELS\s+(.*)$', f.read(), re.M)
    return m.group(1).split() if m else []


def sector_owner(sec, levels):
    for tag, first, stride, count in ATR_BLOCKS:
        f0, st, n = v(first), v(stride), v(count)
        if st > 0 and f0 <= sec < f0 + st * n:
            unit, off = divmod(sec - f0, st)
            if count == 'NUM_LEVELS':
                tag += ' ' + (levels[unit] if unit < len(levels) else f'#{unit}')
            elif n > 1:
                tag += f' #{unit}'
            return tag, off
    return '?', sec


def cache_text(lo, hi):
    """'ATR sectors a-b = SPRC E2M5 +37..+324' if lo..hi is level-cache bytes."""
    levels = level_names()
    for base, sec, cnt in CACHE:
        b0, s0, n = v(base), v(sec), v(cnt)
        if b0 <= lo and hi < b0 + n * 128:
            a, b = s0 + (lo - b0) // 128, s0 + (hi - b0) // 128
            (t0, o0), (t1, o1) = sector_owner(a, levels), sector_owner(b, levels)
            if a == b:
                return f'ATR sector {a} = {t0} +{o0}'
            if t0 == t1:
                return f'ATR sectors {a}-{b} = {t0} +{o0}..+{o1}'
            return f'ATR sectors {a}-{b} = {t0} +{o0} .. {t1} +{o1}'
    return ''


def build():
    regions, skipped = [], []
    for name, base, size, what, note, span in REGIONS:
        r = Region(name, v(base), v(size), what, size, note, span)
        (regions if r.size > 0 else skipped).append(r)
    return regions, skipped


# ---- the checks --------------------------------------------------------------
def order(r):
    return (r.base, -r.hi)            # a containing region sorts before its tenant


def collisions(regions):
    out, rs = [], sorted(regions, key=order)
    for i, a in enumerate(rs):
        for b in rs[i + 1:]:
            if b.base > a.hi:
                break
            out.append((a, b, b.base, min(a.hi, b.hi)))
    return out


def overruns(regions):
    out = []
    for r in regions:
        b0, b1 = r.base >> 16, r.hi >> 16
        if b0 == 0:
            out.append((r, 'starts in bank $00 -- base RAM, not a Rapidus bank'))
        if not r.span and b1 != b0:
            out.append((r, f'the bank ENDS at ${b0:02X}:FFFF and this runs '
                           f'{r.hi - (b0 << 16 | 0xFFFF)} B past it'))
        if b0 <= SRAM_LAST < b1:
            out.append((r, 'runs off the SRAM ($07:FFFF) into the SDRAM'))
        if r.hi > SDRAM_TOP:
            out.append((r, f'runs past the Rapidus SDRAM top ${SDRAM_TOP:06X}'))
    return out


def run_checks():
    ops = {'<=': lambda a, b: a <= b, '>=': lambda a, b: a >= b, '==': lambda a, b: a == b}
    bad = []
    for lhs, op, rhs, fatal, why in CHECKS:
        a, b = v(lhs), v(rhs)
        if not ops[op](a, b):
            bad.append((fatal, f'{lhs} {op} {rhs} fails (${a:X} vs ${b:X}): {why}'))
    return bad


def view_problems(regions):
    out = []
    for sym, what in VIEWS:
        addr = v(sym)
        home = [r for r in regions if r.name.startswith('PRE') and r.base <= addr <= r.hi]
        out.append((sym, addr, what, home[0] if home else None))
    return out


# ---- per-bank arithmetic -----------------------------------------------------
def pieces(regions):
    by_bank = {}
    for r in regions:
        b = r.base >> 16
        while True:
            lo, hi = max(r.base, b << 16), min(r.hi, b << 16 | 0xFFFF)
            by_bank.setdefault(b, []).append((lo, hi, r))
            if hi == r.hi:
                break
            b += 1
    return by_bank


def psort(pcs):
    return sorted(pcs, key=lambda p: (p[0], -p[1]))


def used_bytes(pcs):
    tot, cur = 0, -1
    for lo, hi, _r in psort(pcs):
        lo = max(lo, cur)
        if hi >= lo:
            tot += hi - lo + 1
            cur = hi + 1
    return tot


def largest_free(pcs, bank):
    best, cur = 0, bank << 16
    for lo, hi, _r in psort(pcs):
        best = max(best, lo - cur)
        cur = max(cur, hi + 1)
    return max(best, (bank << 16) + BANK - cur)


def overlaps(pcs):
    n, cur = 0, -1
    for lo, hi, _r in psort(pcs):
        if lo < cur:
            n += 1
        cur = max(cur, hi + 1)
    return n


# ---- output ------------------------------------------------------------------
SRC_INDENT = ' ' * 25 + '= '


def show_bank(bank, pcs, over):
    base = bank << 16
    kind = 'SRAM' if bank <= SRAM_LAST else 'SDRAM'
    print(f'Rapidus bank ${bank:02X} ({kind}, {BANK // 1024} KB)\n')
    if not pcs:
        print('  nothing the engine reaches with long addressing lives here\n')
        return
    cur, top, bad = base, None, 0
    for lo, hi, r in psort(pcs):
        if lo > cur:
            print('  $%04X-$%04X  %6d B  -- free --' % (cur - base, lo - 1 - base, lo - cur))
        print('  $%04X-$%04X  %6d B  %-12s %s%s'
              % (lo - base, hi - base, hi - lo + 1, r.name, r.what, r.span_note()))
        print(SRC_INDENT + r.src())
        if lo < cur:
            bad += 1
            end = min(hi, cur - 1)
            where = cache_text(lo, end)
            print('  %22s^^ COLLISION: $%04X-$%04X (%d B) is %s too%s'
                  % ('', lo - base, end - base, end - lo + 1, top.name,
                     f' -- {where}' if where else ''))
        if hi + 1 > cur:
            cur, top = hi + 1, r
    if cur < base + BANK:
        print('  $%04X-$FFFF  %6d B  -- free --' % (cur - base, base + BANK - cur))
    for r, why in over:
        if r.base >> 16 == bank:
            print(f'  ^^ {r.name}: {why}')
    print(f'\n  {BANK - used_bytes(pcs)} B free in the bank, largest run '
          f'{largest_free(pcs, bank)} B')
    print('  no collisions\n' if not bad else f'  {bad} COLLISION(S) in this bank\n')


def show_sdram(regions, views):
    sd = sorted((r for r in regions if r.base >= SDRAM_LO), key=order)
    print(f'Rapidus SDRAM ${SDRAM_LO:06X}-${SDRAM_TOP:06X} -- the 24-bit view '
          f'({(SDRAM_TOP + 1 - SDRAM_LO) >> 16} banks)\n')
    cur, top, spans = SDRAM_LO, None, []
    for r in sd:
        if r.base > cur:
            print('  $%06X-$%06X  %8d B  -- free --' % (cur, r.base - 1, r.base - cur))
        print('  $%06X-$%06X  %8d B  %-12s %s' % (r.base, r.hi, r.size, r.name, r.what))
        print(' ' * 29 + '= ' + r.src())
        if r.base < cur:
            end = min(r.hi, cur - 1)
            where = cache_text(r.base, end)
            print('  %26s^^ COLLISION: $%06X-$%06X (%d B) is %s too%s'
                  % ('', r.base, end, end - r.base + 1, top.name,
                     f'\n  {"":26}   {where}' if where else ''))
        spans.append((r.base, r.hi, r))
        if r.hi + 1 > cur:
            cur, top = r.hi + 1, r
    if cur <= SDRAM_TOP:
        print('  $%06X-$%06X  %8d B  -- free --' % (cur, SDRAM_TOP, SDRAM_TOP + 1 - cur))
    print('\n  reads inside the cache (views, not regions):')
    for sym, addr, what, home in views:
        where = cache_text(addr, addr)
        if home:
            print(f'    ${addr:06X}  {sym:12} {home.name}, {where} -- {what}')
        else:
            print(f'    ${addr:06X}  {sym:12} OUTSIDE the SDRAM cache -- {what}')
    used = used_bytes(spans)
    print(f'\n  {(SDRAM_TOP + 1 - SDRAM_LO - used) // 1024} KB of SDRAM free, '
          f'first free byte above everything ${cur:06X}\n')


def summary(by_bank):
    print('Summary: one line per bank (identical SDRAM banks in a row are folded)\n')
    print('  bank       kind    used B   free B  largest free  what')
    rows = []
    for b in range(1, (SDRAM_TOP >> 16) + 1):
        pcs = by_bank.get(b, [])
        names = []
        for _lo, _hi, r in psort(pcs):
            if r.name not in names:
                names.append(r.name)
        coll = overlaps(pcs)
        what = ('unused' if not names else ', '.join(names) if len(names) <= 3
                else f'{len(names)} regions')
        if coll:
            what += f'  -- {coll} COLLISION(S)'
        sig = ('SRAM' if b <= SRAM_LAST else 'SDRAM', used_bytes(pcs),
               BANK - used_bytes(pcs), largest_free(pcs, b), what)
        if rows and b > SRAM_LAST + 1 and rows[-1][2] == sig:
            rows[-1][1] = b
        else:
            rows.append([b, b, sig])
    for first, last, (kind, used, free, big, what) in rows:
        label = f'${first:02X}' if first == last else f'${first:02X}-${last:02X}'
        fold = f'  (x{last - first + 1})' if first != last else ''
        print(f'  {label:9}  {kind:5} {used:8} {free:8}  {big:12}  {what}{fold}')
    print()


def parse_bank(argv):
    arg = None
    for i, a in enumerate(argv):
        if a == '--bank':
            if i + 1 >= len(argv):
                sys.exit('bank_map: --bank needs a bank number, e.g. --bank 01 or --bank 0x66')
            arg = argv[i + 1]
        elif a.startswith('--bank='):
            arg = a.split('=', 1)[1]
    if arg is None:
        return None
    t = arg.strip().lower().lstrip('$')
    t = t[2:] if t.startswith('0x') else t[:-1] if t.endswith('h') else t
    try:
        bank = int(t, 16)
    except ValueError:
        sys.exit(f'bank_map: --bank {arg!r} is not a hex bank number')
    if not 1 <= bank <= SDRAM_TOP >> 16:
        sys.exit('bank_map: Rapidus linear RAM is banks $01-$EF '
                 '($00 is base RAM -- tools/ram_map.py)')
    return bank


def main(argv):
    only = parse_bank(argv)
    regions, skipped = build()
    by_bank = pieces(regions)
    coll = collisions(regions)
    over = overruns(regions)
    checks = run_checks()
    views = view_problems(regions)
    lost = [x for x in views if x[3] is None]
    fatal = [msg for is_fatal, msg in checks if is_fatal]

    if only is not None:
        show_bank(only, by_bank.get(only, []), over)
        mine = [c for c in coll if c[2] >> 16 <= only <= c[3] >> 16]
        elsewhere = len(coll) - len(mine) + len(over) + len(fatal) + len(lost)
        if elsewhere:
            print(f'({elsewhere} problem(s) outside bank ${only:02X} -- '
                  f'run without --bank)')
    else:
        for b in range(1, SRAM_LAST + 1):
            if b in by_bank:
                show_bank(b, by_bank[b], over)
            else:
                print(f'Rapidus bank ${b:02X} (SRAM): nothing maps here -- '
                      f'{BANK} B free\n')
        show_sdram(regions, views)
        for b in sorted(k for k in by_bank if k > SRAM_LAST):
            pcs = by_bank[b]
            whole = len(pcs) == 1 and pcs[0][1] - pcs[0][0] == BANK - 1
            if not whole:
                show_bank(b, pcs, over)
        summary(by_bank)
        for r in skipped:
            print(f'  (not mapped: {r.name} prices to {r.size} B -- {r.size_expr})')
        for is_fatal, msg in checks:
            print(f'  {"OVERRUN" if is_fatal else "note"}: {msg}')
        if not checks:
            print(f'  all {len(CHECKS)} consistency checks hold')

    problems = len(coll) + len(over) + len(fatal) + len(lost)
    if coll:
        print(f'\n{len(coll)} COLLISION(S) -- two regions share bytes:')
        for a, b, lo, hi in coll:
            where = cache_text(lo, hi)
            print(f'  ${lo:06X}-${hi:06X} ({hi - lo + 1} B): {a.name} and {b.name}'
                  + (f' -- {where}' if where else ''))
        print('Nothing in the build can see this on its own: these are equates '
              'the engine\nreaches through a bank byte, not segments the '
              'assembler lays out.')
    for r, why in over:
        print(f'OVERRUN: {r.name} -- {why}')
    for sym, addr, what, _home in lost:
        print(f'OUTSIDE THE CACHE: {sym} ${addr:06X} -- {what}')
    if not problems:
        print('\nno collisions')
    return 1 if problems and '--check' in argv else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
