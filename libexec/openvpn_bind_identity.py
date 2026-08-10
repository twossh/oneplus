#!/usr/bin/env python3
"""Bind OpenVPN username/password authentication to the presented mTLS certificate.

The PAM plugin still validates the password. This helper is an additional
fail-closed auth-user-pass-verify hook used only in hybrid mode. It reads only
the username from OpenVPN's via-file credential file and matches the peer
certificate serial against a root-maintained, non-secret authorization map.
"""
from __future__ import annotations

import os
import re
import stat
import sys
from pathlib import Path

DEFAULT_AUTHZ_DIR = Path("/var/lib/oneplus/openvpn-authz")
USER_RE = re.compile(r"^[a-z][a-z0-9_-]{0,31}$")
SERIAL_RE = re.compile(r"^[A-F0-9]{1,64}$")


def authz_dir() -> Path:
    # Test override is intentionally honored only as root. The production
    # OpenVPN hook runs after privilege drop and therefore always uses the
    # fixed root-controlled path above.
    if os.geteuid() == 0:
        override = os.environ.get("ONEPLUS_TEST_AUTHZ_DIR", "")
        if override.startswith("/"):
            return Path(override)
    return DEFAULT_AUTHZ_DIR


def normalize_serial(value: str) -> str:
    serial = value.replace(":", "").strip().upper()
    return serial if SERIAL_RE.fullmatch(serial) else ""


def read_username(credentials: Path) -> str:
    try:
        # Read only the first line. The PAM plugin is solely responsible for
        # validating the password on line 2; this helper never needs it.
        with credentials.open("r", encoding="utf-8", errors="strict") as fh:
            username = fh.readline(128).rstrip("\r\n")
    except (OSError, UnicodeError):
        return ""
    return username if USER_RE.fullmatch(username) else ""


def main(argv: list[str]) -> int:
    if len(argv) != 2 or os.environ.get("script_type") not in {None, "auth-user-pass-verify"}:
        return 1
    credentials = Path(argv[1])
    if not credentials.is_absolute():
        return 1
    username = read_username(credentials)
    serial = normalize_serial(os.environ.get("tls_serial_hex_0", ""))
    if not username or not serial:
        return 1

    mapping = authz_dir() / f"{serial}.user"
    try:
        st = mapping.lstat()
        # Authorization entries are regular, root-owned files in production;
        # symlinks and group/other-writable entries are rejected.
        if not stat.S_ISREG(st.st_mode) or st.st_uid != 0 or st.st_mode & 0o022:
            return 1
        expected = mapping.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError):
        return 1
    return 0 if expected == username else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
