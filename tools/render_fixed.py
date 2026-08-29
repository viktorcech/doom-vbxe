#!/usr/bin/env python3
"""Fixed-point, 6502-shaped BSP renderer -- the math-validation step before ASM.

Same flat-shaded BSP renderer as render_packed.py, but rewritten to use ONLY the
operations a 6502 + VBXE can do, so we prove the integer pipeline matches the
float reference before committing to assembly:

  * angle is a byte (BAM 0..255); sin/cos come from a 256-entry table (Q14)
  * the view-space transform is 16x16->32 fixed multiply + shift
  * NO per-column division. Per seg we divide only a handful of times (screen X
    of the two endpoints, and the wall "scale" 1/Z at the two columns -- a
    reciprocal-table job on 6502). Wall top/bottom Y are then produced by the
    classic DOOM incremental scheme: a fixed-point accumulator per edge that is
    just `+= step` each column (add + shift, no multiply, no divide).

This is the exact structure the 6502 inner loop will run. Validated by diffing
its --shot against render_packed.py (the float reference).

Usage:
  python render_fixed.py E1M1 --shot     # -> _pomocne/preview/E1M1_fixed.png
  python render_fixed.py E1M1            # interactive (W/S/A/D + arrows)
"""
import math
import os
import sys

if '--shot' in sys.argv:
    os.environ['SDL_VIDEODRIVER'] = 'dummy'
import pygame

from render_packed import PackedMap, W, H, H_W, H_H, SCALE, SKY_COLOR

# ---- fixed-point config (the widths the 6502 will use) ----
TRIG = 14                                  # sin/cos in Q14 (signed, +-16384)
SFRAC = 8                                  # wall scale + y accumulators in Q8
RFRAC = 24                                 # reciprocal (1/Z) fractional bits
                                           # (24 not 16: at 16 the 1/Z lsb is too
                                           # coarse for far Z -> wall tops visibly
                                           # tilt. 6502 uses a normalized recip.)
ISF = 16                                   # 1/span fractional bits
FOCAL = H_W                                # 160 px (FOV 90)
ZNEAR = 4                                  # world units; closer is clipped
EYE = 41

SIN = [int(round(math.sin(a * 2 * math.pi / 256) * (1 << TRIG))) for a in range(256)]


def isin(a):
    return SIN[a & 255]


def icos(a):
    return SIN[(a + 64) & 255]


class FixedRenderer:
    def __init__(self, m: PackedMap):
        self.m = m
        self._vframe = 0
        self._vstamp = None

    def render(self, surf, px, py, pz, ang):
        self.px, self.py, self.pz = px, py, pz
        self.sin = isin(ang)
        self.cos = icos(ang)
        self.surf = surf
        self.ytop = [0] * W
        self.ybot = [H - 1] * W
        self.solid = [False] * W
        self.nsolid = 0
        # 6502-feasibility counters (resolution-independent geometry ops +
        # resolution-dependent column/fill work). See cycle_estimate.py.
        self.stats = dict(nodes=0, segs_seen=0, segs_drawn=0,
                          tmul=0, mul=0, recip=0, div=0, ptoa=0, vtox=0,
                          cols=0, span_px=0, bbcheck=0)
        # per-frame vertex-transform cache: each visible vertex transformed once
        # (verts are shared by ~3 segs). stamp != frame -> recompute.
        self._vframe += 1
        if self._vstamp is None or len(self._vstamp) != len(self.m.vx):
            self._vstamp = [0] * len(self.m.vx)
            self._vX = [0] * len(self.m.vx)
            self._vZ = [0] * len(self.m.vx)
        surf.fill((0, 0, 0))
        self._node(self.m.root)

    # ---- BSP front-to-back ----
    def _node(self, nid):
        if self.nsolid >= W:
            return
        m = self.m
        if nid & 0x8000:
            ss = m.ss[nid & 0x7FFF]
            for i in range(ss[0], ss[0] + ss[1]):
                self._seg(m.seg[i])
            return
        self.stats['nodes'] += 1
        self.stats['mul'] += 2                 # point_on_side: 2 mults
        n = m.node[nid]
        side = m.point_on_side(self.px, self.py, n)
        # near side first (always descend), then far side only if its bbox is
        # potentially visible -- DOOM R_CheckBBox. This is THE optimization that
        # stops us transforming the whole map every frame.
        if side == 0:
            near, far, far_bb = n[4], n[5], n[10:14]   # far = left child
        else:
            near, far, far_bb = n[5], n[4], n[6:10]    # far = right child
        self._node(near)
        if self._check_bbox(far_bb):
            self._node(far)

    def _check_bbox(self, bb):
        """True if the world-space bbox (top,bottom,left,right) might be visible:
        i.e. it has some part in front, inside the FOV, over not-yet-solid columns.
        On 6502 this is a table-angle job (no mul/div) -- see cycle_estimate."""
        self.stats['bbcheck'] += 1
        top, bottom, left, right = bb
        px, py = self.px, self.py
        if left <= px <= right and bottom <= py <= top:
            return True                         # viewer inside bbox
        sxs = []
        straddle = False
        for cx, cy in ((left, top), (right, top), (right, bottom), (left, bottom)):
            rx, ry = cx - px, cy - py
            X = (rx * self.sin - ry * self.cos) / (1 << TRIG)
            Z = (rx * self.cos + ry * self.sin) / (1 << TRIG)
            if Z < ZNEAR:
                straddle = True
            else:
                sxs.append(H_W + FOCAL * X / Z)
        if not sxs:
            return False                        # entirely behind near plane
        if straddle:
            return True                         # crosses near plane -> assume visible
        xlo = max(0, int(math.floor(min(sxs))))
        xhi = min(W - 1, int(math.ceil(max(sxs))))
        if xlo > xhi:
            return False                        # outside the screen
        for x in range(xlo, xhi + 1):
            if not self.solid[x]:
                return True                     # an open column -> visible
        return False                            # every column already solid

    # ---- cached view transform (frac-table 16x8: sin/cos are frame constants,
    #      so on 6502 each of these is ~31cy, not a full multiply -- see wx_mul.asm) ----
    def _vt(self, idx):
        if self._vstamp[idx] == self._vframe:
            return self._vX[idx], self._vZ[idx]
        rx = self.m.vx[idx] - self.px
        ry = self.m.vy[idx] - self.py
        self.stats['tmul'] += 4                # 4 frame-constant multiplies
        X = (rx * self.sin - ry * self.cos) >> TRIG
        Z = (rx * self.cos + ry * self.sin) >> TRIG
        self._vstamp[idx] = self._vframe
        self._vX[idx] = X
        self._vZ[idx] = Z
        return X, Z

    def _seg(self, sg):
        m = self.m
        i1, i2 = sg[0], sg[1]
        v1x, v1y = m.vx[i1], m.vy[i1]
        v2x, v2y = m.vx[i2], m.vy[i2]
        px, py = self.px, self.py
        self.stats['segs_seen'] += 1
        # backface: on 6502 this is the angle-span test on the two endpoint
        # angles (R_PointToAngle, table-based) -- NOT a multiply. Cost as 2 ptoa
        # (the python below still uses a cross product just to get the right
        # answer; the COST reflects the intended angle-table implementation).
        self.stats['ptoa'] += 2
        if (v2x - v1x) * (py - v1y) - (v2y - v1y) * (px - v1x) > 0:
            return

        X1, Z1 = self._vt(i1)
        X2, Z2 = self._vt(i2)
        if Z1 < ZNEAR and Z2 < ZNEAR:
            return
        # near-plane clip (integer interpolation)
        if Z1 < ZNEAR:
            self.stats['div'] += 1
            X1 = X1 + (X2 - X1) * (ZNEAR - Z1) // (Z2 - Z1)
            Z1 = ZNEAR
        elif Z2 < ZNEAR:
            self.stats['div'] += 1
            X2 = X2 + (X1 - X2) * (ZNEAR - Z2) // (Z1 - Z2)
            Z2 = ZNEAR

        # ONE reciprocal per endpoint (InvDepth-table lookup on 6502), reused for
        # BOTH screen-X and the wall scale -- no per-column division.
        self.stats['recip'] += 2
        iz1 = (1 << RFRAC) // Z1
        iz2 = (1 << RFRAC) // Z2
        # screen X: on 6502 from viewangletox[endpoint_angle] (a table), NOT a
        # multiply. (python still derives it from X/Z for the correct value.)
        self.stats['vtox'] += 2
        sx1 = H_W + (FOCAL * X1 * iz1 >> RFRAC)
        sx2 = H_W + (FOCAL * X2 * iz2 >> RFRAC)
        # scale = FOCAL/Z in Q(SFRAC), from the same reciprocal (a LUT on 6502)
        sc1 = FOCAL * iz1 >> (RFRAC - SFRAC)
        sc2 = FOCAL * iz2 >> (RFRAC - SFRAC)
        # pair screen-X with its scale while sorting left -> right
        if sx1 <= sx2:
            (sxL, scL), (sxR, scR) = (sx1, sc1), (sx2, sc2)
        else:
            (sxL, scL), (sxR, scR) = (sx2, sc2), (sx1, sc1)
        xa = max(0, sxL)
        xb = min(W - 1, sxR)
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
            b_floor, b_ceil, b_sky = bs[0], bs[1], bs[5] & 1
            up_col = m.shade(sg[4], light)
            lo_col = m.shade(sg[5], light)
        else:
            wall_col = m.shade(sg[4], light)

        self.stats['segs_drawn'] += 1
        # scale at the drawn columns: 1/Z is exactly linear in screen X, so the
        # endpoint scales scL/scR interpolate exactly. In the common unclipped
        # case (xa==sxL, xb==sxR) sa/sb ARE scL/scR -- no work.
        span_full = sxR - sxL
        if span_full and (xa != sxL or xb != sxR):
            self.stats['div'] += 1             # scalestep (kept fractional, Q8)
            self.stats['mul'] += 2
            sstep = ((scR - scL) << 8) // span_full
            sa = scL + ((xa - sxL) * sstep >> 8)
            sb = scL + ((xb - sxL) * sstep >> 8)
        else:
            sa, sb = scL, scR
        span = xb - xa
        # one reciprocal of the column span (a 1/n table on 6502), reused by
        # every height track -> steps become a multiply, not a divide.
        self.stats['div'] += 1
        inv_span = (1 << ISF) // span if span else 0

        def track(world_h):
            """Q8 screen-Y accumulator + per-column step for a height plane."""
            self.stats['mul'] += 3             # world_h*sa, world_h*sb, *inv_span
            yl = (H_H << SFRAC) - world_h * sa
            yr = (H_H << SFRAC) - world_h * sb
            step = (yr - yl) * inv_span >> ISF
            return yl, step

        pz = self.pz
        yc, yc_s = track(f_ceil - pz)
        yf, yf_s = track(f_floor - pz)
        if portal:
            ybc, ybc_s = track(b_ceil - pz)
            ybf, ybf_s = track(b_floor - pz)

        for x in range(xa, xb + 1):
            self.stats['cols'] += 1
            if not self.solid[x]:
                top, bot = self.ytop[x], self.ybot[x]
                if top <= bot:
                    pyc = yc >> SFRAC
                    pyf = yf >> SFRAC
                    if not portal:
                        self._v(x, top, min(pyc - 1, bot), ceil_col)
                        self._v(x, max(pyc, top), min(pyf, bot), wall_col)
                        self._v(x, max(pyf + 1, top), bot, floor_col)
                        self.solid[x] = True
                        self.nsolid += 1
                    else:
                        pybc = ybc >> SFRAC
                        pybf = ybf >> SFRAC
                        self._v(x, top, min(pyc - 1, bot), ceil_col)
                        nt = max(top, pyc)
                        if pybc > pyc:
                            col = SKY_COLOR if (sky_ceil and not b_sky) else up_col
                            self._v(x, max(pyc, top), min(pybc - 1, bot), col)
                            nt = max(nt, pybc)
                        self._v(x, max(pyf + 1, top), bot, floor_col)
                        nb = min(bot, pyf)
                        if pybf < pyf:
                            self._v(x, max(pybf + 1, top), min(pyf, bot), lo_col)
                            nb = min(nb, pybf)
                        self.ytop[x] = nt
                        self.ybot[x] = nb
                        if nt > nb:
                            self.solid[x] = True
                            self.nsolid += 1
            yc += yc_s
            yf += yf_s
            if portal:
                ybc += ybc_s
                ybf += ybf_s

    def _col_z(self, x, XL, ZL, dX, dZ):
        # ray X = m*Z/FOCAL ; solve for s on [pL..pR], return Z. (one divide)
        self.stats['div'] += 1
        m = x - H_W
        denom = FOCAL * dX - m * dZ
        if denom == 0:
            return ZL
        s_num = m * ZL - FOCAL * XL
        # Z = ZL + (dZ * s_num)/denom
        return ZL + (dZ * s_num) // denom

    def _v(self, x, y0, y1, color):
        if y1 < y0:
            return
        y0 = 0 if y0 < 0 else y0
        y1 = H - 1 if y1 > H - 1 else y1
        if y1 >= y0:
            self.stats['span_px'] += (y1 - y0 + 1)
            pygame.draw.line(self.surf, color, (x, y0), (x, y1))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    name = args[0] if args else 'E1M1'
    here = os.path.dirname(os.path.abspath(__file__))
    m = PackedMap(os.path.join(os.path.dirname(here), 'build', 'assets', 'wadmaps', f'{name}.bin'))
    px, py = m.start_x, m.start_y
    ang = m.start_ang
    r = FixedRenderer(m)
    pygame.init()
    if '--shot' in sys.argv:
        surf = pygame.Surface((W, H))
        pz = m.eye_height(px, py)
        r.render(surf, px, py, pz, ang)
        out_dir = os.path.join(os.path.dirname(here), '_pomocne', 'preview')
        os.makedirs(out_dir, exist_ok=True)
        out = os.path.join(out_dir, f'{name}_fixed.png')
        pygame.image.save(pygame.transform.scale(surf, (W * SCALE, H * SCALE)), out)
        print(f'{name}: fixed-point start=({px},{py}) ang={ang} -> {out}')
    else:
        screen = pygame.display.set_mode((W * SCALE, H * SCALE))
        pygame.display.set_caption(f'fixed-point BSP -- {name}')
        clock = pygame.time.Clock()
        surf = pygame.Surface((W, H))
        fang = float(ang)
        fx, fy = float(px), float(py)
        running = True
        while running:
            dt = clock.tick(60) / 1000.0
            for e in pygame.event.get():
                if e.type == pygame.QUIT or (e.type == pygame.KEYDOWN and e.key == pygame.K_ESCAPE):
                    running = False
            k = pygame.key.get_pressed()
            spd = (260 if k[pygame.K_LSHIFT] else 120) * dt
            if k[pygame.K_LEFT]: fang = (fang + 90 * dt) % 256
            if k[pygame.K_RIGHT]: fang = (fang - 90 * dt) % 256
            a = int(fang) & 255
            c, s = icos(a) / (1 << TRIG), isin(a) / (1 << TRIG)
            if k[pygame.K_w]: fx += c * spd; fy += s * spd
            if k[pygame.K_s]: fx -= c * spd; fy -= s * spd
            if k[pygame.K_a]: fx += s * spd; fy -= c * spd
            if k[pygame.K_d]: fx -= s * spd; fy += c * spd
            px, py = int(fx), int(fy)
            pz = m.eye_height(px, py)
            r.render(surf, px, py, pz, a)
            pygame.transform.scale(surf, (W * SCALE, H * SCALE), screen)
            pygame.display.flip()
    pygame.quit()


if __name__ == '__main__':
    main()
