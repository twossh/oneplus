#!/usr/bin/env bash
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/common.sh"
source "$SELF_DIR/lib/os.sh"

trap 'error "Falha na linha ${LINENO}. Instalação interrompida com segurança."' ERR

require_root
check_supported_os

if [[ -f "$SELF_DIR/scripts/validate.sh" ]]; then
  info "Validando arquivos do OnePlus antes da instalação..."
  bash "$SELF_DIR/scripts/validate.sh"
fi

printf "%bOnePlus Installer%b\n" "$C_BOLD$C_CYAN" "$C_RESET"
info "Sistema: $(show_os_line)"
info "Arquitetura: $(dpkg --print-architecture)"

export DEBIAN_FRONTEND=noninteractive
apt-get update
# Dropbear e stunnel ficam no componente Universe em Ubuntu. Imagens mínimas
# podem não trazê-lo habilitado, então fazemos um fallback controlado.
if ! apt-cache show dropbear-bin >/dev/null 2>&1 || ! apt-cache show stunnel4 >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends software-properties-common
  add-apt-repository -y universe
  apt-get update
fi
apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential \
  openssh-server dropbear-bin stunnel4 python3 \
  iproute2 procps util-linux passwd libpam-modules openssl \
  rsync dnsutils lsof less

info "Validando componentes Python após instalar dependências..."
python3 -m py_compile "$SELF_DIR/libexec/websocket_proxy.py" "$SELF_DIR/scripts/test-websocket.py"

# dnstt v1.20260501.0 requer Go 1.24+.
if apt-cache show golang-1.24-go >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends golang-1.24-go
else
  apt-get install -y --no-install-recommends golang-go
fi

install -d -m 0755 /opt/oneplus /usr/local/lib/oneplus/bin /etc/oneplus /var/lib/oneplus
install -d -m 0700 /var/lib/oneplus/users
install -d -m 0700 -o root -g root /etc/oneplus/dropbear
rsync -a --delete \
  --exclude '.git' \
  --exclude '.github' \
  --exclude 'dist' \
  --exclude '*.zip' \
  --exclude '*.sha256' \
  "$SELF_DIR/" /opt/oneplus/

find /opt/oneplus -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 /opt/oneplus/bin/oneplus /opt/oneplus/libexec/* /opt/oneplus/scripts/*.sh /opt/oneplus/scripts/*.py
chmod 0644 /opt/oneplus/VERSION /opt/oneplus/README.md /opt/oneplus/CHANGELOG.md 2>/dev/null || true

ensure_service_account() {
  local name="$1"
  getent group "$name" >/dev/null 2>&1 || groupadd --system "$name"
  if ! getent passwd "$name" >/dev/null 2>&1; then
    useradd --system --gid "$name" --no-create-home --shell /usr/sbin/nologin "$name"
  else
    usermod -g "$name" "$name" >/dev/null 2>&1 || true
  fi
}
ensure_service_account oneplus-badvpn
ensure_service_account oneplus-dnstt
ensure_service_account oneplus-ws
ensure_service_account oneplus-tls
if ! getent group oneplus-users >/dev/null; then
  groupadd --system oneplus-users
fi

[[ -e /etc/oneplus/oneplus.conf ]] || install -m 0644 /opt/oneplus/defaults/oneplus.conf /etc/oneplus/oneplus.conf
[[ -e /etc/oneplus/badvpn.env ]] || install -m 0640 -o root -g oneplus-badvpn /opt/oneplus/defaults/badvpn.env /etc/oneplus/badvpn.env
[[ -e /etc/oneplus/slowdns.env ]] || install -m 0640 -o root -g oneplus-dnstt /opt/oneplus/defaults/slowdns.env /etc/oneplus/slowdns.env
[[ -e /etc/oneplus/users.conf ]] || install -m 0644 -o root -g root /opt/oneplus/defaults/users.conf /etc/oneplus/users.conf
[[ -e /etc/oneplus/dropbear.env ]] || install -m 0640 -o root -g root /opt/oneplus/defaults/dropbear.env /etc/oneplus/dropbear.env
[[ -e /etc/oneplus/websocket.env ]] || install -m 0640 -o root -g oneplus-ws /opt/oneplus/defaults/websocket.env /etc/oneplus/websocket.env
[[ -e /etc/oneplus/tls.env ]] || install -m 0640 -o root -g oneplus-tls /opt/oneplus/defaults/tls.env /etc/oneplus/tls.env
chown root:root /etc/oneplus/oneplus.conf && chmod 0644 /etc/oneplus/oneplus.conf
chown root:oneplus-badvpn /etc/oneplus/badvpn.env && chmod 0640 /etc/oneplus/badvpn.env
chown root:oneplus-dnstt /etc/oneplus/slowdns.env && chmod 0640 /etc/oneplus/slowdns.env
chown root:root /etc/oneplus/users.conf && chmod 0644 /etc/oneplus/users.conf
chown root:root /etc/oneplus/dropbear.env && chmod 0640 /etc/oneplus/dropbear.env
chown root:oneplus-ws /etc/oneplus/websocket.env && chmod 0640 /etc/oneplus/websocket.env
chown root:oneplus-tls /etc/oneplus/tls.env && chmod 0640 /etc/oneplus/tls.env
install -d -m 0750 -o root -g oneplus-dnstt /etc/oneplus/slowdns
install -d -m 0750 -o root -g oneplus-tls /etc/oneplus/tls

install -m 0644 /opt/oneplus/systemd/oneplus-badvpn.service /etc/systemd/system/oneplus-badvpn.service
install -m 0644 /opt/oneplus/systemd/oneplus-slowdns.service /etc/systemd/system/oneplus-slowdns.service
install -m 0644 /opt/oneplus/systemd/oneplus-user-maintenance.service /etc/systemd/system/oneplus-user-maintenance.service
install -m 0644 /opt/oneplus/systemd/oneplus-user-maintenance.timer /etc/systemd/system/oneplus-user-maintenance.timer
install -m 0644 /opt/oneplus/systemd/oneplus-dropbear.service /etc/systemd/system/oneplus-dropbear.service
install -m 0644 /opt/oneplus/systemd/oneplus-websocket.service /etc/systemd/system/oneplus-websocket.service
install -m 0644 /opt/oneplus/systemd/oneplus-tls.service /etc/systemd/system/oneplus-tls.service
ln -sfn /opt/oneplus/bin/oneplus /usr/local/bin/oneplus

if command -v systemd-analyze >/dev/null 2>&1; then
  info "Validando unidades systemd..."
  systemd-analyze verify \
    /etc/systemd/system/oneplus-badvpn.service \
    /etc/systemd/system/oneplus-slowdns.service \
    /etc/systemd/system/oneplus-user-maintenance.service \
    /etc/systemd/system/oneplus-user-maintenance.timer \
    /etc/systemd/system/oneplus-dropbear.service \
    /etc/systemd/system/oneplus-websocket.service \
    /etc/systemd/system/oneplus-tls.service
fi
systemctl daemon-reload
/opt/oneplus/modules/users.sh init

info "Instalando BadVPN UDPGW (compatibilidade SSH UDP)..."
/opt/oneplus/modules/badvpn.sh install-binary

info "Instalando SlowDNS/dnstt v1.20260501.0..."
/opt/oneplus/modules/slowdns.sh install-binary

if sshd -t; then
  ok "OpenSSH atual está válido; nenhuma configuração SSH foi substituída."
else
  error "A configuração OpenSSH existente já contém erro. O OnePlus não a modificou."
  exit 1
fi

if [[ "$(readlink -f /usr/local/bin/oneplus)" != "/opt/oneplus/bin/oneplus" ]]; then
  error "Launcher global não aponta para /opt/oneplus/bin/oneplus."
  exit 1
fi

systemctl enable --now oneplus-user-maintenance.timer

printf "\n%bInstalação concluída.%b\n" "$C_GREEN" "$C_RESET"
printf "Execute: %boneplus%b\n" "$C_BOLD" "$C_RESET"
printf "Verifique: %boneplus --check%b\n" "$C_BOLD" "$C_RESET"
printf "Dropbear, WebSocket, TLS, BadVPN e SlowDNS permanecem desabilitados até serem configurados no menu.\n"
printf "A manutenção segura de expiração/limites de usuários está ativa via systemd timer.\n"
