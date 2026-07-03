"""Header/footer, shared status logic, Overview and Ethereum tabs."""

import curses
import socket
import time

from . import __version__
from .util import fmt_age, fmt_bytes, fmt_dur, fmt_num, fmt_rate
from .widgets import (ACCENT, BAD, DIM, OK, RX, SYM, TEMP, TEXT, TITLE, TX,
                      WARN, box, color, graph, hline, meter, put, put_r)

TABS = ("Overview", "Ethereum", "Network", "System", "Logs")

DOT_ON, DOT_OFF = SYM["on"], SYM["off"]


def svc_attr(state):
    if state == "active":
        return color(OK)
    if state in ("activating", "reloading", "deactivating"):
        return color(WARN)
    return color(BAD)


def dot(win, y, x, on, warn=False):
    attr = color(OK) if on else (color(WARN) if warn else color(BAD))
    put(win, y, x, DOT_ON if on else DOT_OFF, attr)
    return attr


# --- shared status derivation -------------------------------------------------

def el_status(el):
    """-> (label, attr, sub) for the execution client."""
    if el.get("service") is False and not el.get("api"):
        return "STOPPED", color(BAD), "service inactive"
    if not el.get("api"):
        return "NO API", color(BAD), "rpc :8545 not responding"
    if el.get("syncing"):
        return ("SYNCING", color(WARN),
                "%s / %s" % (fmt_num(el.get("current")), fmt_num(el.get("highest"))))
    age = el.get("head_age")
    if age is None:
        return "NO HEAD", color(WARN), "cannot read latest block"
    if age > 300:
        return "STALLED", color(BAD), "head %s old" % fmt_age(age)
    if age > 90:
        return "BEHIND", color(WARN), "head %s old" % fmt_age(age)
    return "SYNCED", color(OK), None


def age_attr(age):
    """Color for a head-age value: unknown is dim, never a reassuring green."""
    if age is None:
        return color(DIM)
    if age <= 90:
        return color(OK)
    return color(WARN) if age <= 300 else color(BAD)


def cl_status(cl):
    """-> (label, attr, sub) for the consensus client."""
    if cl.get("service") is False and not cl.get("api"):
        return "STOPPED", color(BAD), "service inactive"
    if not cl.get("api"):
        return "NO API", color(BAD), "rest :5052 not responding"
    dist = cl.get("sync_dist") or 0
    if dist <= 2 and not cl.get("is_syncing"):
        return "SYNCED", color(OK), None
    if dist <= 2:
        return "SYNCED", color(OK), None
    label = "SYNCING" if cl.get("is_syncing") else "BEHIND"
    return label, color(WARN) if dist < 300 else color(BAD), \
        "%s slots behind" % fmt_num(dist)


def gap_text(el):
    gap = el.get("gap")
    if gap is None:
        return "-", color(DIM)
    if gap == 0:
        return "0", color(OK)
    txt = ("~%s" % fmt_num(gap)) if el.get("gap_est") else fmt_num(gap)
    return txt, color(WARN) if gap < 1000 else color(BAD)


# --- header / footer -----------------------------------------------------------

def draw_header(win, ctx):
    h, w = win.getmaxyx()
    eth, _ = ctx["eth"].snapshot()
    bar = curses.A_REVERSE
    hline(win, 0, 0, w, " ", bar)
    put(win, 0, 1, "WEB3 PI", bar | curses.A_BOLD)
    put(win, 0, 9, "dashboard", bar)
    host = socket.gethostname()
    put(win, 0, 20, host, bar | curses.A_BOLD)
    net = "[%s]" % (eth.get("network") or "?").upper()
    left_end = 21 + len(host) + 1 + len(net)
    put(win, 0, 21 + len(host) + 1, net, bar)
    clock = time.strftime("%Y-%m-%d %H:%M:%S")
    clock_x = w - 1 - len(clock)
    put(win, 0, clock_x, clock, bar | curses.A_BOLD)
    sys_d, _ = ctx["sys"].snapshot()
    up = sys_d.get("uptime_s")
    if up:
        mid = "up %s" % fmt_dur(up)
        mx = max(left_end + 2, (w - len(mid)) // 2)
        if mx + len(mid) < clock_x - 1:
            put(win, 0, mx, mid, bar)


def draw_footer(win, ctx):
    h, w = win.getmaxyx()
    y = h - 1
    hline(win, y, 0, w, " ", curses.A_REVERSE)
    x = 1
    for i, name in enumerate(TABS):
        label = " %d %s " % (i + 1, name)
        attr = curses.A_REVERSE | (curses.A_BOLD if i == ctx["tab"] else 0)
        if i == ctx["tab"]:
            attr = color(TITLE, bold=True)
        put(win, y, x, label, attr)
        x += len(label)
    hint = "p pause  g style  h help" if ctx.get("kiosk") \
        else "q quit  p pause  g style  h help"
    if ctx.get("paused"):
        hint = "PAUSED (p resume)  " + hint
    # never let the right side stomp the tab labels on narrow terminals
    for right in (" %s  v%s " % (hint, __version__), " %s " % hint, " h help "):
        if w - 1 - len(right) > x:
            put_r(win, y, w - 1, right, curses.A_REVERSE)
            break


# --- overview: ethereum panel ---------------------------------------------------

def seg(win, row, x, xmax, text, attr=0):
    """put() clipped to the panel's right edge; returns the next x."""
    if x < xmax:
        put(win, row, x, text[: max(0, xmax - x)], attr)
    return x + len(text)


def panel_ethereum(win, y, x, h, w, ctx):
    iy, ix, ih, iw = box(win, y, x, h, w, "ETHEREUM")
    eth, age = ctx["eth"].snapshot()
    el, cl = eth.get("el", {}), eth.get("cl", {})
    xmax = ix + iw
    row = iy

    label, attr, sub = el_status(el)
    x2 = seg(win, row, ix, xmax, "EL geth   ", color(TEXT, bold=True))
    x2 = seg(win, row, x2, xmax, label, attr | curses.A_BOLD)
    if el.get("block") is not None:
        x2 = seg(win, row, x2 + 2, xmax, "block ", color(DIM))
        x2 = seg(win, row, x2, xmax, fmt_num(el["block"]), color(TEXT, bold=True))
    row += 1
    gap, gattr = gap_text(el)
    peers = el.get("peers")
    x2 = seg(win, row, ix + 2, xmax, "peers ", color(DIM))
    x2 = seg(win, row, x2, xmax, "%s" % (peers if peers is not None else "-"),
             color(OK) if (peers or 0) >= 3 else color(BAD))
    x2 = seg(win, row, x2 + 2, xmax, "gap ", color(DIM))
    x2 = seg(win, row, x2, xmax, gap, gattr)
    x2 = seg(win, row, x2 + 2, xmax, "head age ", color(DIM))
    x2 = seg(win, row, x2, xmax, fmt_age(el.get("head_age")),
             age_attr(el.get("head_age")))
    if sub and xmax - len(sub) > x2 + 1:
        put(win, row, xmax - len(sub), sub, color(DIM))
    row += 1

    label, attr, sub = cl_status(cl)
    x2 = seg(win, row, ix, xmax, "CL nimbus ", color(TEXT, bold=True))
    x2 = seg(win, row, x2, xmax, label, attr | curses.A_BOLD)
    if cl.get("head_slot"):
        x2 = seg(win, row, x2 + 2, xmax, "slot ", color(DIM))
        x2 = seg(win, row, x2, xmax, fmt_num(cl["head_slot"]),
                 color(TEXT, bold=True))
    row += 1
    peers = cl.get("peers")
    x2 = seg(win, row, ix + 2, xmax, "peers ", color(DIM))
    x2 = seg(win, row, x2, xmax, "%s" % (peers if peers is not None else "-"),
             color(OK) if (peers or 0) >= 10 else color(BAD))
    dist = cl.get("sync_dist")
    x2 = seg(win, row, x2 + 2, xmax, "dist ", color(DIM))
    x2 = seg(win, row, x2, xmax, fmt_num(dist) if dist is not None else "-",
             color(OK) if (dist or 0) <= 2 else color(WARN))
    if cl.get("optimistic"):
        seg(win, row, x2 + 2, xmax, "optimistic (EL behind)", color(WARN))
    elif sub and xmax - len(sub) > x2 + 1:
        put(win, row, xmax - len(sub), sub, color(DIM))
    row += 1

    if eth.get("backfill"):
        put(win, row, ix + 2, "backfill %s" % eth["backfill"], color(DIM))
        row += 1

    svcs = eth.get("services", {})
    put(win, row, ix, "VC", color(TEXT, bold=True))
    vc = svcs.get("nimbus-validator", "unknown")
    put(win, row, ix + 10, vc, svc_attr(vc) | curses.A_BOLD)
    row += 1

    if row <= iy + ih - 1:
        x2 = ix
        put(win, row, x2, "svc", color(DIM))
        x2 += 4
        for svc, short in (("geth", "geth"), ("nimbus-beacon-node", "beacon"),
                           ("nimbus-validator", "vc"), ("w3p-failover", "failover")):
            st = svcs.get(svc, "unknown")
            put(win, row, x2, DOT_ON if st == "active" else DOT_OFF, svc_attr(st))
            put(win, row, x2 + 1, short, color(TEXT))
            x2 += len(short) + 3
    if age > 15:
        put_r(win, iy, ix + iw, "stale %s" % fmt_age(age), color(BAD))


# --- overview: failover panel ---------------------------------------------------

ROLE_ORDER = ("wired", "wifi", "lte")


def panel_failover(win, y, x, h, w, ctx):
    iy, ix, ih, iw = box(win, y, x, h, w, "FAILOVER / WAN")
    fo, _ = ctx["fo"].snapshot()
    st = fo.get("status")
    eth, _ = ctx["eth"].snapshot()
    wd_state = eth.get("services", {}).get("w3p-failover", "unknown")
    row = iy

    if not st:
        put(win, row, ix, "no status file", color(WARN))
        put(win, row + 1, ix, "watchdog: %s" % wd_state, svc_attr(wd_state))
        put(win, row + 2, ix, "baseline metric ladder still active",
            color(DIM))
        _routes_line(win, iy + ih - 1, ix, iw, fo)
        return

    active = (st.get("active") or "none").upper()
    aattr = color(OK, bold=True)
    if st.get("active") == "lte":
        aattr = color(WARN, bold=True)
    if st.get("all_down") or st.get("active") in (None, "", "none"):
        active, aattr = "NONE", color(BAD, bold=True)
    put(win, row, ix, "ACTIVE:", color(DIM))
    put(win, row, ix + 8, active, aattr)
    if st.get("active") == "lte":
        put(win, row, ix + 8 + len(active) + 1, "(metered)", color(WARN))
    put_r(win, row, ix + iw, "switches %s" % st.get("switches", 0), color(DIM))
    row += 1

    links = st.get("links", {})
    modem, _ = ctx["modem"].snapshot()
    xmax2 = ix + iw
    for role in ROLE_ORDER:
        li = links.get(role, {})
        health = li.get("health", "absent")
        on = health == "up"
        dot(win, row, ix, on, warn=(health == "absent"))
        x2 = seg(win, row, ix + 2, xmax2, "%-5s " % role,
                 color(TEXT, bold=(st.get("active") == role)))
        x2 = seg(win, row, x2, xmax2, "%-7s " % health,
                 color(OK) if on
                 else (color(DIM) if health == "absent" else color(BAD)))
        x2 = seg(win, row, x2, xmax2, "%-6s " % (li.get("if") or "-"),
                 color(ACCENT))
        x2 = seg(win, row, x2, xmax2, li.get("ip") or "-", color(TEXT))
        if role == "lte":
            info = modem.get("info") or {}
            sig = info.get("signalbar")
            if sig:
                tail = "sig %s/5 %s" % (sig, info.get("network_type", ""))
                if xmax2 - len(tail) > x2 + 1:
                    put(win, row, xmax2 - len(tail), tail, color(TEXT))
        row += 1

    vn, _ = ctx["vnstat"].snapshot()
    usage = vn.get("usage")
    xmax = ix + iw
    if usage and row <= iy + ih - 1:
        x2 = seg(win, row, ix, xmax, "LTE data ", color(DIM))
        x2 = seg(win, row, x2, xmax, "today %s" % usage["today_total"],
                 color(TEXT))
        seg(win, row, x2 + 2, xmax, "month %s" % usage["month_total"],
            color(TEXT, bold=True))
        row += 1

    warn_bits = []
    if st.get("all_down"):
        warn_bits.append(("ALL LINKS DOWN", color(BAD, bold=True)))
    if st.get("latched"):
        warn_bits.append(("FLAP LATCHED %s" % fmt_dur(fo.get("latch_remain", 0)),
                          color(BAD, bold=True)))
    if st.get("escalated"):
        warn_bits.append(("escalated (beacon restarted)", color(WARN)))
    if st.get("verifying"):
        warn_bits.append(("verifying %s" % st["verifying"], color(WARN)))
    if wd_state != "active":
        warn_bits.append(("watchdog %s" % wd_state, color(BAD)))
    elif fo.get("age") is not None and fo["age"] > 90:
        # threshold: the daemon's cycle legitimately stretches to ~40-60 s
        # during multi-link outages (serial probes) — don't cry wolf
        warn_bits.append(("status stale %s" % fmt_age(fo["age"]), color(BAD)))
    if warn_bits and row <= iy + ih - 1:
        x2 = ix
        for text, attr in warn_bits:
            x2 = seg(win, row, x2, xmax, SYM["warn"] + " " + text + "  ", attr)
        row += 1
    if iy + ih - 1 >= row:              # room left: routes on the last line
        _routes_line(win, iy + ih - 1, ix, iw, fo)


def _routes_line(win, y, ix, iw, fo):
    routes = fo.get("routes") or []
    if not routes:
        return
    txt = "routes: " + "  ".join(
        "%s m%s" % (r["dev"], r["metric"]) for r in routes[:4])
    put(win, y, ix, txt[:iw], color(DIM))


# --- overview: system panel -----------------------------------------------------

def panel_system(win, y, x, h, w, ctx):
    iy, ix, ih, iw = box(win, y, x, h, w, "SYSTEM")
    sysc = ctx["sys"]
    d, _ = sysc.snapshot()
    row = iy
    temps = d.get("temps", {})

    xmax = ix + iw
    cpu = d.get("cpu_pct", 0.0)
    x2 = seg(win, row, ix, xmax, "CPU ", color(TEXT, bold=True))
    x2 = seg(win, row, x2, xmax, "%3.0f%%" % cpu,
             color(OK) if cpu < 70 else (color(WARN) if cpu < 90 else color(BAD)))
    if d.get("freq_mhz"):
        x2 = seg(win, row, x2 + 2, xmax, "%d MHz" % d["freq_mhz"], color(DIM))
    load = d.get("load", (0, 0, 0))
    tc = temps.get("cpu")
    tail = "%.0f°C" % tc if tc is not None else ""
    load_txt = "load %.2f %.2f %.2f" % load
    if xmax - len(tail) - 1 - (x2 + 2) >= len(load_txt):
        seg(win, row, x2 + 2, xmax - len(tail) - 1, load_txt, color(DIM))
    if tail:
        put(win, row, xmax - len(tail), tail,
            color(OK) if tc < 70 else (color(WARN) if tc < 80 else color(BAD)))
    row += 1

    gh = 3 if ih >= 12 else (2 if ih >= 10 else 0)
    if gh:
        graph(win, row, ix, gh, iw, sysc.cpu_hist, color(ACCENT),
              ctx["style"], vmax=100.0)
        row += gh

    cores = d.get("core_pct") or []
    if cores and row <= iy + ih - 1:
        cw = max(6, iw // len(cores))
        for i, c in enumerate(cores[: iw // 6]):
            cx = ix + i * cw
            put(win, row, cx, "%d" % (i + 1), color(DIM))
            meter(win, row, cx + 1, cw - 2, c / 100.0)
        row += 1

    mem = d.get("mem", {})
    if row > iy + ih - 1:
        return
    put(win, row, ix, "MEM", color(TEXT, bold=True))
    put(win, row, ix + 4, "%4.0f%%" % mem.get("pct", 0),
        color(OK) if mem.get("pct", 0) < 80 else color(WARN))
    put(win, row, ix + 11, "%s / %s" % (fmt_bytes(mem.get("used")),
                                        fmt_bytes(mem.get("total"))), color(DIM))
    swap_pct = mem.get("swap_pct", 0)
    put_r(win, row, ix + iw, "swap %.0f%%" % swap_pct,
          color(DIM) if swap_pct < 50 else color(WARN))
    row += 1
    if row <= iy + ih - 1:
        meter(win, row, ix, iw, mem.get("pct", 0) / 100.0)
        row += 1

    for disk in d.get("disks", []):
        if row > iy + ih - 1:
            break
        put(win, row, ix, "%-8s" % disk["label"], color(TEXT))
        mw = max(10, iw - 34)
        meter(win, row, ix + 9, mw, disk["pct"] / 100.0)
        put(win, row, ix + 9 + mw + 1, "%3.0f%%" % disk["pct"], color(TEXT))
        put_r(win, row, ix + iw, "%s free" % fmt_bytes(disk["free"], 0),
              color(DIM))
        row += 1

    if row <= iy + ih - 1:
        io = d.get("diskio", {})
        bits = "io r %s w %s" % (fmt_rate(io.get("read_bps")),
                                 fmt_rate(io.get("write_bps")))
        tn = temps.get("nvme")
        if tn is not None:
            bits += "   nvme %.0f°C" % tn
        ntp = d.get("ntp")
        if ntp:
            bits += "   ntp %+.0f ms" % (ntp["offset"] * 1000)
        put(win, row, ix, bits[:iw], color(DIM))
        row += 1

    thr = d.get("throttled") or {}
    alerts = []
    if thr.get("undervolt_now"):
        alerts.append("UNDER-VOLTAGE")
    if thr.get("throttled_now"):
        alerts.append("THROTTLED")
    if alerts and row <= iy + ih - 1:
        put(win, row, ix, SYM["warn"] + " " + " / ".join(alerts),
            color(BAD, bold=True))
        row += 1

    procs = d.get("procs") or []
    if procs and row <= iy + ih - 1:
        x2 = ix
        short = {"geth": "geth", "nimbus_beacon_node": "beacon",
                 "nimbus_validator_client": "vc"}
        for p in procs:
            txt = "%s %s %3.0f%%" % (short.get(p["name"], p["name"]),
                                     fmt_bytes(p["rss"], 1), p["cpu"])
            put(win, row, x2, txt, color(TEXT))
            x2 += len(txt) + 3
            if x2 >= ix + iw:
                break


# --- overview: network panel ----------------------------------------------------

def panel_network(win, y, x, h, w, ctx):
    iy, ix, ih, iw = box(win, y, x, h, w, "NETWORK")
    net, _ = ctx["net"].snapshot()
    ifaces = net.get("ifaces", {})
    order = [n for n in net.get("order", []) if ifaces.get(n)]
    if not order:
        put(win, iy, ix, "no interfaces", color(DIM))
        return
    row = iy
    xmax = ix + iw
    per = 3 if ih >= 3 * len(order) else (2 if ih >= 2 * len(order) else 1)
    for name in order:
        if row > iy + ih - 1:
            break
        i = ifaces[name]
        up = i["oper"] == "up"
        dot(win, row, ix, up)
        x2 = seg(win, row, ix + 2, xmax, "%-7s" % name, color(ACCENT, bold=True))
        if iw >= 52:
            x2 = seg(win, row, x2 + 1, xmax, "%-5s" % i["role"], color(DIM))
        x2 = seg(win, row, x2 + 1, xmax,
                 "%s%-11s" % (SYM["down"], fmt_rate(i["rx_bps"])), color(RX))
        x2 = seg(win, row, x2 + 1, xmax,
                 "%s%-11s" % (SYM["up"], fmt_rate(i["tx_bps"])), color(TX))
        totals = "%s %s%s %s%s" % (SYM["sum"], SYM["down"],
                                   fmt_bytes(i["rx_total"]),
                                   SYM["up"], fmt_bytes(i["tx_total"]))
        if xmax - len(totals) > x2 + 1:
            put(win, row, xmax - len(totals), totals, color(DIM))
        row += 1
        if per >= 2:
            gh = per - 1
            half = iw // 2 - 1
            graph(win, row, ix, gh, half, i["rx_hist"], color(RX), ctx["style"])
            graph(win, row, ix + half + 2, gh, iw - half - 2, i["tx_hist"],
                  color(TX), ctx["style"])
            row += gh


# --- overview ------------------------------------------------------------------

def render_overview(win, ctx):
    h, w = win.getmaxyx()
    ch = h - 2
    lw = w // 2
    top_h = min(10, max(8, ch // 2 - 2))
    panel_ethereum(win, 1, 0, top_h, lw, ctx)
    panel_failover(win, 1, lw, top_h, w - lw, ctx)
    panel_system(win, 1 + top_h, 0, ch - top_h, lw, ctx)
    panel_network(win, 1 + top_h, lw, ch - top_h, w - lw, ctx)


# --- ethereum tab ----------------------------------------------------------------

def render_ethereum(win, ctx):
    h, w = win.getmaxyx()
    eth, _ = ctx["eth"].snapshot()
    el, cl = eth.get("el", {}), eth.get("cl", {})
    ec = ctx["eth"]

    info_h = min(9, max(8, (h - 2) // 3))
    iy, ix, ih, iw = box(win, 1, 0, info_h, w, "CLIENTS")
    xmax = ix + iw
    row = iy
    label, attr, sub = el_status(el)
    gap, gattr = gap_text(el)
    x2 = seg(win, row, ix, xmax, "EL geth   ", color(TEXT, bold=True))
    x2 = seg(win, row, x2, xmax, label, attr | curses.A_BOLD)
    x2 = seg(win, row, x2 + 2, xmax, "block %s   peers %s   gap "
             % (fmt_num(el.get("block")),
                el.get("peers") if el.get("peers") is not None else "-"),
             color(TEXT))
    x2 = seg(win, row, x2, xmax, gap, gattr)
    if sub and xmax - len(sub) > x2 + 1:
        put(win, row, xmax - len(sub), sub, color(DIM))
    row += 1
    ver = eth.get("el_version")
    if ver:
        put(win, row, ix + 2, str(ver)[: iw - 2], color(DIM))
    row += 1
    label, attr, sub = cl_status(cl)
    x2 = seg(win, row, ix, xmax, "CL nimbus ", color(TEXT, bold=True))
    x2 = seg(win, row, x2, xmax, label, attr | curses.A_BOLD)
    x2 = seg(win, row, x2 + 2, xmax, "slot %s   peers %s   dist %s"
             % (fmt_num(cl.get("head_slot")),
                cl.get("peers") if cl.get("peers") is not None else "-",
                fmt_num(cl.get("sync_dist"))), color(TEXT))
    flags = []
    if cl.get("optimistic"):
        flags.append("optimistic")
    if cl.get("el_offline"):
        flags.append("el_offline")
    if flags:
        txt = " ".join(flags)
        if xmax - len(txt) > x2 + 1:
            put(win, row, xmax - len(txt), txt, color(WARN))
    row += 1
    ver = eth.get("cl_version")
    if ver:
        put(win, row, ix + 2, str(ver)[: iw - 2], color(DIM))
    row += 1
    svcs = eth.get("services", {})
    x2 = ix
    for svc in ("geth", "nimbus-beacon-node", "nimbus-validator", "w3p-failover"):
        st = svcs.get(svc, "?")
        if x2 < xmax:
            put(win, row, x2, DOT_ON if st == "active" else DOT_OFF,
                svc_attr(st))
        x2 = seg(win, row, x2 + 2, xmax, "%s: %s" % (svc, st), color(TEXT)) + 2
    row += 1
    if row <= iy + ih - 1:
        bits = "network %s" % (eth.get("network") or "?").upper()
        if eth.get("backfill"):
            bits += "    backfill %s" % eth["backfill"]
        put(win, row, ix, bits[:iw], color(DIM))

    gy = 1 + info_h
    gh = (h - 1 - gy) // 2
    gw2 = w // 2
    _graph_box(win, gy, 0, gh, gw2, "EL peers", ec.el_peers_hist,
               color(ACCENT), ctx, cur=fmt_num(el.get("peers")))
    _graph_box(win, gy, gw2, gh, w - gw2, "CL peers", ec.cl_peers_hist,
               color(ACCENT), ctx, cur=fmt_num(cl.get("peers")))
    _graph_box(win, gy + gh, 0, h - 1 - gy - gh, gw2, "EL gap (blocks)",
               ec.gap_hist, color(TEMP), ctx, cur=gap_text(el)[0])
    _graph_box(win, gy + gh, gw2, h - 1 - gy - gh, w - gw2,
               "CL sync distance (slots)", ec.dist_hist, color(TEMP), ctx,
               cur=fmt_num(cl.get("sync_dist")))


def _graph_box(win, y, x, h, w, title, series, attr, ctx, cur=None):
    if h < 3:
        return
    iy, ix, ih, iw = box(win, y, x, h, w, title)
    vmax = graph(win, iy, ix, ih, iw, series, attr, ctx["style"])
    put_r(win, y, x + w - 2, " now %s  max %s " % (cur, fmt_num(int(vmax))),
          color(DIM))
