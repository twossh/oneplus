#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_KEY="${1:-}"
[[ -n "$SECRET_KEY" && -f "$SECRET_KEY" ]] || { echo "Uso: $0 /caminho/seguro/minisign.key" >&2; exit 2; }
command -v minisign >/dev/null 2>&1 || { echo "minisign não instalado." >&2; exit 1; }
VERSION=$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "VERSION inválida." >&2; exit 1; }
mkdir -p "$ROOT_DIR/release"
cd "$ROOT_DIR"
find . -type f \
  -not -path './.git/*' \
  -not -path './dist/*' \
  -not -path './release/SHA256SUMS' \
  -not -path './release/SHA256SUMS.minisig' \
  -not -name '*.zip' -not -name '*.sha256' \
  -print0 | sort -z | xargs -0 sha256sum > release/SHA256SUMS
minisign -S -s "$SECRET_KEY" -m release/SHA256SUMS -x release/SHA256SUMS.minisig \
  -t "OnePlus v${VERSION} source manifest"
printf 'Manifesto assinado para OnePlus v%s.\n' "$VERSION"
printf 'Agora revise, faça commit de release/SHA256SUMS{,.minisig}, crie a tag v%s e faça push da tag.\n' "$VERSION"
