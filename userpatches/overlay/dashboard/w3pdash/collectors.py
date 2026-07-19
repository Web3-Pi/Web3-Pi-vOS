"""Background collectors: system resources, network interfaces, journal logs.
Each collector runs in its own thread on its own interval; the UI thread only
reads snapshots. A failing source leaves stale/None data — never an exception
that reaches curses."""

import glob
import os
import re
import threading
import time

from .util import read_file, read_int, run_cmd, run_json, to_int
from .widgets import Series


class Collector(threading.Thread):
    interval = 2.0

    def __init__(self):
        super().__init__(daemon=True)
        self._lock = threading.Lock()
        self._stop = threading.Event()
        self.data = {}
        # construction counts as "fresh": snapshot age must not read as a
        # huge staleness before the first collect() lands
        self.updated = time.monotonic()

    def run(self):
        while not self._stop.is_set():
            started = time.monotonic()
            try:
                fresh = self.collect()
                with self._lock:
                    self.data.update(fresh)
                    self.updated = time.monotonic()
            except Exception:
                pass  # a collector must never die; stale data is the signal
            elapsed = time.monotonic() - started
            self._stop.wait(max(0.2, self.interval - elapsed))

    def stop(self):
        self._stop.set()

    def snapshot(self):
        with self._lock:
            return dict(self.data), time.monotonic() - self.updated

    def collect(self):
        raise NotImplementedError


# --- system -------------------------------------------------------------------

DISK_MOUNTS = (("/", "root"), ("/var/lib/el", "EL data"), ("/var/lib/cl", "CL data"))
NODE_PROCS = ("geth", "nimbus_beacon_node", "nimbus_validator_client")
# /proc/<pid>/comm is capped at 15 chars by the kernel (TASK_COMM_LEN-1) —
# match on the truncated form, display the full name
_COMM15 = {n[:15]: n for n in NODE_PROCS}
_WHOLE_DISK = re.compile(r"^(nvme\d+n\d+|sd[a-z]+|mmcblk\d+|vd[a-z]+)$")


class SystemCollector(Collector):
    interval = 1.0

    def __init__(self):
        super().__init__()
        self._prev_stat = None          # per-cpu (busy, total)
        self._prev_disk = None          # (t, read_bytes, write_bytes)
        self._prev_proc = {}            # pid -> (t, proc_jiffies)
        self._tick = 0
        self._hz = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100
        self.cpu_hist = Series()
        self.temp_hist = Series()
        self.io_read_hist = Series()
        self.io_write_hist = Series()
        self.core_hist = []             # created on first sample
        self.data = {"ntp": None, "throttled": None}

    def collect(self):
        d = {}
        d["cpu_pct"], d["core_pct"] = self._cpu()
        self.cpu_hist.push(d["cpu_pct"])
        if d["core_pct"] and not self.core_hist:
            self.core_hist = [Series(150) for _ in d["core_pct"]]
        for s, v in zip(self.core_hist, d["core_pct"] or []):
            s.push(v)
        d["load"] = self._load()
        d["mem"] = self._mem()
        d["temps"] = self._temps()
        if d["temps"].get("cpu") is not None:
            self.temp_hist.push(d["temps"]["cpu"])
        d["freq_mhz"] = self._freq()
        d["governor"] = read_file(
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor")
        d["uptime_s"] = self._uptime()
        d["disks"] = self._disks()
        d["diskio"] = self._diskio()
        self.io_read_hist.push(d["diskio"]["read_bps"])
        self.io_write_hist.push(d["diskio"]["write_bps"])
        d["procs"] = self._procs()
        self._tick += 1
        if self._tick % 30 == 1:                 # every ~30 s
            d["ntp"] = self._chrony()
            d["throttled"] = self._throttled()
        return d

    def _cpu(self):
        txt = read_file("/proc/stat", "")
        cur = {}
        for line in txt.splitlines():
            if not line.startswith("cpu"):
                break
            f = line.split()
            name, vals = f[0], [int(v) for v in f[1:]]
            total = sum(vals)
            idle = vals[3] + (vals[4] if len(vals) > 4 else 0)
            cur[name] = (total - idle, total)
        prev, self._prev_stat = self._prev_stat, cur
        if not prev or not cur:
            return 0.0, []

        def pct(name):
            if name not in prev or name not in cur:
                return 0.0
            db = cur[name][0] - prev[name][0]
            dt = cur[name][1] - prev[name][1]
            return 100.0 * db / dt if dt > 0 else 0.0

        cores = sorted((k for k in cur if k != "cpu"),
                       key=lambda s: to_int(s[3:]))
        return pct("cpu"), [pct(c) for c in cores]

    def _load(self):
        f = (read_file("/proc/loadavg", "") or "").split()
        try:
            return (float(f[0]), float(f[1]), float(f[2]))
        except (IndexError, ValueError):
            return (0.0, 0.0, 0.0)

    def _mem(self):
        info = {}
        for line in (read_file("/proc/meminfo", "") or "").splitlines():
            parts = line.split()
            if len(parts) >= 2:
                info[parts[0].rstrip(":")] = to_int(parts[1]) * 1024
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", 0)
        used = total - avail
        stotal = info.get("SwapTotal", 0)
        sused = stotal - info.get("SwapFree", 0)
        return {"total": total, "used": used, "avail": avail,
                "cached": info.get("Cached", 0),
                "pct": 100.0 * used / total if total else 0.0,
                "swap_total": stotal, "swap_used": sused,
                "swap_pct": 100.0 * sused / stotal if stotal else 0.0}

    def _temps(self):
        temps = {}
        for zone in glob.glob("/sys/class/thermal/thermal_zone*"):
            ztype = (read_file(zone + "/type") or "").lower()
            t = read_int(zone + "/temp")
            if t is None:
                continue
            if "cpu" in ztype or "soc" in ztype or zone.endswith("zone0"):
                temps.setdefault("cpu", t / 1000.0)
        for hw in glob.glob("/sys/class/hwmon/hwmon*"):
            name = (read_file(hw + "/name") or "").lower()
            t = read_int(hw + "/temp1_input")
            if t is None:
                continue
            if "nvme" in name:
                temps["nvme"] = t / 1000.0
            elif "cpu" not in temps and ("cpu" in name or "soc" in name):
                temps["cpu"] = t / 1000.0
        return temps

    def _freq(self):
        f = read_int("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
        return f // 1000 if f else None

    def _uptime(self):
        f = (read_file("/proc/uptime", "") or "").split()
        try:
            return float(f[0])
        except (IndexError, ValueError):
            return None

    def _disks(self):
        seen, out = set(), []
        for path, label in DISK_MOUNTS:
            try:
                st = os.statvfs(path)
                key = os.stat(path).st_dev
            except OSError:
                continue
            if key in seen:                  # el/cl on the root fs -> one entry
                continue
            seen.add(key)
            total = st.f_blocks * st.f_frsize
            free = st.f_bavail * st.f_frsize
            used = total - free
            out.append({"path": path, "label": label, "total": total,
                        "used": used, "free": free,
                        "pct": 100.0 * used / total if total else 0.0})
        return out

    def _diskio(self):
        rd = wr = 0
        for line in (read_file("/proc/diskstats", "") or "").splitlines():
            f = line.split()
            if len(f) < 14 or not _WHOLE_DISK.match(f[2]):
                continue
            rd += to_int(f[5]) * 512
            wr += to_int(f[9]) * 512
        t = time.monotonic()
        prev, self._prev_disk = self._prev_disk, (t, rd, wr)
        if not prev or t <= prev[0]:
            return {"read_bps": 0, "write_bps": 0}
        dt = t - prev[0]
        return {"read_bps": max(0, rd - prev[1]) / dt,
                "write_bps": max(0, wr - prev[2]) / dt}

    def _procs(self):
        """RSS + CPU%% for the three node processes, by /proc comm scan."""
        out, seen_pids = [], {}
        for pdir in glob.glob("/proc/[0-9]*"):
            name = _COMM15.get(read_file(pdir + "/comm") or "")
            if name is None:
                continue
            pid = pdir[6:]
            stat = (read_file(pdir + "/stat", "") or "").rsplit(")", 1)
            rss_kb = 0
            for line in (read_file(pdir + "/status", "") or "").splitlines():
                if line.startswith("VmRSS:"):
                    rss_kb = to_int(line.split()[1])
                    break
            cpu = 0.0
            if len(stat) == 2:
                f = stat[1].split()
                jiff = to_int(f[11]) + to_int(f[12])   # utime+stime
                t = time.monotonic()
                prev = self._prev_proc.get(pid)
                seen_pids[pid] = (t, jiff)
                if prev and t > prev[0]:
                    cpu = 100.0 * (jiff - prev[1]) / self._hz / (t - prev[0])
            out.append({"name": name, "pid": pid, "rss": rss_kb * 1024,
                        "cpu": cpu})
        self._prev_proc = seen_pids
        order = {n: i for i, n in enumerate(NODE_PROCS)}
        out.sort(key=lambda p: order.get(p["name"], 9))
        return out

    def _chrony(self):
        out = run_cmd(["chronyc", "-c", "tracking"], timeout=3)
        f = out.strip().split(",") if out else []
        if len(f) < 6:
            return None
        try:
            return {"stratum": to_int(f[2]), "offset": float(f[4]),
                    "synced": to_int(f[2]) > 0}
        except ValueError:
            return None

    def _throttled(self):
        out = run_cmd(["vcgencmd", "get_throttled"], timeout=3)
        m = re.search(r"0x([0-9a-fA-F]+)", out or "")
        if m:
            bits = int(m.group(1), 16)
            return {"undervolt_now": bool(bits & 0x1),
                    "throttled_now": bool(bits & 0x4),
                    "capped_now": bool(bits & 0x2),
                    "undervolt_ever": bool(bits & 0x10000),
                    "throttled_ever": bool(bits & 0x40000)}
        for hw in glob.glob("/sys/class/hwmon/hwmon*"):
            if (read_file(hw + "/name") or "") == "rpi_volt":
                alarm = read_int(hw + "/in0_lcrit_alarm")
                if alarm is not None:
                    return {"undervolt_now": bool(alarm)}
        return None


# --- network -------------------------------------------------------------------

class NetCollector(Collector):
    interval = 1.0

    def __init__(self):
        super().__init__()
        self._prev = {}                 # if -> (t, rx, tx)
        self._hist = {}                 # if -> (rx Series, tx Series)
        self._tick = 0
        self._addrs = {}

    def collect(self):
        ifaces = {}
        self._tick += 1
        if self._tick % 5 == 1:
            self._addrs = self._ip_addrs()
        for path in sorted(glob.glob("/sys/class/net/*")):
            name = os.path.basename(path)
            if name == "lo":
                continue
            role = self._role(path, name)
            rx = read_int(path + "/statistics/rx_bytes", 0)
            tx = read_int(path + "/statistics/tx_bytes", 0)
            t = time.monotonic()
            prev = self._prev.get(name)
            self._prev[name] = (t, rx, tx)
            rx_bps = tx_bps = 0.0
            if prev and t > prev[0]:
                rx_bps = max(0, rx - prev[1]) / (t - prev[0])
                tx_bps = max(0, tx - prev[2]) / (t - prev[0])
            hist = self._hist.setdefault(name, (Series(), Series()))
            hist[0].push(rx_bps)
            hist[1].push(tx_bps)
            ifaces[name] = {
                "role": role,
                "oper": read_file(path + "/operstate", "?"),
                "carrier": read_int(path + "/carrier", 0) == 1,
                "ip": self._addrs.get(name),
                "rx_total": rx, "tx_total": tx,
                "rx_bps": rx_bps, "tx_bps": tx_bps,
                "rx_hist": hist[0], "tx_hist": hist[1],
            }
        # stable ordering: wired, wifi, lte, rest
        prio = {"wired": 0, "wifi": 1, "lte": 2}
        order = sorted(ifaces, key=lambda n: (prio.get(ifaces[n]["role"], 3), n))
        return {"ifaces": ifaces, "order": order}

    @staticmethod
    def _role(path, name):
        """Same classification the failover daemon uses."""
        try:
            drv = os.path.basename(os.readlink(path + "/device/driver"))
        except OSError:
            drv = ""
        if drv in ("cdc_ether", "rndis_host"):
            return "lte"
        if name.startswith("wl"):
            return "wifi"
        if name.startswith("e"):
            return "wired"
        return "other"

    @staticmethod
    def _ip_addrs():
        out = {}
        for entry in run_json(["ip", "-j", "-4", "addr", "show"], timeout=3) or []:
            name = entry.get("ifname")
            for ai in entry.get("addr_info") or []:
                if ai.get("family") == "inet" and name:
                    out[name] = ai.get("local")
                    break
        return out


# --- journal logs + kernel ring buffer -------------------------------------------

# journal units plus "dmesg" — one more log source in the same unit selector
LOG_UNITS = ("geth", "nimbus-beacon-node", "nimbus-validator", "w3p-failover",
             "dmesg")
_LVL_BAD = re.compile(r"\b(ERROR|ERR|CRIT|FATAL|Error|error|panic)\b")
_LVL_WARN = re.compile(r"\b(WARN|WRN|Warn|warn(?:ing)?|NTC)\b")
# kernel messages carry no journal-style level tags — match kernel phrasing
_DMESG_BAD = re.compile(r"(?i)\b(error|fail(?:ed|ure)?|oops|panic|segfault|"
                        r"under-?voltage|corrupt(?:ed|ion)?|call trace)\b")
DMESG_KEEP = 400


def _level(raw, bad_re):
    if bad_re.search(raw):
        return "bad"
    if _LVL_WARN.search(raw):
        return "warn"
    return "info"


class LogsCollector(Collector):
    interval = 3.0

    def __init__(self):
        super().__init__()
        self.unit = LOG_UNITS[0]        # UI switches this
        self.data = {"unit": self.unit, "lines": [], "available": True}

    def collect(self):
        unit = self.unit
        if unit == "dmesg":
            out = run_cmd(["dmesg", "-T", "--color=never"], timeout=5)
            lines = [(_level(raw, _DMESG_BAD), raw)
                     for raw in (out or "").splitlines()[-DMESG_KEEP:]]
        else:
            out = run_cmd(["journalctl", "-u", unit, "-n", "200", "--no-pager",
                           "-o", "short-iso", "--no-hostname"], timeout=4)
            lines = [(_level(raw, _LVL_BAD), raw)
                     for raw in (out or "").splitlines()
                     if not raw.startswith("--")]   # "-- No entries --"
        return {"unit": unit, "lines": lines,
                "available": bool(out.strip()) if out else False}
