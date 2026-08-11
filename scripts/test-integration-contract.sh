#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/integration-ubuntu.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/integration-ubuntu.yml"

fail() { echo "[FAIL] $*" >&2; exit 1; }
ok() { echo "[OK] $*"; }

[[ -r "$SCRIPT" && -r "$WORKFLOW" ]] || fail "arquivos de integração ausentes"
grep -Fq 'ONEPLUS_INTEGRATION_CONFIRM' "$SCRIPT" || fail "guarda de VM descartável ausente"
grep -Fq 'DESTROYABLE_VM' "$SCRIPT" || fail "token de confirmação explícita ausente"
grep -Fq 'GITHUB_ACTIONS' "$SCRIPT" || fail "detecção do runner GitHub ausente"
grep -Fq 'boot_id' "$SCRIPT" || fail "validação de reboot real por boot_id ausente"
grep -Fq 'oneplus --check' "$SCRIPT" || fail "health check não faz parte da integração"
grep -Fq 'sshd -t' "$SCRIPT" || fail "validação do OpenSSH não faz parte da integração"
grep -Fq '127.0.0.1' "$SCRIPT" || fail "smoke tests devem usar loopback"

if grep -Eq '^[[:space:]]*(reboot|shutdown|poweroff|systemctl[[:space:]]+reboot)([[:space:]]|$)' "$SCRIPT"; then
  fail "suíte não pode reiniciar a máquina automaticamente"
fi
ok "reboot exige ação manual explícita"

if grep -Eq '^[A-Z0-9_]*PORT=(22|53|80|443)$' "$SCRIPT"; then
  fail "integração não deve configurar portas públicas/padrão de produção diretamente"
fi
ok "smoke tests usam portas altas dedicadas"

grep -Fq 'runs-on: ubuntu-24.04' "$WORKFLOW" || fail "workflow não está fixado em Ubuntu 24.04"
grep -Fq 'timeout-minutes:' "$WORKFLOW" || fail "workflow precisa de timeout"
grep -Fq 'permissions:' "$WORKFLOW" || fail "workflow deve declarar permissões"
grep -Fq 'contents: read' "$WORKFLOW" || fail "workflow deve usar somente leitura do repositório"
grep -Fq 'schedule:' "$WORKFLOW" || fail "workflow semanal de regressão ausente"
grep -Fq 'actions/upload-artifact@v4' "$WORKFLOW" || fail "relatório de integração não é publicado como artifact"
if grep -Eq 'runs-on:[[:space:]]*self-hosted|secrets\.' "$WORKFLOW"; then
  fail "workflow padrão não deve usar runner self-hosted nem segredos"
fi
ok "workflow usa VM GitHub descartável e sem segredos"

echo 'INTEGRATION CONTRACT TESTS: OK'
