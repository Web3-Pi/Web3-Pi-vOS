"""Node-specific collectors: Ethereum clients (geth / nimbus), the w3p-failover
watchdog status file, the ZTE LTE modem JSON API and vnstat data counters.

Endpoints and parsing mirror the existing shell tooling (control-panel
modules + w3p-failover.sh) so both always tell the same story."""

import glob
import json
import os
import re
import time

from .util import (http_json, read_file, rpc_call, run_cmd, run_json, to_int,
                   hex_int)
from .collectors import Collector
from .widgets import Series

GETH_RPC = "http://127.0.0.1:8545"
BEACON_REST = "http://127.0.0.1:5052"
FAILOVER_STATUS = "/run/w3p-failover/status.json"
W3P_CONFIG = "/opt/web3pi/config"
SECONDS_PER_SLOT = 12
SERVICES = ("geth", "nimbus-beacon-node", "nimbus-validator", "w3p-failover")

_BACKFILL_RE = re.compile(r"backfill: ([^)]*%\))")


def lte_device():
    """USB LTE modem interface (cdc_ether/rndis) — same rule as the daemon."""
    dev = ""
    for path in glob.glob("/sys/class/net/*"):
        try:
            drv = os.path.basename(os.readlink(path + "/device/driver"))
        except OSError:
            continue
        if drv in ("cdc_ether", "rndis_host"):
            dev = os.path.basename(path)
    return dev


class EthCollector(Collector):
    interval = 2.0

    def __init__(self):
        super().__init__()
        self._tick = 0
        self.el_peers_hist = Series()
        self.cl_peers_hist = Series()
        self.gap_hist = Series()
        self.dist_hist = Series()
        self.age_hist = Series()
        self.data = {"network": self._network(), "el": {}, "cl": {},
                     "services": {}, "el_version": None, "cl_version": None,
                     "backfill": None}

    @staticmethod
    def _network():
        # Config keys carry the W3P_ prefix since 2026-07; accept the legacy
        # unprefixed key too so the dashboard still works on a not-yet-migrated
        # device. Prefixed key wins regardless of file order.
        legacy = None
        for line in (read_file(W3P_CONFIG, "") or "").splitlines():
            if line.startswith("W3P_NETWORK="):
                return line.split("=", 1)[1].strip() or "?"
            if line.startswith("NETWORK="):
                legacy = line.split("=", 1)[1].strip()
        return legacy or "?"

    def collect(self):
        d = {"services": self._services()}
        d["el"] = self._geth(d["services"].get("geth") == "active")
        d["cl"] = self._nimbus(d["services"].get("nimbus-beacon-node") == "active")
        self.el_peers_hist.push(d["el"].get("peers"))
        self.cl_peers_hist.push(d["cl"].get("peers"))
        self.gap_hist.push(d["el"].get("gap"))
        self.dist_hist.push(d["cl"].get("sync_dist"))
        self.age_hist.push(d["el"].get("head_age"))
        self._tick += 1
        if self._tick % 150 == 1:              # every ~5 min
            d["network"] = self._network()
            d["el_version"] = rpc_call(GETH_RPC, "web3_clientVersion")
            v = http_json(BEACON_REST + "/eth/v1/node/version")
            d["cl_version"] = (v or {}).get("data", {}).get("version")
        if self._tick % 15 == 1:               # every ~30 s
            d["backfill"] = self._backfill()
        return d

    @staticmethod
    def _services():
        out = run_cmd(["systemctl", "is-active"] + list(SERVICES), timeout=3)
        states = (out or "").split()
        res = {}
        for i, svc in enumerate(SERVICES):
            res[svc] = states[i] if i < len(states) else "unknown"
        return res

    @staticmethod
    def _geth(service_active):
        el = {"service": service_active, "api": False, "syncing": None,
              "block": None, "current": None, "highest": None, "gap": None,
              "gap_est": False, "head_age": None, "peers": None}
        syncing = rpc_call(GETH_RPC, "eth_syncing")
        if syncing is None:
            return el
        el["api"] = True
        peers = rpc_call(GETH_RPC, "net_peerCount")
        el["peers"] = hex_int(peers) if peers is not None else None
        head = rpc_call(GETH_RPC, "eth_getBlockByNumber", ["latest", False])
        if isinstance(head, dict):
            el["block"] = hex_int(head.get("number"))
            el["head_age"] = max(0, int(time.time()) - hex_int(head.get("timestamp")))
        if isinstance(syncing, dict):
            el["syncing"] = True
            el["current"] = hex_int(syncing.get("currentBlock"))
            el["highest"] = hex_int(syncing.get("highestBlock"))
            el["gap"] = max(0, el["highest"] - el["current"])
        else:
            el["syncing"] = False
            # geth says "synced" even when it simply has nothing newer (e.g.
            # WAN outage). Head age is the honest signal: estimate the gap
            # from how stale the head block is. Head unreadable -> unknown,
            # never a reassuring green zero.
            if el["head_age"] is None:
                el["gap"] = None
            elif el["head_age"] > 90:
                el["gap"] = el["head_age"] // SECONDS_PER_SLOT
                el["gap_est"] = True
            else:
                el["gap"] = 0
        return el

    @staticmethod
    def _nimbus(service_active):
        cl = {"service": service_active, "api": False, "head_slot": None,
              "sync_dist": None, "is_syncing": None, "optimistic": None,
              "el_offline": None, "peers": None}
        resp = http_json(BEACON_REST + "/eth/v1/node/syncing")
        data = (resp or {}).get("data")
        if not isinstance(data, dict):
            return cl
        cl["api"] = True
        cl["head_slot"] = to_int(data.get("head_slot"))
        cl["sync_dist"] = to_int(data.get("sync_distance"))
        cl["is_syncing"] = bool(data.get("is_syncing"))
        cl["optimistic"] = bool(data.get("is_optimistic"))
        cl["el_offline"] = data.get("el_offline")
        pc = http_json(BEACON_REST + "/eth/v1/node/peer_count")
        pdata = (pc or {}).get("data") or {}
        cl["peers"] = to_int(pdata.get("connected"), None)
        return cl

    @staticmethod
    def _backfill():
        out = run_cmd(["journalctl", "-u", "nimbus-beacon-node", "-n", "20",
                       "--no-pager"], timeout=4)
        hits = _BACKFILL_RE.findall(out or "")
        return hits[-1] if hits else None


class FailoverCollector(Collector):
    interval = 2.0

    def collect(self):
        d = {"status": None, "age": None, "routes": []}
        try:
            with open(FAILOVER_STATUS) as f:
                d["status"] = json.load(f)
            d["age"] = max(0, time.time() - os.path.getmtime(FAILOVER_STATUS))
        except (OSError, ValueError):
            pass
        st = d["status"]
        if st:
            remain = st.get("latched_until", 0) - time.time()
            d["latch_remain"] = max(0, int(remain)) if st.get("latched") else 0
        for r in run_json(["ip", "-j", "route", "show", "default"], timeout=3) or []:
            d["routes"].append({"dev": r.get("dev"), "gw": r.get("gateway"),
                                "metric": r.get("metric", 0)})
        d["routes"].sort(key=lambda r: r["metric"])
        return d


class ModemCollector(Collector):
    """ZTE goform JSON API via the modem's gateway IP; read commands work
    without login on stock MF79U firmware. Polled slowly — it's a modem."""
    interval = 30.0
    CMDS = ("signalbar,network_type,network_provider,ppp_status,pin_status,"
            "lte_rsrp,lte_snr,monthly_rx_bytes,monthly_tx_bytes")

    def collect(self):
        dev = lte_device()
        if not dev:
            return {"present": False, "dev": None, "info": None}
        gw = None
        for r in run_json(["ip", "-j", "route", "show", "dev", dev],
                          timeout=3) or []:
            if r.get("dst") == "default" and r.get("gateway"):
                gw = r["gateway"]
                break
        if not gw:
            return {"present": True, "dev": dev, "gw": None, "info": None}
        url = ("http://%s/goform/goform_get_cmd_process?isTest=false"
               "&multi_data=1&cmd=%s" % (gw, self.CMDS))
        info = http_json(url, headers={"Referer": "http://%s/index.html" % gw},
                         timeout=5)
        return {"present": True, "dev": dev, "gw": gw,
                "info": info if isinstance(info, dict) else None}


class VnstatCollector(Collector):
    """Daily/monthly counters for the LTE interface (metered link budget)."""
    interval = 60.0

    def collect(self):
        dev = lte_device()
        if not dev:
            return {"dev": None, "usage": None}
        line = run_cmd(["vnstat", "--oneline", "-i", dev], timeout=5)
        f = (line or "").strip().split(";")
        if len(f) < 11:
            return {"dev": dev, "usage": None}
        # field map matches control-panel failover_data_usage (awk 1-based)
        return {"dev": dev, "usage": {
            "today_date": f[2], "today_rx": f[3], "today_tx": f[4],
            "today_total": f[5], "month": f[7], "month_rx": f[8],
            "month_tx": f[9], "month_total": f[10]}}
