#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d /tmp/oneplus-openvpn-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export ONEPLUS_OPENVPN_DIR="$TMP/openvpn"
export ONEPLUS_OPENVPN_CONF="$TMP/openvpn.env"
export ONEPLUS_OPENVPN_PAM="$TMP/oneplus-openvpn.pam"
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
valid_openvpn_auth_mode password || fail 'Modo password rejeitado.'
valid_openvpn_auth_mode hybrid || fail 'Modo hybrid rejeitado.'
! valid_openvpn_auth_mode mtls-only || fail 'Modo não suportado aceito.'
valid_openvpn_device_name android-1 || fail 'Dispositivo válido rejeitado.'
! valid_openvpn_device_name '../escape' || fail 'Dispositivo inseguro aceito.'

# Valida a migração de uma CA existente para banco OpenSSL + CRL sem substituir a CA.
install -d -m 0700 "$OPENVPN_PKI"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OPENVPN_CA_KEY" >/dev/null 2>&1
openssl req -x509 -new -sha256 -days 30 -key "$OPENVPN_CA_KEY" -subj '/CN=OnePlus Test CA' -out "$OPENVPN_CA_CERT" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OPENVPN_SERVER_KEY" >/dev/null 2>&1
openssl req -new -key "$OPENVPN_SERVER_KEY" -subj '/CN=oneplus-server' -out "$TMP/server.csr" >/dev/null 2>&1
cat > "$TMP/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -sha256 -days 30 -in "$TMP/server.csr" -CA "$OPENVPN_CA_CERT" -CAkey "$OPENVPN_CA_KEY" -CAcreateserial -extfile "$TMP/server.ext" -out "$OPENVPN_SERVER_CERT" >/dev/null 2>&1
printf 'test-only\n' > "$OPENVPN_TLS_CRYPT"
chmod 0600 "$OPENVPN_CA_KEY" "$OPENVPN_SERVER_KEY" "$OPENVPN_TLS_CRYPT"
openvpn_pki_valid || fail 'PKI de teste deveria ser válida.'
ensure_openvpn_ca_db || fail 'Inicialização do banco CA/CRL falhou.'
openvpn_ca_db_valid || fail 'Banco CA/CRL inválido após inicialização.'
[[ "$(stat -c %a "$OPENVPN_CA_DB")" == 711 ]] || fail 'Diretório da CRL deve permitir travessia sem expor listagem.'
[[ "$(stat -c %a "$OPENVPN_CRL")" == 644 ]] || fail 'CRL precisa ser legível após o daemon reduzir privilégios.'

# Assina e revoga um certificado cliente usando exatamente as extensões da v0.6.0.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/client.key" >/dev/null 2>&1
openssl req -new -key "$TMP/client.key" -subj '/CN=op-test-device' -out "$TMP/client.csr" >/dev/null 2>&1
openssl ca -batch -notext -config "$OPENVPN_CA_DB_CONF" -extensions client_cert -days 30 -in "$TMP/client.csr" -out "$TMP/client.crt" >/dev/null 2>&1
openssl verify -purpose sslclient -CAfile "$OPENVPN_CA_CERT" "$TMP/client.crt" >/dev/null 2>&1 || fail 'Certificado clientAuth inválido.'
SERIAL=$(openssl x509 -in "$TMP/client.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
install -m 0644 "$TMP/client.crt" "$(client_cert_file "$SERIAL")"
cat > "$(client_meta_file "$SERIAL")" <<META
FORMAT=1
USER=cliente1
DEVICE=android
CN=op-test-device
SERIAL=${SERIAL}
STATUS=valid
ISSUED_AT=1
NOT_AFTER=9999999999
REVOKE_AFTER=0
REPLACED_BY=
REVOKED_AT=0
META
chmod 0600 "$(client_meta_file "$SERIAL")"
revoke_openvpn_serial "$SERIAL" keyCompromise >/dev/null || fail 'Revogação gerenciada falhou.'
[[ "$(client_meta_get "$(client_meta_file "$SERIAL")" STATUS)" == revoked ]] || fail 'Metadado não marcou certificado como revogado.'
if openssl verify -crl_check -CRLfile "$OPENVPN_CRL" -CAfile "$OPENVPN_CA_CERT" "$TMP/client.crt" >/dev/null 2>&1; then
  fail 'Certificado revogado ainda foi aceito pela CRL.'
fi

# Segurança estática do runtime.
grep -Fq 'verify-client-cert none' "$ROOT_DIR/libexec/run-openvpn" || fail 'Modo password ausente.'
grep -Fq 'verify-client-cert require' "$ROOT_DIR/libexec/run-openvpn" || fail 'Modo hybrid não exige certificado.'
grep -Fq 'remote-cert-tls client' "$ROOT_DIR/libexec/run-openvpn" || fail 'EKU clientAuth não é exigido no servidor.'
grep -Fq 'crl-verify ${CRL}' "$ROOT_DIR/libexec/run-openvpn" || fail 'CRL não é aplicada no runtime.'
grep -Fq 'username-as-common-name' "$ROOT_DIR/libexec/run-openvpn" || fail 'username-as-common-name ausente.'
grep -Fq 'plugin ${plugin} oneplus-openvpn' "$ROOT_DIR/libexec/run-openvpn" || fail 'Plugin PAM ausente.'
! grep -Fq 'duplicate-cn' "$ROOT_DIR/libexec/run-openvpn" || fail 'duplicate-cn não deve ser usado.'
grep -Fq 'if [[ "$full_tunnel" == yes ]]' "$ROOT_DIR/libexec/run-openvpn" || fail 'Full-tunnel precisa ser condicional.'
! grep -Eq 'nft[[:space:]]|iptables|masquerade' "$ROOT_DIR/libexec/run-openvpn" || fail 'OpenVPN não deve manipular firewall diretamente.'
! grep -Fq 'cat "$OPENVPN_CA_KEY"' "$ROOT_DIR/modules/openvpn.sh" || fail 'Chave privada da CA não pode ser exportada.'
! grep -Eq 'client\.key[^\n]*(install|cp).*OPENVPN' "$ROOT_DIR/modules/openvpn.sh" || fail 'Chave privada de dispositivo não pode ser persistida no servidor.'
grep -Fq 'REVOKE_AFTER=' "$ROOT_DIR/modules/openvpn.sh" || fail 'Janela de migração de certificado ausente.'
grep -Fq 'OnUnitActiveSec=5min' "$ROOT_DIR/systemd/oneplus-openvpn-pki-maintenance.timer" || fail 'Timer de manutenção PKI ausente.'

echo 'OPENVPN MTLS TESTS: OK'
