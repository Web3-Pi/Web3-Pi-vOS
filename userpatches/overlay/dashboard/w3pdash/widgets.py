"""Curses drawing primitives: theme/colors, safe text, boxes, meters and
history graphs (braille / block / ascii styles).

Style notes: the Linux console (TERM=linux, HDMI screen) has no braille glyphs
in its font and only 8 colors — 'block' style and the 8-color fallback exist
for exactly that target. Braille is the pretty path over SSH."""

import curses
import os
from collections import deque

# --- theme ------------------------------------------------------------------
# Semantic color slots; init_theme() fills PAIR with curses pair numbers.
OK, WARN, BAD, TITLE, BORDER, DIM, ACCENT, TEXT, RX, TX, TEMP = range(1, 12)
PAIR = {}

# Glyph set: the kernel console font (TERM=linux on the HDMI screen) lacks
# braille, eighth-blocks, arrows and most symbols — fall back to ASCII there.
# Box-drawing chars are present in console fonts, so borders stay unicode.
_TTY = os.environ.get("TERM", "") == "linux"
SYM = {
    "on": "*" if _TTY else "●",
    "off": "o" if _TTY else "○",
    "warn": "!" if _TTY else "⚠",
    "down": "v" if _TTY else "▼",
    "up": "^" if _TTY else "▲",
    "sum": "S" if _TTY else "Σ",
    "fill": "#" if _TTY else "■",
    "empty": "." if _TTY else "·",
}

_COLORS_256 = {
    OK: 114, WARN: 220, BAD: 196, TITLE: 51, BORDER: 240, DIM: 244,
    ACCENT: 45, TEXT: 252, RX: 49, TX: 205, TEMP: 203,
}
_COLORS_8 = {
    OK: curses.COLOR_GREEN, WARN: curses.COLOR_YELLOW, BAD: curses.COLOR_RED,
    TITLE: curses.COLOR_CYAN, BORDER: curses.COLOR_WHITE, DIM: curses.COLOR_WHITE,
    ACCENT: curses.COLOR_CYAN, TEXT: curses.COLOR_WHITE,
    RX: curses.COLOR_CYAN, TX: curses.COLOR_MAGENTA, TEMP: curses.COLOR_RED,
}


def init_theme():
    curses.start_color()
    try:
        curses.use_default_colors()
        bg = -1
    except curses.error:
        bg = curses.COLOR_BLACK
    table = _COLORS_256 if curses.COLORS >= 256 else _COLORS_8
    for slot, color in table.items():
        try:
            curses.init_pair(slot, color, bg)
        except curses.error:
            curses.init_pair(slot, curses.COLOR_WHITE, bg)
        PAIR[slot] = curses.color_pair(slot)


def color(slot, bold=False):
    attr = PAIR.get(slot, 0)
    return attr | curses.A_BOLD if bold else attr


def status_color(good, warn=False):
    if good:
        return color(OK)
    return color(WARN) if warn else color(BAD)


# --- safe drawing -----------------------------------------------------------

def put(win, y, x, text, attr=0):
    """addstr that clips to the window and never raises."""
    try:
        h, w = win.getmaxyx()
        if y < 0 or y >= h or x >= w or x < 0:
            return
        win.addstr(y, x, text[: max(0, w - x)], attr)
    except curses.error:
        pass  # writing the bottom-right cell always raises; harmless


def put_r(win, y, x_right, text, attr=0):
    """Right-aligned put: text ends at column x_right (exclusive)."""
    put(win, y, max(0, x_right - len(text)), text, attr)


def hline(win, y, x, w, ch="─", attr=0):
    put(win, y, x, ch * max(0, w), attr)


def box(win, y, x, h, w, title="", title_attr=None):
    """Border with a title embedded in the top edge. Returns inner rect."""
    if h < 2 or w < 4:
        return (y, x, 0, 0)
    b = color(BORDER)
    hline(win, y, x + 1, w - 2, "─", b)
    hline(win, y + h - 1, x + 1, w - 2, "─", b)
    for i in range(1, h - 1):
        put(win, y + i, x, "│", b)
        put(win, y + i, x + w - 1, "│", b)
    put(win, y, x, "┌", b)
    put(win, y, x + w - 1, "┐", b)
    put(win, y + h - 1, x, "└", b)
    put(win, y + h - 1, x + w - 1, "┘", b)
    if title:
        t = " %s " % title
        put(win, y, x + 2, t[: w - 4], title_attr if title_attr is not None
            else color(TITLE, bold=True))
    return (y + 1, x + 1, h - 2, w - 2)


def meter(win, y, x, w, frac, attr=None, label=""):
    """[■■■■■     ] bar; frac 0..1; auto color by level unless attr given."""
    if w < 4:
        return
    frac = min(1.0, max(0.0, frac or 0.0))
    inner = w - 2
    fill = int(round(inner * frac))
    if attr is None:
        attr = color(OK) if frac < 0.7 else (color(WARN) if frac < 0.9
                                             else color(BAD))
    put(win, y, x, "[", color(DIM))
    put(win, y, x + 1 + inner, "]", color(DIM))
    if fill:
        put(win, y, x + 1, SYM["fill"] * fill, attr)
    if fill < inner:
        put(win, y, x + 1 + fill, SYM["empty"] * (inner - fill), color(DIM))
    if label:
        put(win, y, x + 1 + max(0, (inner - len(label)) // 2), label,
            attr | curses.A_BOLD)


# --- history series + graphs -------------------------------------------------

class Series:
    """Bounded history of floats for graphing. None = 'no data at that tick'
    and renders as a hole in the graph, not as a fake zero."""

    def __init__(self, maxlen=300):
        self.data = deque(maxlen=maxlen)

    def push(self, v):
        self.data.append(None if v is None else float(v))

    def last(self, default=0.0):
        return self.data[-1] if self.data else default

    def window(self, n):
        # collectors append from their own threads while the UI reads;
        # list(deque) can raise if a push lands mid-iteration — retry
        for _ in range(3):
            try:
                d = list(self.data)
                break
            except RuntimeError:
                continue
        else:
            d = []
        return d[-n:] if n < len(d) else d


# rows top->bottom; braille dots: left col 1,2,3,7 = 0x01,0x02,0x04,0x40,
# right col 4,5,6,8 = 0x08,0x10,0x20,0x80
_BRAILLE_DOTS = ((0x01, 0x08), (0x02, 0x10), (0x04, 0x20), (0x40, 0x80))
_BLOCKS = " ▁▂▃▄▅▆▇█"


def pick_graph_style():
    """braille over ssh/xterm; plain ascii on the raw HDMI console — the
    kernel console font has neither braille nor eighth-block glyphs. 'block'
    stays available via the g key for console fonts that do carry blocks."""
    term = os.environ.get("TERM", "")
    return "ascii" if term == "linux" else "braille"


def graph(win, y, x, h, w, series, attr, style="braille", vmax=None):
    """Render series into an h-rows × w-cols region, newest sample at the
    right edge. None samples render as gaps. Returns the vmax used."""
    if h < 1 or w < 1:
        return 0
    per_col = 2 if style == "braille" else 1
    samples = series.window(w * per_col) if isinstance(series, Series) else list(series)[-w * per_col:]
    known = [s for s in samples if s is not None]
    if not known:
        return 0
    scale = vmax if vmax else max(known)
    if scale <= 0:
        scale = 1.0
    norm = [None if s is None else min(1.0, s / scale) for s in samples]

    if style == "braille":
        cols = (len(norm) + 1) // 2
        for c in range(cols):
            i = len(norm) - (cols - c) * 2
            v1 = norm[i] if i >= 0 else None
            v2 = norm[i + 1] if i + 1 < len(norm) and i + 1 >= 0 else None
            gx = x + w - cols + c
            _braille_col(win, y, gx, h, v1, v2, attr)
    elif style == "block":
        for c, v in enumerate(norm):
            if v is None:
                continue
            gx = x + w - len(norm) + c
            lvl = v * h * 8
            full, part = int(lvl // 8), int(lvl % 8)
            for r in range(h):
                row_from_bottom = h - 1 - r
                if row_from_bottom < full:
                    put(win, y + r, gx, "█", attr)
                elif row_from_bottom == full and part:
                    put(win, y + r, gx, _BLOCKS[part], attr)
    else:  # ascii
        for c, v in enumerate(norm):
            if v is None:
                continue
            gx = x + w - len(norm) + c
            lvl = int(round(v * h))
            for r in range(h):
                if h - 1 - r < lvl:
                    put(win, y + r, gx, "#", attr)
    return scale


def _braille_col(win, y, x, h, v1, v2, attr):
    """One braille column: two normalized samples across h rows (4 dots/row)."""
    dots_h = h * 4
    l1 = 0 if v1 is None else max(1 if v1 > 0 else 0, int(round(v1 * dots_h)))
    l2 = 0 if v2 is None else max(1 if v2 > 0 else 0, int(round(v2 * dots_h)))
    for r in range(h):
        top = dots_h - r * 4  # dot heights covered by this row: top-3..top
        ch = 0
        for d in range(4):  # d=0 top dot of the row
            dot_level = top - d
            if l1 >= dot_level:
                ch |= _BRAILLE_DOTS[d][0]
            if l2 >= dot_level:
                ch |= _BRAILLE_DOTS[d][1]
        if ch:
            put(win, y + r, x, chr(0x2800 + ch), attr)
