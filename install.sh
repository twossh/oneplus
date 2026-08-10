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
apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential \
  openssh-server iproute2 procps util-linux \
  rsync dnsutils lsof less

# dnstt v1.20260501.0 requer Go 1.24+.
if apt-cache show golang-1.24-go >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends golang-1.24-go
else
  apt-get install -y --no-install-recommends golang-go
fi

install -d -m 0755 /opt/oneplus /usr/local/lib/oneplus/bin /etc/oneplus /var/lib/oneplus
rsync -a --delete \
  --exclude '.git' \
  --exclude '.github' \
  --exclude 'dist' \
  --exclude '*.zip' \
  --exclude '*.sha256' \
  "$SELF_DIR/" /opt/oneplus/

find /opt/oneplus -type f -name '*.sh' -exec chmod 0755 {} +
chmod 0755 /opt/oneplus/bin/oneplus /opt/oneplus/libexec/run-badvpn /opt/oneplus/libexec/run-slowdns
chmod 0644 /opt/oneplus/VERSION /opt/oneplus/README.md /opt/oneplus/CHANGELOG.md 2>/dev/null || true

if ! getent passwd oneplus-badvpn >/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin oneplus-badvpn
fi
if ! getent passwd oneplus-dnstt >/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin oneplus-dnstt
fi

[[ -e /etc/oneplus/oneplus.conf ]] || install -m 0644 /opt/oneplus/defaults/oneplus.conf /etc/oneplus/oneplus.conf
[[ -e /etc/oneplus/badvpn.env ]] || install -m 0640 -o root -g oneplus-badvpn /opt/oneplus/defaults/badvpn.env /etc/oneplus/badvpn.env
[[ -e /etc/oneplus/slowdns.env ]] || install -m 0640 -o root -g oneplus-dnstt /opt/oneplus/defaults/slowdns.env /etc/oneplus/slowdns.env
chown root:root /etc/oneplus/oneplus.conf && chmod 0644 /etc/oneplus/oneplus.conf
chown root:oneplus-badvpn /etc/oneplus/badvpn.env && chmod 0640 /etc/oneplus/badvpn.env
chown root:oneplus-dnstt /etc/oneplus/slowdns.env && chmod 0640 /etc/oneplus/slowdns.env
install -d -m 0750 -o root -g oneplus-dnstt /etc/oneplus/slowdns

install -m 0644 /opt/oneplus/systemd/oneplus-badvpn.service /etc/systemd/system/oneplus-badvpn.service
install -m 0644 /opt/oneplus/systemd/oneplus-slowdns.service /etc/systemd/system/oneplus-slowdns.service
ln -sfn /opt/oneplus/bin/oneplus /usr/local/bin/oneplus

if command -v systemd-analyze >/dev/null 2>&1; then
  info "Validando unidades systemd..."
  systemd-analyze verify \
    /etc/systemd/system/oneplus-badvpn.service \
    /etc/systemd/system/oneplus-slowdns.service
fi
systemctl daemon-reload

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

printf "\n%bInstalação concluída.%b\n" "$C_GREEN" "$C_RESET"
printf "Execute: %boneplus%b\n" "$C_BOLD" "$C_RESET"
printf "Verifique: %boneplus --check%b\n" "$C_BOLD" "$C_RESET"
printf "BadVPN e SlowDNS foram instalados, mas permanecem desabilitados até serem configurados no menu.\n"
