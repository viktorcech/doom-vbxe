#!/usr/bin/env python3
"""Render a map straight from the packed .bin (pack_map.py output) -- the
round-trip validator. If this image matches bsp_render.py (which reads the WAD),
the compact binary the Atari engine will load is byte-faithful.

It mirrors bsp_render's flat-shaded BSP renderer, but every field comes from the
packed records (indices + per-map palette), exactly as the 6502 will read them.

Usage:
  python render_packed.py                # E1M1 -> _pomocne/preview/E1M1_packed.png
  python render_packed.py E1M3 --shot
  python render_packed.py E1M1           # interactive
"""
import math
import os
import re
import struct
import sys

if '--shot' in sys.argv:
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
import pygame

_HERE = os.path.dirname(os.path.abspath(__file__))

_TOOLS = os.path.dirname(_HERE)          # tools/ -- the build half
MAPS_DIR = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'wadmaps')

W, H = 320, 200
H_W, H_H = W // 2, H // 2
FOCAL = H_W                       # FOV 90
ZNEAR = 1.0
EYE = 41
SCALE = 3
SKY_COLOR = (30, 30, 60)
NF_SUBSECTOR = 0x8000


def _map_syms():
    """The capacities + region split the blob was padded to (map_syms.inc, written
    by pack_map.py). Sections are padded to the CAPS of the whole level set, so a
    reader cannot derive their offsets from one level's header counts."""
    p = os.path.join(os.path.dirname(_HERE), 'map_syms.inc')
    out = {}
    for k, v in re.findall(r'^(\w+)\s+equ\s+(\S+)', open(p).read(), re.M):
        out[k] = int(v[1:], 16) if v.startswith('$') else int(v)
    return out


class PackedMap:
    def __init__(self, src):
        # src: a .bin path, or a bytes blob (e.g. pack_map.pack() output in memory,
        # used to stay in sync with the current WAD rather than a possibly-stale file)
        if isinstance(src, (bytes, bytearray)):
            d = bytes(src)
        else:
            with open(src, 'rb') as f:
                d = f.read()
        # Format v3 (2026-07-25, multi-level): compacted records + TWO regions.
        # The .bin is LOW (loaded at $4000) followed by HIGH (loaded at $D800,
        # under the OS ROM); every section is padded to the build's CAPACITIES, so
        # the reader has to walk the caps from map_syms.inc, not the header counts.
        # See tools/pack_map.py for the full layout.
        caps = _map_syms()
        (nv, nsec, nseg, nss, nnode, self.root,
         self.start_x, self.start_y, self.start_ang, ndoors,
         self.start_eye, nyoff, ntex, self.next_level,
         ver) = struct.unpack_from('<HHHHHHhhBBhHBBH', d, 0)
        assert ver == 3, f'map blob format v{ver}, this reader is v3'
        pp = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures', 'playpal.bin')
        with open(pp, 'rb') as f:
            d2 = f.read()
        self.pal = [tuple(d2[i * 3:i * 3 + 3]) for i in range(256)]

        # LOW  = header, SECTORS, TEXTAB, YOFF
        # HIGH = SSECTORS, DOORS         (streamed to $D800)
        # EXT  = VERTS, NODES, SEGOFF    (Rapidus SRAM bank $01, 2026-07-28)
        # SEG  = SEGS, AMSEG.., SEGMID, MTX, LIGHTS, NODES  (bank $03)
        #
        # EVERY SECTION BASE COMES OUT OF map_syms.inc, never out of a count or
        # a hand-copied constant. That is the only thing that has ever kept this
        # reader alive: the sections keep MOVING between the four regions, and
        # each move broke it SILENTLY --
        #   2026-07-25  VERTS left the LOW region for the EXT bank; the reader
        #               still read them straight after the header, so every
        #               vertex index ran off a list built from the wrong bytes.
        #   2026-07-31  SEGS left LOW for bank $03; the reader would have parsed
        #               the TEXTAB rows as seg records.
        #   2026-08-18  NODES left EXT for bank $03 and SSECT came IN from HIGH.
        #               The reader kept reading nodes from EXT-after-VERTS and
        #               subsectors from HIGH -- both regions hold something else
        #               now, so m.node came back ALL ZEROS and point_subsector
        #               spun forever on node 0 pointing at itself. gui.py and
        #               everything built on PackedMap were dead until 2026-08-27.
        # The bases below are OFFSETS INSIDE their bank (MAP_VERTS = $0000,
        # MAP_SEGS = $0100), so a region's file offset is base-of-region +
        # (symbol - bank base of that region's first section).
        lo0 = 0
        hi0 = caps['MAP_LOW_SECT'] * 128
        ext0 = hi0 + caps['MAP_HI_SECT'] * 128
        seg0 = ext0 + caps['MAP_EXT_SECT'] * 128
        # the EXT blob starts at MAP_VERTS ($0000) and the SEG blob at MAP_SEGS
        # ($0100) -- see pack_map._seg_layout for why the seg bank starts a page
        # in -- so those two are what the other symbols in each bank are
        # measured against.
        EXT = lambda sym: ext0 + caps[sym] - caps['MAP_VERTS']
        SEG = lambda sym: seg0 + caps[sym] - caps['MAP_SEGS']
        LOW = lambda sym: lo0 + caps[sym] - 0x4000

        self.sec = [struct.unpack_from('<hhBBBB', d, LOW('MAP_SECTORS') + i * 8)
                    for i in range(nsec)]     # fl,ce,light,floor_pal,ceil_pal,flags
        self.ss = [struct.unpack_from('<HH', d, EXT('MAP_SSECT') + i * 4)
                   for i in range(nss)]                            # first,count
        # seg (8 B): v1,v2, u8 front, u8 back ($FF = one-sided), wall_tex, low_tex.
        # wall_tex bit7 = ML_BLOCKING (impassable); exposed as seg[6] like before.
        sgb = SEG('MAP_SEGS')
        raw = [struct.unpack_from('<HHBBBB', d, sgb + i * 8) for i in range(nseg)]
        self.seg = [(s[0], s[1], s[2], 0xFFFF if s[3] == 0xFF else s[3],
                     s[4] & 0x7F, s[5], (s[4] >> 7) & 1) for s in raw]
        vb = EXT('MAP_VERTS')
        self.vx = [0] * nv; self.vy = [0] * nv
        for i in range(nv):
            self.vx[i], self.vy[i] = struct.unpack_from('<hh', d, vb + i * 4)
        # SEGOFF: DOOM's seg->offset + sidedef->textureoffset, u16 per seg
        # (renderer.asm rs_segoff). Halved when pack_textures.HALF_W is on.
        ob = EXT('MAP_SEGOFF')
        self.segoff = [struct.unpack_from('<H', d, ob + i * 2)[0] for i in range(nseg)]
        # node (28 B): x,y,dx,dy, child_r, child_l, then the two child bboxes
        # (top,bottom,left,right each). The boxes came back on 2026-07-29 when
        # R_CheckBBox was re-enabled -- see pack_map.py.
        nb = SEG('MAP_NODES')
        self.node = [struct.unpack_from('<hhhhHH', d, nb + i * 28) for i in range(nnode)]
        self.nbbox = [(struct.unpack_from('<hhhh', d, nb + i * 28 + 12),
                       struct.unpack_from('<hhhh', d, nb + i * 28 + 20))
                      for i in range(nnode)]
        # SEGMID: which MIDTEX row this seg's two-sided MIDDLE texture uses
        # ($FF = none), plus the rows themselves -- texid, world top, world
        # bottom (midtex.asm). The renderer draws these in a second, MASKED
        # pass; render_view below does not, but a reader that wants to has
        # them here rather than re-deriving them from the WAD.
        mb = SEG('MAP_SEGMID')
        self.segmid = list(d[mb:mb + nseg])
        nmtx = caps['MAP_NMTX']
        tb = SEG('MAP_MTXTEX')
        self.mtx = [(d[tb + i],
                     struct.unpack_from('<h', bytes([d[SEG('MAP_MTXTLO') + i],
                                                     d[SEG('MAP_MTXTHI') + i]]), 0)[0],
                     struct.unpack_from('<h', bytes([d[SEG('MAP_MTXBLO') + i],
                                                     d[SEG('MAP_MTXBHI') + i]]), 0)[0])
                    for i in range(nmtx)]

    def shade(self, base, light):
        r, g, b = self.pal[base]
        f = max(8, min(255, light)) / 255.0
        return (int(r * f), int(g * f), int(b * f))

    # ---- BSP point location ----
    def point_on_side(self, x, y, n):
        nx, ny, ndx, ndy = n[0], n[1], n[2], n[3]
        left = ndy * (x - nx)
        right = (y - ny) * ndx
        return 0 if right < left else 1

    def point_subsector(self, x, y):
        nid = self.root
        while not (nid & NF_SUBSECTOR):
            n = self.node[nid]
            nid = (n[4] if self.point_on_side(x, y, n) == 0 else n[5])
        return nid & (NF_SUBSECTOR - 1)

    def eye_height(self, x, y):
        ss = self.ss[self.point_subsector(x, y)]
        sg = self.seg[ss[0]]
        return self.sec[sg[2]][0] + EYE


class Renderer:
    def __init__(self, m):
        self.m = m

    def render(self, surf, px, py, pz, pa):
        self.px, self.py, self.pz = px, py, pz
        self.cos, self.sin = math.cos(pa), math.sin(pa)
        self.surf = surf
        self.ytop = [0] * W
        self.ybot = [H - 1] * W
        self.solid = [False] * W
        self.nsolid = 0
        surf.fill((0, 0, 0))
        self._node(self.m.root)

    def _node(self, nid):
        if self.nsolid >= W:
            return
        if nid & NF_SUBSECTOR:
            ss = self.m.ss[nid & (NF_SUBSECTOR - 1)]
            for i in range(ss[0], ss[0] + ss[1]):
                self._seg(self.m.seg[i])
            return
        n = self.m.node[nid]
        side = self.m.point_on_side(self.px, self.py, n)
        near, far = (n[4], n[5]) if side == 0 else (n[5], n[4])
        self._node(near)
        self._node(far)

    def _seg(self, sg):
        m = self.m
        v1x, v1y = m.vx[sg[0]], m.vy[sg[0]]
        v2x, v2y = m.vx[sg[1]], m.vy[sg[1]]
        px, py = self.px, self.py
        if (v2x - v1x) * (py - v1y) - (v2y - v1y) * (px - v1x) > 0:
            return

        def view(vx, vy):
            rx, ry = vx - px, vy - py
            return rx * self.sin - ry * self.cos, rx * self.cos + ry * self.sin  # X, Z
        X1, Z1 = view(v1x, v1y)
        X2, Z2 = view(v2x, v2y)
        if Z1 < ZNEAR and Z2 < ZNEAR:
            return
        if Z1 < ZNEAR:
            t = (ZNEAR - Z1) / (Z2 - Z1); X1 += t * (X2 - X1); Z1 = ZNEAR
        elif Z2 < ZNEAR:
            t = (ZNEAR - Z2) / (Z1 - Z2); X2 += t * (X1 - X2); Z2 = ZNEAR
        sx1 = H_W + FOCAL * X1 / Z1
        sx2 = H_W + FOCAL * X2 / Z2
        if sx1 > sx2:
            sx1, sx2 = sx2, sx1
        xa = max(0, int(math.ceil(sx1)))
        xb = min(W - 1, int(math.floor(sx2)))
        if xa > xb:
            return

        fs = m.sec[sg[2]]
        f_floor, f_ceil, light = fs[0], fs[1], fs[2]
        sky_ceil = fs[5] & 1
        ceil_col = SKY_COLOR if sky_ceil else m.shade(fs[4], light)
        floor_col = m.shade(fs[3], light)
        portal = sg[3] != 0xFFFF
        if portal:
            bs = m.sec[sg[3]]
            b_floor, b_ceil = bs[0], bs[1]
            b_sky = bs[5] & 1
            up_col = m.shade(sg[4], light)
            lo_col = m.shade(sg[5], light)
        else:
            wall_col = m.shade(sg[4], light)

        pz = self.pz
        dX, dZ = X2 - X1, Z2 - Z1
        for x in range(xa, xb + 1):
            if self.solid[x]:
                continue
            top, bot = self.ytop[x], self.ybot[x]
            if top > bot:
                continue
            mm = (x - H_W) / FOCAL
            denom = dX - mm * dZ
            if abs(denom) < 1e-6:
                continue
            s = (mm * Z1 - X1) / denom
            s = 0.0 if s < 0 else (1.0 if s > 1 else s)
            Z = Z1 + s * dZ
            if Z < ZNEAR:
                continue
            inv = FOCAL / Z
            yc = int(H_H - (f_ceil - pz) * inv)
            yf = int(H_H - (f_floor - pz) * inv)
            if not portal:
                self._v(x, top, min(yc - 1, bot), ceil_col)
                self._v(x, max(yc, top), min(yf, bot), wall_col)
                self._v(x, max(yf + 1, top), bot, floor_col)
                self.solid[x] = True; self.nsolid += 1
            else:
                ybc = int(H_H - (b_ceil - pz) * inv)
                ybf = int(H_H - (b_floor - pz) * inv)
                self._v(x, top, min(yc - 1, bot), ceil_col)
                new_top = max(top, yc)
                if ybc > yc:
                    col = SKY_COLOR if (sky_ceil and not b_sky) else up_col
                    self._v(x, max(yc, top), min(ybc - 1, bot), col)
                    new_top = max(new_top, ybc)
                self._v(x, max(yf + 1, top), bot, floor_col)
                new_bot = min(bot, yf)
                if ybf < yf:
                    self._v(x, max(ybf + 1, top), min(yf, bot), lo_col)
                    new_bot = min(new_bot, ybf)
                self.ytop[x] = new_top; self.ybot[x] = new_bot
                if new_top > new_bot:
                    self.solid[x] = True; self.nsolid += 1

    def _v(self, x, y0, y1, color):
        if y1 < y0:
            return
        y0 = max(0, y0); y1 = min(H - 1, y1)
        if y1 >= y0:
            pygame.draw.line(self.surf, color, (x, y0), (x, y1))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    name = args[0] if args else 'E1M1'
    m = PackedMap(os.path.join(MAPS_DIR, f'{name}.bin'))
    px, py = m.start_x, m.start_y
    pa = m.start_ang / 256.0 * 2 * math.pi
    pz = m.eye_height(px, py)
    r = Renderer(m)
    pygame.init()
    if '--shot' in sys.argv:
        surf = pygame.Surface((W, H))
        r.render(surf, px, py, pz, pa)
        out_dir = os.path.join(os.path.dirname(_HERE), '_pomocne', 'preview')
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, f'{name}_packed.png')
        pygame.image.save(pygame.transform.scale(surf, (W * SCALE, H * SCALE)), out)
        print(f'{name}: from packed .bin start=({px},{py}) ang={m.start_ang} -> {out}')
    else:
        screen = pygame.display.set_mode((W * SCALE, H * SCALE))
        pygame.display.set_caption(f'packed BSP -- {name}')
        clock = pygame.time.Clock()
        surf = pygame.Surface((W, H))
        running = True
        while running:
            dt = clock.tick(60) / 1000.0
            for e in pygame.event.get():
                if e.type == pygame.QUIT or (e.type == pygame.KEYDOWN and e.key == pygame.K_ESCAPE):
                    running = False
            k = pygame.key.get_pressed()
            spd = (260 if k[pygame.K_LSHIFT] else 120) * dt
            turn = 2.2 * dt
            if k[pygame.K_LEFT]: pa += turn
            if k[pygame.K_RIGHT]: pa -= turn
            c, s = math.cos(pa), math.sin(pa)
            if k[pygame.K_w]: px += c * spd; py += s * spd
            if k[pygame.K_s]: px -= c * spd; py -= s * spd
            if k[pygame.K_a]: px += s * spd; py -= c * spd
            if k[pygame.K_d]: px -= s * spd; py += c * spd
            pz = m.eye_height(px, py)
            r.render(surf, px, py, pz, pa)
            pygame.transform.scale(surf, (W * SCALE, H * SCALE), screen)
            pygame.display.flip()
    pygame.quit()


if __name__ == '__main__':
    main()
