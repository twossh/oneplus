#!/usr/bin/env python3
"""Validate and read GitHub Release metadata for OnePlus.

This helper deliberately performs no network I/O. modules/update.sh downloads JSON
from the fixed GitHub REST endpoint over HTTPS, and this program validates the
shape, stable-release policy, expected asset names and browser download URLs
before any asset URL is used.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

REPO = "twossh/oneplus"
RELEASE_PREFIX = f"https://github.com/{REPO}/releases/download"
TAG_RE = re.compile(r"^v([0-9]+)\.([0-9]+)\.([0-9]+)$")
SHA256_DIGEST_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
MAX_JSON_BYTES = 2 * 1024 * 1024
MAX_ARCHIVE_BYTES = 64 * 1024 * 1024
MAX_SMALL_ASSET_BYTES = 64 * 1024
MAX_NOTES_CHARS = 6000


class MetadataError(RuntimeError):
    pass


def load_release(path: Path) -> dict[str, Any]:
    try:
        st = path.stat()
    except OSError as exc:
        raise MetadataError(f"não foi possível ler metadados: {exc}") from exc
    if st.st_size <= 0 or st.st_size > MAX_JSON_BYTES:
        raise MetadataError("JSON da release vazio ou acima do limite")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise MetadataError(f"JSON de release inválido: {exc}") from exc
    if not isinstance(data, dict):
        raise MetadataError("resposta da release não é um objeto JSON")
    return data


def stable_tag(data: dict[str, Any], expected_tag: str | None = None) -> str:
    tag = data.get("tag_name")
    if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
        raise MetadataError("tag_name não é uma versão estável vX.Y.Z")
    if expected_tag is not None and tag != expected_tag:
        raise MetadataError(f"GitHub retornou tag {tag}, esperada {expected_tag}")
    if data.get("draft") is not False:
        raise MetadataError("draft release recusada")
    if data.get("prerelease") is not False:
        raise MetadataError("prerelease recusada pelo canal estável")
    return tag


def expected_assets(tag: str) -> tuple[str, str, str]:
    version = tag[1:]
    base = f"OnePlus-v{version}.tar.gz"
    return base, f"{base}.sha256", f"{base}.sha256.minisig"


def asset_map(data: dict[str, Any]) -> dict[str, dict[str, Any]]:
    assets = data.get("assets")
    if not isinstance(assets, list):
        raise MetadataError("campo assets ausente/inválido")
    out: dict[str, dict[str, Any]] = {}
    for item in assets:
        if not isinstance(item, dict):
            raise MetadataError("asset inválido")
        name = item.get("name")
        if not isinstance(name, str) or not name or len(name) > 255:
            raise MetadataError("nome de asset inválido")
        if name in out:
            raise MetadataError(f"asset duplicado: {name}")
        out[name] = item
    return out


def validate_asset(item: dict[str, Any], tag: str, name: str) -> None:
    if item.get("state") != "uploaded":
        raise MetadataError(f"asset não está em estado uploaded: {name}")
    url = item.get("browser_download_url")
    expected_url = f"{RELEASE_PREFIX}/{tag}/{name}"
    if url != expected_url:
        raise MetadataError(f"URL inesperada para asset {name}")
    size = item.get("size")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        raise MetadataError(f"tamanho inválido para asset {name}")
    limit = MAX_ARCHIVE_BYTES if name.endswith(".tar.gz") else MAX_SMALL_ASSET_BYTES
    if size > limit:
        raise MetadataError(f"asset acima do limite: {name}")
    digest = item.get("digest")
    if digest is not None and (
        not isinstance(digest, str) or SHA256_DIGEST_RE.fullmatch(digest) is None
    ):
        raise MetadataError(f"digest GitHub inválido para asset {name}")


def validate_release(data: dict[str, Any], expected_tag: str | None = None) -> str:
    tag = stable_tag(data, expected_tag)
    assets = asset_map(data)
    for name in expected_assets(tag):
        if name not in assets:
            raise MetadataError(f"asset obrigatório ausente: {name}")
        validate_asset(assets[name], tag, name)
    return tag


def get_asset(data: dict[str, Any], name: str, expected_tag: str | None = None) -> dict[str, Any]:
    tag = validate_release(data, expected_tag)
    if name not in expected_assets(tag):
        raise MetadataError("nome de asset não pertence à release OnePlus esperada")
    return asset_map(data)[name]


def clean_text(value: Any, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    # Preserve newline/tab for readable notes, remove terminal/control sequences.
    chars: list[str] = []
    for ch in value:
        code = ord(ch)
        if ch in "\n\t" or (32 <= code != 127):
            chars.append(ch)
    text = "".join(chars).replace("\x1b", "")
    return text[:limit]


def summary(data: dict[str, Any], expected_tag: str | None = None) -> str:
    tag = validate_release(data, expected_tag)
    title = clean_text(data.get("name"), 200) or tag
    published = clean_text(data.get("published_at"), 80) or "N/D"
    html_url = data.get("html_url")
    expected_html = f"https://github.com/{REPO}/releases/tag/{tag}"
    if html_url != expected_html:
        # html_url is display-only, but reject unexpected hosts/paths anyway.
        raise MetadataError("html_url inesperada na release")
    notes = clean_text(data.get("body"), MAX_NOTES_CHARS).strip()
    lines = [f"Release: {tag}", f"Nome: {title}", f"Publicada: {published}", f"Página: {html_url}"]
    if notes:
        lines.extend(["", "Notas:", notes])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Valida metadados de GitHub Release do OnePlus")
    parser.add_argument("command", choices=("validate", "tag", "summary", "asset-url", "asset-digest", "asset-size"))
    parser.add_argument("json_file", type=Path)
    parser.add_argument("arg", nargs="?")
    parser.add_argument("--expect-tag", dest="expected_tag")
    args = parser.parse_args()

    try:
        data = load_release(args.json_file)
        if args.command == "validate":
            tag = validate_release(data, args.expected_tag)
            print(f"GITHUB RELEASE METADATA: OK ({tag})")
        elif args.command == "tag":
            print(validate_release(data, args.expected_tag))
        elif args.command == "summary":
            print(summary(data, args.expected_tag))
        else:
            if not args.arg:
                parser.error(f"{args.command} exige o nome do asset")
            item = get_asset(data, args.arg, args.expected_tag)
            if args.command == "asset-url":
                print(item["browser_download_url"])
            elif args.command == "asset-digest":
                print(item.get("digest") or "")
            else:
                print(item["size"])
        return 0
    except MetadataError as exc:
        print(f"[ERRO] {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
