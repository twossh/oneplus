#!/usr/bin/env python3
from __future__ import annotations

import io
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "libexec" / "release_verify.py"
TOP = "OnePlus-v9.9.9"
REQUIRED = [
    "VERSION",
    "install.sh",
    "bin/oneplus",
    "scripts/validate.sh",
    "release/SHA256SUMS",
    "release/SHA256SUMS.minisig",
]


def add_file(tf: tarfile.TarFile, name: str, data: bytes = b"x", mode: int = 0o644) -> None:
    ti = tarfile.TarInfo(name)
    ti.size = len(data)
    ti.mode = mode
    tf.addfile(ti, io.BytesIO(data))


def make_good(path: Path) -> None:
    with tarfile.open(path, "w:gz") as tf:
        d = tarfile.TarInfo(TOP)
        d.type = tarfile.DIRTYPE
        d.mode = 0o755
        tf.addfile(d)
        for rel in REQUIRED:
            mode = 0o755 if rel in {"install.sh", "bin/oneplus", "scripts/validate.sh"} else 0o644
            add_file(tf, f"{TOP}/{rel}", b"0.0\n" if rel == "VERSION" else b"test\n", mode)


def run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["python3", str(VERIFY), *args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def expect_fail(path: Path, label: str) -> None:
    p = run("inspect", str(path), TOP)
    if p.returncode == 0:
        raise SystemExit(f"[ERRO] archive malicioso aceito: {label}")


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="oneplus-release-test.") as td:
        td = Path(td)
        good = td / "good.tar.gz"
        make_good(good)
        p = run("inspect", str(good), TOP)
        if p.returncode != 0:
            raise SystemExit(f"[ERRO] archive válido recusado: {p.stderr}")
        out = td / "out"
        p = run("extract", str(good), TOP, str(out))
        if p.returncode != 0 or not (out / TOP / "VERSION").is_file():
            raise SystemExit(f"[ERRO] extração válida falhou: {p.stderr}")

        traversal = td / "traversal.tar.gz"
        with tarfile.open(traversal, "w:gz") as tf:
            for rel in REQUIRED:
                add_file(tf, f"{TOP}/{rel}")
            add_file(tf, f"{TOP}/../escape", b"bad")
        expect_fail(traversal, "path traversal")

        symlink = td / "symlink.tar.gz"
        with tarfile.open(symlink, "w:gz") as tf:
            for rel in REQUIRED:
                add_file(tf, f"{TOP}/{rel}")
            ti = tarfile.TarInfo(f"{TOP}/link")
            ti.type = tarfile.SYMTYPE
            ti.linkname = "/etc/shadow"
            tf.addfile(ti)
        expect_fail(symlink, "symlink")

        hardlink = td / "hardlink.tar.gz"
        with tarfile.open(hardlink, "w:gz") as tf:
            for rel in REQUIRED:
                add_file(tf, f"{TOP}/{rel}")
            ti = tarfile.TarInfo(f"{TOP}/hard")
            ti.type = tarfile.LNKTYPE
            ti.linkname = f"{TOP}/VERSION"
            tf.addfile(ti)
        expect_fail(hardlink, "hardlink")

        suid = td / "suid.tar.gz"
        with tarfile.open(suid, "w:gz") as tf:
            for rel in REQUIRED:
                add_file(tf, f"{TOP}/{rel}")
            add_file(tf, f"{TOP}/suid", b"x", 0o4755)
        expect_fail(suid, "setuid")

        outside = td / "outside.tar.gz"
        with tarfile.open(outside, "w:gz") as tf:
            for rel in REQUIRED:
                add_file(tf, f"{TOP}/{rel}")
            add_file(tf, "OtherRoot/file", b"bad")
        expect_fail(outside, "outro top-level")

    print("RELEASE TESTS: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
