"""Network, System and Logs tabs + the help overlay."""

import curses

from .util import fmt_age, fmt_bytes, fmt_dur, fmt_rate, to_int
from .collectors import LOG_UNITS
from .screens import ROLE_ORDER, dot, seg, svc_attr
from .widgets import (ACCENT, BAD, DIM, OK, RX, SYM, TEMP, TEXT, TITLE, TX,
                      WARN, box, color, graph, meter, put, put_r)


# --- network tab -----------------------------------------------------------------

def render_network(win, ctx):
    h, w = win.getmaxyx()
    lw = w // 2
    fo_h = min(13, max(10, (h - 2) // 2))
    _net_failover_box(win, 1, 0, fo_h, lw, ctx)
    modem_h = (h - 1) - (1 + fo_h)
    _net_modem_box(win, 1 + fo_h, 0, modem_h, lw, ctx)
    _net_ifaces_col(win, 1, lw, h - 2, w - lw, ctx)


def _net_failover_box(win, y, x, h, w, ctx):
    iy, ix, ih, iw = box(win, y, x, h, w, "FAILOVER WATCHDOG")
    fo, _ = ctx["fo"].snapshot()
    eth, _ = ctx["eth"].snapshot()
    st = fo.get("status")
    wd = eth.get("services", {}).get("w3p-failover", "unknown")
    row = iy
    put(win, row, ix, "service", color(DIM))
    put(win, row, ix + 9, wd, svc_attr(wd) | curses.A_BOLD)
    if fo.get("age") is not None:
        put_r(win, row, ix + iw, "status age %s" % fmt_age(fo["age"]),
              color(DIM) if fo["age"] < 90 else color(BAD))
    row += 1
    if not st:
        put(win, row, ix, "no status file - watchdog not running?",
            color(WARN))
        put(win, row + 1, ix,
            "baseline netplan metric ladder still applies:", color(DIM))
        put(win, row + 2, ix, "wired 100 > wifi 300 > lte 700", color(DIM))
        return
    active = st.get("active") or "none"
    put(win, row, ix, "active", color(DIM))
    put(win, row, ix + 9, active.upper(),
        (color(BAD, bold=True) if st.get("all_down")
         else color(WARN, bold=True) if active == "lte"
         else color(OK, bold=True)))
    put_r(win, row, ix + iw, "switches %s" % st.get("switches", 0), color(TEXT))
    row += 1
    flags = []
    if st.get("all_down"):
        flags.append(("ALL LINKS DOWN", color(BAD, bold=True)))
    if st.get("latched"):
        flags.append(("flap-latched %s left" % fmt_dur(fo.get("latch_remain", 0)),
                      color(BAD)))
    if st.get("escalated"):
        flags.append(("escalated: beacon restart spent", color(WARN)))
    if st.get("verifying"):
        flags.append(("verifying %s" % st["verifying"], color(WARN)))
    if not flags:
        flags = [("no incidents", color(OK))]
    xmax = ix + iw
    x2 = ix
    for text, attr in flags:
        x2 = seg(win, row, x2, xmax, text + "   ", attr)
    row += 2
    put(win, row, ix, "link   health  iface   ip               gw"[:iw],
        color(DIM))
    row += 1
    links = st.get("links", {})
    for role in ROLE_ORDER:
        li = links.get(role, {})
        health = li.get("health", "absent")
        dot(win, row, ix, health == "up", warn=(health == "absent"))
        x2 = seg(win, row, ix + 2, xmax, "%-6s " % role,
                 color(TEXT, bold=(role == st.get("active"))))
        x2 = seg(win, row, x2, xmax, "%-7s " % health,
                 color(OK) if health == "up"
                 else (color(DIM) if health == "absent" else color(BAD)))
        x2 = seg(win, row, x2, xmax, "%-7s " % (li.get("if") or "-"),
                 color(ACCENT))
        x2 = seg(win, row, x2, xmax, "%-16s " % (li.get("ip") or "-"),
                 color(TEXT))
        seg(win, row, x2, xmax, li.get("gw") or "-", color(DIM))
        row += 1
    row += 1 if row < iy + ih - 1 else 0
    routes = fo.get("routes") or []
    if routes and row <= iy + ih - 1:
        put(win, row, ix, "default routes:", color(DIM))
        row += 1
        for r in routes[:3]:
            if row > iy + ih - 1:
                break
            put(win, row, ix + 2, "via %-15s dev %-7s metric %s"
                % (r.get("gw") or "-", r.get("dev"), r.get("metric")),
                color(TEXT))
            row += 1


def _net_modem_box(win, y, x, h, w, ctx):
    iy, ix, ih, iw = box(win, y, x, h, w, "LTE MODEM")
    modem, _ = ctx["modem"].snapshot()
    vn, _ = ctx["vnstat"].snapshot()
    row = iy
    if not modem.get("present"):
        put(win, row, ix, "no USB LTE modem detected (cdc_ether/rndis)",
            color(DIM))
        return
    put(win, row, ix, "device", color(DIM))
    put(win, row, ix + 9, "%s  gw %s" % (modem.get("dev"), modem.get("gw") or "-"),
        color(TEXT))
    row += 1
    info = modem.get("info")
    if not info:
        if row <= iy + ih - 1:
            put(win, row, ix, "modem API not reachable", color(WARN))
        row += 1
    else:
        # modem JSON values are untrusted strings — never int() them raw
        sig = max(0, min(5, to_int(info.get("signalbar"), 0)))
        if row <= iy + ih - 1:
            put(win, row, ix, "signal", color(DIM))
            meter(win, row, ix + 9, 12, sig / 5.0,
                  color(OK) if sig >= 3
                  else (color(WARN) if sig == 2 else color(BAD)))
            put(win, row, ix + 22, "%d/5" % sig, color(TEXT, bold=True))
            put_r(win, row, ix + iw, "%s @ %s"
                  % (info.get("network_type", "?"),
                     info.get("network_provider", "?")), color(TEXT))
        row += 1
        if row <= iy + ih - 1:
            rsrp, snr = info.get("lte_rsrp"), info.get("lte_snr")
            ppp = info.get("ppp_status", "?")
            sim = info.get("pin_status")
            put(win, row, ix, ("rsrp %s dBm   snr %s dB   ppp %s   sim %s"
                % (rsrp or "-", snr or "-", ppp,
                   sim if sim not in (None, "") else "-"))[:iw], color(DIM))
        row += 1
        if row <= iy + ih - 1:
            mrx = fmt_bytes(int(info["monthly_rx_bytes"])) \
                if str(info.get("monthly_rx_bytes", "")).isdigit() else "-"
            mtx = fmt_bytes(int(info["monthly_tx_bytes"])) \
                if str(info.get("monthly_tx_bytes", "")).isdigit() else "-"
            put(win, row, ix, "modem month: %s%s %s%s"
                % (SYM["down"], mrx, SYM["up"], mtx), color(DIM))
        row += 1
    usage = vn.get("usage")
    if usage and row <= iy + ih - 1:
        put(win, row, ix, "vnstat today (%s):" % usage["today_date"], color(DIM))
        put(win, row, ix + 22, "%s%s %s%s = %s"
            % (SYM["down"], usage["today_rx"], SYM["up"], usage["today_tx"],
               usage["today_total"]), color(TEXT))
        row += 1
        if row <= iy + ih - 1:
            put(win, row, ix, "vnstat month (%s):" % usage["month"], color(DIM))
            put(win, row, ix + 22, "%s%s %s%s = %s"
                % (SYM["down"], usage["month_rx"], SYM["up"], usage["month_tx"],
                   usage["month_total"]), color(TEXT, bold=True))


def _net_ifaces_col(win, y, x, h, w, ctx):
    net, _ = ctx["net"].snapshot()
    ifaces = net.get("ifaces", {})
    order = [n for n in net.get("order", []) if n in ifaces]
    if not order:
        box(win, y, x, h, w, "INTERFACES")
        return
    bh = max(4, h // len(order))
    for idx, name in enumerate(order):
        by = y + idx * bh
        if by + 3 > y + h:
            break
        i = ifaces[name]
        this_h = bh if idx < len(order) - 1 else (y + h - by)
        title = "%s (%s)" % (name, i["role"])
        iy, ix, ih, iw = box(win, by, x, this_h, w, title)
        up = i["oper"] == "up"
        dot(win, by, x + len(title) + 4, up)
        x2 = seg(win, iy, ix, ix + iw, "%s %-12s"
                 % (SYM["down"], fmt_rate(i["rx_bps"])), color(RX, bold=True))
        x2 = seg(win, iy, x2 + 1, ix + iw, "%s %-12s"
                 % (SYM["up"], fmt_rate(i["tx_bps"])), color(TX, bold=True))
        totals = "ip %s  %s %s%s %s%s" % (
            i.get("ip") or "-", SYM["sum"], SYM["down"],
            fmt_bytes(i["rx_total"]), SYM["up"], fmt_bytes(i["tx_total"]))
        if ix + iw - len(totals) > x2 + 1:
            put(win, iy, ix + iw - len(totals), totals, color(DIM))
        gh = ih - 1
        if gh >= 1:
            half = iw // 2 - 1
            vmax = graph(win, iy + 1, ix, gh, half, i["rx_hist"], color(RX),
                         ctx["style"])
            put(win, iy + 1, ix, fmt_rate(vmax), color(DIM))
            vmax = graph(win, iy + 1, ix + half + 2, gh, iw - half - 2,
                         i["tx_hist"], color(TX), ctx["style"])
            put(win, iy + 1, ix + half + 2, fmt_rate(vmax), color(DIM))


# --- system tab -------------------------------------------------------------------

def render_system(win, ctx):
    h, w = win.getmaxyx()
    sysc = ctx["sys"]
    d, _ = sysc.snapshot()
    lw = w // 2
    cpu_h = min(14, max(9, (h - 2) * 55 // 100))
    _sys_cpu_box(win, 1, 0, cpu_h, lw, ctx, d)
    _sys_temp_box(win, 1, lw, cpu_h, w - lw, ctx, d)
    _sys_mem_disk_box(win, 1 + cpu_h, 0, h - 1 - (1 + cpu_h), lw, ctx, d)
    _sys_misc_box(win, 1 + cpu_h, lw, h - 1 - (1 + cpu_h), w - lw, ctx, d)


def _sys_cpu_box(win, y, x, h, w, ctx, d):
    cpu = d.get("cpu_pct", 0.0)
    title = "CPU %.0f%%  %s MHz  %s" % (
        cpu, d.get("freq_mhz") or "?", d.get("governor") or "")
    iy, ix, ih, iw = box(win, y, x, h, w, title)
    sysc = ctx["sys"]
    cores = d.get("core_pct") or []
    rows_cores = (len(cores) + 1) // 2
    gh = max(2, ih - rows_cores - 1)
    graph(win, iy, ix, gh, iw, sysc.cpu_hist, color(ACCENT), ctx["style"],
          vmax=100.0)
    row = iy + gh
    load = d.get("load", (0, 0, 0))
    put(win, row, ix, "load avg  %.2f  %.2f  %.2f   (%d cores)"
        % (load + (len(cores) or 1,)), color(DIM))
    row += 1
    half = iw // 2
    for i, c in enumerate(cores):
        cy = row + i // 2
        cx = ix + (i % 2) * half
        if cy > iy + ih - 1:
            break
        put(win, cy, cx, "c%-2d" % (i + 1), color(DIM))
        meter(win, cy, cx + 3, half - 10, c / 100.0)
        put(win, cy, cx + half - 6, "%4.0f%%" % c, color(TEXT))


def _sys_temp_box(win, y, x, h, w, ctx, d):
    temps = d.get("temps", {})
    tc = temps.get("cpu")
    title = "TEMPERATURE  cpu %s  nvme %s" % (
        "%.0f°C" % tc if tc is not None else "-",
        "%.0f°C" % temps["nvme"] if temps.get("nvme") is not None else "-")
    iy, ix, ih, iw = box(win, y, x, h, w, title)
    thr = d.get("throttled") or {}
    gh = ih - 1 if thr else ih
    graph(win, iy, ix, gh, iw, ctx["sys"].temp_hist, color(TEMP),
          ctx["style"], vmax=100.0)
    put(win, iy, ix, "scale 0-100°C", color(DIM))
    if thr:
        bits = []
        for key, label in (("undervolt_now", "UNDERVOLT"),
                           ("throttled_now", "THROTTLED"),
                           ("capped_now", "FREQ-CAPPED"),
                           ("undervolt_ever", "undervolt seen since boot"),
                           ("throttled_ever", "throttling seen since boot")):
            if thr.get(key):
                bits.append((label, color(BAD, bold=key.endswith("now"))))
        if not bits:
            bits = [("power OK, no throttling", color(OK))]
        x2 = ix
        for text, attr in bits:
            put(win, iy + ih - 1, x2, text + "  ", attr)
            x2 += len(text) + 2


def _sys_mem_disk_box(win, y, x, h, w, ctx, d):
    iy, ix, ih, iw = box(win, y, x, h, w, "MEMORY / DISKS")
    mem = d.get("mem", {})
    row = iy
    put(win, row, ix, ("mem  %s / %s   avail %s   cached %s"
        % (fmt_bytes(mem.get("used")), fmt_bytes(mem.get("total")),
           fmt_bytes(mem.get("avail")), fmt_bytes(mem.get("cached"))))[:iw],
        color(TEXT))
    row += 1
    meter(win, row, ix, iw, mem.get("pct", 0) / 100.0,
          label="%.0f%%" % mem.get("pct", 0))
    row += 1
    if mem.get("swap_total") and row <= iy + ih - 1:
        put(win, row, ix, "swap %s / %s" % (fmt_bytes(mem.get("swap_used")),
                                            fmt_bytes(mem.get("swap_total"))),
            color(TEXT))
        row += 1
        if row <= iy + ih - 1:
            meter(win, row, ix, iw, mem.get("swap_pct", 0) / 100.0,
                  label="%.0f%%" % mem.get("swap_pct", 0))
            row += 1
    row += 1 if row <= iy + ih - 1 else 0
    for disk in d.get("disks", []):
        if row + 2 > iy + ih:           # need label row AND meter row inside
            break
        put(win, row, ix, "%-8s %s" % (disk["label"], disk["path"]),
            color(TEXT, bold=True))
        put_r(win, row, ix + iw, "%s / %s  (%s free)"
              % (fmt_bytes(disk["used"], 0), fmt_bytes(disk["total"], 0),
                 fmt_bytes(disk["free"], 0)), color(DIM))
        row += 1
        meter(win, row, ix, iw, disk["pct"] / 100.0,
              label="%.0f%%" % disk["pct"])
        row += 1


def _sys_misc_box(win, y, x, h, w, ctx, d):
    iy, ix, ih, iw = box(win, y, x, h, w, "DISK I/O / NODE PROCESSES / TIME")
    sysc = ctx["sys"]
    io = d.get("diskio", {})
    put(win, iy, ix, ("read %-12s write %-12s"
                      % (fmt_rate(io.get("read_bps")),
                         fmt_rate(io.get("write_bps"))))[:iw], color(TEXT))
    gh = min(4, ih - 6)
    if gh >= 1:
        half = iw // 2 - 1
        graph(win, iy + 1, ix, gh, half, sysc.io_read_hist, color(RX),
              ctx["style"])
        graph(win, iy + 1, ix + half + 2, gh, iw - half - 2,
              sysc.io_write_hist, color(TX), ctx["style"])
    row = iy + 1 + max(0, gh)
    if row <= iy + ih - 1:
        put(win, row, ix, ("%-10s %10s %8s" % ("process", "rss", "cpu"))[:iw],
            color(DIM))
    row += 1
    short = {"geth": "geth", "nimbus_beacon_node": "beacon",
             "nimbus_validator_client": "validator"}
    procs = d.get("procs") or []
    if not procs and row <= iy + ih - 1:
        put(win, row, ix, "no node processes running"[:iw], color(BAD))
        row += 1
    for p in procs:
        if row > iy + ih - 1:
            break
        put(win, row, ix, ("%-10s %10s %7.0f%%"
                           % (short.get(p["name"], p["name"]),
                              fmt_bytes(p["rss"]), p["cpu"]))[:iw], color(TEXT))
        row += 1
    ntp = d.get("ntp")
    if row <= iy + ih - 1:
        if ntp:
            put(win, row, ix, ("chrony: offset %+.1f ms  stratum %s"
                % (ntp["offset"] * 1000, ntp["stratum"]))[:iw],
                color(OK) if abs(ntp["offset"]) < 0.05 else color(WARN))
        else:
            put(win, row, ix, "chrony: no data"[:iw], color(DIM))
        row += 1
    if row <= iy + ih - 1 and d.get("uptime_s"):
        put(win, row, ix, ("uptime %s" % fmt_dur(d["uptime_s"], 3))[:iw],
            color(DIM))


# --- logs tab ----------------------------------------------------------------------

def render_logs(win, ctx):
    h, w = win.getmaxyx()
    logs, _ = ctx["logs"].snapshot()
    unit = ctx["logs"].unit
    x = 1
    put(win, 1, x, "unit:", color(DIM))
    x += 6
    for u in LOG_UNITS:
        label = " %s " % u
        if x + len(label) >= w - 1:
            break
        attr = color(TITLE, bold=True) | curses.A_REVERSE if u == unit \
            else color(TEXT)
        put(win, 1, x, label, attr)
        x += len(label) + 1
    hint = "arrows: unit / scroll  End: follow"
    if w - 1 - len(hint) > x:
        put_r(win, 1, w - 1, hint, color(DIM))

    title = "dmesg -T" if unit == "dmesg" else "journal - %s" % unit
    iy, ix, ih, iw = box(win, 2, 0, h - 3, w, title)
    lines = logs.get("lines") or []
    if logs.get("unit") != unit:
        put(win, iy, ix, "loading %s ..." % unit, color(DIM))
        return
    if not lines:
        msg = ("no dmesg output (kernel.dmesg_restrict? run as root)"
               if unit == "dmesg" else
               "no journal entries (permissions? run as root "
               "or add user to systemd-journal group)")
        put(win, iy, ix, msg, color(WARN))
        return
    scroll = ctx.get("log_scroll", 0)
    end = len(lines) - scroll
    start = max(0, end - ih)
    for i, (level, text) in enumerate(lines[start:end]):
        attr = {"bad": color(BAD), "warn": color(WARN)}.get(level, color(TEXT))
        put(win, iy + i, ix, text[:iw], attr)
    if scroll:
        put_r(win, iy, ix + iw, " %s %d older " % (SYM["up"], scroll),
              color(WARN))


# --- help overlay -----------------------------------------------------------------

HELP_LINES = (
    ("1-5", "switch tab (Tab / Shift-Tab cycles)"),
    ("left/right", "Logs tab: switch log source"),
    ("up/down PgUp/Dn", "Logs tab: scroll; End = follow"),
    ("p", "pause / resume screen updates"),
    ("g", "cycle graph style (braille / block / ascii)"),
    ("+/-", "faster / slower refresh"),
    ("h or ?", "toggle this help"),
    ("q or Ctrl-C", "quit (ignored in HDMI kiosk mode)"),
)


def render_help(win):
    h, w = win.getmaxyx()
    bh, bw = len(HELP_LINES) + 4, 58
    y, x = max(0, (h - bh) // 2), max(0, (w - bw) // 2)
    for i in range(bh):
        put(win, y + i, x, " " * bw)
    iy, ix, ih, iw = box(win, y, x, bh, bw, "KEYS  (h to close)")
    for i, (key, desc) in enumerate(HELP_LINES):
        put(win, iy + 1 + i, ix + 1, "%-16s" % key, color(ACCENT, bold=True))
        put(win, iy + 1 + i, ix + 18, desc[: iw - 18], color(TEXT))
