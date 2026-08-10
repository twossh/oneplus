#!/usr/bin/env bash

DROPBEAR_CONF="/etc/oneplus/dropbear.env"
DROPBEAR_DIR="/etc/oneplus/dropbear"
DROPBEAR_KEY="$DROPBEAR_DIR/dropbear_ed25519_host_key"

ensure_dropbear_binary() {
  if [[ -x /usr/sbin/dropbear && -x /usr/bin/dropbearkey ]]; then
    return 0
  fi
  info "Instalando dropbear-bin do repositório Ubuntu..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends dropbear-bin
}

ensure_dropbear_key() {
  ensure_dropbear_binary
  install -d -m 0700 -o root -g root "$DROPBEAR_DIR"
  if [[ ! -s "$DROPBEAR_KEY" ]]; then
    /usr/bin/dropbearkey -t ed25519 -f "$DROPBEAR_KEY" >/dev/null
    chown root:root "$DROPBEAR_KEY"
    chmod 0600 "$DROPBEAR_KEY"
    ok "Chave host Ed25519 do Dropbear gerada."
  fi
}

read_dropbear_value() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$DROPBEAR_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}

configure_dropbear() {
  ensure_dropbear_key
  local bind="0.0.0.0" port="442" password="yes" local_fwd="yes" remote_fwd="no"
  local keepalive="60" idle="0" max_auth="6" v confirm tmp old_conf had_old=0 was_active=0

  [[ -r "$DROPBEAR_CONF" ]] && {
    bind=$(read_dropbear_value DROPBEAR_BIND); bind=${bind:-0.0.0.0}
    port=$(read_dropbear_value DROPBEAR_PORT); port=${port:-442}
    password=$(read_dropbear_value DROPBEAR_PASSWORD_LOGIN); password=${password:-yes}
    local_fwd=$(read_dropbear_value DROPBEAR_LOCAL_FORWARD); local_fwd=${local_fwd:-yes}
    remote_fwd=$(read_dropbear_value DROPBEAR_REMOTE_FORWARD); remote_fwd=${remote_fwd:-no}
    keepalive=$(read_dropbear_value DROPBEAR_KEEPALIVE); keepalive=${keepalive:-60}
    idle=$(read_dropbear_value DROPBEAR_IDLE_TIMEOUT); idle=${idle:-0}
    max_auth=$(read_dropbear_value DROPBEAR_MAX_AUTH_TRIES); max_auth=${max_auth:-6}
  }

  printf "IPv4 de escuta [%s]: " "$bind"; read -r v; bind=${v:-$bind}
  is_valid_ipv4 "$bind" || { error "IPv4 inválido."; return 1; }
  printf "Porta TCP [%s]: " "$port"; read -r v; port=${v:-$port}
  is_valid_port "$port" || { error "Porta inválida."; return 1; }

  printf "Permitir autenticação por senha via Dropbear? [S/n]: "; read -r v
  case "${v:-s}" in s|S|sim|SIM|Sim) password=yes ;; n|N|nao|não|NAO|NÃO) password=no ;; *) error "Resposta inválida."; return 1 ;; esac
  printf "Permitir encaminhamento local (-L/-D)? [S/n]: "; read -r v
  case "${v:-s}" in s|S|sim|SIM|Sim) local_fwd=yes ;; n|N|nao|não|NAO|NÃO) local_fwd=no ;; *) error "Resposta inválida."; return 1 ;; esac
  printf "Permitir encaminhamento remoto (-R)? [s/N]: "; read -r v
  case "${v:-n}" in s|S|sim|SIM|Sim) remote_fwd=yes ;; n|N|nao|não|NAO|NÃO) remote_fwd=no ;; *) error "Resposta inválida."; return 1 ;; esac

  warn "Por segurança, login de root via Dropbear é sempre bloqueado pelo OnePlus. O OpenSSH administrativo permanece separado."
  if [[ "$remote_fwd" == yes ]]; then
    warn "Encaminhamento remoto aumenta a superfície de exposição."
    printf "Digite LIBERAR-R para confirmar: "; read -r confirm
    [[ "$confirm" == "LIBERAR-R" ]] || { info "Mantendo encaminhamento remoto desabilitado."; remote_fwd=no; }
  fi

  printf "Keepalive em segundos [%s]: " "$keepalive"; read -r v; keepalive=${v:-$keepalive}
  [[ "$keepalive" =~ ^[0-9]+$ ]] || { error "Keepalive inválido."; return 1; }
  printf "Timeout ocioso em segundos (0=desligado) [%s]: " "$idle"; read -r v; idle=${v:-$idle}
  [[ "$idle" =~ ^[0-9]+$ ]] || { error "Timeout inválido."; return 1; }
  printf "Tentativas máximas de autenticação [%s]: " "$max_auth"; read -r v; max_auth=${v:-$max_auth}
  [[ "$max_auth" =~ ^[0-9]+$ ]] && (( 10#$max_auth >= 1 && 10#$max_auth <= 100 )) || { error "Valor inválido."; return 1; }

  if systemctl is-active --quiet oneplus-dropbear.service 2>/dev/null; then
    was_active=1
    warn "O serviço Dropbear será reiniciado para aplicar a nova configuração."
  fi
  old_conf=$(mktemp /tmp/oneplus-dropbear-old.XXXXXX)
  if [[ -e "$DROPBEAR_CONF" ]]; then cp -a "$DROPBEAR_CONF" "$old_conf"; had_old=1; fi
  systemctl stop oneplus-dropbear.service 2>/dev/null || true
  if tcp_port_in_use "$port"; then
    error "A porta TCP ${port} já está em uso por outro serviço."
    if (( had_old )); then install -m 0640 -o root -g root "$old_conf" "$DROPBEAR_CONF"; fi
    (( was_active && had_old )) && systemctl start oneplus-dropbear.service 2>/dev/null || true
    rm -f "$old_conf"
    return 1
  fi

  tmp=$(mktemp /tmp/oneplus-dropbear.XXXXXX)
  cat > "$tmp" <<EOF2
DROPBEAR_BIND=${bind}
DROPBEAR_PORT=${port}
DROPBEAR_PASSWORD_LOGIN=${password}
DROPBEAR_LOCAL_FORWARD=${local_fwd}
DROPBEAR_REMOTE_FORWARD=${remote_fwd}
DROPBEAR_KEEPALIVE=${keepalive}
DROPBEAR_IDLE_TIMEOUT=${idle}
DROPBEAR_MAX_AUTH_TRIES=${max_auth}
EOF2
  install -m 0640 -o root -g root "$tmp" "$DROPBEAR_CONF"
  rm -f "$tmp"
  systemctl daemon-reload
  if systemctl enable --now oneplus-dropbear.service && sleep 1 && systemctl is-active --quiet oneplus-dropbear.service; then
    rm -f "$old_conf"
    ok "Dropbear ativo em ${bind}:${port}."
    return 0
  fi

  error "Dropbear não iniciou; restaurando configuração anterior."
  journalctl -u oneplus-dropbear.service -n 30 --no-pager || true
  systemctl disable --now oneplus-dropbear.service 2>/dev/null || true
  if (( had_old )); then
    install -m 0640 -o root -g root "$old_conf" "$DROPBEAR_CONF"
    (( was_active )) && systemctl enable --now oneplus-dropbear.service 2>/dev/null || true
  fi
  rm -f "$old_conf"
  return 1
}

show_dropbear_hostkey() {
  ensure_dropbear_key
  /usr/bin/dropbearkey -y -f "$DROPBEAR_KEY" | sed -n '1,4p'
}

module_dropbear() {
  while true; do
    clear
    printf "%bOnePlus • Dropbear SSH%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "Binário: %s\nServiço: %b\nRoot: bloqueado pelo OnePlus\n\n" \
      "$([[ -x /usr/sbin/dropbear ]] && /usr/sbin/dropbear -V 2>&1 | head -1 || echo ausente)" \
      "$(service_state oneplus-dropbear.service)"
    printf "1) Configurar e habilitar\n2) Mostrar chave host\n3) Reiniciar\n4) Logs\n5) Desabilitar\n0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) configure_dropbear; pause ;;
      2) show_dropbear_hostkey; pause ;;
      3) systemctl restart oneplus-dropbear.service; pause ;;
      4) journalctl -u oneplus-dropbear.service -n 100 --no-pager; pause ;;
      5) systemctl disable --now oneplus-dropbear.service 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
