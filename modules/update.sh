#!/usr/bin/env bash
set -Eeuo pipefail

ONEPLUS_UPDATE_REPO="https://github.com/twossh/oneplus"
ONEPLUS_UPDATE_RELEASE_BASE="https://github.com/twossh/oneplus/releases/download"
ONEPLUS_UPDATE_KEY="/etc/oneplus/update.pub"
ONEPLUS_UPDATE_ROLLBACK="/var/lib/oneplus/update-rollback"
ONEPLUS_UPDATE_KEEP_ROLLBACKS="${ONEPLUS_UPDATE_KEEP_ROLLBACKS:-3}"

update_key_format_ok() {
  local f="$1" key
  [[ -r "$f" ]] || return 1
  key=$(grep -Ev '^[[:space:]]*(#|$|untrusted comment:)' "$f" | head -1 | tr -d '[:space:]')
  [[ "$key" =~ ^RW[A-Za-z0-9+/=]{40,}$ ]]
}

install_update_public_key() {
  local src confirm
  printf "Caminho absoluto da chave pública minisign: "; read -r src
  [[ "$src" == /* && -f "$src" && ! -L "$src" ]] || { error "Arquivo regular não encontrado."; return 1; }
  update_key_format_ok "$src" || { error "Formato de chave minisign não reconhecido."; return 1; }
  printf "Chave pública:\n"
  grep -Ev '^[[:space:]]*$' "$src" | sed -n '1,2p'
  printf "SHA-256: %s\n" "$(sha256sum "$src" | awk '{print $1}')"
  warn "Confirme esta chave por um canal independente. Quem controla esta chave controla as atualizações estáveis do OnePlus."
  printf "Digite CONFIAR para instalar: "; read -r confirm
  [[ "$confirm" == CONFIAR ]] || { info "Cancelado."; return 0; }
  install -m 0644 -o root -g root "$src" "$ONEPLUS_UPDATE_KEY"
  ok "Chave pública de atualização instalada em $ONEPLUS_UPDATE_KEY"
}

record_unit_states() {
  local outfile="$1" unit enabled active
  : > "$outfile"
  while IFS= read -r unit; do
    enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    active=$(systemctl is-active "$unit" 2>/dev/null || true)
    printf '%s\t%s\t%s\n' "$unit" "${enabled:-unknown}" "${active:-unknown}" >> "$outfile"
  done < <(find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -printf '%f\n' 2>/dev/null | LC_ALL=C sort)
  chmod 0600 "$outfile"
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
  [[ -e /etc/sysctl.d/90-oneplus-forwarding.conf ]] && paths+=(etc/sysctl.d/90-oneplus-forwarding.conf)
  while IFS= read -r f; do paths+=("${f#/}"); done < <(find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -print 2>/dev/null)
  find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -printf '%f\n' 2>/dev/null | LC_ALL=C sort > "$dir/units.list"
  chmod 0600 "$dir/units.list"
  record_unit_states "$dir/units.state"
  if ((${#paths[@]})); then
    tar -C / -czf "$tarfile" "${paths[@]}"
  else
    tar -C / -czf "$tarfile" --files-from /dev/null
  fi
  chmod 0600 "$tarfile"
  printf '%s' "$tarfile"
}

restore_unit_states() {
  local statefile="$1" unit enabled active
  [[ -r "$statefile" ]] || return 0
  while IFS=$'\t' read -r unit enabled active; do
    [[ "$unit" =~ ^oneplus-[A-Za-z0-9_.@-]+\.(service|timer)$ ]] || continue
    case "$enabled" in
      enabled|enabled-runtime|linked|linked-runtime|alias) systemctl enable "$unit" >/dev/null 2>&1 || true ;;
      disabled) systemctl disable "$unit" >/dev/null 2>&1 || true ;;
    esac
    case "$active" in
      active|activating|reloading) systemctl start "$unit" >/dev/null 2>&1 || true ;;
      inactive|failed|deactivating) systemctl stop "$unit" >/dev/null 2>&1 || true ;;
    esac
  done < "$statefile"
}

restore_update_rollback() {
  local tarfile="$1" dir current base
  [[ -f "$tarfile" ]] || return 1
  dir=$(dirname "$tarfile")
  if [[ -r "$dir/units.list" ]]; then
    while IFS= read -r current; do
      base=$(basename "$current")
      grep -Fxq "$base" "$dir/units.list" || {
        systemctl disable --now "$base" >/dev/null 2>&1 || true
        rm -f -- "$current"
      }
    done < <(find /etc/systemd/system -maxdepth 1 -type f \( -name 'oneplus-*.service' -o -name 'oneplus-*.timer' \) -print 2>/dev/null)
  fi
  tar -C / -xzf "$tarfile"
  systemctl daemon-reload || true
  ln -sfn /opt/oneplus/bin/oneplus /usr/local/bin/oneplus
  restore_unit_states "$dir/units.state"
}

cleanup_update_rollbacks() {
  local keep="${1:-$ONEPLUS_UPDATE_KEEP_ROLLBACKS}" idx=0 item
  [[ "$keep" =~ ^[0-9]+$ ]] || keep=3
  (( keep >= 1 )) || keep=1
  [[ -d "$ONEPLUS_UPDATE_ROLLBACK" ]] || return 0
  while IFS= read -r item; do
    ((idx+=1))
    if (( idx > keep )); then
      rm -rf -- "$item"
    fi
  done < <(find "$ONEPLUS_UPDATE_ROLLBACK" -mindepth 1 -maxdepth 1 -type d -name '20????????T??????Z' -print 2>/dev/null | LC_ALL=C sort -r)
}

manifest_paths_safe() {
  local manifest="$1" hash path count=0
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  while read -r hash path _extra; do
    [[ -z "${_extra:-}" ]] || return 1
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ "$path" == ./* && "$path" != *'/../'* && "$path" != '../'* && "$path" != *'/./'* ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    ((count+=1))
  done < "$manifest"
  (( count > 0 ))
}

verify_release_tree() {
  local dir="$1" tag="$2" expected="${tag#v}" critical
  [[ -r "$ONEPLUS_UPDATE_KEY" ]] || { error "Chave pública de atualização não configurada."; return 1; }
  update_key_format_ok "$ONEPLUS_UPDATE_KEY" || { error "Chave pública instalada é inválida."; return 1; }
  [[ -r "$dir/release/SHA256SUMS" && -r "$dir/release/SHA256SUMS.minisig" ]] || { error "Release sem manifesto Minisign; atualização recusada."; return 1; }
  if find "$dir" -type l -print -quit | grep -q .; then
    error "Release contém link simbólico; atualização recusada."
    return 1
  fi
  manifest_paths_safe "$dir/release/SHA256SUMS" || { error "Manifesto contém caminho/formato inseguro."; return 1; }
  minisign -Vm "$dir/release/SHA256SUMS" -x "$dir/release/SHA256SUMS.minisig" -p "$ONEPLUS_UPDATE_KEY" || { error "Assinatura interna da release inválida."; return 1; }
  for critical in VERSION install.sh bin/oneplus scripts/validate.sh libexec/release_verify.py; do
    grep -Eq "^[0-9a-f]{64}[[:space:]]+\\./${critical//\//\\/}$" "$dir/release/SHA256SUMS" || { error "Manifesto não cobre arquivo crítico: $critical"; return 1; }
  done
  (cd "$dir" && sha256sum -c release/SHA256SUMS) || { error "Checksum da árvore assinada falhou."; return 1; }
  [[ "$(tr -d '[:space:]' < "$dir/VERSION")" == "$expected" ]] || { error "VERSION não corresponde à tag $tag."; return 1; }
  bash "$dir/scripts/validate.sh" || { error "Validação estática da release falhou."; return 1; }
}

download_release_file() {
  local url="$1" out="$2" max_bytes="${3:-67108864}"
  [[ "$max_bytes" =~ ^[0-9]+$ ]] || return 2
  curl --proto '=https' --tlsv1.2 -fL --retry 3 --retry-delay 2 \
    --connect-timeout 10 --max-time 180 --max-filesize "$max_bytes" -o "$out" "$url"
  [[ -s "$out" ]] || { error "Download vazio: $url"; return 1; }
  (( $(stat -c '%s' "$out") <= max_bytes )) || { error "Asset excede o limite de tamanho."; return 1; }
}

verify_external_release_assets() {
  local archive="$1" checksum="$2" signature="$3" asset_name="$4" expected_hash expected_name actual_hash lines
  [[ -f "$archive" && -f "$checksum" && -f "$signature" ]] || return 1
  minisign -Vm "$checksum" -x "$signature" -p "$ONEPLUS_UPDATE_KEY" || { error "Assinatura do checksum do pacote é inválida."; return 1; }
  lines=$(grep -cve '^[[:space:]]*$' "$checksum" || true)
  [[ "$lines" == 1 ]] || { error "Arquivo de checksum deve conter exatamente uma entrada."; return 1; }
  read -r expected_hash expected_name < "$checksum"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ && "$expected_name" == "$asset_name" ]] || { error "Checksum não corresponde ao asset esperado."; return 1; }
  actual_hash=$(sha256sum "$archive" | awk '{print $1}')
  [[ "$actual_hash" == "$expected_hash" ]] || { error "SHA-256 do pacote não confere."; return 1; }
}

signed_update_release() {
  require_root
  command_exists minisign || { error "minisign não instalado."; return 1; }
  command_exists curl || { error "curl não instalado."; return 1; }
  command_exists python3 || { error "python3 não instalado."; return 1; }
  [[ -r "$ONEPLUS_UPDATE_KEY" ]] || { error "Configure primeiro a chave pública de atualização."; return 1; }

  local tag current target tmp top asset_name archive checksum signature src rollback confirm base
  current=$(cat /opt/oneplus/VERSION 2>/dev/null || echo 0.0.0)
  printf "Release assinada a instalar (ex.: v0.5.2): "; read -r tag
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { error "Tag inválida."; return 1; }
  target=${tag#v}
  if ! dpkg --compare-versions "$target" gt "$current"; then
    warn "Versão alvo ($target) não é superior à instalada ($current). Downgrade/reinstalação é recusado."
    return 1
  fi

  tmp=$(mktemp -d /tmp/oneplus-update.XXXXXX)
  trap 'rm -rf -- "${tmp:-}" 2>/dev/null || true' RETURN
  top="OnePlus-v${target}"
  asset_name="${top}.tar.gz"
  archive="$tmp/$asset_name"
  checksum="$tmp/${asset_name}.sha256"
  signature="$tmp/${asset_name}.sha256.minisig"
  base="$ONEPLUS_UPDATE_RELEASE_BASE/$tag"

  info "Baixando assets da GitHub Release $tag..."
  download_release_file "$base/$asset_name" "$archive" 67108864
  download_release_file "$base/${asset_name}.sha256" "$checksum" 4096
  download_release_file "$base/${asset_name}.sha256.minisig" "$signature" 16384

  info "Verificando assinatura externa e SHA-256 do pacote..."
  verify_external_release_assets "$archive" "$checksum" "$signature" "$asset_name" || return 1

  info "Inspecionando e extraindo pacote sem links/arquivos especiais..."
  python3 /opt/oneplus/libexec/release_verify.py extract "$archive" "$top" "$tmp/extracted" >/dev/null || return 1
  src="$tmp/extracted/$top"

  info "Verificando manifesto interno assinado..."
  verify_release_tree "$src" "$tag" || return 1

  printf "Release assinada e validada: %s -> %s\n" "$current" "$target"
  printf "Digite ATUALIZAR para instalar: "; read -r confirm
  [[ "$confirm" == ATUALIZAR ]] || { info "Cancelado."; return 0; }

  rollback=$(create_update_rollback)
  info "Rollback local: $rollback"
  if bash "$src/install.sh"; then
    if [[ "$(cat /opt/oneplus/VERSION 2>/dev/null)" == "$target" ]] && /usr/local/bin/oneplus --check; then
      cleanup_update_rollbacks "$ONEPLUS_UPDATE_KEEP_ROLLBACKS"
      rm -rf -- "$tmp"; trap - RETURN
      ok "OnePlus atualizado com sucesso para $target."
      return 0
    fi
  fi

  error "Atualização falhou. Restaurando arquivos e estados de serviços anteriores."
  restore_update_rollback "$rollback" || error "Rollback automático falhou; arquivo preservado: $rollback"
  rm -rf -- "$tmp"; trap - RETURN
  return 1
}

show_update_status() {
  local rollbacks=0
  [[ -d "$ONEPLUS_UPDATE_ROLLBACK" ]] && rollbacks=$(find "$ONEPLUS_UPDATE_ROLLBACK" -mindepth 1 -maxdepth 1 -type d -name '20????????T??????Z' | wc -l | tr -d ' ')
  printf "Versão instalada: %s\n" "$(cat /opt/oneplus/VERSION 2>/dev/null || echo N/D)"
  printf "Repositório: %s\n" "$ONEPLUS_UPDATE_REPO"
  printf "Canal estável: GitHub Releases assinadas\n"
  printf "Rollbacks locais: %s (retenção após sucesso: %s)\n" "$rollbacks" "$ONEPLUS_UPDATE_KEEP_ROLLBACKS"
  if [[ -r "$ONEPLUS_UPDATE_KEY" ]]; then
    printf "Chave confiável: %s\n" "$ONEPLUS_UPDATE_KEY"
    sed -n '1,2p' "$ONEPLUS_UPDATE_KEY"
    printf "SHA-256 da chave: %s\n" "$(sha256sum "$ONEPLUS_UPDATE_KEY" | awk '{print $1}')"
  else
    printf "Chave confiável: NÃO CONFIGURADA\n"
  fi
  printf "\nPolítica: pacote tar.gz -> checksum assinado -> extração segura -> manifesto interno assinado -> validação -> instalação.\n"
}

module_update() {
  while true; do
    clear
    printf "%bOnePlus • Atualização assinada%b\n\n" "$C_BOLD$C_CYAN" "$C_RESET"
    printf "1) Status/política\n"
    printf "2) Instalar/alterar chave pública confiável\n"
    printf "3) Atualizar por GitHub Release assinada\n"
    printf "4) Limpar rollbacks antigos (manter %s)\n" "$ONEPLUS_UPDATE_KEEP_ROLLBACKS"
    printf "0) Voltar\n\nEscolha: "
    read -r opt
    case "$opt" in
      1) clear; show_update_status; pause ;;
      2) install_update_public_key; pause ;;
      3) signed_update_release; pause ;;
      4) cleanup_update_rollbacks "$ONEPLUS_UPDATE_KEEP_ROLLBACKS"; ok "Rollbacks antigos removidos."; pause ;;
      0) return 0 ;;
      *) warn "Opção inválida"; sleep 1 ;;
    esac
  done
}
