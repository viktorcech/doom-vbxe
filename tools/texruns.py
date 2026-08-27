#!/usr/bin/env python3
"""Wall textures as RUNS the engine PAINTS, instead of pixels it blits.

Why: a blitted texture cannot be shaded (the VBXE blitter has no lookup in its
path -- lights.asm), so textured walls ignore the sector light. Painted spans go
through the colormap, so they blink. And they are FASTER: measured in the
shipped code on a real E1M1 frame (tools/_bench_spans.py), one painted span
costs 105 cycles against 3948 for a textured wall span, so 16 painted runs per
column is 0.43x the CPU of today's path and 79 % of the blitter budget instead
of 203 %.

THE CONVERSION (shared by tools/_cmp_texflat.py, which draws the comparison
PNGs, and by pack_textures.py, which ships the result):

  Each stored texture column is approximated by K constant runs. Choosing K
  constant pieces of ordered data with least squared error is the k-segment /
  v-optimal histogram problem; this is its exact O(h^2 K) dynamic program, with
  the whole cost matrix built from prefix sums in one numpy pass. A run's colour
  is then the PLAYPAL entry nearest its mean, searched over all 256 entries
  (for a squared-error metric that is provably the best single colour for the
  run: sum|p-c|^2 = n|c-mean|^2 + const).

THE ON-DISK FORMAT (v1, fixed K so a column is random-access):

  per stored column: K x (u8 rows, u8 colour)      -- 2*K bytes
  column c of texture t starts at  base[t] + c*2*K

  `rows` is the run's length in TEXELS and they sum to the texture height, so
  the painter walks a column top-down, converting texel rows to screen rows with
  the same rate (rs_tpr) the blit path used, and wraps modulo the height for the
  tiling. `colour` is a PLAYPAL index -- which is exactly what makes it
  shadeable: the painter puts it through the sector's colormap row.

WHAT THE ENGINE SIDE STILL NEEDS (not written yet -- pack_textures.RUN_TEXTURES
stays False until it is, or the blitter draws run bytes as pixels):

  1. wall_src / low_src: the column address becomes base + storedcol*2K, i.e.
     five shifts instead of `qsmul tex_x, texH` -- and the base is
     tex_sdram + MAP_TEXADDR[texid], NOT an arena address: the painter reads the
     runs with the CPU ([zp],y long out of SDRAM), so tex_fget and the whole
     VRAM texture arena drop out of the wall path entirely.
  2. paint_col, in place of draw_twall_col (draw_twall_clip keeps its clipping
     and tail-calls it with A = top row, Y = height):
        rpt   = (rs_dscr << 4) / rs_worldh     screen rows per texel, Q8; ONE
                                               divide per column, memoised on
                                               dscr exactly like tw_setup's tpr
        t0    = (rs_vsh + ((spa - rs_pegrow) * rs_tpr >> 8)) mod texH
        walk the K runs to the one holding t0, then, until y > spb:
           rows_left = run_end - t0
           dy        = rows_left * rpt >> 8
           colour    = [zp_cm],y  with y = the run's colour   <- the shading
           draw_vspan(y, min(y + dy, spb) - y + 1, colour)
           y += dy;  next run, wrapping at K (skip zero-length runs)
  3. What comes OUT once it works: tw_expand, tw_blit, draw_twall_col (the
     TEXBLIT block), tw_runs, TWEMIT, and most of tw_setup -- ~2.6 KB, which is
     what pays for the painter and then some.
  4. Verify: tools/_bench_spans.py renders a real frame in the sim, so the span
     counts and the cycle total can be compared before/after; then the 9-level
     ATR.
"""
import numpy as np

W = np.array([2.0, 4.0, 3.0])        # perceptual weights on R,G,B
CUBE = 5                             # nearest-index cube: 2^CUBE per axis
DEFAULT_K = 16


_CUBE_CACHE = []                     # the cube depends on the PALETTE alone, and
                                     # there is one palette. Rebuilding it per
                                     # texture meant a 32768x256 distance array
                                     # (67 MB) per call and was most of the pack
                                     # time -- 9 levels went from ~25 min to
                                     # under one.


def nearest_cube(pal32):
    """(2^CUBE)^3 -> nearest palette index. Makes the cost matrix affordable;
    the FINAL colour of a run is always recomputed exactly (exact_idx)."""
    if _CUBE_CACHE:
        return _CUBE_CACHE[0]
    n = 1 << CUBE
    step = 256 >> CUBE
    ax = np.arange(n) * step + step // 2
    grid = np.stack(np.meshgrid(ax, ax, ax, indexing='ij'), -1).reshape(-1, 3)
    d = grid[:, None, :] - pal32[None, :, :]
    cube = np.argmin((d.astype(np.float64) ** 2 * W).sum(-1), 1).astype(
        np.uint8).reshape(n, n, n)
    _CUBE_CACHE.append(cube)
    return cube


def exact_idx(pal32, rgb, a, b):
    """The best single palette colour for rows a..b-1, over all 256 entries
    EXCEPT index 0.

    Index 0 is the port's TRANSPARENT marker: paint.asm skips a run whose
    colour is 0, so an opaque wall must never be handed one. PLAYPAL 0 is pure
    black and several near-blacks sit beside it, so the exclusion costs at most
    one shade on the darkest runs -- against holes in every dark wall in the
    game if it is left out."""
    d = pal32.astype(np.float64) - rgb[a:b].mean(0)
    e = (d * d * W).sum(1)
    e[0] = np.inf
    return int(np.argmin(e))


def col_matrix(rgb, pal32, cube):
    """cost[a][b] for painting rows a..b-1 of one column in one colour."""
    h = len(rgb)
    p = rgb.astype(np.float64)
    S = np.vstack([np.zeros(3), np.cumsum(p, 0)])
    Q = np.concatenate([[0.0], np.cumsum((p ** 2 * W).sum(1))])
    a = np.arange(h + 1)
    n = a[None, :] - a[:, None]
    valid = n > 0
    nn = np.where(valid, n, 1)
    ssum = S[None, :, :] - S[:, None, :]
    mean = ssum / nn[..., None]
    q = np.clip((mean / (256 >> CUBE)).astype(np.int32), 0, (1 << CUBE) - 1)
    idx = cube[q[..., 0], q[..., 1], q[..., 2]]
    c = pal32[idx].astype(np.float64)
    cost = ((Q[None, :] - Q[:, None])
            - 2.0 * (c * ssum * W).sum(-1)
            + nn * (c ** 2 * W).sum(-1))
    return np.where(valid, np.maximum(cost, 0.0), np.inf)


def dp_cuts(cost, k):
    """Exact k-segment split of one column -> (total error, boundary list)."""
    h = cost.shape[0] - 1
    k = min(k, h)
    dp = np.full((k + 1, h + 1), np.inf)
    back = np.zeros((k + 1, h + 1), dtype=np.int32)
    dp[0, 0] = 0.0
    for kk in range(1, k + 1):
        prev = dp[kk - 1][:, None] + cost
        back[kk] = np.argmin(prev, 0)
        dp[kk] = prev[back[kk], np.arange(h + 1)]
    b, cuts = h, [h]
    for kk in range(k, 0, -1):
        b = int(back[kk, b])
        cuts.append(b)
    return float(dp[k, h]), sorted(set(cuts))


_RUN_CACHE = {}                      # column bytes -> its runs. The DP is O(h^2 K)
                                     # per column and the build runs it twice per
                                     # level (pack_map, then pack_textures) over
                                     # nine levels that share most of their
                                     # textures -- so this is most of the pack
                                     # time, for identical answers.


def _segments(col_idx):
    """The column split into maximal transparent / opaque stretches ->
    [(a, b, transparent)]."""
    out, i, h = [], 0, len(col_idx)
    while i < h:
        t = col_idx[i] == 0
        j = i + 1
        while j < h and (col_idx[j] == 0) == t:
            j += 1
        out.append((i, j, t))
        i = j
    return out


def _masked_runs(col_idx, pal32, cube, k):
    """A MASKED column (index 0 = transparent, wadtex.get_texture(masked=True)).

    The mask has to come out EXACT -- a bar of BRNBIGC that leaks one texel
    into its gap is a visible seam -- so the run boundaries are pinned to the
    transparency edges first and the k-segment DP only ever runs INSIDE an
    opaque stretch. Each transparent stretch is one run of colour 0, which
    paint.asm skips; the rest of the budget is shared out by length."""
    segs = _segments(col_idx)
    opaque = [s for s in segs if not s[2]]
    # The runs must SUM to the texture height (paint.asm's anchor walk counts
    # texels down), so every stretch has to get at least one -- 7 is the worst
    # column episode 1 has (BRNBIGC) against K = 32.
    assert len(segs) <= k, \
        f'masked column needs {len(segs)} runs > K={k} -- raise TEX_RUNK'
    budget = k - (len(segs) - len(opaque))
    span = sum(b - a for (a, b, _t) in opaque) or 1
    share, left = {}, budget - len(opaque)
    for s in opaque:                         # one run each, then by length
        share[s] = 1
    for s in sorted(opaque, key=lambda s: s[1] - s[0], reverse=True):
        if left <= 0:
            break
        add = min(left, max(0, (s[1] - s[0]) * budget // span - 1))
        share[s] += add
        left -= add
    rgb = pal32[np.asarray(col_idx, dtype=np.uint8)]
    runs = []
    for (a, b, transparent) in segs:
        if transparent:
            runs.append((b - a, 0))
            continue
        sub = rgb[a:b]
        _err, cuts = dp_cuts(col_matrix(sub, pal32, cube), share[(a, b, False)])
        runs += [(cuts[i + 1] - cuts[i],
                  exact_idx(pal32, sub, cuts[i], cuts[i + 1]))
                 for i in range(len(cuts) - 1)]
    return runs


def column_runs(col_idx, pal32, cube, k=DEFAULT_K, masked=False):
    """One column of palette indices -> [(rows, colour)] * k (padded with
    zero-length runs if the column is shorter than k texels)."""
    key = (bytes(bytearray(col_idx)), k, masked)
    hit = _RUN_CACHE.get(key)
    if hit is not None:
        return hit
    if masked:
        runs = _masked_runs(col_idx, pal32, cube, k)
    else:
        rgb = pal32[np.asarray(col_idx, dtype=np.uint8)]
        _err, cuts = dp_cuts(col_matrix(rgb, pal32, cube), k)
        runs = [(cuts[i + 1] - cuts[i],
                 exact_idx(pal32, rgb, cuts[i], cuts[i + 1]))
                for i in range(len(cuts) - 1)]
    while len(runs) < k:
        runs.append((0, runs[-1][1] if runs else 1))
    runs = runs[:k]
    _RUN_CACHE[key] = runs
    return runs


def texture_runs(cols, pal, k=DEFAULT_K, masked=False):
    """cols = [[palette index]*h] per STORED column -> (blob, painted grid).

    The grid is what the engine would show; callers use it to measure the error
    against the real pixels (tools/_cmp_texflat.py draws both)."""
    pal32 = np.asarray(pal, dtype=np.int32)
    cube = nearest_cube(pal32)
    blob = bytearray()
    grid = []
    for col in cols:
        runs = column_runs(col, pal32, cube, k, masked)
        out = []
        for rows, idx in runs:
            blob += bytes((min(255, rows), idx))
            out += [idx] * rows
        out += [out[-1] if out else 0] * (len(col) - len(out))
        grid.append(out[:len(col)])
    return bytes(blob), grid


# ---------------------------------------------------------------------------
# CLI: build the per-level RUN blobs the painter would ship.
#
# It reuses pack_textures' own texture set and column pipeline (half_cols /
# fold_width / dedup), so the ids, widths and heights are EXACTLY the ones the
# engine already has -- only the per-column payload changes: 2*K bytes of runs
# instead of h bytes of pixels. That is what keeps the switch reversible: the
# renderer's texture handle (base, wmask, h) means the same thing either way.
#
#   python tools/texruns.py [E1M1 ...] [--k 16]
# ---------------------------------------------------------------------------
def _main():
    import os
    import struct
    import sys
    here = os.path.dirname(os.path.abspath(__file__))
    sys.path.insert(0, here)
    from wadlib import Wad, DEFAULT_WAD
    from wadtex import WadTextures
    import pack_textures as PT

    argv = sys.argv[1:]
    k = DEFAULT_K
    if '--k' in argv:
        i = argv.index('--k')
        k = int(argv[i + 1])
        del argv[i:i + 2]
    names = [a.upper() for a in argv if not a.startswith('--')] or \
        [f'E1M{i}' for i in range(1, 10)]
    out_dir = os.path.join(os.path.dirname(here), 'build', 'assets', 'textures')
    os.makedirs(out_dir, exist_ok=True)

    w = Wad(DEFAULT_WAD)
    wt = WadTextures(w)
    # the IWAD's own palette, like pack_textures._playpal_rgb: a layered WAD
    # with a PLAYPAL of its own has been remapped into it by wadtex
    pal = np.frombuffer(bytes(w.source_palette(0)),
                        dtype=np.uint8).reshape(256, 3)

    print(f'{"map":6} {"tex":>4} {"pixels B":>9} {"runs B":>8} {"ratio":>6} '
          f'{"mean err":>9}  (K={k})')
    for nm in names:
        md = w.load_map(nm)
        _pool, _tab, _segtex, table, _scr, _ix, _mid = PT.pack_map_textures(md, wt)
        blob = bytearray()
        offs = {}
        errs = []
        for tid, (name, _addr, tw, th, _dom, _mate) in enumerate(table):
            if not th:                            # a flat colour row: no pixels
                continue
            base = PT.tex_base(name)
            t = wt.get_texture(base)
            if t is None:
                continue
            fw, fh, tx = t
            if PT.SWITCH_BUTTON_ONLY and PT.is_switch(base):
                tx = PT.switch_button(wt, base, tx, fw, fh)
            cols, cw = PT.half_cols(tx, fw, fh)
            cols, cw = PT.fold_width(cols, cw, fh)
            grid_in = [list(cols[c * fh:(c + 1) * fh]) for c in range(cw)]
            rb, painted = texture_runs(grid_in, pal, k)
            d = pal[np.array(grid_in, dtype=np.uint8)].astype(np.int32) - \
                pal[np.array(painted, dtype=np.uint8)].astype(np.int32)
            errs.append(float(np.sqrt((d * d).sum(-1)).mean()))
            offs[tid] = len(blob)
            blob += rb
        hdr = bytearray(struct.pack('<BB', len(table), k)) + bytearray(2 * len(table))
        for tid, o in offs.items():
            struct.pack_into('<H', hdr, 2 + 2 * tid, len(hdr) + o)
        data = bytes(hdr) + bytes(blob)
        with open(os.path.join(out_dir, f'{nm}.run'), 'wb') as f:
            f.write(data)
        pix = os.path.getsize(os.path.join(out_dir, f'{nm}.tex'))
        print(f'{nm:6} {len(offs):4} {pix:9} {len(data):8} '
              f'{pix / max(1, len(data)):5.2f}x {sum(errs) / max(1, len(errs)):9.1f}')


if __name__ == '__main__':
    _main()
