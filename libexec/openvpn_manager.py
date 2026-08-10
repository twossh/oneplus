#!/usr/bin/env python3
"""Small root-only client for the local OpenVPN management UNIX socket."""
from __future__ import annotations

import os
import socket
import sys

SOCKET_PATH = "/run/oneplus-openvpn/management.sock"
MAX_REPLY = 1024 * 1024


def fail(message: str, code: int = 1) -> "None":
    print(message, file=sys.stderr)
    raise SystemExit(code)


def valid_username(value: str) -> bool:
    if not (1 <= len(value) <= 32):
        return False
    if not value[0].islower() or not value[0].isascii():
        return False
    return all((c.islower() and c.isascii()) or (c.isdigit() and c.isascii()) or c in "_-" for c in value)


def transact(command: str) -> str:
    if os.geteuid() != 0:
        fail("Este utilitário deve ser executado como root.")
    if not os.path.exists(SOCKET_PATH):
        fail("Socket de gerenciamento OpenVPN ausente.", 3)

    data = bytearray()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(3.0)
        sock.connect(SOCKET_PATH)
        # Read greeting when present; do not wait indefinitely for it.
        try:
            greeting = sock.recv(8192)
            data.extend(greeting)
        except socket.timeout:
            pass
        sock.sendall((command + "\nquit\n").encode("utf-8", "strict"))
        while len(data) < MAX_REPLY:
            try:
                chunk = sock.recv(8192)
            except socket.timeout:
                break
            if not chunk:
                break
            data.extend(chunk)
    return data.decode("utf-8", "replace")


def main() -> None:
    if len(sys.argv) < 2:
        fail("Uso: openvpn_manager.py {status|kill-user USUARIO}", 2)
    action = sys.argv[1]
    if action == "status" and len(sys.argv) == 2:
        print(transact("status 2"), end="")
        return
    if action == "kill-user" and len(sys.argv) == 3:
        user = sys.argv[2]
        if not valid_username(user):
            fail("Usuário inválido.", 2)
        reply = transact(f"kill {user}")
        print(reply, end="")
        return
    fail("Uso: openvpn_manager.py {status|kill-user USUARIO}", 2)


if __name__ == "__main__":
    main()
