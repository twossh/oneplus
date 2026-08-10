#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/modules/users.sh"
source "$ROOT_DIR/modules/openvpn.sh"

fail() { printf '[TESTE OPENVPN][ERRO] %s\n' "$*" >&2; exit 1; }

valid_private_24_network 10.8.0.0 || fail '10.8.0.0 deveria ser válida.'
valid_private_24_network 172.31.40.0 || fail '172.31.40.0 deveria ser válida.'
valid_private_24_network 192.168.99.0 || fail '192.168.99.0 deveria ser válida.'
! valid_private_24_network 8.8.8.0 || fail 'Rede pública não pode ser aceita.'
! valid_private_24_network 10.8.0.1 || fail 'A rede /24 precisa terminar em .0.'
valid_openvpn_public_host vpn.example.com || fail 'Domínio válido rejeitado.'
valid_openvpn_public_host 203.0.113.10 || fail 'IPv4 válido rejeitado.'
! valid_openvpn_public_host 'bad host' || fail 'Host inválido aceito.'

grep -Fq 'verify-client-cert none' "$ROOT_DIR/libexec/run-openvpn" || fail 'verify-client-cert none ausente.'
grep -Fq 'username-as-common-name' "$ROOT_DIR/libexec/run-openvpn" || fail 'username-as-common-name ausente.'
grep -Fq 'plugin ${plugin} oneplus-openvpn' "$ROOT_DIR/libexec/run-openvpn" || fail 'Plugin PAM ausente.'
! grep -Fq 'duplicate-cn' "$ROOT_DIR/libexec/run-openvpn" || fail 'duplicate-cn não deve ser usado.'
! grep -Fq 'redirect-gateway' "$ROOT_DIR/libexec/run-openvpn" || fail 'OpenVPN não deve ativar full-tunnel/NAT nesta fase.'
! grep -Fq 'cat "$OPENVPN_CA_KEY"' "$ROOT_DIR/modules/openvpn.sh" || fail 'Chave privada da CA não pode ser exportada.'

echo 'OPENVPN TESTS: OK'
