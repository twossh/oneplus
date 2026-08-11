#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAILED=0

fail() { printf '[ERRO] %s\n' "$*" >&2; FAILED=1; }
ok()   { printf '[OK] %s\n' "$*"; }

required=(
  VERSION README.md CHANGELOG.md docs/RELEASES.md docs/OPENVPN-PKI-ROTATION.md docs/HARDENING.md release/README.md setup.sh install.sh uninstall.sh scripts/test-users.sh scripts/test-openvpn.sh scripts/test-mux.sh scripts/test-operations.sh scripts/test-release.py scripts/test-update-metadata.py scripts/test-history.py scripts/test-hardening.sh scripts/fix-permissions.sh scripts/git-fix-modes.sh scripts/release-keygen.sh scripts/release-prepare.sh scripts/release-sign.sh
  bin/oneplus lib/common.sh lib/os.sh
  modules/system.sh modules/ssh.sh modules/dropbear.sh modules/websocket.sh modules/tls.sh modules/openvpn.sh modules/mux.sh modules/badvpn.sh modules/slowdns.sh modules/users.sh modules/firewall.sh modules/backup.sh modules/reports.sh modules/diagnostics.sh modules/update.sh modules/history.sh modules/hardening.sh
  libexec/run-badvpn libexec/run-slowdns libexec/run-user-maintenance libexec/run-dropbear libexec/run-websocket libexec/run-tls libexec/run-openvpn libexec/run-openvpn-pki-maintenance libexec/run-mux libexec/run-firewall libexec/run-history libexec/websocket_proxy.py libexec/openvpn_manager.py libexec/openvpn_bind_identity.py libexec/release_verify.py libexec/github_release.py libexec/history_snapshot.py libexec/history_summary.py
  defaults/oneplus.conf defaults/badvpn.env defaults/slowdns.env defaults/users.conf defaults/dropbear.env defaults/websocket.env defaults/tls.env defaults/openvpn.env defaults/mux.env defaults/firewall.env defaults/history.env
  systemd/oneplus-badvpn.service systemd/oneplus-slowdns.service systemd/oneplus-dropbear.service systemd/oneplus-websocket.service systemd/oneplus-tls.service systemd/oneplus-openvpn.service systemd/oneplus-openvpn-pki-maintenance.service systemd/oneplus-openvpn-pki-maintenance.timer systemd/oneplus-mux.service systemd/oneplus-firewall.service
  systemd/oneplus-user-maintenance.service systemd/oneplus-user-maintenance.timer systemd/oneplus-history.service systemd/oneplus-history.timer
  scripts/test-websocket.py
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
    printf '%s\n' "$ROOT_DIR/bin/oneplus" "$ROOT_DIR/libexec/run-badvpn" "$ROOT_DIR/libexec/run-slowdns" "$ROOT_DIR/libexec/run-user-maintenance" \
      "$ROOT_DIR/libexec/run-dropbear" "$ROOT_DIR/libexec/run-websocket" "$ROOT_DIR/libexec/run-tls" "$ROOT_DIR/libexec/run-openvpn" "$ROOT_DIR/libexec/run-openvpn-pki-maintenance" "$ROOT_DIR/libexec/run-mux" "$ROOT_DIR/libexec/run-firewall" "$ROOT_DIR/libexec/run-history"
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
  modules/system.sh modules/ssh.sh modules/dropbear.sh modules/websocket.sh modules/tls.sh modules/openvpn.sh modules/mux.sh modules/badvpn.sh modules/slowdns.sh modules/users.sh modules/firewall.sh modules/backup.sh modules/reports.sh modules/diagnostics.sh modules/update.sh modules/history.sh modules/hardening.sh \
  libexec/run-badvpn libexec/run-slowdns libexec/run-user-maintenance libexec/run-dropbear libexec/run-websocket libexec/run-tls libexec/run-openvpn libexec/run-openvpn-pki-maintenance libexec/run-mux libexec/run-firewall libexec/run-history libexec/websocket_proxy.py libexec/openvpn_manager.py libexec/openvpn_bind_identity.py libexec/release_verify.py libexec/github_release.py libexec/history_snapshot.py libexec/history_summary.py \
  scripts/validate.sh scripts/test-users.sh scripts/test-openvpn.sh scripts/test-mux.sh scripts/test-operations.sh scripts/test-release.py scripts/test-update-metadata.py scripts/test-history.py scripts/test-hardening.sh scripts/fix-permissions.sh scripts/git-fix-modes.sh scripts/release-keygen.sh scripts/release-prepare.sh scripts/release-sign.sh scripts/test-websocket.py scripts/test-update-metadata.py)
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
  if grep -RInE --exclude-dir=.git --exclude='validate.sh' --exclude='*.md' "$re" "$ROOT_DIR" >/tmp/oneplus-validate-match.$$ 2>/dev/null; then
    cat /tmp/oneplus-validate-match.$$ >&2
    fail "Padrão destrutivo proibido encontrado."
  fi
  rm -f /tmp/oneplus-validate-match.$$
done

if find "$ROOT_DIR" -type d -name '__pycache__' -o -type f -name '*.py[co]' | grep -q .; then
  fail "Artefatos Python compilados (__pycache__/pyc) não devem entrar no repositório."
else
  ok "Nenhum artefato Python compilado encontrado."
fi

bad_name=0
while IFS= read -r -d '' f; do
  rel=${f#"$ROOT_DIR/"}
  [[ "$rel" =~ ^[A-Za-z0-9._/-]+$ ]] || { fail "Nome de arquivo/diretório não permitido na release: $rel"; bad_name=1; }
done < <(find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -print0)
(( bad_name == 0 )) && ok "Nomes de caminhos compatíveis com o manifesto de release."

if find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type l -print -quit | grep -q .; then
  fail "Links simbólicos não são permitidos no repositório OnePlus."
else
  ok "Nenhum link simbólico encontrado na árvore do projeto."
fi

if find "$ROOT_DIR" -path "$ROOT_DIR/.git" -prune -o -type f -perm /6000 -print -quit | grep -q .; then
  fail "Arquivo com setuid/setgid não é permitido no repositório."
else
  ok "Nenhum bit setuid/setgid encontrado."
fi

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



if command -v python3 >/dev/null 2>&1; then
  if ! PYTHONPYCACHEPREFIX="${TMPDIR:-/tmp}/oneplus-pycache.$$" python3 -m py_compile "$ROOT_DIR/libexec/websocket_proxy.py" "$ROOT_DIR/libexec/openvpn_manager.py" "$ROOT_DIR/libexec/openvpn_bind_identity.py" "$ROOT_DIR/libexec/release_verify.py" "$ROOT_DIR/libexec/github_release.py" "$ROOT_DIR/libexec/history_snapshot.py" "$ROOT_DIR/libexec/history_summary.py" "$ROOT_DIR/scripts/test-websocket.py" "$ROOT_DIR/scripts/test-release.py" "$ROOT_DIR/scripts/test-update-metadata.py" "$ROOT_DIR/scripts/test-history.py"; then
    fail "Erro de sintaxe Python em componente OnePlus."
  else
    ok "Sintaxe Python dos componentes validada."
  fi
  rm -rf -- "${TMPDIR:-/tmp}/oneplus-pycache.$$" 2>/dev/null || true
else
  printf '[AVISO] Python 3 ainda não está instalado; o instalador repetirá esta validação após instalar as dependências.\n'
fi

# Proteções obrigatórias da conectividade.
if ! grep -Fq 'args=(/usr/sbin/dropbear -F -E -w ' "$ROOT_DIR/libexec/run-dropbear"; then
  fail "Dropbear OnePlus deve iniciar com -w (root bloqueado)."
else
  ok "Dropbear mantém login de root bloqueado."
fi
if grep -Eiq 'x-real-host.*(connect|upstream)|findheader.*x-real-host' "$ROOT_DIR/libexec/websocket_proxy.py"; then
  fail "WebSocket não pode escolher upstream a partir de X-Real-Host."
else
  ok "WebSocket usa upstream fixo definido pelo administrador."
fi
if ! grep -Eq '^TLS_MIN_VERSION=TLSv1\.(2|3)$' "$ROOT_DIR/defaults/tls.env"; then
  fail "TLS_MIN_VERSION padrão inválido."
fi
if ! grep -Fq '[[ "$minver" == TLSv1.2 || "$minver" == TLSv1.3 ]]' "$ROOT_DIR/libexec/run-tls"; then
  fail "Wrapper TLS não restringe a versão mínima a TLS 1.2/1.3."
else
  ok "TLS mínimo restrito a TLS 1.2 ou 1.3."
fi
if ! grep -Fq '10#$max_clients <= 4096' "$ROOT_DIR/libexec/run-websocket" || \
   ! grep -Fq '10#$header_limit <= 65536' "$ROOT_DIR/libexec/run-websocket" || \
   ! grep -Fq '10#$max_frame <= 67108864' "$ROOT_DIR/libexec/run-websocket"; then
  fail "Wrapper WebSocket não restringe adequadamente limites de recursos."
else
  ok "Limites de recursos do WebSocket validados."
fi

if ! grep -Fq 'User=oneplus-ws' "$ROOT_DIR/systemd/oneplus-websocket.service" ||    ! grep -Fq 'User=oneplus-tls' "$ROOT_DIR/systemd/oneplus-tls.service"; then
  fail "WebSocket/TLS devem executar com usuários de serviço dedicados."
else
  ok "WebSocket e TLS usam usuários de serviço dedicados."
fi


# OpenVPN: PAM obrigatório e mTLS híbrido opcional por dispositivo.
if ! grep -Fq 'verify-client-cert none' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'verify-client-cert require' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'remote-cert-tls client' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'crl-verify ${CRL_EFFECTIVE}' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'username-as-common-name' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'plugin ${plugin} oneplus-openvpn' "$ROOT_DIR/libexec/run-openvpn"; then
  fail "OpenVPN não contém os modos password + mTLS híbrido esperados."
else
  ok "OpenVPN mantém PAM e adiciona mTLS híbrido por dispositivo."
fi
if ! grep -Eq '^OPENVPN_AUTH_MODE=password$' "$ROOT_DIR/defaults/openvpn.env"; then
  fail "OPENVPN_AUTH_MODE padrão deve permanecer password para compatibilidade."
fi
if ! grep -Eq '^OPENVPN_TLS_CRYPT_MODE=legacy$' "$ROOT_DIR/defaults/openvpn.env"; then
  fail "OPENVPN_TLS_CRYPT_MODE padrão deve permanecer legacy para preservar perfis existentes."
fi
if ! grep -Fq "printf 'tls-crypt %s\n'" "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq "printf 'tls-crypt-v2 %s\n'" "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'OPENVPN_TLS_CRYPT_MODE deve ser legacy, dual ou v2.' "$ROOT_DIR/libexec/run-openvpn"; then
  fail "Runtime OpenVPN não contém os três estados seguros do canal de controle (legacy/dual/v2)."
else
  ok "OpenVPN suporta migração controlada tls-crypt -> tls-crypt-v2."
fi
if grep -Fq 'client-cert-not-required' "$ROOT_DIR/libexec/run-openvpn" || grep -Fq 'duplicate-cn' "$ROOT_DIR/libexec/run-openvpn"; then
  fail "OpenVPN contém opção removida/incompatível ou duplicate-cn."
fi
if grep -RIn --exclude='validate.sh' -E 'MASQUERADE|nft[[:space:]].*masquerade|iptables' "$ROOT_DIR/modules/openvpn.sh" "$ROOT_DIR/libexec/run-openvpn" >/dev/null 2>&1; then
  fail "OpenVPN não pode manipular NAT/firewall diretamente; isso pertence ao módulo firewall."
else
  ok "OpenVPN não manipula firewall diretamente."
fi
if ! grep -Fq 'if [[ "$full_tunnel" == yes ]]' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'redirect-gateway def1 bypass-dhcp' "$ROOT_DIR/libexec/run-openvpn"; then
  fail "Full-tunnel OpenVPN deve ser opcional e condicionado por OPENVPN_FULL_TUNNEL."
else
  ok "Full-tunnel OpenVPN é opcional e controlado pelo administrador."
fi
if ! grep -Fq 'user ingroup oneplus-users' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'user != root' "$ROOT_DIR/modules/openvpn.sh"; then
  fail "PAM OpenVPN deve negar root e restringir autenticação ao grupo oneplus-users."
else
  ok "PAM OpenVPN nega root e restringe acesso às contas gerenciadas pelo OnePlus."
fi
if ! grep -Fq 'auth-user-pass-verify /opt/oneplus/libexec/openvpn_bind_identity.py via-file' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'tls_serial_hex_0' "$ROOT_DIR/libexec/openvpn_bind_identity.py" || \
   ! grep -Fq 'rebuild_openvpn_authz' "$ROOT_DIR/modules/openvpn.sh"; then
  fail "mTLS OpenVPN precisa vincular o serial do certificado ao usuário autenticado."
else
  ok "mTLS vincula certificado/dispositivo à conta OnePlus sem ler a senha no helper."
fi
if grep -Fq 'via-env' "$ROOT_DIR/libexec/run-openvpn"; then
  fail "Binding mTLS não deve expor senha em variável de ambiente; use via-file."
fi
if ! grep -Fq 'management ${RUNTIME_DIR}/management.sock unix' "$ROOT_DIR/libexec/run-openvpn" || \
   ! grep -Fq 'management-client-user root' "$ROOT_DIR/libexec/run-openvpn"; then
  fail "Interface de gerenciamento OpenVPN deve ser UNIX socket restrito a root."
else
  ok "Gerenciamento OpenVPN limitado a UNIX socket local/root."
fi
if grep -Fq 'cat "$OPENVPN_CA_KEY"' "$ROOT_DIR/modules/openvpn.sh"; then
  fail "A chave privada da CA OpenVPN não pode ser exportada para perfis cliente."
else
  ok "Exportação OpenVPN não inclui a chave privada da CA."
fi
if ! grep -Fq 'extendedKeyUsage = clientAuth' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'REVOKE_AFTER=' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'OnUnitActiveSec=5min' "$ROOT_DIR/systemd/oneplus-openvpn-pki-maintenance.timer"; then
  fail "PKI de dispositivo/CRL/rotação assistida OpenVPN incompleta."
else
  ok "mTLS por dispositivo, CRL e janela de rotação estão presentes."
fi
if ! grep -Fq 'FINALIZAR-FORCAR' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'OPENVPN_ROTATION_CA_BUNDLE' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'OPENVPN_ROTATION_CRL_BUNDLE' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'tls-crypt-v2-client' "$ROOT_DIR/modules/openvpn.sh" || \
   ! grep -Fq 'pre-finalize.tar.gz' "$ROOT_DIR/modules/openvpn.sh"; then
  fail "Rotação coordenada de CA/servidor/tls-crypt-v2 incompleta."
else
  ok "Rotação coordenada OpenVPN contém fase dual, perfis v2, confirmação e rollback."
fi
if grep -Fq 'finalize_infrastructure_rotation' "$ROOT_DIR/libexec/run-openvpn-pki-maintenance"; then
  fail "Timer de PKI não pode promover uma nova CA automaticamente."
else
  ok "Promoção da CA permanece exclusivamente manual."
fi
if grep -Eq 'client\.key[^[:cntrl:]]*(install|cp)[^[:cntrl:]]*OPENVPN' "$ROOT_DIR/modules/openvpn.sh"; then
  fail "Chaves privadas de dispositivos não podem ser persistidas no servidor."
else
  ok "Chave privada mTLS fica somente no perfil exportado."
fi

# sslh: multiplexação somente TCP, backends loopback e sem modo transparente/firewall.
if grep -Fq -- '--transparent' "$ROOT_DIR/libexec/run-mux"; then
  fail "Multiplexador OnePlus não pode usar modo transparente."
fi
if ! grep -Fq 'valid_loopback_target' "$ROOT_DIR/libexec/run-mux" ||    ! grep -Fq '[[ "$host" == 127.0.0.1 || "$host" == localhost ]]' "$ROOT_DIR/libexec/run-mux"; then
  fail "Multiplexador deve restringir todos os backends ao loopback."
else
  ok "Multiplexador sslh usa somente backends loopback."
fi
if ! grep -Fq 'User=oneplus-mux' "$ROOT_DIR/systemd/oneplus-mux.service" ||    ! grep -Fq 'CapabilityBoundingSet=CAP_NET_BIND_SERVICE' "$ROOT_DIR/systemd/oneplus-mux.service"; then
  fail "Multiplexador deve executar com usuário dedicado e somente capability de bind privilegiado."
else
  ok "Multiplexador usa usuário dedicado e capability mínima."
fi

# Integridade dos protocolos compilados.
if ! grep -Eq '^BADVPN_COMMIT="[0-9a-f]{40}"$' "$ROOT_DIR/modules/badvpn.sh" || \
   ! grep -Fq 'sha256sum -c "$BADVPN_HASH_FILE"' "$ROOT_DIR/modules/badvpn.sh"; then
  fail "BadVPN deve usar commit fixado e validação SHA-256 do binário instalado."
else
  ok "BadVPN usa fonte fixada e controle de integridade local."
fi
if ! grep -Fq 'DNSTT_VERSION="v1.20260501.0"' "$ROOT_DIR/modules/slowdns.sh" || \
   ! grep -Fq 'GOSUMDB=sum.golang.org' "$ROOT_DIR/modules/slowdns.sh" || \
   ! grep -Fq 'sha256sum -c "$DNSTT_HASH_FILE"' "$ROOT_DIR/modules/slowdns.sh"; then
  fail "SlowDNS/dnstt não está com versão/verificação de integridade esperadas."
else
  ok "SlowDNS/dnstt mantém versão fixada e controle de integridade local."
fi
if ! grep -Fq 'udp_bind_port_in_use "$bind" "$port"' "$ROOT_DIR/modules/slowdns.sh"; then
  fail "SlowDNS deve abortar em conflito de bind/porta UDP."
else
  ok "SlowDNS valida conflito UDP sem alterar resolvedores do sistema."
fi
if ! grep -Fq '[[ "$SLOWDNS_PRIVKEY" == "$EXPECTED_KEY" ]]' "$ROOT_DIR/libexec/run-slowdns"; then
  fail "Wrapper SlowDNS deve restringir a chave privada ao caminho protegido OnePlus."
else
  ok "Caminho da chave privada SlowDNS está restrito."
fi


# Fase 4: firewall isolado, backup criptografado e atualização assinada.
if ! grep -Fq 'table inet oneplus_filter' "$ROOT_DIR/libexec/run-firewall" ||    ! grep -Fq 'table ip oneplus_nat' "$ROOT_DIR/libexec/run-firewall"; then
  fail "Firewall deve usar tabelas nftables exclusivas do OnePlus."
else
  ok "Firewall usa tabelas nftables próprias."
fi
if grep -Eq 'flush[[:space:]]+ruleset|delete[[:space:]]+table[[:space:]]+(inet|ip)[[:space:]]+(filter|nat)([[:space:]]|$)' "$ROOT_DIR/libexec/run-firewall"; then
  fail "Firewall OnePlus não pode limpar/substituir tabelas globais."
else
  ok "Firewall não limpa ruleset/tabelas globais."
fi
if ! grep -Fq 'masquerade comment "oneplus openvpn nat"' "$ROOT_DIR/libexec/run-firewall"; then
  fail "NAT OpenVPN isolado não encontrado."
fi
if ! grep -Fq 'age -p -o "$outfile"' "$ROOT_DIR/modules/backup.sh" ||    grep -Fq 'backup_copy_if_exists /etc/shadow' "$ROOT_DIR/modules/backup.sh"; then
  fail "Backup deve ser criptografado com age e não copiar /etc/shadow integralmente."
else
  ok "Backup é criptografado e captura apenas contas OnePlus."
fi
if ! grep -Fq 'minisign -Vm' "$ROOT_DIR/modules/update.sh" ||    ! grep -Fq 'sha256sum -c release/SHA256SUMS' "$ROOT_DIR/modules/update.sh"; then
  fail "Atualizador deve verificar assinatura minisign e manifesto SHA-256."
else
  ok "Atualizador estável verifica minisign + SHA-256."
fi
if find "$ROOT_DIR" -type f \( -name 'minisign.key' -o -name '*.sec' -o -name '*secret*key*' \) | grep -q .; then
  fail "Chave secreta de release não pode entrar no repositório."
else
  ok "Nenhuma chave secreta de release encontrada."
fi
if ! grep -Fq 'CapabilityBoundingSet=CAP_NET_ADMIN' "$ROOT_DIR/systemd/oneplus-firewall.service"; then
  fail "Serviço nftables deve limitar capabilities a CAP_NET_ADMIN."
fi

# Proteções obrigatórias do módulo de usuários.
if ! grep -Fq '(( uid > 0 )) || return 1' "$ROOT_DIR/modules/users.sh"; then
  fail "Proteção contra UID 0 ausente no módulo de usuários."
fi
if ! grep -Fq 'ONEPLUS_USERS_GROUP="oneplus-users"' "$ROOT_DIR/modules/users.sh"; then
  fail "Grupo isolado de usuários OnePlus não encontrado."
fi
if grep -nE 'source[[:space:]]+.*(/var/lib/oneplus/users|user_meta|\.conf)' "$ROOT_DIR/modules/users.sh" >/dev/null 2>&1; then
  fail "Metadados de usuários não podem ser executados com source."
else
  ok "Metadados de usuários são lidos sem execução de código."
fi

if ! grep -Eq '^DEFAULT_CONNECTION_LIMIT=[0-9]+$' "$ROOT_DIR/defaults/users.conf"; then
  fail "DEFAULT_CONNECTION_LIMIT inválido."
fi
if ! grep -Eq '^DEFAULT_TEST_EXPIRE_ACTION=(lock|delete|delete-home)$' "$ROOT_DIR/defaults/users.conf"; then
  fail "DEFAULT_TEST_EXPIRE_ACTION inválido."
fi

# Cadeia de release v0.5.1+: pacote assinado, extração segura e chave privada fora do repositório.
if ! grep -Fq 'ONEPLUS_UPDATE_RELEASE_BASE="https://github.com/twossh/oneplus/releases/download"' "$ROOT_DIR/modules/update.sh"; then
  fail "Atualizador não está fixado no canal GitHub Releases."
fi
if ! grep -Eq 'release_verify\.py[^[:cntrl:]]*extract' "$ROOT_DIR/modules/update.sh"; then
  fail "Atualizador não usa extração segura de release."
fi
if ! grep -Fq 'tipo de entrada proibido' "$ROOT_DIR/libexec/release_verify.py"; then
  fail "Validador de release não bloqueia tipos especiais."
fi
if ! grep -Fq 'A chave privada NÃO deve ser copiada' "$ROOT_DIR/scripts/release-keygen.sh"; then
  fail "Gerador de chave não documenta isolamento da chave privada."
fi
if ! grep -Fq 'A chave privada está dentro do repositório' "$ROOT_DIR/scripts/release-prepare.sh"; then
  fail "Preparador de release não bloqueia chave privada dentro do repositório."
fi

# Cadeia de atualização v0.5.2+: metadados REST validados antes de usar URLs de assets.
if ! grep -Fq 'ONEPLUS_UPDATE_API="https://api.github.com/repos/twossh/oneplus/releases"' "$ROOT_DIR/modules/update.sh"; then
  fail "Atualizador não está fixado no endpoint oficial de Releases da API GitHub."
fi
if ! grep -Fq 'release_helper asset-url' "$ROOT_DIR/modules/update.sh" || ! grep -Fq 'browser_download_url' "$ROOT_DIR/libexec/github_release.py"; then
  fail "Atualizador não valida metadados/URLs dos assets antes do download."
else
  ok "URLs de assets são obtidas de metadados GitHub validados."
fi
if ! grep -Fq 'data.get("draft") is not False' "$ROOT_DIR/libexec/github_release.py" || ! grep -Fq 'data.get("prerelease") is not False' "$ROOT_DIR/libexec/github_release.py"; then
  fail "Canal estável deve recusar draft e prerelease."
else
  ok "Canal estável recusa draft/prerelease."
fi
if ! grep -Fq 'oneplus update --check' "$ROOT_DIR/bin/oneplus" || ! grep -Fq 'signed_update_latest' "$ROOT_DIR/modules/update.sh"; then
  fail "CLI de verificação/atualização da release mais recente ausente."
fi


# Fase 5: histórico leve opt-in e hardening audit-only.
if ! grep -Eq '^HISTORY_INTERVAL_MINUTES=(1|5|15|30|60)$' "$ROOT_DIR/defaults/history.env" || \
   ! grep -Eq '^HISTORY_RETENTION_DAYS=([1-9]|[1-8][0-9]|90)$' "$ROOT_DIR/defaults/history.env"; then
  fail "Configuração padrão do histórico leve inválida."
else
  ok "Configuração do histórico leve validada."
fi
if ! grep -Fq 'OnUnitActiveSec=5min' "$ROOT_DIR/systemd/oneplus-history.timer" || \
   grep -Fq 'Persistent=true' "$ROOT_DIR/systemd/oneplus-history.timer"; then
  fail "Timer do histórico deve ser leve, monotônico e sem catch-up de snapshots perdidos."
else
  ok "Timer de histórico é opt-in e não tenta reconstruir snapshots perdidos."
fi
if ! grep -Fq 'O_NOFOLLOW' "$ROOT_DIR/libexec/history_snapshot.py" || \
   ! grep -Fq 'st.st_nlink != 1' "$ROOT_DIR/libexec/history_snapshot.py" || \
   ! grep -Fq '"schema": 1' "$ROOT_DIR/libexec/history_snapshot.py"; then
  fail "Coletor de histórico não contém proteções de arquivo/schema esperadas."
else
  ok "Histórico usa NDJSON root-only com proteção contra symlink/hardlink."
fi
if grep -Eq '"remote_ip"|"password"|"payload"|authorized_keys' "$ROOT_DIR/libexec/history_snapshot.py"; then
  fail "Histórico leve não deve persistir IP remoto, senha, payload ou material de autenticação."
else
  ok "Histórico evita dados sensíveis/identificáveis desnecessários."
fi
if ! grep -Fq 'Modo: AUDIT-ONLY' "$ROOT_DIR/modules/hardening.sh" || \
   ! grep -Fq 'Nenhuma alteração foi aplicada.' "$ROOT_DIR/modules/hardening.sh"; then
  fail "Módulo hardening deve declarar e preservar modo audit-only."
fi
if grep -Eq '^[[:space:]]*(sudo[[:space:]]+)?(apt|apt-get)[[:space:]].*(install|upgrade|dist-upgrade)|^[[:space:]]*systemctl[[:space:]]+(start|stop|restart|enable|disable|mask|unmask)|^[[:space:]]*nft[[:space:]]+(add|delete|flush)|^[[:space:]]*sysctl[[:space:]]+-w' "$ROOT_DIR/modules/hardening.sh"; then
  fail "Hardening audit-only contém primitiva mutável proibida."
else
  ok "Hardening não aplica alterações ao host."
fi
if ! grep -Fq 'oneplus history' "$ROOT_DIR/bin/oneplus" || ! grep -Fq 'oneplus hardening' "$ROOT_DIR/bin/oneplus"; then
  fail "CLI de histórico/hardening ausente."
fi

if [[ "$FAILED" -ne 0 ]]; then
  printf '\nValidação falhou.\n' >&2
  exit 1
fi
printf '\nVALIDATION: OK (OnePlus %s)\n' "$VERSION"
