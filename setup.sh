#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/twossh/oneplus.git"
ONEPLUS_REF="${ONEPLUS_REF:-main}"
TMP_DIR=""

cleanup() {
  [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]] && rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT
trap 'printf "\n[ERRO] Bootstrap interrompido na linha %s.\n" "$LINENO" >&2' ERR

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf '[ERRO] Execute como root ou via sudo.\n' >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  printf '[ERRO] /etc/os-release não encontrado.\n' >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]] || ! dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04; then
  printf '[ERRO] OnePlus requer Ubuntu 24.04 ou superior. Detectado: %s\n' "${PRETTY_NAME:-desconhecido}" >&2
  exit 1
fi

if [[ ! "$ONEPLUS_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || [[ "$ONEPLUS_REF" == *".."* ]]; then
  printf '[ERRO] Referência Git inválida: %s\n' "$ONEPLUS_REF" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
printf '[INFO] Preparando dependências do bootstrap...\n'
bootstrap_missing=()
for pkg in ca-certificates git; do
  if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed'; then
    bootstrap_missing+=("$pkg")
  fi
done
if (( ${#bootstrap_missing[@]} )); then
  apt-get update
  apt-get install -y --no-install-recommends "${bootstrap_missing[@]}"
else
  printf '[INFO] Dependências do bootstrap já instaladas; apt ignorado.\n'
fi

TMP_DIR=$(mktemp -d /tmp/oneplus-setup.XXXXXX)
SRC_DIR="$TMP_DIR/oneplus"
printf '[INFO] Baixando OnePlus (%s)...\n' "$ONEPLUS_REF"
git -c advice.detachedHead=false clone --depth 1 --branch "$ONEPLUS_REF" "$REPO_URL" "$SRC_DIR"

COMMIT=$(git -C "$SRC_DIR" rev-parse HEAD)
printf '[INFO] Commit: %s\n' "$COMMIT"

# GitHub Web Upload pode não preservar bits executáveis. Centralizamos a
# normalização antes de qualquer validação.
chmod 0755 "$SRC_DIR/scripts/fix-permissions.sh"
bash "$SRC_DIR/scripts/fix-permissions.sh"

printf '[INFO] Validando a árvore baixada...\n'
bash "$SRC_DIR/scripts/validate.sh"

printf '[INFO] Iniciando instalação...\n'
bash "$SRC_DIR/install.sh"

printf '[INFO] Executando validação pós-instalação...\n'
/usr/local/bin/oneplus --check

printf '\n[OK] OnePlus instalado com sucesso.\n'
printf 'Execute: oneplus\n'
