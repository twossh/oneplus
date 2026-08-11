#!/usr/bin/env python3
"""Summarize OnePlus NDJSON history without a database."""
from __future__ import annotations

import argparse
import json
import math
import os
import re
import stat
import time
from pathlib import Path
from typing import Any

DAY_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(?:-\d+)?\.ndjson$")
MAX_LINE = 256 * 1024
MAX_RECORDS = 100_000


def human_bytes(value: int | float) -> str:
    n = float(max(0, value))
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return f"{n:.2f} {unit}"
        n /= 1024
    return f"{n:.2f} TiB"


def iter_records(base: Path, since: int):
    count = 0
    if not base.is_absolute() or base.is_symlink():
        return
    try:
        files = sorted(base.iterdir())
    except OSError:
        return
    for path in files:
        if not DAY_RE.fullmatch(path.name):
            continue
        try:
            st = path.lstat()
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            continue
        try:
            with path.open("rb") as fh:
                for raw in fh:
                    if len(raw) > MAX_LINE:
                        continue
                    try:
                        rec = json.loads(raw)
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        continue
                    if not isinstance(rec, dict) or rec.get("schema") != 1:
                        continue
                    epoch = rec.get("epoch")
                    if not isinstance(epoch, int) or epoch < since:
                        continue
                    yield rec
                    count += 1
                    if count >= MAX_RECORDS:
                        return
        except OSError:
            continue


def number(value: Any) -> float | None:
    if isinstance(value, (int, float)) and math.isfinite(float(value)):
        return float(value)
    return None


def summarize(records: list[dict[str, Any]]) -> str:
    if not records:
        return "Nenhum snapshot no período selecionado.\n"
    records.sort(key=lambda r: r.get("epoch", 0))
    load_values: list[float] = []
    mem_avail: list[float] = []
    disk_pct: list[float] = []
    login_max = 0
    vpn_max = 0
    users_max = 0
    traffic: dict[str, dict[str, int]] = {}
    previous: dict[str, tuple[int, int]] = {}
    service_active: dict[str, int] = {}
    service_seen: dict[str, int] = {}

    for rec in records:
        load = rec.get("load") if isinstance(rec.get("load"), dict) else {}
        v = number(load.get("1m"))
        if v is not None:
            load_values.append(v)
        mem = rec.get("memory") if isinstance(rec.get("memory"), dict) else {}
        v = number(mem.get("available_bytes"))
        if v is not None:
            mem_avail.append(v)
        fs = rec.get("root_fs") if isinstance(rec.get("root_fs"), dict) else {}
        total = number(fs.get("total_bytes"))
        used = number(fs.get("used_bytes"))
        if total and used is not None and total > 0:
            disk_pct.append(used * 100.0 / total)
        for field, target in (("login_sessions", "login"), ("openvpn_clients", "vpn"), ("managed_users", "users")):
            val = rec.get(field)
            if isinstance(val, int) and val >= 0:
                if target == "login": login_max = max(login_max, val)
                elif target == "vpn": vpn_max = max(vpn_max, val)
                else: users_max = max(users_max, val)
        net = rec.get("network") if isinstance(rec.get("network"), dict) else {}
        for iface, values in net.items():
            if not isinstance(iface, str) or not isinstance(values, dict):
                continue
            rx = values.get("rx_bytes")
            tx = values.get("tx_bytes")
            if not isinstance(rx, int) or not isinstance(tx, int) or rx < 0 or tx < 0:
                continue
            traffic.setdefault(iface, {"rx": 0, "tx": 0})
            if iface in previous:
                prx, ptx = previous[iface]
                if rx >= prx: traffic[iface]["rx"] += rx - prx
                if tx >= ptx: traffic[iface]["tx"] += tx - ptx
            previous[iface] = (rx, tx)
        states = rec.get("services") if isinstance(rec.get("services"), dict) else {}
        for unit, state in states.items():
            if not isinstance(unit, str) or not isinstance(state, str):
                continue
            service_seen[unit] = service_seen.get(unit, 0) + 1
            if state == "active":
                service_active[unit] = service_active.get(unit, 0) + 1

    start = records[0].get("timestamp", "N/D")
    end = records[-1].get("timestamp", "N/D")
    lines = [
        "ONEPLUS HISTORY SUMMARY",
        f"Snapshots: {len(records)}",
        f"Período: {start} -> {end}",
    ]
    if load_values:
        lines.append(f"Carga 1m: média {sum(load_values)/len(load_values):.2f} | máxima {max(load_values):.2f}")
    if mem_avail:
        lines.append(f"Memória disponível mínima: {human_bytes(min(mem_avail))}")
    if disk_pct:
        lines.append(f"Uso máximo da raiz: {max(disk_pct):.1f}%")
    lines.extend([
        f"Sessões login simultâneas (máx): {login_max}",
        f"Clientes OpenVPN simultâneos (máx): {vpn_max}",
        f"Usuários OnePlus registrados (máx): {users_max}",
        "",
        "Tráfego acumulado entre snapshots:",
    ])
    if traffic:
        for iface in sorted(traffic):
            lines.append(f"  {iface}: RX {human_bytes(traffic[iface]['rx'])} | TX {human_bytes(traffic[iface]['tx'])}")
    else:
        lines.append("  sem dados")
    if service_seen:
        lines.append("")
        lines.append("Disponibilidade observada dos serviços:")
        for unit in sorted(service_seen):
            pct = service_active.get(unit, 0) * 100.0 / service_seen[unit]
            lines.append(f"  {unit}: {pct:.1f}% ativo nos snapshots")
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--history-dir", required=True)
    parser.add_argument("--hours", required=True, type=int)
    args = parser.parse_args()
    if not 1 <= args.hours <= 24 * 90:
        raise SystemExit("hours deve estar entre 1 e 2160")
    base = Path(args.history_dir)
    since = int(time.time()) - args.hours * 3600
    print(summarize(list(iter_records(base, since))), end="")


if __name__ == "__main__":
    main()
