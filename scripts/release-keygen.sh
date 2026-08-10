#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="${1:-}"

usage() {
  cat >&2 <<EOF
Uso: $0 /diretorio/seguro/oneplus-release

O diretório deve ficar FORA do repositório OnePlus. A chave privada nunca deve
ser enviada ao GitHub nem instalada em VPS de produção.
EOF
}

[[ -n "$TARGET_DIR" && "$TARGET_DIR" == /* ]] || { usage; exit 2; }
command -v minisign >/dev/null 2>&1 || { echo "[ERRO] minisign não instalado." >&2; exit 1; }

ROOT_REAL=$(realpath -e "$ROOT_DIR")
mkdir -p -- "$TARGET_DIR"
TARGET_REAL=$(realpath -e "$TARGET_DIR")
case "$TARGET_REAL/" in
  "$ROOT_REAL/"*) echo "[ERRO] O diretório de chaves não pode ficar dentro do repositório." >&2; exit 1 ;;
esac
chmod 0700 "$TARGET_REAL"

SECRET="$TARGET_REAL/oneplus-release.key"
PUBLIC="$TARGET_REAL/oneplus-release.pub"
[[ ! -e "$SECRET" && ! -e "$PUBLIC" ]] || { echo "[ERRO] Já existe material de chave em $TARGET_REAL" >&2; exit 1; }

printf '[INFO] Gerando chave Minisign. Defina uma senha forte para a chave privada.\n'
minisign -G -p "$PUBLIC" -s "$SECRET"
chmod 0600 "$SECRET"
chmod 0644 "$PUBLIC"

printf '\n[OK] Chaves geradas.\n'
printf 'Privada (guardar offline): %s\n' "$SECRET"
printf 'Pública (pode ser distribuída): %s\n' "$PUBLIC"
printf 'SHA-256 da chave pública: '
sha256sum "$PUBLIC" | awk '{print $1}'
printf '\nA chave privada NÃO deve ser copiada para a VPS ou para o GitHub.\n'
