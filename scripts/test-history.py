#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SNAP = ROOT / "libexec/history_snapshot.py"
SUMMARY = ROOT / "libexec/history_summary.py"


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="oneplus-history-test.") as td:
        base = Path(td) / "history"
        cp = run("python3", str(SNAP), "--output-dir", str(base), "--retention-days", "2")
        assert cp.returncode == 0, cp.stderr
        files = list(base.glob("*.ndjson"))
        assert len(files) == 1
        mode = stat.S_IMODE(files[0].stat().st_mode)
        assert mode == 0o600, oct(mode)
        record = json.loads(files[0].read_text().splitlines()[-1])
        assert record["schema"] == 1
        assert isinstance(record["network"], dict)
        assert "timestamp" in record and "services" in record
        forbidden = {"username", "remote_ip", "password", "command", "payload"}
        assert not (forbidden & set(record))

        old = base / "2000-01-01.ndjson"
        old.write_text('{"schema":1,"epoch":1}\n')
        os.chmod(old, 0o600)
        old_time = time.time() - 10 * 86400
        os.utime(old, (old_time, old_time))

        outside = Path(td) / "outside"
        outside.write_text("KEEP")
        link = base / "1999-01-01.ndjson"
        link.symlink_to(outside)
        cp = run("python3", str(SNAP), "--output-dir", str(base), "--retention-days", "2", "--prune-only")
        assert cp.returncode == 0, cp.stderr
        assert not old.exists()
        assert link.is_symlink()
        assert outside.read_text() == "KEEP"

        cp = run("python3", str(SUMMARY), "--history-dir", str(base), "--hours", "24")
        assert cp.returncode == 0, cp.stderr
        assert "ONEPLUS HISTORY SUMMARY" in cp.stdout
        assert "Snapshots:" in cp.stdout

        bad = Path(td) / "badlink"
        bad.symlink_to(base)
        cp = run("python3", str(SNAP), "--output-dir", str(bad), "--retention-days", "2")
        assert cp.returncode != 0

    print("HISTORY TESTS: OK")


if __name__ == "__main__":
    main()
