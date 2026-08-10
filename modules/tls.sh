#!/usr/bin/env bash

TLS_CONF="/etc/oneplus/tls.env"
TLS_DIR="/etc/oneplus/tls"
TLS_CERT="$TLS_DIR/server.crt"
TLS_KEY="$TLS_DIR/server.key"
TLS_SERVICE="oneplus-tls.service"

read_tls_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$TLS_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

ensure_tls_dirs() {
  install -d -m 0750 -o root -g oneplus-tls "$TLS_DIR"
}

validate_cert_key_pair() {
  local cert="$1" key="$2" cert_pub key_pub
  [[ -r "$cert" && -r "$key" ]] || { error "Certificado ou chave não podem ser lidos."; return 1; }
  openssl x509 -in "$cert" -noout >/dev/null 2>&1 || { error "Certificado X.509 inválido."; return 1; }
  openssl pkey -in "$key" -passin pass: -noout >/dev/null 2>&1 || {
    error "Chave privada inválida ou protegida por senha. Use uma chave não criptografada e proteja-a por permissões do sistema."
    return 1
  }
  cert_pub=$(openssl x509 -in "$cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  key_pub=$(openssl pkey -in "$key" -passin pass: -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
  [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || { error "A chave privada não corresponde ao certificado."; return 1; }
}

install_tls_pair() {
  local cert="$1" key="$2"
  validate_cert_key_pair "$cert" "$key" || return 1
  ensure_tls_dirs
  install -m 0644 -o root -g root "$cert" "$TLS_CERT"
  install -m 0640 -o root -g oneplus-tls "$key" "$TLS_KEY"
}

generate_self_signed_tls() {
  local identity="$1" tmpdir san
  if is_valid_ipv4 "$identity"; then
    san="IP:${identity}"
  elif is_valid_domain "$identity"; then
    san="DNS:${identity}"
  else
    error "Use um domínio completo ou IPv4 válido como identidade do certificado."
    return 1
  fi
  tmpdir=$(mktemp -d /tmp/oneplus-tls-cert.XXXXXX)
  trap 'rm -rf "${tmpdir:-}"' RETURN
  openssl req -x509 -newkey rsa:3072 -nodes -sha256 -days 825 \
    -subj "/CN=${identity}" -addext "subjectAltName=${san}" \
    -keyout "$tmpdir/server.key" -out "$tmpdir/server.crt" >/dev/null 2>&1
  install_tls_pair "$tmpdir/server.crt" "$tmpdir/server.key"
  rm -rf "$tmpdir"
  trap - RETURN
  ok "Certificado autoassinado criado para ${identity}."
  warn "Use autoassinado somente em testes ou clientes com pin explícito. Para uso público, prefira certificado emitido por CA/ACME."
}

configure_tls_endpoint() {
  local bind="0.0.0.0" port="443" upstream="127.0.0.1:22" minver="TLSv1.2" v
  local tmp old_conf had_old=0 was_active=0
  [[ -r "$TLS_CONF" ]] && {
    bind=$(read_tls_value TLS_BIND); bind=${bind:-0.0.0.0}
    port=$(read_tls_value TLS_PORT); port=${port:-443}
    upstream=$(read_tls_value TLS_UPSTREAM); upstream=${upstream:-127.0.0.1:22}
    minver=$(read_tls_value TLS_MIN_VERSION); minver=${minver:-TLSv1.2}
  }

  [[ -s "$TLS_CERT" && -s "$TLS_KEY" ]] || { error "Instale ou gere um certificado antes de habilitar TLS."; return 1; }
  validate_cert_key_pair "$TLS_CERT" "$TLS_KEY" || return 1

  printf "IPv4 de escuta [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 inválido."; return 1; }
  printf "Porta TLS [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }
  printf "Destino TCP após TLS [%s]: " "$upstream"; read -r v; upstream=${v:-$upstream}
  is_valid_host_port "$upstream" || { error "Destino inválido. Use host:porta."; return 1; }
  printf "TLS mínimo [1=TLSv1.2, 2=TLSv1.3] [%s]: " "$minver"; read -r v
  case "${v:-$minver}" in
    1|TLSv1.2) minver=TLSv1.2 ;;
    2|TLSv1.3) minver=TLSv1.3 ;;
    *) error "Versão TLS inválida."; return 1 ;;
  esac

  systemctl is-active --quiet "$TLS_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-tls-old.XXXXXX)
  if [[ -e "$TLS_CONF" ]]; then cp -a "$TLS_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$TLS_SERVICE" 2>/dev/null || true
  if tcp_port_in_use "$port"; then
    error "A porta TCP ${port} já está em uso por outro serviço."
    if (( had_old )); then install -m 0640 -o root -g oneplus-tls "$old_conf" "$TLS_CONF"; fi
    (( was_active && had_old )) && systemctl start "$TLS_SERVICE" 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-tls.XXXXXX)
  cat > "$tmp" <<EOF2
TLS_BIND=${bind}
TLS_PORT=${port}
TLS_UPSTREAM=${upstream}
TLS_MIN_VERSION=${minver}
EOF2
  install -m 0640 -o root -g oneplus-tls "$tmp" "$TLS_CONF"
  rm -f "$tmp"
  systemctl daemon-reload
  if systemctl enable --now "$TLS_SERVICE" && sleep 1 && systemctl is-active --quiet "$TLS_SERVICE"; then
    rm -f "$old_conf"
    ok "TLS/Stunnel ativo em ${bind}:${port}, destino ${upstream}, mínimo ${minver}."
    return 0
  fi

  error "TLS/Stunnel não iniciou; restaurando configuração anterior."
  journalctl -u "$TLS_SERVICE" -n 40 --no-pager || true
  systemctl disable --now "$TLS_SERVICE" 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g oneplus-tls "$old_conf" "$TLS_CONF"
    (( was_active )) && systemctl enable --now "$TLS_SERVICE" 2>/dev/null || true
  fi
  rm -f "$old_conf"
  return 1
}

import_tls_certificate() {
  local cert key
  printf "Caminho do certificado/fullchain PEM: "; read -r cert
  printf "Caminho da chave privada PEM: "; read -r key
  [[ "$cert" == /* && "$key" == /* ]] || { error "Use caminhos absolutos."; return 1; }
  install_tls_pair "$cert" "$key" || return 1
  ok "Certificado e chave instalados em ${TLS_DIR}."
}

prompt_self_signed() {
  local identity suggested
  suggested=$(primary_ipv4)
  printf "Domínio ou IPv4 do certificado autoassinado%s: " "${suggested:+ [${suggested}]}"
  read -r identity
  identity=${identity:-$suggested}
  generate_self_signed_tls "$identity"
}

show_tls_certificate() {
  if [[ ! -s "$TLS_CERT" ]]; then
    warn "Certificado TLS ainda não instalado."
    return 0
  fi
  openssl x509 -in "$TLS_CERT" -noout -subject -issuer -serial -dates -fingerprint -sha256
  if openssl x509 -checkend 86400 -noout -in "$TLS_CERT" >/dev/null 2>&1; then
    ok "Certificado válido por mais de 24 horas."
  else
    warn "Certificado expirado ou expira em menos de 24 horas."
  fi
}

module_tls() {
  while true; do
    clear
    printf "%bOnePlus • TLS / Stunnel%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Stunnel: %s\nServiço: %b\nCertificado: %s\n\n" \
      "$(command -v stunnel4 2>/dev/null || command -v stunnel 2>/dev/null || echo ausente)" \
      "$(service_state "$TLS_SERVICE")" \
      "$([[ -s "$TLS_CERT" ]] && echo instalado || echo ausente)"
    printf "1) Importar certificado existente\n2) Gerar certificado autoassinado (teste)\n3) Configurar e habilitar TLS\n4) Mostrar certificado\n5) Reiniciar\n6) Logs\n7) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) import_tls_certificate; pause ;;
      2) prompt_self_signed; pause ;;
      3) configure_tls_endpoint; pause ;;
      4) show_tls_certificate; pause ;;
      5) systemctl restart "$TLS_SERVICE"; pause ;;
      6) journalctl -u "$TLS_SERVICE" -n 100 --no-pager; pause ;;
      7) systemctl disable --now "$TLS_SERVICE" 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
