#!/usr/bin/env bash

check_supported_os() {
  [[ -r /etc/os-release ]] || { error "/etc/os-release não encontrado."; return 1; }
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || { error "OnePlus suporta somente Ubuntu."; return 1; }
  dpkg --compare-versions "${VERSION_ID:-0}" ge "24.04" || {
    error "Ubuntu 24.04 ou superior é necessário. Detectado: ${PRETTY_NAME:-desconhecido}."
    return 1
  }
}

show_os_line() {
  # shellcheck disable=SC1091
  source /etc/os-release
  printf "%s" "${PRETTY_NAME:-Ubuntu}"
}
