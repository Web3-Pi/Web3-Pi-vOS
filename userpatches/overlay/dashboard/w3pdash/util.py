"""Shared helpers: formatting, file/command/HTTP access. Everything best-effort:
on this box a dead data source is a state to display, never a crash."""

import json
import subprocess
import time
import urllib.request


def read_file(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def read_int(path, default=None):
    v = read_file(path)
    if v is None:
        return default
    try:
        return int(v)
    except ValueError:
        return default


def run_cmd(cmd, timeout=5):
    """Run a command, return stdout ('' on any failure). cmd is a list."""
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def run_json(cmd, timeout=5):
    out = run_cmd(cmd, timeout)
    if not out:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def http_json(url, payload=None, headers=None, timeout=3):
    """GET (or POST if payload) a JSON endpoint. Returns dict/list or None."""
    try:
        data = None
        req_headers = {"Content-Type": "application/json"}
        if headers:
            req_headers.update(headers)
        if payload is not None:
            data = json.dumps(payload).encode()
        req = urllib.request.Request(url, data=data, headers=req_headers)
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


def rpc_call(url, method, params=None, timeout=3):
    """Ethereum JSON-RPC call; returns .result or None."""
    resp = http_json(url, {"jsonrpc": "2.0", "method": method,
                           "params": params or [], "id": 1}, timeout=timeout)
    if isinstance(resp, dict):
        return resp.get("result")
    return None


def hex_int(v, default=0):
    """Parse '0x1a2b' (or int) into int."""
    if isinstance(v, int):
        return v
    try:
        return int(v, 16)
    except (TypeError, ValueError):
        return default


def to_int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def fmt_bytes(n, digits=1):
    """1234567 -> '1.2 MB' (binary steps, short units)."""
    if n is None:
        return "-"
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB", "PB"):
        if abs(n) < 1024 or unit == "PB":
            if unit == "B":
                return "%d %s" % (n, unit)
            return "%.*f %s" % (digits, n, unit)
        n /= 1024
    return "-"


def fmt_rate(bps):
    """Bytes/s -> '1.2 MB/s'."""
    if bps is None:
        return "-"
    return fmt_bytes(bps) + "/s"


def fmt_num(n):
    """1234567 -> '1,234,567'."""
    if n is None:
        return "-"
    return "{:,}".format(n)


def fmt_dur(seconds, parts=2):
    """3672 -> '1h 1m'. Days included when relevant."""
    if seconds is None:
        return "-"
    seconds = int(seconds)
    if seconds < 0:
        seconds = 0
    out = []
    for name, size in (("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
        if seconds >= size or (name == "s" and not out):
            out.append("%d%s" % (seconds // size, name))
            seconds %= size
        if len(out) >= parts:
            break
    return " ".join(out)


def fmt_age(seconds):
    """Short single-unit age: 8s / 3m / 2h / 5d."""
    if seconds is None:
        return "-"
    seconds = int(seconds)
    for name, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size:
            return "%d%s" % (seconds // size, name)
    return "%ds" % seconds


def now():
    return time.monotonic()
