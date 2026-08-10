#!/usr/bin/env bash

BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
BADVPN_COMMIT="07268f02706e78e282e19641b5d1d41e8e89bf31"
BADVPN_BIN="/usr/local/lib/oneplus/bin/badvpn-udpgw"
BADVPN_CONF="/etc/oneplus/badvpn.env"

install_badvpn_binary() {
  require_root
  if [[ -x "$BADVPN_BIN" ]]; then
    info "BadVPN UDPGW já está instalado."
    return 0
  fi
  warn "BadVPN upstream está arquivado desde 2021. O OnePlus compila somente o UDPGW para compatibilidade."
  local work src build endian
  work=$(mktemp -d /tmp/oneplus-badvpn.XXXXXX)
  src="$work/src"
  build="$work/build"
  trap 'rm -rf "${work:-}"' RETURN
  git clone -q --no-checkout "$BADVPN_REPO" "$src"
  git -C "$src" checkout -q --detach "$BADVPN_COMMIT"
  local actual_commit
  actual_commit=$(git -C "$src" rev-parse HEAD)
  [[ "$actual_commit" == "$BADVPN_COMMIT" ]] || {
    error "Commit BadVPN inesperado: $actual_commit"
    return 1
  }
  mkdir -p "$build"
  endian=$(printf '#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__\nlittle\n#else\nbig\n#endif\n' | gcc -E -P -x c - | tr -d '[:space:]')
  [[ "$endian" == "little" || "$endian" == "big" ]] || { error "Não foi possível detectar endianness."; return 1; }
  (
    cd "$build"
    SRCDIR="$src" CC=gcc ENDIAN="$endian" KERNEL=2.6 CFLAGS="-O2 -pipe" bash "$src/compile-udpgw.sh"
  )
  install -D -m 0755 "$build/udpgw" "$BADVPN_BIN"
  printf "%s\n" "$BADVPN_COMMIT" > /var/lib/oneplus/badvpn-source.commit
  chmod 0644 /var/lib/oneplus/badvpn-source.commit
  "$BADVPN_BIN" --help >/dev/null 2>&1 || true
  ok "BadVPN UDPGW compilado e instalado."
  rm -rf "$work"
  trap - RETURN
}

configure_badvpn() {
  local bind port max_clients max_conn sndbuf
  bind="127.0.0.1"
  port=7300
  max_clients=500
  max_conn=64
  sndbuf=1048576
  printf "Endereço de escuta [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  if [[ "$bind" != "::1" ]] && ! is_valid_ipv4 "$bind"; then
    error "Endereço de escuta inválido."
    return 1
  fi
  printf "Porta [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }
  if [[ "$bind" != "127.0.0.1" && "$bind" != "::1" ]]; then
    warn "UDPGW normalmente deve permanecer em loopback para ser acessado pelo túnel SSH."
    printf "Digite EXPOR para continuar: "; read -r confirm
    [[ "$confirm" == "EXPOR" ]] || return 1
  fi
  printf "Máximo de clientes [%s]: " "$max_clients"; read -r v; max_clients=${v:-$max_clients}
  is_valid_positive_int "$max_clients" || { error "Máximo de clientes inválido."; return 1; }
  printf "Máximo de conexões por cliente [%s]: " "$max_conn"; read -r v; max_conn=${v:-$max_conn}
  is_valid_positive_int "$max_conn" || { error "Máximo de conexões inválido."; return 1; }
  cat > "$BADVPN_CONF" <<EOF2
BADVPN_BIND=${bind}:${port}
BADVPN_LOGLEVEL=warning
BADVPN_MAX_CLIENTS=${max_clients}
BADVPN_MAX_CONNECTIONS=${max_conn}
BADVPN_SNDBUF=${sndbuf}
EOF2
  chmod 0640 "$BADVPN_CONF"
  chown root:oneplus-badvpn "$BADVPN_CONF"
  systemctl daemon-reload
  systemctl enable --now oneplus-badvpn.service
  ok "BadVPN configurado em ${bind}:${port}."
}

module_badvpn() {
  while true; do
    clear
    printf "%bOnePlus • BadVPN UDPGW%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Binário: %s\nServiço: %s\nConfig:  %s\n\n" \
      "$([[ -x "$BADVPN_BIN" ]] && echo instalado || echo ausente)" \
      "$(service_state oneplus-badvpn.service)" "$BADVPN_CONF"
    printf "1) Instalar/recompilar UDPGW\n2) Configurar e habilitar\n3) Reiniciar\n4) Logs\n5) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) rm -f "$BADVPN_BIN"; install_badvpn_binary; pause ;;
      2) [[ -x "$BADVPN_BIN" ]] || install_badvpn_binary; configure_badvpn; pause ;;
      3) systemctl restart oneplus-badvpn.service; pause ;;
      4) journalctl -u oneplus-badvpn.service -n 100 --no-pager; pause ;;
      5) systemctl disable --now oneplus-badvpn.service 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # shellcheck source=../lib/common.sh
  source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
  case "${1:-}" in
    install-binary) install_badvpn_binary ;;
    *) echo "Uso: $0 install-binary"; exit 2 ;;
  esac
fi
