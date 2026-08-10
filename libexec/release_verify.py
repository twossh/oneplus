#!/usr/bin/env python3
"""Safely inspect/extract OnePlus signed release archives.

Only regular files and directories under the expected top-level directory are
accepted. Symlinks, hardlinks, devices, FIFOs, absolute paths, traversal and
setuid/setgid bits are rejected before extraction.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tarfile

MAX_MEMBERS = 5000
MAX_TOTAL_BYTES = 128 * 1024 * 1024
MAX_FILE_BYTES = 32 * 1024 * 1024


class ReleaseError(RuntimeError):
    pass


def safe_parts(name: str) -> tuple[str, ...]:
    if (
        not name
        or name.startswith("/")
        or "\x00" in name
        or "\\" in name
        or any(ord(ch) < 32 or ord(ch) == 127 for ch in name)
    ):
        raise ReleaseError(f"caminho inválido no arquivo: {name!r}")
    p = PurePosixPath(name)
    parts = p.parts
    if not parts or any(part in ("", ".", "..") for part in parts):
        raise ReleaseError(f"travessia/caminho inválido: {name!r}")
    return parts


def validate_archive(archive: Path, expected_root: str) -> list[tarfile.TarInfo]:
    if not expected_root or "/" in expected_root or expected_root in (".", ".."):
        raise ReleaseError("expected_root inválido")

    members: list[tarfile.TarInfo] = []
    seen: set[str] = set()
    total = 0
    required = {
        f"{expected_root}/VERSION",
        f"{expected_root}/install.sh",
        f"{expected_root}/bin/oneplus",
        f"{expected_root}/scripts/validate.sh",
        f"{expected_root}/release/SHA256SUMS",
        f"{expected_root}/release/SHA256SUMS.minisig",
    }

    try:
        tf = tarfile.open(archive, mode="r:gz")
    except (tarfile.TarError, OSError) as exc:
        raise ReleaseError(f"arquivo tar.gz inválido: {exc}") from exc

    with tf:
        for idx, member in enumerate(tf, start=1):
            if idx > MAX_MEMBERS:
                raise ReleaseError("release contém arquivos demais")
            parts = safe_parts(member.name)
            if parts[0] != expected_root:
                raise ReleaseError(f"entrada fora do diretório esperado: {member.name}")
            normalized = "/".join(parts)
            if normalized in seen:
                raise ReleaseError(f"entrada duplicada: {normalized}")
            seen.add(normalized)

            if not (member.isdir() or member.isfile()):
                raise ReleaseError(f"tipo de entrada proibido: {member.name}")
            if member.mode & (stat.S_ISUID | stat.S_ISGID):
                raise ReleaseError(f"bit setuid/setgid proibido: {member.name}")
            if member.isfile():
                if member.size < 0 or member.size > MAX_FILE_BYTES:
                    raise ReleaseError(f"arquivo acima do limite: {member.name}")
                total += member.size
                if total > MAX_TOTAL_BYTES:
                    raise ReleaseError("release excede o limite total de tamanho")
            members.append(member)

        missing = sorted(required - seen)
        if missing:
            raise ReleaseError("arquivos obrigatórios ausentes: " + ", ".join(missing))

    return members


def extract_archive(archive: Path, destination: Path, expected_root: str) -> Path:
    members = validate_archive(archive, expected_root)
    destination.mkdir(parents=True, exist_ok=True)
    base = destination.resolve()
    top = base / expected_root
    if top.exists():
        raise ReleaseError(f"destino já existe: {top}")

    with tarfile.open(archive, mode="r:gz") as tf:
        for member in members:
            parts = safe_parts(member.name)
            target = base.joinpath(*parts)
            parent = target.parent
            parent.mkdir(parents=True, exist_ok=True)
            resolved_parent = parent.resolve()
            try:
                resolved_parent.relative_to(base)
            except ValueError as exc:
                raise ReleaseError(f"destino escapou do diretório temporário: {member.name}") from exc

            if member.isdir():
                target.mkdir(mode=member.mode & 0o777, exist_ok=True)
                os.chmod(target, member.mode & 0o777)
                continue

            if target.exists():
                raise ReleaseError(f"destino duplicado durante extração: {member.name}")
            src = tf.extractfile(member)
            if src is None:
                raise ReleaseError(f"não foi possível ler: {member.name}")
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
            if hasattr(os, "O_NOFOLLOW"):
                flags |= os.O_NOFOLLOW
            fd = os.open(target, flags, member.mode & 0o777)
            written = 0
            try:
                with os.fdopen(fd, "wb") as dst, src:
                    while True:
                        chunk = src.read(1024 * 1024)
                        if not chunk:
                            break
                        written += len(chunk)
                        if written > member.size:
                            raise ReleaseError(f"tamanho divergente: {member.name}")
                        dst.write(chunk)
                if written != member.size:
                    raise ReleaseError(f"tamanho divergente: {member.name}")
                os.chmod(target, member.mode & 0o777)
            except Exception:
                try:
                    target.unlink(missing_ok=True)
                except OSError:
                    pass
                raise

    return top


def main() -> int:
    parser = argparse.ArgumentParser(description="Valida/extrai release OnePlus com segurança")
    parser.add_argument("mode", choices=("inspect", "extract"))
    parser.add_argument("archive", type=Path)
    parser.add_argument("expected_root")
    parser.add_argument("destination", nargs="?", type=Path)
    args = parser.parse_args()

    try:
        if args.mode == "inspect":
            validate_archive(args.archive, args.expected_root)
            print("RELEASE ARCHIVE: OK")
        else:
            if args.destination is None:
                parser.error("destination é obrigatório no modo extract")
            out = extract_archive(args.archive, args.destination, args.expected_root)
            print(out)
        return 0
    except ReleaseError as exc:
        print(f"[ERRO] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
