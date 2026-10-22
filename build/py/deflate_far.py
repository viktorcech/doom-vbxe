#!/usr/bin/env python3
"""deflate_far -- raw DEFLATE with FAR matches: a match reaches back through
the whole blob, not 32 KB.

The stream is RFC 1951 with its two reserved distance symbols in use:
    30   distance  32769 + 16 extra bits   (..   98304)
    31   distance  98305 + 21 extra bits   (.. 2195456)
Block types, headers and code order are DEFLATE's.

    pack(base, data)   `base` = a DEFLATE stream of `data` (zopfli's). Its
                       parse is kept; every stretch a far match codes in fewer
                       bits is replaced and each block's codes are rebuilt.
                       Returns `base` itself when nothing was gained.
    unpack(stream)     the reference decoder (plain DEFLATE too)
    inflate(blob)      (data, bytes used) of the stream `blob` starts with:
                       zlib's work for a plain stream, unpack's for a far one
    parse(stream)      its blocks: (symbols, literal/length lengths, distance
                       lengths); a symbol is a literal 0..255 or
                       length << 24 | distance
"""
import bisect
import sys

sys.dont_write_bytecode = True

LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
         67, 83, 99, 115, 131, 163, 195, 227, 258]
LEXT = [0] * 8 + [1] * 4 + [2] * 4 + [3] * 4 + [4] * 4 + [5] * 4 + [0]
DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385,
         513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
         32769, 98305]
DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
        11, 11, 12, 12, 13, 13, 16, 21]
ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
NEAR = 32768                          # DEFLATE's own reach
FAR_MAX = DBASE[31] + (1 << DEXT[31]) - 1
FIXED_LL = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
FIXED_DL = [5] * 32

# a match length -> (length symbol - 257, extra bits, their value)
LSYM = [None] * 259
for _s in range(29):
    for _x in range(1 << LEXT[_s]):
        if LBASE[_s] + _x <= 258 and LSYM[LBASE[_s] + _x] is None:
            LSYM[LBASE[_s] + _x] = (_s, LEXT[_s], _x)
LSYM[258] = (28, 0, 0)


def dsym(d):
    return bisect.bisect_right(DBASE, d) - 1


# ---- reading ----------------------------------------------------------------
def _codes(lengths):
    """Canonical codes, bit-reversed (the stream's order): symbol -> code."""
    count = [0] * 16
    for l in lengths:
        count[l] += 1
    count[0] = 0
    nxt, code = [0] * 16, 0
    for bits in range(1, 16):
        code = (code + count[bits - 1]) << 1
        nxt[bits] = code
    out = [0] * len(lengths)
    for s, l in enumerate(lengths):
        if l:
            out[s] = int(format(nxt[l], '0%db' % l)[::-1], 2)
            nxt[l] += 1
    return out


def _table(lengths):
    """The stream's next 15 bits -> symbol << 4 | code length (0 = no code)."""
    tab = [0] * 32768
    for s, (l, c) in enumerate(zip(lengths, _codes(lengths))):
        if l:
            tab[c::1 << l] = [(s << 4) | l] * (1 << (15 - l))
    return tab


def parse(stream):
    return _parse(stream)[0]


def _parse(stream):
    """(blocks, the bytes the stream took)"""
    d = bytes(stream) + bytes(8)
    end = len(stream) * 8
    bp, blocks = 0, []
    while True:
        if bp >= end:
            raise ValueError('the stream ends inside a block')
        v = int.from_bytes(d[bp >> 3:(bp >> 3) + 8], 'little') >> (bp & 7)
        final, typ = v & 1, (v >> 1) & 3
        bp += 3
        if typ == 3:
            raise ValueError('reserved block type 3')
        if typ == 0:
            i = (bp + 7) >> 3
            n = d[i] | (d[i + 1] << 8)
            blocks.append((list(d[i + 4:i + 4 + n]), None, None))
            bp = (i + 4 + n) * 8
            if final:
                return blocks, (bp + 7) >> 3
            continue
        if typ == 1:
            ll, dl = FIXED_LL, FIXED_DL
        else:
            v >>= 3
            hlit, hdist, hclen = (v & 31) + 257, ((v >> 5) & 31) + 1, ((v >> 10) & 15) + 4
            bp += 14
            cl = [0] * 19
            for i in range(hclen):
                cl[ORDER[i]] = (d[bp >> 3] | (d[(bp >> 3) + 1] << 8)) >> (bp & 7) & 7
                bp += 3
            ct, lens = _table(cl), []
            while len(lens) < hlit + hdist:
                v = int.from_bytes(d[bp >> 3:(bp >> 3) + 4], 'little') >> (bp & 7)
                e = ct[v & 0x7FFF]
                l = e & 15
                if not l:
                    raise ValueError('bad code-length code')
                s = e >> 4
                v >>= l
                if s < 16:
                    lens.append(s)
                elif s == 16:
                    lens += [lens[-1]] * (3 + (v & 3))
                    l += 2
                elif s == 17:
                    lens += [0] * (3 + (v & 7))
                    l += 3
                else:
                    lens += [0] * (11 + (v & 127))
                    l += 7
                bp += l
            if len(lens) != hlit + hdist:
                raise ValueError('a repeat runs past the code lengths')
            ll = lens[:hlit] + [0] * (288 - hlit)
            dl = lens[hlit:] + [0] * (32 - hdist)
        lt, dt = _table(ll), _table(dl)
        syms = []
        put = syms.append
        while True:
            if bp >= end:
                raise ValueError('the stream ends inside a block')
            v = int.from_bytes(d[bp >> 3:(bp >> 3) + 8], 'little') >> (bp & 7)
            e = lt[v & 0x7FFF]
            l = e & 15
            if not l:
                raise ValueError('bad literal/length code')
            s = e >> 4
            if s < 256:
                put(s)
                bp += l
                continue
            if s == 256:
                bp += l
                break
            s -= 257
            if s > 28:
                raise ValueError('length symbol past 285')
            x = LEXT[s]
            ln = LBASE[s] + ((v >> l) & ((1 << x) - 1))
            l += x
            e = dt[(v >> l) & 0x7FFF]
            k = e & 15
            if not k:
                raise ValueError('bad distance code')
            t = e >> 4
            x = DEXT[t]
            put((ln << 24) | (DBASE[t] + ((v >> (l + k)) & ((1 << x) - 1))))
            bp += l + k + x
        blocks.append((syms, list(ll), list(dl)))
        if final:
            return blocks, (bp + 7) >> 3


def unpack(stream):
    return _unpack(stream)[0]


def inflate(blob):
    import zlib
    d = zlib.decompressobj(-15)
    try:
        out = d.decompress(bytes(blob))
        if d.eof:
            return out, len(blob) - len(d.unused_data)
    except zlib.error:
        pass
    return _unpack(blob)


def _unpack(stream):
    blocks, used = _parse(stream)
    out = bytearray()
    for syms, _, _ in blocks:
        for s in syms:
            if s < 256:
                out.append(s)
                continue
            ln, d = s >> 24, s & 0xFFFFFF
            p = len(out) - d
            if p < 0:
                raise ValueError('a match from before the start')
            if d >= ln:
                out += out[p:p + ln]
            else:
                for i in range(ln):
                    out.append(out[p + i])
    return bytes(out), used


def has_far(stream):
    return any(s >= 256 and (s & 0xFFFFFF) > NEAR
               for syms, _, _ in parse(stream) for s in syms)


# ---- the far matches --------------------------------------------------------
class Far:
    """The blob's suffixes in order (to DEPTH bytes), to find where the text
    at p stood before, more than NEAR bytes back."""
    DEPTH = 2048
    SCAN = 64
    CAP = 258 * 64

    def __init__(self, data):
        import numpy as np
        self.d = data
        n = len(data)
        rank = np.frombuffer(data, np.uint8).astype(np.int64)
        k = 1
        while True:
            nxt = np.zeros(n, np.int64)
            nxt[:n - k] = rank[k:] + 1           # 0 = past the end
            key = rank * (n + 2) + nxt
            sa = np.argsort(key, kind='stable')
            ks = key[sa]
            rank = np.empty(n, np.int64)
            rank[sa] = np.concatenate(([0], np.cumsum(ks[1:] != ks[:-1])))
            if k >= self.DEPTH or int(rank.max()) == n - 1:
                break
            k *= 2
        inv = np.empty(n, np.int64)
        inv[sa] = np.arange(n)
        self.sa, self.inv = sa.tolist(), inv.tolist()

    def _cpl(self, p, q, cap):
        d = self.d
        if d[p:p + cap] == d[q:q + cap]:
            return cap
        lo, hi = 0, cap
        while hi - lo > 1:
            mid = (lo + hi) >> 1
            if d[p + lo:p + mid] == d[q + lo:q + mid]:
                lo = mid
            else:
                hi = mid
        return lo

    def best(self, p):
        """(length, source) of the longest match for p from more than NEAR
        back, (0, 0) when there is none."""
        lim = p - NEAR
        if lim <= 0:
            return 0, 0
        sa, r = self.sa, self.inv[p]
        cap = min(self.CAP, len(self.d) - p)
        bl = bq = 0
        for step in (-1, 1):
            j = r + step
            for _ in range(self.SCAN):
                if j < 0 or j >= len(sa):
                    break
                q = sa[j]
                if q < lim and p - q <= FAR_MAX:
                    l = self._cpl(p, q, cap)
                    if l > bl:
                        bl, bq = l, q
                    break
                j += step
        return bl, bq


def _chunks(total):
    """A long match as matches of 3..258."""
    out = [258] * (total // 258)
    r = total % 258
    if r:
        if r < 3 and out:
            out[-1] -= 3 - r
            r = 3
        out.append(r)
    return out


def _refit(data, blocks, far, est, margin=3):
    """The parse with far matches in: a list of symbols per block. `est` =
    the (literal/length, distance) code lengths a block's bits are priced
    with; a symbol without a code is priced at UNUSED bits."""
    UNUSED = 11
    F, P, B = [], [], []
    p = 0
    for b, (syms, _, _) in enumerate(blocks):
        for s in syms:
            F.append(s)
            P.append(p)
            B.append(b)
            p += 1 if s < 256 else s >> 24
    P.append(p)
    n = len(F)

    def price(b, s):
        ll, dl = est[b]
        if s < 256:
            return ll[s] or UNUSED
        ls, lx, _ = LSYM[s >> 24]
        t = dsym(s & 0xFFFFFF)
        return (ll[257 + ls] or UNUSED) + lx + (dl[t] or (UNUSED if t < 30 else 6)) + DEXT[t]

    C = [0] * (n + 1)
    for i in range(n):
        C[i + 1] = C[i] + price(B[i], F[i])
    out = [[] for _ in blocks]
    i = skip = 0
    while i < n:
        p, s, b = P[i], F[i], B[i]
        if p < skip:                         # under a far match: the tail of
            e = P[i + 1]                     #   a match may stick out
            if e > skip:
                if e - skip >= 3:
                    out[b].append(((e - skip) << 24) | (s & 0xFFFFFF))
                else:
                    out[b] += data[skip:e]
                skip = e
            i += 1
            continue
        ln, q = far.best(p)
        if ln >= 4:
            d = p - q
            best = None
            j = bisect.bisect_right(P, p + ln) - 1       # the symbol p + ln falls in
            for e in {p + ln, P[j]}:
                if e - p < 4:
                    continue
                j = bisect.bisect_right(P, e) - 1
                if j < n and P[j] < e:                   # a match is cut
                    old = C[j + 1] - C[i]
                    rem = P[j + 1] - e
                    tail = (price(B[j], (rem << 24) | (F[j] & 0xFFFFFF)) if rem >= 3
                            else sum(price(B[j], c) for c in data[e:e + rem]))
                else:
                    old, tail = C[j] - C[i], 0
                new = tail + sum(price(b, (c << 24) | d) for c in _chunks(e - p))
                if old - new > margin and (best is None or old - new > best[0]):
                    best = (old - new, e)
            if best is not None:
                out[b] += [(c << 24) | d for c in _chunks(best[1] - p)]
                skip = best[1]
                continue
        out[b].append(s)
        skip = P[i + 1]
        i += 1
    return out


# ---- writing ----------------------------------------------------------------
def _lengths(freq, limit):
    """Optimal code lengths of at most `limit` bits (package-merge)."""
    out = [0] * len(freq)
    items = sorted((f, [s]) for s, f in enumerate(freq) if f)
    if len(items) == 1:
        out[items[0][1][0]] = 1
        return out
    pk = items
    for _ in range(limit - 1):
        pk = sorted(items + [(pk[i][0] + pk[i + 1][0], pk[i][1] + pk[i + 1][1])
                             for i in range(0, len(pk) - 1, 2)], key=lambda t: t[0])
    for _, ss in pk[:2 * len(items) - 2]:
        for s in ss:
            out[s] += 1
    return out


def _rle(seq):
    """Code lengths as code-length symbols: (symbol, extra bits, value)."""
    out, i, n = [], 0, len(seq)
    while i < n:
        v, j = seq[i], i
        while j < n and seq[j] == v:
            j += 1
        run = j - i
        i = j
        if v == 0:
            while run >= 11:
                k = min(run, 138)
                out.append((18, 7, k - 11))
                run -= k
            if run >= 3:
                out.append((17, 3, run - 3))
                run = 0
        else:
            out.append((v, 0, 0))
            run -= 1
            while run >= 3:
                k = min(run, 6)
                out.append((16, 2, k - 3))
                run -= k
        out += [(v, 0, 0)] * run
    return out


class _Bits:
    def __init__(self):
        self.out, self.acc, self.n = bytearray(), 0, 0

    def put(self, v, k):
        self.acc |= v << self.n
        self.n += k
        if self.n >= 64:
            self.out += (self.acc & 0xFFFFFFFFFFFFFFFF).to_bytes(8, 'little')
            self.acc >>= 64
            self.n -= 64

    def align(self):
        self.n = (self.n + 7) & ~7

    def done(self):
        return bytes(self.out + self.acc.to_bytes((self.n + 7) >> 3, 'little'))


def _body(syms, ll, dl):
    """(bits, [(value, bit count)]) of a block's symbols and its end."""
    lc, dc = _codes(ll), _codes(dl)
    lit = [(lc[s], ll[s]) for s in range(256)]
    memo, out, bits = {}, [], 0
    for s in syms:
        if s < 256:
            e = lit[s]
        else:
            e = memo.get(s)
            if e is None:
                ls, lx, lv = LSYM[s >> 24]
                d = s & 0xFFFFFF
                t = dsym(d)
                v, k = lc[257 + ls], ll[257 + ls]
                v |= lv << k
                k += lx
                v |= dc[t] << k
                k += dl[t]
                v |= (d - DBASE[t]) << k
                e = memo[s] = (v, k + DEXT[t])
        out.append(e)
        bits += e[1]
    out.append((lc[256], ll[256]))
    return bits + ll[256], out


def encode(data, blocks):
    """The stream of `blocks` (a list of symbols each) over `data`."""
    blocks = [b for b in blocks if b]
    w, pos = _Bits(), 0
    for bi, syms in enumerate(blocks):
        final = 1 if bi == len(blocks) - 1 else 0
        size = sum(1 if s < 256 else s >> 24 for s in syms)
        lf, df = [0] * 286, [0] * 32
        lf[256] = 1
        for s in syms:
            if s < 256:
                lf[s] += 1
            else:
                lf[257 + LSYM[s >> 24][0]] += 1
                df[dsym(s & 0xFFFFFF)] += 1
        ll, dl = _lengths(lf, 15), _lengths(df, 15)
        for t in (0, 1):                     # two distance codes at least, as
            if sum(1 for l in dl if l) < 2 and not dl[t]:   # zopfli leaves it
                dl[t] = 1
        hlit = max(i for i in range(286) if ll[i]) + 1
        hdist = max(i for i in range(32) if dl[i]) + 1
        rle = _rle(ll[:hlit] + dl[:hdist])
        cf = [0] * 19
        for s, _, _ in rle:
            cf[s] += 1
        cl = _lengths(cf, 7)
        hclen = max(i for i in range(19) if cl[ORDER[i]]) + 1
        hclen = max(hclen, 4)
        head = 14 + 3 * hclen + sum(cl[s] + x for s, x, _ in rle)
        dyn_bits, dyn = _body(syms, ll, dl)
        fix_bits, fix = _body(syms, FIXED_LL, FIXED_DL)
        stored = 8 * size + 40 * -(-size // 65535)
        if stored + 7 < min(head + dyn_bits, fix_bits):
            for o in range(0, size, 65535):
                part = data[pos + o:pos + min(o + 65535, size)]
                w.put(1 if final and o + 65535 >= size else 0, 3)
                w.align()
                w.put(len(part) | ((len(part) ^ 0xFFFF) << 16), 32)
                for c in part:
                    w.put(c, 8)
        elif fix_bits <= head + dyn_bits:
            w.put(final | 2, 3)
            for v, k in fix:
                w.put(v, k)
        else:
            w.put(final | 4, 3)
            w.put((hlit - 257) | ((hdist - 1) << 5) | ((hclen - 4) << 10), 14)
            for i in range(hclen):
                w.put(cl[ORDER[i]], 3)
            cc = _codes(cl)
            for s, x, v in rle:
                w.put(cc[s] | (v << cl[s]), cl[s] + x)
            for v, k in dyn:
                w.put(v, k)
        pos += size
    return w.done()


def pack(base, data, passes=2):
    data = bytes(data)
    if len(data) <= NEAR or len(data) > FAR_MAX:
        return base
    try:
        import numpy                         # noqa: F401 (Far sorts with it)
    except ImportError:
        print('  WARNING: numpy is not installed -- no far matches, the '
              'streams stay plain DEFLATE (about 10 % more sectors)')
        return base
    blocks = parse(base)
    far = Far(data)
    est = [(ll or [8] * 288, dl or [0] * 32) for _, ll, dl in blocks]
    best = base
    for _ in range(passes):
        new = _refit(data, blocks, far, est)
        out = encode(data, new)
        if unpack(out) != data:
            raise AssertionError('deflate_far: the stream does not unpack to the data')
        if len(out) < len(best):
            best = out
        # the next pass prices with the codes this one ended on
        got = parse(out)
        if len(got) != len([b for b in new if b]) or len(got) != len(blocks):
            break
        est = [(ll or [8] * 288, dl or [0] * 32) for _, ll, dl in got]
    return best


if __name__ == '__main__':
    import zlib
    for path in sys.argv[1:]:
        data = open(path, 'rb').read()
        c = zlib.compressobj(9, zlib.DEFLATED, -15, 9)
        base = c.compress(data) + c.flush()
        out = pack(base, data)
        print(f'{path}: {len(data)} B  zlib -9 {len(base)}  far {len(out)} '
              f'({(len(out) - len(base)) * 100 / len(base):+.1f}%)')
