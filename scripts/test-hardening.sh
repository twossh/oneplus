#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "$ROOT_DIR/modules/hardening.sh"

# Hardening is intentionally audit-only. Refuse host-mutating primitives in this module.
if grep -nE '^[[:space:]]*(sudo[[:space:]]+)?(apt|apt-get)[[:space:]].*(install|upgrade|dist-upgrade)|^[[:space:]]*systemctl[[:space:]]+(start|stop|restart|enable|disable|mask|unmask)|^[[:space:]]*nft[[:space:]]+(add|delete|flush)|^[[:space:]]*sysctl[[:space:]]+-w|^[[:space:]]*sed[[:space:]]+-i[^[:cntrl:]]*sshd_config' "$ROOT_DIR/modules/hardening.sh"; then
  echo "[ERRO] hardening audit-only contém comando mutável proibido" >&2
  exit 1
fi

grep -Fq 'Modo: AUDIT-ONLY' "$ROOT_DIR/modules/hardening.sh"
grep -Fq 'Nenhuma alteração foi aplicada.' "$ROOT_DIR/modules/hardening.sh"
grep -Fq 'PermitRootLogin=yes' "$ROOT_DIR/modules/hardening.sh"
grep -Fq 'unattended-upgrades' "$ROOT_DIR/modules/hardening.sh"
grep -Fq 'AppArmor' "$ROOT_DIR/modules/hardening.sh"
grep -Fq 'PasswordAuthentication' "$ROOT_DIR/modules/hardening.sh"
if grep -Eq '^[[:space:]]*openssh_config_test([[:space:]]|$)' "$ROOT_DIR/modules/hardening.sh"; then
  echo '[ERRO] hardening audit-only não pode chamar helper que cria /run/sshd' >&2
  exit 1
fi
grep -Fq 'Missing privilege separation directory' "$ROOT_DIR/modules/hardening.sh"

echo "HARDENING TESTS: OK"
