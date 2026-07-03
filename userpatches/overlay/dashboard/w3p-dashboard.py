#!/usr/bin/env python3
"""Web3 Pi vOS — live node & system console dashboard.

Zero-dependency (Python stdlib only). Shows Ethereum client sync/peers state,
WAN failover status, per-interface traffic, and system resources — designed
for the HDMI console during a WAN outage, and for SSH sessions.

Usage:
    w3p-dashboard [--refresh N] [--style braille|block|ascii] [--tab N]
    w3p-dashboard --check     # one-shot text dump of all collectors (no TUI)
"""

import argparse
import curses
import locale
import os
import signal
import sys
import time

# realpath: the program is also invoked via the /usr/local/bin/w3p-dashboard
# symlink — the package lives next to the real file, not the symlink
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))

from w3pdash import __version__                                   # noqa: E402
from w3pdash.collectors import (LogsCollector, NetCollector,      # noqa: E402
                                SystemCollector, LOG_UNITS)
from w3pdash.nodecollectors import (EthCollector, FailoverCollector,  # noqa: E402
                                    ModemCollector, VnstatCollector)
from w3pdash import screens, screens_extra, widgets               # noqa: E402

STYLES = ("braille", "block", "ascii")
MIN_H, MIN_W = 15, 60


def build_ctx(style, tab, refresh):
    ctx = {
        "sys": SystemCollector(), "net": NetCollector(),
        "eth": EthCollector(), "fo": FailoverCollector(),
        "modem": ModemCollector(), "vnstat": VnstatCollector(),
        "logs": LogsCollector(),
        "style": style, "tab": tab, "refresh": refresh,
        "paused": False, "help": False, "log_scroll": 0,
        "kiosk": os.environ.get("W3P_KIOSK") == "1",
    }
    for key in ("sys", "net", "eth", "fo", "modem", "vnstat", "logs"):
        ctx[key].start()
    return ctx


def handle_key(ctx, key):
    if key in (ord("q"), ord("Q")):
        # kiosk (HDMI console service): quitting would leave a dead console
        # and systemd would respawn us anyway — disable via control-panel
        return ctx["kiosk"]
    if key in (ord("h"), ord("?")):
        ctx["help"] = not ctx["help"]
    elif key == ord("p"):
        ctx["paused"] = not ctx["paused"]
    elif key == ord("g"):
        ctx["style"] = STYLES[(STYLES.index(ctx["style"]) + 1) % len(STYLES)]
    elif key in (ord("+"), ord("=")):
        ctx["refresh"] = max(0.5, ctx["refresh"] / 2)
    elif key == ord("-"):
        ctx["refresh"] = min(10.0, ctx["refresh"] * 2)
    elif ord("1") <= key <= ord("0") + len(screens.TABS):
        ctx["tab"] = key - ord("1")
        ctx["log_scroll"] = 0
    elif key == 9:                                    # Tab
        ctx["tab"] = (ctx["tab"] + 1) % len(screens.TABS)
    elif key == curses.KEY_BTAB:
        ctx["tab"] = (ctx["tab"] - 1) % len(screens.TABS)
    elif ctx["tab"] == 4:                             # Logs tab keys
        logs = ctx["logs"]
        nlines = len((logs.data or {}).get("lines") or [])
        if key in (curses.KEY_LEFT, curses.KEY_RIGHT):
            i = LOG_UNITS.index(logs.unit)
            step = 1 if key == curses.KEY_RIGHT else -1
            logs.unit = LOG_UNITS[(i + step) % len(LOG_UNITS)]
            ctx["log_scroll"] = 0
        elif key == curses.KEY_UP:
            ctx["log_scroll"] = max(0, min(nlines - 1, ctx["log_scroll"] + 1))
        elif key == curses.KEY_DOWN:
            ctx["log_scroll"] = max(0, ctx["log_scroll"] - 1)
        elif key == curses.KEY_PPAGE:
            ctx["log_scroll"] = min(max(0, nlines - 1), ctx["log_scroll"] + 20)
        elif key == curses.KEY_NPAGE:
            ctx["log_scroll"] = max(0, ctx["log_scroll"] - 20)
        elif key == curses.KEY_END:
            ctx["log_scroll"] = 0
    elif key in (curses.KEY_LEFT, curses.KEY_RIGHT):
        step = 1 if key == curses.KEY_RIGHT else -1
        ctx["tab"] = (ctx["tab"] + step) % len(screens.TABS)
    return True


RENDERERS = (screens.render_overview, screens.render_ethereum,
             screens_extra.render_network, screens_extra.render_system,
             screens_extra.render_logs)


def draw(stdscr, ctx):
    stdscr.erase()
    h, w = stdscr.getmaxyx()
    if h < MIN_H or w < MIN_W:
        widgets.put(stdscr, 0, 0, "terminal too small (need %dx%d)"
                    % (MIN_W, MIN_H))
        stdscr.refresh()
        return
    screens.draw_header(stdscr, ctx)
    RENDERERS[ctx["tab"]](stdscr, ctx)
    screens.draw_footer(stdscr, ctx)
    if ctx["help"]:
        screens_extra.render_help(stdscr)
    stdscr.refresh()


def tui(stdscr, ctx):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    widgets.init_theme()
    stdscr.timeout(150)
    last = 0.0
    while True:
        try:
            key = stdscr.getch()
            dirty = False
            if key == curses.KEY_RESIZE:
                dirty = True
            elif key != -1:
                if not handle_key(ctx, key):
                    return
                dirty = True
            now = time.monotonic()
            if dirty or (not ctx["paused"] and now - last >= ctx["refresh"]):
                draw(stdscr, ctx)
                last = now
        except KeyboardInterrupt:
            if not ctx["kiosk"]:
                return


def check_mode(ctx):
    """One collection cycle as plain text — debugging aid, no TTY needed."""
    print("w3p-dashboard %s — collector check" % __version__)
    time.sleep(3.5)
    for name in ("sys", "net", "eth", "fo", "modem", "vnstat", "logs"):
        data, age = ctx[name].snapshot()
        print("\n== %s (age %.1fs) ==" % (name, age))
        for k, v in sorted(data.items(), key=lambda kv: kv[0]):
            if k == "lines":
                v = "%d lines" % len(v or [])
            if k == "ifaces":
                v = {n: {kk: vv for kk, vv in i.items()
                         if not kk.endswith("_hist")} for n, i in v.items()}
            print("  %-12s %s" % (k, v))


def main():
    # best-effort: SSH commonly forwards a locale the box doesn't have
    # (macOS sends LC_CTYPE=UTF-8) and setlocale would die on it
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        try:
            locale.setlocale(locale.LC_ALL, "C.UTF-8")
        except locale.Error:
            pass
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--refresh", type=float, default=1.0,
                    help="UI refresh interval in seconds (default 1)")
    ap.add_argument("--style", choices=STYLES,
                    default=widgets.pick_graph_style(),
                    help="graph style (default: auto by terminal)")
    ap.add_argument("--tab", type=int, default=1, choices=range(1, 6),
                    help="start tab 1-5")
    ap.add_argument("--check", action="store_true",
                    help="print one collector snapshot and exit")
    ap.add_argument("--version", action="version", version=__version__)
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    ctx = build_ctx(args.style, args.tab - 1, max(0.5, args.refresh))
    if args.check:
        check_mode(ctx)
        return
    try:
        curses.wrapper(tui, ctx)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
