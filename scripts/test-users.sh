#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/modules/users.sh"

fail_test() { printf '[TESTE FALHOU] %s\n' "$*" >&2; exit 1; }

is_valid_username 'cliente1' || fail_test 'cliente1 deveria ser válido'
is_valid_username 'a' || fail_test 'nome de 1 caractere deveria ser válido'
! is_valid_username 'root' || fail_test 'root nunca pode ser gerenciado'
! is_valid_username 'oneplus-admin' || fail_test 'prefixo oneplus- deve ser reservado'
! is_valid_username 'Cliente' || fail_test 'maiúsculas devem ser rejeitadas'
! is_valid_username '../root' || fail_test 'path traversal deve ser rejeitado'

TMP=$(mktemp -d /tmp/oneplus-user-test.XXXXXX)
trap 'rm -rf -- "$TMP"' EXIT
ONEPLUS_USERS_DIR="$TMP/users"
ONEPLUS_USERS_CONF="$TMP/users.conf"
ONEPLUS_LIMITS_FILE="$TMP/limits.conf"
cat > "$ONEPLUS_USERS_CONF" <<'EOF2'
DEFAULT_CONNECTION_LIMIT=1
DEFAULT_VALIDITY_DAYS=30
DEFAULT_TEST_HOURS=1
DEFAULT_EXPIRE_ACTION=lock
DEFAULT_TEST_EXPIRE_ACTION=delete-home
EOF2

write_user_meta 'cliente1' 12345 '/home/cliente1' regular 1000 2000 1 lock
FILE=$(user_meta_file 'cliente1')
[[ -f "$FILE" ]] || fail_test 'metadado não foi criado'
[[ "$(stat -c %a "$FILE")" == 600 ]] || fail_test 'metadado precisa ser 0600'
[[ "$(meta_get "$FILE" UID)" == 12345 ]] || fail_test 'meta_get UID'
meta_set "$FILE" CONNECTION_LIMIT 3
[[ "$(meta_get "$FILE" CONNECTION_LIMIT)" == 3 ]] || fail_test 'meta_set CONNECTION_LIMIT'

printf 'USER STATIC TESTS: OK\n'
