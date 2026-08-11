#!/usr/bin/env bash

oneplus_package_installed() {
  local pkg="$1"
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Fxq 'install ok installed'
}

oneplus_sync_tree() {
  local source="$1" dest="$2"
  [[ "$source" == /* && -d "$source" ]] || { error "Origem de sincronização inválida: $source"; return 1; }
  [[ "$dest" == /* && -d "$dest" ]] || { error "Destino de sincronização inválido: $dest"; return 1; }
  if [[ "$(readlink -f "$source")" == "$(readlink -f "$dest")" ]]; then
    info "Instalador executado a partir da própria árvore instalada; sincronização de código não é necessária."
    return 0
  fi

  # --checksum é intencional: releases consecutivas podem ter arquivos com o
  # mesmo tamanho e mtime (especialmente worktrees criados no mesmo segundo).
  # O quick-check padrão do rsync poderia manter conteúdo antigo nessa situação.
  # --delay-updates mantém arquivos novos em temporários até o fim da cópia;
  # --delete-delay posterga exclusões; --delete-excluded também remove lixo de
  # build/release que não pertence à árvore runtime em /opt/oneplus.
  rsync -a --checksum --delay-updates --delete-delay --delete-excluded \
    --exclude '.git' \
    --exclude '.github' \
    --exclude 'dist' \
    --exclude '*.zip' \
    --exclude '*.sha256' \
    "$source/" "$dest/"
}

oneplus_verify_synced_core() {
  local source="$1" dest="$2" rel
  local -a critical=(
    VERSION
    install.sh
    bin/oneplus
    lib/common.sh
    scripts/validate.sh
  )
  for rel in "${critical[@]}"; do
    [[ -f "$source/$rel" && -f "$dest/$rel" ]] || {
      error "Arquivo crítico ausente após sincronização: $rel"
      return 1
    }
    cmp -s -- "$source/$rel" "$dest/$rel" || {
      error "Arquivo crítico divergiu após sincronização: $rel"
      return 1
    }
  done
}
