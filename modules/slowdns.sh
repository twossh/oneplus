#!/usr/bin/env bash

DNSTT_VERSION="v1.20260501.0"
DNSTT_BIN="/usr/local/lib/oneplus/bin/dnstt-server"
SLOWDNS_CONF="/etc/oneplus/slowdns.env"
SLOWDNS_DIR="/etc/oneplus/slowdns"
DNSTT_VERSION_FILE="/var/lib/oneplus/dnstt.version"
DNSTT_HASH_FILE="/var/lib/oneplus/dnstt.sha256"
SLOWDNS_SERVICE="oneplus-slowdns.service"

read_slowdns_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$SLOWDNS_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

find_go_124() {
  local candidates=(/usr/lib/go-1.24/bin/go /usr/local/go/bin/go "$(command -v go 2>/dev/null || true)")
  local go_bin ver
  for go_bin in "${candidates[@]}"; do
    [[ -n "$go_bin" && -x "$go_bin" ]] || continue
    ver=$($go_bin env GOVERSION 2>/dev/null | sed 's/^go//')
    if dpkg --compare-versions "$ver" ge "1.24"; then
      printf "%s" "$go_bin"
      return 0
    fi
  done
  return 1
}

install_slowdns_binary() {
  require_root
  local force="${1:-0}"
  if [[ "$force" != 1 && -x "$DNSTT_BIN" && -r "$DNSTT_VERSION_FILE" && -r "$DNSTT_HASH_FILE" ]] &&
     [[ "$(cat "$DNSTT_VERSION_FILE")" == "$DNSTT_VERSION" ]] &&
     sha256sum -c "$DNSTT_HASH_FILE" >/dev/null 2>&1; then
    info "dnstt-server ${DNSTT_VERSION} já está instalado e íntegro."
    return 0
  fi
  local go_bin gobin was_active=0
  go_bin=$(find_go_124) || {
    error "Go 1.24+ não encontrado. Execute novamente o instalador do OnePlus."
    return 1
  }
  gobin=$(mktemp -d /tmp/oneplus-go.XXXXXX)
  trap 'rm -rf "${gobin:-}"' RETURN
  info "Compilando dnstt ${DNSTT_VERSION} com verificação de módulos Go."
  GOBIN="$gobin" GOTOOLCHAIN=auto GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE= GONOPROXY= \
    "$go_bin" install "www.bamsoftware.com/git/dnstt.git/dnstt-server@${DNSTT_VERSION}"
  [[ -x "$gobin/dnstt-server" ]] || { error "A compilação do dnstt não gerou o executável esperado."; return 1; }
  if ! "$gobin/dnstt-server" -h 2>&1 | grep -Eqi 'usage|dnstt'; then
    error "O dnstt-server compilado não respondeu como esperado ao teste local."
    return 1
  fi

  local had_old_bin=0 had_old_version=0 had_old_hash=0
  [[ -x "$DNSTT_BIN" ]] && { cp -a "$DNSTT_BIN" "$gobin/old-dnstt-server"; had_old_bin=1; }
  [[ -r "$DNSTT_VERSION_FILE" ]] && { cp -a "$DNSTT_VERSION_FILE" "$gobin/old-version"; had_old_version=1; }
  [[ -r "$DNSTT_HASH_FILE" ]] && { cp -a "$DNSTT_HASH_FILE" "$gobin/old-hash"; had_old_hash=1; }

  systemctl is-active --quiet "$SLOWDNS_SERVICE" 2>/dev/null && was_active=1
  install -D -m 0755 "$gobin/dnstt-server" "$DNSTT_BIN"
  printf "%s\n" "$DNSTT_VERSION" > "$DNSTT_VERSION_FILE"
  sha256sum "$DNSTT_BIN" > "$DNSTT_HASH_FILE"
  chmod 0644 "$DNSTT_VERSION_FILE" "$DNSTT_HASH_FILE"
  if (( was_active )) && ! systemctl restart "$SLOWDNS_SERVICE"; then
    error "Novo dnstt não reiniciou; restaurando o binário anterior."
    if (( had_old_bin )); then install -D -m 0755 "$gobin/old-dnstt-server" "$DNSTT_BIN"; else rm -f "$DNSTT_BIN"; fi
    if (( had_old_version )); then install -m 0644 "$gobin/old-version" "$DNSTT_VERSION_FILE"; else rm -f "$DNSTT_VERSION_FILE"; fi
    if (( had_old_hash )); then install -m 0644 "$gobin/old-hash" "$DNSTT_HASH_FILE"; else rm -f "$DNSTT_HASH_FILE"; fi
    (( had_old_bin )) && systemctl restart "$SLOWDNS_SERVICE" 2>/dev/null || true
    return 1
  fi
  rm -rf "$gobin"
  trap - RETURN
  ok "dnstt-server ${DNSTT_VERSION} instalado."
}

ensure_slowdns_keys() {
  install -d -m 0750 -o root -g oneplus-dnstt "$SLOWDNS_DIR"
  if [[ ! -s "$SLOWDNS_DIR/server.key" || ! -s "$SLOWDNS_DIR/server.pub" ]]; then
    "$DNSTT_BIN" -gen-key -privkey-file "$SLOWDNS_DIR/server.key" -pubkey-file "$SLOWDNS_DIR/server.pub"
    chown root:oneplus-dnstt "$SLOWDNS_DIR/server.key"
    chown root:root "$SLOWDNS_DIR/server.pub"
    chmod 0640 "$SLOWDNS_DIR/server.key"
    chmod 0644 "$SLOWDNS_DIR/server.pub"
    ok "Par de chaves SlowDNS gerado localmente."
  fi
}

configure_slowdns() {
  local domain="" bind="" port="53" public_ip="" upstream="127.0.0.1:22" mtu="1232"
  local suggested v tmp old_conf had_old=0 was_active=0
  suggested=$(primary_ipv4)

  if [[ -r "$SLOWDNS_CONF" ]]; then
    domain=$(read_slowdns_value SLOWDNS_DOMAIN)
    bind=$(read_slowdns_value SLOWDNS_BIND)
    port=$(read_slowdns_value SLOWDNS_PORT); port=${port:-53}
    public_ip=$(read_slowdns_value SLOWDNS_PUBLIC_IP)
    upstream=$(read_slowdns_value SLOWDNS_UPSTREAM); upstream=${upstream:-127.0.0.1:22}
    mtu=$(read_slowdns_value SLOWDNS_MTU); mtu=${mtu:-1232}
  fi
  if [[ -z "$bind" || "$bind" == "0.0.0.0" ]]; then
    bind=${suggested:-0.0.0.0}
  fi

  printf "Domínio delegado para o túnel%s: " "${domain:+ [${domain}]}"
  read -r v; domain=${v:-$domain}
  is_valid_domain "$domain" || { error "Domínio inválido."; return 1; }

  printf "IPv4 local da interface para escuta [%s]: " "$bind"
  read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 de escuta inválido."; return 1; }
  if [[ "$bind" != "0.0.0.0" ]] && ! ipv4_is_local_address "$bind"; then
    error "O endereço ${bind} não está atribuído a uma interface local. Em VPS com NAT, use aqui o IP local e informe o IP público no próximo campo."
    return 1
  fi
  [[ "$bind" != "0.0.0.0" ]] || warn "Escutar em 0.0.0.0:53 pode conflitar com resolvedores locais. Prefira o IPv4 específico da interface."

  printf "Porta UDP [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }

  if [[ -n "$public_ip" ]]; then
    printf "IPv4 público usado no registro A [%s]: " "$public_ip"
  else
    printf "IPv4 público usado no registro A%s: " "${suggested:+ [IP local detectado: ${suggested}]}"
  fi
  read -r v; public_ip=${v:-$public_ip}
  [[ -n "$public_ip" ]] || { error "Informe explicitamente o IPv4 público do servidor/NAT."; return 1; }
  is_valid_ipv4 "$public_ip" || { error "IPv4 público inválido."; return 1; }

  printf "Destino TCP do túnel [%s]: " "$upstream"; read -r v; upstream=${v:-$upstream}
  is_valid_host_port "$upstream" || { error "Destino TCP inválido. Use host:porta (ex.: 127.0.0.1:22)."; return 1; }
  printf "MTU DNS [%s]: " "$mtu"; read -r v; mtu=${v:-$mtu}
  [[ "$mtu" =~ ^[0-9]+$ ]] && (( 10#$mtu >= 512 && 10#$mtu <= 4096 )) || { error "MTU inválido (512..4096)."; return 1; }

  ensure_slowdns_keys
  systemctl is-active --quiet "$SLOWDNS_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-slowdns-old.XXXXXX)
  if [[ -e "$SLOWDNS_CONF" ]]; then cp -a "$SLOWDNS_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$SLOWDNS_SERVICE" 2>/dev/null || true

  if udp_bind_port_in_use "$bind" "$port"; then
    error "A combinação ${bind}:${port}/UDP conflita com outro socket. O OnePlus não desativa systemd-resolved nem outros serviços automaticamente."
    if (( had_old )); then install -m 0640 -o root -g oneplus-dnstt "$old_conf" "$SLOWDNS_CONF"; fi
    (( was_active && had_old )) && systemctl start "$SLOWDNS_SERVICE" 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-slowdns.XXXXXX)
  cat > "$tmp" <<EOF2
SLOWDNS_DOMAIN=${domain}
SLOWDNS_BIND=${bind}
SLOWDNS_PORT=${port}
SLOWDNS_PUBLIC_IP=${public_ip}
SLOWDNS_UPSTREAM=${upstream}
SLOWDNS_MTU=${mtu}
SLOWDNS_PRIVKEY=/etc/oneplus/slowdns/server.key
SLOWDNS_PUBKEY=/etc/oneplus/slowdns/server.pub
EOF2
  install -m 0640 -o root -g oneplus-dnstt "$tmp" "$SLOWDNS_CONF"
  rm -f "$tmp"
  systemctl daemon-reload

  if systemctl enable --now "$SLOWDNS_SERVICE" && sleep 1 && systemctl is-active --quiet "$SLOWDNS_SERVICE"; then
    rm -f "$old_conf"
    ok "SlowDNS ativo em ${bind}:${port}/UDP."
    printf "\nChave pública para os clientes:\n"
    cat "$SLOWDNS_DIR/server.pub"
    printf "\n\nDNS necessário: delegue %s por NS para um hostname cujo registro A aponte para %s.\n" "$domain" "$public_ip"
    return 0
  fi

  error "SlowDNS não iniciou; restaurando configuração anterior."
  journalctl -u "$SLOWDNS_SERVICE" -n 40 --no-pager || true
  systemctl disable --now "$SLOWDNS_SERVICE" 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g oneplus-dnstt "$old_conf" "$SLOWDNS_CONF"
    (( was_active )) && systemctl enable --now "$SLOWDNS_SERVICE" 2>/dev/null || true
  else
    rm -f "$SLOWDNS_CONF"
  fi
  rm -f "$old_conf"
  return 1
}

module_slowdns() {
  while true; do
    clear
    printf "%bOnePlus • SlowDNS / DNSTT%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Versão alvo: %s\nBinário: %s\nServiço: %b\n\n" "$DNSTT_VERSION" \
      "$([[ -x "$DNSTT_BIN" ]] && echo instalado || echo ausente)" \
      "$(service_state "$SLOWDNS_SERVICE")"
    printf "1) Instalar/recompilar dnstt\n2) Configurar e habilitar\n3) Mostrar chave pública\n4) Reiniciar\n5) Logs\n6) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) install_slowdns_binary 1; pause ;;
      2) [[ -x "$DNSTT_BIN" ]] || install_slowdns_binary; configure_slowdns; pause ;;
      3) [[ -r "$SLOWDNS_DIR/server.pub" ]] && cat "$SLOWDNS_DIR/server.pub" || warn "Chave ainda não gerada."; pause ;;
      4) systemctl restart "$SLOWDNS_SERVICE"; pause ;;
      5) journalctl -u "$SLOWDNS_SERVICE" -n 100 --no-pager; pause ;;
      6) systemctl disable --now "$SLOWDNS_SERVICE" 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  case "${1:-}" in
    install-binary) install_slowdns_binary ;;
    reinstall-binary) install_slowdns_binary 1 ;;
    *) echo "Uso: $0 install-binary|reinstall-binary"; exit 2 ;;
  esac
fi
