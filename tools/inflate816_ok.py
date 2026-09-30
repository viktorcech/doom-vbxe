"""Can inflate816.asm depack this raw-DEFLATE stream?

inflate816.asm counts the codes of each length in WORDS since 2026-09-28
(the zlib6502 depacker before it kept one BYTE per length, and a block with
256 or more codes of one length -- E3M1's map stream had 258 of 9 bits --
never ended). What is left to refuse is what no DEFLATE reader takes: the
reserved block type and a stream that does not parse.
tools/tests/_verify_inflate.py runs a block of 256 nine-bit codes on the
built code.

problem(stream) -> None if inflate816 can take it, else a one-line reason.
Used by tools/make_atr_doom.py (_deflate picks only streams that pass) and
by tools/tests/_bench_frame.py (every stream the zlib hook stands in for).
"""

LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
         67, 83, 99, 115, 131, 163, 195, 227, 258]
LEXT = [0] * 8 + [1] * 4 + [2] * 4 + [3] * 4 + [4] * 4 + [5] * 4 + [0]
DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10,
        11, 11, 12, 12, 13, 13,
        16, 21]                       # 30, 31: the FAR matches (tools/deflate_far.py)
ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


class _Bits:
    def __init__(self, data):
        self.d, self.p, self.b, self.n = data, 0, 0, 0

    def get(self, k):
        while self.n < k:
            self.b |= self.d[self.p] << self.n
            self.p += 1
            self.n += 8
        v = self.b & ((1 << k) - 1)
        self.b >>= k
        self.n -= k
        return v


def _table(lengths):
    """canonical Huffman as {(len, code): symbol}"""
    code, tab = 0, {}
    for L in range(1, 16):
        for s, l in enumerate(lengths):
            if l == L:
                tab[(L, code)] = s
                code += 1
        code <<= 1
    return tab


def _dec(bs, tab):
    code = L = 0
    while True:
        code = (code << 1) | bs.get(1)
        L += 1
        s = tab.get((L, code))
        if s is not None:
            return s
        if L > 15:
            raise ValueError('bad code')


_FIXED = None


def problem(stream):
    global _FIXED
    if not stream:
        return None
    if _FIXED is None:
        _FIXED = (_table([8] * 144 + [9] * 112 + [7] * 24 + [8] * 8), _table([5] * 32))
    bs, blk = _Bits(stream), 0
    try:
        while True:
            final, typ = bs.get(1), bs.get(2)
            if typ == 0:
                bs.b = bs.n = 0
                ln = stream[bs.p] | (stream[bs.p + 1] << 8)
                bs.p += 4 + ln
            elif typ == 3:
                return f'block {blk}: reserved block type 3'
            else:
                if typ == 1:
                    lt, dt = _FIXED
                else:
                    hlit, hdist, hclen = bs.get(5) + 257, bs.get(5) + 1, bs.get(4) + 4
                    cl = [0] * 19
                    for i in range(hclen):
                        cl[ORDER[i]] = bs.get(3)
                    ct, lens = _table(cl), []
                    while len(lens) < hlit + hdist:
                        s = _dec(bs, ct)
                        if s < 16:
                            lens.append(s)
                        elif s == 16:
                            lens += [lens[-1]] * (3 + bs.get(2))
                        elif s == 17:
                            lens += [0] * (3 + bs.get(3))
                        else:
                            lens += [0] * (11 + bs.get(7))
                    if len(lens) != hlit + hdist:
                        return (f'block {blk}: a repeat runs past the '
                                f'{hlit + hdist} code lengths')
                    ll, dl = lens[:hlit], lens[hlit:]
                    lt, dt = _table(ll), _table(dl)
                while True:
                    s = _dec(bs, lt)
                    if s < 256:
                        continue
                    if s == 256:
                        break
                    s -= 257
                    bs.get(LEXT[s])
                    d = _dec(bs, dt)
                    bs.get(DEXT[d])
            if final:
                return None
            blk += 1
    except (IndexError, ValueError) as e:
        return f'block {blk}: unparsable ({e})'
