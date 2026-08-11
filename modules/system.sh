#!/usr/bin/env bash

system_update_ubuntu() {
  local confirm
  clear
  printf "%bOnePlus • Atualização do Ubuntu%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
  warn "Esta ação usa o gerenciador de pacotes do Ubuntu e pode reiniciar serviços durante a atualização."
  warn "O OnePlus não executa dist-upgrade/full-upgrade e não reinicia o servidor automaticamente."
  printf "\nAtualizando apenas o índice APT para montar a prévia...\n"
  apt-get update || { error "Falha ao atualizar índices APT."; return 1; }

  printf "\n%bPrévia do apt-get upgrade:%b\n" "$C_BOLD" "$C_RESET"
  DEBIAN_FRONTEND=noninteractive apt-get -s upgrade || {
    error "Não foi possível simular a atualização. Nada foi instalado."
    return 1
  }

  printf "\nDigite ATUALIZAR para aplicar os upgrades acima: "
  read -r confirm
  if [[ "$confirm" != ATUALIZAR ]]; then
    info "Atualização cancelada; nenhum pacote foi alterado."
    return 0
  fi

  DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  ok "Atualização de pacotes concluída."
  if [[ -e /var/run/reboot-required ]]; then
    warn "O Ubuntu informa que um reboot é necessário. O OnePlus não reiniciará o host automaticamente."
  fi
}

module_system() {
  while true; do
    clear
    local os kernel uptime_s mem disk ipaddr
    os=$(show_os_line)
    kernel=$(uname -r)
    uptime_s=$(uptime -p 2>/dev/null || true)
    mem=$(free -m | awk '/^Mem:/ {printf "%d/%d MB", $3, $2}')
    disk=$(df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}')
    ipaddr=$(primary_ipv4)
    printf "%bOnePlus • Sistema%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "SO:       %s\nKernel:   %s\nUptime:   %s\nMemória:  %s\nDisco /:  %s\nIPv4:     %s\n\n" \
      "$os" "$kernel" "$uptime_s" "$mem" "$disk" "${ipaddr:-não detectado}"
    printf "1) Atualizar pacotes do Ubuntu (prévia + confirmação)\n"
    printf "2) Ver portas em escuta\n"
    printf "3) Ver serviços OnePlus\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) system_update_ubuntu || true; pause ;;
      2) ss -lntup || true; pause ;;
      3) systemctl --no-pager --full status 'oneplus-*.service' 'oneplus-*.timer' 2>/dev/null || true; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
