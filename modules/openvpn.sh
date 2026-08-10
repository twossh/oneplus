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
OPENVPN_TLS_CRYPT_V2="$OPENVPN_DIR/tls-crypt-v2-server.key"
OPENVPN_ROTATION_DIR="$OPENVPN_DIR/rotation"
OPENVPN_ROTATION_STATE="$OPENVPN_ROTATION_DIR/state.conf"
OPENVPN_ROTATION_NEXT="$OPENVPN_ROTATION_DIR/next"
OPENVPN_NEXT_PKI="$OPENVPN_ROTATION_NEXT/pki"
OPENVPN_NEXT_CA_KEY="$OPENVPN_NEXT_PKI/ca.key"
OPENVPN_NEXT_CA_CERT="$OPENVPN_NEXT_PKI/ca.crt"
OPENVPN_NEXT_SERVER_KEY="$OPENVPN_NEXT_PKI/server.key"
OPENVPN_NEXT_SERVER_CERT="$OPENVPN_NEXT_PKI/server.crt"
OPENVPN_NEXT_TLS_CRYPT_V2="$OPENVPN_ROTATION_NEXT/tls-crypt-v2-server.key"
OPENVPN_NEXT_CA_DB="$OPENVPN_ROTATION_NEXT/ca-db"
OPENVPN_NEXT_CA_DB_CONF="$OPENVPN_NEXT_CA_DB/openssl.cnf"
OPENVPN_NEXT_CRL="$OPENVPN_NEXT_CA_DB/crl.pem"
OPENVPN_NEXT_CLIENTS="$OPENVPN_ROTATION_NEXT/clients"
OPENVPN_ROTATION_CA_BUNDLE="$OPENVPN_ROTATION_DIR/ca-bundle.crt"
OPENVPN_ROTATION_CRL_BUNDLE="$OPENVPN_ROTATION_DIR/crl-bundle.pem"
OPENVPN_ARCHIVE_ROOT="${ONEPLUS_OPENVPN_ARCHIVE_ROOT:-/var/lib/oneplus/openvpn-pki-archives}"
OPENVPN_AUTHZ_DIR="${ONEPLUS_OPENVPN_AUTHZ_DIR:-/var/lib/oneplus/openvpn-authz}"
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

set_openvpn_value() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^OPENVPN_[A-Z0-9_]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  [[ -f "$OPENVPN_CONF" ]] || return 1
  tmp=$(mktemp /tmp/oneplus-openvpn-env.XXXXXX)
  awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k{print k"="v;done=1;next}{print} END{if(!done)print k"="v}' "$OPENVPN_CONF" > "$tmp"
  install -m 0640 -o root -g root "$tmp" "$OPENVPN_CONF"
  rm -f "$tmp"
}

rotation_state_get() {
  local key="$1"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$OPENVPN_ROTATION_STATE" 2>/dev/null || true
}

rotation_is_prepared() {
  [[ -r "$OPENVPN_ROTATION_STATE" && "$(rotation_state_get STATE)" == prepared ]]
}

valid_openvpn_tls_crypt_mode() { [[ "$1" == legacy || "$1" == dual || "$1" == v2 ]]; }

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

openvpn_pki_material_valid() {
  [[ -s "$OPENVPN_CA_KEY" && -s "$OPENVPN_CA_CERT" && -s "$OPENVPN_SERVER_KEY" && -s "$OPENVPN_SERVER_CERT" ]] || return 1
  openssl x509 -in "$OPENVPN_CA_CERT" -noout >/dev/null 2>&1 || return 1
  openssl x509 -in "$OPENVPN_SERVER_CERT" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$OPENVPN_CA_KEY" -passin pass: -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$OPENVPN_SERVER_KEY" -passin pass: -noout >/dev/null 2>&1 || return 1
  openssl verify -purpose sslserver -CAfile "$OPENVPN_CA_CERT" "$OPENVPN_SERVER_CERT" >/dev/null 2>&1 || return 1
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$OPENVPN_SERVER_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$OPENVPN_SERVER_KEY" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]
}

openvpn_pki_valid() {
  openvpn_pki_material_valid || return 1
  local mode
  mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); mode=${mode:-legacy}
  valid_openvpn_tls_crypt_mode "$mode" || return 1
  case "$mode" in
    legacy) [[ -s "$OPENVPN_TLS_CRYPT" ]] ;;
    dual)
      [[ -s "$OPENVPN_TLS_CRYPT" ]] || return 1
      if rotation_is_prepared; then [[ -s "$OPENVPN_NEXT_TLS_CRYPT_V2" ]]; else [[ -s "$OPENVPN_TLS_CRYPT_V2" ]]; fi
      ;;
    v2) [[ -s "$OPENVPN_TLS_CRYPT_V2" ]] ;;
  esac
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

write_ca_config_generic() {
  local db="$1" ca_cert="$2" ca_key="$3" conf="$4" tmp
  install -d -m 0711 -o root -g root "$db"
  install -d -m 0700 -o root -g root "$db/newcerts"
  tmp=$(mktemp /tmp/oneplus-openssl-ca.XXXXXX)
  cat > "$tmp" <<EOF2
[ ca ]
default_ca = oneplus_ca

[ oneplus_ca ]
dir = ${db}
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
certificate = ${ca_cert}
private_key = ${ca_key}
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
  install -m 0600 -o root -g root "$tmp" "$conf"
  rm -f "$tmp"
}

write_openvpn_ca_config() {
  install -d -m 0700 -o root -g root "$OPENVPN_CLIENTS_DIR"
  write_ca_config_generic "$OPENVPN_CA_DB" "$OPENVPN_CA_CERT" "$OPENVPN_CA_KEY" "$OPENVPN_CA_DB_CONF"
}

write_next_ca_config() {
  install -d -m 0700 -o root -g root "$OPENVPN_NEXT_CLIENTS"
  write_ca_config_generic "$OPENVPN_NEXT_CA_DB" "$OPENVPN_NEXT_CA_CERT" "$OPENVPN_NEXT_CA_KEY" "$OPENVPN_NEXT_CA_DB_CONF"
}

generate_crl_generic() {
  local db_conf="$1" ca_cert="$2" output="$3" tmp
  tmp=$(mktemp "$(dirname "$output")/.crl.XXXXXX")
  if ! openssl ca -batch -config "$db_conf" -gencrl -out "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    error "Falha ao gerar CRL OpenVPN."
    return 1
  fi
  openssl crl -in "$tmp" -noout -verify -CAfile "$ca_cert" >/dev/null 2>&1 || { rm -f "$tmp"; error "CRL gerada não passou na validação."; return 1; }
  chown root:root "$tmp"
  chmod 0644 "$tmp"
  mv -f -- "$tmp" "$output"
}

generate_openvpn_crl() {
  [[ -r "$OPENVPN_CA_DB_CONF" ]] || write_openvpn_ca_config
  generate_crl_generic "$OPENVPN_CA_DB_CONF" "$OPENVPN_CA_CERT" "$OPENVPN_CRL"
}

generate_next_crl() {
  [[ -r "$OPENVPN_NEXT_CA_DB_CONF" ]] || write_next_ca_config
  generate_crl_generic "$OPENVPN_NEXT_CA_DB_CONF" "$OPENVPN_NEXT_CA_CERT" "$OPENVPN_NEXT_CRL"
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

ensure_next_ca_db() {
  [[ -s "$OPENVPN_NEXT_CA_KEY" && -s "$OPENVPN_NEXT_CA_CERT" && -s "$OPENVPN_NEXT_SERVER_KEY" && -s "$OPENVPN_NEXT_SERVER_CERT" ]] || return 1
  write_next_ca_config
  [[ -e "$OPENVPN_NEXT_CA_DB/index.txt" ]] || install -m 0600 -o root -g root /dev/null "$OPENVPN_NEXT_CA_DB/index.txt"
  if [[ ! -s "$OPENVPN_NEXT_CA_DB/serial" ]]; then
    openssl rand -hex 16 | tr '[:lower:]' '[:upper:]' > "$OPENVPN_NEXT_CA_DB/serial"
    chmod 0600 "$OPENVPN_NEXT_CA_DB/serial"
  fi
  if [[ ! -s "$OPENVPN_NEXT_CA_DB/crlnumber" ]]; then
    printf '1000\n' > "$OPENVPN_NEXT_CA_DB/crlnumber"
    chmod 0600 "$OPENVPN_NEXT_CA_DB/crlnumber"
  fi
  [[ -s "$OPENVPN_NEXT_CRL" ]] || generate_next_crl
  openssl crl -in "$OPENVPN_NEXT_CRL" -noout -verify -CAfile "$OPENVPN_NEXT_CA_CERT" >/dev/null 2>&1
}

next_ca_db_valid() {
  [[ -r "$OPENVPN_NEXT_CA_DB_CONF" && -r "$OPENVPN_NEXT_CA_DB/index.txt" && -s "$OPENVPN_NEXT_CA_DB/serial" && -s "$OPENVPN_NEXT_CRL" ]] || return 1
  openssl crl -in "$OPENVPN_NEXT_CRL" -noout -verify -CAfile "$OPENVPN_NEXT_CA_CERT" >/dev/null 2>&1
}

openvpn_ca_db_valid() {
  [[ -r "$OPENVPN_CA_DB_CONF" && -r "$OPENVPN_CA_DB/index.txt" && -s "$OPENVPN_CA_DB/serial" && -s "$OPENVPN_CRL" ]] || return 1
  openssl crl -in "$OPENVPN_CRL" -noout -verify -CAfile "$OPENVPN_CA_CERT" >/dev/null 2>&1
}

client_meta_file() { printf '%s/%s.conf' "$OPENVPN_CLIENTS_DIR" "${1^^}"; }
client_cert_file() { printf '%s/%s.crt' "$OPENVPN_CLIENTS_DIR" "${1^^}"; }
next_client_meta_file() { printf '%s/%s.conf' "$OPENVPN_NEXT_CLIENTS" "${1^^}"; }
next_client_cert_file() { printf '%s/%s.crt' "$OPENVPN_NEXT_CLIENTS" "${1^^}"; }
client_meta_get() { awk -F= -v k="$2" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$1" 2>/dev/null || true; }

authz_file() { printf '%s/%s.user' "$OPENVPN_AUTHZ_DIR" "${1^^}"; }
rebuild_openvpn_authz() {
  local tmp f serial user status out dir ca cert cert_serial
  tmp=$(mktemp -d /tmp/oneplus-openvpn-authz.XXXXXX)
  chmod 0755 "$tmp"
  for dir in "$OPENVPN_CLIENTS_DIR" "$OPENVPN_NEXT_CLIENTS"; do
    [[ -d "$dir" ]] || continue
    if [[ "$dir" == "$OPENVPN_NEXT_CLIENTS" ]]; then ca="$OPENVPN_NEXT_CA_CERT"; else ca="$OPENVPN_CA_CERT"; fi
    [[ -s "$ca" ]] || continue
    shopt -s nullglob
    for f in "$dir"/*.conf; do
      status=$(client_meta_get "$f" STATUS); [[ "$status" == valid ]] || continue
      serial=$(client_meta_get "$f" SERIAL); serial=${serial^^}
      user=$(client_meta_get "$f" USER)
      valid_openvpn_serial "$serial" || continue
      is_valid_username "$user" || continue
      cert="$dir/${serial}.crt"; [[ -s "$cert" ]] || continue
      cert_serial=$(openssl x509 -in "$cert" -noout -serial 2>/dev/null | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
      [[ "$cert_serial" == "$serial" ]] || continue
      openssl verify -purpose sslclient -CAfile "$ca" "$cert" >/dev/null 2>&1 || continue
      out="$tmp/${serial}.user"
      if [[ -e "$out" && "$(cat "$out" 2>/dev/null)" != "$user" ]]; then
        rm -rf "$tmp"; error "Colisão de serial no mapa de identidade OpenVPN."; return 1
      fi
      printf '%s\n' "$user" > "$out"
      chmod 0644 "$out"
    done
    shopt -u nullglob
  done
  install -d -m 0711 -o root -g root "$OPENVPN_AUTHZ_DIR"
  find "$OPENVPN_AUTHZ_DIR" -mindepth 1 -maxdepth 1 -type f -name '*.user' -delete
  shopt -s nullglob
  for f in "$tmp"/*.user; do install -m 0644 -o root -g root "$f" "$OPENVPN_AUTHZ_DIR/$(basename "$f")"; done
  shopt -u nullglob
  rm -rf "$tmp"
}
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

next_active_device_exists() {
  local user="$1" device="$2" f
  shopt -s nullglob
  for f in "$OPENVPN_NEXT_CLIENTS"/*.conf; do
    [[ "$(client_meta_get "$f" USER)" == "$user" && "$(client_meta_get "$f" DEVICE)" == "$device" && "$(client_meta_get "$f" STATUS)" == valid ]] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

generate_tlscrypt_v2_client_key() {
  local server_key="$1" output="$2" user="$3" device="$4" serial="$5" metadata metadata_b64
  [[ -s "$server_key" ]] || { error "Chave tls-crypt-v2 do servidor ausente."; return 1; }
  command -v openvpn >/dev/null 2>&1 || { error "OpenVPN não instalado."; return 1; }
  metadata="oneplus:v1:user=${user};device=${device};serial=${serial}"
  metadata_b64=$(printf '%s' "$metadata" | base64 -w0)
  openvpn --tls-crypt-v2 "$server_key" --genkey tls-crypt-v2-client "$output" "$metadata_b64" >/dev/null 2>&1 || return 1
  grep -Fq 'BEGIN OpenVPN tls-crypt-v2 client key' "$output"
}

write_hybrid_profile() {
  local output="$1" host="$2" port="$3" proto="$4" cert="$5" key="$6" ovpn_proto ca_file="${7:-$OPENVPN_CA_CERT}" tls_key="${8:-$OPENVPN_TLS_CRYPT}"
  [[ "$proto" == tcp ]] && ovpn_proto=tcp4-client || ovpn_proto=udp4
  [[ -r "$ca_file" && -r "$tls_key" ]] || return 1
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
    cat "$ca_file"
    printf '</ca>\n<cert>\n'
    cat "$cert"
    printf '</cert>\n<key>\n'
    cat "$key"
    printf '</key>\n<tls-crypt>\n'
    cat "$tls_key"
    printf '</tls-crypt>\n'
  } > "$output"
  chown root:root "$output"
  chmod 0600 "$output"
}

write_hybrid_profile_v2() {
  local output="$1" host="$2" port="$3" proto="$4" cert="$5" key="$6" ca_file="$7" tls_v2_key="$8" ovpn_proto
  [[ "$proto" == tcp ]] && ovpn_proto=tcp4-client || ovpn_proto=udp4
  [[ -r "$ca_file" && -r "$tls_v2_key" ]] || return 1
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
    cat "$ca_file"
    printf '</ca>\n<cert>\n'
    cat "$cert"
    printf '</cert>\n<key>\n'
    cat "$key"
    printf '</key>\n<tls-crypt-v2>\n'
    cat "$tls_v2_key"
    printf '</tls-crypt-v2>\n'
  } > "$output"
  chown root:root "$output"
  chmod 0600 "$output"
}

issue_openvpn_device_profile() {
  local user="$1" device="$2" output="$3" allow_duplicate="${4:-0}"
  require_managed_user "$user" || return 1
  valid_openvpn_device_name "$device" || { error "Nome de dispositivo inválido (1..32; letras, números, ponto, hífen e sublinhado)."; return 1; }
  [[ "$(read_openvpn_value OPENVPN_AUTH_MODE)" == hybrid ]] || { error "Ative o modo usuário/senha + mTLS antes de emitir certificados de dispositivo."; return 1; }
  rotation_is_prepared && { error "Há uma rotação de infraestrutura em andamento. Emita o perfil pelo menu 'Rotação da infraestrutura PKI'."; return 1; }
  [[ "$output" == /* && ! -e "$output" ]] || { error "Use um caminho absoluto ainda inexistente para o perfil."; return 1; }
  ensure_openvpn_ca_db || return 1
  if [[ "$allow_duplicate" != 1 ]] && active_device_exists "$user" "$device"; then
    error "Já existe um certificado ativo para ${user}/${device}. Use a opção de rotação para substituí-lo com janela de migração."
    return 1
  fi

  local tmp cn serial certfile metafile host port proto now not_after tc_mode
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

  tc_mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); tc_mode=${tc_mode:-legacy}
  case "$tc_mode" in
    legacy) ;;
    v2)
      generate_tlscrypt_v2_client_key "$OPENVPN_TLS_CRYPT_V2" "$tmp/tls-v2.key" "$user" "$device" "$serial" || { rm -rf "$tmp"; error "Falha ao gerar tls-crypt-v2 do dispositivo."; return 1; }
      ;;
    *) rm -rf "$tmp"; error "Modo tls-crypt inesperado: $tc_mode"; return 1 ;;
  esac

  install -d -m 0700 -o root -g root "$OPENVPN_CLIENTS_DIR"
  install -m 0644 -o root -g root "$tmp/client.crt" "$certfile"
  now=$(date +%s)
  not_after=$(LC_ALL=C date -d "$(LC_ALL=C openssl x509 -in "$tmp/client.crt" -noout -enddate | cut -d= -f2-)" +%s 2>/dev/null || echo 0)
  cat > "$tmp/meta" <<EOF2
FORMAT=2
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
CONTROL_KEY=${tc_mode}
EOF2
  install -m 0600 -o root -g root "$tmp/meta" "$metafile"
  local write_ok=0
  if [[ "$tc_mode" == v2 ]]; then
    write_hybrid_profile_v2 "$output" "$host" "$port" "$proto" "$tmp/client.crt" "$tmp/client.key" "$OPENVPN_CA_CERT" "$tmp/tls-v2.key" && write_ok=1
  else
    write_hybrid_profile "$output" "$host" "$port" "$proto" "$tmp/client.crt" "$tmp/client.key" "$OPENVPN_CA_CERT" "$OPENVPN_TLS_CRYPT" && write_ok=1
  fi
  if (( write_ok )) && rebuild_openvpn_authz; then
    :
  else
    rm -f -- "$output"
    openssl ca -batch -config "$OPENVPN_CA_DB_CONF" -revoke "$certfile" -crl_reason cessationOfOperation >/dev/null 2>&1 || true
    generate_openvpn_crl >/dev/null 2>&1 || true
    client_meta_set "$metafile" STATUS revoked || true
    client_meta_set "$metafile" REVOKED_AT "$(date +%s)" || true
    rebuild_openvpn_authz >/dev/null 2>&1 || true
    rm -rf "$tmp"
    error "Falha ao finalizar perfil/vínculo certificado-usuário; certificado emitido foi revogado."
    return 1
  fi
  rm -rf "$tmp"
  ONEPLUS_LAST_ISSUED_SERIAL="$serial"
  ok "Perfil mTLS criado: $output"
  info "Dispositivo: ${user}/${device} | serial: ${serial} | controle: ${tc_mode}"
  warn "A chave privada do dispositivo existe somente dentro deste perfil e não é armazenada no servidor. Proteja o arquivo 0600 e transfira-o por canal seguro."
}

export_password_profile() {
  openvpn_pki_valid || { error "PKI OpenVPN ausente ou inválida."; return 1; }
  [[ -r "$OPENVPN_CONF" ]] || { error "Configure o OpenVPN primeiro."; return 1; }
  rotation_is_prepared && { error "Há rotação de infraestrutura em andamento. Finalize/cancele a rotação antes de exportar perfil password genérico."; return 1; }
  local host port proto output ovpn_proto tc_mode tmp=""
  host=$(read_openvpn_value OPENVPN_PUBLIC_HOST); port=$(read_openvpn_value OPENVPN_PUBLIC_PORT); proto=$(read_openvpn_value OPENVPN_PROTO)
  [[ -n "$host" ]] || host=$(primary_ipv4)
  valid_openvpn_public_host "$host" && [[ -n "$host" ]] || { error "Host público inválido na configuração."; return 1; }
  is_valid_port "$port" || { error "Porta pública inválida na configuração."; return 1; }
  [[ "$proto" == tcp || "$proto" == udp ]] || { error "Protocolo inválido na configuração."; return 1; }
  [[ "$proto" == tcp ]] && ovpn_proto=tcp4-client || ovpn_proto=udp4
  printf "Arquivo de saída [/root/oneplus-openvpn.ovpn]: "; read -r output
  output=${output:-/root/oneplus-openvpn.ovpn}
  [[ "$output" == /* && ! -e "$output" ]] || { error "Use caminho absoluto ainda inexistente."; return 1; }
  tc_mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); tc_mode=${tc_mode:-legacy}
  if [[ "$tc_mode" == v2 ]]; then
    tmp=$(mktemp -d /tmp/oneplus-openvpn-password-v2.XXXXXX)
    generate_tlscrypt_v2_client_key "$OPENVPN_TLS_CRYPT_V2" "$tmp/tls-v2.key" generic password "$(openssl rand -hex 8 | tr '[:lower:]' '[:upper:]')" || { rm -rf "$tmp"; error "Falha ao gerar tls-crypt-v2 para o perfil."; return 1; }
  elif [[ "$tc_mode" != legacy ]]; then
    error "Modo tls-crypt incompatível com exportação password: $tc_mode"
    return 1
  fi
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
    printf '</ca>\n'
    if [[ "$tc_mode" == v2 ]]; then
      printf '<tls-crypt-v2>\n'; cat "$tmp/tls-v2.key"; printf '</tls-crypt-v2>\n'
    else
      printf '<tls-crypt>\n'; cat "$OPENVPN_TLS_CRYPT"; printf '</tls-crypt>\n'
    fi
  } > "$output"
  [[ -z "$tmp" ]] || rm -rf "$tmp"
  chown root:root "$output"; chmod 0600 "$output"
  ok "Perfil criado: ${output}"
  warn "Este perfil usa usuário/senha OnePlus e contém material do canal de controle. Trate-o como sensível."
}

next_pki_valid() {
  [[ -s "$OPENVPN_NEXT_CA_KEY" && -s "$OPENVPN_NEXT_CA_CERT" && -s "$OPENVPN_NEXT_SERVER_KEY" && -s "$OPENVPN_NEXT_SERVER_CERT" && -s "$OPENVPN_NEXT_TLS_CRYPT_V2" ]] || return 1
  openssl x509 -in "$OPENVPN_NEXT_CA_CERT" -noout >/dev/null 2>&1 || return 1
  openssl x509 -in "$OPENVPN_NEXT_SERVER_CERT" -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$OPENVPN_NEXT_CA_KEY" -passin pass: -noout >/dev/null 2>&1 || return 1
  openssl pkey -in "$OPENVPN_NEXT_SERVER_KEY" -passin pass: -noout >/dev/null 2>&1 || return 1
  openssl verify -purpose sslserver -CAfile "$OPENVPN_NEXT_CA_CERT" "$OPENVPN_NEXT_SERVER_CERT" >/dev/null 2>&1 || return 1
  local cert_pub key_pub
  cert_pub=$(openssl x509 -in "$OPENVPN_NEXT_SERVER_CERT" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$OPENVPN_NEXT_SERVER_KEY" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || return 1
  grep -Fq 'BEGIN OpenVPN tls-crypt-v2 server key' "$OPENVPN_NEXT_TLS_CRYPT_V2" 2>/dev/null
}

build_rotation_bundles() {
  rotation_is_prepared || return 1
  next_pki_valid || return 1
  openvpn_ca_db_valid || return 1
  next_ca_db_valid || return 1
  local ca_tmp crl_tmp
  ca_tmp=$(mktemp "$OPENVPN_ROTATION_DIR/.ca-bundle.XXXXXX")
  crl_tmp=$(mktemp "$OPENVPN_ROTATION_DIR/.crl-bundle.XXXXXX")
  cat "$OPENVPN_CA_CERT" "$OPENVPN_NEXT_CA_CERT" > "$ca_tmp"
  cat "$OPENVPN_CRL" "$OPENVPN_NEXT_CRL" > "$crl_tmp"
  openssl verify -CAfile "$ca_tmp" "$OPENVPN_SERVER_CERT" "$OPENVPN_NEXT_SERVER_CERT" >/dev/null 2>&1 || { rm -f "$ca_tmp" "$crl_tmp"; return 1; }
  openssl crl -in "$OPENVPN_CRL" -noout -verify -CAfile "$OPENVPN_CA_CERT" >/dev/null 2>&1 || { rm -f "$ca_tmp" "$crl_tmp"; return 1; }
  openssl crl -in "$OPENVPN_NEXT_CRL" -noout -verify -CAfile "$OPENVPN_NEXT_CA_CERT" >/dev/null 2>&1 || { rm -f "$ca_tmp" "$crl_tmp"; return 1; }
  chmod 0644 "$ca_tmp" "$crl_tmp"; chown root:root "$ca_tmp" "$crl_tmp"
  mv -f "$ca_tmp" "$OPENVPN_ROTATION_CA_BUNDLE"
  mv -f "$crl_tmp" "$OPENVPN_ROTATION_CRL_BUNDLE"
}

generate_next_openvpn_infrastructure() {
  ensure_openvpn_packages
  [[ "$(read_openvpn_value OPENVPN_AUTH_MODE)" == hybrid ]] || { error "A rotação coordenada de CA exige o modo mTLS híbrido."; return 1; }
  rotation_is_prepared && { error "Já existe uma rotação de infraestrutura preparada."; return 1; }
  local tc_mode
  tc_mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); tc_mode=${tc_mode:-legacy}
  [[ "$tc_mode" == legacy ]] || { error "A preparação completa parte do modo tls-crypt legado. Estado atual: $tc_mode"; return 1; }
  openvpn_pki_valid || { error "PKI atual inválida."; return 1; }
  ensure_openvpn_ca_db || return 1

  local tmp ext stamp state_tmp was_active=0
  tmp=$(mktemp -d /tmp/oneplus-openvpn-next.XXXXXX)
  ext="$tmp/server.ext"
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  umask 077
  info "Gerando próxima CA, certificado de servidor e chave tls-crypt-v2..."
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/ca.key" >/dev/null 2>&1
  openssl req -x509 -new -sha256 -days 3650 -key "$tmp/ca.key" -subj "/CN=OnePlus OpenVPN CA ${stamp}" -out "$tmp/ca.crt" >/dev/null 2>&1
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/server.key" >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/server.key" -subj '/CN=oneplus-server' -out "$tmp/server.csr" >/dev/null 2>&1
  cat > "$ext" <<'EOF2'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:oneplus-server
EOF2
  openssl x509 -req -sha256 -days 825 -in "$tmp/server.csr" -CA "$tmp/ca.crt" -CAkey "$tmp/ca.key" -set_serial "0x$(openssl rand -hex 16)" -extfile "$ext" -out "$tmp/server.crt" >/dev/null 2>&1
  openvpn --genkey tls-crypt-v2-server "$tmp/tls-crypt-v2-server.key" >/dev/null 2>&1 || { rm -rf "$tmp"; error "Falha ao gerar chave tls-crypt-v2 do servidor."; return 1; }

  install -d -m 0711 -o root -g root "$OPENVPN_ROTATION_DIR"
  install -d -m 0700 -o root -g root "$OPENVPN_ROTATION_NEXT" "$OPENVPN_NEXT_PKI" "$OPENVPN_NEXT_CLIENTS"
  install -m 0600 -o root -g root "$tmp/ca.key" "$OPENVPN_NEXT_CA_KEY"
  install -m 0644 -o root -g root "$tmp/ca.crt" "$OPENVPN_NEXT_CA_CERT"
  install -m 0600 -o root -g root "$tmp/server.key" "$OPENVPN_NEXT_SERVER_KEY"
  install -m 0644 -o root -g root "$tmp/server.crt" "$OPENVPN_NEXT_SERVER_CERT"
  install -m 0600 -o root -g root "$tmp/tls-crypt-v2-server.key" "$OPENVPN_NEXT_TLS_CRYPT_V2"
  rm -rf "$tmp"

  write_next_ca_config
  [[ -e "$OPENVPN_NEXT_CA_DB/index.txt" ]] || install -m 0600 -o root -g root /dev/null "$OPENVPN_NEXT_CA_DB/index.txt"
  openssl rand -hex 16 | tr '[:lower:]' '[:upper:]' > "$OPENVPN_NEXT_CA_DB/serial"
  printf '1000\n' > "$OPENVPN_NEXT_CA_DB/crlnumber"
  chmod 0600 "$OPENVPN_NEXT_CA_DB/serial" "$OPENVPN_NEXT_CA_DB/crlnumber"
  generate_next_crl || { rm -rf "$OPENVPN_ROTATION_DIR"; return 1; }

  state_tmp=$(mktemp /tmp/oneplus-openvpn-rotation-state.XXXXXX)
  cat > "$state_tmp" <<EOF2
FORMAT=1
STATE=prepared
ROTATION_ID=${stamp}
CREATED_AT=$(date +%s)
LEGACY_CA_SHA256=$(openssl x509 -in "$OPENVPN_CA_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
NEXT_CA_SHA256=$(openssl x509 -in "$OPENVPN_NEXT_CA_CERT" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
EOF2
  install -m 0600 -o root -g root "$state_tmp" "$OPENVPN_ROTATION_STATE"; rm -f "$state_tmp"
  next_pki_valid && ensure_next_ca_db && build_rotation_bundles || { rm -rf "$OPENVPN_ROTATION_DIR"; error "A próxima infraestrutura falhou na validação."; return 1; }

  systemctl is-active --quiet "$OPENVPN_SERVICE" 2>/dev/null && was_active=1
  if ! set_openvpn_value OPENVPN_TLS_CRYPT_MODE dual; then rm -rf "$OPENVPN_ROTATION_DIR"; return 1; fi
  if (( was_active )); then
    if ! systemctl restart "$OPENVPN_SERVICE" || ! sleep 2 || ! systemctl is-active --quiet "$OPENVPN_SERVICE"; then
      error "OpenVPN não aceitou o modo de migração; revertendo sem alterar a PKI ativa."
      set_openvpn_value OPENVPN_TLS_CRYPT_MODE legacy || true
      rm -rf "$OPENVPN_ROTATION_DIR"
      systemctl restart "$OPENVPN_SERVICE" 2>/dev/null || true
      return 1
    fi
  fi
  ok "Rotação preparada em modo dual: CA antiga+nova e tls-crypt legado+tls-crypt-v2 coexistem."
  warn "Nenhuma CA foi substituída. Gere e teste os novos perfis antes de finalizar."
}

issue_rotation_device_profile() {
  rotation_is_prepared || { error "Nenhuma rotação de infraestrutura preparada."; return 1; }
  local user="$1" device="$2" output="$3"
  require_managed_user "$user" || return 1
  valid_openvpn_device_name "$device" || { error "Nome de dispositivo inválido."; return 1; }
  [[ "$output" == /* && ! -e "$output" ]] || { error "Use um caminho absoluto ainda inexistente para o perfil."; return 1; }
  next_active_device_exists "$user" "$device" && { error "Já existe perfil de migração ativo para ${user}/${device}."; return 1; }
  ensure_next_ca_db || return 1
  build_rotation_bundles || return 1

  local tmp cn serial certfile metafile host port proto now not_after
  tmp=$(mktemp -d /tmp/oneplus-openvpn-migration-client.XXXXXX)
  cn="op2-$(openssl rand -hex 10)"
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/client.key" >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/client.key" -subj "/CN=${cn}" -out "$tmp/client.csr" >/dev/null 2>&1
  if ! openssl ca -batch -notext -config "$OPENVPN_NEXT_CA_DB_CONF" -extensions client_cert -days 825 -in "$tmp/client.csr" -out "$tmp/client.crt" >/dev/null 2>&1; then rm -rf "$tmp"; error "Falha ao assinar certificado com a próxima CA."; return 1; fi
  openssl verify -purpose sslclient -CAfile "$OPENVPN_NEXT_CA_CERT" "$tmp/client.crt" >/dev/null 2>&1 || { rm -rf "$tmp"; error "Certificado de migração inválido."; return 1; }
  serial=$(openssl x509 -in "$tmp/client.crt" -noout -serial | cut -d= -f2 | tr '[:lower:]' '[:upper:]')
  valid_openvpn_serial "$serial" || { rm -rf "$tmp"; return 1; }
  certfile=$(next_client_cert_file "$serial"); metafile=$(next_client_meta_file "$serial")
  [[ ! -e "$certfile" && ! -e "$metafile" ]] || { rm -rf "$tmp"; error "Colisão inesperada de serial."; return 1; }
  generate_tlscrypt_v2_client_key "$OPENVPN_NEXT_TLS_CRYPT_V2" "$tmp/tls-v2.key" "$user" "$device" "$serial" || { rm -rf "$tmp"; error "Falha ao gerar tls-crypt-v2 de migração."; return 1; }

  host=$(read_openvpn_value OPENVPN_PUBLIC_HOST); [[ -n "$host" ]] || host=$(primary_ipv4)
  port=$(read_openvpn_value OPENVPN_PUBLIC_PORT); proto=$(read_openvpn_value OPENVPN_PROTO)
  valid_openvpn_public_host "$host" && [[ -n "$host" ]] || { rm -rf "$tmp"; return 1; }
  is_valid_port "$port" || { rm -rf "$tmp"; return 1; }
  [[ "$proto" == tcp || "$proto" == udp ]] || { rm -rf "$tmp"; return 1; }
  install -m 0644 -o root -g root "$tmp/client.crt" "$certfile"
  now=$(date +%s); not_after=$(LC_ALL=C date -d "$(LC_ALL=C openssl x509 -in "$tmp/client.crt" -noout -enddate | cut -d= -f2-)" +%s 2>/dev/null || echo 0)
  cat > "$tmp/meta" <<EOF2
FORMAT=2
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
CONTROL_KEY=v2
GENERATION=next
EOF2
  install -m 0600 -o root -g root "$tmp/meta" "$metafile"
  if ! write_hybrid_profile_v2 "$output" "$host" "$port" "$proto" "$tmp/client.crt" "$tmp/client.key" "$OPENVPN_ROTATION_CA_BUNDLE" "$tmp/tls-v2.key" || ! rebuild_openvpn_authz; then
    rm -f -- "$output"
    openssl ca -batch -config "$OPENVPN_NEXT_CA_DB_CONF" -revoke "$certfile" -crl_reason cessationOfOperation >/dev/null 2>&1 || true
    generate_next_crl >/dev/null 2>&1 || true; build_rotation_bundles >/dev/null 2>&1 || true
    client_meta_set "$metafile" STATUS revoked || true
    client_meta_set "$metafile" REVOKED_AT "$(date +%s)" || true
    rebuild_openvpn_authz >/dev/null 2>&1 || true
    rm -rf "$tmp"; error "Falha ao finalizar perfil de migração/vínculo certificado-usuário."; return 1
  fi
  rm -rf "$tmp"
  ok "Perfil de migração criado: $output"
  info "${user}/${device} usa a próxima CA e tls-crypt-v2, mas já pode conectar durante a fase dual."
}

rotation_missing_devices() {
  local count=0 f user device
  shopt -s nullglob
  for f in "$OPENVPN_CLIENTS_DIR"/*.conf; do
    [[ "$(client_meta_get "$f" STATUS)" == valid ]] || continue
    user=$(client_meta_get "$f" USER); device=$(client_meta_get "$f" DEVICE)
    next_active_device_exists "$user" "$device" || ((count+=1))
  done
  shopt -u nullglob
  printf '%s' "$count"
}

rotation_next_count() {
  local count=0 f
  shopt -s nullglob
  for f in "$OPENVPN_NEXT_CLIENTS"/*.conf; do [[ "$(client_meta_get "$f" STATUS)" == valid ]] && ((count+=1)); done
  shopt -u nullglob
  printf '%s' "$count"
}

show_infrastructure_rotation_status() {
  local mode missing next_count created
  mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); mode=${mode:-legacy}
  printf "Canal de controle: %s\n" "$mode"
  if ! rotation_is_prepared; then
    printf "Rotação coordenada: nenhuma preparada.\n"
    return 0
  fi
  created=$(rotation_state_get CREATED_AT)
  printf "Rotação: PREPARADA (%s)\n" "$(rotation_state_get ROTATION_ID)"
  [[ "$created" =~ ^[0-9]+$ ]] && printf "Criada: %s\n" "$(date -d "@${created}" '+%F %T' 2>/dev/null || echo '?')"
  printf "CA atual SHA-256: %s\n" "$(rotation_state_get LEGACY_CA_SHA256)"
  printf "Próxima CA SHA-256: %s\n" "$(rotation_state_get NEXT_CA_SHA256)"
  missing=$(rotation_missing_devices); next_count=$(rotation_next_count)
  printf "Perfis novos emitidos: %s\n" "$next_count"
  printf "Dispositivos ativos ainda sem perfil novo: %s\n" "$missing"
}

list_rotation_devices() {
  local f user device status mark count=0
  printf '%-18s %-18s %-12s\n' USUARIO DISPOSITIVO MIGRACAO
  shopt -s nullglob
  for f in "$OPENVPN_CLIENTS_DIR"/*.conf; do
    status=$(client_meta_get "$f" STATUS); [[ "$status" == valid ]] || continue
    user=$(client_meta_get "$f" USER); device=$(client_meta_get "$f" DEVICE)
    if next_active_device_exists "$user" "$device"; then mark=PRONTO; else mark=PENDENTE; fi
    printf '%-18s %-18s %-12s\n' "$user" "$device" "$mark"; ((count+=1))
  done
  shopt -u nullglob
  (( count > 0 )) || printf 'Nenhum certificado mTLS atual ativo.\n'
}

issue_rotation_profile_interactive() {
  rotation_is_prepared || { error "Prepare primeiro a rotação."; return 1; }
  clear; list_rotation_devices
  local user device output
  user=$(prompt_managed_username) || return 1
  printf "Dispositivo: "; read -r device
  valid_openvpn_device_name "$device" || { error "Dispositivo inválido."; return 1; }
  output="/root/oneplus-${user}-${device}-next.ovpn"
  printf "Arquivo de saída [%s]: " "$output"; read -r v; output=${v:-$output}
  issue_rotation_device_profile "$user" "$device" "$output"
}

list_next_rotation_profiles() {
  local f user device serial status count=0
  printf '%-18s %-18s %-34s %-10s\n' USUARIO DISPOSITIVO SERIAL STATUS
  shopt -s nullglob
  for f in "$OPENVPN_NEXT_CLIENTS"/*.conf; do
    user=$(client_meta_get "$f" USER); device=$(client_meta_get "$f" DEVICE); serial=$(client_meta_get "$f" SERIAL); status=$(client_meta_get "$f" STATUS)
    printf '%-18s %-18s %-34s %-10s\n' "$user" "$device" "$serial" "$status"
    ((count+=1))
  done
  shopt -u nullglob
  (( count > 0 )) || printf 'Nenhum perfil da próxima geração emitido.\n'
}

revoke_next_openvpn_serial() {
  rotation_is_prepared || { error "Nenhuma rotação preparada."; return 1; }
  local serial="${1^^}" reason="${2:-cessationOfOperation}" metafile certfile ca_status=""
  valid_openvpn_serial "$serial" || { error "Serial inválido."; return 1; }
  metafile=$(next_client_meta_file "$serial"); certfile=$(next_client_cert_file "$serial")
  [[ -f "$metafile" && -f "$certfile" ]] || { error "Certificado da próxima geração não encontrado."; return 1; }
  [[ "$(client_meta_get "$metafile" STATUS)" == valid ]] || { warn "Certificado da próxima geração já não está ativo."; return 0; }
  ensure_next_ca_db || return 1
  case "$reason" in unspecified|keyCompromise|affiliationChanged|superseded|cessationOfOperation) ;; *) reason=cessationOfOperation ;; esac
  if ! openssl ca -batch -config "$OPENVPN_NEXT_CA_DB_CONF" -revoke "$certfile" -crl_reason "$reason" >/dev/null 2>&1; then
    ca_status=$(openssl ca -config "$OPENVPN_NEXT_CA_DB_CONF" -status "$serial" 2>&1 || true)
    grep -qi 'revoked' <<< "$ca_status" || { error "Falha ao revogar certificado da próxima geração ${serial}."; return 1; }
  fi
  client_meta_set "$metafile" STATUS revocation-pending
  client_meta_set "$metafile" REVOKED_AT "$(date +%s)"
  if ! generate_next_crl || ! build_rotation_bundles; then
    error "Certificado foi marcado no banco da próxima CA, mas CRL/bundle ainda não pôde ser atualizado."
    return 1
  fi
  client_meta_set "$metafile" STATUS revoked
  rebuild_openvpn_authz || warn "Falha ao atualizar mapa certificado/usuário."
  ok "Certificado da próxima geração ${serial} revogado. Emita um novo perfil para o dispositivo se necessário."
}

revoke_next_profile_interactive() {
  rotation_is_prepared || { error "Nenhuma rotação preparada."; return 1; }
  clear; list_next_rotation_profiles
  local serial confirm
  printf "Serial da próxima geração a revogar: "; read -r serial; serial=${serial^^}
  valid_openvpn_serial "$serial" || { error "Serial inválido."; return 1; }
  printf "Digite REVOGAR-NOVO para confirmar: "; read -r confirm
  [[ "$confirm" == REVOGAR-NOVO ]] || { info "Cancelado."; return 0; }
  revoke_next_openvpn_serial "$serial" cessationOfOperation
}

prune_openvpn_rotation_archives() {
  install -d -m 0700 -o root -g root "$OPENVPN_ARCHIVE_ROOT"
  mapfile -t old < <(find "$OPENVPN_ARCHIVE_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
  local i
  for ((i=3; i<${#old[@]}; i++)); do rm -rf -- "$OPENVPN_ARCHIVE_ROOT/${old[$i]}"; done
}

finalize_infrastructure_rotation() {
  rotation_is_prepared || { error "Nenhuma rotação preparada."; return 1; }
  [[ "$(read_openvpn_value OPENVPN_AUTH_MODE)" == hybrid ]] || { error "A promoção de CA exige OpenVPN em modo híbrido mTLS."; return 1; }
  [[ "$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE)" == dual ]] || { error "A promoção exige a fase dual ativa; operação recusada."; return 1; }
  local missing confirm id archive was_active=0 tmp_list
  missing=$(rotation_missing_devices)
  clear; show_infrastructure_rotation_status; printf '\n'; list_rotation_devices
  if (( missing > 0 )); then
    warn "Há ${missing} dispositivo(s) ativo(s) sem perfil da próxima geração. Finalizar agora fará esses perfis antigos pararem de conectar."
    printf "Digite FINALIZAR-FORCAR para continuar mesmo assim: "; read -r confirm
    [[ "$confirm" == FINALIZAR-FORCAR ]] || { info "Cancelado."; return 0; }
  else
    warn "A finalização troca a CA/certificado do servidor e remove o tls-crypt compartilhado do runtime. Conexões serão reiniciadas."
    printf "Digite FINALIZAR para promover a nova infraestrutura: "; read -r confirm
    [[ "$confirm" == FINALIZAR ]] || { info "Cancelado."; return 0; }
  fi
  next_pki_valid && next_ca_db_valid && build_rotation_bundles || { error "Próxima infraestrutura inválida."; return 1; }
  id=$(rotation_state_get ROTATION_ID); [[ "$id" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || id=$(date -u +%Y%m%dT%H%M%SZ)
  archive="$OPENVPN_ARCHIVE_ROOT/$id"
  install -d -m 0700 -o root -g root "$archive"
  tmp_list=$(mktemp /tmp/oneplus-openvpn-archive-list.XXXXXX)
  local path rel
  for path in "$OPENVPN_PKI" "$OPENVPN_CA_DB" "$OPENVPN_CLIENTS_DIR" "$OPENVPN_TLS_CRYPT" "$OPENVPN_TLS_CRYPT_V2" "$OPENVPN_CONF"; do
    [[ -e "$path" && "$path" == /* && "$path" != / ]] || continue
    rel=${path#/}
    printf '%s\n' "$rel" >> "$tmp_list"
  done
  [[ -s "$tmp_list" ]] || { rm -f "$tmp_list"; error "Nenhum estado OpenVPN encontrado para rollback."; return 1; }
  tar -C / -czf "$archive/pre-finalize.tar.gz" -T "$tmp_list"; rm -f "$tmp_list"; chmod 0600 "$archive/pre-finalize.tar.gz"
  systemctl is-active --quiet "$OPENVPN_SERVICE" 2>/dev/null && was_active=1
  systemctl stop "$OPENVPN_SERVICE" 2>/dev/null || true

  rm -rf "$OPENVPN_PKI" "$OPENVPN_CA_DB" "$OPENVPN_CLIENTS_DIR"
  install -d -m 0700 -o root -g root "$OPENVPN_PKI" "$OPENVPN_CLIENTS_DIR"
  install -d -m 0711 -o root -g root "$OPENVPN_CA_DB"
  rsync -a --delete "$OPENVPN_NEXT_PKI/" "$OPENVPN_PKI/"
  rsync -a --delete "$OPENVPN_NEXT_CA_DB/" "$OPENVPN_CA_DB/"
  rsync -a --delete "$OPENVPN_NEXT_CLIENTS/" "$OPENVPN_CLIENTS_DIR/"
  install -m 0600 -o root -g root "$OPENVPN_NEXT_TLS_CRYPT_V2" "$OPENVPN_TLS_CRYPT_V2"
  rm -f "$OPENVPN_TLS_CRYPT"
  set_openvpn_value OPENVPN_TLS_CRYPT_MODE v2 || true
  write_openvpn_ca_config
  if ! openvpn_pki_valid || ! openvpn_ca_db_valid; then
    error "PKI promovida falhou na validação; restaurando geração anterior."
  elif (( ! was_active )) || (systemctl start "$OPENVPN_SERVICE" && sleep 2 && systemctl is-active --quiet "$OPENVPN_SERVICE"); then
    printf 'FINALIZED_AT=%s\n' "$(date +%s)" > "$archive/finalized.conf"; chmod 0600 "$archive/finalized.conf"
    rm -rf "$OPENVPN_ROTATION_DIR"
    rebuild_openvpn_authz || warn "Falha ao reconstruir mapa certificado/usuário após promoção."
    prune_openvpn_rotation_archives
    ok "Nova CA e certificado de servidor promovidos. O runtime agora usa somente tls-crypt-v2 por perfil."
    warn "O rollback local contém chaves antigas e fica protegido em ${archive}; mantenha backups age atualizados."
    return 0
  else
    error "OpenVPN não iniciou com a nova infraestrutura; executando rollback."
  fi

  systemctl stop "$OPENVPN_SERVICE" 2>/dev/null || true
  rm -rf "$OPENVPN_PKI" "$OPENVPN_CA_DB" "$OPENVPN_CLIENTS_DIR"
  rm -f "$OPENVPN_TLS_CRYPT" "$OPENVPN_TLS_CRYPT_V2" "$OPENVPN_CONF"
  tar -C / -xzf "$archive/pre-finalize.tar.gz"
  (( was_active )) && systemctl start "$OPENVPN_SERVICE" 2>/dev/null || true
  return 1
}

cancel_infrastructure_rotation() {
  rotation_is_prepared || { info "Nenhuma rotação preparada."; return 0; }
  local confirm was_active=0
  warn "Perfis emitidos pela próxima CA deixarão de funcionar se a preparação for cancelada."
  printf "Digite CANCELAR-ROTACAO: "; read -r confirm
  [[ "$confirm" == CANCELAR-ROTACAO ]] || { info "Cancelado."; return 0; }
  systemctl is-active --quiet "$OPENVPN_SERVICE" 2>/dev/null && was_active=1
  set_openvpn_value OPENVPN_TLS_CRYPT_MODE legacy || return 1
  if (( was_active )); then
    if ! systemctl restart "$OPENVPN_SERVICE" || ! sleep 2 || ! systemctl is-active --quiet "$OPENVPN_SERVICE"; then
      set_openvpn_value OPENVPN_TLS_CRYPT_MODE dual || true
      systemctl restart "$OPENVPN_SERVICE" 2>/dev/null || true
      error "Não foi possível voltar ao modo legado; preparação mantida."
      return 1
    fi
  fi
  rm -rf "$OPENVPN_ROTATION_DIR"
  rebuild_openvpn_authz || warn "Falha ao reconstruir mapa certificado/usuário após cancelamento."
  ok "Preparação cancelada; PKI ativa original foi preservada."
}

rotate_server_certificate_same_ca() {
  rotation_is_prepared && { error "Finalize ou cancele a rotação de CA antes de rotacionar somente o certificado do servidor."; return 1; }
  openvpn_pki_material_valid || { error "PKI atual inválida."; return 1; }
  local confirm tmp ext stamp archive was_active=0
  warn "Esta operação mantém a mesma CA e material de controle; perfis clientes não precisam ser reemitidos, mas as conexões OpenVPN serão reiniciadas."
  printf "Digite ROTACIONAR-SERVIDOR: "; read -r confirm
  [[ "$confirm" == ROTACIONAR-SERVIDOR ]] || { info "Cancelado."; return 0; }
  tmp=$(mktemp -d /tmp/oneplus-openvpn-server-rotate.XXXXXX); ext="$tmp/server.ext"; stamp=$(date -u +%Y%m%dT%H%M%SZ)
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$tmp/server.key" >/dev/null 2>&1
  openssl req -new -sha256 -key "$tmp/server.key" -subj '/CN=oneplus-server' -out "$tmp/server.csr" >/dev/null 2>&1
  cat > "$ext" <<'EOF2'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:oneplus-server
EOF2
  openssl x509 -req -sha256 -days 825 -in "$tmp/server.csr" -CA "$OPENVPN_CA_CERT" -CAkey "$OPENVPN_CA_KEY" -set_serial "0x$(openssl rand -hex 16)" -extfile "$ext" -out "$tmp/server.crt" >/dev/null 2>&1
  openssl verify -purpose sslserver -CAfile "$OPENVPN_CA_CERT" "$tmp/server.crt" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  archive="$OPENVPN_ARCHIVE_ROOT/server-$stamp"; install -d -m 0700 -o root -g root "$archive"
  install -m 0600 -o root -g root "$OPENVPN_SERVER_KEY" "$archive/server.key"
  install -m 0644 -o root -g root "$OPENVPN_SERVER_CERT" "$archive/server.crt"
  systemctl is-active --quiet "$OPENVPN_SERVICE" 2>/dev/null && was_active=1
  install -m 0600 -o root -g root "$tmp/server.key" "$OPENVPN_SERVER_KEY"
  install -m 0644 -o root -g root "$tmp/server.crt" "$OPENVPN_SERVER_CERT"
  rm -rf "$tmp"
  if openvpn_pki_valid && { (( ! was_active )) || { systemctl restart "$OPENVPN_SERVICE" && sleep 2 && systemctl is-active --quiet "$OPENVPN_SERVICE"; }; }; then
    prune_openvpn_rotation_archives
    ok "Certificado do servidor rotacionado mantendo a mesma CA."
    show_openvpn_certificate
    return 0
  fi
  error "Falha após rotacionar certificado; restaurando anterior."
  install -m 0600 -o root -g root "$archive/server.key" "$OPENVPN_SERVER_KEY"
  install -m 0644 -o root -g root "$archive/server.crt" "$OPENVPN_SERVER_CERT"
  (( was_active )) && systemctl restart "$OPENVPN_SERVICE" 2>/dev/null || true
  return 1
}

module_openvpn_infrastructure_rotation() {
  while true; do
    clear
    printf "%bOnePlus • Rotação da infraestrutura OpenVPN%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    show_infrastructure_rotation_status
    printf "\n1) Rotacionar somente certificado do servidor (mesma CA)\n"
    printf "2) Preparar nova CA + servidor + tls-crypt-v2\n"
    printf "3) Listar progresso de migração\n"
    printf "4) Emitir perfil da próxima geração\n"
    printf "5) Revogar perfil da próxima geração\n"
    printf "6) Finalizar/promover nova infraestrutura\n"
    printf "7) Cancelar preparação\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) rotate_server_certificate_same_ca; pause ;;
      2) generate_next_openvpn_infrastructure; pause ;;
      3) clear; show_infrastructure_rotation_status; printf '\n'; list_rotation_devices; pause ;;
      4) issue_rotation_profile_interactive; pause ;;
      5) revoke_next_profile_interactive; pause ;;
      6) finalize_infrastructure_rotation; pause ;;
      7) cancel_infrastructure_rotation; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
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
  rebuild_openvpn_authz || warn "Não foi possível atualizar imediatamente o mapa certificado/usuário."
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
  local mode tc_mode
  mode=$(read_openvpn_value OPENVPN_AUTH_MODE); mode=${mode:-password}
  tc_mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); tc_mode=${tc_mode:-legacy}
  valid_openvpn_auth_mode "$mode" || return 1
  valid_openvpn_tls_crypt_mode "$tc_mode" || return 1
  [[ -r "$OPENVPN_PAM" ]] || return 1
  if [[ "$mode" == hybrid ]]; then
    openvpn_ca_db_valid || return 1
    [[ -x /opt/oneplus/libexec/openvpn_bind_identity.py && -d "$OPENVPN_AUTHZ_DIR" ]] || return 1
  fi
  if [[ "$tc_mode" == dual ]]; then
    rotation_is_prepared || return 1
    next_pki_valid && next_ca_db_valid && build_rotation_bundles || return 1
  fi
}

openvpn_port_in_use() {
  local bind="$1" port="$2" proto="$3"
  if [[ "$proto" == tcp ]]; then tcp_port_in_use "$port"; else udp_bind_port_in_use "$bind" "$port"; fi
}

configure_openvpn() {
  rotation_is_prepared && { error "Há uma rotação de infraestrutura em andamento. Finalize ou cancele antes de reconfigurar o serviço."; return 1; }
  ensure_openvpn_packages; ensure_openvpn_pam; generate_openvpn_pki || return 1
  local bind="127.0.0.1" port="1194" proto="tcp" public_host="" public_port="443" network="10.8.0.0" max_clients="128" full_tunnel="no" push_dns1="" push_dns2="" auth_mode="password" tls_crypt_mode="legacy" v tmp old_conf had_old=0 was_active=0
  [[ -r "$OPENVPN_CONF" ]] && {
    bind=$(read_openvpn_value OPENVPN_BIND); bind=${bind:-127.0.0.1}; port=$(read_openvpn_value OPENVPN_PORT); port=${port:-1194}; proto=$(read_openvpn_value OPENVPN_PROTO); proto=${proto:-tcp}
    public_host=$(read_openvpn_value OPENVPN_PUBLIC_HOST); public_port=$(read_openvpn_value OPENVPN_PUBLIC_PORT); public_port=${public_port:-443}; network=$(read_openvpn_value OPENVPN_NETWORK); network=${network:-10.8.0.0}
    max_clients=$(read_openvpn_value OPENVPN_MAX_CLIENTS); max_clients=${max_clients:-128}; full_tunnel=$(read_openvpn_value OPENVPN_FULL_TUNNEL); full_tunnel=${full_tunnel:-no}; push_dns1=$(read_openvpn_value OPENVPN_PUSH_DNS1); push_dns2=$(read_openvpn_value OPENVPN_PUSH_DNS2)
    auth_mode=$(read_openvpn_value OPENVPN_AUTH_MODE); auth_mode=${auth_mode:-password}
    tls_crypt_mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); tls_crypt_mode=${tls_crypt_mode:-legacy}
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
    rebuild_openvpn_authz || return 1
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
OPENVPN_TLS_CRYPT_MODE=${tls_crypt_mode}
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
  local mode tc_mode
  mode=$(read_openvpn_value OPENVPN_AUTH_MODE); mode=${mode:-password}
  tc_mode=$(read_openvpn_value OPENVPN_TLS_CRYPT_MODE); tc_mode=${tc_mode:-legacy}
  printf "Versão: %s\n" "$(openvpn --version 2>/dev/null | head -1 || echo ausente)"
  printf "Serviço: %b\n" "$(service_state "$OPENVPN_SERVICE")"
  printf "Autenticação: %s\n" "$([[ "$mode" == hybrid ]] && echo 'usuário/senha + mTLS por dispositivo' || echo 'usuário/senha')"
  printf "Canal de controle: %s\n" "$tc_mode"
  rotation_is_prepared && printf "Rotação de infraestrutura: PREPARADA (%s)\n" "$(rotation_state_get ROTATION_ID)"
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

initialize_openvpn_module() { require_root; ensure_openvpn_pam; rebuild_openvpn_authz; }

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
    printf "1) Configurar e habilitar\n2) Gerar/verificar PKI do servidor\n3) Exportar perfil .ovpn\n4) Dispositivos mTLS / revogação / rotação\n5) Rotação da infraestrutura PKI / tls-crypt\n6) Status/clientes\n7) Mostrar certificado do servidor\n8) Reiniciar\n9) Logs\n10) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) configure_openvpn; pause ;;
      2) generate_openvpn_pki; pause ;;
      3) export_openvpn_profile; pause ;;
      4) module_openvpn_devices ;;
      5) module_openvpn_infrastructure_rotation ;;
      6) clear; show_openvpn_status; pause ;;
      7) show_openvpn_certificate; pause ;;
      8) systemctl restart "$OPENVPN_SERVICE"; pause ;;
      9) journalctl -u "$OPENVPN_SERVICE" -n 120 --no-pager; pause ;;
      10) systemctl disable --now "$OPENVPN_SERVICE" 2>/dev/null || true; pause ;;
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
    rotation-status) show_infrastructure_rotation_status ;;
    revoke) [[ -n "${2:-}" ]] || { echo "Uso: $0 revoke SERIAL"; exit 2; }; revoke_openvpn_serial "$2" cessationOfOperation ;;
    *) echo "Uso: $0 {init|pki|ca-db|maintenance|health|rotation-status|revoke SERIAL}"; exit 2 ;;
  esac
fi
