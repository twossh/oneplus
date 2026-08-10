#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import os
import socket
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ROOT = Path(__file__).resolve().parents[1]
PROXY = ROOT / "libexec" / "websocket_proxy.py"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def echo_server(port: int, ready: threading.Event, stop: threading.Event) -> None:
    with socket.socket() as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", port))
        server.listen(5)
        server.settimeout(0.2)
        ready.set()
        while not stop.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            threading.Thread(target=echo_conn, args=(conn,), daemon=True).start()


def echo_conn(conn: socket.socket) -> None:
    with conn:
        while True:
            data = conn.recv(65536)
            if not data:
                return
            conn.sendall(data)


def recv_headers(sock: socket.socket) -> bytes:
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            raise AssertionError("socket closed during headers")
        data.extend(chunk)
    return bytes(data)


def masked_frame(payload: bytes, opcode: int = 2) -> bytes:
    mask = os.urandom(4)
    size = len(payload)
    if size < 126:
        header = bytes((0x80 | opcode, 0x80 | size))
    elif size <= 65535:
        header = bytes((0x80 | opcode, 0x80 | 126)) + struct.pack("!H", size)
    else:
        header = bytes((0x80 | opcode, 0x80 | 127)) + struct.pack("!Q", size)
    body = bytes(value ^ mask[i & 3] for i, value in enumerate(payload))
    return header + mask + body


def recv_exact(sock: socket.socket, n: int) -> bytes:
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise AssertionError("short frame")
        out.extend(chunk)
    return bytes(out)


def recv_server_frame(sock: socket.socket) -> tuple[int, bytes]:
    first, second = recv_exact(sock, 2)
    assert first & 0x80
    assert not (second & 0x80), "server frame must not be masked"
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    return first & 0x0F, recv_exact(sock, length)


def test_legacy(port: int) -> None:
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.sendall(
            b"GET /ssh HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        )
        head = recv_headers(sock)
        assert b"101 Switching Protocols" in head
        sock.sendall(b"legacy-echo")
        assert recv_exact(sock, 11) == b"legacy-echo"


def test_rfc(port: int) -> None:
    key = base64.b64encode(os.urandom(16)).decode("ascii")
    expected = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest())
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        request = (
            "GET /ssh HTTP/1.1\r\n"
            "Host: localhost\r\n"
            "Upgrade: websocket\r\n"
            "Connection: keep-alive, Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        ).encode("ascii")
        sock.sendall(request)
        head = recv_headers(sock)
        assert b"101 Switching Protocols" in head
        assert b"Sec-WebSocket-Accept: " + expected in head
        sock.sendall(masked_frame(b"rfc-echo"))
        opcode, payload = recv_server_frame(sock)
        assert opcode == 2
        assert payload == b"rfc-echo"


def test_reject_dynamic_destination(port: int) -> None:
    # X-Real-Host is intentionally ignored. The fixed echo upstream must still answer.
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.sendall(
            b"GET /ssh HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            b"X-Real-Host: 203.0.113.1:1\r\n\r\n"
        )
        head = recv_headers(sock)
        assert b"101 Switching Protocols" in head
        sock.sendall(b"fixed")
        assert recv_exact(sock, 5) == b"fixed"



def test_reject_invalid_rfc(port: int) -> None:
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.sendall(
            b"GET /ssh HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Key: not-base64!\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        head = recv_headers(sock)
        assert b"400 Invalid WebSocket Key" in head

    key = base64.b64encode(os.urandom(16))
    with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
        sock.sendall(
            b"GET /ssh HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + b"Sec-WebSocket-Key: " + key + b"\r\nSec-WebSocket-Version: 12\r\n\r\n"
        )
        head = recv_headers(sock)
        assert b"400 Unsupported WebSocket Version" in head

def main() -> int:
    upstream = free_port()
    proxy_port = free_port()
    ready = threading.Event()
    stop = threading.Event()
    thread = threading.Thread(target=echo_server, args=(upstream, ready, stop), daemon=True)
    thread.start()
    assert ready.wait(2)

    proc = subprocess.Popen(
        [
            sys.executable,
            str(PROXY),
            "--bind", "127.0.0.1",
            "--port", str(proxy_port),
            "--upstream", f"127.0.0.1:{upstream}",
            "--path", "/ssh",
            "--mode", "auto",
            "--max-clients", "8",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + 3
        while time.time() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", proxy_port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            output = proc.stdout.read() if proc.stdout else ""
            raise AssertionError(f"proxy did not start: {output}")
        test_legacy(proxy_port)
        test_rfc(proxy_port)
        test_reject_dynamic_destination(proxy_port)
        test_reject_invalid_rfc(proxy_port)
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
        stop.set()
        thread.join(timeout=1)
    print("WEBSOCKET TESTS: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
