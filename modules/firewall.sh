#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_FIREWALL_CONF=/etc/oneplus/firewall.env
ONEPLUS_FIREWALL_SERVICE=oneplus-firewall.service
ONEPLUS_FORWARD_SYSCTL=/etc/sysctl.d/90-oneplus-forwarding.conf

fw_get() {
  local key="$1" line
  line=$(grep -E "^${key}=" "$ONEPLUS_FIREWALL_CONF" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}
fw_set() {
  local key="$1" value="$2" tmp
  [[ "$key" =~ ^[A-Z0-9_]+$ && "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  tmp=$(mktemp /tmp/oneplus-fw.XXXXXX)
  awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k{print k "=" v;done=1;next}{print} END{if(!done)print k "=" v}' "$ONEPLUS_FIREWALL_CONF" > "$tmp"
  install -m 0640 -o root -g root "$tmp" "$ONEPLUS_FIREWALL_CONF"
  rm -f "$tmp"
}
openvpn_set() {
  local key="$1" value="$2" file=/etc/oneplus/openvpn.env tmp
  [[ -r "$file" ]] || return 1
  tmp=$(mktemp /tmp/oneplus-ovpn-fw.XXXXXX)
  awk -F= -v k="$key" -v v="$value" 'BEGIN{done=0} $1==k{print k "=" v;done=1;next}{print} END{if(!done)print k "=" v}' "$file" > "$tmp"
  install -m 0640 -o root -g root "$tmp" "$file"
  rm -f "$tmp"
}
valid_iface_name() { [[ "$1" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] && ip link show dev "$1" >/dev/null 2>&1; }
default_egress_iface() { ip -4 route show default 2>/dev/null | awk '/default/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'; }

port_audit() {
  clear
  printf "%bOnePlus • Auditoria de portas%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
  printf "Listeners TCP/UDP atuais:\n"
  ss -H -lntup 2>/dev/null | sort -k5,5 || true
  printf "\nTabelas nftables existentes (somente leitura):\n"
  nft list tables 2>/dev/null || warn "nftables não disponível/sem regras."
  printf "\nTabelas gerenciadas pelo OnePlus:\n"
  nft list table inet oneplus_filter 2>/dev/null || printf "inet oneplus_filter: ausente\n"
  nft list table ip oneplus_nat 2>/dev/null || printf "ip oneplus_nat: ausente\n"
  printf "\nUFW: "
  if command_exists ufw; then ufw status 2>/dev/null | head -1 || true; else printf "não instalado\n"; fi
}

configure_openvpn_nat() {
  local egress default_if tun full dns1 dns2 old_full was_active=0
  default_if=$(default_egress_iface)
  printf "Interface de saída [%s]: " "${default_if:-eth0}"; read -r egress
  egress=${egress:-${default_if:-eth0}}
  valid_iface_name "$egress" || { error "Interface inválida/inexistente: $egress"; return 1; }
  printf "Interface TUN OpenVPN [tun0]: "; read -r tun; tun=${tun:-tun0}
  [[ "$tun" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] || { error "Nome TUN inválido."; return 1; }
  printf "Enviar rota padrão (full tunnel) aos clientes? [s/N]: "; read -r full
  [[ "$full" =~ ^[sSyY]$ ]] && full=yes || full=no
  dns1=""; dns2=""
  if [[ "$full" == yes ]]; then
    printf "DNS IPv4 1 para clientes [vazio = não enviar]: "; read -r dns1
    printf "DNS IPv4 2 [vazio]: "; read -r dns2
    [[ -z "$dns1" ]] || is_valid_ipv4 "$dns1" || { error "DNS1 inválido."; return 1; }
    [[ -z "$dns2" ]] || is_valid_ipv4 "$dns2" || { error "DNS2 inválido."; return 1; }
  fi
  warn "O OnePlus criará SOMENTE as tabelas nftables 'inet oneplus_filter' e 'ip oneplus_nat'. Regras existentes não serão limpas."
  warn "Firewalls externos (UFW/cloud security groups) ainda podem bloquear encaminhamento."
  printf "Digite ATIVAR-NAT para continuar: "; read -r confirm
  [[ "$confirm" == ATIVAR-NAT ]] || { info "Cancelado."; return 0; }

  old_full=$(grep -E '^OPENVPN_FULL_TUNNEL=' /etc/oneplus/openvpn.env 2>/dev/null | tail -1 | cut -d= -f2- || true)
  systemctl is-active --quiet oneplus-openvpn.service 2>/dev/null && was_active=1
  fw_set OPENVPN_EGRESS_IFACE "$egress"
  fw_set OPENVPN_TUN_IFACE "$tun"
  fw_set OPENVPN_NAT_ENABLED yes
  openvpn_set OPENVPN_FULL_TUNNEL "$full"
  openvpn_set OPENVPN_PUSH_DNS1 "$dns1"
  openvpn_set OPENVPN_PUSH_DNS2 "$dns2"
  cat > "$ONEPLUS_FORWARD_SYSCTL" <<'EOF2'
# Gerado pelo OnePlus para OpenVPN/NAT. Remover este arquivo não força ip_forward=0 em runtime.
net.ipv4.ip_forward=1
EOF2
  chmod 0644 "$ONEPLUS_FORWARD_SYSCTL"
  sysctl -w net.ipv4.ip_forward=1 >/dev/null
  systemctl daemon-reload
  if ! systemctl enable --now "$ONEPLUS_FIREWALL_SERVICE"; then
    error "Falha ao aplicar as tabelas OnePlus; desativando NAT."
    fw_set OPENVPN_NAT_ENABLED no
    systemctl disable --now "$ONEPLUS_FIREWALL_SERVICE" 2>/dev/null || true
    return 1
  fi
  if (( was_active )); then
    if ! systemctl restart oneplus-openvpn.service; then
      error "OpenVPN não reiniciou; revertendo full-tunnel e NAT."
      openvpn_set OPENVPN_FULL_TUNNEL "${old_full:-no}"
      fw_set OPENVPN_NAT_ENABLED no
      systemctl disable --now "$ONEPLUS_FIREWALL_SERVICE" 2>/dev/null || true
      return 1
    fi
  fi
  ok "NAT OpenVPN ativo via tabela nftables própria."
  [[ "$full" == yes ]] && info "Clientes receberão redirect-gateway após reconectar." || info "NAT ativo sem forçar rota padrão nos clientes."
}

disable_openvpn_nat() {
  printf "Digite DESATIVAR-NAT para remover somente as tabelas nftables do OnePlus: "; read -r confirm
  [[ "$confirm" == DESATIVAR-NAT ]] || { info "Cancelado."; return 0; }
  fw_set OPENVPN_NAT_ENABLED no
  openvpn_set OPENVPN_FULL_TUNNEL no || true
  openvpn_set OPENVPN_PUSH_DNS1 "" || true
  openvpn_set OPENVPN_PUSH_DNS2 "" || true
  systemctl disable --now "$ONEPLUS_FIREWALL_SERVICE" 2>/dev/null || /opt/oneplus/libexec/run-firewall remove || true
  rm -f "$ONEPLUS_FORWARD_SYSCTL"
  if systemctl is-active --quiet oneplus-openvpn.service 2>/dev/null; then
    systemctl restart oneplus-openvpn.service || warn "Revise o OpenVPN manualmente."
  fi
  ok "Regras OnePlus removidas. net.ipv4.ip_forward NÃO foi forçado para 0, pois outro serviço pode depender dele."
}

show_firewall_status() {
  printf "NAT OpenVPN: %s\n" "$(fw_get OPENVPN_NAT_ENABLED)"
  printf "Saída: %s\n" "$(fw_get OPENVPN_EGRESS_IFACE)"
  printf "TUN: %s\n" "$(fw_get OPENVPN_TUN_IFACE)"
  printf "ip_forward: %s\n" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo N/D)"
  printf "Serviço: %b\n\n" "$(service_state "$ONEPLUS_FIREWALL_SERVICE")"
  nft list table inet oneplus_filter 2>/dev/null || true
  nft list table ip oneplus_nat 2>/dev/null || true
}

module_firewall() {
  while true; do
    clear
    printf "%bOnePlus • Portas, firewall e NAT%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "NAT OpenVPN: %s | nftables OnePlus: %b\n\n" "$(fw_get OPENVPN_NAT_ENABLED)" "$(service_state "$ONEPLUS_FIREWALL_SERVICE")"
    printf "1) Auditoria de portas/firewall\n"
    printf "2) Ativar/configurar NAT OpenVPN\n"
    printf "3) Desativar NAT OpenVPN\n"
    printf "4) Status/regras OnePlus\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) port_audit; pause ;;
      2) configure_openvpn_nat; pause ;;
      3) disable_openvpn_nat; pause ;;
      4) clear; show_firewall_status; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
