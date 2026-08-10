#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/modules/mux.sh"

fail() { printf '[TESTE MUX][ERRO] %s\n' "$*" >&2; exit 1; }

mux_loopback_target_valid 127.0.0.1:22 || fail 'Loopback IPv4 rejeitado.'
mux_loopback_target_valid localhost:1194 || fail 'localhost rejeitado.'
! mux_loopback_target_valid 0.0.0.0:22 || fail '0.0.0.0 não pode ser backend.'
! mux_loopback_target_valid 192.168.1.10:22 || fail 'Backend remoto não pode ser aceito.'
! mux_loopback_target_valid 127.0.0.1:70000 || fail 'Porta inválida aceita.'
! grep -Fq -- '--transparent' "$ROOT_DIR/libexec/run-mux" || fail 'Modo transparente não pode ser usado.'
grep -Fq 'valid_loopback_target' "$ROOT_DIR/libexec/run-mux" || fail 'Validação loopback ausente.'

echo 'MUX TESTS: OK'
