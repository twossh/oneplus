#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cat >&2 <<'EOF'
[AVISO] release-sign.sh foi substituído pelo fluxo completo release-prepare.sh na v0.5.1.
Agora são exigidas a chave privada E a chave pública para verificar localmente o resultado antes da publicação.
EOF
exec "$ROOT_DIR/scripts/release-prepare.sh" "$@"
