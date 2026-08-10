#!/usr/bin/env bash

module_system() {
  while true; do
    clear
    local os kernel uptime_s mem total_mem used_mem disk ipaddr
    os=$(show_os_line)
    kernel=$(uname -r)
    uptime_s=$(uptime -p 2>/dev/null || true)
    mem=$(free -m | awk '/^Mem:/ {printf "%d/%d MB", $3, $2}')
    disk=$(df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
    ipaddr=$(primary_ipv4)
    printf "%bOnePlus • Sistema%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "SO:       %s\nKernel:   %s\nUptime:   %s\nMemória:  %s\nDisco /:  %s\nIPv4:     %s\n\n" \
      "$os" "$kernel" "$uptime_s" "$mem" "$disk" "${ipaddr:-não detectado}"
    printf "1) Atualizar pacotes do Ubuntu\n"
    printf "2) Ver portas em escuta\n"
    printf "3) Ver serviços OnePlus\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1)
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
        pause
        ;;
      2)
        ss -lntup || true
        pause
        ;;
      3)
        systemctl --no-pager --full status 'oneplus-*.service' 'oneplus-*.timer' 2>/dev/null || true
        pause
        ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
