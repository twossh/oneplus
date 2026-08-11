#!/usr/bin/env python3
"""Write privacy-minimal OnePlus host snapshots as NDJSON.

The snapshot intentionally stores counters and totals only. It does not persist
usernames, remote IP addresses, commands, passwords, or packet payloads.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import socket
import stat
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:-\d+)?\.ndjson$")
MAX_LINE_BYTES = 256 * 1024
OPENVPN_SOCKET = Path("/run/oneplus-openvpn/management.sock")
SERVICES = (
    "ssh.service",
    "oneplus-dropbear.service",
    "oneplus-websocket.service",
    "oneplus-tls.service",
    "oneplus-openvpn.service",
    "oneplus-mux.service",
    "oneplus-badvpn.service",
    "oneplus-slowdns.service",
    "oneplus-firewall.service",
)


def run_text(argv: list[str], timeout: float = 2.0) -> str:
    try:
        cp = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
        return cp.stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def memory_info() -> tuple[int, int]:
    total = available = 0
    try:
        with open("/proc/meminfo", "r", encoding="ascii", errors="replace") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    total = int(line.split()[1]) * 1024
                elif line.startswith("MemAvailable:"):
                    available = int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return total, available


def uptime_seconds() -> float:
    try:
        with open("/proc/uptime", "r", encoding="ascii") as fh:
            return float(fh.read().split()[0])
    except (OSError, ValueError, IndexError):
        return 0.0


def network_counters() -> dict[str, dict[str, int]]:
    result: dict[str, dict[str, int]] = {}
    try:
        with open("/proc/net/dev", "r", encoding="ascii", errors="replace") as fh:
            for line in fh.readlines()[2:]:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                iface = name.strip()
                if not iface or iface == "lo" or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,32}", iface):
                    continue
                fields = rest.split()
                if len(fields) < 16:
                    continue
                try:
                    result[iface] = {"rx_bytes": int(fields[0]), "tx_bytes": int(fields[8])}
                except ValueError:
                    continue
    except OSError:
        pass
    return result


def managed_user_count() -> int:
    base = Path("/var/lib/oneplus/users")
    try:
        count = 0
        for p in base.iterdir():
            try:
                st = p.lstat()
            except OSError:
                continue
            if p.name.endswith(".conf") and stat.S_ISREG(st.st_mode):
                count += 1
        return count
    except OSError:
        return 0


def login_session_count() -> int:
    return sum(1 for line in run_text(["who"]).splitlines() if line.strip())


def openvpn_client_count() -> int:
    try:
        st = OPENVPN_SOCKET.lstat()
        if not stat.S_ISSOCK(st.st_mode):
            return 0
    except OSError:
        return 0
    data = bytearray()
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(1.5)
            sock.connect(str(OPENVPN_SOCKET))
            try:
                data.extend(sock.recv(8192))
            except socket.timeout:
                pass
            sock.sendall(b"status 2\nquit\n")
            while len(data) < 1024 * 1024:
                try:
                    chunk = sock.recv(8192)
                except socket.timeout:
                    break
                if not chunk:
                    break
                data.extend(chunk)
    except OSError:
        return 0
    text = data.decode("utf-8", "replace")
    return sum(1 for line in text.splitlines() if line.startswith("CLIENT_LIST,"))


def service_states() -> dict[str, str]:
    states: dict[str, str] = {}
    for unit in SERVICES:
        value = run_text(["systemctl", "is-active", unit], timeout=1.0).strip()
        states[unit] = value if value in {"active", "inactive", "failed", "activating", "deactivating"} else "unknown"
    return states


def snapshot() -> dict[str, Any]:
    now = datetime.now(timezone.utc)
    mem_total, mem_available = memory_info()
    try:
        load1, load5, load15 = os.getloadavg()
    except OSError:
        load1 = load5 = load15 = 0.0
    try:
        vfs = os.statvfs("/")
        fs_total = vfs.f_frsize * vfs.f_blocks
        fs_available = vfs.f_frsize * vfs.f_bavail
        fs_used = max(0, fs_total - fs_available)
    except OSError:
        fs_total = fs_used = 0
    return {
        "schema": 1,
        "timestamp": now.replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "epoch": int(now.timestamp()),
        "uptime_seconds": round(uptime_seconds(), 3),
        "load": {"1m": round(load1, 4), "5m": round(load5, 4), "15m": round(load15, 4)},
        "memory": {"total_bytes": mem_total, "available_bytes": mem_available},
        "root_fs": {"total_bytes": fs_total, "used_bytes": fs_used},
        "network": network_counters(),
        "managed_users": managed_user_count(),
        "login_sessions": login_session_count(),
        "openvpn_clients": openvpn_client_count(),
        "services": service_states(),
    }


def ensure_safe_dir(path: Path) -> None:
    if not path.is_absolute():
        raise SystemExit("output-dir deve ser absoluto")
    if path.exists() and path.is_symlink():
        raise SystemExit("output-dir não pode ser link simbólico")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    st = path.lstat()
    if not stat.S_ISDIR(st.st_mode):
        raise SystemExit("output-dir não é diretório")
    try:
        os.chmod(path, 0o700)
    except PermissionError:
        pass


def safe_regular(path: Path) -> bool:
    try:
        st = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(st.st_mode) and st.st_nlink == 1


def prune(path: Path, retention_days: int, now: float | None = None) -> int:
    now = time.time() if now is None else now
    cutoff = now - retention_days * 86400
    removed = 0
    try:
        entries = list(path.iterdir())
    except OSError:
        return 0
    for item in entries:
        if not DAY_RE.fullmatch(item.name):
            continue
        try:
            st = item.lstat()
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            continue
        if st.st_mtime < cutoff:
            try:
                item.unlink()
                removed += 1
            except OSError:
                pass
    return removed


def append_snapshot(path: Path, data: dict[str, Any]) -> Path:
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    target = path / f"{day}.ndjson"
    if target.exists() and not safe_regular(target):
        raise SystemExit("arquivo diário de histórico não é regular ou possui hardlink")
    line = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii") + b"\n"
    if len(line) > MAX_LINE_BYTES:
        raise SystemExit("snapshot excede limite interno")
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(target, flags, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise SystemExit("destino de histórico inseguro")
        os.fchmod(fd, 0o600)
        os.write(fd, line)
        os.fsync(fd)
    finally:
        os.close(fd)
    return target


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--retention-days", required=True, type=int)
    parser.add_argument("--prune-only", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.retention_days <= 90:
        raise SystemExit("retention-days deve estar entre 1 e 90")
    out = Path(args.output_dir)
    ensure_safe_dir(out)
    prune(out, args.retention_days)
    if args.prune_only:
        return
    append_snapshot(out, snapshot())


if __name__ == "__main__":
    main()
