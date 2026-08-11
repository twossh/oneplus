#!/usr/bin/env python3
from __future__ import annotations

import sys
sys.dont_write_bytecode = True
import importlib.util
from pathlib import Path
import tempfile
import json

ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "libexec" / "github_release.py"
spec = importlib.util.spec_from_file_location("oneplus_github_release", HELPER_PATH)
assert spec and spec.loader
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

TAG = "v0.5.2"
BASE = "OnePlus-v0.5.2.tar.gz"


def asset(name: str, size: int, digest: str | None = None) -> dict:
    item = {
        "name": name,
        "state": "uploaded",
        "size": size,
        "browser_download_url": f"https://github.com/twossh/oneplus/releases/download/{TAG}/{name}",
    }
    if digest is not None:
        item["digest"] = digest
    return item


def release() -> dict:
    return {
        "tag_name": TAG,
        "name": "OnePlus 0.5.2",
        "body": "Atualização estável.\nSem execução automática.\x1b[31m",
        "draft": False,
        "prerelease": False,
        "published_at": "2026-08-10T20:00:00Z",
        "html_url": f"https://github.com/twossh/oneplus/releases/tag/{TAG}",
        "assets": [
            asset(BASE, 123456, "sha256:" + "a" * 64),
            asset(BASE + ".sha256", 96),
            asset(BASE + ".sha256.minisig", 512),
        ],
    }


def must_fail(data: dict, fn) -> None:
    try:
        fn(data)
    except mod.MetadataError:
        return
    raise AssertionError("esperava MetadataError")


def main() -> None:
    good = release()
    assert mod.validate_release(good, TAG) == TAG
    assert mod.get_asset(good, BASE, TAG)["browser_download_url"].endswith(f"/{TAG}/{BASE}")
    text = mod.summary(good, TAG)
    assert "Release: v0.5.2" in text
    assert "\x1b" not in text

    # Também valida o carregamento JSON usado pela CLI.
    with tempfile.TemporaryDirectory(prefix="oneplus-meta-test.") as td:
        p = Path(td) / "release.json"
        p.write_text(json.dumps(good), encoding="utf-8")
        assert mod.validate_release(mod.load_release(p), TAG) == TAG

    bad = release(); bad["draft"] = True
    must_fail(bad, mod.validate_release)
    bad = release(); bad["prerelease"] = True
    must_fail(bad, mod.validate_release)
    bad = release(); bad["tag_name"] = "nightly"
    must_fail(bad, mod.validate_release)
    bad = release(); bad["assets"] = bad["assets"][:-1]
    must_fail(bad, mod.validate_release)
    bad = release(); bad["assets"].append(dict(bad["assets"][0]))
    must_fail(bad, mod.validate_release)
    bad = release(); bad["assets"][0]["browser_download_url"] = "https://example.invalid/payload"
    must_fail(bad, mod.validate_release)
    bad = release(); bad["assets"][0]["size"] = 65 * 1024 * 1024
    must_fail(bad, mod.validate_release)
    bad = release(); bad["assets"][0]["digest"] = "sha256:not-a-hash"
    must_fail(bad, mod.validate_release)
    bad = release(); bad["html_url"] = "https://example.invalid/release"
    must_fail(bad, mod.summary)

    print("UPDATE METADATA TESTS: OK")


if __name__ == "__main__":
    main()
