#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_UPDATE_REPO="https://github.com/twossh/oneplus.git"
ONEPLUS_UPDATE_KEY="/etc/oneplus/update.pub"
ONEPLUS_UPDATE_ROLLBACK="/var/lib/oneplus/update-rollback"

update_key_format_ok() {
  local f="$1" key
  [[ -r "$f" ]] || return 1
  key=$(grep -Ev '^[[:space:]]*(#|$|untrusted comment:)' "$f" | head -1 | tr -d '[:space:]')
  [[ "$key" =~ ^RW[A-Za-z0-9+/=]{40,}$ ]]
}

install_update_public_key() {
  local src confirm
  printf "Caminho absoluto da chave pública minisign: "; read -r src
  [[ "$src" == /* && -f "$src" ]] || { error "Arquivo não encontrado."; return 1; }
  update_key_format_ok "$src" || { error "Formato de chave minisign não reconhecido."; return 1; }
  printf "Fingerprint/linha pública:\n"
  grep -Ev '^[[:space:]]*$' "$src" | sed -n '1,2p'
  warn "Confirme esta chave por um canal independente. Quem controla esta chave controla as atualizações estáveis do OnePlus."
  printf "Digite CONFIAR para instalar: "; read -r confirm
  [[ "$confirm" == CONFIAR ]] || { info "Cancelado."; return 0; }
  install -m 0644 -o root -g root "$src" "$ONEPLUS_UPDATE_KEY"
  ok "Chave pública de atualização instalada em $ONEPLUS_UPDATE_KEY"
}

create_update_rollback() {
  local dir tarfile stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  dir="$ONEPLUS_UPDATE_ROLLBACK/$stamp"
  install -d -m 0700 -o root -g root "$dir"
  tarfile="$dir/system.tar.gz"
  local -a paths=()
  [[ -d /opt/oneplus ]] && paths+=(opt/oneplus)
  [[ -d /etc/oneplus ]] && paths+=(etc/oneplus)
  [[ -e /usr/local/bin/oneplus ]] && paths+=(usr/local/bin/oneplus)
  [[ -e /etc/pam.d/oneplus-openvpn ]] && paths+=(etc/pam.d/oneplus-openvpn)
  [[ -e /etc/security/limits.d/90-oneplus.conf ]] && paths+=(etc/security/limits.d/90-oneplus.conf)
  [[ -e /etc/ssh/sshd_config.d/60-oneplus.conf ]] && paths+=(etc/ssh/sshd_config.d/60-oneplus.conf)
  while IFS= read -r f; do paths+=("${f#/}"); done < <(find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -print 2>/dev/null)
  find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -printf '%f\n' 2>/dev/null | sort > "$dir/units.list"
  chmod 0600 "$dir/units.list"
  tar -C / -czf "$tarfile" "${paths[@]}"
  chmod 0600 "$tarfile"
  printf '%s' "$tarfile"
}

restore_update_rollback() {
  local tarfile="$1" dir current base
  [[ -f "$tarfile" ]] || return 1
  dir=$(dirname "$tarfile")
  if [[ -r "$dir/units.list" ]]; then
    while IFS= read -r current; do
      base=$(basename "$current")
      grep -Fxq "$base" "$dir/units.list" || rm -f -- "$current"
    done < <(find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -print 2>/dev/null)
  fi
  tar -C / -xzf "$tarfile"
  systemctl daemon-reload || true
  ln -sfn /opt/oneplus/bin/oneplus /usr/local/bin/oneplus
}

verify_release_tree() {
  local dir="$1" tag="$2" expected="${tag#v}"
  [[ -r "$ONEPLUS_UPDATE_KEY" ]] || { error "Chave pública de atualização não configurada."; return 1; }
  update_key_format_ok "$ONEPLUS_UPDATE_KEY" || { error "Chave pública instalada é inválida."; return 1; }
  [[ -r "$dir/release/SHA256SUMS" && -r "$dir/release/SHA256SUMS.minisig" ]] || { error "Tag sem manifesto minisign; atualização recusada."; return 1; }
  minisign -Vm "$dir/release/SHA256SUMS" -x "$dir/release/SHA256SUMS.minisig" -p "$ONEPLUS_UPDATE_KEY" || { error "Assinatura da release inválida."; return 1; }
  for critical in VERSION install.sh bin/oneplus scripts/validate.sh; do
    grep -Eq "[[:space:]]+\\./${critical//\//\\/}$" "$dir/release/SHA256SUMS" || { error "Manifesto não cobre arquivo crítico: $critical"; return 1; }
  done
  (cd "$dir" && sha256sum -c release/SHA256SUMS) || { error "Checksum da árvore assinada falhou."; return 1; }
  [[ "$(tr -d '[:space:]' < "$dir/VERSION")" == "$expected" ]] || { error "VERSION não corresponde à tag $tag."; return 1; }
  bash "$dir/scripts/validate.sh" || { error "Validação estática da release falhou."; return 1; }
}

signed_update_tag() {
  require_root
  command_exists minisign || { error "minisign não instalado."; return 1; }
  command_exists git || { error "git não instalado."; return 1; }
  [[ -r "$ONEPLUS_UPDATE_KEY" ]] || { error "Configure primeiro a chave pública de atualização."; return 1; }
  local tag current target tmp src rollback confirm
  current=$(cat /opt/oneplus/VERSION 2>/dev/null || echo 0.0.0)
  printf "Tag assinada a instalar (ex.: v0.5.1): "; read -r tag
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { error "Tag inválida."; return 1; }
  target=${tag#v}
  if ! dpkg --compare-versions "$target" gt "$current"; then
    warn "Versão alvo ($target) não é superior à instalada ($current). Downgrade/reinstalação não é feito pelo atualizador estável."
    return 1
  fi
  tmp=$(mktemp -d /tmp/oneplus-update.XXXXXX)
  src="$tmp/oneplus"
  trap 'rm -rf -- "${tmp:-}" 2>/dev/null || true' RETURN
  info "Baixando tag $tag..."
  git -c advice.detachedHead=false clone --depth 1 --branch "$tag" "$ONEPLUS_UPDATE_REPO" "$src"
  info "Verificando assinatura minisign e todos os checksums..."
  verify_release_tree "$src" "$tag" || return 1
  printf "Release assinada e validada: %s -> %s\n" "$current" "$target"
  printf "Digite ATUALIZAR para instalar: "; read -r confirm
  [[ "$confirm" == ATUALIZAR ]] || { info "Cancelado."; return 0; }
  rollback=$(create_update_rollback)
  info "Rollback local: $rollback"
  if bash "$src/install.sh"; then
    if [[ "$(cat /opt/oneplus/VERSION 2>/dev/null)" == "$target" ]] && /usr/local/bin/oneplus --check; then
      rm -rf -- "$tmp"; trap - RETURN
      ok "OnePlus atualizado com sucesso para $target."
      return 0
    fi
  fi
  error "Atualização falhou. Restaurando arquivos anteriores."
  restore_update_rollback "$rollback" || error "Rollback automático falhou; arquivo preservado: $rollback"
  rm -rf -- "$tmp"; trap - RETURN
  return 1
}

show_update_status() {
  printf "Versão instalada: %s\n" "$(cat /opt/oneplus/VERSION 2>/dev/null || echo N/D)"
  printf "Repositório: %s\n" "$ONEPLUS_UPDATE_REPO"
  if [[ -r "$ONEPLUS_UPDATE_KEY" ]]; then
    printf "Chave confiável: %s\n" "$ONEPLUS_UPDATE_KEY"
    sed -n '1,2p' "$ONEPLUS_UPDATE_KEY"
  else
    printf "Chave confiável: NÃO CONFIGURADA\n"
  fi
  printf "\nPolítica: atualizações estáveis recusam tags sem manifesto SHA-256 assinado por minisign.\n"
}

module_update() {
  while true; do
    clear
    printf "%bOnePlus • Atualização assinada%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "1) Status/política\n"
    printf "2) Instalar/alterar chave pública confiável\n"
    printf "3) Atualizar por tag assinada\n"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) clear; show_update_status; pause ;;
      2) install_update_public_key; pause ;;
      3) signed_update_tag; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
