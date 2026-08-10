#!/usr/bin/env bash
set -Eeuo pipefail

OPENVPN_CONF="/etc/oneplus/openvpn.env"
OPENVPN_DIR="/etc/oneplus/openvpn"
OPENVPN_PKI="$OPENVPN_DIR/pki"
OPENVPN_CA_KEY="$OPENVPN_PKI/ca.key"
OPENVPN_CA_CERT="$OPENVPN_PKI/ca.crt"
OPENVPN_SERVER_KEY="$OPENVPN_PKI/server.key"
OPENVPN_SERVER_CERT="$OPENVPN_PKI/server.crt"
OPENVPN_TLS_CRYPT="$OPENVPN_DIR/tls-crypt.key"
OPENVPN_PAM="/etc/pam.d/oneplus-openvpn"
OPENVPN_SERVICE="oneplus-openvpn.service"
OPENVPN_MGMT="/run/oneplus-openvpn/management.sock"

read_openvpn_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$OPENVPN_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

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
  trap 'rm -rf "${tmp:-}"' RETURN
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
  trap - RETURN

  openvpn_pki_valid || { error "A PKI gerada falhou na validação."; return 1; }
  ok "PKI OpenVPN criada localmente. A chave privada da CA nunca é exportada para clientes."
}

openvpn_port_in_use() {
  local bind="$1" port="$2" proto="$3"
  if [[ "$proto" == tcp ]]; then
    tcp_port_in_use "$port"
  else
    udp_bind_port_in_use "$bind" "$port"
  fi
}

configure_openvpn() {
  ensure_openvpn_packages
  ensure_openvpn_pam
  generate_openvpn_pki || return 1

  local bind="127.0.0.1" port="1194" proto="tcp" public_host="" public_port="443"
  local network="10.8.0.0" max_clients="128" v tmp old_conf had_old=0 was_active=0
  [[ -r "$OPENVPN_CONF" ]] && {
    bind=$(read_openvpn_value OPENVPN_BIND); bind=${bind:-127.0.0.1}
    port=$(read_openvpn_value OPENVPN_PORT); port=${port:-1194}
    proto=$(read_openvpn_value OPENVPN_PROTO); proto=${proto:-tcp}
    public_host=$(read_openvpn_value OPENVPN_PUBLIC_HOST)
    public_port=$(read_openvpn_value OPENVPN_PUBLIC_PORT); public_port=${public_port:-443}
    network=$(read_openvpn_value OPENVPN_NETWORK); network=${network:-10.8.0.0}
    max_clients=$(read_openvpn_value OPENVPN_MAX_CLIENTS); max_clients=${max_clients:-128}
  }

  printf "IPv4 de escuta OpenVPN [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 inválido."; return 1; }
  if [[ "$bind" != "0.0.0.0" && "$bind" != "127.0.0.1" ]] && ! ipv4_is_local_address "$bind"; then
    error "O IPv4 ${bind} não pertence a uma interface local."
    return 1
  fi
  printf "Protocolo [tcp/udp] [%s]: " "$proto"; read -r v; proto=${v:-$proto}
  [[ "$proto" == tcp || "$proto" == udp ]] || { error "Protocolo inválido."; return 1; }
  printf "Porta interna OpenVPN [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }
  printf "Rede VPN privada /24 [%s]: " "$network"; read -r v; network=${v:-$network}
  valid_private_24_network "$network" || { error "Use uma rede privada RFC1918 /24 terminada em .0 (ex.: 10.8.0.0)."; return 1; }
  printf "Máximo de clientes [%s]: " "$max_clients"; read -r v; max_clients=${v:-$max_clients}
  [[ "$max_clients" =~ ^[0-9]+$ ]] && (( 10#$max_clients >= 1 && 10#$max_clients <= 250 )) || { error "Máximo inválido (1..250 para a rede /24)."; return 1; }

  local suggested
  suggested=${public_host:-$(primary_ipv4)}
  printf "Host/IP público para o perfil cliente [%s]: " "$suggested"; read -r v; public_host=${v:-$suggested}
  valid_openvpn_public_host "$public_host" && [[ -n "$public_host" ]] || { error "Host/IP público inválido."; return 1; }
  printf "Porta pública para o perfil cliente [%s]: " "$public_port"; read -r v; public_port=${v:-$public_port}
  is_valid_port "$public_port" || { error "Porta pública inválida."; return 1; }

  warn "O OpenVPN autentica somente contas do grupo oneplus-users via PAM; senhas não são armazenadas pelo OnePlus."
  warn "O perfil atual usa usuário/senha sem certificado cliente individual. É mais simples para as contas OnePlus, mas oferece menos proteção de identidade do cliente do que mTLS com certificado por dispositivo."
  warn "Esta fase NÃO cria NAT/masquerade nem altera firewall. A VPN fornece o túnel e a rede privada; roteamento de Internet será opcional na fase de firewall."
  if [[ "$bind" == 127.0.0.1 ]]; then
    info "Bind loopback selecionado: ideal para publicar OpenVPN através do multiplexador sslh."
  else
    warn "OpenVPN será exposto diretamente em ${bind}:${port}/${proto}."
  fi

  systemctl is-active --quiet "$OPENVPN_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-openvpn-old.XXXXXX)
  if [[ -e "$OPENVPN_CONF" ]]; then cp -a "$OPENVPN_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$OPENVPN_SERVICE" 2>/dev/null || true
  if openvpn_port_in_use "$bind" "$port" "$proto"; then
    error "A porta ${port}/${proto} já está em uso."
    if (( had_old )); then install -m 0640 -o root -g root "$old_conf" "$OPENVPN_CONF"; fi
    (( was_active && had_old )) && systemctl start "$OPENVPN_SERVICE" 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-openvpn.XXXXXX)
  cat > "$tmp" <<EOF2
OPENVPN_BIND=${bind}
OPENVPN_PORT=${port}
OPENVPN_PROTO=${proto}
OPENVPN_PUBLIC_HOST=${public_host}
OPENVPN_PUBLIC_PORT=${public_port}
OPENVPN_NETWORK=${network}
OPENVPN_MAX_CLIENTS=${max_clients}
EOF2
  install -m 0640 -o root -g root "$tmp" "$OPENVPN_CONF"
  rm -f "$tmp"
  systemctl daemon-reload
  if systemctl enable --now "$OPENVPN_SERVICE" && sleep 2 && systemctl is-active --quiet "$OPENVPN_SERVICE"; then
    rm -f "$old_conf"
    ok "OpenVPN ativo em ${bind}:${port}/${proto}."
    [[ "$public_port" == "$port" && "$bind" != 127.0.0.1 ]] || info "Perfil cliente anunciará ${public_host}:${public_port}; confirme que um listener/multiplexador encaminha para o OpenVPN."
    return 0
  fi

  error "OpenVPN não iniciou; restaurando configuração anterior."
  journalctl -u "$OPENVPN_SERVICE" -n 60 --no-pager || true
  systemctl disable --now "$OPENVPN_SERVICE" 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g root "$old_conf" "$OPENVPN_CONF"
    (( was_active )) && systemctl enable --now "$OPENVPN_SERVICE" 2>/dev/null || true
  fi
  rm -f "$old_conf"
  return 1
}

export_openvpn_profile() {
  openvpn_pki_valid || { error "PKI OpenVPN ausente ou inválida."; return 1; }
  [[ -r "$OPENVPN_CONF" ]] || { error "Configure o OpenVPN primeiro."; return 1; }
  local host port proto output ovpn_proto
  host=$(read_openvpn_value OPENVPN_PUBLIC_HOST)
  port=$(read_openvpn_value OPENVPN_PUBLIC_PORT)
  proto=$(read_openvpn_value OPENVPN_PROTO)
  [[ -n "$host" ]] || host=$(primary_ipv4)
  valid_openvpn_public_host "$host" && [[ -n "$host" ]] || { error "Host público inválido na configuração."; return 1; }
  is_valid_port "$port" || { error "Porta pública inválida na configuração."; return 1; }
  [[ "$proto" == tcp || "$proto" == udp ]] || { error "Protocolo inválido na configuração."; return 1; }
  [[ "$proto" == tcp ]] && ovpn_proto=tcp4-client || ovpn_proto=udp4
  printf "Arquivo de saída [/root/oneplus-openvpn.ovpn]: "; read -r output
  output=${output:-/root/oneplus-openvpn.ovpn}
  [[ "$output" == /* ]] || { error "Use caminho absoluto."; return 1; }

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
    cat <<'EOF2'
</ca>
<tls-crypt>
EOF2
    cat "$OPENVPN_TLS_CRYPT"
    cat <<'EOF2'
</tls-crypt>
EOF2
  } > "$output"
  chown root:root "$output"
  chmod 0600 "$output"
  ok "Perfil criado: ${output}"
  warn "O perfil contém a chave compartilhada tls-crypt. Trate-o como material sensível e distribua por canal seguro."
}

show_openvpn_status() {
  printf "Versão: %s\n" "$(openvpn --version 2>/dev/null | head -1 || echo ausente)"
  printf "Serviço: %b\n" "$(service_state "$OPENVPN_SERVICE")"
  if [[ -r "$OPENVPN_CONF" ]]; then
    printf "Escuta: %s:%s/%s\n" "$(read_openvpn_value OPENVPN_BIND)" "$(read_openvpn_value OPENVPN_PORT)" "$(read_openvpn_value OPENVPN_PROTO)"
    printf "Público: %s:%s\n" "$(read_openvpn_value OPENVPN_PUBLIC_HOST)" "$(read_openvpn_value OPENVPN_PUBLIC_PORT)"
    printf "Rede: %s/24\n" "$(read_openvpn_value OPENVPN_NETWORK)"
  fi
  printf "PKI: %s\n" "$([[ -s "$OPENVPN_SERVER_CERT" ]] && echo instalada || echo ausente)"
  if [[ -S "$OPENVPN_MGMT" ]]; then
    printf "\nClientes/status:\n"
    /opt/oneplus/libexec/openvpn_manager.py status 2>/dev/null | sed -n '1,80p' || true
  fi
}

show_openvpn_certificate() {
  openvpn_pki_valid || { warn "PKI ausente ou inválida."; return 0; }
  openssl x509 -in "$OPENVPN_SERVER_CERT" -noout -subject -issuer -serial -dates -fingerprint -sha256
}

initialize_openvpn_module() {
  require_root
  ensure_openvpn_pam
}

module_openvpn() {
  while true; do
    clear
    printf "%bOnePlus • OpenVPN%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Serviço: %b | PKI: %s | PAM: somente oneplus-users\n\n" \
      "$(service_state "$OPENVPN_SERVICE")" "$([[ -s "$OPENVPN_SERVER_CERT" ]] && echo OK || echo ausente)"
    printf "1) Configurar e habilitar\n2) Gerar/verificar PKI\n3) Exportar perfil .ovpn\n4) Status/clientes\n5) Mostrar certificado\n6) Reiniciar\n7) Logs\n8) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) configure_openvpn; pause ;;
      2) generate_openvpn_pki; pause ;;
      3) export_openvpn_profile; pause ;;
      4) clear; show_openvpn_status; pause ;;
      5) show_openvpn_certificate; pause ;;
      6) systemctl restart "$OPENVPN_SERVICE"; pause ;;
      7) journalctl -u "$OPENVPN_SERVICE" -n 120 --no-pager; pause ;;
      8) systemctl disable --now "$OPENVPN_SERVICE" 2>/dev/null || true; pause ;;
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
    *) echo "Uso: $0 {init|pki}"; exit 2 ;;
  esac
fi
