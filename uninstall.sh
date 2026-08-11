#!/usr/bin/env bash
set -Eeuo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SELF_DIR/lib/common.sh"
require_root

warn "Esta remoção desativa apenas componentes OnePlus. Não remove OpenSSH nem pacotes do Ubuntu."
printf "Digite REMOVER para continuar: "
read -r confirm
[[ "$confirm" == "REMOVER" ]] || { info "Cancelado."; exit 0; }

systemctl disable --now oneplus-badvpn.service oneplus-slowdns.service oneplus-dropbear.service oneplus-websocket.service oneplus-tls.service oneplus-openvpn.service oneplus-mux.service oneplus-firewall.service oneplus-user-maintenance.timer oneplus-openvpn-pki-maintenance.timer oneplus-history.timer 2>/dev/null || true
systemctl stop oneplus-user-maintenance.service oneplus-openvpn-pki-maintenance.service oneplus-history.service 2>/dev/null || true
rm -f /etc/systemd/system/oneplus-badvpn.service /etc/systemd/system/oneplus-slowdns.service \
  /etc/systemd/system/oneplus-dropbear.service /etc/systemd/system/oneplus-websocket.service /etc/systemd/system/oneplus-tls.service \
  /etc/systemd/system/oneplus-openvpn.service /etc/systemd/system/oneplus-openvpn-pki-maintenance.service /etc/systemd/system/oneplus-openvpn-pki-maintenance.timer /etc/systemd/system/oneplus-mux.service /etc/systemd/system/oneplus-firewall.service \
  /etc/systemd/system/oneplus-user-maintenance.service /etc/systemd/system/oneplus-user-maintenance.timer \
  /etc/systemd/system/oneplus-history.service /etc/systemd/system/oneplus-history.timer
rm -f /etc/security/limits.d/90-oneplus.conf /etc/pam.d/oneplus-openvpn /etc/sysctl.d/90-oneplus-forwarding.conf
rm -f /usr/local/bin/oneplus
rm -rf /opt/oneplus /usr/local/lib/oneplus
if [[ -e /etc/ssh/sshd_config.d/60-oneplus.conf ]]; then
  ssh_backup=$(mktemp)
  cp -a /etc/ssh/sshd_config.d/60-oneplus.conf "$ssh_backup"
  rm -f /etc/ssh/sshd_config.d/60-oneplus.conf
  if sshd -t; then
    systemctl daemon-reload
    systemctl restart ssh.service
    rm -f "$ssh_backup"
  else
    install -m 0644 "$ssh_backup" /etc/ssh/sshd_config.d/60-oneplus.conf
    rm -f "$ssh_backup"
    error "A remoção do snippet deixaria o OpenSSH inválido; configuração OnePlus restaurada."
  fi
fi
systemctl daemon-reload
ok "Executáveis e serviços OnePlus removidos. /etc/oneplus e os metadados foram preservados para segurança/backup."
warn "Contas SSH criadas pelo OnePlus não foram removidas automaticamente."
