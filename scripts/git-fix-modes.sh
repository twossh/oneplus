#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v git >/dev/null 2>&1 || { echo "[ERRO] git não instalado." >&2; exit 1; }
git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "[ERRO] Execute dentro de um clone Git do OnePlus." >&2; exit 1; }

execs=(setup.sh install.sh uninstall.sh bin/oneplus)
while IFS= read -r f; do execs+=("${f#"$ROOT_DIR/"}"); done < <(find "$ROOT_DIR/lib" "$ROOT_DIR/modules" -maxdepth 1 -type f -name '*.sh' -print | LC_ALL=C sort)
while IFS= read -r f; do execs+=("${f#"$ROOT_DIR/"}"); done < <(find "$ROOT_DIR/libexec" -maxdepth 1 -type f -print | LC_ALL=C sort)
while IFS= read -r f; do execs+=("${f#"$ROOT_DIR/"}"); done < <(find "$ROOT_DIR/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -print | LC_ALL=C sort)

for rel in "${execs[@]}"; do
  git -C "$ROOT_DIR" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1 || continue
  git -C "$ROOT_DIR" update-index --chmod=+x -- "$rel"
done

printf '[OK] Bits executáveis preparados no índice Git.\n'
printf 'Revise e faça commit das alterações de modo antes da tag:\n'
git -C "$ROOT_DIR" diff --cached --summary -- . || true
