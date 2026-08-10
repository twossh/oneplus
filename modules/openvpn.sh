#!/usr/bin/env bash
set -Eeuo pipefail

OPENVPN_CONF="${ONEPLUS_OPENVPN_CONF:-/etc/oneplus/openvpn.env}"
OPENVPN_DIR="${ONEPLUS_OPENVPN_DIR:-/etc/oneplus/openvpn}"
OPENVPN_PKI="$OPENVPN_DIR/pki"
OPENVPN_CA_KEY="$OPENVPN_PKI/ca.key"
OPENVPN_CA_CERT="$OPENVPN_PKI/ca.crt"
OPENVPN_SERVER_KEY="$OPENVPN_PKI/server.key"
OPENVPN_SERVER_CERT="$OPENVPN_PKI/server.crt"
OPENVPN_TLS_CRYPT="$OPENVPN_DIR/tls-crypt.key"
OPENVPN_CA_DB="$OPENVPN_DIR/ca-db"
OPENVPN_CA_DB_CONF="$OPENVPN_CA_DB/openssl.cnf"
OPENVPN_CRL="$OPENVPN_CA_DB/crl.pem"
OPENVPN_CLIENTS_DIR="$OPENVPN_DIR/clients"
OPENVPN_PAM="${ONEPLUS_OPENVPN_PAM:-/etc/pam.d/oneplus-openvpn}"
OPENVPN_SERVICE="oneplus-openvpn.service"
OPENVPN_MGMT="/run/oneplus-openvpn/management.sock"

read_openvpn_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$OPENVPN_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

valid_openvpn_auth_mode() { [[ "$1" == password || "$1" == hybrid ]]; }
valid_openvpn_device_name() { [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]]; }
valid_openvpn_serial() { [[ "$1" =~ ^[A-Fa-f0-9]{1,64}$ ]]; }

valid_openvpn_public_host() {
  [[ -z "$1" ]] && return 0
  is_valid_ipv4 "$1" || is_valid_domain "$1"
}

valid_private_24_network() {
  local ip="$1" a b c d
  is_valid_ipv4 "$ip" || return 1
  IFS=. read -r a b c d <<< "$ip"
  (( 10#$d == 0 )) || return 1
  if (( 10#$a == 10 )); then return 0; fi
  if (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )); then return 0; fi
  if (( 10#$a == 192 && 10#$b == 168 )); then return 0; fi
  return 1
}

ensure_openvpn_packages() {
  if command -v openvpn >/dev/null 2>&1 && find /usr/lib -type f -name 'openvpn-plugin-auth-pam.so' -print -quit 2>/dev/null | grep -q .; then
    return 0
  fi
  info "Instalando OpenVPN do repositório oficial do Ubuntu..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends openvpn libpam-modules openssl
}

ensure_openvpn_pam() {
  ensure_users_group
  local tmp
  tmp=$(mktemp /tmp/oneplus-openvpn-pam.XXXXXX)
  cat > "$tmp" <<'EOF2'
# Managed by OnePlus. Root is denied and only oneplus-users may authenticate.
auth requisite pam_succeed_if.so quiet user != root
auth requisite pam_succeed_if.so quiet user ingroup oneplus-users
@include common-auth
account requisite pam_succeed_if.so quiet user != root
account requisite pam_succeed_if.so quiet user ingroup oneplus-users
@include common-account
EOF2
  install -m 0644 -o root -g root "$tmp" "$OPENVPN_PAM"
  rm -f "$tmp"
}

openvpn_pki_valid() {
  [[ -s "$OPENVPN_CA_KEY" && -s "$OPENVPN_CA_CERT" && -s "$OPENVPN_SERVER_KEY" && -s "$OPENVPN_SERVER_CERT" && -s "$OPENVPN_TLS_CRYPT" ]] || return 1
  openssl x509 -in "$OPENVPN_CA_CERT" -noout >/dev/null 2>&1 || return 1
  openssl x509 -in "$OPENVPN_SERVER_CERT" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$OPENVPN_CA_KEY" -passin pass: -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$OPENVPN_SERVER_KEY" -passin pass: -noout >/dev/null 2>&1 || return 1
  openssl verify -CAfile "$OPENVPN_CA_CERT" "$OPENVPN_SERVER_CERT" >/dev/null 2>&1 || return 1
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$OPENVPN_SERVER_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$OPENVPN_SERVER_KEY" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

generate_openvpn_pki() {
  ensure_openvpn_packages
  if openvpn_pki_valid; then
    ok "PKI OpenVPN já existe e está válida."
    return 0
  fi
  if find "$OPENVPN_DIR" -mindepth 1 -maxdepth 2 -type f \( -name '*.key' -o -name '*.crt' \) 2>/dev/null | grep -q .; then
    error "Há uma PKI OpenVPN parcial/inválida em ${OPENVPN_DIR}. O OnePlus não a sobrescreverá automaticamente."
    return 1
  fi

  local tmp ext
  tmp=$(mktemp -d /tmp/oneplus-openvpn-pki.XXXXXX)
  ext="$tmp/server.ext"
  umask 077
  info "Gerando CA interna e certificado do servidor OpenVPN..."
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/ca.key" >/dev/null 2>&1
  openssl req -x509 -new -sha256 -days 3650 -key "$tmp/ca.key" \
    -subj '/CN=OnePlus OpenVPN CA' -out "$tmp/ca.crt" >/dev/null 2>&1
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/server.key" >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/server.key" -subj '/CN=oneplus-server' -out "$tmp/server.csr" >/dev/null 2>&1
  cat > "$ext" <<'EOF2'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:oneplus-server
EOF2
  openssl x509 -req -sha256 -days 825 -in "$tmp/server.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" \
    -CAcreateserial -extfile "$ext" -out "$tmp/server.crt" >/dev/null 2>&1
  openvpn --genkey tls-crypt "$tmp/tls-crypt.key" >/dev/null 2>&1

  install -d -m 0700 -o root -g root "$OPENVPN_PKI"
  install -m 0600 -o root -g root "$tmp/ca.key" "$OPENVPN_CA_KEY"
  install -m 0644 -o root -g root "$tmp/ca.crt" "$OPENVPN_CA_CERT"
  install -m 0600 -o root -g root "$tmp/server.key" "$OPENVPN_SERVER_KEY"
  install -m 0644 -o root -g root "$tmp/server.crt" "$OPENVPN_SERVER_CERT"
  install -m 0600 -o root -g root "$tmp/tls-crypt.key" "$OPENVPN_TLS_CRYPT"
  rm -rf "$tmp"

  openvpn_pki_valid || { error "A PKI gerada falhou na validação."; return 1; }
  ok "PKI OpenVPN criada localmente. A chave privada da CA nunca é exportada para clientes."
}

write_openvpn_ca_config() {
  install -d -m 0711 -o root -g root "$OPENVPN_CA_DB"
  install -d -m 0700 -o root -g root "$OPENVPN_CA_DB/newcerts" "$OPENVPN_CLIENTS_DIR"
  local tmp
  tmp=$(mktemp /tmp/oneplus-openssl-ca.XXXXXX)
  cat > "$tmp" <<EOF2
[ ca ]
default_ca = oneplus_ca

[ oneplus_ca ]
dir = ${OPENVPN_CA_DB}
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
certificate = ${OPENVPN_CA_CERT}
private_key = ${OPENVPN_CA_KEY}
serial = \$dir/serial
crlnumber = \$dir/crlnumber
default_md = sha256
default_days = 825
default_crl_days = 30
policy = oneplus_policy
unique_subject = no
copy_extensions = none

[ oneplus_policy ]
commonName = supplied

[ client_cert ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF2
  install -m 0600 -o root -g root "$tmp" "$OPENVPN_CA_DB_CONF"
  rm -f "$tmp"
}

generate_openvpn_crl() {
  [[ -r "$OPENVPN_CA_DB_CONF" ]] || write_openvpn_ca_config
  local tmp
  install -d -m 0711 -o root -g root "$OPENVPN_CA_DB"
  tmp=$(mktemp "$OPENVPN_CA_DB/.crl.XXXXXX")
  if ! openssl ca -batch -config "$OPENVPN_CA_DB_CONF" -gencrl -out "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "Falha ao gerar CRL OpenVPN."
    return 1
  fi
  openssl crl -in "$tmp" -noout -verify -CAfile "$OPENVPN_CA_CERT" >/dev/null 2>&1 || { rm -f "$tmp"; error "CRL gerada não passou na validação."; return 1; }
  # O OpenVPN relê a CRL em novas conexões após reduzir privilégios.
  # A troca por rename no mesmo filesystem evita que o daemon observe um arquivo parcial.
  chown root:root "$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$OPENVPN_CRL"
}

ensure_openvpn_ca_db() {
  openvpn_pki_valid || { error "PKI OpenVPN ausente ou inválida."; return 1; }
  write_openvpn_ca_config
  [[ -e "$OPENVPN_CA_DB/index.txt" ]] || install -m 0600 -o root -g root /dev/null "$OPENVPN_CA_DB/index.txt"
  if [[ ! -s "$OPENVPN_CA_DB/serial" ]]; then
    openssl rand -hex 16 | tr '[:lower:]' '[:upper:]' > "$OPENVPN_CA_DB/serial"
    chmod 0600 "$OPENVPN_CA_DB/serial"
  fi
  if [[ ! -s "$OPENVPN_CA_DB/crlnumber" ]]; then
    printf '1000\n' > "$OPENVPN_CA_DB/crlnumber"
    chmod 0600 "$OPENVPN_CA_DB/crlnumber"
  fi
  [[ -s "$OPENVPN_CRL" ]] || generate_openvpn_crl
  openssl crl -in "$OPENVPN_CRL" -noout -verify -CAfile "$OPENVPN_CA_CERT" >/dev/null 2>&1
}

openvpn_ca_db_valid() {
  [[ -r "$OPENVPN_CA_DB_CONF" && -r "$OPENVPN_CA_DB/index.txt" && -s "$OPENVPN_CA_DB/serial" && -s "$OPENVPN_CRL" ]] || return 1
  openssl crl -in "$OPENVPN_CRL" -noout -verify -CAfile "$OPENVPN_CA_CERT" >/dev/null 2>&1
}

client_meta_file() { printf '%s/%s.conf' "$OPENVPN_CLIENTS_DIR" "${1^^}"; }
client_cert_file() { printf '%s/%s.crt' "$OPENVPN_CLIENTS_DIR" "${1^^}"; }
client_meta_get() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$1" 2>/dev/null || true; }
client_meta_set() {
  local file="$1" key="$2" value="$3" tmp
  [[ -f "$file" && "$key" =~ ^[A-Z0-9_]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  awk -F= -v k="$key" -v v="$value" 'BEGIN{d=0} $1==k{print k"="v;d=1;next}{print} END{if(!d)print k"="v}' "$file" > "$tmp"
  install -m 0600 -o root -g root "$tmp" "$file"
  rm -f "$tmp"
}

active_device_exists() {
  local user="$1" device="$2" f
  shopt -s nullglob
  for f in "$OPENVPN_CLIENTS_DIR"/*.conf; do
    [[ "$(client_meta_get "$f" USER)" == "$user" && "$(client_meta_get "$f" DEVICE)" == "$device" && "$(client_meta_get "$f" STATUS)" == valid ]] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

write_hybrid_profile() {
  local output="$1" host="$2" port="$3" proto="$4" cert="$5" key="$6" ovpn_proto
  [[ "$proto" == tcp ]] && ovpn_proto=tcp4-client || ovpn_proto=udp4
  umask 077
  {
    cat <<EOF2
client
dev tun
proto ${ovpn_proto}
remote ${host} ${port}
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name oneplus-server name
auth-user-pass
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:?CHACHA20-POLY1305
auth SHA256
allow-compression no
verb 3
<ca>
EOF2
    cat "$OPENVPN_CA_CERT"
    printf '</ca>\n<cert>\n'
    cat "$cert"
    printf '</cert>\n<key>\n'
    cat "$key"
    printf '</key>\n<tls-crypt>\n'
    cat "$OPENVPN_TLS_CRYPT"
    printf '</tls-crypt>\n'
  } > "$output"
  chown root:root "$output"
  chmod 0600 "$output"
}

issue_openvpn_device_profile() {
  local user="$1" device="$2" output="$3" allow_duplicate="${4:-0}"
  require_managed_user "$user" || return 1
  valid_openvpn_device_name "$device" || { error "Nome de dispositivo inválido (1..32; letras, números, ponto, hífen e sublinhado)."; return 1; }
  [[ "$(read_openvpn_value OPENVPN_AUTH_MODE)" == hybrid ]] || { error "Ative o modo usuário/senha + mTLS antes de emitir certificados de dispositivo."; return 1; }
  [[ "$output" == /* && ! -e "$output" ]] || { error "Use um caminho absoluto ainda inexistente para o perfil."; return 1; }
  ensure_openvpn_ca_db || return 1
  if [[ "$allow_duplicate" != 1 ]] && active_device_exists "$user" "$device"; then
    error "Já existe um certificado ativo para ${user}/${device}. Use a opção de rotação para substituí-lo com janela de migração."
    return 1
  fi

  local tmp cn serial certfile metafile host port proto now not_after
  tmp=$(mktemp -d /tmp/oneplus-openvpn-client.XXXXXX)
  cn="op-$(openssl rand -hex 10)"
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/client.key" >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/client.key" -subj "/CN=${cn}" -out "$tmp/client.csr" >/dev/null 2>&1
  if ! openssl ca -batch -notext -config "$OPENVPN_CA_DB_CONF" -extensions client_cert -days 825 -in "$tmp/client.csr" -out "$tmp/client.crt" >/dev/null 2>&1; then
    rm -rf "$tmp"; error "Falha ao assinar certificado do dispositivo."; return 1
  fi
  openssl verify -purpose sslclient -CAfile "$OPENVPN_CA_CERT" "$tmp/client.crt" >/dev/null 2>&1 || { rm -rf "$tmp"; error "Certificado cliente não passou na validação."; return 1; }
  serial=$(openssl x509 -in "$tmp/client.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
  valid_openvpn_serial "$serial" || { rm -rf "$tmp"; error "Serial X.509 inesperado."; return 1; }
  certfile=$(client_cert_file "$serial")
  metafile=$(client_meta_file "$serial")
  [[ ! -e "$certfile" && ! -e "$metafile" ]] || { rm -rf "$tmp"; error "Colisão inesperada de serial."; return 1; }

  host=$(read_openvpn_value OPENVPN_PUBLIC_HOST); [[ -n "$host" ]] || host=$(primary_ipv4)
  port=$(read_openvpn_value OPENVPN_PUBLIC_PORT)
  proto=$(read_openvpn_value OPENVPN_PROTO)
  valid_openvpn_public_host "$host" && [[ -n "$host" ]] || { rm -rf "$tmp"; error "Host público inválido."; return 1; }
  is_valid_port "$port" || { rm -rf "$tmp"; error "Porta pública inválida."; return 1; }
  [[ "$proto" == tcp || "$proto" == udp ]] || { rm -rf "$tmp"; error "Protocolo inválido."; return 1; }

  install -d -m 0700 -o root -g root "$OPENVPN_CLIENTS_DIR"
  install -m 0644 -o root -g root "$tmp/client.crt" "$certfile"
  now=$(date +%s)
  not_after=$(LC_ALL=C date -d "$(LC_ALL=C openssl x509 -in "$tmp/client.crt" -noout -enddate | cut -d= -f2-)" +%s 2>/dev/null || echo 0)
  cat > "$tmp/meta" <<EOF2
FORMAT=1
USER=${user}
DEVICE=${device}
CN=${cn}
SERIAL=${serial}
STATUS=valid
ISSUED_AT=${now}
NOT_AFTER=${not_after}
REVOKE_AFTER=0
REPLACED_BY=
REVOKED_AT=0
EOF2
  install -m 0600 -o root -g root "$tmp/meta" "$metafile"
  if ! write_hybrid_profile "$output" "$host" "$port" "$proto" "$tmp/client.crt" "$tmp/client.key"; then
    openssl ca -batch -config "$OPENVPN_CA_DB_CONF" -revoke "$certfile" -crl_reason cessationOfOperation >/dev/null 2>&1 || true
    generate_openvpn_crl >/dev/null 2>&1 || true
    client_meta_set "$metafile" STATUS revoked || true
    client_meta_set "$metafile" REVOKED_AT "$(date +%s)" || true
    rm -rf "$tmp"
    error "Falha ao gravar perfil; o certificado emitido foi marcado para revogação."
    return 1
  fi
  rm -rf "$tmp"
  ONEPLUS_LAST_ISSUED_SERIAL="$serial"
  ok "Perfil mTLS criado: $output"
  info "Dispositivo: ${user}/${device} | serial: ${serial}"
  warn "A chave privada do dispositivo existe somente dentro deste perfil e não é armazenada no servidor. Proteja o arquivo 0600 e transfira-o por canal seguro."
}

export_password_profile() {
  openvpn_pki_valid || { error "PKI OpenVPN ausente ou inválida."; return 1; }
  [[ -r "$OPENVPN_CONF" ]] || { error "Configure o OpenVPN primeiro."; return 1; }
  local host port proto output ovpn_proto
  host=$(read_openvpn_value OPENVPN_PUBLIC_HOST); port=$(read_openvpn_value OPENVPN_PUBLIC_PORT); proto=$(read_openvpn_value OPENVPN_PROTO)
  [[ -n "$host" ]] || host=$(primary_ipv4)
  valid_openvpn_public_host "$host" && [[ -n "$host" ]] || { error "Host público inválido na configuração."; return 1; }
  is_valid_port "$port" || { error "Porta pública inválida na configuração."; return 1; }
  [[ "$proto" == tcp || "$proto" == udp ]] || { error "Protocolo inválido na configuração."; return 1; }
  [[ "$proto" == tcp ]] && ovpn_proto=tcp4-client || ovpn_proto=udp4
  printf "Arquivo de saída [/root/oneplus-openvpn.ovpn]: "; read -r output
  output=${output:-/root/oneplus-openvpn.ovpn}
  [[ "$output" == /* && ! -e "$output" ]] || { error "Use caminho absoluto ainda inexistente."; return 1; }
  umask 077
  {
    cat <<EOF2
client
dev tun
proto ${ovpn_proto}
remote ${host} ${port}
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name oneplus-server name
auth-user-pass
tls-version-min 1.2
data-ciphers AES-256-GCM:AES-128-GCM:?CHACHA20-POLY1305
auth SHA256
allow-compression no
verb 3
<ca>
EOF2
    cat "$OPENVPN_CA_CERT"
    printf '</ca>\n<tls-crypt>\n'
    cat "$OPENVPN_TLS_CRYPT"
    printf '</tls-crypt>\n'
  } > "$output"
  chown root:root "$output"; chmod 0600 "$output"
  ok "Perfil criado: ${output}"
  warn "Este perfil usa usuário/senha OnePlus e contém tls-crypt. Trate-o como material sensível."
}

issue_device_profile_interactive() {
  [[ "$(read_openvpn_value OPENVPN_AUTH_MODE)" == hybrid ]] || { error "O servidor não está no modo mTLS híbrido."; return 1; }
  local user device output
  user=$(prompt_managed_username) || return 1
  printf "Nome do dispositivo (ex.: android, notebook): "; read -r device
  valid_openvpn_device_name "$device" || { error "Nome inválido."; return 1; }
  output="/root/oneplus-${user}-${device}.ovpn"
  printf "Arquivo de saída [%s]: " "$output"; read -r v; output=${v:-$output}
  issue_openvpn_device_profile "$user" "$device" "$output" 0
}

list_openvpn_devices() {
  ensure_openvpn_ca_db >/dev/null 2>&1 || true
  local f user device serial status issued revoke count=0
  printf '%-18s %-18s %-34s %-10s %-12s %s\n' USUARIO DISPOSITIVO SERIAL STATUS EMITIDO REVOGA_EM
  shopt -s nullglob
  for f in "$OPENVPN_CLIENTS_DIR"/*.conf; do
    user=$(client_meta_get "$f" USER); device=$(client_meta_get "$f" DEVICE); serial=$(client_meta_get "$f" SERIAL); status=$(client_meta_get "$f" STATUS)
    issued=$(client_meta_get "$f" ISSUED_AT); revoke=$(client_meta_get "$f" REVOKE_AFTER)
    [[ "$issued" =~ ^[0-9]+$ ]] && issued=$(date -d "@${issued}" +%F 2>/dev/null || echo '?') || issued='?'
    if [[ "$revoke" =~ ^[0-9]+$ ]] && (( revoke > 0 )); then revoke=$(date -d "@${revoke}" '+%F %H:%M' 2>/dev/null || echo '?'); else revoke='-'; fi
    printf '%-18s %-18s %-34s %-10s %-12s %s\n' "$user" "$device" "$serial" "$status" "$issued" "$revoke"
    ((count+=1))
  done
  shopt -u nullglob
  (( count > 0 )) || printf 'Nenhum certificado de dispositivo emitido.\n'
}

revoke_openvpn_serial() {
  local serial="${1^^}" reason="${2:-cessationOfOperation}" metafile certfile user
  valid_openvpn_serial "$serial" || { error "Serial inválido."; return 1; }
  metafile=$(client_meta_file "$serial"); certfile=$(client_cert_file "$serial")
  [[ -f "$metafile" && -f "$certfile" ]] || { error "Certificado gerenciado não encontrado."; return 1; }
  [[ "$(client_meta_get "$metafile" STATUS)" == valid ]] || { warn "Certificado já não está ativo."; return 0; }
  ensure_openvpn_ca_db || return 1
  case "$reason" in unspecified|keyCompromise|affiliationChanged|superseded|cessationOfOperation) ;; *) reason=cessationOfOperation ;; esac
  local ca_status=""
  if ! openssl ca -batch -config "$OPENVPN_CA_DB_CONF" -revoke "$certfile" -crl_reason "$reason" >/dev/null 2>&1; then
    ca_status=$(openssl ca -config "$OPENVPN_CA_DB_CONF" -status "$serial" 2>&1 || true)
    if ! grep -qi 'revoked' <<< "$ca_status"; then
      error "Falha ao revogar certificado ${serial}."
      return 1
    fi
  fi
  client_meta_set "$metafile" STATUS revocation-pending
  client_meta_set "$metafile" REVOKED_AT "$(date +%s)"
  client_meta_set "$metafile" REVOKE_AFTER 0
  if ! generate_openvpn_crl; then
    error "O certificado foi revogado no banco da CA, mas a CRL ainda não pôde ser atualizada. O timer tentará novamente."
    return 1
  fi
  client_meta_set "$metafile" STATUS revoked
  user=$(client_meta_get "$metafile" USER)
  if [[ -S "$OPENVPN_MGMT" && -n "$user" && -x /opt/oneplus/libexec/openvpn_manager.py ]]; then
    /opt/oneplus/libexec/openvpn_manager.py kill-user "$user" >/dev/null 2>&1 || true
  fi
  ok "Certificado ${serial} revogado. A CRL será aplicada em novas conexões sem reiniciar o servidor."
}

revoke_device_interactive() {
  clear; list_openvpn_devices; local serial confirm
  printf '\nSerial a revogar: '; read -r serial
  valid_openvpn_serial "$serial" || { error "Serial inválido."; return 1; }
  printf 'Digite REVOGAR para confirmar: '; read -r confirm
  [[ "$confirm" == REVOGAR ]] || { info "Cancelado."; return 0; }
  revoke_openvpn_serial "$serial" cessationOfOperation
}

rotate_device_interactive() {
  [[ "$(read_openvpn_value OPENVPN_AUTH_MODE)" == hybrid ]] || { error "O servidor não está no modo mTLS híbrido."; return 1; }
  clear; list_openvpn_devices
  local old_serial metafile user device output hours new_serial now revoke_at
  printf '\nSerial ativo a substituir: '; read -r old_serial; old_serial=${old_serial^^}
  valid_openvpn_serial "$old_serial" || { error "Serial inválido."; return 1; }
  metafile=$(client_meta_file "$old_serial")
  [[ -f "$metafile" && "$(client_meta_get "$metafile" STATUS)" == valid ]] || { error "Certificado ativo não encontrado."; return 1; }
  user=$(client_meta_get "$metafile" USER); device=$(client_meta_get "$metafile" DEVICE)
  require_managed_user "$user" || return 1
  output="/root/oneplus-${user}-${device}-rotated.ovpn"
  printf "Novo perfil [%s]: " "$output"; read -r v; output=${v:-$output}
  printf "Janela de migração em horas [24] (1..168): "; read -r hours; hours=${hours:-24}
  [[ "$hours" =~ ^[0-9]+$ ]] && (( 10#$hours >= 1 && 10#$hours <= 168 )) || { error "Janela inválida."; return 1; }
  issue_openvpn_device_profile "$user" "$device" "$output" 1 || return 1
  new_serial="$ONEPLUS_LAST_ISSUED_SERIAL"
  now=$(date +%s); revoke_at=$(( now + 10#$hours * 3600 ))
  client_meta_set "$metafile" REVOKE_AFTER "$revoke_at"
  client_meta_set "$metafile" REPLACED_BY "$new_serial"
  ok "Rotação preparada. O certificado antigo ${old_serial} continuará válido por ${hours}h e será revogado automaticamente pelo timer OnePlus."
  warn "Distribua e teste o novo perfil antes do fim da janela."
}

maintain_openvpn_pki() {
  require_root
  [[ -d "$OPENVPN_CLIENTS_DIR" ]] || return 0
  local now f serial revoke status
  now=$(date +%s)
  shopt -s nullglob
  for f in "$OPENVPN_CLIENTS_DIR"/*.conf; do
    status=$(client_meta_get "$f" STATUS); revoke=$(client_meta_get "$f" REVOKE_AFTER); serial=$(client_meta_get "$f" SERIAL)
    if [[ "$status" == revocation-pending ]]; then
      if generate_openvpn_crl; then
        client_meta_set "$f" STATUS revoked || true
        printf '[PKI] CRL recuperada; serial %s confirmado como revogado.\n' "$serial"
      fi
      continue
    fi
    [[ "$status" == valid && "$revoke" =~ ^[0-9]+$ ]] || continue
    (( revoke > 0 && now >= revoke )) || continue
    printf '[PKI] Janela de migração encerrada; revogando serial %s.\n' "$serial"
    revoke_openvpn_serial "$serial" superseded || true
  done
  shopt -u nullglob
}

openvpn_security_health() {
  openvpn_pki_valid || return 1
  [[ -r "$OPENVPN_CONF" ]] || return 1
  local mode
  mode=$(read_openvpn_value OPENVPN_AUTH_MODE); mode=${mode:-password}
  valid_openvpn_auth_mode "$mode" || return 1
  [[ -r "$OPENVPN_PAM" ]] || return 1
  if [[ "$mode" == hybrid ]]; then openvpn_ca_db_valid || return 1; fi
}

openvpn_port_in_use() {
  local bind="$1" port="$2" proto="$3"
  if [[ "$proto" == tcp ]]; then tcp_port_in_use "$port"; else udp_bind_port_in_use "$bind" "$port"; fi
}

configure_openvpn() {
  ensure_openvpn_packages; ensure_openvpn_pam; generate_openvpn_pki || return 1
  local bind="127.0.0.1" port="1194" proto="tcp" public_host="" public_port="443" network="10.8.0.0" max_clients="128" full_tunnel="no" push_dns1="" push_dns2="" auth_mode="password" v tmp old_conf had_old=0 was_active=0
  [[ -r "$OPENVPN_CONF" ]] && {
    bind=$(read_openvpn_value OPENVPN_BIND); bind=${bind:-127.0.0.1}; port=$(read_openvpn_value OPENVPN_PORT); port=${port:-1194}; proto=$(read_openvpn_value OPENVPN_PROTO); proto=${proto:-tcp}
    public_host=$(read_openvpn_value OPENVPN_PUBLIC_HOST); public_port=$(read_openvpn_value OPENVPN_PUBLIC_PORT); public_port=${public_port:-443}; network=$(read_openvpn_value OPENVPN_NETWORK); network=${network:-10.8.0.0}
    max_clients=$(read_openvpn_value OPENVPN_MAX_CLIENTS); max_clients=${max_clients:-128}; full_tunnel=$(read_openvpn_value OPENVPN_FULL_TUNNEL); full_tunnel=${full_tunnel:-no}; push_dns1=$(read_openvpn_value OPENVPN_PUSH_DNS1); push_dns2=$(read_openvpn_value OPENVPN_PUSH_DNS2)
    auth_mode=$(read_openvpn_value OPENVPN_AUTH_MODE); auth_mode=${auth_mode:-password}
  }
  printf "IPv4 de escuta OpenVPN [%s]: " "$bind"; read -r v; bind=${v:-$bind}; is_valid_ipv4 "$bind" || { error "IPv4 inválido."; return 1; }
  if [[ "$bind" != 0.0.0.0 && "$bind" != 127.0.0.1 ]] && ! ipv4_is_local_address "$bind"; then error "O IPv4 ${bind} não pertence a uma interface local."; return 1; fi
  printf "Protocolo [tcp/udp] [%s]: " "$proto"; read -r v; proto=${v:-$proto}; [[ "$proto" == tcp || "$proto" == udp ]] || { error "Protocolo inválido."; return 1; }
  printf "Porta interna OpenVPN [%s]: " "$port"; read -r v; port=${v:-$port}; is_valid_port "$port" || { error "Porta inválida."; return 1; }
  printf "Rede VPN privada /24 [%s]: " "$network"; read -r v; network=${v:-$network}; valid_private_24_network "$network" || { error "Use uma rede privada RFC1918 /24 terminada em .0."; return 1; }
  printf "Máximo de clientes [%s]: " "$max_clients"; read -r v; max_clients=${v:-$max_clients}; [[ "$max_clients" =~ ^[0-9]+$ ]] && (( 10#$max_clients >= 1 && 10#$max_clients <= 250 )) || { error "Máximo inválido."; return 1; }
  local suggested=${public_host:-$(primary_ipv4)}
  printf "Host/IP público para o perfil cliente [%s]: " "$suggested"; read -r v; public_host=${v:-$suggested}; valid_openvpn_public_host "$public_host" && [[ -n "$public_host" ]] || { error "Host/IP público inválido."; return 1; }
  printf "Porta pública para o perfil cliente [%s]: " "$public_port"; read -r v; public_port=${v:-$public_port}; is_valid_port "$public_port" || { error "Porta pública inválida."; return 1; }
  printf '\nAutenticação:\n1) Usuário/senha OnePlus (PAM)\n2) Usuário/senha + certificado mTLS por dispositivo\nEscolha [%s]: ' "$([[ "$auth_mode" == hybrid ]] && echo 2 || echo 1)"
  read -r v
  case "${v:-$([[ "$auth_mode" == hybrid ]] && echo 2 || echo 1)}" in 1) auth_mode=password ;; 2) auth_mode=hybrid ;; *) error "Opção inválida."; return 1 ;; esac
  if [[ "$auth_mode" == hybrid ]]; then
    ensure_openvpn_ca_db || return 1
    warn "Ao ativar mTLS, perfis antigos sem <cert>/<key> deixarão de conectar até receberem um perfil de dispositivo."
  fi

  warn "O OpenVPN sempre exige uma conta válida do grupo oneplus-users via PAM."
  [[ "$auth_mode" == hybrid ]] && info "mTLS híbrido ativado: além da senha, cada dispositivo precisará de certificado individual e poderá ser revogado isoladamente."
  info "NAT/full-tunnel é gerenciado separadamente em Portas / Firewall / NAT."
  [[ "$bind" == 127.0.0.1 ]] && info "Bind loopback selecionado: ideal para sslh." || warn "OpenVPN será exposto diretamente em ${bind}:${port}/${proto}."

  systemctl is-active --quiet "$OPENVPN_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-openvpn-old.XXXXXX); if [[ -e "$OPENVPN_CONF" ]]; then cp -a "$OPENVPN_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$OPENVPN_SERVICE" 2>/dev/null || true
  if openvpn_port_in_use "$bind" "$port" "$proto"; then error "A porta ${port}/${proto} já está em uso."; (( had_old )) && install -m 0640 -o root -g root "$old_conf" "$OPENVPN_CONF"; (( was_active && had_old )) && systemctl start "$OPENVPN_SERVICE" 2>/dev/null || true; rm -f "$old_conf"; return 1; fi

  tmp=$(mktemp /tmp/oneplus-openvpn.XXXXXX)
  cat > "$tmp" <<EOF2
OPENVPN_BIND=${bind}
OPENVPN_PORT=${port}
OPENVPN_PROTO=${proto}
OPENVPN_PUBLIC_HOST=${public_host}
OPENVPN_PUBLIC_PORT=${public_port}
OPENVPN_NETWORK=${network}
OPENVPN_MAX_CLIENTS=${max_clients}
OPENVPN_FULL_TUNNEL=${full_tunnel}
OPENVPN_PUSH_DNS1=${push_dns1}
OPENVPN_PUSH_DNS2=${push_dns2}
OPENVPN_AUTH_MODE=${auth_mode}
EOF2
  install -m 0640 -o root -g root "$tmp" "$OPENVPN_CONF"; rm -f "$tmp"; systemctl daemon-reload
  if systemctl enable --now "$OPENVPN_SERVICE" && sleep 2 && systemctl is-active --quiet "$OPENVPN_SERVICE"; then rm -f "$old_conf"; ok "OpenVPN ativo em ${bind}:${port}/${proto} (${auth_mode})."; return 0; fi
  error "OpenVPN não iniciou; restaurando configuração anterior."; journalctl -u "$OPENVPN_SERVICE" -n 60 --no-pager || true; systemctl disable --now "$OPENVPN_SERVICE" 2>/dev/null || true
  if (( had_old )); then install -m 0640 -o root -g root "$old_conf" "$OPENVPN_CONF"; (( was_active )) && systemctl enable --now "$OPENVPN_SERVICE" 2>/dev/null || true; fi
  rm -f "$old_conf"; return 1
}

export_openvpn_profile() {
  local mode
  mode=$(read_openvpn_value OPENVPN_AUTH_MODE); mode=${mode:-password}
  if [[ "$mode" == hybrid ]]; then issue_device_profile_interactive; else export_password_profile; fi
}

show_openvpn_status() {
  local mode
  mode=$(read_openvpn_value OPENVPN_AUTH_MODE); mode=${mode:-password}
  printf "Versão: %s\n" "$(openvpn --version 2>/dev/null | head -1 || echo ausente)"
  printf "Serviço: %b\n" "$(service_state "$OPENVPN_SERVICE")"
  printf "Autenticação: %s\n" "$([[ "$mode" == hybrid ]] && echo 'usuário/senha + mTLS por dispositivo' || echo 'usuário/senha')"
  if [[ -r "$OPENVPN_CONF" ]]; then
    printf "Escuta: %s:%s/%s\n" "$(read_openvpn_value OPENVPN_BIND)" "$(read_openvpn_value OPENVPN_PORT)" "$(read_openvpn_value OPENVPN_PROTO)"
    printf "Público: %s:%s\n" "$(read_openvpn_value OPENVPN_PUBLIC_HOST)" "$(read_openvpn_value OPENVPN_PUBLIC_PORT)"
    printf "Rede: %s/24\n" "$(read_openvpn_value OPENVPN_NETWORK)"
    printf "Full tunnel: %s\n" "$(read_openvpn_value OPENVPN_FULL_TUNNEL)"
  fi
  printf "PKI servidor: %s\n" "$([[ -s "$OPENVPN_SERVER_CERT" ]] && echo instalada || echo ausente)"
  [[ "$mode" == hybrid ]] && printf "CRL mTLS: %s\n" "$([[ -s "$OPENVPN_CRL" ]] && echo válida || echo ausente)"
  if [[ -S "$OPENVPN_MGMT" ]]; then printf "\nClientes/status:\n"; /opt/oneplus/libexec/openvpn_manager.py status 2>/dev/null | sed -n '1,80p' || true; fi
}

show_openvpn_certificate() {
  openvpn_pki_valid || { warn "PKI ausente ou inválida."; return 0; }
  openssl x509 -in "$OPENVPN_SERVER_CERT" -noout -subject -issuer -serial -dates -fingerprint -sha256
}

initialize_openvpn_module() { require_root; ensure_openvpn_pam; }

module_openvpn_devices() {
  while true; do
    clear
    printf "%bOnePlus • OpenVPN mTLS por dispositivo%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "1) Listar dispositivos/certificados\n2) Emitir novo perfil mTLS\n3) Revogar dispositivo agora\n4) Rotacionar certificado com janela de migração\n5) Regenerar/verificar CRL\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) clear; list_openvpn_devices; pause ;;
      2) issue_device_profile_interactive; pause ;;
      3) revoke_device_interactive; pause ;;
      4) rotate_device_interactive; pause ;;
      5) ensure_openvpn_ca_db && generate_openvpn_crl && openssl crl -in "$OPENVPN_CRL" -noout -issuer -lastupdate -nextupdate; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

module_openvpn() {
  while true; do
    clear
    local mode
    mode=$(read_openvpn_value OPENVPN_AUTH_MODE); mode=${mode:-password}
    printf "%bOnePlus • OpenVPN%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Serviço: %b | PKI: %s | Auth: %s\n\n" "$(service_state "$OPENVPN_SERVICE")" "$([[ -s "$OPENVPN_SERVER_CERT" ]] && echo OK || echo ausente)" "$mode"
    printf "1) Configurar e habilitar\n2) Gerar/verificar PKI do servidor\n3) Exportar perfil .ovpn\n4) Dispositivos mTLS / revogação / rotação\n5) Status/clientes\n6) Mostrar certificado do servidor\n7) Reiniciar\n8) Logs\n9) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) configure_openvpn; pause ;;
      2) generate_openvpn_pki; pause ;;
      3) export_openvpn_profile; pause ;;
      4) module_openvpn_devices ;;
      5) clear; show_openvpn_status; pause ;;
      6) show_openvpn_certificate; pause ;;
      7) systemctl restart "$OPENVPN_SERVICE"; pause ;;
      8) journalctl -u "$OPENVPN_SERVICE" -n 120 --no-pager; pause ;;
      9) systemctl disable --now "$OPENVPN_SERVICE" 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  source "$ROOT_DIR/lib/common.sh"
  source "$ROOT_DIR/modules/users.sh"
  case "${1:-}" in
    init) initialize_openvpn_module ;;
    pki) generate_openvpn_pki ;;
    ca-db) ensure_openvpn_ca_db ;;
    maintenance) maintain_openvpn_pki ;;
    health) openvpn_security_health ;;
    revoke) [[ -n "${2:-}" ]] || { echo "Uso: $0 revoke SERIAL"; exit 2; }; revoke_openvpn_serial "$2" cessationOfOperation ;;
    *) echo "Uso: $0 {init|pki|ca-db|maintenance|health|revoke SERIAL}"; exit 2 ;;
  esac
fi
