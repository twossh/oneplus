#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

fail() { printf '[ERRO] %s\n' "$*" >&2; FAILED=1; }
ok()   { printf '[OK] %s\n' "$*"; }

required=(
  VERSION README.md CHANGELOG.md setup.sh install.sh uninstall.sh
  bin/oneplus lib/common.sh lib/os.sh
  modules/system.sh modules/ssh.sh modules/badvpn.sh modules/slowdns.sh
  libexec/run-badvpn libexec/run-slowdns
  defaults/oneplus.conf defaults/badvpn.env defaults/slowdns.env
  systemd/oneplus-badvpn.service systemd/oneplus-slowdns.service
)

for rel in "${required[@]}"; do
  [[ -f "$ROOT_DIR/$rel" ]] || fail "Arquivo obrigatório ausente: $rel"
done

VERSION=$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || true)
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION inválida: '$VERSION'"
grep -Fq "# OnePlus v${VERSION}" "$ROOT_DIR/README.md" || fail "README não corresponde à versão ${VERSION}."

mapfile -t shell_files < <(
  {
    find "$ROOT_DIR" -type f -name '*.sh' -not -path '*/.git/*' -print
    printf '%s\n' "$ROOT_DIR/bin/oneplus" "$ROOT_DIR/libexec/run-badvpn" "$ROOT_DIR/libexec/run-slowdns"
  } | sort -u
)

for f in "${shell_files[@]}"; do
  [[ -f "$f" ]] || continue
  if grep -q $'\r' "$f"; then
    fail "CRLF detectado: ${f#"$ROOT_DIR/"}"
  fi
  if ! bash -n "$f"; then
    fail "Erro de sintaxe Bash: ${f#"$ROOT_DIR/"}"
  fi
done
(( FAILED == 0 )) && ok "Sintaxe Bash e finais de linha validados."

executables=(setup.sh install.sh uninstall.sh bin/oneplus lib/common.sh lib/os.sh \
  modules/system.sh modules/ssh.sh modules/badvpn.sh modules/slowdns.sh \
  libexec/run-badvpn libexec/run-slowdns scripts/validate.sh)
for rel in "${executables[@]}"; do
  [[ -x "$ROOT_DIR/$rel" ]] || fail "Permissão executável ausente: $rel"
done
(( FAILED == 0 )) && ok "Permissões executáveis validadas."

# Padrões destrutivos que não pertencem ao OnePlus.
forbidden_regex=(
  'rm[[:space:]]+-rf[[:space:]]+/?bin([[:space:]]|$)'
  'crontab[[:space:]]+-r([[:space:]]|$)'
  'iptables([[:space:]][^;|&]*)?[[:space:]]+-F([[:space:]]|$)'
  'nft[[:space:]]+flush[[:space:]]+ruleset'
  'chmod[[:space:]]+(-R[[:space:]]+)?777([[:space:]]|$)'
)
for re in "${forbidden_regex[@]}"; do
  if grep -RInE --exclude-dir=.git --exclude='validate.sh' "$re" "$ROOT_DIR" >/tmp/oneplus-validate-match.$$ 2>/dev/null; then
    cat /tmp/oneplus-validate-match.$$ >&2
    fail "Padrão destrutivo proibido encontrado."
  fi
  rm -f /tmp/oneplus-validate-match.$$
done

if grep -RIl --exclude-dir=.git --exclude='validate.sh' -- '-----BEGIN .*PRIVATE KEY-----' "$ROOT_DIR" | grep -q .; then
  fail "Material de chave privada encontrado no repositório."
else
  ok "Nenhuma chave privada embutida detectada."
fi

if grep -RInE --exclude-dir=.git --exclude='validate.sh' "(^|[[:space:]])(eval|source)[[:space:]]+[/\"']?etc/oneplus/.*\\.env" "$ROOT_DIR" >/dev/null 2>&1; then
  fail "Arquivo .env do OnePlus não deve ser executado com source/eval."
else
  ok "Leitura segura de arquivos .env validada."
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf '\nValidação falhou.\n' >&2
  exit 1
fi
printf '\nVALIDATION: OK (OnePlus %s)\n' "$VERSION"
