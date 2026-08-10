#!/usr/bin/env bash

WS_CONF="/etc/oneplus/websocket.env"
WS_SERVICE="oneplus-websocket.service"

read_ws_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$WS_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

valid_ws_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/%-]*$ ]]
}

configure_websocket() {
  local bind="0.0.0.0" port="80" upstream="127.0.0.1:22" path="/" mode="auto"
  local max_clients="256" header_limit="16384" max_frame="8388608" v tmp old_conf had_old=0 was_active=0

  [[ -r "$WS_CONF" ]] && {
    bind=$(read_ws_value WS_BIND); bind=${bind:-0.0.0.0}
    port=$(read_ws_value WS_PORT); port=${port:-80}
    upstream=$(read_ws_value WS_UPSTREAM); upstream=${upstream:-127.0.0.1:22}
    path=$(read_ws_value WS_PATH); path=${path:-/}
    mode=$(read_ws_value WS_MODE); mode=${mode:-auto}
    max_clients=$(read_ws_value WS_MAX_CLIENTS); max_clients=${max_clients:-256}
    header_limit=$(read_ws_value WS_HEADER_LIMIT); header_limit=${header_limit:-16384}
    max_frame=$(read_ws_value WS_MAX_FRAME); max_frame=${max_frame:-8388608}
  }

  printf "IPv4 de escuta [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 inválido."; return 1; }
  printf "Porta TCP [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }
  printf "Destino TCP fixo [%s]: " "$upstream"; read -r v; upstream=${v:-$upstream}
  is_valid_host_port "$upstream" || { error "Destino inválido. Use host:porta."; return 1; }
  printf "Caminho WebSocket [%s]: " "$path"; read -r v; path=${v:-$path}
  valid_ws_path "$path" || { error "Caminho inválido. Use, por exemplo, / ou /ssh."; return 1; }

  printf "Modo [1=auto, 2=RFC6455, 3=legacy upgrade] [%s]: " "$mode"; read -r v
  case "${v:-$mode}" in
    1|auto) mode=auto ;;
    2|rfc6455) mode=rfc6455 ;;
    3|legacy) mode=legacy ;;
    *) error "Modo inválido."; return 1 ;;
  esac
  printf "Máximo de clientes simultâneos [%s]: " "$max_clients"; read -r v; max_clients=${v:-$max_clients}
  is_valid_positive_int "$max_clients" || { error "Limite inválido."; return 1; }
  (( 10#$max_clients <= 4096 )) || { error "Máximo permitido pelo OnePlus: 4096."; return 1; }

  warn "O proxy ignora X-Real-Host e qualquer destino solicitado pelo cliente. Todo tráfego vai somente para ${upstream}."
  [[ "$mode" != legacy ]] || warn "Modo legacy existe apenas para compatibilidade com clientes HTTP Upgrade antigos; prefira RFC6455 quando possível."

  systemctl is-active --quiet "$WS_SERVICE" 2>/dev/null && was_active=1
  old_conf=$(mktemp /tmp/oneplus-ws-old.XXXXXX)
  if [[ -e "$WS_CONF" ]]; then cp -a "$WS_CONF" "$old_conf"; had_old=1; fi
  systemctl stop "$WS_SERVICE" 2>/dev/null || true
  if tcp_port_in_use "$port"; then
    error "A porta TCP ${port} já está em uso por outro serviço."
    if (( had_old )); then install -m 0640 -o root -g oneplus-ws "$old_conf" "$WS_CONF"; fi
    (( was_active && had_old )) && systemctl start "$WS_SERVICE" 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-ws.XXXXXX)
  cat > "$tmp" <<EOF2
WS_BIND=${bind}
WS_PORT=${port}
WS_UPSTREAM=${upstream}
WS_PATH=${path}
WS_MODE=${mode}
WS_MAX_CLIENTS=${max_clients}
WS_HEADER_LIMIT=${header_limit}
WS_MAX_FRAME=${max_frame}
EOF2
  install -m 0640 -o root -g oneplus-ws "$tmp" "$WS_CONF"
  rm -f "$tmp"
  systemctl daemon-reload
  if systemctl enable --now "$WS_SERVICE" && sleep 1 && systemctl is-active --quiet "$WS_SERVICE"; then
    rm -f "$old_conf"
    ok "WebSocket ativo em ${bind}:${port}${path}, destino ${upstream}."
    printf "Modo: %s\n" "$mode"
    return 0
  fi

  error "Proxy WebSocket não iniciou; restaurando configuração anterior."
  journalctl -u "$WS_SERVICE" -n 40 --no-pager || true
  systemctl disable --now "$WS_SERVICE" 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g oneplus-ws "$old_conf" "$WS_CONF"
    (( was_active )) && systemctl enable --now "$WS_SERVICE" 2>/dev/null || true
  fi
  rm -f "$old_conf"
  return 1
}

show_websocket_config() {
  if [[ ! -r "$WS_CONF" ]]; then
    warn "Configuração ainda não existe."
    return 0
  fi
  local bind port upstream path mode
  bind=$(read_ws_value WS_BIND); port=$(read_ws_value WS_PORT)
  upstream=$(read_ws_value WS_UPSTREAM); path=$(read_ws_value WS_PATH); mode=$(read_ws_value WS_MODE)
  printf "Escuta:    %s:%s\nCaminho:   %s\nModo:      %s\nDestino:   %s\n" "$bind" "$port" "$path" "$mode" "$upstream"
}

module_websocket() {
  while true; do
    clear
    printf "%bOnePlus • WebSocket%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Implementação: Python 3 / destino fixo\nServiço: %b\n\n" "$(service_state "$WS_SERVICE")"
    printf "1) Configurar e habilitar\n2) Mostrar configuração\n3) Reiniciar\n4) Logs\n5) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) configure_websocket; pause ;;
      2) show_websocket_config; pause ;;
      3) systemctl restart "$WS_SERVICE"; pause ;;
      4) journalctl -u "$WS_SERVICE" -n 100 --no-pager; pause ;;
      5) systemctl disable --now "$WS_SERVICE" 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
