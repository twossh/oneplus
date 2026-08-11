#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_HARDENING_REPORT_DIR=/var/log/oneplus/reports
HARDEN_PASS=0
HARDEN_WARN=0
HARDEN_INFO=0
HARDEN_FAIL=0

hardening_emit() {
  local level="$1"; shift
  case "$level" in
    PASS) HARDEN_PASS=$((HARDEN_PASS + 1)); printf '%b[PASS]%b %s\n' "$C_GREEN" "$C_RESET" "$*" ;;
    WARN) HARDEN_WARN=$((HARDEN_WARN + 1)); printf '%b[WARN]%b %s\n' "$C_YELLOW" "$C_RESET" "$*" ;;
    FAIL) HARDEN_FAIL=$((HARDEN_FAIL + 1)); printf '%b[FAIL]%b %s\n' "$C_RED" "$C_RESET" "$*" ;;
    INFO) HARDEN_INFO=$((HARDEN_INFO + 1)); printf '%b[INFO]%b %s\n' "$C_BLUE" "$C_RESET" "$*" ;;
  esac
}

hardening_cert_check() {
  local label="$1" file="$2"
  [[ -s "$file" ]] || return 0
  if ! openssl x509 -in "$file" -noout >/dev/null 2>&1; then
    hardening_emit FAIL "$label: certificado inválido ($file)"
  elif openssl x509 -in "$file" -checkend 2592000 -noout >/dev/null 2>&1; then
    hardening_emit PASS "$label: validade superior a 30 dias"
  else
    local end
    end=$(openssl x509 -in "$file" -noout -enddate 2>/dev/null | cut -d= -f2-)
    hardening_emit WARN "$label: expira em menos de 30 dias (${end:-data desconhecida})"
  fi
}

hardening_audit() {
  HARDEN_PASS=0; HARDEN_WARN=0; HARDEN_INFO=0; HARDEN_FAIL=0
  printf '%bONEPLUS HARDENING AUDIT%b\n' "$C_BOLD$C_CYAN" "$C_RESET"
  printf 'Gerado: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Modo: AUDIT-ONLY — nenhuma configuração do host será alterada.\n\n'

  if check_supported_os >/dev/null 2>&1; then
    hardening_emit PASS "Sistema suportado: $(show_os_line 2>/dev/null || true)"
  else
    hardening_emit FAIL "Sistema fora da matriz Ubuntu 24.04+"
  fi

  local sshout rootlogin passwordauth maxauth debianbanner
  if openssh_config_test >/dev/null 2>&1; then
    hardening_emit PASS "OpenSSH: sintaxe válida"
    sshout=$(sshd -T 2>/dev/null || true)
    rootlogin=$(awk '$1=="permitrootlogin"{print $2;exit}' <<< "$sshout")
    passwordauth=$(awk '$1=="passwordauthentication"{print $2;exit}' <<< "$sshout")
    maxauth=$(awk '$1=="maxauthtries"{print $2;exit}' <<< "$sshout")
    debianbanner=$(awk '$1=="debianbanner"{print $2;exit}' <<< "$sshout")
    if [[ "$rootlogin" == yes ]]; then
      hardening_emit WARN "OpenSSH: PermitRootLogin=yes; prefira no/prohibit-password quando compatível"
    else
      hardening_emit PASS "OpenSSH: login root por senha não está liberado (PermitRootLogin=${rootlogin:-N/D})"
    fi
    if [[ "$maxauth" =~ ^[0-9]+$ && "$maxauth" -le 6 ]]; then
      hardening_emit PASS "OpenSSH: MaxAuthTries=${maxauth}"
    else
      hardening_emit WARN "OpenSSH: MaxAuthTries=${maxauth:-N/D}; revise tentativas de autenticação"
    fi
    hardening_emit INFO "OpenSSH: PasswordAuthentication=${passwordauth:-N/D} (OnePlus suporta contas gerenciadas por senha)"
    if [[ "$debianbanner" == no ]]; then
      hardening_emit PASS "OpenSSH: DebianBanner=no reduz divulgação do sistema operacional"
    else
      hardening_emit INFO "OpenSSH: DebianBanner=${debianbanner:-N/D}; ocultar banner do SO é opcional"
    fi
  else
    hardening_emit FAIL "OpenSSH: configuração inválida"
  fi

  if dpkg-query -W -f='${Status}' unattended-upgrades 2>/dev/null | grep -Fq 'install ok installed'; then
    hardening_emit PASS "unattended-upgrades instalado"
    local aptdump unattended lists
    aptdump=$(apt-config dump 2>/dev/null || true)
    unattended=$(awk '$1=="APT::Periodic::Unattended-Upgrade" {gsub(/[";]/,"",$2); print $2; exit}' <<< "$aptdump")
    lists=$(awk '$1=="APT::Periodic::Update-Package-Lists" {gsub(/[";]/,"",$2); print $2; exit}' <<< "$aptdump")
    if [[ "$unattended" == 1 && "$lists" == 1 ]]; then
      hardening_emit PASS "Atualizações automáticas de segurança aparentam estar habilitadas diariamente"
    else
      hardening_emit WARN "APT periódico: Update-Package-Lists=${lists:-N/D}, Unattended-Upgrade=${unattended:-N/D}"
    fi
  else
    hardening_emit WARN "unattended-upgrades não está instalado"
  fi

  if systemctl is-active --quiet apparmor.service 2>/dev/null; then
    hardening_emit PASS "AppArmor ativo"
  else
    hardening_emit WARN "AppArmor não aparece ativo"
  fi

  local ntp
  ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
  [[ "$ntp" == yes ]] && hardening_emit PASS "Relógio sincronizado via NTP" || hardening_emit WARN "NTP não confirmado como sincronizado"

  local failed_units
  failed_units=$(systemctl --failed --no-legend --plain 2>/dev/null | awk 'NF{n++} END{print n+0}')
  [[ "$failed_units" == 0 ]] && hardening_emit PASS "Nenhuma unidade systemd em estado failed" || hardening_emit WARN "$failed_units unidade(s) systemd em estado failed"

  [[ -e /var/run/reboot-required ]] && hardening_emit WARN "Reboot requerido por atualização do sistema" || hardening_emit PASS "Nenhum reboot pendente sinalizado"

  local insecure_count
  insecure_count=$(find /etc/oneplus -xdev \( -type f -o -type d \) -perm /0022 -print 2>/dev/null | wc -l | tr -d ' ')
  [[ "$insecure_count" == 0 ]] && hardening_emit PASS "/etc/oneplus sem arquivos/diretórios graváveis por grupo/outros" || hardening_emit FAIL "/etc/oneplus possui $insecure_count item(ns) graváveis por grupo/outros"

  local exposed_keys
  exposed_keys=$(find /etc/oneplus -xdev -type f -name '*.key' -perm -0004 -print 2>/dev/null | wc -l | tr -d ' ')
  [[ "$exposed_keys" == 0 ]] && hardening_emit PASS "Chaves privadas OnePlus não estão legíveis por 'other'" || hardening_emit FAIL "$exposed_keys chave(s) privada(s) OnePlus legíveis por 'other'"

  if [[ -r /etc/oneplus/update.pub ]]; then
    hardening_emit PASS "Chave pública do canal de atualização instalada"
  else
    hardening_emit INFO "Chave pública do atualizador assinado ainda não configurada"
  fi

  hardening_cert_check "OpenVPN servidor" /etc/oneplus/openvpn/pki/server.crt
  hardening_cert_check "TLS/Stunnel" /etc/oneplus/tls/server.crt

  local listeners
  listeners=$(ss -H -lntup 2>/dev/null | awk '$5 ~ /(^|\])0\.0\.0\.0:|\[::\]:|\*:/ {n++} END{print n+0}')
  hardening_emit INFO "Listeners TCP/UDP potencialmente públicos detectados: ${listeners:-0} (revise em 'oneplus firewall')"

  if command_exists ufw; then
    local ufwstate
    ufwstate=$(ufw status 2>/dev/null | awk 'NR==1{print $2}' || true)
    [[ "$ufwstate" == active ]] && hardening_emit PASS "UFW ativo" || hardening_emit INFO "UFW não está ativo; pode haver nftables ou firewall do provedor"
  else
    hardening_emit INFO "UFW não instalado; o OnePlus não força um firewall externo"
  fi

  if command_exists nft && nft list table inet oneplus_filter >/dev/null 2>&1; then
    hardening_emit PASS "Tabela nftables OnePlus presente"
  else
    hardening_emit INFO "Tabela nftables OnePlus não está ativa"
  fi

  local forwarding nat_enabled
  forwarding=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo N/D)
  nat_enabled=$(awk -F= '$1=="OPENVPN_NAT_ENABLED"{print $2;exit}' /etc/oneplus/firewall.env 2>/dev/null || true)
  if [[ "$nat_enabled" == yes && "$forwarding" == 1 ]]; then
    hardening_emit PASS "IPv4 forwarding ativo conforme NAT OpenVPN OnePlus"
  elif [[ "$forwarding" == 1 ]]; then
    hardening_emit INFO "IPv4 forwarding está ativo; confirme se é necessário para outras funções"
  else
    hardening_emit INFO "IPv4 forwarding=${forwarding}"
  fi

  if [[ -s /root/.ssh/authorized_keys ]]; then
    hardening_emit INFO "root possui authorized_keys; revise as chaves administrativas periodicamente"
  else
    hardening_emit INFO "root sem authorized_keys detectado"
  fi

  printf '\nResumo: PASS=%d WARN=%d FAIL=%d INFO=%d\n' "$HARDEN_PASS" "$HARDEN_WARN" "$HARDEN_FAIL" "$HARDEN_INFO"
  printf 'Nenhuma alteração foi aplicada.\n'
}

hardening_save_report() {
  local now outfile tmp
  now=$(date -u +%Y%m%dT%H%M%SZ)
  install -d -m 0700 -o root -g root "$ONEPLUS_HARDENING_REPORT_DIR"
  outfile="$ONEPLUS_HARDENING_REPORT_DIR/hardening-${now}.txt"
  tmp=$(mktemp /tmp/oneplus-hardening.XXXXXX)
  hardening_audit > "$tmp"
  # Remove ANSI colors from the persisted copy only.
  sed -E $'s/\x1B\[[0-9;]*[mK]//g' "$tmp" > "$outfile"
  chmod 0600 "$outfile"
  cat "$tmp"
  rm -f -- "$tmp"
  printf '\nRelatório salvo em: %s\n' "$outfile"
}

hardening_policy() {
  cat <<'EOF2'
Política de hardening do OnePlus

- AUDIT-ONLY por padrão e nesta versão.
- O módulo não executa apt upgrade/install, não reinicia serviços, não altera sysctl,
  não edita sshd_config e não cria/remove regras de firewall.
- PasswordAuthentication não é marcado automaticamente como falha porque o OnePlus
  administra contas SSH por senha quando o operador escolhe esse modelo.
- Portas públicas são inventariadas, não bloqueadas automaticamente.
- Recomendações que podem interromper acesso remoto devem ser aplicadas manualmente,
  após confirmação por console/out-of-band e validação de sshd.
EOF2
}

module_hardening() {
  while true; do
    clear
    printf "%bOnePlus • Hardening audit-only%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf '1) Executar auditoria agora\n'
    printf '2) Executar e salvar relatório root-only\n'
    printf '3) Ver política audit-only\n'
    printf '0) Voltar\n\nEscolha: '
    read -r opt
    case "$opt" in
      1) clear; hardening_audit; pause ;;
      2) clear; hardening_save_report; pause ;;
      3) clear; hardening_policy; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
