#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d /tmp/oneplus-openvpn-test.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
export ONEPLUS_OPENVPN_DIR="$TMP/openvpn"
export ONEPLUS_OPENVPN_CONF="$TMP/openvpn.env"
export ONEPLUS_OPENVPN_PAM="$TMP/oneplus-openvpn.pam"
export ONEPLUS_OPENVPN_ARCHIVE_ROOT="$TMP/archives"
export ONEPLUS_OPENVPN_AUTHZ_DIR="$TMP/authz"
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
valid_openvpn_tls_crypt_mode legacy || fail 'Modo tls-crypt legacy rejeitado.'
valid_openvpn_tls_crypt_mode dual || fail 'Modo tls-crypt dual rejeitado.'
valid_openvpn_tls_crypt_mode v2 || fail 'Modo tls-crypt v2 rejeitado.'
! valid_openvpn_tls_crypt_mode unsafe || fail 'Modo tls-crypt inválido aceito.'
valid_openvpn_device_name android-1 || fail 'Dispositivo válido rejeitado.'
! valid_openvpn_device_name '../escape' || fail 'Dispositivo inseguro aceito.'

cat > "$OPENVPN_CONF" <<'CONF'
OPENVPN_BIND=127.0.0.1
OPENVPN_PORT=1194
OPENVPN_PROTO=tcp
OPENVPN_PUBLIC_HOST=vpn.example.com
OPENVPN_PUBLIC_PORT=443
OPENVPN_NETWORK=10.8.0.0
OPENVPN_MAX_CLIENTS=128
OPENVPN_FULL_TUNNEL=no
OPENVPN_PUSH_DNS1=
OPENVPN_PUSH_DNS2=
OPENVPN_AUTH_MODE=hybrid
OPENVPN_TLS_CRYPT_MODE=legacy
CONF
chmod 0600 "$OPENVPN_CONF"

# CA atual e banco OpenSSL/CRL.
install -d -m 0700 "$OPENVPN_PKI"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OPENVPN_CA_KEY" >/dev/null 2>&1
openssl req -x509 -new -sha256 -days 30 -key "$OPENVPN_CA_KEY" -subj '/CN=OnePlus Test CA' -out "$OPENVPN_CA_CERT" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OPENVPN_SERVER_KEY" >/dev/null 2>&1
openssl req -new -key "$OPENVPN_SERVER_KEY" -subj '/CN=oneplus-server' -out "$TMP/server.csr" >/dev/null 2>&1
cat > "$TMP/server.ext" <<'EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:oneplus-server
EXT
openssl x509 -req -sha256 -days 30 -in "$TMP/server.csr" -CA "$OPENVPN_CA_CERT" -CAkey "$OPENVPN_CA_KEY" -set_serial 0x1001 -extfile "$TMP/server.ext" -out "$OPENVPN_SERVER_CERT" >/dev/null 2>&1
printf '%s\n' '-----BEGIN OpenVPN Static key V1-----' 'test-only' '-----END OpenVPN Static key V1-----' > "$OPENVPN_TLS_CRYPT"
chmod 0600 "$OPENVPN_CA_KEY" "$OPENVPN_SERVER_KEY" "$OPENVPN_TLS_CRYPT"
openvpn_pki_valid || fail 'PKI de teste deveria ser válida em modo legacy.'
ensure_openvpn_ca_db || fail 'Inicialização do banco CA/CRL falhou.'
openvpn_ca_db_valid || fail 'Banco CA/CRL inválido após inicialização.'
[[ "$(stat -c %a "$OPENVPN_CA_DB")" == 711 ]] || fail 'Diretório da CRL deve permitir travessia sem expor listagem.'
[[ "$(stat -c %a "$OPENVPN_CRL")" == 644 ]] || fail 'CRL precisa ser legível após o daemon reduzir privilégios.'

# Assina e revoga certificado cliente atual.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/client.key" >/dev/null 2>&1
openssl req -new -key "$TMP/client.key" -subj '/CN=op-test-device' -out "$TMP/client.csr" >/dev/null 2>&1
openssl ca -batch -notext -config "$OPENVPN_CA_DB_CONF" -extensions client_cert -days 30 -in "$TMP/client.csr" -out "$TMP/client.crt" >/dev/null 2>&1
openssl verify -purpose sslclient -CAfile "$OPENVPN_CA_CERT" "$TMP/client.crt" >/dev/null 2>&1 || fail 'Certificado clientAuth inválido.'
SERIAL=$(openssl x509 -in "$TMP/client.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
install -m 0644 "$TMP/client.crt" "$(client_cert_file "$SERIAL")"
cat > "$(client_meta_file "$SERIAL")" <<META
FORMAT=2
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
CONTROL_KEY=legacy
META
chmod 0600 "$(client_meta_file "$SERIAL")"
rebuild_openvpn_authz || fail 'Falha ao gerar mapa certificado/usuário.'
AUTHZ_FILE="$OPENVPN_AUTHZ_DIR/${SERIAL}.user"
[[ -r "$AUTHZ_FILE" && "$(cat "$AUTHZ_FILE")" == cliente1 ]] || fail 'Mapa certificado/usuário não foi criado.'
[[ "$(stat -c %a "$OPENVPN_AUTHZ_DIR")" == 711 ]] || fail 'Diretório authz deve ser atravessável, mas não listável por usuários comuns.'
printf 'cliente1\nsenha-ignorada-pelo-binding\n' > "$TMP/credentials"
SERIAL_COLON=$(sed 's/../&:/g;s/:$//' <<< "$SERIAL")
ONEPLUS_TEST_AUTHZ_DIR="$OPENVPN_AUTHZ_DIR" script_type=auth-user-pass-verify tls_serial_hex_0="$SERIAL_COLON" \
  python3 "$ROOT_DIR/libexec/openvpn_bind_identity.py" "$TMP/credentials" || fail 'Binding certificado/usuário válido foi recusado.'
printf 'cliente2\nsenha-ignorada\n' > "$TMP/credentials-bad"
if ONEPLUS_TEST_AUTHZ_DIR="$OPENVPN_AUTHZ_DIR" script_type=auth-user-pass-verify tls_serial_hex_0="$SERIAL_COLON" \
  python3 "$ROOT_DIR/libexec/openvpn_bind_identity.py" "$TMP/credentials-bad"; then
  fail 'Binding aceitou certificado de cliente1 junto com usuário cliente2.'
fi
revoke_openvpn_serial "$SERIAL" keyCompromise >/dev/null || fail 'Revogação gerenciada falhou.'
[[ ! -e "$AUTHZ_FILE" ]] || fail 'Certificado revogado permaneceu autorizado no mapa de identidade.'
[[ "$(client_meta_get "$(client_meta_file "$SERIAL")" STATUS)" == revoked ]] || fail 'Metadado não marcou certificado como revogado.'
if openssl verify -crl_check -CRLfile "$OPENVPN_CRL" -CAfile "$OPENVPN_CA_CERT" "$TMP/client.crt" >/dev/null 2>&1; then
  fail 'Certificado revogado ainda foi aceito pela CRL.'
fi

# Prepara manualmente uma segunda CA para validar bundles de migração sem depender do binário OpenVPN no CI.
install -d -m 0711 "$OPENVPN_ROTATION_DIR"
install -d -m 0700 "$OPENVPN_ROTATION_NEXT" "$OPENVPN_NEXT_PKI" "$OPENVPN_NEXT_CLIENTS"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OPENVPN_NEXT_CA_KEY" >/dev/null 2>&1
openssl req -x509 -new -sha256 -days 30 -key "$OPENVPN_NEXT_CA_KEY" -subj '/CN=OnePlus Next Test CA' -out "$OPENVPN_NEXT_CA_CERT" >/dev/null 2>&1
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$OPENVPN_NEXT_SERVER_KEY" >/dev/null 2>&1
openssl req -new -key "$OPENVPN_NEXT_SERVER_KEY" -subj '/CN=oneplus-server' -out "$TMP/next-server.csr" >/dev/null 2>&1
openssl x509 -req -sha256 -days 30 -in "$TMP/next-server.csr" -CA "$OPENVPN_NEXT_CA_CERT" -CAkey "$OPENVPN_NEXT_CA_KEY" -set_serial 0x2001 -extfile "$TMP/server.ext" -out "$OPENVPN_NEXT_SERVER_CERT" >/dev/null 2>&1
printf '%s\n' '-----BEGIN OpenVPN tls-crypt-v2 server key-----' 'test-only' '-----END OpenVPN tls-crypt-v2 server key-----' > "$OPENVPN_NEXT_TLS_CRYPT_V2"
chmod 0600 "$OPENVPN_NEXT_CA_KEY" "$OPENVPN_NEXT_SERVER_KEY" "$OPENVPN_NEXT_TLS_CRYPT_V2"
cat > "$OPENVPN_ROTATION_STATE" <<STATE
FORMAT=1
STATE=prepared
ROTATION_ID=20260810T220000Z
CREATED_AT=1
LEGACY_CA_SHA256=AA
NEXT_CA_SHA256=BB
STATE
chmod 0600 "$OPENVPN_ROTATION_STATE"
write_next_ca_config
: > "$OPENVPN_NEXT_CA_DB/index.txt"
printf '2000\n' > "$OPENVPN_NEXT_CA_DB/serial"
printf '1000\n' > "$OPENVPN_NEXT_CA_DB/crlnumber"
chmod 0600 "$OPENVPN_NEXT_CA_DB/index.txt" "$OPENVPN_NEXT_CA_DB/serial" "$OPENVPN_NEXT_CA_DB/crlnumber"
generate_next_crl || fail 'Falha ao gerar CRL da próxima CA.'
next_pki_valid || fail 'Próxima PKI deveria ser válida.'
next_ca_db_valid || fail 'Próximo banco CA deveria ser válido.'
build_rotation_bundles || fail 'Falha ao montar bundles de duas CAs/CRLs.'
[[ "$(grep -c 'BEGIN CERTIFICATE' "$OPENVPN_ROTATION_CA_BUNDLE")" -eq 2 ]] || fail 'Bundle deve conter duas CAs.'
[[ "$(grep -c 'BEGIN X509 CRL' "$OPENVPN_ROTATION_CRL_BUNDLE")" -eq 2 ]] || fail 'Bundle deve conter duas CRLs.'
openssl verify -CAfile "$OPENVPN_ROTATION_CA_BUNDLE" "$OPENVPN_SERVER_CERT" "$OPENVPN_NEXT_SERVER_CERT" >/dev/null 2>&1 || fail 'Bundle não confia nas duas gerações de servidor.'

# Revogação da próxima geração deve atualizar CRL/bundle e retirar autorização de identidade.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/next-client.key" >/dev/null 2>&1
openssl req -new -key "$TMP/next-client.key" -subj '/CN=op-next-device' -out "$TMP/next-client.csr" >/dev/null 2>&1
openssl ca -batch -notext -config "$OPENVPN_NEXT_CA_DB_CONF" -extensions client_cert -days 30 -in "$TMP/next-client.csr" -out "$TMP/next-client.crt" >/dev/null 2>&1
NEXT_SERIAL=$(openssl x509 -in "$TMP/next-client.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
install -m 0644 "$TMP/next-client.crt" "$(next_client_cert_file "$NEXT_SERIAL")"
cat > "$(next_client_meta_file "$NEXT_SERIAL")" <<META
FORMAT=2
USER=cliente1
DEVICE=tablet
CN=op-next-device
SERIAL=${NEXT_SERIAL}
STATUS=valid
ISSUED_AT=1
NOT_AFTER=9999999999
REVOKE_AFTER=0
REPLACED_BY=
REVOKED_AT=0
CONTROL_KEY=v2
GENERATION=next
META
chmod 0600 "$(next_client_meta_file "$NEXT_SERIAL")"
rebuild_openvpn_authz || fail 'Falha ao autorizar certificado da próxima geração.'
[[ -r "$OPENVPN_AUTHZ_DIR/${NEXT_SERIAL}.user" ]] || fail 'Certificado next não entrou no mapa de identidade.'
revoke_next_openvpn_serial "$NEXT_SERIAL" keyCompromise >/dev/null || fail 'Revogação next falhou.'
[[ "$(client_meta_get "$(next_client_meta_file "$NEXT_SERIAL")" STATUS)" == revoked ]] || fail 'Metadado next não marcou revogação.'
[[ ! -e "$OPENVPN_AUTHZ_DIR/${NEXT_SERIAL}.user" ]] || fail 'Certificado next revogado permaneceu autorizado.'
if openssl verify -crl_check -CRLfile "$OPENVPN_NEXT_CRL" -CAfile "$OPENVPN_NEXT_CA_CERT" "$TMP/next-client.crt" >/dev/null 2>&1; then
  fail 'Certificado next revogado ainda foi aceito pela CRL.'
fi

# Perfil v2 usa CA bundle e nunca inclui tls-crypt legado.
printf '%s\n' '-----BEGIN OpenVPN tls-crypt-v2 client key-----' 'client-test' '-----END OpenVPN tls-crypt-v2 client key-----' > "$TMP/client-v2.key"
write_hybrid_profile_v2 "$TMP/v2.ovpn" vpn.example.com 443 tcp "$TMP/client.crt" "$TMP/client.key" "$OPENVPN_ROTATION_CA_BUNDLE" "$TMP/client-v2.key" || fail 'Falha ao escrever perfil v2.'
grep -Fq '<tls-crypt-v2>' "$TMP/v2.ovpn" || fail 'Perfil v2 sem bloco tls-crypt-v2.'
! grep -Fq '<tls-crypt>' "$TMP/v2.ovpn" || fail 'Perfil v2 não pode carregar tls-crypt legado.'
[[ "$(grep -c 'BEGIN CERTIFICATE' "$TMP/v2.ovpn")" -ge 3 ]] || fail 'Perfil de migração deve embutir bundle de CA + certificado cliente.'

# Controle de progresso usa certificados/metadados reais das duas gerações.
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/current2.key" >/dev/null 2>&1
openssl req -new -key "$TMP/current2.key" -subj '/CN=op-current-notebook' -out "$TMP/current2.csr" >/dev/null 2>&1
openssl ca -batch -notext -config "$OPENVPN_CA_DB_CONF" -extensions client_cert -days 30 -in "$TMP/current2.csr" -out "$TMP/current2.crt" >/dev/null 2>&1
CUR2=$(openssl x509 -in "$TMP/current2.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
install -m 0644 "$TMP/current2.crt" "$(client_cert_file "$CUR2")"
cat > "$(client_meta_file "$CUR2")" <<META
FORMAT=2
USER=cliente2
DEVICE=notebook
CN=op-current-notebook
SERIAL=${CUR2}
STATUS=valid
ISSUED_AT=1
NOT_AFTER=9999999999
REVOKE_AFTER=0
REPLACED_BY=
REVOKED_AT=0
CONTROL_KEY=legacy
META
chmod 0600 "$(client_meta_file "$CUR2")"
[[ "$(rotation_missing_devices)" == 1 ]] || fail 'Deveria haver um dispositivo sem perfil novo.'

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TMP/next2.key" >/dev/null 2>&1
openssl req -new -key "$TMP/next2.key" -subj '/CN=op-next-notebook' -out "$TMP/next2.csr" >/dev/null 2>&1
openssl ca -batch -notext -config "$OPENVPN_NEXT_CA_DB_CONF" -extensions client_cert -days 30 -in "$TMP/next2.csr" -out "$TMP/next2.crt" >/dev/null 2>&1
NEXT2=$(openssl x509 -in "$TMP/next2.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
install -m 0644 "$TMP/next2.crt" "$(next_client_cert_file "$NEXT2")"
cat > "$(next_client_meta_file "$NEXT2")" <<META
FORMAT=2
USER=cliente2
DEVICE=notebook
CN=op-next-notebook
SERIAL=${NEXT2}
STATUS=valid
ISSUED_AT=1
NOT_AFTER=9999999999
REVOKE_AFTER=0
REPLACED_BY=
REVOKED_AT=0
CONTROL_KEY=v2
GENERATION=next
META
chmod 0600 "$(next_client_meta_file "$NEXT2")"
rebuild_openvpn_authz || fail 'Falha ao reconstruir authz com as duas gerações.'
[[ "$(rotation_missing_devices)" == 0 ]] || fail 'Dispositivo com perfil emitido deveria sair da lista pendente.'
[[ -r "$OPENVPN_AUTHZ_DIR/${CUR2}.user" && -r "$OPENVPN_AUTHZ_DIR/${NEXT2}.user" ]] || fail 'Authz deve aceitar as duas gerações durante a fase dual.'

# Primeiro força uma falha pós-promoção e confirma o rollback; depois promove com sucesso.
OLD_CA_FP=$(openssl x509 -in "$OPENVPN_CA_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
NEXT_CA_FP=$(openssl x509 -in "$OPENVPN_NEXT_CA_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
set_openvpn_value OPENVPN_TLS_CRYPT_MODE dual || fail 'Falha ao colocar teste em modo dual.'
eval "$(declare -f openvpn_pki_valid | sed '1s/openvpn_pki_valid/openvpn_pki_valid_real/')"
openvpn_pki_valid() { [[ "${ONEPLUS_TEST_FORCE_PKI_FAIL:-0}" != 1 ]] && openvpn_pki_valid_real; }
export ONEPLUS_TEST_FORCE_PKI_FAIL=1
if TERM=xterm finalize_infrastructure_rotation <<< 'FINALIZAR' >/dev/null 2>&1; then
  fail 'Finalização deveria falhar quando a validação pós-promoção é forçada a falhar.'
fi
unset ONEPLUS_TEST_FORCE_PKI_FAIL
[[ "$(openssl x509 -in "$OPENVPN_CA_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')" == "$OLD_CA_FP" ]] || fail 'Rollback não restaurou a CA anterior.'
[[ -s "$OPENVPN_TLS_CRYPT" && -d "$OPENVPN_ROTATION_DIR" ]] || fail 'Rollback deve restaurar tls-crypt legado e manter preparação para nova tentativa.'
eval "$(declare -f openvpn_pki_valid_real | sed '1s/openvpn_pki_valid_real/openvpn_pki_valid/')"
unset -f openvpn_pki_valid_real
TERM=xterm finalize_infrastructure_rotation <<< 'FINALIZAR' >/dev/null || fail 'Finalização da infraestrutura falhou no teste isolado.'
[[ "$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE)" == v2 ]] || fail 'Promoção deveria mudar controle para v2.'
[[ ! -d "$OPENVPN_ROTATION_DIR" ]] || fail 'Área de rotação deveria ser removida após promoção.'
[[ -s "$OPENVPN_TLS_CRYPT_V2" && ! -e "$OPENVPN_TLS_CRYPT" ]] || fail 'Promoção não trocou tls-crypt legado por v2.'
[[ "$(openssl x509 -in "$OPENVPN_CA_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')" == "$NEXT_CA_FP" ]] || fail 'CA ativa não corresponde à próxima geração após promoção.'
find "$OPENVPN_ARCHIVE_ROOT" -type f -name pre-finalize.tar.gz -print -quit | grep -q . || fail 'Rollback pré-finalização não foi criado.'
[[ -r "$OPENVPN_AUTHZ_DIR/${NEXT2}.user" && ! -e "$OPENVPN_AUTHZ_DIR/${CUR2}.user" ]] || fail 'Authz pós-promoção deve manter apenas certificados da nova geração.'
openvpn_pki_valid || fail 'PKI promovida deveria estar válida em modo v2.'

# Segurança estática do runtime e da rotação.
grep -Fq 'verify-client-cert none' "$ROOT_DIR/libexec/run-openvpn" || fail 'Modo password ausente.'
grep -Fq 'verify-client-cert require' "$ROOT_DIR/libexec/run-openvpn" || fail 'Modo hybrid não exige certificado.'
grep -Fq 'remote-cert-tls client' "$ROOT_DIR/libexec/run-openvpn" || fail 'EKU clientAuth não é exigido no servidor.'
grep -Fq 'crl-verify ${CRL_EFFECTIVE}' "$ROOT_DIR/libexec/run-openvpn" || fail 'CRL efetiva não é aplicada no runtime.'
grep -Fq 'tls-crypt-v2 %s' "$ROOT_DIR/libexec/run-openvpn" || fail 'Runtime não suporta tls-crypt-v2.'
grep -Fq 'tls-crypt %s' "$ROOT_DIR/libexec/run-openvpn" || fail 'Modo dual não preserva tls-crypt legado durante a migração.'
grep -Fq 'username-as-common-name' "$ROOT_DIR/libexec/run-openvpn" || fail 'username-as-common-name ausente.'
grep -Fq 'plugin ${plugin} oneplus-openvpn' "$ROOT_DIR/libexec/run-openvpn" || fail 'Plugin PAM ausente.'
grep -Fq 'auth-user-pass-verify /opt/oneplus/libexec/openvpn_bind_identity.py via-file' "$ROOT_DIR/libexec/run-openvpn" || fail 'Binding certificado/usuário não está no runtime híbrido.'
! grep -Fq 'via-env' "$ROOT_DIR/libexec/run-openvpn" || fail 'Senha não deve ser exposta via ambiente no binding.'
! grep -Fq 'duplicate-cn' "$ROOT_DIR/libexec/run-openvpn" || fail 'duplicate-cn não deve ser usado.'
grep -Fq 'if [[ "$full_tunnel" == yes ]]' "$ROOT_DIR/libexec/run-openvpn" || fail 'Full-tunnel precisa ser condicional.'
! grep -Eq 'nft[[:space:]]|iptables|masquerade' "$ROOT_DIR/libexec/run-openvpn" || fail 'OpenVPN não deve manipular firewall diretamente.'
! grep -Fq 'cat "$OPENVPN_CA_KEY"' "$ROOT_DIR/modules/openvpn.sh" || fail 'Chave privada da CA não pode ser exportada.'
! grep -Eq 'client\.key[^[:cntrl:]]*(install|cp)[^[:cntrl:]]*OPENVPN' "$ROOT_DIR/modules/openvpn.sh" || fail 'Chave privada de dispositivo não pode ser persistida no servidor.'
grep -Fq 'REVOKE_AFTER=' "$ROOT_DIR/modules/openvpn.sh" || fail 'Janela de migração de certificado ausente.'
grep -Fq 'FINALIZAR-FORCAR' "$ROOT_DIR/modules/openvpn.sh" || fail 'Finalização da CA precisa de confirmação reforçada quando há perfis pendentes.'
! grep -Fq 'finalize_infrastructure_rotation' "$ROOT_DIR/libexec/run-openvpn-pki-maintenance" || fail 'Timer não deve promover CA automaticamente.'
grep -Fq 'OnUnitActiveSec=5min' "$ROOT_DIR/systemd/oneplus-openvpn-pki-maintenance.timer" || fail 'Timer de manutenção PKI ausente.'

echo 'OPENVPN MTLS/ROTATION TESTS: OK'
