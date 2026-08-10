#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail(){ echo "[ERRO] $*" >&2; exit 1; }
ok(){ echo "[OK] $*"; }

# Firewall isolado: nenhuma limpeza global e NAT somente em tabela OnePlus.
grep -Fq 'table inet oneplus_filter' "$ROOT_DIR/libexec/run-firewall" || fail "Tabela filter própria ausente."
grep -Fq 'table ip oneplus_nat' "$ROOT_DIR/libexec/run-firewall" || fail "Tabela NAT própria ausente."
! grep -Eq 'nft[[:space:]]+flush[[:space:]]+ruleset|iptables[[:space:]].*-F' "$ROOT_DIR/libexec/run-firewall" || fail "Limpeza global detectada."
grep -Fq 'ip saddr ${network}/24 oifname "${egress}" counter masquerade' "$ROOT_DIR/libexec/run-firewall" || fail "Masquerade restrito à rede/interface não encontrado."
ok "Firewall isolado validado."

# OpenVPN só anuncia full tunnel quando explicitamente habilitado.
grep -Fq 'if [[ "$full_tunnel" == yes ]]' "$ROOT_DIR/libexec/run-openvpn" || fail "Full tunnel não é condicional."
grep -Fq 'redirect-gateway def1 bypass-dhcp' "$ROOT_DIR/libexec/run-openvpn" || fail "Push redirect-gateway ausente."
ok "Full tunnel opcional validado."

# Backup: criptografia obrigatória e sem /etc/shadow inteiro.
grep -Fq 'age -p -o "$outfile"' "$ROOT_DIR/modules/backup.sh" || fail "Backup não usa age passphrase."
! grep -Fq 'backup_copy_if_exists /etc/shadow' "$ROOT_DIR/modules/backup.sh" || fail "Backup copia /etc/shadow inteiro."
grep -Fq 'getent shadow "$user"' "$ROOT_DIR/modules/backup.sh" || fail "Backup não limita hashes aos usuários gerenciados."
grep -Fq 'backup_archive_safe' "$ROOT_DIR/modules/backup.sh" || fail "Restauração sem validação de caminhos."
! grep -Eq 'rsync[[:space:]]+-aL|cp[[:space:]]+-L' "$ROOT_DIR/modules/backup.sh" || fail "Backup segue links simbólicos."
grep -Fq 't!="-" && t!="d"' "$ROOT_DIR/modules/backup.sh" || fail "Restauração não restringe tipos de entrada TAR."
grep -Fq 'não é uma conta OnePlus validada' "$ROOT_DIR/modules/backup.sh" || fail "Restauração pode alterar conta externa preexistente."
ok "Backup seguro validado."

# Update: assinatura antes do install.sh.
line_verify=$(grep -n 'verify_release_tree "$src" "$tag"' "$ROOT_DIR/modules/update.sh" | head -1 | cut -d: -f1)
line_install=$(grep -n 'bash "$src/install.sh"' "$ROOT_DIR/modules/update.sh" | head -1 | cut -d: -f1)
[[ "$line_verify" =~ ^[0-9]+$ && "$line_install" =~ ^[0-9]+$ && "$line_verify" -lt "$line_install" ]] || fail "Instalador pode rodar antes da verificação assinada."
grep -Fq 'minisign -Vm' "$ROOT_DIR/modules/update.sh" || fail "Verificação minisign ausente."
grep -Fq 'sha256sum -c release/SHA256SUMS' "$ROOT_DIR/modules/update.sh" || fail "Verificação SHA-256 ausente."
ok "Atualização fail-closed validada."

# Chave privada de assinatura nunca deve ser versionada.
if find "$ROOT_DIR" -type f \( -name 'minisign.key' -o -name '*.sec' \) | grep -q .; then fail "Chave secreta encontrada."; fi
ok "Nenhuma chave secreta de release no projeto."

echo "OPERATIONS TESTS: OK"
