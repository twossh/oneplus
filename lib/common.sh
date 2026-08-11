#!/usr/bin/env bash

C_RESET='\033[0m'
C_RED='\033[1;31m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[1;34m'
C_CYAN='\033[1;36m'
C_BOLD='\033[1m'

info()  { printf "%b[INFO]%b %s\n"  "$C_BLUE" "$C_RESET" "$*"; }
ok()    { printf "%b[OK]%b %s\n"    "$C_GREEN" "$C_RESET" "$*"; }
warn()  { printf "%b[AVISO]%b %s\n" "$C_YELLOW" "$C_RESET" "$*"; }
error() { printf "%b[ERRO]%b %s\n"  "$C_RED" "$C_RESET" "$*" >&2; }

pause() {
  printf "\nPressione Enter para continuar..."
  read -r _ || true
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "Execute como root ou via sudo."
    exit 1
  fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

ensure_openssh_runtime_dir() {
  local dir=/run/sshd
  if [[ -L "$dir" ]]; then
    error "$dir não pode ser link simbólico."
    return 1
  fi
  if [[ -e "$dir" && ! -d "$dir" ]]; then
    error "$dir existe mas não é diretório."
    return 1
  fi
  install -d -m 0755 -o root -g root "$dir"
}

openssh_config_test() {
  command_exists sshd || { error "sshd não está instalado."; return 1; }
  ensure_openssh_runtime_dir || return 1
  sshd -t
}

service_state() {
  local unit="$1"
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    printf "%bATIVO%b" "$C_GREEN" "$C_RESET"
  elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
    printf "%bINATIVO%b" "$C_YELLOW" "$C_RESET"
  else
    printf "%bNÃO CONFIGURADO%b" "$C_RED" "$C_RESET"
  fi
}

primary_ipv4() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}'
}

is_valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

is_valid_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] && [[ "$domain" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_ipv4() {
  local ip="$1" IFS=. octets
  read -r -a octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  local o
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$o >= 0 && 10#$o <= 255)) || return 1
  done
}

is_valid_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 > 0 ))
}

is_valid_host_port() {
  local value="$1" host port
  if [[ "$value" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
    port="${BASH_REMATCH[2]}"
    is_valid_port "$port"
    return
  fi
  [[ "$value" == *:* ]] || return 1
  host=${value%:*}
  port=${value##*:}
  is_valid_port "$port" || return 1
  [[ "$host" == "localhost" ]] && return 0
  is_valid_ipv4 "$host" && return 0
  is_valid_domain "$host"
}

backup_file_once() {
  local file="$1"
  [[ -e "$file" ]] || return 0
  local dst="${file}.oneplus.original"
  if [[ ! -e "$dst" ]]; then
    cp -a -- "$file" "$dst"
    chmod a-w "$dst" 2>/dev/null || true
  fi
}

tcp_port_in_use() {
  local port="$1"
  is_valid_port "$port" || return 2
  ss -H -ltn 2>/dev/null | awk -v p="$port" '$4 ~ (":" p "$") {found=1} END {exit(found?0:1)}'
}

safe_yes_no() {
  case "$1" in
    yes|no) return 0 ;;
    *) return 1 ;;
  esac
}

ipv4_is_local_address() {
  local wanted="$1"
  is_valid_ipv4 "$wanted" || return 1
  ip -o -4 addr show 2>/dev/null | awk -v ip="$wanted" '{split($4,a,"/"); if (a[1]==ip) found=1} END {exit(found?0:1)}'
}

udp_bind_port_in_use() {
  local bind="$1" port="$2"
  is_valid_ipv4 "$bind" || return 2
  is_valid_port "$port" || return 2
  ss -H -lun 2>/dev/null | awk -v b="$bind" -v p="$port" '
    {
      ep=$4
      if (ep !~ (":" p "$")) next
      sub(":" p "$", "", ep)
      sub(/%.*/, "", ep)
      if (b=="0.0.0.0" || ep==b || ep=="0.0.0.0" || ep=="*" || ep=="[::]") conflict=1
    }
    END {exit(conflict?0:1)}
  '
}
