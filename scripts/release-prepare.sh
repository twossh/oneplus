#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRET_KEY="${1:-}"
PUBLIC_KEY="${2:-}"

usage() {
  cat >&2 <<EOF
Uso: $0 /caminho/seguro/oneplus-release.key /caminho/oneplus-release.pub

Gera:
  release/SHA256SUMS
  release/SHA256SUMS.minisig
  dist/OnePlus-vX.Y.Z.tar.gz
  dist/OnePlus-vX.Y.Z.tar.gz.sha256
  dist/OnePlus-vX.Y.Z.tar.gz.sha256.minisig
EOF
}

[[ -n "$SECRET_KEY" && -n "$PUBLIC_KEY" ]] || { usage; exit 2; }
[[ "$SECRET_KEY" == /* && "$PUBLIC_KEY" == /* ]] || { echo "[ERRO] Use caminhos absolutos para as chaves." >&2; exit 2; }
[[ -f "$SECRET_KEY" && -f "$PUBLIC_KEY" ]] || { echo "[ERRO] Chave privada/pública não encontrada." >&2; exit 1; }
command -v minisign >/dev/null 2>&1 || { echo "[ERRO] minisign não instalado." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[ERRO] python3 não instalado." >&2; exit 1; }

ROOT_REAL=$(realpath -e "$ROOT_DIR")
SECRET_REAL=$(realpath -e "$SECRET_KEY")
case "$SECRET_REAL" in
  "$ROOT_REAL"/*) echo "[ERRO] A chave privada está dentro do repositório. Mova-a para um local seguro." >&2; exit 1 ;;
esac

# Normaliza permissões antes de verificar se o checkout está pronto para release.
bash "$ROOT_DIR/scripts/fix-permissions.sh"

VERSION=$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "[ERRO] VERSION inválida." >&2; exit 1; }
grep -Fq "## ${VERSION} " "$ROOT_DIR/CHANGELOG.md" || { echo "[ERRO] CHANGELOG não contém seção para ${VERSION}." >&2; exit 1; }

if find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type l -print -quit | grep -q .; then
  echo "[ERRO] Links simbólicos não são permitidos na árvore de release." >&2
  exit 1
fi

if [[ -d "$ROOT_DIR/.git" ]]; then
  # A tag precisa preservar 100755 mesmo quando o checkout foi preparado no Windows/GitHub Web.
  bad_mode=0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    mode=$(git -C "$ROOT_DIR" ls-files -s -- "$rel" | awk 'NR==1{print $1}')
    if [[ "$mode" != 100755 ]]; then
      echo "[ERRO] Git não registra 100755 para $rel (modo: ${mode:-N/D})." >&2
      bad_mode=1
    fi
  done < <(
    {
      printf '%s\n' setup.sh install.sh uninstall.sh bin/oneplus
      find "$ROOT_DIR/lib" "$ROOT_DIR/modules" -maxdepth 1 -type f -name '*.sh' -print
      find "$ROOT_DIR/libexec" -maxdepth 1 -type f -print
      find "$ROOT_DIR/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -print
    } | sed "s#^$ROOT_DIR/##" | LC_ALL=C sort -u
  )
  if (( bad_mode )); then
    echo "[ERRO] Execute: bash scripts/git-fix-modes.sh ; faça commit; depois prepare a release." >&2
    exit 1
  fi
  if [[ "${ONEPLUS_ALLOW_DIRTY:-no}" != yes ]] && { ! git -C "$ROOT_DIR" diff --quiet -- . || ! git -C "$ROOT_DIR" diff --cached --quiet -- .; }; then
    echo "[ERRO] Há alterações rastreadas não commitadas. Faça commit antes de preparar a release." >&2
    exit 1
  fi
fi

printf '[INFO] Validando fonte...\n'
bash "$ROOT_DIR/scripts/validate.sh"
bash "$ROOT_DIR/scripts/test-openvpn.sh"
bash "$ROOT_DIR/scripts/test-mux.sh"
bash "$ROOT_DIR/scripts/test-operations.sh"
python3 "$ROOT_DIR/scripts/test-websocket.py"
python3 "$ROOT_DIR/scripts/test-release.py"
python3 "$ROOT_DIR/scripts/test-update-metadata.py"

mkdir -p "$ROOT_DIR/release" "$ROOT_DIR/dist"
rm -f -- "$ROOT_DIR/release/SHA256SUMS" "$ROOT_DIR/release/SHA256SUMS.minisig"
rm -f -- "$ROOT_DIR/dist/OnePlus-v${VERSION}.tar.gz" \
  "$ROOT_DIR/dist/OnePlus-v${VERSION}.tar.gz.sha256" \
  "$ROOT_DIR/dist/OnePlus-v${VERSION}.tar.gz.sha256.minisig"

printf '[INFO] Gerando manifesto interno SHA-256...\n'
(
  cd "$ROOT_DIR"
  find . -type f \
    -not -path './.git/*' \
    -not -path './dist/*' \
    -not -path './release/SHA256SUMS' \
    -not -path './release/SHA256SUMS.minisig' \
    -not -name '*.zip' -not -name '*.tar.gz' -not -name '*.sha256' \
    -print0 | LC_ALL=C sort -z | xargs -0 sha256sum > release/SHA256SUMS
)
chmod 0644 "$ROOT_DIR/release/SHA256SUMS"
minisign -S -s "$SECRET_KEY" -m "$ROOT_DIR/release/SHA256SUMS" \
  -x "$ROOT_DIR/release/SHA256SUMS.minisig" -t "OnePlus v${VERSION} source manifest"
chmod 0644 "$ROOT_DIR/release/SHA256SUMS.minisig"
minisign -Vm "$ROOT_DIR/release/SHA256SUMS" -x "$ROOT_DIR/release/SHA256SUMS.minisig" -p "$PUBLIC_KEY" >/dev/null

TMP=$(mktemp -d "${TMPDIR:-/tmp}/oneplus-release.XXXXXX")
trap 'rm -rf -- "${TMP:-}"' EXIT
TOP="OnePlus-v${VERSION}"
mkdir -p "$TMP/$TOP"
rsync -a \
  --exclude '.git' --exclude 'dist' --exclude '*.zip' --exclude '*.tar.gz' --exclude '*.sha256' \
  "$ROOT_DIR/" "$TMP/$TOP/"
# Não transportar bits especiais herdados do filesystem de desenvolvimento.
find "$TMP/$TOP" -exec chmod u-s,g-s {} +
chmod 0755 "$TMP/$TOP"

SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-}
if [[ -z "$SOURCE_DATE_EPOCH" && -d "$ROOT_DIR/.git" ]]; then
  SOURCE_DATE_EPOCH=$(git -C "$ROOT_DIR" log -1 --format=%ct 2>/dev/null || true)
fi
[[ "$SOURCE_DATE_EPOCH" =~ ^[0-9]+$ ]] || SOURCE_DATE_EPOCH=0
ARCHIVE="$ROOT_DIR/dist/${TOP}.tar.gz"
(
  cd "$TMP"
  tar --sort=name --mtime="@${SOURCE_DATE_EPOCH}" --owner=0 --group=0 --numeric-owner \
    --format=pax --pax-option=delete=atime,delete=ctime -cf - "$TOP" | gzip -n -9 > "$ARCHIVE"
)
chmod 0644 "$ARCHIVE"

python3 "$ROOT_DIR/libexec/release_verify.py" inspect "$ARCHIVE" "$TOP" >/dev/null
(
  cd "$ROOT_DIR/dist"
  sha256sum "${TOP}.tar.gz" > "${TOP}.tar.gz.sha256"
)
chmod 0644 "$ROOT_DIR/dist/${TOP}.tar.gz.sha256"
minisign -S -s "$SECRET_KEY" -m "$ROOT_DIR/dist/${TOP}.tar.gz.sha256" \
  -x "$ROOT_DIR/dist/${TOP}.tar.gz.sha256.minisig" -t "OnePlus v${VERSION} release archive checksum"
chmod 0644 "$ROOT_DIR/dist/${TOP}.tar.gz.sha256.minisig"
minisign -Vm "$ROOT_DIR/dist/${TOP}.tar.gz.sha256" \
  -x "$ROOT_DIR/dist/${TOP}.tar.gz.sha256.minisig" -p "$PUBLIC_KEY" >/dev/null

printf '\n[OK] Release v%s preparada e verificada.\n' "$VERSION"
printf 'Arquivos para commit/tag:\n  release/SHA256SUMS\n  release/SHA256SUMS.minisig\n'
printf 'Assets para GitHub Release:\n  dist/%s.tar.gz\n  dist/%s.tar.gz.sha256\n  dist/%s.tar.gz.sha256.minisig\n' "$TOP" "$TOP" "$TOP"
printf '\nPróximo passo: commit dos dois arquivos release/, tag v%s e publicação dos três assets em uma GitHub Release com a mesma tag.\n' "$VERSION"
