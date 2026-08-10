#!/usr/bin/env bash

BADVPN_REPO="https://github.com/ambrop72/badvpn.git"
BADVPN_COMMIT="07268f02706e78e282e19641b5d1d41e8e89bf31"
BADVPN_BIN="/usr/local/lib/oneplus/bin/badvpn-udpgw"
BADVPN_CONF="/etc/oneplus/badvpn.env"
BADVPN_HASH_FILE="/var/lib/oneplus/badvpn.sha256"
BADVPN_COMMIT_FILE="/var/lib/oneplus/badvpn-source.commit"
BADVPN_SERVICE="oneplus-badvpn.service"

read_badvpn_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$BADVPN_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

install_badvpn_binary() {
  require_root
  local force="${1:-0}"
  if [[ "$force" != 1 && -x "$BADVPN_BIN" && -r "$BADVPN_COMMIT_FILE" && -r "$BADVPN_HASH_FILE" ]] &&
     [[ "$(cat "$BADVPN_COMMIT_FILE")" == "$BADVPN_COMMIT" ]] &&
     sha256sum -c "$BADVPN_HASH_FILE" >/dev/null 2>&1; then
    info "BadVPN UDPGW fixado já está instalado e íntegro."
    return 0
  fi

  warn "O upstream original do BadVPN está arquivado. O OnePlus compila somente o UDPGW a partir de um commit fixado e não baixa binários de terceiros."
  local work src build endian actual_commit was_active=0
  work=$(mktemp -d /tmp/oneplus-badvpn.XXXXXX)
  src="$work/src"
  build="$work/build"
  trap 'rm -rf "${work:-}"' RETURN

  git clone -q --no-checkout "$BADVPN_REPO" "$src"
  git -C "$src" checkout -q --detach "$BADVPN_COMMIT"
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
    SRCDIR="$src" CC=gcc ENDIAN="$endian" KERNEL=2.6 \
      CFLAGS="-O2 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2" \
      bash "$src/compile-udpgw.sh"
  )
  [[ -x "$build/udpgw" ]] || { error "A compilação do UDPGW não gerou o executável esperado."; return 1; }
  if ldd "$build/udpgw" 2>&1 | grep -q 'not found'; then
    error "O executável UDPGW compilado possui biblioteca dinâmica ausente."
    return 1
  fi

  local had_old_bin=0 had_old_commit=0 had_old_hash=0
  [[ -x "$BADVPN_BIN" ]] && { cp -a "$BADVPN_BIN" "$work/old-udpgw"; had_old_bin=1; }
  [[ -r "$BADVPN_COMMIT_FILE" ]] && { cp -a "$BADVPN_COMMIT_FILE" "$work/old-commit"; had_old_commit=1; }
  [[ -r "$BADVPN_HASH_FILE" ]] && { cp -a "$BADVPN_HASH_FILE" "$work/old-hash"; had_old_hash=1; }

  systemctl is-active --quiet "$BADVPN_SERVICE" 2>/dev/null && was_active=1
  install -D -m 0755 "$build/udpgw" "$BADVPN_BIN"
  printf "%s\n" "$BADVPN_COMMIT" > "$BADVPN_COMMIT_FILE"
  sha256sum "$BADVPN_BIN" > "$BADVPN_HASH_FILE"
  chmod 0644 "$BADVPN_COMMIT_FILE" "$BADVPN_HASH_FILE"

  if (( was_active )) && ! systemctl restart "$BADVPN_SERVICE"; then
    error "Novo UDPGW não reiniciou; restaurando o binário anterior."
    if (( had_old_bin )); then install -D -m 0755 "$work/old-udpgw" "$BADVPN_BIN"; else rm -f "$BADVPN_BIN"; fi
    if (( had_old_commit )); then install -m 0644 "$work/old-commit" "$BADVPN_COMMIT_FILE"; else rm -f "$BADVPN_COMMIT_FILE"; fi
    if (( had_old_hash )); then install -m 0644 "$work/old-hash" "$BADVPN_HASH_FILE"; else rm -f "$BADVPN_HASH_FILE"; fi
    (( had_old_bin )) && systemctl restart "$BADVPN_SERVICE" 2>/dev/null || true
    return 1
  fi
  ok "BadVPN UDPGW compilado e instalado a partir do commit fixado ${BADVPN_COMMIT:0:12}."
  rm -rf "$work"
  trap - RETURN
}

configure_badvpn() {
  local bind="127.0.0.1" port="7300" max_clients="500" max_conn="64" sndbuf="1048576"
  local existing v confirm tmp old_conf had_old=0 was_active=0

  if [[ -r "$BADVPN_CONF" ]]; then
    existing=$(read_badvpn_value BADVPN_BIND)
    if [[ "$existing" =~ ^([0-9.]+):([0-9]+)$ ]]; then
      bind=${BASH_REMATCH[1]}; port=${BASH_REMATCH[2]}
    fi
    v=$(read_badvpn_value BADVPN_MAX_CLIENTS); max_clients=${v:-$max_clients}
    v=$(read_badvpn_value BADVPN_MAX_CONNECTIONS); max_conn=${v:-$max_conn}
    v=$(read_badvpn_value BADVPN_SNDBUF); sndbuf=${v:-$sndbuf}
  fi

  printf "Endereço IPv4 de escuta [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "Endereço de escuta inválido."; return 1; }
  printf "Porta TCP [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }
  (( 10#$port >= 1024 )) || { error "UDPGW OnePlus roda sem root; escolha porta TCP 1024 ou superior."; return 1; }

  if [[ "$bind" != "127.0.0.1" ]]; then
    warn "UDPGW normalmente deve permanecer em loopback e ser acessado através do túnel SSH."
    printf "Digite EXPOR para permitir escuta fora do loopback: "; read -r confirm
    [[ "$confirm" == "EXPOR" ]] || { info "Configuração cancelada."; return 1; }
  fi

  printf "Máximo de clientes [%s]: " "$max_clients"; read -r v; max_clients=${v:-$max_clients}
  is_valid_positive_int "$max_clients" && (( 10#$max_clients <= 10000 )) || { error "Use 1..10000 clientes."; return 1; }
  printf "Máximo de conexões por cliente [%s]: " "$max_conn"; read -r v; max_conn=${v:-$max_conn}
  is_valid_positive_int "$max_conn" && (( 10#$max_conn <= 1000 )) || { error "Use 1..1000 conexões por cliente."; return 1; }
  [[ "$sndbuf" =~ ^[0-9]+$ ]] && (( 10#$sndbuf >= 65536 && 10#$sndbuf <= 16777216 )) || sndbuf=1048576

  systemctl is-active --quiet "$BADVPN_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-badvpn-old.XXXXXX)
  if [[ -e "$BADVPN_CONF" ]]; then cp -a "$BADVPN_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$BADVPN_SERVICE" 2>/dev/null || true

  if tcp_port_in_use "$port"; then
    error "A porta TCP ${port} já está em uso."
    if (( had_old )); then install -m 0640 -o root -g oneplus-badvpn "$old_conf" "$BADVPN_CONF"; fi
    (( was_active && had_old )) && systemctl start "$BADVPN_SERVICE" 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-badvpn.XXXXXX)
  cat > "$tmp" <<EOF2
BADVPN_BIND=${bind}:${port}
BADVPN_LOGLEVEL=warning
BADVPN_MAX_CLIENTS=${max_clients}
BADVPN_MAX_CONNECTIONS=${max_conn}
BADVPN_SNDBUF=${sndbuf}
EOF2
  install -m 0640 -o root -g oneplus-badvpn "$tmp" "$BADVPN_CONF"
  rm -f "$tmp"
  systemctl daemon-reload

  if systemctl enable --now "$BADVPN_SERVICE" && sleep 1 && systemctl is-active --quiet "$BADVPN_SERVICE"; then
    rm -f "$old_conf"
    ok "BadVPN UDPGW ativo em ${bind}:${port}."
    return 0
  fi

  error "BadVPN não iniciou; restaurando configuração anterior."
  journalctl -u "$BADVPN_SERVICE" -n 40 --no-pager || true
  systemctl disable --now "$BADVPN_SERVICE" 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g oneplus-badvpn "$old_conf" "$BADVPN_CONF"
    (( was_active )) && systemctl enable --now "$BADVPN_SERVICE" 2>/dev/null || true
  else
    rm -f "$BADVPN_CONF"
  fi
  rm -f "$old_conf"
  return 1
}

module_badvpn() {
  while true; do
    clear
    printf "%bOnePlus • BadVPN UDPGW%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Fonte: commit fixado %s\nBinário: %s\nServiço: %b\nConfig:  %s\n\n" \
      "${BADVPN_COMMIT:0:12}" \
      "$([[ -x "$BADVPN_BIN" ]] && echo instalado || echo ausente)" \
      "$(service_state "$BADVPN_SERVICE")" "$BADVPN_CONF"
    printf "1) Instalar/recompilar UDPGW\n2) Configurar e habilitar\n3) Reiniciar\n4) Logs\n5) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) install_badvpn_binary 1; pause ;;
      2) [[ -x "$BADVPN_BIN" ]] || install_badvpn_binary; configure_badvpn; pause ;;
      3) systemctl restart "$BADVPN_SERVICE"; pause ;;
      4) journalctl -u "$BADVPN_SERVICE" -n 100 --no-pager; pause ;;
      5) systemctl disable --now "$BADVPN_SERVICE" 2>/dev/null || true; pause ;;
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
    reinstall-binary) install_badvpn_binary 1 ;;
    *) echo "Uso: $0 install-binary|reinstall-binary"; exit 2 ;;
  esac
fi
