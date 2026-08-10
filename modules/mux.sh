#!/usr/bin/env bash
set -Eeuo pipefail

MUX_CONF="/etc/oneplus/mux.env"
MUX_SERVICE="oneplus-mux.service"

read_mux_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$MUX_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

mux_loopback_target_valid() {
  local value="$1" host port
  [[ "$value" == *:* ]] || return 1
  host=${value%:*}; port=${value##*:}
  is_valid_port "$port" || return 1
  [[ "$host" == 127.0.0.1 || "$host" == localhost ]]
}

prompt_mux_bool() {
  local label="$1" current="$2" answer
  if [[ "$current" == yes ]]; then
    printf "%s [S/n]: " "$label"
    read -r answer
    case "${answer:-s}" in s|S|sim|SIM|Sim) printf yes ;; n|N|nao|não|NAO|NÃO) printf no ;; *) return 1 ;; esac
  else
    printf "%s [s/N]: " "$label"
    read -r answer
    case "${answer:-n}" in s|S|sim|SIM|Sim) printf yes ;; n|N|nao|não|NAO|NÃO) printf no ;; *) return 1 ;; esac
  fi
}

configure_mux() {
  command -v sslh-select >/dev/null 2>&1 || { info "Instalando sslh do Ubuntu..."; apt-get update; apt-get install -y --no-install-recommends sslh; }
  local bind="0.0.0.0" port="443" timeout="5" ssh_enable=yes ssh_target="127.0.0.1:22"
  local tls_enable=no tls_target="127.0.0.1:8443" ovpn_enable=yes ovpn_target="127.0.0.1:1194"
  local http_enable=no http_target="127.0.0.1:8080" timeout_proto=ssh v tmp old_conf had_old=0 was_active=0 count
  [[ -r "$MUX_CONF" ]] && {
    bind=$(read_mux_value MUX_BIND); bind=${bind:-0.0.0.0}
    port=$(read_mux_value MUX_PORT); port=${port:-443}
    timeout=$(read_mux_value MUX_TIMEOUT); timeout=${timeout:-5}
    ssh_enable=$(read_mux_value MUX_SSH_ENABLE); ssh_enable=${ssh_enable:-yes}
    ssh_target=$(read_mux_value MUX_SSH_TARGET); ssh_target=${ssh_target:-127.0.0.1:22}
    tls_enable=$(read_mux_value MUX_TLS_ENABLE); tls_enable=${tls_enable:-no}
    tls_target=$(read_mux_value MUX_TLS_TARGET); tls_target=${tls_target:-127.0.0.1:8443}
    ovpn_enable=$(read_mux_value MUX_OPENVPN_ENABLE); ovpn_enable=${ovpn_enable:-yes}
    ovpn_target=$(read_mux_value MUX_OPENVPN_TARGET); ovpn_target=${ovpn_target:-127.0.0.1:1194}
    http_enable=$(read_mux_value MUX_HTTP_ENABLE); http_enable=${http_enable:-no}
    http_target=$(read_mux_value MUX_HTTP_TARGET); http_target=${http_target:-127.0.0.1:8080}
    timeout_proto=$(read_mux_value MUX_TIMEOUT_PROTOCOL); timeout_proto=${timeout_proto:-ssh}
  }

  printf "IPv4 de escuta pública [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 inválido."; return 1; }
  if [[ "$bind" != 0.0.0.0 && "$bind" != 127.0.0.1 ]] && ! ipv4_is_local_address "$bind"; then error "IPv4 não local."; return 1; fi
  printf "Porta TCP compartilhada [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }
  printf "Timeout de detecção em segundos [%s]: " "$timeout"; read -r v; timeout=${v:-$timeout}
  [[ "$timeout" =~ ^[0-9]+$ ]] && (( 10#$timeout >= 1 && 10#$timeout <= 30 )) || { error "Timeout inválido (1..30)."; return 1; }

  ssh_enable=$(prompt_mux_bool "Habilitar detecção SSH?" "$ssh_enable") || { error "Resposta inválida."; return 1; }
  printf "Destino SSH loopback [%s]: " "$ssh_target"; read -r v; ssh_target=${v:-$ssh_target}
  mux_loopback_target_valid "$ssh_target" || { error "Destino SSH deve ser 127.0.0.1:porta ou localhost:porta."; return 1; }

  tls_enable=$(prompt_mux_bool "Habilitar detecção TLS?" "$tls_enable") || { error "Resposta inválida."; return 1; }
  printf "Destino TLS loopback [%s]: " "$tls_target"; read -r v; tls_target=${v:-$tls_target}
  mux_loopback_target_valid "$tls_target" || { error "Destino TLS inválido."; return 1; }

  ovpn_enable=$(prompt_mux_bool "Habilitar detecção OpenVPN TCP?" "$ovpn_enable") || { error "Resposta inválida."; return 1; }
  printf "Destino OpenVPN loopback [%s]: " "$ovpn_target"; read -r v; ovpn_target=${v:-$ovpn_target}
  mux_loopback_target_valid "$ovpn_target" || { error "Destino OpenVPN inválido."; return 1; }

  http_enable=$(prompt_mux_bool "Habilitar detecção HTTP/WebSocket?" "$http_enable") || { error "Resposta inválida."; return 1; }
  printf "Destino HTTP loopback [%s]: " "$http_target"; read -r v; http_target=${v:-$http_target}
  mux_loopback_target_valid "$http_target" || { error "Destino HTTP inválido."; return 1; }

  count=0
  [[ "$ssh_enable" == yes ]] && ((count+=1))
  [[ "$tls_enable" == yes ]] && ((count+=1))
  [[ "$ovpn_enable" == yes ]] && ((count+=1))
  [[ "$http_enable" == yes ]] && ((count+=1))
  (( count >= 2 )) || { error "Habilite pelo menos dois protocolos."; return 1; }

  printf "Protocolo para conexões silenciosas [ssh/tls/openvpn/http] [%s]: " "$timeout_proto"; read -r v; timeout_proto=${v:-$timeout_proto}
  case "$timeout_proto" in
    ssh) [[ "$ssh_enable" == yes ]] ;;
    tls) [[ "$tls_enable" == yes ]] ;;
    openvpn) [[ "$ovpn_enable" == yes ]] ;;
    http) [[ "$http_enable" == yes ]] ;;
    *) false ;;
  esac || { error "O protocolo de timeout precisa estar habilitado."; return 1; }

  warn "O OnePlus usa sslh SEM modo transparente: não cria regras iptables/nftables e não limpa firewall."
  warn "Por consequência, os serviços de destino podem enxergar a conexão como originada localmente pelo multiplexador."
  info "Os destinos são obrigatoriamente loopback. Reconfigure TLS/WebSocket/OpenVPN para portas internas antes de habilitar cada rota."

  systemctl is-active --quiet "$MUX_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-mux-old.XXXXXX)
  if [[ -e "$MUX_CONF" ]]; then cp -a "$MUX_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$MUX_SERVICE" 2>/dev/null || true
  if tcp_port_in_use "$port"; then
    error "A porta TCP ${port} já está em uso. Pare/reconfigure o serviço que ocupa a porta antes de habilitar o multiplexador."
    if (( had_old )); then install -m 0640 -o root -g oneplus-mux "$old_conf" "$MUX_CONF"; fi
    (( was_active && had_old )) && systemctl start "$MUX_SERVICE" 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-mux.XXXXXX)
  cat > "$tmp" <<EOF2
MUX_BIND=${bind}
MUX_PORT=${port}
MUX_TIMEOUT=${timeout}
MUX_SSH_ENABLE=${ssh_enable}
MUX_SSH_TARGET=${ssh_target}
MUX_TLS_ENABLE=${tls_enable}
MUX_TLS_TARGET=${tls_target}
MUX_OPENVPN_ENABLE=${ovpn_enable}
MUX_OPENVPN_TARGET=${ovpn_target}
MUX_HTTP_ENABLE=${http_enable}
MUX_HTTP_TARGET=${http_target}
MUX_TIMEOUT_PROTOCOL=${timeout_proto}
EOF2
  install -m 0640 -o root -g oneplus-mux "$tmp" "$MUX_CONF"
  rm -f "$tmp"
  systemctl daemon-reload
  if systemctl enable --now "$MUX_SERVICE" && sleep 1 && systemctl is-active --quiet "$MUX_SERVICE"; then
    rm -f "$old_conf"
    ok "Multiplexador ativo em ${bind}:${port}."
    return 0
  fi

  error "Multiplexador não iniciou; restaurando configuração anterior."
  journalctl -u "$MUX_SERVICE" -n 60 --no-pager || true
  systemctl disable --now "$MUX_SERVICE" 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g oneplus-mux "$old_conf" "$MUX_CONF"
    (( was_active )) && systemctl enable --now "$MUX_SERVICE" 2>/dev/null || true
  fi
  rm -f "$old_conf"
  return 1
}

show_mux_config() {
  [[ -r "$MUX_CONF" ]] || { warn "Configuração ausente."; return 0; }
  printf "Escuta: %s:%s TCP\n" "$(read_mux_value MUX_BIND)" "$(read_mux_value MUX_PORT)"
  printf "Timeout: %ss -> %s\n" "$(read_mux_value MUX_TIMEOUT)" "$(read_mux_value MUX_TIMEOUT_PROTOCOL)"
  printf "SSH:     %s -> %s\n" "$(read_mux_value MUX_SSH_ENABLE)" "$(read_mux_value MUX_SSH_TARGET)"
  printf "TLS:     %s -> %s\n" "$(read_mux_value MUX_TLS_ENABLE)" "$(read_mux_value MUX_TLS_TARGET)"
  printf "OpenVPN: %s -> %s\n" "$(read_mux_value MUX_OPENVPN_ENABLE)" "$(read_mux_value MUX_OPENVPN_TARGET)"
  printf "HTTP/WS: %s -> %s\n" "$(read_mux_value MUX_HTTP_ENABLE)" "$(read_mux_value MUX_HTTP_TARGET)"
}

module_mux() {
  while true; do
    clear
    printf "%bOnePlus • Multiplexador de portas (sslh)%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Binário: %s\nServiço: %b\nModo transparente: NÃO\n\n" \
      "$(command -v sslh-select 2>/dev/null || echo ausente)" "$(service_state "$MUX_SERVICE")"
    printf "1) Configurar e habilitar\n2) Mostrar configuração\n3) Reiniciar\n4) Logs\n5) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) configure_mux; pause ;;
      2) show_mux_config; pause ;;
      3) systemctl restart "$MUX_SERVICE"; pause ;;
      4) journalctl -u "$MUX_SERVICE" -n 120 --no-pager; pause ;;
      5) systemctl disable --now "$MUX_SERVICE" 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
