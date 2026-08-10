#!/usr/bin/env bash

DNSTT_VERSION="v1.20260501.0"
DNSTT_BIN="/usr/local/lib/oneplus/bin/dnstt-server"
SLOWDNS_CONF="/etc/oneplus/slowdns.env"
SLOWDNS_DIR="/etc/oneplus/slowdns"
DNSTT_VERSION_FILE="/var/lib/oneplus/dnstt.version"

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
  if [[ -x "$DNSTT_BIN" && -r "$DNSTT_VERSION_FILE" && "$(cat "$DNSTT_VERSION_FILE")" == "$DNSTT_VERSION" ]]; then
    info "dnstt-server ${DNSTT_VERSION} já está instalado."
    return 0
  fi
  local go_bin
  go_bin=$(find_go_124) || {
    error "Go 1.24+ não encontrado. Execute novamente o instalador do OnePlus."
    return 1
  }
  local gobin
  gobin=$(mktemp -d /tmp/oneplus-go.XXXXXX)
  info "Compilando dnstt ${DNSTT_VERSION} com verificação de módulos Go..."
  GOBIN="$gobin" GOTOOLCHAIN=auto "$go_bin" install "www.bamsoftware.com/git/dnstt.git/dnstt-server@${DNSTT_VERSION}"
  install -D -m 0755 "$gobin/dnstt-server" "$DNSTT_BIN"
  printf "%s\n" "$DNSTT_VERSION" > "$DNSTT_VERSION_FILE"
  chmod 0644 "$DNSTT_VERSION_FILE"
  rm -rf "$gobin"
  ok "dnstt-server ${DNSTT_VERSION} instalado."
}

ensure_slowdns_keys() {
  install -d -m 0750 -o root -g oneplus-dnstt "$SLOWDNS_DIR"
  if [[ ! -s "$SLOWDNS_DIR/server.key" || ! -s "$SLOWDNS_DIR/server.pub" ]]; then
    "$DNSTT_BIN" -gen-key -privkey-file "$SLOWDNS_DIR/server.key" -pubkey-file "$SLOWDNS_DIR/server.pub"
    chown root:oneplus-dnstt "$SLOWDNS_DIR/server.key" "$SLOWDNS_DIR/server.pub"
    chmod 0640 "$SLOWDNS_DIR/server.key"
    chmod 0644 "$SLOWDNS_DIR/server.pub"
    ok "Par de chaves SlowDNS gerado."
  fi
}

configure_slowdns() {
  local domain bind port public_ip upstream mtu suggested v
  suggested=$(primary_ipv4)
  bind="0.0.0.0"
  port=53
  upstream="127.0.0.1:22"
  mtu=1232

  printf "Domínio delegado para o túnel (ex.: dns.exemplo.com): "
  read -r domain
  is_valid_domain "$domain" || { error "Domínio inválido."; return 1; }

  printf "Endereço IPv4 local para escuta [%s]: " "$bind"
  read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 de escuta inválido."; return 1; }

  printf "Porta UDP [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }

  printf "IPv4 público apontado no DNS%s: " "${suggested:+ [sugestão local: $suggested]}"
  read -r public_ip
  public_ip=${public_ip:-$suggested}
  is_valid_ipv4 "$public_ip" || { error "IPv4 público inválido."; return 1; }

  printf "Destino TCP do túnel [%s]: " "$upstream"; read -r v; upstream=${v:-$upstream}
  is_valid_host_port "$upstream" || { error "Destino TCP inválido. Use host:porta (ex.: 127.0.0.1:22)."; return 1; }
  printf "MTU DNS [%s]: " "$mtu"; read -r v; mtu=${v:-$mtu}
  [[ "$mtu" =~ ^[0-9]+$ ]] && (( 10#$mtu >= 512 && 10#$mtu <= 4096 )) || { error "MTU inválido (512-4096)."; return 1; }

  if ss -lunH | awk '{print $5}' | grep -Eq "(^|\])${bind}:${port}$|^${bind}:${port}$|^0\.0\.0\.0:${port}$|^\*:${port}$"; then
    warn "Já existe um socket UDP compatível com a porta ${port}. Verifique conflitos antes de iniciar."
  fi

  ensure_slowdns_keys
  cat > "$SLOWDNS_CONF" <<EOF2
SLOWDNS_DOMAIN=${domain}
SLOWDNS_BIND=${bind}
SLOWDNS_PORT=${port}
SLOWDNS_PUBLIC_IP=${public_ip}
SLOWDNS_UPSTREAM=${upstream}
SLOWDNS_MTU=${mtu}
SLOWDNS_PRIVKEY=/etc/oneplus/slowdns/server.key
SLOWDNS_PUBKEY=/etc/oneplus/slowdns/server.pub
EOF2
  chmod 0640 "$SLOWDNS_CONF"
  chown root:oneplus-dnstt "$SLOWDNS_CONF"
  systemctl daemon-reload
  systemctl enable --now oneplus-slowdns.service
  sleep 1
  if systemctl is-active --quiet oneplus-slowdns.service; then
    ok "SlowDNS ativo em ${bind}:${port}/UDP."
    printf "\nChave pública para os clientes:\n"
    cat "$SLOWDNS_DIR/server.pub"
    printf "\n\nDNS necessário: delegue o subdomínio %s por registro NS para um hostname com registro A apontando para %s.\n" "$domain" "$public_ip"
  else
    error "O serviço não iniciou. Últimos logs:"
    journalctl -u oneplus-slowdns.service -n 30 --no-pager || true
    return 1
  fi
}

module_slowdns() {
  while true; do
    clear
    printf "%bOnePlus • SlowDNS / DNSTT%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Versão alvo: %s\nBinário: %s\nServiço: %s\n\n" "$DNSTT_VERSION" \
      "$([[ -x "$DNSTT_BIN" ]] && echo instalado || echo ausente)" \
      "$(service_state oneplus-slowdns.service)"
    printf "1) Instalar/reinstalar dnstt\n2) Configurar e habilitar\n3) Mostrar chave pública\n4) Reiniciar\n5) Logs\n6) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) rm -f "$DNSTT_BIN"; install_slowdns_binary; pause ;;
      2) [[ -x "$DNSTT_BIN" ]] || install_slowdns_binary; configure_slowdns; pause ;;
      3) [[ -r "$SLOWDNS_DIR/server.pub" ]] && cat "$SLOWDNS_DIR/server.pub" || warn "Chave ainda não gerada."; pause ;;
      4) systemctl restart oneplus-slowdns.service; pause ;;
      5) journalctl -u oneplus-slowdns.service -n 100 --no-pager; pause ;;
      6) systemctl disable --now oneplus-slowdns.service 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  case "${1:-}" in
    install-binary) install_slowdns_binary ;;
    *) echo "Uso: $0 install-binary"; exit 2 ;;
  esac
fi
