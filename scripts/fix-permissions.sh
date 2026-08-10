#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

chmod 0755 \
  "$ROOT_DIR/setup.sh" \
  "$ROOT_DIR/install.sh" \
  "$ROOT_DIR/uninstall.sh" \
  "$ROOT_DIR/bin/oneplus"

find "$ROOT_DIR/lib" "$ROOT_DIR/modules" -maxdepth 1 -type f -name '*.sh' -exec chmod 0755 {} +
find "$ROOT_DIR/libexec" -maxdepth 1 -type f -exec chmod 0755 {} +
find "$ROOT_DIR/scripts" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod 0755 {} +

# Arquivos declarativos nunca precisam ser executáveis.
find "$ROOT_DIR/defaults" "$ROOT_DIR/systemd" -maxdepth 1 -type f -exec chmod 0644 {} +
chmod 0644 "$ROOT_DIR/VERSION" "$ROOT_DIR/README.md" "$ROOT_DIR/CHANGELOG.md" "$ROOT_DIR/.gitattributes" "$ROOT_DIR/.gitignore" 2>/dev/null || true
find "$ROOT_DIR/docs" "$ROOT_DIR/release" -type f -exec chmod 0644 {} + 2>/dev/null || true
