"""The working-mouse scenes (#185): one stepped pixel animation per kind of work, at two sizes.

Ported from the owner-approved mock-up (`.scratch/mouse-lab/scenes.py` for the large 64x30 scenes,
`compact.py` for the compact 34x14 ones and the typing mouse). Every drawing call is kept as it was,
so the frames are pixel-identical to the gallery the owner signed off on; the only changes are:

- no PIL: a frame is a grid of palette glyphs (`.` transparent), and `gen_working_mouse.py` writes it;
- the large terminal is the mock-up's `big_terminal` (the corrected typing mouse), not the first draft;
- the large thinking scene is the approved one (sits and ponders); the pacing alternative is dropped;
- the compact "waiting on you" holds its head still (the mock-up blinked and flicked an ear), so only
  the `?` blinks while a Response is paused on the user: it must not compete with the question or
  approval card (coordinator decision for #185).

Brand mouse grids come from `sprites.json` (the same file `gen_sprites.py` reads). Props are drawn at one
pixel per pixel in the brand palette plus the scene colours below. `v`/`V` are the accent's two values
(verdigris by default) and follow the user's AccentChoice at runtime (#179), but only on UI-accent pixels:
the thought dot, highlighted lines and labels, chat bubbles, terminal and code output, cursors and run
lights. Scenery that depicts a real object (the painted hills, book spines, folder labels, a window's
traffic light, the paint on the palette) uses `n`/`N`, the same verdigris values, fixed. In Verdigris the
frames are pixel-identical to the mock-up.

Freestanding ink marks (#192), the waiting `?` and the thought puffs, are drawn in `k` (INK) rather than
`K`: the same umber in light mode, light grey in dark, where umber all but disappears on Nocturne. Ink
attached to the mouse or a prop (outlines, a bubble's edge, written lines on a page) stays `K`.
"""
from __future__ import annotations

import json
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent
_DATA = json.loads((HERE / "sprites.json").read_text(encoding="utf-8"))
# The ink of freestanding marks (#192); gen_sprites.py adds it to the sprite palette as K's colour.
INK = "k"
SP: dict[str, list[str]] = {**_DATA["sprites"], **_DATA["frames"]}

# The colours the scenes add to the sprite palette (the mock-up's PAL.update).
SCENE_PALETTE: dict[str, str] = {
    "s": "#5B88A8",  # ocean
    "S": "#3F6A88",  # ocean shade
    "g": "#6E9A5A",  # land
    "q": "#4F7A43",  # land shade
    "v": "#2C6656",  # UI accent (verdigris light value; follows AccentChoice)
    "V": "#7CC7B0",  # UI accent light (verdigris dark value; follows AccentChoice)
    "n": "#2C6656",  # verdigris on scenery (fixed): hills, book spines, folder labels, a window's green light
    "N": "#7CC7B0",  # light verdigris on scenery (fixed): the painted hills' band
    "d": "#1C2420",  # screen
    "D": "#2A3530",  # screen bezel inner
    "r": "#B42318",  # red
    "R": "#F0736A",  # red light
    "c": "#9CC2DD",  # sky, lens
    "w": "#5A4320",  # dark wood
}
PALETTE: dict[str, str] = {**_DATA["palette"], INK: _DATA["palette"]["K"], **SCENE_PALETTE}

LARGE = (64, 30)
COMPACT = (34, 14)


class Canvas:
    """A sparse pixel grid clipped to w x h (the mock-up's Canvas / compact.C)."""

    def __init__(self, w: int, h: int):
        self.w, self.h = w, h
        self.px: dict[tuple[int, int], str] = {}

    def p(self, x, y, c):
        if c == ".":
            self.px.pop((x, y), None)
        elif c and 0 <= x < self.w and 0 <= y < self.h:
            self.px[(x, y)] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.p(x, y, c)

    def box(self, x0, y0, x1, y1, fill, line="K"):
        self.rect(x0, y0, x1, y1, line)
        self.rect(x0 + 1, y0 + 1, x1 - 1, y1 - 1, fill)

    def hline(self, x0, x1, y, c):
        self.rect(x0, y, x1, y, c)

    def vline(self, x, y0, y1, c):
        self.rect(x, y0, x, y1, c)

    def line(self, x0, y0, x1, y1, c):
        n = max(abs(x1 - x0), abs(y1 - y0), 1)
        for i in range(n + 1):
            self.p(round(x0 + (x1 - x0) * i / n), round(y0 + (y1 - y0) * i / n), c)

    def disc(self, cx, cy, r, c):
        for y in range(-r, r + 1):
            for x in range(-r, r + 1):
                if x * x + y * y <= r * r + r * 0.6:
                    self.p(cx + x, cy + y, c)

    def ring(self, cx, cy, r, c):
        for y in range(-r - 1, r + 2):
            for x in range(-r - 1, r + 2):
                d = x * x + y * y
                if r * r - r <= d <= r * r + r:
                    self.p(cx + x, cy + y, c)

    def sprite(self, name, x, y, rows=None):
        for j, row in enumerate(rows or SP[name]):
            for i, ch in enumerate(row):
                if ch != ".":
                    self.p(x + i, y + j, ch)

    def grid(self, rows, x, y):
        self.sprite(None, x, y, rows)

    def rows(self) -> list[str]:
        return ["".join(self.px.get((x, y), ".") for x in range(self.w)) for y in range(self.h)]


def L() -> Canvas:
    return Canvas(*LARGE)


def C() -> Canvas:
    return Canvas(*COMPACT)


def blink_sit(f, n):
    """sit with a blink, an ear flick and a sniff spread over the loop."""
    return {n * 5 // 12: "sitBlink", n * 9 // 12: "sitEar", n * 11 // 12: "sitSniff"}.get(f, "sit")


def head(c, f, n, x=0, y=5):
    pose = {n * 4 // 12: "headBlink", n * 8 // 12: "headEar", n * 11 // 12: "headSniff"}.get(f, "head")
    c.sprite(pose, x, y)


LAND = [
    "......................................",
    "....gggg..........ggg.........gg......",
    "..ggggggg......ggggggggg....gggggg....",
    "...gggggg.....gggggggggggggggggggggg..",
    "....gggg.......gggg..ggggggggggggg....",
    ".....ggg.......ggggg..gggggggggg......",
    "......gg........ggggg...ggggggg.......",
    "......ggg........gggg....gg...g.......",
    ".......gggg.......ggg.........gg......",
    "........gggg......gggg.........gg.....",
    "........ggg........gg..........ggg....",
    ".........gg........g..........gggg....",
    ".........g......................g.....",
    "......................................",
    "..............ggggggggggggg...........",
]


def globe_face(c, cx, cy, r, f, n):
    """The turning globe (the continents scroll past; shaded on the right), ringed in ink."""
    lw = len(LAND[0])
    off = f * lw / n
    for y in range(-r, r + 1):
        half = math.sqrt(max(r * r - y * y, 0))
        for x in range(-r, r + 1):
            if x * x + y * y > r * r + r * 0.6:
                continue
            lon = math.asin(max(-1, min(1, x / (half + 0.5)))) / math.pi + 0.5  # 0..1 across the face
            u = int((lon * lw / 2 + off) % lw)
            v = int((y + r) / (2 * r + 1) * len(LAND))
            land = LAND[v][u] == "g"
            shade = x > r * 0.45
            c.p(cx + x, cy + y, ("q" if shade else "g") if land else ("S" if shade else "s"))
    c.ring(cx, cy, r, "K")


# --- the typing mouse and its terminal (compact.py) ------------------------------------------------
def typist(c, f, x=0, y=0, keys=17):
    """Front-facing mouse behind a keyboard: chest and two arms reach the keys; the paws take turns
    pressing (the pressing paw sits 1 px lower, over the keyboard's edge, and its key darkens)."""
    head_rows = SP["peek"][:7] + ["...KKWWWPWWWKK..."]
    for j, row in enumerate(head_rows):
        for i, ch in enumerate(row):
            if ch != ".":
                c.p(x + i, y + j, ch)
    if f % 8 == 7:  # a blink now and then
        c.p(x + 6, y + 5, "W"); c.p(x + 10, y + 5, "W")
    # chest
    c.hline(x + 4, x + 12, y + 8, "W"); c.hline(x + 4, x + 12, y + 9, "W")
    c.p(x + 8, y + 9, "L")
    # keyboard
    kx0, kx1, ky = x - 1, x + keys, y + 10
    c.hline(kx0, kx1, ky, "K")
    for r, yy in enumerate((ky + 1, ky + 2)):
        c.p(kx0, yy, "K"); c.p(kx1, yy, "K")
        for k in range(kx0 + 1, kx1):
            c.p(k, yy, "W" if (k + r) % 3 else "L")
    c.hline(kx0, kx1, ky + 3, "L"); c.p(kx0, ky + 3, "K"); c.p(kx1, ky + 3, "K")
    c.hline(kx0, kx1, ky + 4, "K")
    left_down = f % 2 == 0
    for side, down in ((0, left_down), (1, not left_down)):
        ax = x + 1 if side == 0 else x + 12   # the arm's outer column
        # upper arm from the shoulder
        if side == 0:
            c.p(ax + 1, y + 8, "K"); c.p(ax + 2, y + 8, "W"); c.p(ax + 3, y + 8, "W")
        else:
            c.p(ax + 2, y + 8, "K"); c.p(ax, y + 8, "W"); c.p(ax + 1, y + 8, "W")
        if down:
            c.p(ax, y + 9, "K"); c.p(ax + 1, y + 9, "W"); c.p(ax + 2, y + 9, "W"); c.p(ax + 3, y + 9, "K")
            c.p(ax, ky, "K"); c.p(ax + 1, ky, "P"); c.p(ax + 2, ky, "P"); c.p(ax + 3, ky, "K")
            c.p(ax + 1, ky + 1, "G"); c.p(ax + 2, ky + 1, "G")
        else:
            c.p(ax, y + 9, "K"); c.p(ax + 1, y + 9, "P"); c.p(ax + 2, y + 9, "P"); c.p(ax + 3, y + 9, "K")


def term_panel(c, x0, y0, x1, y1, f):
    c.box(x0, y0, x1, y1, "d")
    c.p(x0 + 2, y0 + 1, "r"); c.p(x0 + 4, y0 + 1, "Y"); c.p(x0 + 6, y0 + 1, "n")
    out = [("Y", 2, "V", 6), ("W", 9, None, 0), ("W", 6, None, 0), ("Y", 2, "V", 4), ("W", 8, None, 0)]
    shift = f // 2
    rows = (y1 - y0 - 3) // 2
    for k in range(rows):
        a, la, b, lb = out[(k + shift) % len(out)]
        y = y0 + 3 + k * 2
        width = x1 - x0 - 4
        c.hline(x0 + 2, x0 + 1 + min(la, width), y, a)
        if b:
            c.hline(x0 + 3 + la, x0 + 2 + min(la + lb, width), y, b)
    if f % 2 == 0:
        c.hline(x0 + 2, x0 + 3, y1 - 2, "V")


QUESTION = [".kkk.", "k...k", "...k.", "..k..", ".....", "..k.."]  # freestanding ink (#192)

# =================================================================================================
# Large scenes (64x30, scenes.py)
# =================================================================================================


def l_thinking(f, n=16):
    c = L()
    c.sprite(blink_sit(f, n), 4, 15)
    # rising thought puffs (freestanding ink, #192), then the bubble
    c.box(23, 12, 24, 13, "W", INK)
    c.box(26, 8, 28, 10, "W", INK)
    bx0, by0, bx1, by1 = 30, 1, 52, 9
    c.rect(bx0 + 1, by0, bx1 - 1, by1, "K")
    c.rect(bx0, by0 + 1, bx1, by1 - 1, "K")
    c.rect(bx0 + 1, by0 + 1, bx1 - 1, by1 - 1, "W")
    dots = min(3, f // 3) if f < 12 else (3 if f % 2 == 0 else 0)
    for i in range(dots):
        c.rect(35 + i * 6, 4, 36 + i * 6, 6, "G" if i < 2 else "v")
    # the tail swishes
    if f % 4 in (1, 2):
        c.p(3, 24, "G"); c.p(4, 25, ".")
    return c


def l_web(f, n=12):
    c = L()
    c.sprite("stand", 2, 11)
    cx, cy, r = 32, 13, 10
    # stand: meridian ring and foot
    c.ring(cx, cy, r + 1, "O")
    c.vline(cx, cy + r + 2, 27, "O")
    c.rect(cx - 5, 27, cx + 5, 28, "w")
    globe_face(c, cx, cy, r, f, n)
    # a glint that stays put while the world turns
    c.p(cx - 5, cy - 6, "W"); c.p(cx - 6, cy - 5, "W")
    # the paw nudges the globe on the first beat
    if f % 6 == 0:
        c.p(19, 21, "P"); c.p(20, 21, "K")
    return c


def l_read_page(f, n=12):
    c = L()
    c.sprite("stand", 1, 11)
    x0, y0, x1, y1 = 22, 2, 58, 27
    c.box(x0, y0, x1, y1, "W")
    c.rect(x0 + 1, y0 + 1, x1 - 1, y0 + 3, "L")
    c.hline(x0 + 1, x1 - 1, y0 + 4, "K")
    for i, col in enumerate("rYn"):
        c.p(x0 + 3 + i * 3, y0 + 2, col)
    c.rect(x0 + 13, y0 + 2, x1 - 3, y0 + 2, "W")
    lines = [26, 18, 30, 22, 12, 28, 20, 24, 16, 30, 14, 26]
    for k in range(9):
        idx = (k + f) % len(lines)
        y = y0 + 7 + k * 2
        if y >= y1 - 1:
            break
        col = "v" if idx % 5 == 0 else "G"
        c.hline(x0 + 3, x0 + 3 + lines[idx] * 30 // 30 - (0 if col == "G" else 8), y, col)
    # magnifier sweeps down the page
    mx, my = 40 + (2 if f % 4 < 2 else 0), 10 + (f % n) * 12 // n
    c.disc(mx, my, 4, "c")
    c.ring(mx, my, 4, "K")
    c.line(mx + 3, my + 4, mx + 6, my + 7, "w")
    c.p(mx - 2, my - 2, "W")
    return c


def l_knowledge(f, n=12):
    c = L()
    c.sprite("read", 2, 11)
    x0, x1 = 28, 60
    for sy in (13, 28):
        c.rect(x0, sy, x1, sy + 1, "O")
        c.hline(x0, x1, sy + 1, "w")
    c.vline(x0, 1, 29, "w"); c.vline(x1, 1, 29, "w")
    books = [("B", 10), ("r", 9), ("n", 11), ("Y", 8), ("G", 10), ("B", 9), ("r", 11), ("n", 10), ("O", 9)]
    pulled = f % len(books)
    for shelf, sy in enumerate((13, 28)):
        x = x0 + 2
        for i, (col, h) in enumerate(books if shelf == 0 else books[::-1]):
            lift = 3 if (shelf == 0 and i == pulled) or (shelf == 1 and i == (pulled + 4) % len(books)) else 0
            top = sy - h - lift
            c.rect(x, top, x + 2, sy - 1 - lift, col)
            c.vline(x + 3, top, sy - 1 - lift, "K")
            c.hline(x, x + 2, top + 2, "y")
            x += 4
    return c


def l_memory(f, n=12):
    c = L()
    c.sprite("stand", 4, 11)
    # cards
    for i in range(6):
        x = 26 + i * 4
        up = 5 if i == f % 6 else 0
        c.box(x, 12 - up, x + 7, 22 - up, "b", "G")
        c.hline(x + 2, x + 5, 14 - up, "G")
        if up:
            c.hline(x + 2, x + 5, 16 - up, "v")
            c.p(x + 8, 8 - up, "y"); c.p(x + 9, 7 - up, "Y"); c.p(x + 10, 8 - up, "y")
    # the box
    c.box(23, 18, 52, 28, "O")
    c.hline(24, 51, 22, "w")
    c.box(35, 20, 40, 22, "y")
    return c


def l_past_chats(f, n=12):
    c = L()
    c.sprite(blink_sit(f, n), 2, 15)
    bubbles = [(0, "W", 20), (1, "V", 14), (0, "W", 24), (1, "V", 18), (0, "W", 12), (1, "V", 22)]
    for k in range(6):
        side, fill, w = bubbles[(k + f // 2) % len(bubbles)]
        y = 1 + k * 5 - (f % 2) * 2
        if y < 0 or y > 24:
            continue
        x0 = 30 if side == 0 else 58 - w
        c.box(x0, y, x0 + w, y + 3, fill)
        tail = x0 + 2 if side == 0 else x0 + w - 2
        c.p(tail, y + 4, "K")
    return c


def l_time(f, n=12):
    c = L()
    c.sprite(blink_sit(f, n), 4, 15)
    x0, y0 = 36, 3
    flipped = f >= n - 2
    c.rect(x0 - 2, y0, x0 + 14, y0 + 1, "O"); c.rect(x0 - 2, y0 + 23, x0 + 14, y0 + 24, "O")
    c.vline(x0 - 1, y0 + 2, y0 + 22, "Y"); c.vline(x0 + 13, y0 + 2, y0 + 22, "Y")
    level = min(f, n - 3) / (n - 3)
    for y in range(11):
        half = 5 - y // 2
        for x in range(-half, half + 1):
            c.p(x0 + 6 + x, y0 + 2 + y, "W")
            c.p(x0 + 6 + x, y0 + 22 - y, "W")
        # outline
        c.p(x0 + 6 - half - 1, y0 + 2 + y, "K"); c.p(x0 + 6 + half + 1, y0 + 2 + y, "K")
        c.p(x0 + 6 - half - 1, y0 + 22 - y, "K"); c.p(x0 + 6 + half + 1, y0 + 22 - y, "K")
    top = int(round(8 * (1 - level))) if not flipped else 8
    bot = int(round(8 * level)) if not flipped else 0
    for y in range(top):
        half = 5 - (10 - y) // 2
        c.hline(x0 + 6 - half, x0 + 6 + half, y0 + 12 - y, "y")
    for y in range(bot):
        half = 5 - y // 2
        c.hline(x0 + 6 - half, x0 + 6 + half, y0 + 22 - y, "Y")
    if not flipped and f % 2 == 0:
        c.vline(x0 + 6, y0 + 13, y0 + 21 - bot, "y")
    return c


STROKES = [
    ("c", [(x, y) for y in range(0, 5) for x in range(0, 18)]),
    ("Y", [(13, 1), (14, 1), (13, 2), (14, 2), (12, 2), (15, 2), (13, 3), (14, 3)]),
    ("N", [(x, 5 + (x // 4) % 2) for x in range(18)] + [(x, 6) for x in range(18)]),
    ("n", [(x, y) for x in range(0, 9) for y in range(7, 10)]),
    ("g", [(x, y) for x in range(8, 18) for y in range(7, 10)]),
    ("q", [(x, y) for x in range(0, 18) for y in range(10, 12)]),
    ("r", [(4, 8), (4, 7), (5, 8), (3, 8)]),
    ("R", [(11, 9), (12, 9), (12, 8)]),
    ("W", [(2, 1), (3, 1), (4, 1), (3, 0)]),
]


def l_image(f, n=14):
    c = L()
    c.sprite("stand", 2, 11)
    # easel
    c.line(30, 28, 38, 2, "O"); c.line(54, 28, 46, 2, "O"); c.line(42, 18, 42, 28, "w")
    c.box(31, 4, 52, 19, "b")
    c.rect(29, 19, 55, 20, "O")
    done = min(f + 1, len(STROKES))
    paint = None
    for col, pts in STROKES[:done]:
        for x, y in pts:
            c.p(33 + x, 6 + y, col)
        paint = col
    # brush from the paw to the last stroke
    tx, ty = (33 + STROKES[done - 1][1][-1][0], 6 + STROKES[done - 1][1][-1][1]) if f < len(STROKES) else (33 + 9, 6 + 6)
    c.line(17, 22, min(tx, 30), max(ty, 12), "O")
    c.p(min(tx, 30) + 1, max(ty, 12), paint or "K")
    # palette
    c.disc(22, 25, 3, "b"); c.p(21, 24, "r"); c.p(23, 24, "Y"); c.p(22, 26, "n"); c.p(21, 26, "B")
    return c


CODE = [("v", 6), ("W", 12), ("W", 9), ("Y", 7), ("W", 14), ("V", 5), ("W", 10), ("Y", 11)]


def l_run_code(f, n=16):
    c = L()
    c.sprite("stand", 1, 11)
    c.box(22, 1, 56, 23, "L")
    c.rect(23, 21, 55, 22, "G")
    c.box(25, 3, 53, 19, "d", "K")
    typed = f * 4
    y = 5
    for col, length in CODE:
        if typed <= 0 or y > 17:
            break
        shown = min(length, typed)
        indent = 2 if col == "W" else 0
        c.hline(27 + indent, 27 + indent + shown * 2 - 1, y, col)
        typed -= length
        y += 2
    if f % 2 == 0 and y <= 17:
        c.rect(27, y - 1 if typed < 0 else y, 28, (y - 1 if typed < 0 else y), "V")
    # run light
    c.p(51, 21, "V" if f % 2 else "v")
    c.rect(33, 24, 45, 25, "G")
    c.rect(28, 26, 50, 27, "L")
    c.hline(28, 50, 28, "K")
    return c


def l_terminal(f, n=12):
    """The corrected typing mouse (compact.py's `big_terminal`)."""
    c = L()
    typist(c, f, x=4, y=14, keys=19)
    term_panel(c, 28, 1, 62, 26, f)
    return c


def l_read_files(f, n=12):
    c = L()
    c.sprite("read", 4, 11)
    # a page turning over the open book
    phase = f % 6
    pages = {1: [(17, 18), (18, 17), (19, 17)], 2: [(18, 16), (18, 15), (19, 15), (19, 16)],
             3: [(17, 15), (16, 15), (16, 16), (17, 16)], 4: [(15, 17), (16, 17), (16, 18)]}
    for x, y in pages.get(phase, []):
        c.p(x + 4, y + 2, "b"); c.p(x + 4, y + 1, "K")
    # the file stack it works through
    for i in range(4):
        x, y = 34 + i * 6, 6 + i * 4
        active = i == (f // 3) % 4
        c.box(x, y, x + 11, y + 13, "W" if active else "b", "K" if active else "G")
        c.hline(x + 2, x + 8, y + 3, "v" if active else "L")
        c.hline(x + 2, x + 6, y + 5, "G" if active else "L")
        c.hline(x + 2, x + 8, y + 7, "G" if active else "L")
    return c


def l_write_files(f, n=16):
    c = L()
    c.sprite("stand", 2, 11)
    x0, y0, x1, y1 = 22, 4, 46, 28
    c.box(x0, y0, x1, y1, "W")
    lines = [18, 14, 20, 10, 16, 19, 12]
    ink = f * 3
    tip = (x0 + 3, y0 + 4)
    for i, ln in enumerate(lines):
        if ink <= 0:
            break
        shown = min(ln, ink)
        y = y0 + 4 + i * 3
        c.hline(x0 + 3, x0 + 2 + shown, y, "v" if i == 0 else "K")
        tip = (x0 + 2 + shown, y)
        ink -= ln
    # quill
    tx, ty = tip
    wob = f % 2
    c.line(tx + 1, ty - 1, tx + 7, ty - 9 + wob, "O")
    c.line(tx + 3, ty - 4, tx + 9, ty - 11 + wob, "W")
    c.line(tx + 4, ty - 3, tx + 10, ty - 9 + wob, "W")
    c.line(tx + 2, ty - 4, tx + 8, ty - 12 + wob, "K")
    c.p(tx, ty, "K")
    # ink pot
    c.box(50, 22, 56, 28, "B"); c.rect(51, 21, 55, 21, "K")
    return c


def l_file_search(f, n=12):
    c = L()
    c.sprite("stand", 1, 11)
    found = (f // 4) % 3
    for i in range(3):
        x = 24 + i * 13
        c.box(x, 14, x + 10, 24, "Y", "K")
        c.rect(x + 1, 12, x + 4, 13, "Y"); c.p(x, 13, "K"); c.hline(x + 1, x + 4, 11, "K"); c.p(x + 5, 12, "K")
        c.hline(x + 1, x + 9, 15, "O")
        if i == found and f % 4 >= 2:
            c.rect(x + 3, 18, x + 7, 20, "n")
            c.p(x + 9, 9, "y"); c.p(x + 10, 8, "Y"); c.p(x + 11, 9, "y")
    mx = 29 + found * 13 + (f % 4) - 2
    my = 9 + (1 if f % 2 else 0)
    c.disc(mx, my, 4, "c"); c.ring(mx, my, 4, "K"); c.line(mx + 3, my + 4, mx + 6, my + 7, "w")
    c.p(mx - 2, my - 2, "W")
    return c


def l_skill(f, n=12):
    c = L()
    c.sprite("lantern", 2, 11)
    # lantern glow flicker
    glow = "y" if f % 3 else "Y"
    for x, y in ((24, 21), (24, 25), (19, 19), (25, 23)):
        if f % 2 == 0:
            c.p(x, y, glow)
    # scroll unrolling downwards
    length = min(4 + f * 2, 22)
    c.rect(30, 2, 52, 3, "O"); c.p(29, 2, "K"); c.p(53, 2, "K")
    c.box(31, 3, 51, 3 + length, "y", "O")
    for k in range(3, length - 1, 3):
        c.hline(34, 34 + (k * 7) % 14 + 2, 3 + k, "O" if k % 2 else "v")
    c.rect(30, 4 + length, 52, 5 + length, "O")
    return c


def l_sub_agent(f, n=12):
    c = L()
    c.sprite("stand", 0, 3)
    if f < 3:
        c.box(16, 12, 19, 15, "b", "K")  # the note at the paw
    run = "run1" if f % 2 else "run2"
    x = 4 + max(0, f - 2) * 6
    if f >= 2:
        c.sprite(run, x, 19)
        c.box(x + 20, 17, x + 23, 20, "b", "K")
    if f >= 9:
        c.p(8, 27, "G"); c.p(10, 28, "G"); c.p(6, 28, "G")  # dust
    return c


def l_tool(f, n=8):
    c = L()
    cx, cy, r = 32, 14, 14
    # A-frame legs outside the wheel, joined at the axle from behind
    c.line(cx, cy, cx - 12, 29, "O"); c.line(cx, cy, cx + 12, 29, "O")
    c.rect(cx - 16, 29, cx + 16, 29, "w")
    a0 = f * math.pi / 4 / 2
    for k in range(6):
        a = a0 + k * math.pi / 3
        c.line(cx, cy, round(cx + math.cos(a) * (r - 1)), round(cy + math.sin(a) * (r - 1)), "L")
    c.ring(cx, cy, r, "K")
    c.ring(cx, cy, r - 1, "G")
    c.disc(cx, cy, 1, "w")
    c.sprite("run1" if f % 2 else "run2", cx - 13, cy + r - 12)
    c.ring(cx, cy, r, "K")
    # spark from the axle
    if f % 4 == 0:
        c.p(cx + r + 3, cy - 8, "y"); c.p(cx + r + 4, cy - 9, "Y")
    return c


def l_still_writing(f, n=8):
    c = L()
    x = 8 + (f % 2)
    c.sprite("run1" if f % 2 else "run2", x + 10, 12)
    for k in range(3):
        c.hline(4 + k * 3 - (f % 3), 9 + k * 3 - (f % 3), 16 + k * 2, "L")
    return c


def l_waiting(f, n=12):
    c = L()
    c.rect(18, 26, 46, 28, "Y"); c.hline(18, 46, 29, "O")
    up = 0 if f < 6 else 1
    c.sprite("peek", 24, 13 - up)
    if f % 6 < 4:
        c.grid(QUESTION, 43, 3)
    return c


# =================================================================================================
# Compact scenes (34x14, compact.py): the head (13x9) with a small prop on the right
# =================================================================================================


def c_thinking(c, f, n):
    head(c, f, n)
    c.p(14, 5, INK); c.rect(16, 3, 17, 4, INK)  # the thought puffs (freestanding ink, #192)
    c.rect(20, 0, 32, 6, "K"); c.p(20, 0, "."); c.p(32, 0, "."); c.p(20, 6, "."); c.p(32, 6, ".")
    c.rect(21, 1, 31, 5, "W")
    dots = min(3, f // 3) if f < 12 else (3 if f % 2 == 0 else 0)
    for i in range(dots):
        c.rect(23 + i * 3, 3, 23 + i * 3 + 1, 3, "G" if i < 2 else "v")


def c_web(c, f, n):
    head(c, f, n)
    globe_face(c, 24, 6, 6, f, n)
    c.p(24 - 2, 6 - 3, "W")  # the compact globe's glint (compact.globe)
    c.hline(21, 27, 13, "O")


def c_read_page(c, f, n):
    head(c, f, n)
    x0, y0, x1, y1 = 16, 0, 33, 13
    c.box(x0, y0, x1, y1, "W")
    c.hline(x0 + 1, x1 - 1, y0 + 2, "L"); c.p(x0 + 2, y0 + 1, "r"); c.p(x0 + 4, y0 + 1, "Y"); c.p(x0 + 6, y0 + 1, "n")
    lens = [12, 8, 14, 10, 6, 13, 9]
    for k in range(5):
        ln = lens[(k + f) % len(lens)]
        c.hline(x0 + 2, x0 + 1 + min(ln, 14), y0 + 4 + k * 2, "v" if (k + f) % 5 == 0 else "G")
    mx, my = 26 + (f % 4 > 1), 5 + (f % n) * 5 // n
    c.disc(mx, my, 2, "c"); c.ring(mx, my, 2, "K"); c.p(mx + 2, my + 3, "w"); c.p(mx + 3, my + 4, "w")


def c_knowledge(c, f, n):
    head(c, f, n)
    c.rect(15, 12, 33, 13, "O"); c.hline(15, 33, 13, "w")
    books = [("B", 9), ("r", 8), ("n", 10), ("Y", 7), ("G", 9), ("B", 8), ("r", 10), ("n", 9), ("O", 8)]
    for i, (col, h) in enumerate(books[:6]):
        x = 16 + i * 3
        lift = 2 if i == f % 6 else 0
        c.rect(x, 12 - h - lift + 2, x + 1, 11 - lift, col)
        c.vline(x + 2, 12 - h - lift + 2, 11 - lift, "K")
        c.hline(x, x + 1, 12 - h - lift + 3, "y")


def c_memory(c, f, n):
    head(c, f, n)
    for i in range(4):
        x = 17 + i * 4
        up = 3 if i == f % 4 else 0
        c.box(x, 4 - up, x + 5, 9 - up, "b", "G")
        if up:
            c.hline(x + 1, x + 4, 6 - up, "v"); c.p(x + 6, 1, "y")
    c.box(15, 8, 33, 13, "O"); c.box(22, 9, 26, 11, "y", "w")


def c_past_chats(c, f, n):
    head(c, f, n)
    spec = [(0, "W", 11), (1, "V", 8), (0, "W", 13), (1, "V", 10)]
    for k in range(4):
        side, fill, w = spec[(k + f // 2) % len(spec)]
        y = k * 4 - (f % 2) * 2
        x0 = 16 if side == 0 else 33 - w
        if -3 < y < 13:
            c.box(x0, y, x0 + w, y + 2, fill)


def c_time(c, f, n):
    head(c, f, n)
    x0 = 20
    c.hline(x0, x0 + 10, 0, "O"); c.hline(x0, x0 + 10, 13, "O")
    flipped = f >= n - 2
    level = min(f, n - 3) / (n - 3)
    for y in range(6):
        half = 4 - y * 4 // 6
        for side, yy in ((0, 1 + y), (1, 12 - y)):
            c.hline(x0 + 5 - half, x0 + 5 + half, yy, "W")
            c.p(x0 + 4 - half, yy, "K"); c.p(x0 + 6 + half, yy, "K")
    top = 5 if flipped else round(5 * (1 - level))
    bot = 0 if flipped else round(5 * level)
    for y in range(top):
        half = 4 - (5 - y) * 4 // 6
        c.hline(x0 + 5 - half, x0 + 5 + half, 6 - y, "y")
    for y in range(bot):
        half = 4 - y * 4 // 6
        c.hline(x0 + 5 - half, x0 + 5 + half, 12 - y, "Y")
    if not flipped and f % 2 == 0:
        c.vline(x0 + 5, 7, 11 - bot, "y")


def c_image(c, f, n):
    head(c, f, n)
    c.box(17, 0, 33, 10, "b")
    strokes = [("c", [(x, y) for y in range(0, 3) for x in range(15)]), ("Y", [(11, 1), (12, 1)]),
               ("N", [(x, 3) for x in range(15)]), ("n", [(x, y) for x in range(7) for y in range(4, 6)]),
               ("g", [(x, y) for x in range(7, 15) for y in range(4, 6)]), ("q", [(x, 6) for x in range(15)]),
               ("r", [(3, 5), (3, 4)]), ("R", [(10, 5)])]
    done = min(f + 1, len(strokes))
    for col, pts in strokes[:done]:
        for x, y in pts:
            c.p(18 + x, 1 + y, col)
    c.line(19, 13, 21, 11, "O"); c.line(31, 13, 29, 11, "O")
    if f < len(strokes):
        tx, ty = strokes[done - 1][1][-1]
        c.line(14, 12, 18 + tx - 1, 1 + ty + 1, "O"); c.p(18 + tx, 1 + ty, strokes[done - 1][0])


def c_code(c, f, n):
    head(c, f, n)
    c.box(16, 0, 33, 11, "L")
    c.box(17, 1, 32, 9, "d", "K")
    lines = [("v", 4), ("W", 6), ("W", 5), ("Y", 4)]
    typed = f * 2
    for i, (col, ln) in enumerate(lines):
        if typed <= 0:
            break
        s = min(ln, typed)
        ind = 1 if col == "W" else 0
        c.hline(19 + ind * 2, 18 + ind * 2 + s * 2, 3 + i * 2 - 1 + 1, col)
        typed -= ln
    c.p(31, 10, "V" if f % 2 else "v")
    c.rect(23, 12, 26, 12, "G"); c.hline(20, 29, 13, "G")


def c_terminal(c, f, n):
    typist(c, f, x=1, y=0, keys=15)
    term_panel(c, 19, 0, 33, 12, f)


def c_read_files(c, f, n):
    head(c, f, n)
    c.box(24, 0, 33, 11, "b", "G")
    c.box(18, 2, 28, 13, "W")
    for k in range(4):
        y = 4 + k * 2
        active = k == (f // 2) % 4
        c.hline(20, 26 - (k % 2) * 2, y, "v" if active else "L")
    if f % 6 == 5:
        c.p(28, 1, "b"); c.p(29, 1, "b"); c.p(29, 2, "K")


def c_write_files(c, f, n):
    head(c, f, n)
    c.box(16, 1, 28, 13, "W")
    lens = [9, 6, 8, 5, 7]
    ink = f
    tip = (18, 3)
    for i, ln in enumerate(lens):
        if ink <= 0:
            break
        s = min(ln, ink)
        c.hline(18, 17 + s, 3 + i * 2, "v" if i == 0 else "K")
        tip = (17 + s, 3 + i * 2)
        ink -= ln
    tx, ty = tip
    c.line(tx + 1, ty - 1, tx + 4, ty - 5 + f % 2, "O")
    c.line(tx + 3, ty - 3, tx + 6, ty - 7 + f % 2, "W")
    c.p(tx, ty, "K")
    c.box(30, 9, 33, 13, "B")


def c_file_search(c, f, n):
    head(c, f, n)
    found = (f // 4) % 2
    for i in range(2):
        x = 16 + i * 9
        c.box(x, 6, x + 7, 13, "Y")
        c.hline(x + 1, x + 3, 5, "K"); c.p(x, 5, "."); c.rect(x + 1, 6, x + 3, 6, "Y")
        c.hline(x + 1, x + 6, 7, "O")
        if i == found and f % 4 >= 2:
            c.rect(x + 2, 9, x + 5, 10, "n")
    mx = 20 + found * 9 + (f % 4) - 1
    c.disc(mx, 3, 2, "c"); c.ring(mx, 3, 2, "K"); c.p(mx + 2, 6, "w"); c.p(mx + 3, 7, "w")


def c_skill(c, f, n):
    head(c, f, n)
    ln = min(3 + f, 10)
    c.hline(17, 31, 0, "O")
    c.box(18, 1, 30, 1 + ln, "y", "O")
    for k in range(3, ln, 2):
        c.hline(20, 20 + (k * 5) % 8 + 2, 1 + k, "O" if k % 4 == 1 else "v")
    c.hline(17, 31, 2 + ln, "O")
    c.p(14, 12, "Y" if f % 2 else "y")


def c_sub_agent(c, f, n):
    x = -6 + f * 4
    c.sprite("run1" if f % 2 else "run2", x, 3)
    c.box(x + 25, 1, x + 28, 4, "b")  # the note it carries off
    for k in range(3):
        c.hline(x - 6 + k, x - 3 + k, 6 + k * 2, "L")


def c_tool(c, f, n):
    head(c, f, n)
    cx, cy = 25, 7
    a0 = f * math.pi / 16
    for k in range(8):
        a = a0 + k * math.pi / 4
        c.rect(round(cx + math.cos(a) * 5.4), round(cy + math.sin(a) * 5.4), round(cx + math.cos(a) * 5.4), round(cy + math.sin(a) * 5.4), "G")
    c.disc(cx, cy, 4, "L"); c.ring(cx, cy, 4, "K"); c.disc(cx, cy, 1, "K")


def c_still(c, f, n):
    c.sprite("run1" if f % 2 else "run2", 6 + f % 2, 2)
    for k in range(3):
        c.hline(0 + k - f % 3, 3 + k - f % 3, 6 + k * 2, "L")


def c_waiting(c, f, n):
    # Deviation from the mock-up (it swapped in headEar at frames 4-5 and headBlink at 9): the head
    # holds still, so only the `?` blinks while the Response is paused on the user.
    c.sprite("head", 4, 5)
    if f % 6 < 4:
        c.grid(QUESTION, 19, 2)


def _compact(fn):
    def draw(f, n):
        c = C()
        fn(c, f, n)
        return c
    return draw


# =================================================================================================
# The scene table, in #185's order: the Swift case name -> each size's drawing and frame count, the
# still frame per size for Reduce Motion (large, compact), and what it's for.
# =================================================================================================
SCENES = {
    "thinking": dict(large=(l_thinking, 16), compact=(_compact(c_thinking), 16), still=(9, 9),
                     purpose="No tool: waiting, between parts, a quiet stream, reasoning. Sits and ponders; a thought bubble fills dot by dot."),
    "stillWriting": dict(large=(l_still_writing, 8), compact=(_compact(c_still), 8), still=(0, 0),
                         purpose="The stream resumed after a reconnect: the runner with speed lines."),
    "webSearch": dict(large=(l_web, 12), compact=(_compact(c_web), 12), still=(0, 0),
                      purpose="search_web, web_search: turns a desk globe."),
    "readingPage": dict(large=(l_read_page, 12), compact=(_compact(c_read_page), 12), still=(2, 2),
                        purpose="fetch_url: a browser page under a magnifier."),
    "knowledge": dict(large=(l_knowledge, 9), compact=(_compact(c_knowledge), 9), still=(2, 2),
                      purpose="Knowledge tools: a bookshelf, books slide out."),
    "memory": dict(large=(l_memory, 12), compact=(_compact(c_memory), 12), still=(1, 1),
                   purpose="Memory tools: an index-card box."),
    "pastChats": dict(large=(l_past_chats, 12), compact=(_compact(c_past_chats), 12), still=(0, 0),
                      purpose="search_chats, view_chat: scrolling chat bubbles."),
    "time": dict(large=(l_time, 12), compact=(_compact(c_time), 12), still=(5, 5),
                 purpose="*_timestamp: an hourglass."),
    "image": dict(large=(l_image, 14), compact=(_compact(c_image), 14), still=(8, 7),
                  purpose="generate_image, edit_image: paints at an easel."),
    "runningCode": dict(large=(l_run_code, 16), compact=(_compact(c_code), 16), still=(12, 9),
                        purpose="execute_code, run_code, code_interpreter: a CRT typing code."),
    "runningCommand": dict(large=(l_terminal, 12), compact=(_compact(c_terminal), 12), still=(0, 0),
                           purpose="Open Terminal process tools: faces you behind a keyboard, paws pressing keys in turn, beside a terminal."),
    "readingFiles": dict(large=(l_read_files, 12), compact=(_compact(c_read_files), 12), still=(1, 1),
                         purpose="read_file, list_files, display_file: a page turning, a file stack."),
    "writingFiles": dict(large=(l_write_files, 16), compact=(_compact(c_write_files), 16), still=(9, 9),
                         purpose="write_file, replace_file_content: a quill writing."),
    "searchingFiles": dict(large=(l_file_search, 12), compact=(_compact(c_file_search), 12), still=(2, 2),
                           purpose="grep/glob/match/search_files: a magnifier over folders."),
    "skill": dict(large=(l_skill, 12), compact=(_compact(c_skill), 12), still=(9, 7),
                  purpose="view_skill, read_skill_file: a scroll by lantern light."),
    "subAgent": dict(large=(l_sub_agent, 12), compact=(_compact(c_sub_agent), 12), still=(4, 3),
                     purpose="delegate_task: a runner carrying a note."),
    "tool": dict(large=(l_tool, 8), compact=(_compact(c_tool), 8), still=(0, 0),
                 purpose="Connectors, tool servers, Functions: a gear (compact), a hamster wheel (large)."),
    "waitingOnYou": dict(large=(l_waiting, 12), compact=(_compact(c_waiting), 12), still=(0, 0),
                         purpose="ask_user, a tool waiting for approval: a peek with a blinking ?."),
}


def frames(name: str, size: str) -> list[list[str]]:
    """Every frame of one scene at one size, as rows of glyphs."""
    fn, n = SCENES[name][size]
    return [fn(i, n).rows() for i in range(n)]
