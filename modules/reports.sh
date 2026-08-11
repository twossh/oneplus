#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_REPORT_DIR=/var/log/oneplus/reports

report_managed_users() {
  local file user kind expires limit count status now
  now=$(date +%s)
  printf '%-18s %-9s %-12s %-8s %-8s %s\n' USER TIPO EXPIRA LIMITE SESSOES STATUS
  shopt -s nullglob
  for file in /var/lib/oneplus/users/*.conf; do
    user=$(meta_get "$file" USERNAME)
    managed_user_identity_ok "$user" || continue
    kind=$(meta_get "$file" KIND)
    expires=$(meta_get "$file" EXPIRES_AT)
    limit=$(meta_get "$file" CONNECTION_LIMIT)
    count=$(user_connection_count "$user")
    if [[ "$expires" =~ ^[0-9]+$ && "$expires" -gt 0 ]]; then
      expiry_text=$(date -d "@$expires" +%F 2>/dev/null || echo invalida)
      (( expires <= now )) && status=EXPIRADO || status=ATIVO
    else
      expiry_text=sem-data
      status=ATIVO
    fi
    passwd -S "$user" 2>/dev/null | awk '{print $2}' | grep -Eq 'L|LK' && status=BLOQUEADO || true
    printf '%-18s %-9s %-12s %-8s %-8s %s\n' "$user" "${kind:-normal}" "$expiry_text" "${limit:-0}" "$count" "$status"
  done
  shopt -u nullglob
}

report_openvpn_clients() {
  if [[ -S /run/oneplus-openvpn/management.sock && -x /opt/oneplus/libexec/openvpn_manager.py ]]; then
    /opt/oneplus/libexec/openvpn_manager.py status 2>/dev/null || true
  else
    printf 'OpenVPN sem socket de gerenciamento ativo.\n'
  fi
}

report_interface_traffic() {
  printf '%-16s %16s %16s\n' INTERFACE RX_BYTES TX_BYTES
  awk -F'[: ]+' 'NR>2 && $2!="lo" {printf "%-16s %16s %16s\n", $2, $3, $11}' /proc/net/dev 2>/dev/null || true
}

report_nft_counters() {
  if command_exists nft; then
    nft list table inet oneplus_filter 2>/dev/null || true
    nft list table ip oneplus_nat 2>/dev/null || true
  fi
}

report_recent_logins() {
  last -ai -n 30 2>/dev/null || true
}

generate_full_report() {
  local outfile="${1:-}" now
  now=$(date -u +%Y%m%dT%H%M%SZ)
  if [[ -z "$outfile" ]]; then
    install -d -m 0700 -o root -g root "$ONEPLUS_REPORT_DIR"
    outfile="$ONEPLUS_REPORT_DIR/report-${now}.txt"
  fi
  umask 077
  {
    printf 'ONEPLUS SYSTEM REPORT\n'
    printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Version: %s\n' "$(cat /opt/oneplus/VERSION 2>/dev/null || echo unknown)"
    printf 'Host: %s\n' "$(hostname -f 2>/dev/null || hostname)"
    printf 'OS: %s\n' "$(show_os_line 2>/dev/null || true)"
    printf 'Kernel: %s\n' "$(uname -r)"
    printf 'Uptime: %s\n\n' "$(uptime -p 2>/dev/null || true)"

    printf '=== Managed users ===\n'
    report_managed_users
    printf '\n=== OpenVPN clients ===\n'
    report_openvpn_clients
    printf '\n=== Listening ports ===\n'
    ss -lntup 2>/dev/null || true
    printf '\n=== Interface traffic ===\n'
    report_interface_traffic
    printf '\n=== OnePlus nftables counters ===\n'
    report_nft_counters
    printf '\n=== Historical summary (24h) ===\n'
    if [[ -x /opt/oneplus/libexec/history_summary.py && -d /var/lib/oneplus/history ]]; then
      python3 /opt/oneplus/libexec/history_summary.py --history-dir /var/lib/oneplus/history --hours 24 2>/dev/null || true
    else
      printf 'Histórico leve não configurado.\n'
    fi
    printf '\n=== OnePlus services ===\n'
    systemctl --no-pager --full status 'oneplus-*.service' 'oneplus-*.timer' 2>/dev/null || true
    printf '\n=== Recent logins ===\n'
    report_recent_logins
  } > "$outfile"
  chmod 0600 "$outfile"
  printf '%s' "$outfile"
}

module_reports() {
  while true; do
    clear
    printf "%bOnePlus • Relatórios%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "1) Usuários/sessões atuais\n"
    printf "2) Clientes OpenVPN\n"
    printf "3) Tráfego por interface\n"
    printf "4) Contadores nftables OnePlus\n"
    printf "5) Logins recentes\n"
    printf "6) Gerar relatório completo root-only\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) clear; report_managed_users; pause ;;
      2) clear; report_openvpn_clients; pause ;;
      3) clear; report_interface_traffic; pause ;;
      4) clear; report_nft_counters; pause ;;
      5) clear; report_recent_logins; pause ;;
      6) file=$(generate_full_report); ok "Relatório criado: $file"; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
