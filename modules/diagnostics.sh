#!/usr/bin/env bash
set -Eeuo pipefail

DIAG_FAILED=0

diag_ok() { printf "%b[OK]%b %s\n" "$C_GREEN" "$C_RESET" "$*"; }
diag_fail() { printf "%b[FALHA]%b %s\n" "$C_RED" "$C_RESET" "$*"; DIAG_FAILED=1; }
diag_warn() { printf "%b[AVISO]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
diag_cmd() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then diag_ok "$label"; else diag_fail "$label"; fi
}

file_mode_at_most_600() {
  local f="$1" mode
  [[ -f "$f" ]] || return 0
  mode=$(stat -c '%a' "$f")
  (( 8#$mode <= 8#600 ))
}

diagnostics_run() {
  DIAG_FAILED=0
  printf "%bOnePlus • Diagnóstico completo%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
  diag_cmd "Ubuntu suportado" check_supported_os
  diag_cmd "OpenSSH válido" sshd -t
  diag_cmd "Launcher OnePlus" bash -c '[[ "$(readlink -f /usr/local/bin/oneplus 2>/dev/null)" == /opt/oneplus/bin/oneplus ]]'
  diag_cmd "Timer de usuários habilitado" systemctl is-enabled oneplus-user-maintenance.timer
  diag_cmd "BadVPN íntegro" sha256sum -c /var/lib/oneplus/badvpn.sha256
  diag_cmd "dnstt íntegro" sha256sum -c /var/lib/oneplus/dnstt.sha256
  diag_cmd "nftables disponível" command -v nft
  diag_cmd "age disponível" command -v age
  diag_cmd "minisign disponível" command -v minisign
  diag_cmd "Config OpenVPN" test -r /etc/oneplus/openvpn.env
  diag_cmd "Config firewall" test -r /etc/oneplus/firewall.env

  local f
  for f in \
    /etc/oneplus/openvpn/pki/ca.key \
    /etc/oneplus/openvpn/pki/server.key \
    /etc/oneplus/openvpn/tls-crypt.key \
    /etc/oneplus/dropbear/dropbear_ed25519_host_key; do
    if file_mode_at_most_600 "$f"; then diag_ok "Permissão protegida: $f"; else diag_fail "Permissão excessiva: $f"; fi
  done
  if [[ -f /etc/oneplus/tls/server.key ]]; then
    [[ "$(stat -c '%a:%U:%G' /etc/oneplus/tls/server.key)" == "640:root:oneplus-tls" ]] && diag_ok "TLS key restrita ao serviço" || diag_fail "Permissão/grupo incorreto na chave TLS"
  fi
  if [[ -f /etc/oneplus/slowdns/server.key ]]; then
    [[ "$(stat -c '%a:%U:%G' /etc/oneplus/slowdns/server.key)" == "640:root:oneplus-dnstt" ]] && diag_ok "SlowDNS key restrita ao serviço" || diag_fail "Permissão/grupo incorreto na chave SlowDNS"
  fi

  if systemctl --failed --no-legend 2>/dev/null | grep -q 'oneplus-'; then
    diag_fail "Existem unidades OnePlus em estado failed"
    systemctl --failed --no-pager 2>/dev/null | grep 'oneplus-' || true
  else
    diag_ok "Nenhuma unidade OnePlus em failed"
  fi

  if systemctl is-active --quiet oneplus-firewall.service 2>/dev/null; then
    diag_cmd "Tabela NAT OnePlus carregada" nft list table ip oneplus_nat
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == 1 ]]; then diag_ok "IPv4 forwarding ativo"; else diag_fail "IPv4 forwarding desativado com NAT ativo"; fi
  else
    diag_ok "Firewall/NAT OnePlus desativado ou não necessário"
  fi

  local diskpct
  diskpct=$(df -P / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
  if [[ "$diskpct" =~ ^[0-9]+$ ]] && (( diskpct >= 90 )); then diag_warn "Uso de disco / em ${diskpct}%"; else diag_ok "Espaço em disco dentro do limite de alerta"; fi

  if [[ -s /etc/oneplus/update.pub ]]; then
    diag_ok "Chave pública de atualização configurada"
  else
    diag_warn "Atualização assinada ainda sem chave pública confiável (/etc/oneplus/update.pub)."
  fi

  printf "\nServiços:\n"
  for unit in ssh.service oneplus-dropbear.service oneplus-websocket.service oneplus-tls.service oneplus-openvpn.service oneplus-mux.service oneplus-firewall.service oneplus-badvpn.service oneplus-slowdns.service oneplus-user-maintenance.timer; do
    printf "  %-34s %b\n" "$unit" "$(service_state "$unit")"
  done

  printf "\nListeners:\n"
  ss -lntup 2>/dev/null || true
  if (( DIAG_FAILED )); then
    printf "\n%bDiagnóstico concluído com falhas.%b\n" "$C_RED" "$C_RESET"
    return 1
  fi
  printf "\n%bDiagnóstico concluído sem falhas críticas.%b\n" "$C_GREEN" "$C_RESET"
}

repair_permissions() {
  require_root
  install -d -m 0755 -o root -g root /etc/oneplus /var/lib/oneplus
  install -d -m 0700 -o root -g root /var/lib/oneplus/users /var/lib/oneplus/rollback /etc/oneplus/openvpn /etc/oneplus/openvpn/pki /etc/oneplus/dropbear
  install -d -m 0750 -o root -g oneplus-dnstt /etc/oneplus/slowdns 2>/dev/null || true
  install -d -m 0750 -o root -g oneplus-tls /etc/oneplus/tls 2>/dev/null || true
  find /var/lib/oneplus/users -maxdepth 1 -type f -name '*.conf' -exec chown root:root {} + -exec chmod 0600 {} + 2>/dev/null || true
  [[ -f /etc/oneplus/oneplus.conf ]] && chmod 0644 /etc/oneplus/oneplus.conf
  [[ -f /etc/oneplus/users.conf ]] && chmod 0644 /etc/oneplus/users.conf
  [[ -f /etc/oneplus/dropbear.env ]] && chown root:root /etc/oneplus/dropbear.env && chmod 0640 /etc/oneplus/dropbear.env
  [[ -f /etc/oneplus/openvpn.env ]] && chown root:root /etc/oneplus/openvpn.env && chmod 0640 /etc/oneplus/openvpn.env
  [[ -f /etc/oneplus/firewall.env ]] && chown root:root /etc/oneplus/firewall.env && chmod 0640 /etc/oneplus/firewall.env
  [[ -f /etc/oneplus/badvpn.env ]] && chown root:oneplus-badvpn /etc/oneplus/badvpn.env && chmod 0640 /etc/oneplus/badvpn.env
  [[ -f /etc/oneplus/slowdns.env ]] && chown root:oneplus-dnstt /etc/oneplus/slowdns.env && chmod 0640 /etc/oneplus/slowdns.env
  [[ -f /etc/oneplus/websocket.env ]] && chown root:oneplus-ws /etc/oneplus/websocket.env && chmod 0640 /etc/oneplus/websocket.env
  [[ -f /etc/oneplus/tls.env ]] && chown root:oneplus-tls /etc/oneplus/tls.env && chmod 0640 /etc/oneplus/tls.env
  [[ -f /etc/oneplus/mux.env ]] && chown root:oneplus-mux /etc/oneplus/mux.env && chmod 0640 /etc/oneplus/mux.env
  local f
  for f in /etc/oneplus/openvpn/pki/ca.key /etc/oneplus/openvpn/pki/server.key /etc/oneplus/openvpn/tls-crypt.key /etc/oneplus/dropbear/dropbear_ed25519_host_key; do
    [[ -f "$f" ]] && chown root:root "$f" 2>/dev/null || true
    [[ -f "$f" ]] && chmod 0600 "$f" || true
  done
  [[ -f /etc/oneplus/tls/server.key ]] && chown root:oneplus-tls /etc/oneplus/tls/server.key && chmod 0640 /etc/oneplus/tls/server.key || true
  [[ -f /etc/oneplus/slowdns/server.key ]] && chown root:oneplus-dnstt /etc/oneplus/slowdns/server.key && chmod 0640 /etc/oneplus/slowdns/server.key || true
  ln -sfn /opt/oneplus/bin/oneplus /usr/local/bin/oneplus
}

repair_system() {
  require_root
  printf "Esta rotina NÃO altera firewall externo, não executa apt upgrade e não habilita protocolos desativados.\n"
  printf "Digite REPARAR para reinstalar arquivos OnePlus e corrigir permissões: "; read -r confirm
  [[ "$confirm" == REPARAR ]] || { info "Cancelado."; return 0; }
  repair_permissions
  local f
  for f in /opt/oneplus/systemd/oneplus-*.service /opt/oneplus/systemd/oneplus-*.timer; do
    [[ -f "$f" ]] || continue
    install -m 0644 -o root -g root "$f" "/etc/systemd/system/$(basename "$f")"
  done
  systemctl daemon-reload
  /opt/oneplus/modules/users.sh init
  /opt/oneplus/modules/openvpn.sh init
  systemctl enable oneplus-user-maintenance.timer >/dev/null 2>&1 || true
  systemctl start oneplus-user-maintenance.timer >/dev/null 2>&1 || true
  sshd -t || { error "OpenSSH continua inválido; não foi reiniciado."; return 1; }
  ok "Arquivos/permissões OnePlus reparados sem reiniciar protocolos de rede."
}

module_diagnostics() {
  while true; do
    clear
    printf "%bOnePlus • Diagnóstico e reparo%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "1) Diagnóstico completo\n"
    printf "2) Reparar arquivos/permissões OnePlus\n"
    printf "3) Unidades OnePlus com falha\n"
    printf "4) Logs recentes com prioridade warning+\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) clear; diagnostics_run || true; pause ;;
      2) repair_system; pause ;;
      3) systemctl --failed --no-pager | grep -E 'oneplus-|UNIT' || true; pause ;;
      4) journalctl --no-pager -p warning -n 150 -u 'oneplus-*' 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
  source "$ROOT_DIR/lib/common.sh"
  source "$ROOT_DIR/lib/os.sh"
  case "${1:-}" in
    repair-permissions) repair_permissions ;;
    check) diagnostics_run ;;
    *) echo "Uso: $0 {repair-permissions|check}"; exit 2 ;;
  esac
fi
