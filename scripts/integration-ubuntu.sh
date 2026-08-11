#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:---ci}"
BASE_DIR="${ONEPLUS_INTEGRATION_BASE_DIR:-}"
INTEGRATION_ROOT="/var/lib/oneplus/integration"
LOG_ROOT="/var/log/oneplus/integration"
UPSTREAM_UNIT="oneplus-integration-upstream.service"
CURRENT_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
REPORT=""

log() { printf '[INTEGRATION] %s\n' "$*"; }
pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
skip() { printf '[SKIP] %s\n' "$*"; }

require_disposable_vm() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "execute como root/sudo"
  [[ -r /etc/os-release ]] || fail "/etc/os-release ausente"
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || fail "integração suportada somente em Ubuntu; detectado ${ID:-desconhecido}"
  dpkg --compare-versions "${VERSION_ID:-0}" ge 24.04 || fail "Ubuntu 24.04+ obrigatório"

  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    return 0
  fi
  if [[ "${ONEPLUS_INTEGRATION_CONFIRM:-}" == DESTROYABLE_VM ]]; then
    return 0
  fi
  cat >&2 <<'MSG'
[RECUSADO] Este teste instala pacotes, cria contas/configurações e habilita serviços.
Execute SOMENTE em VM/VPS descartável e confirme explicitamente:
  sudo env ONEPLUS_INTEGRATION_CONFIRM=DESTROYABLE_VM bash scripts/integration-ubuntu.sh --ci
Nunca use esta suíte na VPS de produção.
MSG
  exit 2
}

assert_cmd() { command -v "$1" >/dev/null 2>&1 || fail "comando ausente: $1"; }
assert_file() { [[ -f "$1" ]] || fail "arquivo ausente: $1"; }
assert_active() { systemctl is-active --quiet "$1" || { journalctl -u "$1" -n 80 --no-pager || true; fail "serviço não ativo: $1"; }; }
assert_enabled() { systemctl is-enabled --quiet "$1" || fail "unidade não habilitada: $1"; }
assert_tcp() {
  local port="$1"
  ss -H -ltn | awk -v p="$port" '$4 ~ (":" p "$") {ok=1} END {exit(ok?0:1)}' || fail "porta TCP não está em escuta: $port"
}
assert_udp() {
  local port="$1"
  ss -H -lun | awk -v p="$port" '$4 ~ (":" p "$") {ok=1} END {exit(ok?0:1)}' || fail "porta UDP não está em escuta: $port"
}

prepare_report() {
  install -d -m 0700 "$INTEGRATION_ROOT" "$LOG_ROOT"
  REPORT="$LOG_ROOT/integration-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "$REPORT") 2>&1
  chmod 0600 "$REPORT" 2>/dev/null || true
  log "OnePlus ${CURRENT_VERSION} • Ubuntu integration"
  log "Host: $(hostname)"
  log "Kernel: $(uname -srmo)"
  log "OS: ${PRETTY_NAME:-unknown}"
}

install_tree() {
  local tree="$1" expected="$2"
  [[ "$tree" == /* && -d "$tree" ]] || fail "árvore de instalação inválida: $tree"
  [[ -r "$tree/VERSION" && -r "$tree/install.sh" ]] || fail "árvore incompleta: $tree"
  if [[ -r "$tree/scripts/fix-permissions.sh" ]]; then
    chmod 0755 "$tree/scripts/fix-permissions.sh"
    bash "$tree/scripts/fix-permissions.sh"
  fi
  # Releases históricas anteriores à v0.8.1 chamavam `sshd -t` diretamente.
  # Em runners Ubuntu 24.04 com socket activation, /run/sshd pode ainda não
  # existir. Preparar o runtime torna o cenário de upgrade fiel a uma VPS em uso
  # e não modifica configuração persistente do OpenSSH.
  if [[ -L /run/sshd || ( -e /run/sshd && ! -d /run/sshd ) ]]; then
    fail "/run/sshd possui tipo inseguro"
  fi
  install -d -m 0755 -o root -g root /run/sshd
  local source_version installed_version launcher_version
  source_version=$(tr -d '[:space:]' < "$tree/VERSION")
  [[ "$source_version" == "$expected" ]] || fail "VERSION da origem diverge do cenário: esperada=${expected} origem=${source_version}"

  log "Instalando OnePlus ${expected} a partir de $tree"
  bash "$tree/install.sh"
  installed_version=$(tr -d '[:space:]' < /opt/oneplus/VERSION 2>/dev/null || true)
  launcher_version=$(/usr/local/bin/oneplus --version 2>/dev/null | awk '{print $2}' || true)
  if [[ "$installed_version" != "$expected" || "$launcher_version" != "$expected" ]]; then
    printf '[DIAG] versão esperada=%s origem=%s árvore_instalada=%s launcher=%s\n' \
      "$expected" "$source_version" "${installed_version:-ausente}" "${launcher_version:-ausente}" >&2
    sha256sum "$tree/VERSION" /opt/oneplus/VERSION 2>/dev/null || true
    stat -c '[DIAG] %n size=%s mtime=%Y mode=%a' "$tree/VERSION" /opt/oneplus/VERSION 2>/dev/null || true
    fail "versão instalada não corresponde a ${expected}"
  fi
  pass "versão instalada confirmada: ${expected}"
}

mark_preserved_configuration() {
  local marker="ONEPLUS-INTEGRATION-PRESERVE-${CURRENT_VERSION}"
  printf '\n# %s\n' "$marker" >> /etc/oneplus/history.env
  printf '%s\n' "$marker" > "$INTEGRATION_ROOT/preserve.marker"
  chmod 0600 "$INTEGRATION_ROOT/preserve.marker"
}

assert_preserved_configuration() {
  local marker
  marker=$(cat "$INTEGRATION_ROOT/preserve.marker" 2>/dev/null || true)
  [[ -n "$marker" ]] || fail "marcador de preservação ausente"
  grep -Fqx "# $marker" /etc/oneplus/history.env || fail "reinstalação/upgrade sobrescreveu configuração persistente"
  pass "configuração /etc/oneplus preservada no upgrade/reinstall"
}

run_install_or_upgrade() {
  local base_ver=""
  if [[ -n "$BASE_DIR" && -d "$BASE_DIR" && -r "$BASE_DIR/VERSION" ]]; then
    base_ver=$(tr -d '[:space:]' < "$BASE_DIR/VERSION")
    if [[ "$base_ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && dpkg --compare-versions "$CURRENT_VERSION" gt "$base_ver"; then
      log "Cenário upgrade: ${base_ver} -> ${CURRENT_VERSION}"
      install_tree "$BASE_DIR" "$base_ver"
      mark_preserved_configuration
      install_tree "$ROOT_DIR" "$CURRENT_VERSION"
      assert_preserved_configuration
      pass "upgrade ${base_ver} -> ${CURRENT_VERSION}"
      return 0
    fi
    skip "base ${base_ver:-inválida} não é anterior a ${CURRENT_VERSION}; executando instalação limpa"
  fi

  if [[ -e /opt/oneplus && "${ONEPLUS_INTEGRATION_ALLOW_EXISTING:-no}" != yes ]]; then
    fail "/opt/oneplus já existe. Use VM limpa ou ONEPLUS_INTEGRATION_ALLOW_EXISTING=yes somente em VM descartável."
  fi
  install_tree "$ROOT_DIR" "$CURRENT_VERSION"
  mark_preserved_configuration
  log "Testando reinstalação idempotente da mesma versão"
  install_tree "$ROOT_DIR" "$CURRENT_VERSION"
  assert_preserved_configuration
  pass "instalação limpa + reinstalação idempotente"
}

start_upstream() {
  systemctl stop "$UPSTREAM_UNIT" >/dev/null 2>&1 || true
  systemd-run --unit=oneplus-integration-upstream --property=Type=simple \
    /usr/bin/python3 -m http.server 18022 --bind 127.0.0.1 >/dev/null
  sleep 1
  assert_active "$UPSTREAM_UNIT"
  curl -fsS --max-time 5 http://127.0.0.1:18022/ >/dev/null
  pass "upstream local de teste em 127.0.0.1:18022"
}

smoke_dropbear() {
  install -d -m 0700 /etc/oneplus/dropbear
  if [[ ! -s /etc/oneplus/dropbear/dropbear_ed25519_host_key ]]; then
    /usr/bin/dropbearkey -t ed25519 -f /etc/oneplus/dropbear/dropbear_ed25519_host_key >/dev/null
  fi
  chmod 0600 /etc/oneplus/dropbear/dropbear_ed25519_host_key
  cat > /etc/oneplus/dropbear.env <<'EOF2'
DROPBEAR_BIND=127.0.0.1
DROPBEAR_PORT=22442
DROPBEAR_PASSWORD_LOGIN=no
DROPBEAR_LOCAL_FORWARD=yes
DROPBEAR_REMOTE_FORWARD=no
DROPBEAR_KEEPALIVE=30
DROPBEAR_IDLE_TIMEOUT=0
DROPBEAR_MAX_AUTH_TRIES=4
EOF2
  chown root:root /etc/oneplus/dropbear.env; chmod 0640 /etc/oneplus/dropbear.env
  systemctl enable --now oneplus-dropbear.service
  assert_active oneplus-dropbear.service
  assert_tcp 22442
  timeout 10 ssh-keyscan -T 5 -p 22442 127.0.0.1 2>/dev/null | grep -Eq 'ssh-ed25519|ssh-rsa|ecdsa' || fail "handshake SSH Dropbear falhou"
  pass "Dropbear: systemd + listener + handshake SSH"
}

smoke_websocket() {
  cat > /etc/oneplus/websocket.env <<'EOF2'
WS_BIND=127.0.0.1
WS_PORT=18080
WS_UPSTREAM=127.0.0.1:18022
WS_PATH=/ci
WS_MODE=rfc6455
WS_MAX_CLIENTS=32
WS_HEADER_LIMIT=16384
WS_MAX_FRAME=1048576
EOF2
  chown root:oneplus-ws /etc/oneplus/websocket.env; chmod 0640 /etc/oneplus/websocket.env
  systemctl enable --now oneplus-websocket.service
  assert_active oneplus-websocket.service
  assert_tcp 18080
  python3 - <<'PY'
import base64, os, socket
key = base64.b64encode(os.urandom(16)).decode()
req = ("GET /ci HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n") % key
with socket.create_connection(("127.0.0.1", 18080), timeout=5) as s:
    s.sendall(req.encode())
    data = s.recv(4096)
if not data.startswith(b"HTTP/1.1 101"):
    raise SystemExit("WebSocket não respondeu 101 Switching Protocols")
PY
  pass "WebSocket: systemd + RFC6455 real"
}

smoke_tls() {
  install -d -m 0750 -o root -g oneplus-tls /etc/oneplus/tls
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 1 \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    -keyout /etc/oneplus/tls/server.key -out /etc/oneplus/tls/server.crt >/dev/null 2>&1
  chown root:oneplus-tls /etc/oneplus/tls/server.key; chmod 0640 /etc/oneplus/tls/server.key
  chown root:root /etc/oneplus/tls/server.crt; chmod 0644 /etc/oneplus/tls/server.crt
  cat > /etc/oneplus/tls.env <<'EOF2'
TLS_BIND=127.0.0.1
TLS_PORT=18443
TLS_UPSTREAM=127.0.0.1:18022
TLS_MIN_VERSION=TLSv1.2
EOF2
  chown root:oneplus-tls /etc/oneplus/tls.env; chmod 0640 /etc/oneplus/tls.env
  systemctl enable --now oneplus-tls.service
  assert_active oneplus-tls.service
  assert_tcp 18443
  timeout 10 openssl s_client -showcerts -connect 127.0.0.1:18443 -servername localhost -tls1_2 </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE' || fail "handshake TLS falhou"
  pass "TLS/Stunnel: systemd + handshake TLS 1.2"
}

smoke_badvpn() {
  cat > /etc/oneplus/badvpn.env <<'EOF2'
BADVPN_BIND=127.0.0.1:17300
BADVPN_LOGLEVEL=warning
BADVPN_MAX_CLIENTS=32
BADVPN_MAX_CONNECTIONS=8
BADVPN_SNDBUF=262144
EOF2
  chown root:oneplus-badvpn /etc/oneplus/badvpn.env; chmod 0640 /etc/oneplus/badvpn.env
  systemctl enable --now oneplus-badvpn.service
  assert_active oneplus-badvpn.service
  assert_tcp 17300
  pass "BadVPN UDPGW: binário compilado + systemd + listener"
}

smoke_slowdns() {
  install -d -m 0750 -o root -g oneplus-dnstt /etc/oneplus/slowdns
  if [[ ! -s /etc/oneplus/slowdns/server.key || ! -s /etc/oneplus/slowdns/server.pub ]]; then
    /usr/local/lib/oneplus/bin/dnstt-server -gen-key \
      -privkey-file /etc/oneplus/slowdns/server.key \
      -pubkey-file /etc/oneplus/slowdns/server.pub
  fi
  chown root:oneplus-dnstt /etc/oneplus/slowdns/server.key; chmod 0640 /etc/oneplus/slowdns/server.key
  chown root:root /etc/oneplus/slowdns/server.pub; chmod 0644 /etc/oneplus/slowdns/server.pub
  cat > /etc/oneplus/slowdns.env <<'EOF2'
SLOWDNS_DOMAIN=tunnel.example.com
SLOWDNS_BIND=127.0.0.1
SLOWDNS_PORT=15353
SLOWDNS_PUBLIC_IP=127.0.0.1
SLOWDNS_UPSTREAM=127.0.0.1:18022
SLOWDNS_MTU=1232
SLOWDNS_PRIVKEY=/etc/oneplus/slowdns/server.key
SLOWDNS_PUBKEY=/etc/oneplus/slowdns/server.pub
EOF2
  chown root:oneplus-dnstt /etc/oneplus/slowdns.env; chmod 0640 /etc/oneplus/slowdns.env
  systemctl enable --now oneplus-slowdns.service
  assert_active oneplus-slowdns.service
  assert_udp 15353
  pass "SlowDNS/dnstt: chaves locais + systemd + listener UDP"
}

smoke_openvpn() {
  if [[ ! -c /dev/net/tun ]]; then
    skip "OpenVPN runtime: /dev/net/tun indisponível neste runner"
    return 0
  fi
  /opt/oneplus/modules/openvpn.sh pki
  cat > /etc/oneplus/openvpn.env <<'EOF2'
OPENVPN_BIND=127.0.0.1
OPENVPN_PORT=11194
OPENVPN_PROTO=tcp
OPENVPN_PUBLIC_HOST=127.0.0.1
OPENVPN_PUBLIC_PORT=11194
OPENVPN_NETWORK=10.77.0.0
OPENVPN_MAX_CLIENTS=16
OPENVPN_FULL_TUNNEL=no
OPENVPN_PUSH_DNS1=
OPENVPN_PUSH_DNS2=
OPENVPN_AUTH_MODE=password
OPENVPN_TLS_CRYPT_MODE=legacy
EOF2
  chown root:root /etc/oneplus/openvpn.env; chmod 0640 /etc/oneplus/openvpn.env
  systemctl enable --now oneplus-openvpn.service
  sleep 2
  if systemctl is-active --quiet oneplus-openvpn.service; then
    assert_tcp 11194
    [[ -S /run/oneplus-openvpn/management.sock ]] || fail "socket management OpenVPN ausente"
    pass "OpenVPN: PKI + TUN + systemd + management socket"
  else
    journalctl -u oneplus-openvpn.service -n 100 --no-pager || true
    fail "OpenVPN deveria iniciar quando /dev/net/tun existe"
  fi
}

smoke_mux() {
  cat > /etc/oneplus/mux.env <<'EOF2'
MUX_BIND=127.0.0.1
MUX_PORT=19443
MUX_TIMEOUT=2
MUX_SSH_ENABLE=yes
MUX_SSH_TARGET=127.0.0.1:22442
MUX_TLS_ENABLE=yes
MUX_TLS_TARGET=127.0.0.1:18443
MUX_OPENVPN_ENABLE=no
MUX_OPENVPN_TARGET=127.0.0.1:11194
MUX_HTTP_ENABLE=yes
MUX_HTTP_TARGET=127.0.0.1:18080
MUX_TIMEOUT_PROTOCOL=ssh
EOF2
  chown root:oneplus-mux /etc/oneplus/mux.env; chmod 0640 /etc/oneplus/mux.env
  systemctl enable --now oneplus-mux.service
  assert_active oneplus-mux.service
  assert_tcp 19443
  timeout 12 ssh-keyscan -T 8 -p 19443 127.0.0.1 2>/dev/null | grep -Eq 'ssh-ed25519|ssh-rsa|ecdsa' || fail "sslh não roteou SSH"
  timeout 12 openssl s_client -showcerts -connect 127.0.0.1:19443 -servername localhost -tls1_2 </dev/null 2>/dev/null | grep -q 'BEGIN CERTIFICATE' || fail "sslh não roteou TLS"
  python3 - <<'PY'
import base64, os, socket
key = base64.b64encode(os.urandom(16)).decode()
req = ("GET /ci HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n"
       "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n") % key
with socket.create_connection(("127.0.0.1", 19443), timeout=8) as s:
    s.sendall(req.encode())
    data = s.recv(4096)
if not data.startswith(b"HTTP/1.1 101"):
    raise SystemExit("sslh não roteou HTTP/WebSocket")
PY
  pass "sslh: SSH + TLS + HTTP/WebSocket na mesma porta"
}

smoke_history_and_timers() {
  systemctl start oneplus-history.service
  find /var/lib/oneplus/history -maxdepth 1 -type f -name '*.ndjson' -size +0c | grep -q . || fail "snapshot de histórico não foi gravado"
  systemctl enable --now oneplus-history.timer
  assert_active oneplus-history.timer
  assert_enabled oneplus-user-maintenance.timer
  assert_active oneplus-user-maintenance.timer
  assert_enabled oneplus-openvpn-pki-maintenance.timer
  assert_active oneplus-openvpn-pki-maintenance.timer
  pass "histórico one-shot + timers persistentes"
}

smoke_security_contracts() {
  /usr/local/bin/oneplus --check
  # Usa o mesmo wrapper do produto para cobrir socket activation, mantendo um
  # `sshd -t` real por baixo dele.
  # shellcheck disable=SC1091
  source /opt/oneplus/lib/common.sh
  openssh_config_test
  if systemctl is-failed --quiet sslh.service 2>/dev/null; then
    systemctl status sslh.service --no-pager -l || true
    fail "serviço vendor sslh.service ficou em estado failed"
  fi
  [[ "$(stat -c '%a' /var/lib/oneplus/users)" == 700 ]] || fail "permissão inesperada em users metadata"
  [[ "$(stat -c '%a' /var/lib/oneplus/history)" == 700 ]] || fail "permissão inesperada em history"
  ! grep -R -nE 'rm[[:space:]]+-rf[[:space:]]+/(bin|usr|etc)([[:space:]]|$)' /opt/oneplus >/dev/null 2>&1 || fail "padrão destrutivo encontrado após instalação"
  pass "health check + OpenSSH + isolamento sslh vendor + permissões + contrato destrutivo"
}

write_reboot_state() {
  local boot_id list="" u
  boot_id=$(cat /proc/sys/kernel/random/boot_id)
  for u in oneplus-dropbear.service oneplus-websocket.service oneplus-tls.service oneplus-badvpn.service oneplus-slowdns.service oneplus-mux.service oneplus-openvpn.service oneplus-history.timer oneplus-user-maintenance.timer oneplus-openvpn-pki-maintenance.timer; do
    if systemctl is-enabled --quiet "$u" 2>/dev/null; then
      list+="${list:+,}${u}"
    fi
  done
  umask 077
  cat > "$INTEGRATION_ROOT/reboot.state" <<EOF2
VERSION=${CURRENT_VERSION}
BOOT_ID=${boot_id}
ENABLED_UNITS=${list}
EOF2
}

install_reboot_resume_unit() {
  cat > /etc/systemd/system/oneplus-integration-resume.service <<'EOF2'
[Unit]
Description=OnePlus disposable-VM post-reboot integration check
After=network-online.target
Wants=network-online.target
ConditionPathExists=/var/lib/oneplus/integration/reboot.state

[Service]
Type=oneshot
Environment=ONEPLUS_INTEGRATION_CONFIRM=DESTROYABLE_VM
ExecStart=/opt/oneplus/scripts/integration-ubuntu.sh --post-reboot

[Install]
WantedBy=multi-user.target
EOF2
  chmod 0644 /etc/systemd/system/oneplus-integration-resume.service
  systemctl daemon-reload
  systemctl enable oneplus-integration-resume.service
}

arm_reboot() {
  require_disposable_vm
  [[ -x /usr/local/bin/oneplus ]] || fail "OnePlus ainda não está instalado"
  prepare_report
  write_reboot_state
  install_reboot_resume_unit
  pass "checagem pós-reboot armada"
  printf '\nAgora, NESTA VM DESCARTÁVEL, execute manualmente:\n  sudo reboot\n\n'
  printf 'Após o boot, confira:\n  sudo systemctl status oneplus-integration-resume.service --no-pager\n  sudo cat /var/lib/oneplus/integration/post-reboot.result\n'
}

state_value() {
  local key="$1" f="$INTEGRATION_ROOT/reboot.state"
  awk -F= -v k="$key" '$1==k {sub(/^[^=]*=/,""); print; exit}' "$f" 2>/dev/null
}

post_reboot() {
  require_disposable_vm
  prepare_report
  assert_file "$INTEGRATION_ROOT/reboot.state"
  local old_boot current_boot expected_version units unit failed=0
  old_boot=$(state_value BOOT_ID)
  expected_version=$(state_value VERSION)
  units=$(state_value ENABLED_UNITS)
  current_boot=$(cat /proc/sys/kernel/random/boot_id)
  [[ -n "$old_boot" && "$current_boot" != "$old_boot" ]] || fail "boot_id não mudou; este não é um teste pós-reboot real"
  [[ "$(/usr/local/bin/oneplus --version | awk '{print $2}')" == "$expected_version" ]] || fail "versão mudou após reboot"
  /usr/local/bin/oneplus --check
  IFS=',' read -r -a arr <<< "$units"
  for unit in "${arr[@]}"; do
    [[ -n "$unit" ]] || continue
    if systemctl is-active --quiet "$unit"; then
      pass "pós-reboot ativo: $unit"
    else
      journalctl -u "$unit" -n 60 --no-pager || true
      printf '[FAIL] pós-reboot inativo: %s\n' "$unit"
      failed=1
    fi
  done
  if (( failed )); then
    printf 'FAIL\n' > "$INTEGRATION_ROOT/post-reboot.result"
    chmod 0600 "$INTEGRATION_ROOT/post-reboot.result"
    exit 1
  fi
  grep -Fq "ONEPLUS-INTEGRATION-PRESERVE" /etc/oneplus/history.env || fail "configuração preservada desapareceu após reboot"
  printf 'PASS version=%s boot_id=%s tested_at=%s\n' "$expected_version" "$current_boot" "$(date -u +%FT%TZ)" > "$INTEGRATION_ROOT/post-reboot.result"
  chmod 0600 "$INTEGRATION_ROOT/post-reboot.result"
  systemctl disable oneplus-integration-resume.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/oneplus-integration-resume.service
  systemctl daemon-reload
  pass "REBOOT REAL VALIDADO"
}

ci_main() {
  require_disposable_vm
  prepare_report
  assert_cmd systemctl
  assert_cmd ss
  assert_cmd python3
  bash "$ROOT_DIR/scripts/validate.sh"
  run_install_or_upgrade
  start_upstream
  smoke_dropbear
  smoke_websocket
  smoke_tls
  smoke_badvpn
  smoke_slowdns
  smoke_openvpn
  smoke_mux
  smoke_history_and_timers
  smoke_security_contracts
  write_reboot_state
  pass "INTEGRATION HOSTED VM: OK"
  log "Relatório: $REPORT"
  log "Estado para teste de reboot manual: $INTEGRATION_ROOT/reboot.state"
}

case "$MODE" in
  --ci) ci_main ;;
  --arm-reboot) arm_reboot ;;
  --post-reboot) post_reboot ;;
  *)
    cat >&2 <<'USAGE'
Uso:
  scripts/integration-ubuntu.sh --ci
  scripts/integration-ubuntu.sh --arm-reboot
  scripts/integration-ubuntu.sh --post-reboot   # chamado pelo systemd

SEGURANÇA: somente VM/VPS descartável.
Fora do GitHub Actions, exige ONEPLUS_INTEGRATION_CONFIRM=DESTROYABLE_VM.
USAGE
    exit 2
    ;;
esac
