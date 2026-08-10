#!/usr/bin/env python3
"""OnePlus fixed-upstream WebSocket/HTTP Upgrade TCP proxy.

Supports RFC 6455 WebSocket framing and a compatibility mode for legacy
HTTP Upgrade clients that switch to raw TCP after the 101 response.
The upstream is fixed by the administrator; client-supplied destination
headers are intentionally ignored.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import logging
import select
import signal
import socket
import struct
import threading
from dataclasses import dataclass
from typing import Dict, Optional, Tuple

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
LOG = logging.getLogger("oneplus-websocket")


@dataclass(frozen=True)
class Config:
    bind: str
    port: int
    upstream_host: str
    upstream_port: int
    path: str
    mode: str
    max_clients: int
    header_limit: int
    max_frame: int


def parse_host_port(value: str) -> Tuple[str, int]:
    host, sep, port_text = value.rpartition(":")
    if not sep or not host:
        raise ValueError("upstream deve usar host:porta")
    port = int(port_text)
    if not (1 <= port <= 65535):
        raise ValueError("porta upstream inválida")
    return host, port


def recv_until(sock: socket.socket, marker: bytes, limit: int) -> Tuple[bytes, bytes]:
    data = bytearray()
    while marker not in data:
        chunk = sock.recv(min(4096, limit - len(data) + 1))
        if not chunk:
            raise ConnectionError("cliente fechou antes do cabeçalho")
        data.extend(chunk)
        if len(data) > limit:
            raise ValueError("cabeçalho HTTP excede o limite")
    head, rest = bytes(data).split(marker, 1)
    return head + marker, rest


def parse_request(head: bytes) -> Tuple[str, str, Dict[str, str]]:
    try:
        text = head.decode("iso-8859-1")
    except UnicodeDecodeError as exc:
        raise ValueError("cabeçalho HTTP inválido") from exc
    lines = text.split("\r\n")
    parts = lines[0].split()
    if len(parts) != 3 or not parts[2].startswith("HTTP/1."):
        raise ValueError("linha HTTP inválida")
    method, path, _version = parts
    headers: Dict[str, str] = {}
    for line in lines[1:]:
        if not line:
            continue
        if ":" not in line:
            raise ValueError("cabeçalho HTTP malformado")
        key, value = line.split(":", 1)
        headers[key.strip().lower()] = value.strip()
    return method.upper(), path, headers


def send_http_error(sock: socket.socket, code: int, reason: str) -> None:
    body = f"{code} {reason}\n".encode("ascii", "replace")
    response = (
        f"HTTP/1.1 {code} {reason}\r\n"
        "Connection: close\r\n"
        "Content-Type: text/plain\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode("ascii") + body
    try:
        sock.sendall(response)
    except OSError:
        pass


def websocket_accept(key: str) -> str:
    digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("socket fechado")
        chunks.extend(chunk)
    return bytes(chunks)


def read_frame(sock: socket.socket, max_frame: int) -> Tuple[bool, int, bytes]:
    first, second = recv_exact(sock, 2)
    fin = bool(first & 0x80)
    rsv = first & 0x70
    opcode = first & 0x0F
    masked = bool(second & 0x80)
    length = second & 0x7F

    if rsv:
        raise ValueError("RSV sem extensão negociada")
    if not masked:
        raise ValueError("frame de cliente não mascarado")
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
        if length & (1 << 63):
            raise ValueError("tamanho de frame inválido")
    if length > max_frame:
        raise ValueError("frame excede o limite")
    if opcode >= 0x8 and (not fin or length > 125):
        raise ValueError("frame de controle inválido")

    mask = recv_exact(sock, 4)
    payload = bytearray(recv_exact(sock, length))
    for index in range(length):
        payload[index] ^= mask[index & 3]
    return fin, opcode, bytes(payload)


def make_frame(payload: bytes, opcode: int = 0x2, fin: bool = True) -> bytes:
    first = opcode | (0x80 if fin else 0)
    length = len(payload)
    if length < 126:
        header = bytes((first, length))
    elif length <= 0xFFFF:
        header = bytes((first, 126)) + struct.pack("!H", length)
    else:
        header = bytes((first, 127)) + struct.pack("!Q", length)
    return header + payload


def raw_relay(client: socket.socket, upstream: socket.socket, initial: bytes = b"") -> None:
    if initial:
        upstream.sendall(initial)
    sockets = (client, upstream)
    while True:
        readable, _, exceptional = select.select(sockets, [], sockets, 60)
        if exceptional:
            return
        if not readable:
            continue
        for source in readable:
            data = source.recv(65536)
            if not data:
                return
            target = upstream if source is client else client
            target.sendall(data)


def rfc6455_relay(client: socket.socket, upstream: socket.socket, initial: bytes, max_frame: int) -> None:
    send_lock = threading.Lock()
    stopped = threading.Event()

    def send_client(payload: bytes, opcode: int = 0x2) -> None:
        frame = make_frame(payload, opcode=opcode)
        with send_lock:
            client.sendall(frame)

    def upstream_to_client() -> None:
        try:
            while not stopped.is_set():
                data = upstream.recv(65536)
                if not data:
                    break
                send_client(data, 0x2)
        except OSError:
            pass
        finally:
            stopped.set()
            try:
                client.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    if initial:
        # Bytes following the HTTP header are WebSocket frame bytes, not raw payload.
        # Put them back in front of the stream through a small buffered wrapper is
        # cumbersome with sockets; RFC clients normally wait for 101. Rejecting an
        # eager frame is safer than accidentally forwarding framed bytes to SSH.
        raise ValueError("dados RFC enviados antes da resposta 101 não são suportados")

    thread = threading.Thread(target=upstream_to_client, name="ws-upstream", daemon=True)
    thread.start()
    fragmented = False
    try:
        while not stopped.is_set():
            fin, opcode, payload = read_frame(client, max_frame)
            if opcode == 0x8:  # close
                try:
                    send_client(payload[:125], 0x8)
                except OSError:
                    pass
                break
            if opcode == 0x9:  # ping
                send_client(payload, 0xA)
                continue
            if opcode == 0xA:  # pong
                continue
            if opcode in (0x1, 0x2):
                if fragmented:
                    raise ValueError("nova mensagem antes do fim da fragmentação")
                fragmented = not fin
                if payload:
                    upstream.sendall(payload)
                continue
            if opcode == 0x0:
                if not fragmented:
                    raise ValueError("continuação sem mensagem fragmentada")
                if payload:
                    upstream.sendall(payload)
                if fin:
                    fragmented = False
                continue
            raise ValueError("opcode WebSocket não suportado")
    finally:
        stopped.set()
        try:
            upstream.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        thread.join(timeout=1)


def handle_client(client: socket.socket, address: Tuple[str, int], cfg: Config, slots: threading.BoundedSemaphore) -> None:
    upstream: Optional[socket.socket] = None
    try:
        client.settimeout(15)
        head, initial = recv_until(client, b"\r\n\r\n", cfg.header_limit)
        method, path, headers = parse_request(head)
        if method != "GET":
            send_http_error(client, 405, "Method Not Allowed")
            return
        if path.split("?", 1)[0] != cfg.path:
            send_http_error(client, 404, "Not Found")
            return
        upgrade = headers.get("upgrade", "").lower()
        connection = headers.get("connection", "").lower()
        if upgrade != "websocket" or "upgrade" not in {token.strip() for token in connection.split(",")}:
            send_http_error(client, 426, "Upgrade Required")
            return

        key = headers.get("sec-websocket-key", "")
        selected_mode = cfg.mode
        if selected_mode == "auto":
            selected_mode = "rfc6455" if key else "legacy"
        if selected_mode == "rfc6455":
            if not key:
                send_http_error(client, 400, "Missing WebSocket Key")
                return
            if headers.get("sec-websocket-version", "") != "13":
                send_http_error(client, 400, "Unsupported WebSocket Version")
                return
            try:
                raw_key = base64.b64decode(key.encode("ascii"), validate=True)
            except (UnicodeError, ValueError) as exc:
                LOG.info("%s:%s chave WebSocket inválida: %s", address[0], address[1], exc)
                send_http_error(client, 400, "Invalid WebSocket Key")
                return
            if len(raw_key) != 16:
                send_http_error(client, 400, "Invalid WebSocket Key")
                return

        upstream = socket.create_connection((cfg.upstream_host, cfg.upstream_port), timeout=10)
        upstream.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        client.settimeout(None)
        upstream.settimeout(None)

        if selected_mode == "rfc6455":
            response = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {websocket_accept(key)}\r\n\r\n"
            ).encode("ascii")
            client.sendall(response)
            LOG.info("%s:%s conectado em modo RFC6455", address[0], address[1])
            rfc6455_relay(client, upstream, initial, cfg.max_frame)
        else:
            response = (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n\r\n"
            ).encode("ascii")
            client.sendall(response)
            LOG.info("%s:%s conectado em modo legacy upgrade", address[0], address[1])
            raw_relay(client, upstream, initial)
    except (ConnectionError, OSError, ValueError) as exc:
        LOG.info("%s:%s encerrado: %s", address[0], address[1], exc)
    except Exception:
        LOG.exception("falha inesperada em %s:%s", address[0], address[1])
    finally:
        if upstream is not None:
            try:
                upstream.close()
            except OSError:
                pass
        try:
            client.close()
        except OSError:
            pass
        slots.release()


def serve(cfg: Config) -> None:
    stop = threading.Event()
    slots = threading.BoundedSemaphore(cfg.max_clients)

    def request_stop(_signum: int, _frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((cfg.bind, cfg.port))
        server.listen(min(cfg.max_clients, 4096))
        server.settimeout(1)
        LOG.info(
            "OnePlus WebSocket ouvindo %s:%s caminho=%s modo=%s upstream=%s:%s",
            cfg.bind,
            cfg.port,
            cfg.path,
            cfg.mode,
            cfg.upstream_host,
            cfg.upstream_port,
        )
        while not stop.is_set():
            try:
                client, address = server.accept()
            except socket.timeout:
                continue
            except OSError:
                if stop.is_set():
                    break
                raise
            if not slots.acquire(blocking=False):
                send_http_error(client, 503, "Busy")
                client.close()
                continue
            thread = threading.Thread(
                target=handle_client,
                args=(client, address, cfg, slots),
                name=f"ws-{address[0]}:{address[1]}",
                daemon=True,
            )
            thread.start()


def main() -> int:
    parser = argparse.ArgumentParser(description="OnePlus WebSocket fixed-upstream proxy")
    parser.add_argument("--bind", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--upstream", required=True)
    parser.add_argument("--path", default="/")
    parser.add_argument("--mode", choices=("auto", "rfc6455", "legacy"), default="auto")
    parser.add_argument("--max-clients", type=int, default=256)
    parser.add_argument("--header-limit", type=int, default=16384)
    parser.add_argument("--max-frame", type=int, default=8388608)
    args = parser.parse_args()

    if not (1 <= args.port <= 65535):
        parser.error("porta inválida")
    if not (1 <= args.max_clients <= 4096):
        parser.error("max-clients deve estar entre 1 e 4096")
    if not (1024 <= args.header_limit <= 65536):
        parser.error("header-limit deve estar entre 1024 e 65536")
    if not (125 <= args.max_frame <= 67108864):
        parser.error("max-frame deve estar entre 125 e 67108864")
    upstream_host, upstream_port = parse_host_port(args.upstream)
    cfg = Config(
        bind=args.bind,
        port=args.port,
        upstream_host=upstream_host,
        upstream_port=upstream_port,
        path=args.path,
        mode=args.mode,
        max_clients=args.max_clients,
        header_limit=args.header_limit,
        max_frame=args.max_frame,
    )
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    serve(cfg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
