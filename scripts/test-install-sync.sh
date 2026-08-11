#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/install_helpers.sh"

fail() { echo "[FAIL] $*" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
SRC="$TMP/source"
DST="$TMP/dest"
mkdir -p "$SRC/bin" "$SRC/lib" "$SRC/scripts" "$DST/bin" "$DST/lib" "$DST/scripts"

# Conteúdos diferentes, mesmo tamanho e exatamente o mesmo mtime. Esse é o
# cenário que fez o upgrade 0.8.0 -> 0.8.1 manter VERSION antigo no runner.
printf '0.8.2\n' > "$SRC/VERSION"
printf '0.8.1\n' > "$DST/VERSION"
printf 'new-code\n' > "$SRC/bin/oneplus"
printf 'old-code\n' > "$DST/bin/oneplus"
printf 'new-inst\n' > "$SRC/install.sh"
printf 'old-inst\n' > "$DST/install.sh"
printf 'new-libx\n' > "$SRC/lib/common.sh"
printf 'old-libx\n' > "$DST/lib/common.sh"
printf 'new-test\n' > "$SRC/scripts/validate.sh"
printf 'old-test\n' > "$DST/scripts/validate.sh"
find "$SRC" "$DST" -type f -exec touch -t 202608110041.00 {} +

# Demonstra a pré-condição: tamanho+mtime são iguais para VERSION.
[[ $(stat -c '%s:%Y' "$SRC/VERSION") == $(stat -c '%s:%Y' "$DST/VERSION") ]] || fail "fixture não reproduziu quick-check ambíguo"

oneplus_sync_tree "$SRC" "$DST"
oneplus_verify_synced_core "$SRC" "$DST"
[[ "$(cat "$DST/VERSION")" == 0.8.2 ]] || fail "VERSION antigo sobreviveu à sincronização"
[[ "$(cat "$DST/bin/oneplus")" == new-code ]] || fail "arquivo de mesmo tamanho/mtime não foi atualizado"
# Executar install.sh diretamente de /opt/oneplus deve ser reparo/no-op, não erro.
oneplus_sync_tree "$DST" "$DST"
oneplus_verify_synced_core "$DST" "$DST"

echo 'INSTALL SYNC TESTS: OK'
