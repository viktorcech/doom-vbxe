#!/usr/bin/env python3
"""pool_plan -- what a SHARED texture pool would really cost and save.

pack_textures.py emits one .tex per level, so a wall used by six maps is
stored six times. This walks the SAME payload pipeline pack_map_textures uses
(half_cols -> fold_width -> _payload -> dedup_columns, with the scroll texture's
double copy) but dedups ACROSS the whole episode, and reports:

  * the pool's real size, against the sum of today's per-level blobs
  * per level, in play order, how many bytes would actually be STREAMED --
    i.e. only the textures not already resident in SDRAM from an earlier map

No estimates: these are the bytes the packer would emit.

  python tools/pool_plan.py [E1M1 E1M2 ...]      (default: the whole episode)
"""
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from wadlib import Wad, DEFAULT_WAD                            # noqa: E402
from wadtex import WadTextures                                 # noqa: E402
import pack_textures as PT                                     # noqa: E402

SECTOR = 128


def payloads(md, wt):
    """{name: (payload bytes, column-index bytes)} for one level, exactly the
    bytes pack_map_textures would put in that level's .tex."""
    slots = PT._seg_slots(md)
    used = {n for pair in slots for n in pair if n}
    for name in [n for n in used if PT.is_switch(n)]:
        mate = PT.doomspecs.switch_mate(name)
        if mate and wt.get_texture(mate) is not None:
            used.add(mate)

    out = {}
    for name in sorted(used):
        base = PT.tex_base(name)
        t = wt.get_texture(base)
        if t is None:
            continue
        w, h, tx = t
        if PT.SWITCH_BUTTON_ONLY and PT.is_switch(base):
            tx = PT.switch_button(wt, base, tx, w, h)
        cols, w = PT.half_cols(tx, w, h)
        cols, w = PT.fold_width(cols, w, h)

        textured = (PT.SHIP_ALL_TEXTURES or PT.is_switch(base)
                    or name.endswith(PT.ROLE_TAG))
        if not textured:
            continue                                   # flat row: no pixels at all
        if PT.SCROLL_TAG in name:
            body, _w, _stride = PT._payload(cols, w, h)
            pool, idx = bytearray(body + body), bytes(range(w))
        else:
            pool, idx = PT.dedup_columns(*PT._payload(cols, w, h))
        out[name] = (bytes(pool), bytes(idx))
    return out


def main(levels):
    w = Wad(DEFAULT_WAD)
    wt = WadTextures(w)

    per = {}
    for m in levels:
        per[m] = payloads(w.load_map(m), wt)

    # --- the pool: one entry per distinct payload, sector aligned so a texture
    #     can be streamed on its own (and so its SDRAM home is its disk home).
    pool = {}                      # payload -> [pool index, padded bytes]
    for m in levels:
        for name, (pl, _idx) in per[m].items():
            if pl not in pool:
                pool[pl] = [len(pool), (len(pl) + SECTOR - 1) // SECTOR * SECTOR]
    pool_bytes = sum(v[1] for v in pool.values())

    print(f'{"level":6} {"pouziva":>7} {"nove":>5} {"dnes KB":>9} {"pool KB":>9}')
    resident, tn, tp, jrows = set(), 0, 0, []
    for m in levels:
        f = os.path.join(os.path.dirname(_HERE), 'build', 'assets', 'textures',
                         m + '.tex')
        now = os.path.getsize(f) / 1024 if os.path.exists(f) else 0
        new = [pl for pl, _i in ((pl, pool[pl][0]) for pl, _ in per[m].values())
               if pool[pl][0] not in resident]
        stream = sum(pool[pl][1] for pl in dict.fromkeys(new))
        for pl, _idx in per[m].values():
            resident.add(pool[pl][0])
        tn += now
        tp += stream / 1024
        jrows.append(dict(level=m, used=len(per[m]),
                          new=len(dict.fromkeys(new)), now=now,
                          pool=stream/1024))
        print(f'{m:6} {len(per[m]):7} {len(dict.fromkeys(new)):5} '
              f'{now:9.0f} {stream/1024:9.0f}')
    print(f'{"SPOLU":6} {len(pool):7} {"":5} {tn:9.0f} {tp:9.0f}')
    print(f'\npool: {len(pool)} unikatnych textur, {pool_bytes:,} B '
          f'({pool_bytes/1024:.0f} KB, sektorovo zarovnane)')
    print(f'dnes: {tn:.0f} KB v {len(levels)} blokoch  ->  usetri '
          f'{100*(1-tp/tn):.0f} % streamovania')
    if '--json' in sys.argv:
        out = os.path.join(os.path.dirname(_HERE), 'bench', 'pool.json')
        json.dump(dict(levels=jrows, distinct=len(pool), pool_bytes=pool_bytes,
                       total_now=tn, total_pool=tp,
                       saved_pct=100*(1-tp/tn)),
                  open(out, 'w', encoding='utf-8'), indent=1)
        print('-> ' + out)
    return 0


if __name__ == '__main__':
    lv = [a for a in sys.argv[1:] if not a.startswith('--')] or [f'E1M{i}' for i in range(1, 10)]
    sys.exit(main(lv))
