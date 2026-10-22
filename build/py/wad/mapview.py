#!/usr/bin/env python3
"""The clickable automap, on its own.

Lifted out of testlevel.py (2026-08-30) because wadconv.py wants ONE class from
it -- MapView, the map it draws beside the level list -- and testlevel is a
level TESTER: it patches a spawn point into a copy of the shipping ATR and
launches an emulator, none of which a WAD conversion has any use for. Dragging
all 810 lines of it into the community drop to get one widget was silly, and
copying the widget instead would have left two of it to keep in step. So it
lives here and both import it.

NF_SUBSECTOR and `locate` come along because MapView's click handler needs the
sector under the cursor.
"""
import re
import math

import doomspecs

NF_SUBSECTOR = 0x8000            # node child bit: the child is a subsector leaf


def locate(md, x, y):
    """The sector a point stands in, by the BSP descent the engine itself does.

    Deliberately spelled out here instead of importing pack_things.wad_subsector:
    that module pulls in doomstates, pack_los, wadtex and wadthings just to be
    imported, and if any of them fails this tool loses its spot list -- for
    fifteen lines of node walking that never change."""
    nid = len(md.nodes) - 1
    while not (nid & NF_SUBSECTOR):
        n = md.nodes[nid]
        nid = n.child[0] if (y - n.y) * n.dx < n.dy * (x - n.x) else n.child[1]
    sg = md.segs[md.ssectors[nid & (NF_SUBSECTOR - 1)].first]
    ld = md.linedefs[sg.linedef]
    from wadlib import NO_SIDEDEF
    side = ld.right if sg.side == 0 else ld.left
    return md.sidedefs[side].sector if side != NO_SIDEDEF else 0



LINE_COLS = [                        # (specials, colour, legend), first match wins
    ({7, 8}, '#ffe14d', 'schody'),
    ({88, 62, 21}, '#ff8c1a', 'vytah'),
    ({9}, '#c07cff', 'donut'),
    ({97}, '#ff5ce0', 'teleport'),
    ({11, 51, 52, 124}, '#ff3b3b', 'exit'),
]
C_FLOOR = '#4dd07a'                  # the rest of doomspecs.FLOORS
C_DOOR = '#3fa9ff'
C_WALL = '#c8c8c8'                   # one-sided: the level's outline
C_STEP = '#5a5a5a'                   # two-sided: a sector boundary you walk over
C_SECRET = '#ffc21a'                 # a secret sector -- gold, and the only
                                     #   warm colour on the map on purpose: the
                                     #   old olive #8a7326 at width 2 vanished
                                     #   into the walls
C_BG = '#101014'


def _line_style(md, ld, doors, floors):
    """(colour, width, on top?) for one linedef."""
    from wadlib import NO_SIDEDEF, ML_TWOSIDED
    sp = ld.special
    for specials, col, _name in LINE_COLS:
        if sp in specials:
            return col, 3, True
    if sp in doors:
        return C_DOOR, 3, True
    if sp in floors:
        return C_FLOOR, 3, True
    if ld.left == NO_SIDEDEF or not (ld.flags & ML_TWOSIDED):
        return C_WALL, 1, False
    return C_STEP, 1, False


def parse_at(text):
    """`X,Y` / `X,Y,UHOL` -> (x, y, ang or None), or None if it is not a spot.

    Deliberately forgiving, because the numbers arrive from three places and
    only one of them is typed by hand: the GUI's own box (`-224,176,90`), a
    line pasted out of --list (`... ( -224,   176) uhol  90  sektor 26`) and
    whatever the user retypes from a screenshot. A parenthesised pair wins --
    in a --list line the bare integers are linedef and special numbers."""
    m = re.search(r'\(\s*([-+]?\d+)\s*,\s*([-+]?\d+)\s*\)'
                  r'(?:\s*uhol\s*([-+]?\d+))?', text)
    if m:
        g = m.groups()
        return int(g[0]), int(g[1]), (int(g[2]) & 0xFF if g[2] else None)
    n = re.findall(r'[-+]?\d+', text)
    if len(n) < 2:
        return None
    return int(n[0]), int(n[1]), (int(n[2]) & 0xFF if len(n) > 2 else None)


class MapView:
    """The level's automap on a Tk canvas, in world coordinates."""

    def __init__(self, parent, tk, status, on_pick, coords=None,
                 coords_live=None):
        self.tk, self.status, self.on_pick = tk, status, on_pick
        # A StringVar the caller can put in a SELECTABLE widget. The status bar
        # is a plain Label, so the numbers in it cannot be dragged over and
        # copied -- which is the whole point of reading them off the map.
        # run_gui puts it in an EDITABLE Entry, so the same var is an INPUT too
        # (set_spawn below). coords_live() answers "is the box still free?" --
        # once something has been typed into it the hover tracker must keep its
        # hands off, or every mouse move eats what is being written.
        self.coords = coords
        self.coords_live = coords_live
        self.canvas = tk.Canvas(parent, bg=C_BG, highlightthickness=0,
                                width=860, height=600)
        self.md = None
        self.scale = 1.0
        self.ox = self.oy = 0.0       # world coords at the canvas's top-left
        self.spawn = None             # (x, y, ang)
        self._drag = None
        c = self.canvas
        c.bind('<Configure>', lambda e: self.redraw())
        c.bind('<Button-1>', self._down)
        c.bind('<B1-Motion>', self._aim)
        c.bind('<ButtonRelease-1>', self._up)
        c.bind('<Button-3>', self._pan_start)
        c.bind('<B3-Motion>', self._pan)
        c.bind('<MouseWheel>', self._wheel)
        c.bind('<Motion>', self._hover)

    # --- coordinate transforms (DOOM y points UP, the canvas down) ----------
    def w2s(self, x, y):
        return ((x - self.ox) * self.scale,
                (self.oy - y) * self.scale)

    def s2w(self, sx, sy):
        return (int(round(self.ox + sx / self.scale)),
                int(round(self.oy - sy / self.scale)))

    def load(self, md):
        """md = a wadlib MapData. Deliberately not a level number: tools/wadconv.py
        previews maps out of somebody else's WAD with the same view."""
        self.md = md
        self.spawn = None
        self.fit()

    def fit(self):
        if not self.md:
            return
        w = max(self.canvas.winfo_width(), 50)
        h = max(self.canvas.winfo_height(), 50)
        mnx, mny, mxx, mxy = self.md.bounds()
        self.scale = min(w / max(mxx - mnx, 1), h / max(mxy - mny, 1)) * 0.96
        self.ox = mnx - (w / self.scale - (mxx - mnx)) / 2
        self.oy = mxy + (h / self.scale - (mxy - mny)) / 2
        self.redraw()

    # --- drawing ------------------------------------------------------------
    def redraw(self):
        c = self.canvas
        c.delete('all')
        if not self.md:
            return
        import doomspecs
        md = self.md
        doors, floors = doomspecs.DOORS, doomspecs.FLOORS
        secret = {s for s, sec in enumerate(md.sectors) if sec.special == 9}
        from wadlib import NO_SIDEDEF
        later = []
        for ld in md.linedefs:
            v1, v2 = md.vertices[ld.v1], md.vertices[ld.v2]
            x1, y1 = self.w2s(v1.x, v1.y)
            x2, y2 = self.w2s(v2.x, v2.y)
            col, wid, top = _line_style(md, ld, doors, floors)
            if col in (C_WALL, C_STEP) and secret:
                sides = [md.sidedefs[s].sector for s in (ld.right, ld.left)
                         if s != NO_SIDEDEF]
                if any(s in secret for s in sides):
                    col, wid, top = C_SECRET, 3, True   # over the walls, not under
            if top:                                  # specials go over the walls
                later.append((x1, y1, x2, y2, col, wid))
            else:
                c.create_line(x1, y1, x2, y2, fill=col, width=wid)
        for x1, y1, x2, y2, col, wid in later:      # specials on top of walls
            c.create_line(x1, y1, x2, y2, fill=col, width=wid)
        # ...and a pin per SECRET sector, at the middle of its bounding box. A
        # gold outline still has to be FOUND; a pin does not. The label is the
        # SECTOR index, not a running count: spots() numbers `secret:N` only for
        # the ones it can stand you next to, so a count would drift -- while
        # its own label already ends in `sector {si}`, which is this number.
        for si in sorted(secret):
            xs, ys = [], []
            for ld in md.linedefs:
                for s in (ld.right, ld.left):
                    if s != NO_SIDEDEF and md.sidedefs[s].sector == si:
                        for v in (md.vertices[ld.v1], md.vertices[ld.v2]):
                            xs.append(v.x)
                            ys.append(v.y)
                        break
            if not xs:
                continue
            sx, sy = self.w2s((min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2)
            c.create_polygon(sx, sy - 7, sx + 6, sy, sx, sy + 7, sx - 6, sy,
                             fill=C_SECRET, outline='#000000')
            c.create_text(sx + 10, sy - 8, text=f'tajne {si}', fill=C_SECRET,
                          anchor='w', font=('Segoe UI', 8, 'bold'))
        for t in md.things:                          # the map's own player start
            if t.type == 1:
                sx, sy = self.w2s(t.x, t.y)
                c.create_oval(sx - 5, sy - 5, sx + 5, sy + 5,
                              outline='#00ff7f', width=2)
                c.create_text(sx + 9, sy - 9, text='start', fill='#00ff7f',
                              anchor='w', font=('Segoe UI', 8))
        self._draw_spawn()

    def _draw_spawn(self):
        c = self.canvas
        c.delete('spawn')
        if not self.spawn:
            return
        x, y, ang = self.spawn
        sx, sy = self.w2s(x, y)
        c.create_oval(sx - 7, sy - 7, sx + 7, sy + 7, outline='#ffffff',
                      width=2, tags='spawn')
        a = ang * 2 * math.pi / 256
        c.create_line(sx, sy, sx + 26 * math.cos(a), sy - 26 * math.sin(a),
                      fill='#ffffff', width=2, arrow='last', tags='spawn')

    def set_spawn(self, x, y, ang=None, center=True):
        """The mouse's job, done from numbers: put the marker on (x, y).

        `ang` None keeps whatever direction is already set, so typing a spot
        does not throw away an aim dragged out with the mouse. `center` slides
        the view over when the spot is off-screen -- typing the coordinates of
        a far corner is useless if the marker then sits outside the canvas.
        Returns the sector it landed in."""
        if ang is None:
            ang = self.spawn[2] if self.spawn else 0
        self.spawn = (int(x), int(y), int(ang) & 0xFF)
        sx, sy = self.w2s(self.spawn[0], self.spawn[1])
        w, h = self.canvas.winfo_width(), self.canvas.winfo_height()
        if center and not (0 <= sx <= w and 0 <= sy <= h):
            self.ox = self.spawn[0] - w / self.scale / 2
            self.oy = self.spawn[1] + h / self.scale / 2
            self.redraw()                        # redraw() ends in _draw_spawn
        else:
            self._draw_spawn()
        self._report()
        return locate(self.md, self.spawn[0], self.spawn[1])

    # --- mouse --------------------------------------------------------------
    def _down(self, e):
        x, y = self.s2w(e.x, e.y)
        self.spawn = (x, y, self.spawn[2] if self.spawn else 0)
        self._drag = (e.x, e.y)
        self._draw_spawn()
        self._report()

    def _aim(self, e):
        if not self._drag or not self.spawn:
            return
        dx, dy = e.x - self._drag[0], self._drag[1] - e.y      # canvas y is down
        if dx * dx + dy * dy < 16:
            return
        ang = int(round(math.degrees(math.atan2(dy, dx)) * 256 / 360)) & 0xFF
        self.spawn = (self.spawn[0], self.spawn[1], ang)
        self._draw_spawn()
        self._report()

    def _up(self, _e):
        self._drag = None
        self.on_pick(self.spawn)

    def _pan_start(self, e):
        self._pan_from = (e.x, e.y)

    def _pan(self, e):
        if not getattr(self, '_pan_from', None):
            return
        dx, dy = e.x - self._pan_from[0], e.y - self._pan_from[1]
        self.ox -= dx / self.scale
        self.oy += dy / self.scale
        self._pan_from = (e.x, e.y)
        self.redraw()

    def _wheel(self, e):
        wx, wy = self.s2w(e.x, e.y)                  # zoom about the cursor
        self.scale *= 1.25 if e.delta > 0 else 0.8
        self.ox = wx - e.x / self.scale
        self.oy = wy + e.y / self.scale
        self.redraw()

    def _hover(self, e):
        if not self.md:
            return
        x, y = self.s2w(e.x, e.y)
        sec = locate(self.md, x, y)
        self.status.set(f'({x}, {y})   sektor {sec}, podlaha '
                        f'{self.md.sectors[sec].floor_h}, strop '
                        f'{self.md.sectors[sec].ceil_h}')
        if (self.coords is not None and not self.spawn
                and (self.coords_live is None or self.coords_live())):
            self.coords.set(f'{x},{y}')          # nothing picked yet: the cursor

    def _report(self):
        x, y, ang = self.spawn
        sec = locate(self.md, x, y)
        self.status.set(f'spawn ({x}, {y}) uhol {ang} -- sektor {sec}, podlaha '
                        f'{self.md.sectors[sec].floor_h}   '
                        f'(tahaj mysou = smer pohladu)')
        if self.coords is not None:
            # X,Y,ANGLE with no spaces: readable, and it pastes straight into
            # `--at` (and into a message to somebody who needs to know where
            # you are standing).
            self.coords.set(f'{x},{y},{ang}')


